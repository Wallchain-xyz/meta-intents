// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "@uniswap/permit2-sdk/permit2/src/interfaces/IAllowanceTransfer.sol";
import "@uniswap/permit2-sdk/permit2/src/interfaces/ISignatureTransfer.sol";
import "../../src/SearcherExecutionCapsule.sol";

contract TestUtils is Test {
    bytes32 public constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 public constant PERMIT_TRANSFER_FROM_TYPEHASH =
        keccak256(
            "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
        );

    bytes32 public constant PERMIT2_DOMAIN_SEPARATOR =
        0x4142cc3c823f819c467fa4437d637fe20589a31dfcd1da2ff22292c9ed9344e7;

    function getPermitTransferSignature(
        ISignatureTransfer.PermitTransferFrom memory permit,
        address spender,
        uint256 privateKey,
        Vm vm
    ) public pure returns (bytes memory) {
        bytes32 tokenPermissions = keccak256(
            abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted)
        );
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                PERMIT2_DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TRANSFER_FROM_TYPEHASH,
                        tokenPermissions,
                        spender,
                        permit.nonce,
                        permit.deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }
}
