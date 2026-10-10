// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import "./ArbitrageExecutorOriginal.t.sol";
// Tests use the actual original contract, no mock Aave/DEX. Fork is created in setUp.
contract ArbitrageExecutorIndependentForkTest is ArbitrageExecutorProof {
 function test_FORK_directCallbackMustFail() public {
   ArbitrageExecutor.Hop[] memory empty = new ArbitrageExecutor.Hop[](0);
   bytes memory params=abi.encode(USDC,uint256(20_000e6),block.timestamp+120,address(this),empty);
   vm.expectRevert(ArbitrageExecutor.ExecutionTimeout.selector); // direct call fails the initial timeout guard first
   arb.executeOperation(USDC,20_000e6,0,address(arb),params);
 }
 function test_FORK_pauseBlocksExecution() public {
   arb.pause();
   ArbitrageExecutor.Hop[] memory hops=_buildHops(20_000e6);
   vm.expectRevert(ArbitrageExecutor.ContractPaused.selector);
   arb.startArbitrage(USDC,20_000e6,block.timestamp+120,hops);
 }
 function test_FORK_nonOwnerCannotSweep() public {
   vm.prank(address(0xbaddad));
   vm.expectRevert(ArbitrageExecutor.Unauthorized.selector);
   arb.sweepToken(USDC,address(0xbaddad),1000);
 }
 function test_FORK_nonOwnerCannotWithdraw() public {
   vm.prank(address(0xbaddad));
   vm.expectRevert(ArbitrageExecutor.Unauthorized.selector);
   arb.emergencyProfitWithdraw(USDC,address(0xbaddad),1000);
 }
 function test_FORK_unprofitableLoanIsRejected() public {
   ArbitrageExecutor.Hop[] memory hops=_buildHops(20_000e6);
   arb.setMinProfitBps(9000);
   vm.expectRevert();
   arb.startArbitrage(USDC,20_000e6,block.timestamp+120,hops);
 }
}
