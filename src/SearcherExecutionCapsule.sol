// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import "lib/ExcessivelySafeCall/src/ExcessivelySafeCall.sol";
import "./SearcherBase.sol";
import "./SearcherRequestCall.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract SearcherExecutionCapsule is Ownable, EIP712, ReentrancyGuard {
    using ExcessivelySafeCall for address;
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;
    using BitMaps for BitMaps.BitMap;
    event WithdrawAll();
    event WithdrawEth();
    event GaspriceOverSearcherLimit();
    event SearcherSignatureNotValid();
    event SearcherGasRefundFailed();
    event SetSearcherRequestCall();
    event GasWalletRefundFailed();
    event SearcherError(string message);
    event SearcherError(bytes message);
    event NonceInvalidation(address indexed owner, uint256 index);
    event NonceError();
    event Extracted(
        uint256 bid,
        address searcherAddress,
        bytes searcherSignature
    );

    bytes32 constant _WALLCHAIN_HASH =
        keccak256(
            "SearcherRequest(address to,uint256 gas,uint256 nonce,bytes data,uint256 bid,bytes32 userCallHash,uint256 maxGasPrice, uint256 deadline)"
        );
    IWETH public immutable wethAddress;
    SearcherRequestCall public searcherRequestCall;
    address public immutable trustedMetaSwapWrapper;
    uint256 public immutable prePayGasLimit;

    // The unordered bitmap of nonces used by the searcher
    mapping(address => BitMaps.BitMap) internal _searcherNonceBitmap;

    /**
     * @dev The struct of the searcher request to be executed as backrunning
     * @param to The address of the contract to be called
     * @param gas The gas limit of the transaction
     * @param nonce The unordered nonce of the searcher txn
     * @param data The data of the transaction to be called
     * @param bid The bid of the searcher
     * @param userCallHash The hash of user call, to verify match
     * @param maxGasPrice The max gas price searcher is ready to pay
     * @param deadline The deadline for the searcher transaction to expire
     */
    struct SearcherRequest {
        address to;
        uint256 gas;
        uint256 nonce;
        bytes data;
        uint256 bid;
        bytes32 userCallHash;
        uint256 maxGasPrice;
        uint256 deadline;
    }

    /**
     * @param _wethAddress The address of the WETH contract on chain
     * @param _trustedMetaSwapWrapper The only contract to run pipeline
     * @param _prePayGasLimit The once-set hard limit on the computations to do
     * in prepay-gas function. Used to prevent extensive computations in that
     * func.
     */
    constructor(
        IWETH _wethAddress,
        address _trustedMetaSwapWrapper,
        uint256 _prePayGasLimit
    ) EIP712("SearcherExecutionCapsule", "1") {
        wethAddress = _wethAddress;
        trustedMetaSwapWrapper = _trustedMetaSwapWrapper;
        prePayGasLimit = _prePayGasLimit;
    }

    /** @dev Will set the nonce in the storage, returns false if already set.
     */
    function _isNonceValid(
        address from,
        uint256 nonce
    ) internal returns (bool) {
        bool isNonceUsed = _searcherNonceBitmap[from].get(nonce);
        _searcherNonceBitmap[from].set(nonce);
        return !isNonceUsed;
    }

    /** @dev Invalidates nonce of the caller. Anyone can invalidate their own nonces.
     */
    function invalidateNonce(uint256 index) external {
        _searcherNonceBitmap[msg.sender].unset(index);
        emit NonceInvalidation(msg.sender, index);
    }

    function setSearcherRequestCall(
        SearcherRequestCall requestCall
    ) external onlyOwner {
        require(
            address(searcherRequestCall) == address(0x0),
            "SearcherRequestCall already set"
        );
        searcherRequestCall = requestCall;
        emit SetSearcherRequestCall();
    }

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "SearcherExecution: EXPIRED");
        _;
    }

    modifier onlyTrusted() {
        require(
            msg.sender == trustedMetaSwapWrapper,
            "SearcherExecution: Sender is not trusted"
        );
        _;
    }

    modifier verifySignature(
        SearcherRequest calldata searcherRequest,
        bytes calldata signature
    ) {
        if (tx.gasprice > searcherRequest.maxGasPrice) {
            emit GaspriceOverSearcherLimit();
            return;
        }

        address signer = getDigest(searcherRequest).recover(signature);
        if (signer != Ownable(searcherRequest.to).owner()) {
            emit SearcherSignatureNotValid();
            return;
        }

        if (!_isNonceValid(signer, searcherRequest.nonce)) {
            emit NonceError();
            return;
        }
        _;
    }

    function withdrawEth() external onlyOwner {
        (bool result, ) = msg.sender.call{value: address(this).balance}("");
        require(result, "Failed to withdraw Ether");
        emit WithdrawEth();
    }

    function withdrawAll(IERC20[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].safeTransfer(
                msg.sender,
                tokens[i].balanceOf(address(this))
            );
        }
        emit WithdrawAll();
    }

    function getDigest(
        SearcherRequest calldata searcherRequest
    ) public view returns (bytes32 payload) {
        return _hashTypedDataV4(getSearcherHash(searcherRequest));
    }

    receive() external payable {}

    function getSearcherHash(
        SearcherRequest calldata searcherRequest
    ) public pure returns (bytes32 searcherHash) {
        return
            keccak256(
                abi.encode(
                    _WALLCHAIN_HASH,
                    searcherRequest.to,
                    searcherRequest.gas,
                    searcherRequest.nonce,
                    keccak256(searcherRequest.data),
                    searcherRequest.bid,
                    searcherRequest.userCallHash,
                    searcherRequest.maxGasPrice,
                    searcherRequest.deadline
                )
            );
    }

    function _refundExtraGasToSearcher(
        uint256 gasLeftBefore,
        uint256 searcherGas,
        address searcher
    ) internal {
        uint256 gasLeftAfter = gasleft();
        if (gasLeftAfter + searcherGas > gasLeftBefore) {
            (bool success, ) = searcher.excessivelySafeCall(
                prePayGasLimit,
                (gasLeftAfter + searcherGas - gasLeftBefore) * tx.gasprice, // Value
                0, // Do not copy bytes to memory
                ""
            );

            if (!success) {
                emit SearcherGasRefundFailed();
            }
        }
    }

    function _prePayGas(uint256 searcherGas, address searcher) internal {
        uint256 balanceBefore = address(this).balance;
        // Limit computations in the prepay-gas function.
        (bool success, ) = searcher.excessivelySafeCall(
            prePayGasLimit,
            0, // Value
            0, // Do not copy bytes to memory
            abi.encodeWithSelector(
                SearcherBase.prePayGas.selector,
                searcherGas * tx.gasprice
            )
        );
        require(success, "Searcher prepay gas failed");
        require(
            address(this).balance >= balanceBefore + searcherGas * tx.gasprice,
            "Searcher did not prepay gas"
        );
    }

    function _refundGas(address gasWallet) internal {
        (bool success, ) = gasWallet.call{value: address(this).balance}("");
        if (!success) {
            emit GasWalletRefundFailed();
        }
    }

    function _distributeBid(
        address[] calldata originators,
        uint256 bid,
        address searcherAddress,
        bytes calldata searcherSignature
    ) internal {
        if (originators.length > 0) {
            uint256 profit = ((bid * 9) / 10) / originators.length;
            for (
                uint256 origIndex = 0;
                origIndex < originators.length;
                origIndex++
            ) {
                wethAddress.transfer(originators[origIndex], profit);
            }
        }
        emit Extracted(bid, searcherAddress, searcherSignature);
    }

    function _executeSearcherCall(
        SearcherRequest calldata request
    ) internal returns (bool) {
        try
            searcherRequestCall.executeSearcherCall(
                request.gas,
                request.to,
                request.data,
                request.bid
            )
        {} catch Error(string memory _err) {
            emit SearcherError(_err);
            return false;
        } catch (bytes memory _err) {
            emit SearcherError(_err);
            return false;
        }
        return true;
    }

    function _convertRemainingGas(
        uint256 gasLeftBefore,
        uint256 searcherGas
    ) internal {
        uint256 gasLeft = gasleft();
        if (searcherGas > (gasLeftBefore - gasLeft)) {
            wethAddress.deposit{
                value: (searcherGas - (gasLeftBefore - gasLeft)) * tx.gasprice
            }();
        }
    }

    function backrun(
        SearcherRequest calldata searcherRequest,
        bytes calldata _signature,
        address[] calldata originators,
        address gasWallet
    )
        external
        onlyTrusted
        nonReentrant
        ensure(searcherRequest.deadline)
        verifySignature(searcherRequest, _signature)
    {
        uint256 gasLeftBefore = gasleft();
        _prePayGas(searcherRequest.gas, searcherRequest.to);

        if (!_executeSearcherCall(searcherRequest)) {
            // If searcher call failed or bid was not repaid.
            _convertRemainingGas(gasLeftBefore, searcherRequest.gas);

            _refundGas(gasWallet);
            return;
        }
        // Distribute bid to originators
        _distributeBid(
            originators,
            searcherRequest.bid,
            searcherRequest.to,
            _signature
        );

        // Refund remaining gas to searcher
        _refundExtraGasToSearcher(
            gasLeftBefore,
            searcherRequest.gas,
            searcherRequest.to
        );

        // Refund gas to gas wallet
        _refundGas(gasWallet);
    }
}
