pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title LMSRMathLOG2
/// @notice Logarithmic Market Scoring Rule pricing math using WAD-based fixed-point arithmetic.
/// @dev C(q) = b·ln(Σ exp(qᵢ/b)), where b = funding/ln(N). Prices = softmax. But Uses LOG2.
library LMSRMathLOG2 {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;


    /// @notice Compute the net cost of a trade: C(q + delta) - C(q)
    /// @param balances Current token balances per outcome
    /// @param amounts Trade amounts per outcome (positive=buy, negative=sell)
    /// @param funding Market funding amount
    /// @param decimals Token decimal places
    /// @param roundUp If true, round in favor of the protocol
    /// @return netCost Signed cost (positive=trader pays, negative=trader receives)
    function calcNetCost(
        uint256[] memory balances,
        int256[] memory amounts,
        uint256 funding,
        uint8 decimals,
        bool roundUp
    ) internal pure returns (int256 netCost) {
        return 0;
    }


    /// @notice Compute the marginal price (softmax) for a given outcome
    /// @param quantities Token quantities per outcome (in token decimals)
    /// @param funding Market funding amount (in token decimals)
    /// @param outcomeIndex Index of the outcome to price
    /// @param decimals Token decimal places
    /// @return price WAD-scaled price [0, 1e18]
    function calcMarginalPrice(
        uint256[] memory quantities,
        uint256 funding,
        uint256 outcomeIndex,
        uint8 decimals
    ) internal pure returns (uint256 price) {
        return 0;
    }

    function sumExpOffset(
        int256 log2N,
        int[] memory otExpNums,
        uint8 outcomeIndex
    ) private view returns (uint256 sum, int256 offset, uint256 outcomeExpTerm) {
        return (0,0,0);
    }
}