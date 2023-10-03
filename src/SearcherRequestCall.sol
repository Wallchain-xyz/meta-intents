// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;
import "./SearcherExecutionCapsule.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "lib/ExcessivelySafeCall/src/ExcessivelySafeCall.sol";

contract SearcherRequestCall {
    using ExcessivelySafeCall for address;
    SearcherExecutionCapsule public immutable trustedCapsule;
    IERC20 public immutable wethAddress;

    constructor(SearcherExecutionCapsule _trustedCapsule) {
        trustedCapsule = _trustedCapsule;
        wethAddress = trustedCapsule.wethAddress();
    }

    function executeSearcherCall(
        uint256 gas,
        address searcher,
        bytes calldata searcherData,
        uint256 bid
    ) external {
        require(
            msg.sender == address(trustedCapsule),
            "msg.sender is not trusted capsule"
        );
        uint256 balanceBefore = wethAddress.balanceOf(address(trustedCapsule));

        (bool success, ) = searcher.excessivelySafeCall(
            gas,
            0, // Value
            0, // Do not copy bytes to memory
            searcherData
        );
        require(success, "Searcher Call failed");

        require(
            balanceBefore + bid <=
                wethAddress.balanceOf(address(trustedCapsule)),
            "Bid was not payed"
        );
    }
}
