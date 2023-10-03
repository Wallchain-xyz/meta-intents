// SPDX-License-Identifier: GPL-2.0-or-later

/**
 * BaseContract for searchers
 * Designed by Wallchain in Metaverse.
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract SearcherBase is Ownable {
    // Address to be invoked from as part of Wallchain's pipeline preparation.
    address public immutable trustedExecutionCapsule;
    // Address to be invoked from as part of Wallchain's pipeline execution.
    address public immutable trustedSearcherRequestCall;

    constructor(
        address _trustedExecutionCapsule,
        address _trustedSearcherRequestCall
    ) Ownable() {
        trustedExecutionCapsule = _trustedExecutionCapsule;
        trustedSearcherRequestCall = _trustedSearcherRequestCall;
    }

    // Should be applied to the searcher external main faction.
    modifier onlyTrustedRequestCall() {
        require(
            msg.sender == trustedSearcherRequestCall,
            "Msg sender is not trusted SearcherRequestCall"
        );
        _;
    }

    function prePayGas(uint256 gasAmount) external {
        require(
            msg.sender == trustedExecutionCapsule,
            "msg.sender not trusted"
        );
        (bool sent, ) = msg.sender.call{value: gasAmount}("");
        require(sent, "Gas PrePay Failed");
    }
}
