// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LMSRMathHarness} from "./utils/LMSRMathHarness.sol";

/// @title LMSRMathFFI
/// @notice Compares Solidity LMSR math against a Python reference implementation via vm.ffi()
contract LMSRMathFFI is Test {
    LMSRMathHarness h;

    uint256 constant FUNDING = 100e6;
    uint8 constant DEC = 6;
    uint256 constant PRICE_TOLERANCE = 1e12; // WAD tolerance for prices
    uint256 constant VALUE_TOLERANCE = 1; // token-decimal tolerance

    function setUp() public {
        h = new LMSRMathHarness();
    }

    // ═══════════════════════════════════════════════════════════════════
    // FFI Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _ffiNetCost(
        uint256 balYes,
        uint256 balNo,
        int256 dYes,
        int256 dNo,
        uint256 funding,
        uint8 decimals,
        bool roundUp
    ) internal returns (int256) {
        string[] memory cmd = new string[](10);
        cmd[0] = "python3";
        cmd[1] = "script/lmsr_reference.py";
        cmd[2] = "netcost";
        cmd[3] = vm.toString(balYes);
        cmd[4] = vm.toString(balNo);
        cmd[5] = vm.toString(dYes);
        cmd[6] = vm.toString(dNo);
        cmd[7] = vm.toString(funding);
        cmd[8] = vm.toString(uint256(decimals));
        cmd[9] = vm.toString(roundUp ? uint256(1) : uint256(0));
        bytes memory result = vm.ffi(cmd);
        return abi.decode(result, (int256));
    }

    function _ffiPrice(
        uint256 balYes,
        uint256 balNo,
        uint256 funding,
        uint8 decimals
    ) internal returns (uint256) {
        string[] memory cmd = new string[](7);
        cmd[0] = "python3";
        cmd[1] = "script/lmsr_reference.py";
        cmd[2] = "price";
        cmd[3] = vm.toString(balYes);
        cmd[4] = vm.toString(balNo);
        cmd[5] = vm.toString(funding);
        cmd[6] = vm.toString(uint256(decimals));
        bytes memory result = vm.ffi(cmd);
        return abi.decode(result, (uint256));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Reserve update helpers (mirrors hook logic)
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Update reserves after buying `delta` tokens of `outcomeIndex` at `cost` collateral
    function _applyBuy(
        uint256 rYes,
        uint256 rNo,
        uint256 delta,
        uint256 cost,
        uint256 outcomeIndex
    ) internal pure returns (uint256, uint256) {
        if (outcomeIndex == 0) {
            // Buy YES: split adds cost to both, then delta YES goes to user
            rYes = rYes + cost - delta;
            rNo = rNo + cost;
        } else {
            // Buy NO: split adds cost to both, then delta NO goes to user
            rNo = rNo + cost - delta;
            rYes = rYes + cost;
        }
        return (rYes, rNo);
    }

    /// @dev Update reserves after selling `tokensIn` tokens of `outcomeIndex` for `collateralOut`
    function _applySell(
        uint256 rYes,
        uint256 rNo,
        uint256 tokensIn,
        uint256 collateralOut,
        uint256 outcomeIndex
    ) internal pure returns (uint256, uint256) {
        if (outcomeIndex == 0) {
            // Sell YES: tokens come back, merge removes collateral from both
            rYes = rYes + tokensIn - collateralOut;
            rNo = rNo - collateralOut;
        } else {
            // Sell NO
            rNo = rNo + tokensIn - collateralOut;
            rYes = rYes - collateralOut;
        }
        return (rYes, rNo);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 1: Sequential buys — price movement
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario1_sequentialBuys() public {
        // Start with funded market (split creates equal reserves)
        uint256 rYes = FUNDING;
        uint256 rNo = FUNDING;
        uint256 prevPrice = h.calcMarginalPriceBinary(rYes, rNo, FUNDING, DEC);
        assertApproxEqAbs(prevPrice, 0.5e18, 2, "initial price should be 0.5");

        for (uint256 i = 0; i < 5; i++) {
            uint256 delta = 10e6; // tokens to buy

            // Compute cost
            int256 solCost = h.calcNetCostBinary(rYes, rNo, int256(delta), 0, FUNDING, DEC, true);
            int256 pyCost = _ffiNetCost(rYes, rNo, int256(delta), 0, FUNDING, DEC, true);
            assertApproxEqAbs(solCost, pyCost, VALUE_TOLERANCE, "netCost mismatch at step");

            // Update reserves as the hook does
            (rYes, rNo) = _applyBuy(rYes, rNo, delta, uint256(solCost), 0);

            // Compare price after update
            uint256 solPrice = h.calcMarginalPriceBinary(rYes, rNo, FUNDING, DEC);
            uint256 pyPrice = _ffiPrice(rYes, rNo, FUNDING, DEC);
            assertApproxEqAbs(solPrice, pyPrice, PRICE_TOLERANCE, "price mismatch at step");

            // YES price should increase monotonically (buying YES drives price up)
            assertGt(solPrice, prevPrice, "YES price should increase after buying YES");
            prevPrice = solPrice;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 2: Buy-then-sell round-trip
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario2_buySellRoundTrip() public {
        uint256 rYes = FUNDING;
        uint256 rNo = FUNDING;
        uint256 delta = 50e6;

        // Buy 50e6 YES
        int256 buyCost = h.calcNetCostBinary(rYes, rNo, int256(delta), 0, FUNDING, DEC, false);
        int256 pyBuyCost = _ffiNetCost(rYes, rNo, int256(delta), 0, FUNDING, DEC, false);
        assertApproxEqAbs(buyCost, pyBuyCost, VALUE_TOLERANCE, "buy cost mismatch");
        assertGt(buyCost, 0, "buy should cost positive");

        (rYes, rNo) = _applyBuy(rYes, rNo, delta, uint256(buyCost), 0);

        // Sell 50e6 YES back — netCost uses negative delta
        int256 sellCost = h.calcNetCostBinary(rYes, rNo, -int256(delta), 0, FUNDING, DEC, false);
        int256 pySellCost = _ffiNetCost(rYes, rNo, -int256(delta), 0, FUNDING, DEC, false);
        assertApproxEqAbs(sellCost, pySellCost, VALUE_TOLERANCE, "sell cost mismatch");
        assertLt(sellCost, 0, "sell should return negative cost");

        // Round-trip: user gets back exactly what they paid
        assertEq(buyCost + sellCost, 0, "round-trip should net zero");

        // Partial sell: buy 50e6, sell only 25e6 — recover less than full cost
        int256 partialSell = h.calcNetCostBinary(rYes, rNo, -25e6, 0, FUNDING, DEC, false);
        int256 pyPartialSell = _ffiNetCost(rYes, rNo, -25e6, 0, FUNDING, DEC, false);
        assertApproxEqAbs(partialSell, pyPartialSell, VALUE_TOLERANCE, "partial sell mismatch");
        assertLt(uint256(-partialSell), uint256(buyCost), "partial sell < full buy cost");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 3: Mixed sequence
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario3_mixedSequence() public {
        uint256 rYes = FUNDING;
        uint256 rNo = FUNDING;

        // 6-step sequence: [delta, outcomeIndex, isBuy]
        // Buy YES 20e6, Buy NO 15e6, Buy YES 30e6, Sell YES 10e6, Buy NO 25e6, Sell NO 5e6
        uint256[3][6] memory steps = [
            [uint256(20e6), 0, 1], // Buy 20e6 YES
            [uint256(15e6), 1, 1], // Buy 15e6 NO
            [uint256(30e6), 0, 1], // Buy 30e6 YES
            [uint256(10e6), 0, 0], // Sell 10e6 YES
            [uint256(25e6), 1, 1], // Buy 25e6 NO
            [uint256(5e6), 1, 0]   // Sell 5e6 NO
        ];

        for (uint256 i = 0; i < 6; i++) {
            uint256 size = steps[i][0];
            uint256 outcomeIdx = steps[i][1];
            bool isBuy = steps[i][2] == 1;

            if (isBuy) {
                // Build delta for calcNetCostBinary
                int256 dYes = outcomeIdx == 0 ? int256(size) : int256(0);
                int256 dNo = outcomeIdx == 1 ? int256(size) : int256(0);

                int256 solCost = h.calcNetCostBinary(rYes, rNo, dYes, dNo, FUNDING, DEC, true);
                int256 pyCost = _ffiNetCost(rYes, rNo, dYes, dNo, FUNDING, DEC, true);
                assertApproxEqAbs(solCost, pyCost, VALUE_TOLERANCE, "netCost mismatch in mixed seq");

                (rYes, rNo) = _applyBuy(rYes, rNo, size, uint256(solCost), outcomeIdx);
            } else {
                // Sell: negative delta
                int256 dYes = outcomeIdx == 0 ? -int256(size) : int256(0);
                int256 dNo = outcomeIdx == 1 ? -int256(size) : int256(0);

                int256 solCost = h.calcNetCostBinary(rYes, rNo, dYes, dNo, FUNDING, DEC, false);
                int256 pyCost = _ffiNetCost(rYes, rNo, dYes, dNo, FUNDING, DEC, false);
                assertApproxEqAbs(solCost, pyCost, VALUE_TOLERANCE, "netCost mismatch in mixed seq");

                uint256 collateralOut = uint256(-solCost);
                (rYes, rNo) = _applySell(rYes, rNo, size, collateralOut, outcomeIdx);
            }

            // Compare price after update
            uint256 solPrice = h.calcMarginalPriceBinary(rYes, rNo, FUNDING, DEC);
            uint256 pyPrice = _ffiPrice(rYes, rNo, FUNDING, DEC);
            assertApproxEqAbs(solPrice, pyPrice, PRICE_TOLERANCE, "price mismatch in mixed seq");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 4: Price sum invariant — pYES + pNO == 1
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario4_priceSumInvariant() public {
        uint256 rYes = FUNDING;
        uint256 rNo = FUNDING;

        // Reuse scenario 3's 6-step mixed sequence
        uint256[3][6] memory steps = [
            [uint256(20e6), 0, 1],
            [uint256(15e6), 1, 1],
            [uint256(30e6), 0, 1],
            [uint256(10e6), 0, 0],
            [uint256(25e6), 1, 1],
            [uint256(5e6), 1, 0]
        ];

        for (uint256 i = 0; i < 6; i++) {
            uint256 size = steps[i][0];
            uint256 outcomeIdx = steps[i][1];
            bool isBuy = steps[i][2] == 1;

            if (isBuy) {
                int256 dYes = outcomeIdx == 0 ? int256(size) : int256(0);
                int256 dNo = outcomeIdx == 1 ? int256(size) : int256(0);
                int256 solCost = h.calcNetCostBinary(rYes, rNo, dYes, dNo, FUNDING, DEC, true);
                (rYes, rNo) = _applyBuy(rYes, rNo, size, uint256(solCost), outcomeIdx);
            } else {
                int256 dYes = outcomeIdx == 0 ? -int256(size) : int256(0);
                int256 dNo = outcomeIdx == 1 ? -int256(size) : int256(0);
                int256 solCost = h.calcNetCostBinary(rYes, rNo, dYes, dNo, FUNDING, DEC, false);
                (rYes, rNo) = _applySell(rYes, rNo, size, uint256(-solCost), outcomeIdx);
            }

            // Solidity: pYES + pNO == 1e18
            uint256 solPriceYes = h.calcMarginalPriceBinary(rYes, rNo, FUNDING, DEC);
            uint256 solPriceNo = h.calcMarginalPriceBinary(rNo, rYes, FUNDING, DEC);
            assertApproxEqAbs(solPriceYes + solPriceNo, 1e18, PRICE_TOLERANCE, "sol price sum != 1");

            // Python: pYES + pNO == 1e18
            uint256 pyPriceYes = _ffiPrice(rYes, rNo, FUNDING, DEC);
            uint256 pyPriceNo = _ffiPrice(rNo, rYes, FUNDING, DEC);
            assertApproxEqAbs(pyPriceYes + pyPriceNo, 1e18, PRICE_TOLERANCE, "py price sum != 1");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 5: Simultaneous delta — netCost([d,d]) == d
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario5_simultaneousDelta() public {
        uint256 d = 10e6;

        // At balanced reserves, netCost([d,d]) should equal d
        int256 solCost = h.calcNetCostBinary(FUNDING, FUNDING, int256(d), int256(d), FUNDING, DEC, false);
        assertApproxEqAbs(solCost, int256(d), VALUE_TOLERANCE, "balanced: netCost([d,d]) != d");

        int256 pyCost = _ffiNetCost(FUNDING, FUNDING, int256(d), int256(d), FUNDING, DEC, false);
        assertApproxEqAbs(pyCost, int256(d), VALUE_TOLERANCE, "py balanced: netCost([d,d]) != d");

        // Skew reserves first: buy 50e6 YES
        uint256 rYes = FUNDING;
        uint256 rNo = FUNDING;
        int256 skewCost = h.calcNetCostBinary(rYes, rNo, 50e6, 0, FUNDING, DEC, true);
        (rYes, rNo) = _applyBuy(rYes, rNo, 50e6, uint256(skewCost), 0);

        // Invariant still holds at asymmetric reserves
        int256 solCostSkewed = h.calcNetCostBinary(rYes, rNo, int256(d), int256(d), FUNDING, DEC, false);
        assertApproxEqAbs(solCostSkewed, int256(d), VALUE_TOLERANCE, "skewed: netCost([d,d]) != d");

        int256 pyCostSkewed = _ffiNetCost(rYes, rNo, int256(d), int256(d), FUNDING, DEC, false);
        assertApproxEqAbs(pyCostSkewed, int256(d), VALUE_TOLERANCE, "py skewed: netCost([d,d]) != d");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 6: Extreme price — large trade drives price near 1
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario6_extremePrice() public {
        uint256 rYes = FUNDING;
        uint256 rNo = FUNDING;
        // b = funding/ln(2) ≈ 144e6, need delta/b > ln(99) ≈ 4.6 for price > 0.99
        // 700e6 / 144e6 ≈ 4.86 → price ≈ 0.992
        uint256 delta = 700e6;

        // Buy 700e6 YES from balanced market
        int256 solCost = h.calcNetCostBinary(rYes, rNo, int256(delta), 0, FUNDING, DEC, true);
        int256 pyCost = _ffiNetCost(rYes, rNo, int256(delta), 0, FUNDING, DEC, true);
        assertApproxEqAbs(solCost, pyCost, VALUE_TOLERANCE, "extreme: netCost mismatch");

        (rYes, rNo) = _applyBuy(rYes, rNo, delta, uint256(solCost), 0);

        // Verify extreme prices
        uint256 solPriceYes = h.calcMarginalPriceBinary(rYes, rNo, FUNDING, DEC);
        uint256 pyPriceYes = _ffiPrice(rYes, rNo, FUNDING, DEC);
        assertApproxEqAbs(solPriceYes, pyPriceYes, PRICE_TOLERANCE, "extreme: price mismatch");

        assertGt(solPriceYes, 0.99e18, "YES price should be > 0.99");

        uint256 solPriceNo = h.calcMarginalPriceBinary(rNo, rYes, FUNDING, DEC);
        assertLt(solPriceNo, 0.01e18, "NO price should be < 0.01");

        // Price sum invariant at extreme
        assertApproxEqAbs(solPriceYes + solPriceNo, 1e18, PRICE_TOLERANCE, "extreme: price sum != 1");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 7: Many small trades — rounding error accumulation
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario7_manySmallTrades() public {
        uint256 rYes = FUNDING;
        uint256 rNo = FUNDING;
        uint256 prevPrice = h.calcMarginalPriceBinary(rYes, rNo, FUNDING, DEC);
        uint256 delta = 1e6;

        for (uint256 i = 0; i < 20; i++) {
            int256 solCost = h.calcNetCostBinary(rYes, rNo, int256(delta), 0, FUNDING, DEC, true);
            int256 pyCost = _ffiNetCost(rYes, rNo, int256(delta), 0, FUNDING, DEC, true);
            assertApproxEqAbs(solCost, pyCost, VALUE_TOLERANCE, "small trade: netCost mismatch");

            (rYes, rNo) = _applyBuy(rYes, rNo, delta, uint256(solCost), 0);

            uint256 solPrice = h.calcMarginalPriceBinary(rYes, rNo, FUNDING, DEC);
            uint256 pyPrice = _ffiPrice(rYes, rNo, FUNDING, DEC);
            assertApproxEqAbs(solPrice, pyPrice, PRICE_TOLERANCE, "small trade: price mismatch");

            // Monotonic price increase
            assertGt(solPrice, prevPrice, "price should increase monotonically");
            prevPrice = solPrice;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 8: Large single trade — massive buy
    // ═══════════════════════════════════════════════════════════════════

    function test_scenario8_largeSingleTrade() public {
        uint256 rYes = FUNDING;
        uint256 rNo = FUNDING;
        // Single massive buy: 800e6 YES (≈5.5× b)
        uint256 delta = 800e6;

        int256 solCost = h.calcNetCostBinary(rYes, rNo, int256(delta), 0, FUNDING, DEC, true);
        int256 pyCost = _ffiNetCost(rYes, rNo, int256(delta), 0, FUNDING, DEC, true);
        assertApproxEqAbs(solCost, pyCost, VALUE_TOLERANCE, "large trade: netCost mismatch");

        // Cost must be less than tokens received (you never pay more than delta)
        assertLt(uint256(solCost), delta, "cost should be < tokens received");

        (rYes, rNo) = _applyBuy(rYes, rNo, delta, uint256(solCost), 0);

        // Cross-check resulting price
        uint256 solPrice = h.calcMarginalPriceBinary(rYes, rNo, FUNDING, DEC);
        uint256 pyPrice = _ffiPrice(rYes, rNo, FUNDING, DEC);
        assertApproxEqAbs(solPrice, pyPrice, PRICE_TOLERANCE, "large trade: price mismatch");

        assertGt(solPrice, 0.99e18, "YES price should be > 0.99 after large buy");
    }

}
