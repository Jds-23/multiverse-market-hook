// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {SimpleERC20} from "../src/SimpleERC20.sol";
import {MultiverseMarkets} from "../src/MultiverseMarkets.sol";
import {MultiverseHook} from "../src/MultiverseHook.sol";
import {console} from "forge-std/console.sol";


contract MultiverseHookTest is BaseTest, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    uint256 constant FUNDING = 10_000e6;
    uint256 constant INITIAL_LIQUIDITY = 10_000e6;
    bytes32 constant UNIVERSE_ID = keccak256("test-condition");
    bytes32 constant UNIVERSE_ID_2 = keccak256("test-condition-2");

    MultiverseHook hook;
    SimpleERC20 collateral;
    MultiverseMarkets multiverseMarkets;

    Currency collateralCurrency;
    Currency yesCurrency;
    Currency noCurrency;

    PoolKey poolKeyColYes;
    PoolKey poolKeyColNo;
    PoolKey poolKeyYesNo;

    // Pending action routing state
    uint8 constant ACTION_SWAP = 3;
    uint8 constant ACTION_SWAP_EXACT_OUTPUT = 4;

    uint8 pendingAction;
    Currency pendingTokenIn;
    Currency pendingTokenOut;
    uint256 pendingAmountIn;
    uint256 pendingAmountOut;
    uint256 pendingMaxAmountIn;

    function setUp() public {
        // 1. Deploy infrastructure
        deployArtifactsAndLabel();

        // 2. Deploy collateral + MultiverseMarkets
        collateral = new SimpleERC20("Collateral", "COL");
        multiverseMarkets = new MultiverseMarkets(poolManager);
        vm.label(address(collateral), "Collateral");
        vm.label(address(multiverseMarkets), "MultiverseMarkets");

        // 3. Compute flag address and deploy hook
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager, multiverseMarkets);
        deployCodeTo("MultiverseHook.sol:MultiverseHook", constructorArgs, flags);
        hook = MultiverseHook(flags);
        vm.label(flags, "Hook");

        // 4. Wire hook to CM
        multiverseMarkets.setHook(hook);

        // 5. Mint collateral and approve CM
        collateral.mint(address(this), INITIAL_LIQUIDITY * 10);
        collateral.approve(address(multiverseMarkets), type(uint256).max);

        // 6. Create market (deploys tokens, splits, initializes pools)
        multiverseMarkets.createMarket(UNIVERSE_ID, address(collateral), FUNDING);

        // 7. Split some tokens for test contract (needed for pre-transfer sell/redeem patterns)
        collateral.approve(address(multiverseMarkets), type(uint256).max);
        multiverseMarkets.split(UNIVERSE_ID, INITIAL_LIQUIDITY * 2);

        // 8. Read YES/NO tokens
        (address colAddr, address yesAddr, address noAddr) = multiverseMarkets.universes(UNIVERSE_ID);
        collateralCurrency = Currency.wrap(colAddr);
        yesCurrency = Currency.wrap(yesAddr);
        noCurrency = Currency.wrap(noAddr);
        vm.label(yesAddr, "YesToken");
        vm.label(noAddr, "NoToken");

        // 8. Pool keys (for swap helpers)
        poolKeyColYes = _makePoolKey(Currency.wrap(address(collateral)), yesCurrency);
        poolKeyColNo = _makePoolKey(Currency.wrap(address(collateral)), noCurrency);
        poolKeyYesNo = _makePoolKey(yesCurrency, noCurrency);

        // 9. Approvals for swaps
        collateral.approve(address(hook), type(uint256).max);
        collateral.approve(address(poolManager), type(uint256).max);

        IERC20(yesAddr).approve(address(hook), type(uint256).max);
        IERC20(yesAddr).approve(address(poolManager), type(uint256).max);
        IERC20(yesAddr).approve(address(multiverseMarkets), type(uint256).max);

        IERC20(noAddr).approve(address(hook), type(uint256).max);
        IERC20(noAddr).approve(address(poolManager), type(uint256).max);
        IERC20(noAddr).approve(address(multiverseMarkets), type(uint256).max);
    }

    function test_setUp() public view {
        (,,,,uint256 resYes, uint256 resNo, uint256 resCol) = hook.markets(UNIVERSE_ID);
        assertEq(resCol, INITIAL_LIQUIDITY);
        assertEq(resYes, INITIAL_LIQUIDITY);
        assertEq(resNo, INITIAL_LIQUIDITY);
    }

    function test_marketState() public view {
        (Currency col, Currency yes, Currency no, uint256 funding,,,) = hook.markets(UNIVERSE_ID);
        assertEq(Currency.unwrap(col), address(collateral));
        assertEq(Currency.unwrap(yes), Currency.unwrap(yesCurrency));
        assertEq(Currency.unwrap(no), Currency.unwrap(noCurrency));
        assertEq(funding, FUNDING);
        assertEq(address(hook.multiverseMarket()), address(multiverseMarkets));
    }

    // ── Pricing Invariants ───────────────────────────────────────────────

    function test_marginalPrice_equalReserves() public view {
        assertEq(hook.calcMarginalPrice(UNIVERSE_ID, yesCurrency), 0.5e18);
        assertEq(hook.calcMarginalPrice(UNIVERSE_ID, noCurrency), 0.5e18);
    }

    function test_marginalPrice_sumEqualsOne() public view {
        uint256 sum = hook.calcMarginalPrice(UNIVERSE_ID, yesCurrency) + hook.calcMarginalPrice(UNIVERSE_ID, noCurrency);
        assertApproxEqAbs(sum, 1e18, 1);
    }

    function test_price_increases_after_buying_yes() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);

        uint256 priceBefore = hook.calcMarginalPrice(UNIVERSE_ID, yesCurrency);
        assertEq(priceBefore, 0.5e18);

        swapExactOutput(address(collateral), Currency.unwrap(yesCurrency), 1000e6, type(uint256).max);

        uint256 priceAfter = hook.calcMarginalPrice(UNIVERSE_ID, yesCurrency);
        assertGt(priceAfter, priceBefore);
        assertApproxEqAbs(
            hook.calcMarginalPrice(UNIVERSE_ID, yesCurrency) + hook.calcMarginalPrice(UNIVERSE_ID, noCurrency),
            1e18,
            1
        );
    }

    // ── Swap Validation ────────────────────────────────────────────────

    function test_swap_buy_reverts_when_resolved() public {
        multiverseMarkets.resolve(UNIVERSE_ID, Currency.unwrap(yesCurrency));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(MultiverseHook.MarketResolved.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(address(collateral), Currency.unwrap(yesCurrency), 100e6);
    }

    function test_buy_yes_exactInput_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);
        uint256 collateralToSpend = 50e6;
        uint256 yesBefore = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));

        swap(address(collateral), Currency.unwrap(yesCurrency), collateralToSpend);

        uint256 yesAfter = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colAfter = collateral.balanceOf(address(this));

        uint256 tokensReceived = yesAfter - yesBefore;
        assertGt(tokensReceived, 0, "should receive YES tokens");
        assertEq(colBefore - colAfter, collateralToSpend, "should pay exact collateral");
        assertGt(tokensReceived, collateralToSpend, "tokens > collateral at fair price");
    }

    function test_buy_no_exactInput_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);
        uint256 collateralToSpend = 50e6;
        uint256 noBefore = IERC20(Currency.unwrap(noCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));

        swap(address(collateral), Currency.unwrap(noCurrency), collateralToSpend);

        uint256 noAfter = IERC20(Currency.unwrap(noCurrency)).balanceOf(address(this));
        uint256 colAfter = collateral.balanceOf(address(this));

        uint256 tokensReceived = noAfter - noBefore;
        assertGt(tokensReceived, 0, "should receive NO tokens");
        assertEq(colBefore - colAfter, collateralToSpend, "should pay exact collateral");
    }

    function test_sell_yes_exactOutput_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);

        swapExactOutput(address(collateral), Currency.unwrap(yesCurrency), 200e6, type(uint256).max);

        uint256 collateralWanted = 30e6;
        uint256 yesBefore = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));

        IERC20(Currency.unwrap(yesCurrency)).transfer(address(poolManager), 200e6);

        swapExactOutput(Currency.unwrap(yesCurrency), address(collateral), collateralWanted, type(uint256).max);

        uint256 colAfter = collateral.balanceOf(address(this));
        uint256 yesAfter = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));

        assertEq(colAfter - colBefore, collateralWanted, "should receive exact collateral");
        assertGt(yesBefore - yesAfter, 0, "should spend YES tokens");
    }

    function test_sell_no_exactOutput_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);

        swapExactOutput(address(collateral), Currency.unwrap(noCurrency), 200e6, type(uint256).max);

        uint256 collateralWanted = 30e6;
        uint256 noBefore = IERC20(Currency.unwrap(noCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));

        IERC20(Currency.unwrap(noCurrency)).transfer(address(poolManager), 200e6);

        swapExactOutput(Currency.unwrap(noCurrency), address(collateral), collateralWanted, type(uint256).max);

        uint256 colAfter = collateral.balanceOf(address(this));
        uint256 noAfter = IERC20(Currency.unwrap(noCurrency)).balanceOf(address(this));

        assertEq(colAfter - colBefore, collateralWanted, "should receive exact collateral");
        assertGt(noBefore - noAfter, 0, "should spend NO tokens");
    }

    function test_swap_sell_postResolution_reverts_losingToken() public {
        multiverseMarkets.resolve(UNIVERSE_ID, Currency.unwrap(yesCurrency));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(MultiverseHook.TokenNotWinner.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(Currency.unwrap(noCurrency), address(collateral), 100e6);
    }

    function test_swap_crossOutcome_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(MultiverseHook.CrossUniverseSwapsNotSupportedYet.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(Currency.unwrap(yesCurrency), Currency.unwrap(noCurrency), 100e6);
    }

    // ── Buy ─────────────────────────────────────────────────────────────

    function test_buy_yes_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);
        uint256 deltaYes = 100e6;
        uint256 yesBefore = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));

        swapExactOutput(address(collateral), Currency.unwrap(yesCurrency), deltaYes, type(uint256).max);

        uint256 yesAfter = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colAfter = collateral.balanceOf(address(this));

        assertEq(yesAfter - yesBefore, deltaYes);
        uint256 cost = colBefore - colAfter;
        assertGt(cost, 0);
        assertApproxEqRel(cost, deltaYes / 2, 0.1e18);
        (,,,,uint256 resYes,,) = hook.markets(UNIVERSE_ID);
        assertEq(resYes, (INITIAL_LIQUIDITY+cost) - deltaYes);
    }

    function test_buy_no_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);
        uint256 deltaNO = 100e6;
        uint256 noBefore = IERC20(Currency.unwrap(noCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));

        swapExactOutput(address(collateral), Currency.unwrap(noCurrency), deltaNO, type(uint256).max);

        uint256 noAfter = IERC20(Currency.unwrap(noCurrency)).balanceOf(address(this));
        assertEq(noAfter - noBefore, deltaNO);
        uint256 cost = colBefore - collateral.balanceOf(address(this));
        assertGt(cost, 0);
        (,,,,,uint256 resNo,) = hook.markets(UNIVERSE_ID);
        assertEq(resNo, (INITIAL_LIQUIDITY+cost) - deltaNO);
    }

    function test_sell_yes_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);

        // Buy YES
        uint256 colBefore = collateral.balanceOf(address(this));
        swapExactOutput(address(collateral), Currency.unwrap(yesCurrency), 100e6, type(uint256).max);
        uint256 buyCost = colBefore - collateral.balanceOf(address(this));
        assertGt(buyCost, 0, "Buy: should pay collateral");

        // Sell YES
        uint256 yesBeforeSell = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colBeforeSell = collateral.balanceOf(address(this));
        IERC20(Currency.unwrap(yesCurrency)).transfer(address(poolManager), 50e6);
        swap(Currency.unwrap(yesCurrency), address(collateral), 50e6);

        uint256 yesSpent = yesBeforeSell - IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colGained = collateral.balanceOf(address(this)) - colBeforeSell;
        assertEq(yesSpent, 100e6, "Sell: YES decreased by tokens sold + transferred");
        assertGt(colGained, 0, "Sell: should receive collateral back");

        _assertReserves(
            UNIVERSE_ID,
            (INITIAL_LIQUIDITY + buyCost) - 100e6 - colGained + 50e6,
            (INITIAL_LIQUIDITY + buyCost) - colGained
        );
    }

    function test_sell_no_success() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);

        // Buy NO
        uint256 colBefore = collateral.balanceOf(address(this));
        swapExactOutput(address(collateral), Currency.unwrap(noCurrency), 200e6, type(uint256).max);
        uint256 buyCost = colBefore - collateral.balanceOf(address(this));
        assertGt(buyCost, 0, "Buy: should pay collateral");

        // Sell NO
        uint256 noBeforeSell = IERC20(Currency.unwrap(noCurrency)).balanceOf(address(this));
        uint256 colBeforeSell = collateral.balanceOf(address(this));
        IERC20(Currency.unwrap(noCurrency)).transfer(address(poolManager), 100e6);
        swap(Currency.unwrap(noCurrency), address(collateral), 100e6);

        uint256 noSpent = noBeforeSell - IERC20(Currency.unwrap(noCurrency)).balanceOf(address(this));
        uint256 colGained = collateral.balanceOf(address(this)) - colBeforeSell;
        assertEq(noSpent, 200e6, "Sell: NO decreased by tokens sold + transferred");
        assertGt(colGained, 0, "Sell: should receive collateral back");

        _assertReserves(
            UNIVERSE_ID,
            (INITIAL_LIQUIDITY + buyCost) - colGained,
            (INITIAL_LIQUIDITY + buyCost) - 200e6 - colGained + 100e6
        );
    }

    function test_redeem_exactInput_post_resolution() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);

        swapExactOutput(address(collateral), Currency.unwrap(yesCurrency), 100e6, type(uint256).max);

        multiverseMarkets.resolve(UNIVERSE_ID, Currency.unwrap(yesCurrency));

        uint256 yesToRedeem = 100e6;
        uint256 yesBefore = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));

        IERC20(Currency.unwrap(yesCurrency)).transfer(address(poolManager), yesToRedeem);
        swap(Currency.unwrap(yesCurrency), address(collateral), yesToRedeem);

        assertEq(collateral.balanceOf(address(this)) - colBefore, yesToRedeem, "Redeem: 1:1 collateral");
        assertEq(yesBefore - IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this)), yesToRedeem + yesToRedeem, "Redeem: YES decreased by transferred + settled");
    }

    function test_redeem_exactOutput_post_resolution() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);

        swapExactOutput(address(collateral), Currency.unwrap(yesCurrency), 100e6, type(uint256).max);

        multiverseMarkets.resolve(UNIVERSE_ID, Currency.unwrap(yesCurrency));

        uint256 colToRedeem = 100e6;
        uint256 colBefore = collateral.balanceOf(address(this));

        IERC20(Currency.unwrap(yesCurrency)).transfer(address(poolManager), colToRedeem);

        swapExactOutput(Currency.unwrap(yesCurrency), address(collateral), colToRedeem, type(uint256).max);

        assertEq(collateral.balanceOf(address(this)) - colBefore, colToRedeem, "Redeem: received exact collateral");
    }

    // ── Integration ────────────────────────────────────────────────────

    function test_full_lifecycle() public {
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);

        // 1. Buy 200 YES tokens
        uint256 yesBefore = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        uint256 colBefore = collateral.balanceOf(address(this));
        swapExactOutput(address(collateral), Currency.unwrap(yesCurrency), 200e6, type(uint256).max);
        assertEq(IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this)) - yesBefore, 200e6, "Buy: +200 YES");
        uint256 buyCost = colBefore - collateral.balanceOf(address(this));
        assertGt(buyCost, 0, "Buy: paid collateral");

        // 2. Sell 100 YES back
        uint256 yesBeforeSell = IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this));
        colBefore = collateral.balanceOf(address(this));
        IERC20(Currency.unwrap(yesCurrency)).transfer(address(poolManager), 100e6);
        swap(Currency.unwrap(yesCurrency), address(collateral), 100e6);
        assertEq(yesBeforeSell - IERC20(Currency.unwrap(yesCurrency)).balanceOf(address(this)), 200e6, "Sell: 2x YES consumed");
        uint256 sellProceeds = collateral.balanceOf(address(this)) - colBefore;
        assertGt(sellProceeds, 0, "Sell: received collateral");

        // 3. Resolve: YES wins
        multiverseMarkets.resolve(UNIVERSE_ID, Currency.unwrap(yesCurrency));

        // 4. Redeem 100 YES → 100 collateral (1:1)
        colBefore = collateral.balanceOf(address(this));
        IERC20(Currency.unwrap(yesCurrency)).transfer(address(poolManager), 100e6);
        swap(Currency.unwrap(yesCurrency), address(collateral), 100e6);
        assertEq(collateral.balanceOf(address(this)) - colBefore, 100e6, "Redeem: 1:1 collateral");
    }

    // ── Multi-Market Tests ─────────────────────────────────────────────

    function test_multiMarket_independentPricing() public {
        // Create second market
        collateral.mint(address(this), INITIAL_LIQUIDITY * 10);
        collateral.approve(address(multiverseMarkets), type(uint256).max);
        multiverseMarkets.createMarket(UNIVERSE_ID_2, address(collateral), FUNDING);

        (, address yes2Addr,) = multiverseMarkets.universes(UNIVERSE_ID_2);
        Currency yes2Currency = Currency.wrap(yes2Addr);

        // Approve second market tokens
        IERC20(yes2Addr).approve(address(poolManager), type(uint256).max);

        // Buy YES on universe 1
        collateral.mint(address(poolManager), INITIAL_LIQUIDITY * 10);
        swapExactOutput(address(collateral), Currency.unwrap(yesCurrency), 1000e6, type(uint256).max);

        // Universe 1 price moved
        uint256 price1 = hook.calcMarginalPrice(UNIVERSE_ID, yesCurrency);
        assertGt(price1, 0.5e18, "Universe 1 YES price should increase");

        // Universe 2 price unchanged
        uint256 price2 = hook.calcMarginalPrice(UNIVERSE_ID_2, yes2Currency);
        assertEq(price2, 0.5e18, "Universe 2 YES price should be unchanged");
    }

    function test_multiMarket_duplicateReverts() public {
        vm.expectRevert(abi.encodeWithSelector(MultiverseMarkets.UniverseAlreadyExists.selector, UNIVERSE_ID));
        multiverseMarkets.createMarket(UNIVERSE_ID, address(collateral), FUNDING);
    }

    function test_multiMarket_differentCollateral() public {
        SimpleERC20 collateral2 = new SimpleERC20("Collateral2", "COL2");
        collateral2.mint(address(this), INITIAL_LIQUIDITY * 10);
        collateral2.approve(address(multiverseMarkets), type(uint256).max);

        multiverseMarkets.createMarket(UNIVERSE_ID_2, address(collateral2), FUNDING);

        (address col2Addr,,) = multiverseMarkets.universes(UNIVERSE_ID_2);
        assertEq(col2Addr, address(collateral2));
    }

    function test_onCreateMarket_accessControl() public {
        vm.expectRevert(MultiverseHook.OnlyMultiverseMarket.selector);
        hook.onCreateMarket(UNIVERSE_ID_2, address(collateral), address(0x1), address(0x2), 100);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _assertReserves(bytes32 cid, uint256 expectedYes, uint256 expectedNo) internal view {
        (,,,,uint256 resYes, uint256 resNo,) = hook.markets(cid);
        assertEq(resYes, expectedYes, "YES reserves mismatch");
        assertEq(resNo, expectedNo, "NO reserves mismatch");
    }

    function _makePoolKey(Currency a, Currency b) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
        return PoolKey(c0, c1, 0, 60, IHooks(hook));
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        pendingAction = ACTION_SWAP;
        pendingTokenIn = Currency.wrap(tokenIn);
        pendingTokenOut = Currency.wrap(tokenOut);
        pendingAmountIn = amountIn;
        poolManager.unlock("");
    }

    function swapExactOutput(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxAmountIn) internal {
        pendingAction = ACTION_SWAP_EXACT_OUTPUT;
        pendingTokenIn = Currency.wrap(tokenIn);
        pendingTokenOut = Currency.wrap(tokenOut);
        pendingAmountOut = amountOut;
        pendingMaxAmountIn = maxAmountIn;
        poolManager.unlock("");
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        if (pendingAction == ACTION_SWAP) {
            _executeSwap();
        } else if (pendingAction == ACTION_SWAP_EXACT_OUTPUT) {
            _executeSwapExactOutput();
        }
        return "";
    }

    function _executeSwap() internal {
        PoolKey memory key = _makePoolKey(pendingTokenIn, pendingTokenOut);
        bool zeroForOne = pendingTokenIn < pendingTokenOut;

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(pendingAmountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = poolManager.swap(key, params, "");

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) {
            key.currency0.settle(poolManager, address(this), uint128(-delta0), false);
        } else if (delta0 > 0) {
            key.currency0.take(poolManager, address(this), uint128(delta0), false);
        }

        if (delta1 < 0) {
            key.currency1.settle(poolManager, address(this), uint128(-delta1), false);
        } else if (delta1 > 0) {
            key.currency1.take(poolManager, address(this), uint128(delta1), false);
        }
    }

    function _executeSwapExactOutput() internal {
        PoolKey memory key = _makePoolKey(pendingTokenIn, pendingTokenOut);
        bool zeroForOne = pendingTokenIn < pendingTokenOut;

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(pendingAmountOut),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = poolManager.swap(key, params, "");

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) {
            key.currency0.settle(poolManager, address(this), uint128(-delta0), false);
        } else if (delta0 > 0) {
            key.currency0.take(poolManager, address(this), uint128(delta0), false);
        }

        if (delta1 < 0) {
            key.currency1.settle(poolManager, address(this), uint128(-delta1), false);
        } else if (delta1 > 0) {
            key.currency1.take(poolManager, address(this), uint128(delta1), false);
        }
    }
}
