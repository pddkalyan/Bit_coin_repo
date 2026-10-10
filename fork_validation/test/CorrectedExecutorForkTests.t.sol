// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import "./ArbitrageExecutorOriginal.t.sol";
import {ArbitrageExecutor as CandidateExecutor} from "./ArbitrageExecutorCandidate.sol";

interface VmEventCapture {
    struct Log {bytes32[] topics; bytes data; address emitter;}
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

// Only the completion event's request-hash handling differs from the original
// production contract. Test uses actual Aave/Uniswap/Sushi contracts on a fork.
contract CorrectedExecutorForkTests is ArbitrageExecutorProof {
    CandidateExecutor internal corrected;

    function _setupCorrected() internal {
        address[] memory routers = new address[](2);
        routers[0] = UNI_ROUTER; routers[1] = SUSHI_ROUTER;
        address[] memory tokens = new address[](2);
        tokens[0] = WETH; tokens[1] = USDC;
        corrected = new CandidateExecutor(AAVE_POOL, address(this), routers, tokens);
    }

    function _correctedHops(uint256 loan) internal view returns (CandidateExecutor.Hop[] memory h) {
        uint256 q1 = _quote(UNI_ROUTER, loan, USDC, WETH);
        uint256 q2 = _quote(SUSHI_ROUTER, q1, WETH, USDC);
        h = new CandidateExecutor.Hop[](2);
        h[0] = CandidateExecutor.Hop(CandidateExecutor.DexType.V2, UNI_ROUTER, USDC, WETH, q1*995/1000, 0);
        h[1] = CandidateExecutor.Hop(CandidateExecutor.DexType.V2, SUSHI_ROUTER, WETH, USDC, q2*995/1000, 0);
    }

    function test_PATCH_completionEventContainsActualRequestHash() public {
        _setupCorrected();
        _whaleMovePrice(1_000 ether);
        uint256 amount=20_000e6, deadline=block.timestamp+120;
        CandidateExecutor.Hop[] memory hops=_correctedHops(amount);
        bytes32 expectedHash=keccak256(abi.encode(USDC,amount,deadline,address(this),hops));
        VmEventCapture capture = VmEventCapture(address(vm));
        capture.recordLogs();
        corrected.startArbitrage(USDC, amount, deadline, hops);
        VmEventCapture.Log[] memory entries = capture.getRecordedLogs();
        bytes32 sig=keccak256("FlashCompleted(address,uint256,uint256,uint256,bytes32)");
        bool matched=false;
        for(uint256 i=0;i<entries.length;i++){
            if(entries[i].emitter!=address(corrected) || entries[i].topics.length<2 || entries[i].topics[0]!=sig)continue;
            (uint256 loggedAmount,uint256 premium,uint256 profit,bytes32 requestHash)=
                abi.decode(entries[i].data,(uint256,uint256,uint256,bytes32));
            assertEq(loggedAmount,amount,"event original amount");
            assertGt(premium,0,"event loan premium");
            assertGt(profit,0,"event profit after fee");
            assertEq(uint256(requestHash),uint256(expectedHash),"request hash survives reset");
            matched=true;
        }
        assertTrue(matched,"corrected completion receipt must exist");
        assertEq(uint256(corrected.activeRequestHash()),0,"active request state cleared");
    }

    function test_PATCH_organicMarketDoesNotPretendProfit() public {
        _setupCorrected();
        uint256 amount=20_000e6;
        CandidateExecutor.Hop[] memory hops=_correctedHops(amount);
        vm.expectRevert(CandidateExecutor.NoProfitableRouteFound.selector);
        corrected.startArbitrage(USDC,amount,block.timestamp+120,hops);
    }

    function test_PATCH_whaleNetAfterBaseFeeEstimate() public {
        _setupCorrected();
        _whaleMovePrice(1_000 ether);
        uint256 amount=20_000e6;
        CandidateExecutor.Hop[] memory hops=_correctedHops(amount);
        uint256 startGas=gasleft();
        corrected.startArbitrage(USDC,amount,block.timestamp+120,hops);
        uint256 usedGas=startGas-gasleft();
        uint256 profit=IERC20(USDC).balanceOf(address(corrected));
        uint256 gasWei=usedGas*block.basefee;
        uint256 gasInUsdc=_quote(SUSHI_ROUTER,gasWei,WETH,USDC);
        console2.log("Whale fork corrected token profit USDC micro",profit);
        console2.log("Fork measured call gas units",usedGas);
        console2.log("Fork block basefee wei",block.basefee);
        console2.log("Approx gas cost USDC micro",gasInUsdc);
        assertGt(profit,gasInUsdc,"whale dislocation must exceed base-fee gas estimate");
    }
}
