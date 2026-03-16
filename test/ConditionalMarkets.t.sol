// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ConditionalMarkets} from "../src/ConditionalMarkets.sol";
import {IMarketHook} from "../src/IMarketHook.sol";
import {MultiverseToken} from "../src/MultiverseToken.sol";
import {SimpleERC20} from "../src/SimpleERC20.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract ConditionalMarketsTest is Test {
    ConditionalMarkets cm;
    SimpleERC20 collateral;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 conditionId = keccak256("condition-1");
    bytes32 conditionId2 = keccak256("condition-2");

    // Mock poolManager for constructor
    address mockPoolManager = makeAddr("poolManager");
    address mockHook = makeAddr("hook");

    function setUp() public {
        // Mock poolManager.initialize to succeed (returns tick 0)
        vm.mockCall(mockPoolManager, abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(int24(0)));

        cm = new ConditionalMarkets(IPoolManager(mockPoolManager));
        collateral = new SimpleERC20("USD Coin", "USDC");

        collateral.mint(alice, 10_000e6);
        collateral.mint(bob, 10_000e6);

        vm.prank(alice);
        collateral.approve(address(cm), type(uint256).max);

        vm.prank(bob);
        collateral.approve(address(cm), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _createConditionViaMarket(bytes32 _conditionId) internal returns (address yesToken, address noToken) {
        // Set up a mock hook that does nothing on onCreateMarket
        if (!cm.hookSet()) {
            // Deploy a do-nothing mock for the hook
            vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
            cm.setHook(IMarketHook(mockHook));
        }

        // Transfer collateral to mock hook (createMarket transfers from caller to hook)
        uint256 amount = 100e6;
        collateral.mint(address(this), amount);
        collateral.approve(address(cm), amount);
        cm.createMarket(_conditionId, address(collateral), amount);
        (,address y, address n) = cm.conditions(_conditionId);
        return (y, n);
    }

    function _createCondition() internal returns (address yesToken, address noToken) {
        return _createConditionViaMarket(conditionId);
    }

    function _createCondition2() internal returns (address yesToken, address noToken) {
        return _createConditionViaMarket(conditionId2);
    }

    // Need to set up split/merge for tests that use them directly
    function _setupForSplitMerge() internal {
        _createCondition();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Condition Creation (via createMarket)
    // ═══════════════════════════════════════════════════════════════════

    function test_createMarket_storesStruct() public {
        _createCondition();
        (address col, address yes, address no) = cm.conditions(conditionId);
        assertEq(col, address(collateral));
        assertTrue(yes != address(0));
        assertTrue(no != address(0));
        assertTrue(yes != no);
    }

    function test_createMarket_tokenNamesEncodeConditionId() public {
        (address yes, address no) = _createCondition();
        string memory hexId = _bytes32ToHex(conditionId);
        assertEq(ERC20(yes).name(), string.concat("YES-", hexId));
        assertEq(ERC20(no).name(), string.concat("NO-", hexId));
    }

    function test_createMarket_tokenSymbols() public {
        (address yes, address no) = _createCondition();
        assertEq(ERC20(yes).symbol(), "YES");
        assertEq(ERC20(no).symbol(), "NO");
    }

    function test_createMarket_tokenDecimals() public {
        (address yes, address no) = _createCondition();
        assertEq(ERC20(yes).decimals(), 6);
        assertEq(ERC20(no).decimals(), 6);
    }

    function test_createMarket_tokenOwnerIsConditionalMarkets() public {
        (address yes, address no) = _createCondition();
        assertEq(MultiverseToken(yes).owner(), address(cm));
        assertEq(MultiverseToken(no).owner(), address(cm));
    }

    function test_createMarket_reverseMappingsSet() public {
        (address yes, address no) = _createCondition();
        assertEq(cm.tokenCondition(yes), conditionId);
        assertEq(cm.tokenCondition(no), conditionId);
    }

    function test_createMarket_emitsEvent() public {
        if (!cm.hookSet()) {
            vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
            cm.setHook(IMarketHook(mockHook));
        }
        collateral.mint(address(this), 100e6);
        collateral.approve(address(cm), 100e6);

        vm.expectEmit(true, false, false, false);
        emit ConditionalMarkets.ConditionCreated(conditionId, address(0), address(0), address(0));
        cm.createMarket(conditionId, address(collateral), 100e6);
    }

    function test_createMarket_duplicateReverts() public {
        _createCondition();
        collateral.mint(address(this), 100e6);
        collateral.approve(address(cm), 100e6);
        vm.expectRevert(abi.encodeWithSelector(ConditionalMarkets.ConditionAlreadyExists.selector, conditionId));
        cm.createMarket(conditionId, address(collateral), 100e6);
    }

    function test_createMarket_multipleIndependent() public {
        (address yes1,) = _createCondition();
        (address yes2,) = _createCondition2();
        assertTrue(yes1 != yes2);
    }

    function test_createMarket_hookNotSetReverts() public {
        ConditionalMarkets cm2 = new ConditionalMarkets(IPoolManager(mockPoolManager));
        vm.expectRevert(ConditionalMarkets.HookNotSet.selector);
        cm2.createMarket(conditionId, address(collateral), 100e6);
    }

    function test_setHook_doubleSetReverts() public {
        ConditionalMarkets cm2 = new ConditionalMarkets(IPoolManager(mockPoolManager));
        cm2.setHook(IMarketHook(mockHook));
        vm.expectRevert(ConditionalMarkets.HookAlreadySet.selector);
        cm2.setHook(IMarketHook(mockHook));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Split
    // ═══════════════════════════════════════════════════════════════════

    function test_split_mintsTokensAndLocksCollateral() public {
        (address yes, address no) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);

        assertEq(ERC20(yes).balanceOf(alice), 100e6);
        assertEq(ERC20(no).balanceOf(alice), 100e6);
        assertEq(collateral.balanceOf(alice), 10_000e6 - 100e6);
    }

    function test_split_incrementsCollateralBalances() public {
        _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        assertEq(cm.collateralBalances(conditionId, address(collateral)), 100e6);
    }

    function test_split_emitsEvent() public {
        _createCondition();
        vm.expectEmit(true, true, false, true);
        emit ConditionalMarkets.Split(conditionId, alice, 100e6);
        vm.prank(alice);
        cm.split(conditionId, 100e6);
    }

    function test_split_zeroAmountIsNoop() public {
        _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 0);
        assertEq(collateral.balanceOf(alice), 10_000e6);
    }

    function test_split_insufficientCollateralReverts() public {
        _createCondition();
        vm.prank(alice);
        vm.expectRevert();
        cm.split(conditionId, 20_000e6);
    }

    function test_split_noApprovalReverts() public {
        _createCondition();
        address charlie = makeAddr("charlie");
        collateral.mint(charlie, 1000e6);
        vm.prank(charlie);
        vm.expectRevert();
        cm.split(conditionId, 100e6);
    }

    function test_split_afterResolutionReverts() public {
        (address yes,) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        cm.resolve(conditionId, yes);

        vm.expectRevert(ConditionalMarkets.ConditionAlreadyResolved.selector);
        vm.prank(alice);
        cm.split(conditionId, 50e6);
    }

    function test_split_multipleAccumulate() public {
        _createCondition();
        vm.startPrank(alice);
        cm.split(conditionId, 100e6);
        cm.split(conditionId, 200e6);
        vm.stopPrank();
        assertEq(cm.collateralBalances(conditionId, address(collateral)), 300e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Merge
    // ═══════════════════════════════════════════════════════════════════

    function test_merge_burnsTokensAndReturnsCollateral() public {
        (address yes, address no) = _createCondition();
        vm.startPrank(alice);
        cm.split(conditionId, 100e6);
        cm.merge(conditionId, 60e6);
        vm.stopPrank();

        assertEq(ERC20(yes).balanceOf(alice), 40e6);
        assertEq(ERC20(no).balanceOf(alice), 40e6);
        assertEq(collateral.balanceOf(alice), 10_000e6 - 40e6);
    }

    function test_merge_decrementsCollateralBalances() public {
        _createCondition();
        vm.startPrank(alice);
        cm.split(conditionId, 100e6);
        cm.merge(conditionId, 30e6);
        vm.stopPrank();
        assertEq(cm.collateralBalances(conditionId, address(collateral)), 70e6);
    }

    function test_merge_emitsEvent() public {
        _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);

        vm.expectEmit(true, true, false, true);
        emit ConditionalMarkets.Merged(conditionId, alice, 60e6);
        vm.prank(alice);
        cm.merge(conditionId, 60e6);
    }

    function test_merge_zeroAmountIsNoop() public {
        _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        vm.prank(alice);
        cm.merge(conditionId, 0);
        assertEq(cm.collateralBalances(conditionId, address(collateral)), 100e6);
    }

    function test_merge_insufficientTokensReverts() public {
        _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);

        vm.prank(alice);
        vm.expectRevert();
        cm.merge(conditionId, 200e6);
    }

    function test_merge_afterResolutionReverts() public {
        (address yes,) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        cm.resolve(conditionId, yes);

        vm.expectRevert(ConditionalMarkets.ConditionAlreadyResolved.selector);
        vm.prank(alice);
        cm.merge(conditionId, 50e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Resolve
    // ═══════════════════════════════════════════════════════════════════

    function test_resolve_withYesWinner() public {
        (address yes,) = _createCondition();
        cm.resolve(conditionId, yes);
        assertEq(cm.resolved(conditionId), yes);
    }

    function test_resolve_withNoWinner() public {
        (, address no) = _createCondition();
        cm.resolve(conditionId, no);
        assertEq(cm.resolved(conditionId), no);
    }

    function test_resolve_emitsEvent() public {
        (address yes,) = _createCondition();
        vm.expectEmit(true, true, false, false);
        emit ConditionalMarkets.Resolved(conditionId, yes);
        cm.resolve(conditionId, yes);
    }

    function test_resolve_invalidWinnerReverts() public {
        _createCondition();
        vm.expectRevert(abi.encodeWithSelector(ConditionalMarkets.InvalidWinner.selector, address(0xdead)));
        cm.resolve(conditionId, address(0xdead));
    }

    function test_resolve_doubleResolveReverts() public {
        (address yes,) = _createCondition();
        cm.resolve(conditionId, yes);
        vm.expectRevert(ConditionalMarkets.ConditionAlreadyResolved.selector);
        cm.resolve(conditionId, yes);
    }

    function test_resolve_permissionless() public {
        (address yes,) = _createCondition();
        address random = makeAddr("random");
        vm.prank(random);
        cm.resolve(conditionId, yes);
        assertEq(cm.resolved(conditionId), yes);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Redeem
    // ═══════════════════════════════════════════════════════════════════

    function test_redeem_burnsWinningTokensAndReturnsCollateral() public {
        (address yes,) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        cm.resolve(conditionId, yes);

        vm.prank(alice);
        cm.redeem(yes, 100e6);

        assertEq(ERC20(yes).balanceOf(alice), 0);
        assertEq(collateral.balanceOf(alice), 10_000e6);
    }

    function test_redeem_emitsEvent() public {
        (address yes,) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        cm.resolve(conditionId, yes);

        vm.expectEmit(true, true, true, true);
        emit ConditionalMarkets.Redeemed(conditionId, alice, yes, 100e6);
        vm.prank(alice);
        cm.redeem(yes, 100e6);
    }

    function test_redeem_zeroAmountReverts() public {
        (address yes,) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        cm.resolve(conditionId, yes);

        vm.expectRevert(ConditionalMarkets.ZeroAmount.selector);
        vm.prank(alice);
        cm.redeem(yes, 0);
    }

    function test_redeem_unresolvedReverts() public {
        (address yes,) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);

        vm.expectRevert(abi.encodeWithSelector(ConditionalMarkets.ConditionNotResolved.selector, conditionId));
        vm.prank(alice);
        cm.redeem(yes, 100e6);
    }

    function test_redeem_losingTokenReverts() public {
        (address yes, address no) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        cm.resolve(conditionId, yes);

        vm.expectRevert(abi.encodeWithSelector(ConditionalMarkets.TokenNotWinner.selector, no));
        vm.prank(alice);
        cm.redeem(no, 100e6);
    }

    function test_redeem_unknownTokenReverts() public {
        _createCondition();
        vm.expectRevert(abi.encodeWithSelector(ConditionalMarkets.UnknownToken.selector, address(0xbeef)));
        cm.redeem(address(0xbeef), 100e6);
    }

    function test_redeem_insufficientBalanceReverts() public {
        (address yes,) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        cm.resolve(conditionId, yes);

        vm.expectRevert(abi.encodeWithSelector(ConditionalMarkets.InsufficientBalance.selector, yes, 200e6, 100e6));
        vm.prank(alice);
        cm.redeem(yes, 200e6);
    }

    function test_redeem_partial() public {
        (address yes,) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        cm.resolve(conditionId, yes);

        vm.prank(alice);
        cm.redeem(yes, 40e6);

        assertEq(ERC20(yes).balanceOf(alice), 60e6);
        assertEq(collateral.balanceOf(alice), 10_000e6 - 60e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Integration / Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    function test_lifecycle_splitResolveRedeem() public {
        (address yes,) = _createCondition();

        vm.prank(alice);
        cm.split(conditionId, 500e6);

        cm.resolve(conditionId, yes);

        vm.prank(alice);
        cm.redeem(yes, 500e6);

        assertEq(collateral.balanceOf(alice), 10_000e6);
        assertEq(cm.collateralBalances(conditionId, address(collateral)), 0);
    }

    function test_lifecycle_splitPartialMergeResolveRedeem() public {
        (address yes, address no) = _createCondition();

        vm.startPrank(alice);
        cm.split(conditionId, 100e6);
        cm.merge(conditionId, 30e6);
        vm.stopPrank();

        cm.resolve(conditionId, yes);

        vm.prank(alice);
        cm.redeem(yes, 70e6);

        assertEq(collateral.balanceOf(alice), 10_000e6);
        assertEq(ERC20(yes).balanceOf(alice), 0);
        assertEq(ERC20(no).balanceOf(alice), 70e6); // losing tokens remain
    }

    function test_lifecycle_transferAndRedeem() public {
        (address yes,) = _createCondition();

        vm.prank(alice);
        cm.split(conditionId, 100e6);

        vm.prank(alice);
        ERC20(yes).transfer(bob, 60e6);

        cm.resolve(conditionId, yes);

        vm.prank(alice);
        cm.redeem(yes, 40e6);
        assertEq(collateral.balanceOf(alice), 10_000e6 - 100e6 + 40e6);

        vm.prank(bob);
        cm.redeem(yes, 60e6);
        assertEq(collateral.balanceOf(bob), 10_000e6 + 60e6);
    }

    function test_lifecycle_splitFullMergeZeroResidual() public {
        (address yes, address no) = _createCondition();

        vm.startPrank(alice);
        cm.split(conditionId, 100e6);
        cm.merge(conditionId, 100e6);
        vm.stopPrank();

        assertEq(ERC20(yes).balanceOf(alice), 0);
        assertEq(ERC20(no).balanceOf(alice), 0);
        assertEq(collateral.balanceOf(alice), 10_000e6);
        assertEq(cm.collateralBalances(conditionId, address(collateral)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Invariants
    // ═══════════════════════════════════════════════════════════════════

    function test_invariant_yesNoSupplyEqualAfterSplit() public {
        (address yes, address no) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        vm.prank(bob);
        cm.split(conditionId, 200e6);
        assertEq(ERC20(yes).totalSupply(), ERC20(no).totalSupply());
    }

    function test_invariant_yesNoSupplyEqualAfterMerge() public {
        (address yes, address no) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        vm.prank(alice);
        cm.merge(conditionId, 30e6);
        assertEq(ERC20(yes).totalSupply(), ERC20(no).totalSupply());
    }

    function test_invariant_collateralBalanceEqualsSupply() public {
        (address yes,) = _createCondition();
        vm.prank(alice);
        cm.split(conditionId, 100e6);
        vm.prank(bob);
        cm.split(conditionId, 200e6);
        vm.prank(alice);
        cm.merge(conditionId, 50e6);

        assertEq(cm.collateralBalances(conditionId, address(collateral)), ERC20(yes).totalSupply());
    }

    function test_invariant_contractBalanceGteCollateralBalances() public {
        _createCondition();
        _createCondition2();

        vm.startPrank(alice);
        cm.split(conditionId, 100e6);
        cm.split(conditionId2, 200e6);
        vm.stopPrank();

        uint256 totalTracked = cm.collateralBalances(conditionId, address(collateral))
            + cm.collateralBalances(conditionId2, address(collateral));
        assertGe(collateral.balanceOf(address(cm)), totalTracked);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Edge Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_edge_zeroConditionIdReverts() public {
        if (!cm.hookSet()) {
            vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
            cm.setHook(IMarketHook(mockHook));
        }
        vm.expectRevert(ConditionalMarkets.InvalidConditionId.selector);
        cm.createMarket(bytes32(0), address(collateral), 100e6);
    }

    function test_edge_duplicateConditionIdReverts() public {
        _createCondition();
        collateral.mint(address(this), 100e6);
        collateral.approve(address(cm), 100e6);
        vm.expectRevert(abi.encodeWithSelector(ConditionalMarkets.ConditionAlreadyExists.selector, conditionId));
        cm.createMarket(conditionId, address(collateral), 100e6);
    }

    function test_edge_twoConditionsSameCollateralIndependent() public {
        _createCondition();
        _createCondition2();

        vm.startPrank(alice);
        cm.split(conditionId, 100e6);
        cm.split(conditionId2, 200e6);
        vm.stopPrank();

        assertEq(cm.collateralBalances(conditionId, address(collateral)), 100e6);
        assertEq(cm.collateralBalances(conditionId2, address(collateral)), 200e6);
    }

    function test_edge_outcomeTokenDirectMintByNonOwnerReverts() public {
        (address yes, address no) = _createCondition();
        vm.expectRevert();
        MultiverseToken(yes).mint(alice, 100e6);
        vm.expectRevert();
        MultiverseToken(no).burn(alice, 100e6);
    }

    function test_edge_redeemAfterPartialMerge() public {
        (address yes,) = _createCondition();

        vm.startPrank(alice);
        cm.split(conditionId, 100e6);
        cm.merge(conditionId, 30e6);
        vm.stopPrank();

        cm.resolve(conditionId, yes);

        vm.prank(alice);
        cm.redeem(yes, 70e6);

        assertEq(collateral.balanceOf(alice), 10_000e6);
        assertEq(cm.collateralBalances(conditionId, address(collateral)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Internal test helper
    // ═══════════════════════════════════════════════════════════════════

    function _bytes32ToHex(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }
}
