// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LMSRMath} from "../../src/LMSRMath.sol";

/// @dev Wrapper contract to expose library functions for testing
contract LMSRMathHarness {
    function calcCostFunction(
        uint256[] memory quantities,
        uint256 funding,
        uint8 decimals
    ) external pure returns (uint256) {
        return LMSRMath.calcCostFunction(quantities, funding, decimals);
    }

    function calcMarginalPrice(
        uint256[] memory quantities,
        uint256 funding,
        uint256 outcomeIndex,
        uint8 decimals
    ) external pure returns (uint256) {
        return LMSRMath.calcMarginalPrice(quantities, funding, outcomeIndex, decimals);
    }

    function calcNetCost(
        uint256[] memory quantities,
        int256[] memory amounts,
        uint256 funding,
        uint8 decimals,
        bool roundUp
    ) external pure returns (int256) {
        return LMSRMath.calcNetCost(quantities, amounts, funding, decimals, roundUp);
    }

    function calcMarginalPriceBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        uint256 funding,
        uint8 decimals
    ) external pure returns (uint256) {
        return LMSRMath.calcMarginalPriceBinary(balanceYes, balanceNo, funding, decimals);
    }

    function calcNetCostBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        int256 deltaYes,
        int256 deltaNo,
        uint256 funding,
        uint8 decimals,
        bool roundUp
    ) external pure returns (int256) {
        return LMSRMath.calcNetCostBinary(balanceYes, balanceNo, deltaYes, deltaNo, funding, decimals, roundUp);
    }

    function calcTradeAmountBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        int256 amount,
        uint256 outcomeIndex,
        uint256 funding,
        uint8 decimals
    ) external pure returns (uint256) {
        return LMSRMath.calcTradeAmountBinary(balanceYes, balanceNo, amount, outcomeIndex, funding, decimals);
    }

    function calcTokenSwapBinary(
        uint256 balanceYes,
        uint256 balanceNo,
        uint256 tokensToSell,
        uint256 sellOutcomeIndex,
        uint256 funding,
        uint8 decimals
    ) external pure returns (uint256) {
        return LMSRMath.calcTokenSwapBinary(balanceYes, balanceNo, tokensToSell, sellOutcomeIndex, funding, decimals);
    }
}
