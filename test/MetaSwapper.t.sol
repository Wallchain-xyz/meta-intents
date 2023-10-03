// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/MetaSwapper.sol";
import "../src/SearcherExecutionCapsule.sol";
import "../src/searcher/WChainMasterV3.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/metatx/MinimalForwarder.sol";
import "@uniswap/permit2-sdk/permit2/src/interfaces/IAllowanceTransfer.sol";
import "@uniswap/permit2-sdk/permit2/src/interfaces/ISignatureTransfer.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {TestUtils} from "./utils/Utils.sol";
import "./TestHelper.sol";

// Testing https://bscscan.com/tx/0x2b3f96d085be140e19f92be515a76a8c13b21f67f8549d65f3908f587804d336
contract MetaSwapperTest is Test, TestHelper {
    using ECDSA for bytes32;
    event MasterError(string message);
    event EvmError(string message);
    event NonceError();
    event SearcherError(string message);
    event SearcherError(bytes message);
    event UserTransactionModified();

    MetaSwapper public metaSwapWrapper;
    SearcherExecutionCapsule public searcherExecutionCapsule;
    SearcherRequestCall public searcherRequestCall;

    WChainMasterV3 public searcherWChainMasterV3;
    TestUtils public utils;

    SearcherExecutionCapsule.SearcherRequest public searcherTx;
    bytes public searcherSignature;

    uint256 requestedAmount = 28724244166535293965;
    uint256 requestedAmountBNB = 106927161003544874;
    ISignatureTransfer.PermitTransferFrom public permit2 =
        ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(
                address(CAKE_TOKEN),
                requestedAmount
            ),
            58287030565013270674326244417476654535129209701280052917947412217452428886362, //nonce
            1688475247 //deadline
        );

    function setUp() public {
        forkNetwork = vm.createFork(vm.envString("CHAIN_RPC_URL"));
        vm.selectFork(forkNetwork);
        vm.rollFork(forkNetwork, BLOCK_START);
        vm.txGasPrice(4000000000); // 4 Gwei

        // Deploy MetaSwapper & SearcherExecutionCapsule
        vm.startPrank(wallchainEOA);
        metaSwapWrapper = new MetaSwapper(
            whitelistedTargetsBNB,
            ISignatureTransfer(permit2Address)
        );
        searcherExecutionCapsule = new SearcherExecutionCapsule(
            IWETH(WBNB),
            address(metaSwapWrapper),
            prePayGasLimit
        );
        searcherRequestCall = new SearcherRequestCall(searcherExecutionCapsule);

        metaSwapWrapper.setSearcherExecutionCapsule(searcherExecutionCapsule);
        searcherExecutionCapsule.setSearcherRequestCall(searcherRequestCall);
        utils = new TestUtils();
        vm.stopPrank();

        // // Deploy Searcher
        vm.startPrank(searcherEOA);
        searcherWChainMasterV3 = new WChainMasterV3(
            address(searcherExecutionCapsule),
            address(searcherRequestCall)
        );

        vm.deal(address(searcherWChainMasterV3), 1 ether);
        vm.deal(msgSender, 10 ether);
        vm.stopPrank();

        // Generate Searcher signature
        uint8 v;
        bytes32 r;
        bytes32 s;
        searcherTx = SearcherExecutionCapsule.SearcherRequest({
            to: address(searcherWChainMasterV3),
            gas: 1_000_000,
            nonce: 100, //searcherNextNonce(searcherEOA),
            data: abi.encodeWithSelector(
                WChainMasterV3.execute.selector,
                masterInput,
                100
            ),
            bid: 100,
            userCallHash: keccak256(
                abi.encodePacked(
                    userCallTarget,
                    userTargetData,
                    /*value*/ uint256(0)
                )
            ),
            maxGasPrice: tx.gasprice * 2,
            deadline: block.timestamp + 1
        });

        vm.startPrank(searcherEOA);
        (v, r, s) = vm.sign(
            searcherPK,
            searcherExecutionCapsule.getDigest(searcherTx)
        );
        searcherSignature = abi.encodePacked(r, s, v);
        vm.stopPrank();

        vm.startPrank(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
        CAKE_TOKEN.transfer(msgSender, requestedAmount);
        IERC20(WBNB).transfer(msgSender, requestedAmountBNB);
        IERC20(WBNB).transfer(
            address(searcherWChainMasterV3),
            requestedAmountBNB
        );
        vm.stopPrank();

        vm.allowCheatcodes(0xB3052d703489a568D9276f3eAEf5EDd9B4326157);
        vm.allowCheatcodes(0x7cbD330aF178E052ad56BB8646D36Db22ABE01F3);
        originators.push(msgSender);
    }

    function testSwapWithWallchain() public {
        vm.txGasPrice(4000000000);
        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        uint256 balanceBefore = IERC20(WBNB).balanceOf(msgSender);
        vm.startPrank(msgSender);
        CAKE_TOKEN.approve(permit2Address, requestedAmount);
        metaSwapWrapper.swapWithWallchain(
            MetaSwapper.WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetData,
                amount: requestedAmount,
                srcToken: CAKE_TOKEN,
                dstToken: IERC20(0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40),
                permit: permit2,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            })
        );
        vm.stopPrank();
        uint256 balanceAfter = IERC20(WBNB).balanceOf(msgSender);
        assertTrue(
            balanceBefore + (searcherTx.bid * 9) / 10 <= balanceAfter,
            "Bid was not payed"
        );

        uint256 wallchainBalance = IERC20(WBNB).balanceOf(wallchainEOA);
        vm.startPrank(wallchainEOA);
        IERC20[] memory listOfWBNB = new IERC20[](1);
        listOfWBNB[0] = IERC20(WBNB);
        searcherExecutionCapsule.withdrawEth();
        searcherExecutionCapsule.withdrawAll(listOfWBNB);
        vm.stopPrank();
        assertTrue(
            wallchainBalance < IERC20(WBNB).balanceOf(wallchainEOA),
            "Withdraw failed"
        );
    }

    function testDuplicateNonce() public {
        vm.txGasPrice(4000000000);
        testSwapWithWallchain();
        bytes
            memory userTargetDataBNB = hex"5ae401dc0000000000000000000000000000000000000000000000000000000064a40ab400000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000e4472b43f3000000000000000000000000000000000000000000000000017be1afb875112a000000000000000000000000000000000000000000000000000a2000bdb7865c0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000a2d82453f7353aff8281e8de76b03e3e2f23ff170000000000000000000000000000000000000000000000000000000000000002000000000000000000000000bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c000000000000000000000000827f22c99819674641ab76cf186b2ec13e34aab000000000000000000000000000000000000000000000000000000000";
        ISignatureTransfer.PermitTransferFrom
            memory permit2BNB = ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(
                    address(WBNB),
                    requestedAmountBNB
                ),
                22, //nonce
                1688475647 //deadline
            );

        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2BNB,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        // Generate Searcher signature
        uint8 v;
        bytes32 r;
        bytes32 s;
        searcherTx = SearcherExecutionCapsule.SearcherRequest({
            to: address(searcherWChainMasterV3),
            gas: 1_000_000,
            nonce: 100,
            data: abi.encodeWithSelector(
                WChainMasterV3.execute.selector,
                masterInput,
                0 // burn profit
            ),
            bid: 100,
            userCallHash: keccak256(
                abi.encodePacked(
                    userCallTarget,
                    userTargetDataBNB,
                    /*value*/ uint256(0)
                )
            ),
            maxGasPrice: tx.gasprice * 2,
            deadline: block.timestamp + 1
        });

        vm.startPrank(searcherEOA);
        (v, r, s) = vm.sign(
            searcherPK,
            searcherExecutionCapsule.getDigest(searcherTx)
        );
        searcherSignature = abi.encodePacked(r, s, v);
        vm.stopPrank();

        vm.startPrank(msgSender);
        IERC20(WBNB).approve(permit2Address, requestedAmount);
        MetaSwapper.WallchainExecutionParams memory exectionParams = MetaSwapper
            .WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetDataBNB,
                amount: requestedAmountBNB,
                srcToken: IERC20(WBNB),
                dstToken: IERC20(0xbA2aE424d960c26247Dd6c32edC70B295c744C43), // Doge
                permit: permit2BNB,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            });

        vm.expectEmit();
        emit NonceError();
        metaSwapWrapper.swapWithWallchain(exectionParams);
        vm.stopPrank();
    }

    function testInvalidateNonce() public {
        vm.txGasPrice(4000000000);
        testSwapWithWallchain();
        bytes
            memory userTargetDataBNB = hex"5ae401dc0000000000000000000000000000000000000000000000000000000064a40ab400000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000e4472b43f3000000000000000000000000000000000000000000000000017be1afb875112a000000000000000000000000000000000000000000000000000a2000bdb7865c0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000a2d82453f7353aff8281e8de76b03e3e2f23ff170000000000000000000000000000000000000000000000000000000000000002000000000000000000000000bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c000000000000000000000000827f22c99819674641ab76cf186b2ec13e34aab000000000000000000000000000000000000000000000000000000000";
        ISignatureTransfer.PermitTransferFrom
            memory permit2BNB = ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(
                    address(WBNB),
                    requestedAmountBNB
                ),
                22, //nonce
                1688475647 //deadline
            );

        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2BNB,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        // Generate Searcher signature
        uint8 v;
        bytes32 r;
        bytes32 s;
        searcherTx = SearcherExecutionCapsule.SearcherRequest({
            to: address(searcherWChainMasterV3),
            gas: 1_000_000,
            nonce: 100,
            data: abi.encodeWithSelector(
                WChainMasterV3.execute.selector,
                masterInput,
                0 // burn profit
            ),
            bid: 100,
            userCallHash: keccak256(
                abi.encodePacked(
                    userCallTarget,
                    userTargetDataBNB,
                    /*value*/ uint256(0)
                )
            ),
            maxGasPrice: tx.gasprice * 2,
            deadline: block.timestamp + 1
        });

        vm.startPrank(searcherEOA);
        (v, r, s) = vm.sign(
            searcherPK,
            searcherExecutionCapsule.getDigest(searcherTx)
        );
        searcherSignature = abi.encodePacked(r, s, v);

        searcherExecutionCapsule.invalidateNonce(100);
        vm.stopPrank();

        vm.startPrank(msgSender);
        IERC20(WBNB).approve(permit2Address, requestedAmount);
        MetaSwapper.WallchainExecutionParams memory exectionParams = MetaSwapper
            .WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetDataBNB,
                amount: requestedAmountBNB,
                srcToken: IERC20(WBNB),
                dstToken: IERC20(0xbA2aE424d960c26247Dd6c32edC70B295c744C43), // Doge
                permit: permit2BNB,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            });

        metaSwapWrapper.swapWithWallchain(exectionParams);
        vm.stopPrank();
    }

    function testBidNotPayed() public {
        vm.txGasPrice(4000000000);
        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        // Generate Searcher signature
        uint8 v;
        bytes32 r;
        bytes32 s;
        searcherTx = SearcherExecutionCapsule.SearcherRequest({
            to: address(searcherWChainMasterV3),
            gas: 1_000_000,
            nonce: 100,
            data: abi.encodeWithSelector(
                WChainMasterV3.execute.selector,
                masterInput,
                0 // don't pay
            ),
            bid: 100,
            userCallHash: keccak256(
                abi.encodePacked(
                    userCallTarget,
                    userTargetData,
                    /*value*/ uint256(0)
                )
            ),
            maxGasPrice: tx.gasprice * 2,
            deadline: block.timestamp + 1
        });

        vm.startPrank(searcherEOA);
        (v, r, s) = vm.sign(
            searcherPK,
            searcherExecutionCapsule.getDigest(searcherTx)
        );
        searcherSignature = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 msgSenderBalanceBefore = address(msgSender).balance;
        uint256 searcherCapsuleBalanceBefore = IERC20(WBNB).balanceOf(
            address(searcherExecutionCapsule)
        );
        vm.startPrank(msgSender);
        CAKE_TOKEN.approve(permit2Address, requestedAmount);

        MetaSwapper.WallchainExecutionParams memory execution = MetaSwapper
            .WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetData,
                amount: requestedAmount,
                srcToken: CAKE_TOKEN,
                dstToken: IERC20(0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40),
                permit: permit2,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            });

        vm.expectEmit();
        emit SearcherError(string("Bid was not payed"));
        metaSwapWrapper.swapWithWallchain(execution);
        vm.stopPrank();

        assertTrue(
            msgSenderBalanceBefore < address(msgSender).balance,
            "Gas was not refunded to msg sender"
        );
        assertTrue(
            searcherCapsuleBalanceBefore <
                IERC20(WBNB).balanceOf(address(searcherExecutionCapsule)),
            "Gas was not converted for searcher capsule"
        );
    }

    function testDeadlinePassed() public {
        vm.txGasPrice(4000000000);
        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        // Generate Searcher signature
        uint8 v;
        bytes32 r;
        bytes32 s;
        searcherTx = SearcherExecutionCapsule.SearcherRequest({
            to: address(searcherWChainMasterV3),
            gas: 1_000_000,
            nonce: 100,
            data: abi.encodeWithSelector(
                WChainMasterV3.execute.selector,
                masterInput,
                0 // don't pay
            ),
            bid: 100,
            userCallHash: keccak256(
                abi.encodePacked(
                    userCallTarget,
                    userTargetData,
                    /*value*/ uint256(0)
                )
            ),
            maxGasPrice: tx.gasprice * 2,
            deadline: block.timestamp - 1
        });

        vm.startPrank(searcherEOA);
        (v, r, s) = vm.sign(
            searcherPK,
            searcherExecutionCapsule.getDigest(searcherTx)
        );
        searcherSignature = abi.encodePacked(r, s, v);
        vm.stopPrank();

        vm.startPrank(msgSender);
        CAKE_TOKEN.approve(permit2Address, requestedAmount);

        MetaSwapper.WallchainExecutionParams memory execution = MetaSwapper
            .WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetData,
                amount: requestedAmount,
                srcToken: CAKE_TOKEN,
                dstToken: IERC20(0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40),
                permit: permit2,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            });

        vm.expectEmit();
        emit MasterError("SearcherExecution: EXPIRED");
        metaSwapWrapper.swapWithWallchain(execution);
        vm.stopPrank();
    }

    function testUserTxnModified() public {
        vm.txGasPrice(4000000000);
        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        // Generate Searcher signature
        uint8 v;
        bytes32 r;
        bytes32 s;
        searcherTx = SearcherExecutionCapsule.SearcherRequest({
            to: address(searcherWChainMasterV3),
            gas: 1_000_000,
            nonce: 100,
            data: abi.encodeWithSelector(
                WChainMasterV3.execute.selector,
                masterInput,
                100 //bid
            ),
            bid: 100,
            userCallHash: keccak256(
                abi.encodePacked(
                    0x10ED43C718714eb63d5aA57B78B54704E256024E,
                    userTargetData,
                    /*value*/ uint256(0)
                )
            ),
            maxGasPrice: tx.gasprice * 2,
            deadline: block.timestamp
        });

        vm.startPrank(searcherEOA);
        (v, r, s) = vm.sign(
            searcherPK,
            searcherExecutionCapsule.getDigest(searcherTx)
        );
        searcherSignature = abi.encodePacked(r, s, v);
        vm.stopPrank();

        vm.startPrank(msgSender);
        CAKE_TOKEN.approve(permit2Address, requestedAmount);

        MetaSwapper.WallchainExecutionParams memory execution = MetaSwapper
            .WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetData,
                amount: requestedAmount,
                srcToken: CAKE_TOKEN,
                dstToken: IERC20(0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40),
                permit: permit2,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            });

        vm.expectEmit();
        emit UserTransactionModified();
        metaSwapWrapper.swapWithWallchain(execution);
        vm.stopPrank();
    }

    function testUserTxnFailed() public {
        vm.txGasPrice(4000000000);
        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        // Generate Searcher signature
        uint8 v;
        bytes32 r;
        bytes32 s;
        searcherTx = SearcherExecutionCapsule.SearcherRequest({
            to: address(searcherWChainMasterV3),
            gas: 1_000_000,
            nonce: 100,
            data: abi.encodeWithSelector(
                WChainMasterV3.execute.selector,
                masterInput,
                100 //bid
            ),
            bid: 100,
            userCallHash: keccak256(
                abi.encodePacked(
                    userCallTarget,
                    userTargetData,
                    /*value*/ uint256(0)
                )
            ),
            maxGasPrice: tx.gasprice * 2,
            deadline: block.timestamp
        });

        vm.startPrank(searcherEOA);
        (v, r, s) = vm.sign(
            searcherPK,
            searcherExecutionCapsule.getDigest(searcherTx)
        );
        searcherSignature = abi.encodePacked(r, s, v);
        vm.stopPrank();

        vm.startPrank(msgSender);
        CAKE_TOKEN.approve(permit2Address, requestedAmount);

        MetaSwapper.WallchainExecutionParams memory execution = MetaSwapper
            .WallchainExecutionParams({
                callTarget: 0x10ED43C718714eb63d5aA57B78B54704E256024E, // PancakeV2 - wrong router
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetData,
                amount: requestedAmount,
                srcToken: CAKE_TOKEN,
                dstToken: IERC20(0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40),
                permit: permit2,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            });

        vm.expectRevert(bytes("Call Target failed"));
        metaSwapWrapper.swapWithWallchain(execution);
        vm.stopPrank();
    }

    function testSearcherOutOfGas() public {
        address swapBeneficiary = 0xCDA20F2C2256b3982686a7BBeB7648804409a060;
        vm.txGasPrice(4000000000);
        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        // Generate Searcher signature
        uint8 v;
        bytes32 r;
        bytes32 s;
        searcherTx = SearcherExecutionCapsule.SearcherRequest({
            to: address(searcherWChainMasterV3),
            gas: 100_0,
            nonce: 100,
            data: abi.encodeWithSelector(
                WChainMasterV3.execute.selector,
                masterInput,
                100
            ),
            bid: 100,
            userCallHash: keccak256(
                abi.encodePacked(
                    userCallTarget,
                    userTargetData,
                    /*value*/ uint256(0)
                )
            ),
            maxGasPrice: tx.gasprice * 2,
            deadline: block.timestamp
        });

        vm.startPrank(searcherEOA);
        (v, r, s) = vm.sign(
            searcherPK,
            searcherExecutionCapsule.getDigest(searcherTx)
        );
        searcherSignature = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 balanceBefore = IERC20(
            0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40
        ).balanceOf(swapBeneficiary);
        vm.startPrank(msgSender);
        CAKE_TOKEN.approve(permit2Address, requestedAmount);

        MetaSwapper.WallchainExecutionParams memory execution = MetaSwapper
            .WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetData,
                amount: requestedAmount,
                srcToken: CAKE_TOKEN,
                dstToken: IERC20(0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40),
                permit: permit2,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            });

        vm.expectEmit();
        emit SearcherError(string("Searcher Call failed"));
        metaSwapWrapper.swapWithWallchain(execution);
        vm.stopPrank();

        uint256 balanceAfter = IERC20(
            0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40
        ).balanceOf(swapBeneficiary);
        assertTrue(balanceBefore < balanceAfter, "Swap was not executed");
    }

    function testMetaSwapWrapperSetup() public {
        vm.txGasPrice(4000000000);
        // Deploy Searcher capsule cannot be set twice
        vm.startPrank(wallchainEOA);
        vm.expectRevert(bytes("SearcherExecutionCapsule already set"));
        metaSwapWrapper.setSearcherExecutionCapsule(searcherExecutionCapsule);
        vm.allowCheatcodes(0xB3052d703489a568D9276f3eAEf5EDd9B4326157);
        MetaSwapper metaSwapWrapperNoSearcher = new MetaSwapper(
            whitelistedTargetsBNB,
            ISignatureTransfer(permit2Address)
        );
        vm.stopPrank();

        // Searcher capusle not set
        vm.startPrank(msgSender);
        CAKE_TOKEN.approve(permit2Address, requestedAmount);
        MetaSwapper.WallchainExecutionParams memory execution = MetaSwapper
            .WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetData,
                amount: requestedAmount,
                srcToken: CAKE_TOKEN,
                dstToken: IERC20(0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40),
                permit: permit2,
                permit2signature: utils.getPermitTransferSignature(
                    permit2,
                    address(metaSwapWrapperNoSearcher),
                    msgSenderPK,
                    vm
                ),
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            });
        vm.expectRevert(bytes("SearcherExecutionCapsule is not set"));
        metaSwapWrapperNoSearcher.swapWithWallchain(execution);
        vm.stopPrank();

        // Wrong meta wrapper calls searcher capsule
        vm.startPrank(wallchainEOA);
        metaSwapWrapperNoSearcher.setSearcherExecutionCapsule(
            searcherExecutionCapsule
        );
        vm.stopPrank();

        vm.startPrank(msgSender);
        vm.expectEmit();
        emit MasterError("SearcherExecution: Sender is not trusted");
        metaSwapWrapperNoSearcher.swapWithWallchain(execution);
        vm.stopPrank();
    }

    function testTargets() public {
        vm.txGasPrice(4000000000);

        vm.startPrank(wallchainEOA);
        uint256 targetsLen = metaSwapWrapper.whitelistedTargetsLength();
        address testTarget = 0xD2F4e803757ceE9257a0111953c92976E353Dcb1;
        metaSwapWrapper.removeTarget(testTarget);
        assertTrue(
            targetsLen == metaSwapWrapper.whitelistedTargetsLength() + 1,
            "Target was not removed"
        );
        metaSwapWrapper.addTarget(testTarget);
        assertTrue(
            targetsLen == metaSwapWrapper.whitelistedTargetsLength(),
            "Target was not added"
        );
        assertTrue(
            testTarget == metaSwapWrapper.whitelistedTargetsAt(targetsLen - 1),
            "Target was not added at the end"
        );

        vm.stopPrank();

        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        uint256 balanceBefore = IERC20(WBNB).balanceOf(msgSender);
        vm.startPrank(msgSender);
        CAKE_TOKEN.approve(permit2Address, requestedAmount);
        metaSwapWrapper.swapWithWallchain(
            MetaSwapper.WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetData,
                amount: requestedAmount,
                srcToken: CAKE_TOKEN,
                dstToken: IERC20(0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40),
                permit: permit2,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            })
        );
        vm.stopPrank();
        uint256 balanceAfter = IERC20(WBNB).balanceOf(msgSender);
        assertTrue(
            balanceBefore + (searcherTx.bid * 9) / 10 <= balanceAfter,
            "Bid was not payed"
        );
    }

    function testPause() public {
        vm.txGasPrice(4000000000);

        vm.startPrank(wallchainEOA);
        metaSwapWrapper.pause();
        vm.stopPrank();

        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        uint256 balanceBefore = IERC20(WBNB).balanceOf(msgSender);
        vm.startPrank(msgSender);
        CAKE_TOKEN.approve(permit2Address, requestedAmount);
        MetaSwapper.WallchainExecutionParams memory metaParams = MetaSwapper
            .WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetData,
                amount: requestedAmount,
                srcToken: CAKE_TOKEN,
                dstToken: IERC20(0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40),
                permit: permit2,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            });

        vm.expectRevert(bytes("Pausable: paused"));
        metaSwapWrapper.swapWithWallchain(metaParams);
        vm.stopPrank();

        vm.startPrank(wallchainEOA);
        metaSwapWrapper.unpause();
        vm.stopPrank();

        vm.startPrank(msgSender);
        metaSwapWrapper.swapWithWallchain(metaParams);
        vm.stopPrank();

        uint256 balanceAfter = IERC20(WBNB).balanceOf(msgSender);
        assertTrue(
            balanceBefore + (searcherTx.bid * 9) / 10 <= balanceAfter,
            "Bid was not payed"
        );
    }

    function testMetaSwapperFundsReturned() public {
        vm.txGasPrice(4000000000);
        bytes memory userSignedPermit2 = utils.getPermitTransferSignature(
            permit2,
            address(metaSwapWrapper),
            msgSenderPK,
            vm
        );

        // Generate Searcher signature
        uint8 v;
        bytes32 r;
        bytes32 s;
        searcherTx = SearcherExecutionCapsule.SearcherRequest({
            to: address(searcherWChainMasterV3),
            gas: 1_000_000,
            nonce: 100,
            data: abi.encodeWithSelector(
                WChainMasterV3.execute.selector,
                masterInput,
                100 // don't pay
            ),
            bid: 100,
            userCallHash: keccak256(
                abi.encodePacked(
                    userCallTarget,
                    userTargetDataMetaSwapperBeneficiary,
                    /*value*/ uint256(0)
                )
            ),
            maxGasPrice: tx.gasprice * 2,
            deadline: block.timestamp
        });

        vm.startPrank(searcherEOA);
        (v, r, s) = vm.sign(
            searcherPK,
            searcherExecutionCapsule.getDigest(searcherTx)
        );
        searcherSignature = abi.encodePacked(r, s, v);
        vm.stopPrank();

        vm.startPrank(msgSender);
        CAKE_TOKEN.approve(permit2Address, requestedAmount);

        MetaSwapper.WallchainExecutionParams memory execution = MetaSwapper
            .WallchainExecutionParams({
                callTarget: userCallTarget,
                approveTarget: userCallTarget,
                isPermit: false,
                targetData: userTargetDataMetaSwapperBeneficiary,
                amount: requestedAmount,
                srcToken: CAKE_TOKEN,
                dstToken: IERC20(0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40),
                permit: permit2,
                permit2signature: userSignedPermit2,
                searcherRequest: searcherTx,
                searcherSignature: searcherSignature,
                originators: originators
            });
        uint256 balanceBefore = IERC20(
            0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40
        ).balanceOf(msgSender);
        // Swap router returns tokens to swap wrapper which refunds it to the user.
        metaSwapWrapper.swapWithWallchain(execution);
        vm.stopPrank();
        uint256 balanceAfter = IERC20(
            0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40
        ).balanceOf(msgSender);
        assertTrue(
            balanceBefore < balanceAfter,
            "Swap was not returned to the user"
        );
    }
}
