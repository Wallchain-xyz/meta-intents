// SPDX-License-Identifier: GPL-2.0-or-later

/**
 * Profit Capturing Wallchain Master Contract.
 * Designed by Wallchain in Metaverse.
 */

pragma solidity >=0.8.6;

import "@uniswap/v3-core/contracts/libraries/TransferHelper.sol";

import "../SearcherBase.sol";

contract WChainMasterV3 is SearcherBase {
    constructor(
        address _trustedExecutionCapsule,
        address _trustedSearcherRequestCall
    ) SearcherBase(_trustedExecutionCapsule, _trustedSearcherRequestCall) {}

    receive() external payable {}

    function execute(
        bytes calldata, // input
        uint256 bid
    ) external onlyTrustedRequestCall {
        TransferHelper.safeTransfer(
            0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
            trustedExecutionCapsule,
            bid
        );
    }
}
