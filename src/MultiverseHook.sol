// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {MultiverseMarkets} from "./MultiverseMarkets.sol";
import {LMSRMath} from "./LMSRMath.sol";
import {IMarketHook} from "./IMarketHook.sol";

contract MultiverseHook is BaseHook, IMarketHook, ReentrancyGuardTransient {
    error NotImplementedYet();
    error UnknownToken();
    error MarketResolved();
    error InsufficientLiquidity();
    error CrossUniverseSwapsNotSupportedYet();
    error TokenNotWinner();
    error OnlyMultiverseMarket();
    error MarketAlreadyExists();
    error SlippageExceeded();

    uint8 internal constant DECIMALS = 6;

    struct MarketState {
        Currency collateralToken;
        Currency yesToken;
        Currency noToken;
        uint256 funding;
        uint256 reserveYes;
        uint256 reserveNo;
        uint256 reserveCollateral;
    }

    MultiverseMarkets public immutable multiverseMarket;

    mapping(bytes32 => MarketState) public markets;
    mapping(address => bytes32) public tokenToUniverse;

    constructor(
        IPoolManager _poolManager,
        MultiverseMarkets _multiverseMarket
    ) BaseHook(_poolManager) {
        multiverseMarket = _multiverseMarket;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function onCreateMarket(
        bytes32 universeId,
        address collateral,
        address yesToken,
        address noToken,
        uint256 amount
    ) external override nonReentrant {
        if (msg.sender != address(multiverseMarket)) revert OnlyMultiverseMarket();
        if (Currency.unwrap(markets[universeId].collateralToken) != address(0)) revert MarketAlreadyExists();

        markets[universeId] = MarketState({
            collateralToken: Currency.wrap(collateral),
            yesToken: Currency.wrap(yesToken),
            noToken: Currency.wrap(noToken),
            funding: amount,
            reserveYes: amount,
            reserveNo: amount,
            reserveCollateral: amount
        });

        tokenToUniverse[yesToken] = universeId;
        tokenToUniverse[noToken] = universeId;

        // C-3 + M-3: Use max approval — hook trusts immutable multiverseMarket
        SafeTransferLib.safeApprove(collateral, address(multiverseMarket), type(uint256).max);
        multiverseMarket.split(universeId, amount);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Currency tokenIn = params.zeroForOne ? key.currency0 : key.currency1;
        Currency tokenOut = params.zeroForOne ? key.currency1 : key.currency0;

        bytes32 cid = _resolveUniverse(tokenIn, tokenOut);

        uint8 action = _classifySwap(cid, tokenIn, tokenOut);
        if (action == 1) return _executeBuy(cid, tokenIn, tokenOut, params, hookData);
        if (action == 2) return _executeSell(cid, tokenIn, tokenOut, params, hookData);
        if (action == 3) return _executeRedeem(cid, tokenIn, tokenOut, params);
        revert CrossUniverseSwapsNotSupportedYet(); // unreachable if _classifySwap is correct
    }

    /// @dev Returns 1=buy, 2=sell, 3=redeem. Reverts on invalid.
    function _classifySwap(bytes32 cid, Currency tokenIn, Currency tokenOut) internal view returns (uint8) {
        MarketState storage state = markets[cid];

        bool isBuy = _currenciesEqual(tokenIn, state.collateralToken) && _isMultiverseToken(state, tokenOut);
        bool isSell = _isMultiverseToken(state, tokenIn) && _currenciesEqual(tokenOut, state.collateralToken);

        if (!isBuy && !isSell) revert CrossUniverseSwapsNotSupportedYet();

        if (isBuy) {
            if (multiverseMarket.resolved(cid) != address(0)) revert MarketResolved();
            return 1;
        }

        address winner = multiverseMarket.resolved(cid);
        if (winner == address(0)) return 2;
        if (winner != Currency.unwrap(tokenIn)) revert TokenNotWinner();
        return 3;
    }

    function _resolveUniverse(Currency tokenIn, Currency tokenOut) internal view returns (bytes32) {
        bytes32 cid = tokenToUniverse[Currency.unwrap(tokenIn)];
        if (cid != bytes32(0)) return cid;
        cid = tokenToUniverse[Currency.unwrap(tokenOut)];
        if (cid != bytes32(0)) return cid;
        revert UnknownToken();
    }

    function _isMultiverseToken(MarketState storage state, Currency token) internal view returns (bool) {
        return _currenciesEqual(token, state.yesToken) || _currenciesEqual(token, state.noToken);
    }

    function _currenciesEqual(Currency a, Currency b) internal pure returns (bool) {
        return Currency.unwrap(a) == Currency.unwrap(b);
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert NotImplementedYet();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert NotImplementedYet();
    }

    function calcMarginalPrice(bytes32 universeId, Currency token) public view returns (uint256) {
        MarketState storage state = markets[universeId];
        uint256 yesPrice = LMSRMath.calcMarginalPriceBinary(
            state.reserveYes, state.reserveNo, state.funding, 6
        );
        if (Currency.unwrap(token) == Currency.unwrap(state.yesToken)) {
            return yesPrice;
        } else if (Currency.unwrap(token) == Currency.unwrap(state.noToken)) {
            return 1e18 - yesPrice;
        }
        revert UnknownToken();
    }

    function _executeBuy(bytes32 cid, Currency tokenIn, Currency tokenOut, SwapParams calldata params, bytes calldata hookData)
        private
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        MarketState storage state = markets[cid];
        uint256 cost;
        uint256 delta;

        if (params.amountSpecified > 0) {
            delta = uint256(params.amountSpecified);

            uint256[] memory quantities = new uint256[](2);
            quantities[0] = state.reserveYes;
            quantities[1] = state.reserveNo;

            int256[] memory amounts = new int256[](2);
            if (_currenciesEqual(tokenOut, state.yesToken)) {
                amounts[0] = int256(delta);
                amounts[1] = 0;
            } else {
                amounts[0] = 0;
                amounts[1] = int256(delta);
            }

            cost = uint256(LMSRMath.calcNetCost(quantities, amounts, state.funding, DECIMALS, true));
        } else {
            cost = uint256(-params.amountSpecified);
            uint256 outcomeIndex = _currenciesEqual(tokenOut, state.yesToken) ? 0 : 1;
            delta = LMSRMath.calcTradeAmountBinary(
                state.reserveYes, state.reserveNo, int256(cost), outcomeIndex, state.funding, DECIMALS
            );
        }

        if (cost == 0 || delta == 0) revert InsufficientLiquidity();

        // M-4: Slippage protection via hookData
        if (hookData.length >= 32) {
            uint256 limit = abi.decode(hookData, (uint256));
            if (params.amountSpecified > 0 && cost > limit) revert SlippageExceeded();
            if (params.amountSpecified < 0 && delta < limit) revert SlippageExceeded();
        }

        poolManager.take(tokenIn, address(this), cost);
        // C-3/M-3: Max approval set once in onCreateMarket — no per-trade approval needed
        multiverseMarket.split(cid, cost);

        poolManager.sync(tokenOut);
        SafeTransferLib.safeTransfer(Currency.unwrap(tokenOut), address(poolManager), delta);
        poolManager.settle();

        // Update reserves
        if (_currenciesEqual(tokenOut, state.yesToken)) {
            state.reserveYes += cost;
            state.reserveYes -= delta;
            state.reserveNo += cost;
        } else {
            state.reserveNo += cost;
            state.reserveNo -= delta;
            state.reserveYes += cost;
        }
        state.reserveCollateral += cost;

        // H-1: Reserve drift detection — fail fast if reserves diverge from actual balances
        assert(ERC20(Currency.unwrap(state.yesToken)).balanceOf(address(this)) >= state.reserveYes);
        assert(ERC20(Currency.unwrap(state.noToken)).balanceOf(address(this)) >= state.reserveNo);

        // H-4: Safe casts to prevent silent truncation
        if (params.amountSpecified > 0) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(-SafeCastLib.toInt128(int256(delta)), SafeCastLib.toInt128(int256(cost))), 0);
        } else {
            return (this.beforeSwap.selector, toBeforeSwapDelta(SafeCastLib.toInt128(int256(cost)), -SafeCastLib.toInt128(int256(delta))), 0);
        }
    }

    function _executeSell(bytes32 cid, Currency tokenIn, Currency tokenOut, SwapParams calldata params, bytes calldata hookData)
        private
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        MarketState storage state = markets[cid];
        uint256 tokensIn;
        uint256 collateralOut;

        if (params.amountSpecified < 0) {
            tokensIn = uint256(-params.amountSpecified);

            uint256[] memory quantities = new uint256[](2);
            quantities[0] = state.reserveYes;
            quantities[1] = state.reserveNo;

            int256[] memory amounts = new int256[](2);
            if (_currenciesEqual(tokenIn, state.yesToken)) {
                amounts[0] = -int256(tokensIn);
                amounts[1] = 0;
            } else {
                amounts[0] = 0;
                amounts[1] = -int256(tokensIn);
            }

            int256 netCost = LMSRMath.calcNetCost(quantities, amounts, state.funding, DECIMALS, false);
            if (netCost >= 0) revert InsufficientLiquidity();
            collateralOut = uint256(-netCost);
        } else {
            collateralOut = uint256(params.amountSpecified);
            uint256 outcomeIndex = _currenciesEqual(tokenIn, state.yesToken) ? 0 : 1;
            tokensIn = LMSRMath.calcTradeAmountBinary(
                state.reserveYes, state.reserveNo, -int256(collateralOut), outcomeIndex, state.funding, DECIMALS
            );
        }

        if (tokensIn == 0 || collateralOut == 0) revert InsufficientLiquidity();

        // M-4: Slippage protection via hookData
        if (hookData.length >= 32) {
            uint256 limit = abi.decode(hookData, (uint256));
            if (params.amountSpecified < 0 && collateralOut < limit) revert SlippageExceeded();
            if (params.amountSpecified > 0 && tokensIn > limit) revert SlippageExceeded();
        }

        // H-2: Verify hook holds enough of the counter-token for merge
        Currency counterToken = _currenciesEqual(tokenIn, state.yesToken) ? state.noToken : state.yesToken;
        uint256 counterBal = ERC20(Currency.unwrap(counterToken)).balanceOf(address(this));
        if (counterBal < collateralOut) revert InsufficientLiquidity();

        poolManager.take(tokenIn, address(this), tokensIn);
        multiverseMarket.merge(cid, collateralOut);

        poolManager.sync(tokenOut);
        SafeTransferLib.safeTransfer(Currency.unwrap(tokenOut), address(poolManager), collateralOut);
        poolManager.settle();

        // Update reserves
        if (_currenciesEqual(tokenIn, state.yesToken)) {
            state.reserveYes += tokensIn;
            state.reserveYes -= collateralOut;
            state.reserveNo -= collateralOut;
        } else {
            state.reserveNo += tokensIn;
            state.reserveNo -= collateralOut;
            state.reserveYes -= collateralOut;
        }
        state.reserveCollateral -= collateralOut;

        // H-1: Reserve drift detection
        assert(ERC20(Currency.unwrap(state.yesToken)).balanceOf(address(this)) >= state.reserveYes);
        assert(ERC20(Currency.unwrap(state.noToken)).balanceOf(address(this)) >= state.reserveNo);

        // H-4: Safe casts
        if (params.amountSpecified < 0) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(SafeCastLib.toInt128(int256(tokensIn)), -SafeCastLib.toInt128(int256(collateralOut))), 0);
        } else {
            return (this.beforeSwap.selector, toBeforeSwapDelta(-SafeCastLib.toInt128(int256(collateralOut)), SafeCastLib.toInt128(int256(tokensIn))), 0);
        }
    }

    // H-3: Named `cid` parameter + reserve updates after redeem
    // L-3: Measure actual collateral received instead of assuming 1:1
    function _executeRedeem(bytes32 cid, Currency tokenIn, Currency tokenOut, SwapParams calldata params)
        private
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 amount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        poolManager.take(tokenIn, address(this), amount);

        // L-3: Measure actual collateral received rather than assuming 1:1
        uint256 colBefore = ERC20(Currency.unwrap(tokenOut)).balanceOf(address(this));
        multiverseMarket.redeem(Currency.unwrap(tokenIn), amount);
        uint256 colReceived = ERC20(Currency.unwrap(tokenOut)).balanceOf(address(this)) - colBefore;

        poolManager.sync(tokenOut);
        SafeTransferLib.safeTransfer(Currency.unwrap(tokenOut), address(poolManager), colReceived);
        poolManager.settle();

        // H-3: Update reserves post-redemption
        MarketState storage state = markets[cid];
        if (_currenciesEqual(tokenIn, state.yesToken)) {
            state.reserveYes -= amount;
        } else {
            state.reserveNo -= amount;
        }
        state.reserveCollateral -= colReceived;

        // H-4: Safe casts
        if (params.amountSpecified < 0) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(SafeCastLib.toInt128(int256(amount)), -SafeCastLib.toInt128(int256(colReceived))), 0);
        } else {
            return (this.beforeSwap.selector, toBeforeSwapDelta(-SafeCastLib.toInt128(int256(colReceived)), SafeCastLib.toInt128(int256(amount))), 0);
        }
    }
}
