// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import "./ArbitrageExecutorOriginal.t.sol";

/**
 * Diagnose independently maintained Aave V3 pools listed in Aave DAO's address book.
 * This test adjusts only pool choice in a freshly deployed UNMODIFIED original
 * ArbitrageExecutor. It does NOT validate a real trading opportunity.
 * Ref: aave-dao/aave-address-book/src/AaveV3EthereumLido.sol
 * Ref: aave-dao/aave-address-book/src/AaveV3EthereumEtherFi.sol
 */
contract AaveVerifiedMarketsCandidate is ArbitrageExecutorProof {
    address internal constant LIDO_POOL = 0x4e033931ad43597d96D6bcc25c280717730B58B1;
    address internal constant ETHERFI_POOL = 0x0AA97c284e98396202b6A04024F5E2c65026F3c0;

    function _setPool(address pool) internal {
        address[] memory routers = new address[](2);
        routers[0] = UNI_ROUTER;
        routers[1] = SUSHI_ROUTER;
        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        arb = new ArbitrageExecutor(pool, address(this), routers, tokens);
    }

    function test_CANDIDATE_lidoPremiumReadable() public {
        _setPool(LIDO_POOL);
        uint256 premium = arb.flashLoanPremiumBps();
        console2.log("Lido market loan premium bps", premium);
        assertTrue(premium > 0 && premium < 1000, "premium looks plausible");
    }

    function test_CANDIDATE_etherFiPremiumReadable() public {
        _setPool(ETHERFI_POOL);
        uint256 premium = arb.flashLoanPremiumBps();
        console2.log("EtherFi market loan premium bps", premium);
        assertTrue(premium > 0 && premium < 1000, "premium looks plausible");
    }

    function test_CANDIDATE_lidoWhaleCycle() public {
        _setPool(LIDO_POOL);
        _whaleMovePrice(1_000 ether);
        uint256 input = 20_000e6;
        uint256 beforeGas = gasleft();
        uint256 profit = _runArb(input, _buildHops(input));
        uint256 gasUsed = beforeGas - gasleft();
        console2.log("Lido fork USDC profit token units", profit);
        console2.log("Lido fork simulated gas used", gasUsed);
        assertGt(profit, 0, "Lido fork whale cycle profit");
    }

    function test_CANDIDATE_etherFiWhaleCycle() public {
        _setPool(ETHERFI_POOL);
        _whaleMovePrice(1_000 ether);
        uint256 input = 2_000e6; // limited EtherFi USDC reserve
        uint256 beforeGas = gasleft();
        uint256 profit = _runArb(input, _buildHops(input));
        uint256 gasUsed = beforeGas - gasleft();
        console2.log("EtherFi fork USDC profit token units", profit);
        console2.log("EtherFi fork simulated gas used", gasUsed);
        assertGt(profit, 0, "EtherFi fork whale cycle profit");
    }
}
