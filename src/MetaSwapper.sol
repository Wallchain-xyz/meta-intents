// SPDX-License-Identifier: BUSL-1.1

/**
 * Meta Swap Router Wrapper Contract.
 * Designed by Wallchain in Metaverse.
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@uniswap/permit2-sdk/permit2/src/interfaces/IAllowanceTransfer.sol";
import "@uniswap/permit2-sdk/permit2/src/interfaces/ISignatureTransfer.sol";

import "./SearcherExecutionCapsule.sol";

contract MetaSwapper is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    address private constant _ETH_ADDRESS =
        address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    event MasterError(string message);
    event MasterError(bytes message);
    event UserTransactionModified();
    event TargetAdded(address indexed target);
    event TargetRemoved(address indexed target);

    struct WallchainExecutionParams {
        address callTarget; // Target to call. Should create MEV opportunity.
        address approveTarget; // Target to handle token transfers. Usually the same as callTarget.
        bool isPermit; // Should approveTarget be treated like Permit2.
        bytes targetData; // Target transaction data.
        uint256 amount; // Input token amount. Used in targetData for swap.
        IERC20 srcToken; // Input token. Used in targetData for swap.
        IERC20 dstToken; // Output token. Used in targetData for swap.
        ISignatureTransfer.PermitTransferFrom permit;
        bytes permit2signature;
        SearcherExecutionCapsule.SearcherRequest searcherRequest;
        bytes searcherSignature;
        address[] originators;
    }

    SearcherExecutionCapsule public searcherExecutionCapsule;
    EnumerableSet.AddressSet private _whitelistedTargets;
    ISignatureTransfer public immutable permit2;

    constructor(
        address[] memory whitelistedTargets,
        ISignatureTransfer _permit2
    ) {
        for (uint256 i = 0; i < whitelistedTargets.length; i++) {
            require(
                Address.isContract(whitelistedTargets[i]),
                "Target must be a contract"
            );
            _whitelistedTargets.add(whitelistedTargets[i]);
        }
        permit2 = _permit2;
    }

    receive() external payable {}

    function setSearcherExecutionCapsule(
        SearcherExecutionCapsule executionCapsule
    ) external onlyOwner {
        require(
            address(searcherExecutionCapsule) == address(0x0),
            "SearcherExecutionCapsule already set"
        );
        searcherExecutionCapsule = executionCapsule;
    }

    function whitelistedTargetsLength() external view returns (uint256) {
        return _whitelistedTargets.length();
    }

    function whitelistedTargetsAt(
        uint256 index
    ) external view returns (address) {
        return _whitelistedTargets.at(index);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function addTarget(address _target) external onlyOwner {
        require(Address.isContract(_target), "Target must be a contract");
        require(_whitelistedTargets.add(_target), "Target is already present");
        emit TargetAdded(_target);
    }

    function removeTarget(address _target) external onlyOwner {
        require(_whitelistedTargets.remove(_target), "Target is not present");
        emit TargetRemoved(_target);
    }

    function _isETH(IERC20 token) internal pure returns (bool) {
        return (address(token) == _ETH_ADDRESS);
    }

    function _tokenBalance(
        address token,
        address account
    ) internal view returns (uint256) {
        if (_isETH(IERC20(token))) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }

    function _maybeApproveERC20(
        IERC20 token,
        uint256 amount,
        address target,
        address callTarget,
        bool isPermit
    ) private {
        // approve router to fetch the funds for swapping
        if (isPermit) {
            if (token.allowance(address(this), target) < amount) {
                token.forceApprove(target, type(uint256).max);
            }

            IAllowanceTransfer(target).approve(
                address(token),
                callTarget,
                uint160(amount),
                uint48(block.timestamp)
            );
        } else {
            if (token.allowance(address(this), target) < amount) {
                token.forceApprove(target, amount);
            }
        }
    }

    function _transferTokens(
        address token,
        address payable destination,
        uint256 amount
    ) internal {
        if (amount > 0) {
            if (_isETH(IERC20(token))) {
                (bool result, ) = destination.call{value: amount}("");
                require(result, "Native Token Transfer Failed");
            } else {
                IERC20(token).safeTransfer(destination, amount);
            }
        }
    }

    function _processPermits(
        WallchainExecutionParams memory execution
    ) private {
        if (!_isETH(execution.srcToken)) {
            _maybeApproveERC20(
                execution.srcToken,
                execution.amount,
                execution.approveTarget,
                execution.callTarget,
                execution.isPermit
            );

            permit2.permitTransferFrom(
                execution.permit,
                ISignatureTransfer.SignatureTransferDetails(
                    address(this),
                    execution.amount
                ),
                msg.sender,
                execution.permit2signature
            );
        }
    }

    modifier backrun(WallchainExecutionParams calldata execution) {
        _;

        // Ensure user transaction that was executed meets searcher expectations.
        if (
            execution.searcherRequest.userCallHash !=
            keccak256(
                abi.encodePacked(
                    execution.callTarget,
                    execution.targetData,
                    msg.value
                )
            )
        ) {
            emit UserTransactionModified();
        } else {
            require(
                address(searcherExecutionCapsule) != address(0x0),
                "SearcherExecutionCapsule is not set"
            );
            try
                searcherExecutionCapsule.backrun(
                    execution.searcherRequest,
                    execution.searcherSignature,
                    execution.originators,
                    msg.sender // Refunded with gas
                )
            {} catch Error(string memory _err) {
                emit MasterError(_err);
            } catch (bytes memory _err) {
                emit MasterError(_err);
            }
        }
    }

    function _validateInput(
        WallchainExecutionParams calldata execution
    ) private {
        require(
            _whitelistedTargets.contains(execution.approveTarget) &&
                (execution.callTarget == execution.approveTarget ||
                    _whitelistedTargets.contains(execution.callTarget)),
            "Target must be whitelisted"
        );
        require(
            execution.callTarget != address(permit2),
            "Call target must not be Permit2"
        );

        if (_isETH(execution.srcToken)) {
            require(
                msg.value != 0,
                "Value must be above 0 when input token is Native Token"
            );
        } else {
            require(
                msg.value == 0,
                "Value must be 0 when input token is not Native Token"
            );
        }
        {
            require(
                execution.targetData.length != 0,
                "Transaction data must not be empty"
            );
            if (execution.targetData.length > 4) {
                bytes4 selector = bytes4(execution.targetData[:4]);
                require(
                    bytes4(selector) != IERC20.transferFrom.selector,
                    "transferFrom not allowed for externalCall"
                );
            }
        }
    }

    /// @return returnAmount The destination token sent to msg.sender
    function swapWithWallchain(
        WallchainExecutionParams calldata execution
    )
        external
        payable
        nonReentrant
        whenNotPaused
        backrun(execution)
        returns (uint256 returnAmount)
    {
        _validateInput(execution);

        uint256 balanceBefore = _tokenBalance(
            address(execution.dstToken),
            address(this)
        ) - (_isETH(execution.dstToken) ? msg.value : 0);

        uint256 srcBalanceBefore = _tokenBalance(
            address(execution.srcToken),
            address(this)
        ) - msg.value;

        _processPermits(execution);

        {
            (bool success, ) = execution.callTarget.call{value: msg.value}(
                execution.targetData
            );
            require(success, "Call Target failed");
        }

        uint256 balance = _tokenBalance(
            address(execution.dstToken),
            address(this)
        );

        uint256 srcBalance = _tokenBalance(
            address(execution.srcToken),
            address(this)
        );

        if (srcBalance > srcBalanceBefore) {
            _transferTokens(
                address(execution.srcToken),
                payable(msg.sender),
                srcBalance - srcBalanceBefore
            );
        }

        returnAmount = balance - balanceBefore;
        if (returnAmount > 0) {
            _transferTokens(
                address(execution.dstToken),
                payable(msg.sender),
                returnAmount
            );
        }
    }
}
