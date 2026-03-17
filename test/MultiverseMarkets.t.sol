// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {MultiverseMarkets} from "../src/MultiverseMarkets.sol";
import {IMarketHook} from "../src/IMarketHook.sol";
import {MultiverseToken} from "../src/MultiverseToken.sol";
import {SimpleERC20} from "../src/SimpleERC20.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract MultiverseMarketsTest is Test {
    MultiverseMarkets cm;
    SimpleERC20 collateral;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 universeId = keccak256("condition-1");
    bytes32 universeId2 = keccak256("condition-2");

    // Mock poolManager for constructor
    address mockPoolManager = makeAddr("poolManager");
    address mockHook = makeAddr("hook");

    function setUp() public {
        // Mock poolManager.initialize to succeed (returns tick 0)
        vm.mockCall(mockPoolManager, abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(int24(0)));

        cm = new MultiverseMarkets(IPoolManager(mockPoolManager));
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

    function _createUniverseViaMarket(bytes32 _universeId) internal returns (address yesToken, address noToken) {
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
        cm.createMarket(_universeId, address(collateral), amount);
        (,address y, address n) = cm.universes(_universeId);
        return (y, n);
    }

    function _createUniverse() internal returns (address yesToken, address noToken) {
        return _createUniverseViaMarket(universeId);
    }

    function _createUniverse2() internal returns (address yesToken, address noToken) {
        return _createUniverseViaMarket(universeId2);
    }

    // Need to set up split/merge for tests that use them directly
    function _setupForSplitMerge() internal {
        _createUniverse();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Universe Creation (via createMarket)
    // ═══════════════════════════════════════════════════════════════════

    function test_createMarket_storesStruct() public {
        _createUniverse();
        (address col, address yes, address no) = cm.universes(universeId);
        assertEq(col, address(collateral));
        assertTrue(yes != address(0));
        assertTrue(no != address(0));
        assertTrue(yes != no);
    }

    function test_createMarket_tokenNamesEncodeUniverseId() public {
        (address yes, address no) = _createUniverse();
        string memory hexId = _bytes32ToHex(universeId);
        assertEq(ERC20(yes).name(), string.concat("YES-", hexId));
        assertEq(ERC20(no).name(), string.concat("NO-", hexId));
    }

    function test_createMarket_tokenSymbols() public {
        (address yes, address no) = _createUniverse();
        assertEq(ERC20(yes).symbol(), "YES");
        assertEq(ERC20(no).symbol(), "NO");
    }

    function test_createMarket_tokenDecimals() public {
        (address yes, address no) = _createUniverse();
        assertEq(ERC20(yes).decimals(), 6);
        assertEq(ERC20(no).decimals(), 6);
    }

    function test_createMarket_tokenOwnerIsMultiverseMarkets() public {
        (address yes, address no) = _createUniverse();
        assertEq(MultiverseToken(yes).owner(), address(cm));
        assertEq(MultiverseToken(no).owner(), address(cm));
    }

    function test_createMarket_reverseMappingsSet() public {
        (address yes, address no) = _createUniverse();
        assertEq(cm.tokenUniverse(yes), universeId);
        assertEq(cm.tokenUniverse(no), universeId);
    }

    function test_createMarket_emitsEvent() public {
        if (!cm.hookSet()) {
            vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
            cm.setHook(IMarketHook(mockHook));
        }
        collateral.mint(address(this), 100e6);
        collateral.approve(address(cm), 100e6);

        vm.expectEmit(true, false, false, false);
        emit MultiverseMarkets.UniverseCreated(universeId, address(0), address(0), address(0), address(0));
        cm.createMarket(universeId, address(collateral), 100e6);
    }

    function test_createMarket_duplicateReverts() public {
        _createUniverse();
        collateral.mint(address(this), 100e6);
        collateral.approve(address(cm), 100e6);
        vm.expectRevert(abi.encodeWithSelector(MultiverseMarkets.UniverseAlreadyExists.selector, universeId));
        cm.createMarket(universeId, address(collateral), 100e6);
    }

    function test_createMarket_multipleIndependent() public {
        (address yes1,) = _createUniverse();
        (address yes2,) = _createUniverse2();
        assertTrue(yes1 != yes2);
    }

    function test_createMarket_hookNotSetReverts() public {
        MultiverseMarkets cm2 = new MultiverseMarkets(IPoolManager(mockPoolManager));
        vm.expectRevert(MultiverseMarkets.HookNotSet.selector);
        cm2.createMarket(universeId, address(collateral), 100e6);
    }

    function test_setHook_doubleSetReverts() public {
        MultiverseMarkets cm2 = new MultiverseMarkets(IPoolManager(mockPoolManager));
        cm2.setHook(IMarketHook(mockHook));
        vm.expectRevert(MultiverseMarkets.HookAlreadySet.selector);
        cm2.setHook(IMarketHook(mockHook));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Split
    // ═══════════════════════════════════════════════════════════════════

    function test_split_mintsTokensAndLocksCollateral() public {
        (address yes, address no) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);

        assertEq(ERC20(yes).balanceOf(alice), 100e6);
        assertEq(ERC20(no).balanceOf(alice), 100e6);
        assertEq(collateral.balanceOf(alice), 10_000e6 - 100e6);
    }

    function test_split_incrementsCollateralBalances() public {
        _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        assertEq(cm.collateralBalances(universeId, address(collateral)), 100e6);
    }

    function test_split_emitsEvent() public {
        _createUniverse();
        vm.expectEmit(true, true, false, true);
        emit MultiverseMarkets.Split(universeId, alice, 100e6);
        vm.prank(alice);
        cm.split(universeId, 100e6);
    }

    function test_split_zeroAmountIsNoop() public {
        _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 0);
        assertEq(collateral.balanceOf(alice), 10_000e6);
    }

    function test_split_insufficientCollateralReverts() public {
        _createUniverse();
        vm.prank(alice);
        vm.expectRevert();
        cm.split(universeId, 20_000e6);
    }

    function test_split_noApprovalReverts() public {
        _createUniverse();
        address charlie = makeAddr("charlie");
        collateral.mint(charlie, 1000e6);
        vm.prank(charlie);
        vm.expectRevert();
        cm.split(universeId, 100e6);
    }

    function test_split_afterResolutionReverts() public {
        (address yes,) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        cm.resolve(universeId, yes);

        vm.expectRevert(MultiverseMarkets.UniverseAlreadyResolved.selector);
        vm.prank(alice);
        cm.split(universeId, 50e6);
    }

    function test_split_multipleAccumulate() public {
        _createUniverse();
        vm.startPrank(alice);
        cm.split(universeId, 100e6);
        cm.split(universeId, 200e6);
        vm.stopPrank();
        assertEq(cm.collateralBalances(universeId, address(collateral)), 300e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Merge
    // ═══════════════════════════════════════════════════════════════════

    function test_merge_burnsTokensAndReturnsCollateral() public {
        (address yes, address no) = _createUniverse();
        vm.startPrank(alice);
        cm.split(universeId, 100e6);
        cm.merge(universeId, 60e6);
        vm.stopPrank();

        assertEq(ERC20(yes).balanceOf(alice), 40e6);
        assertEq(ERC20(no).balanceOf(alice), 40e6);
        assertEq(collateral.balanceOf(alice), 10_000e6 - 40e6);
    }

    function test_merge_decrementsCollateralBalances() public {
        _createUniverse();
        vm.startPrank(alice);
        cm.split(universeId, 100e6);
        cm.merge(universeId, 30e6);
        vm.stopPrank();
        assertEq(cm.collateralBalances(universeId, address(collateral)), 70e6);
    }

    function test_merge_emitsEvent() public {
        _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);

        vm.expectEmit(true, true, false, true);
        emit MultiverseMarkets.Merged(universeId, alice, 60e6);
        vm.prank(alice);
        cm.merge(universeId, 60e6);
    }

    function test_merge_zeroAmountIsNoop() public {
        _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        vm.prank(alice);
        cm.merge(universeId, 0);
        assertEq(cm.collateralBalances(universeId, address(collateral)), 100e6);
    }

    function test_merge_insufficientTokensReverts() public {
        _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);

        vm.prank(alice);
        vm.expectRevert();
        cm.merge(universeId, 200e6);
    }

    function test_merge_afterResolutionReverts() public {
        (address yes,) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        cm.resolve(universeId, yes);

        vm.expectRevert(MultiverseMarkets.UniverseAlreadyResolved.selector);
        vm.prank(alice);
        cm.merge(universeId, 50e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Resolve
    // ═══════════════════════════════════════════════════════════════════

    function test_resolve_withYesWinner() public {
        (address yes,) = _createUniverse();
        cm.resolve(universeId, yes);
        assertEq(cm.resolved(universeId), yes);
    }

    function test_resolve_withNoWinner() public {
        (, address no) = _createUniverse();
        cm.resolve(universeId, no);
        assertEq(cm.resolved(universeId), no);
    }

    function test_resolve_emitsEvent() public {
        (address yes,) = _createUniverse();
        vm.expectEmit(true, true, false, false);
        emit MultiverseMarkets.Resolved(universeId, yes);
        cm.resolve(universeId, yes);
    }

    function test_resolve_invalidWinnerReverts() public {
        _createUniverse();
        vm.expectRevert(abi.encodeWithSelector(MultiverseMarkets.InvalidWinner.selector, address(0xdead)));
        cm.resolve(universeId, address(0xdead));
    }

    function test_resolve_doubleResolveReverts() public {
        (address yes,) = _createUniverse();
        cm.resolve(universeId, yes);
        vm.expectRevert(MultiverseMarkets.UniverseAlreadyResolved.selector);
        cm.resolve(universeId, yes);
    }

    function test_resolve_nonCreatorReverts() public {
        (address yes,) = _createUniverse();
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(MultiverseMarkets.NotCreatorOrAdmin.selector);
        cm.resolve(universeId, yes);
    }

    function test_resolve_creatorSucceeds() public {
        // alice creates the market, alice resolves
        if (!cm.hookSet()) {
            vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
            cm.setHook(IMarketHook(mockHook));
        }
        collateral.mint(alice, 100e6);
        vm.startPrank(alice);
        collateral.approve(address(cm), 100e6);
        cm.createMarket(universeId, address(collateral), 100e6);
        (, address yes,) = cm.universes(universeId);
        cm.resolve(universeId, yes);
        vm.stopPrank();
        assertEq(cm.resolved(universeId), yes);
    }

    function test_resolve_adminCanResolve() public {
        // alice creates, admin (address(this) = deployer) resolves
        if (!cm.hookSet()) {
            vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
            cm.setHook(IMarketHook(mockHook));
        }
        collateral.mint(alice, 100e6);
        vm.startPrank(alice);
        collateral.approve(address(cm), 100e6);
        cm.createMarket(universeId, address(collateral), 100e6);
        vm.stopPrank();
        (, address yes,) = cm.universes(universeId);
        // address(this) is admin (deployed cm)
        cm.resolve(universeId, yes);
        assertEq(cm.resolved(universeId), yes);
    }

    function test_resolve_nonCreatorNonAdminReverts() public {
        // alice creates, bob resolves → reverts
        if (!cm.hookSet()) {
            vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
            cm.setHook(IMarketHook(mockHook));
        }
        collateral.mint(alice, 100e6);
        vm.startPrank(alice);
        collateral.approve(address(cm), 100e6);
        cm.createMarket(universeId, address(collateral), 100e6);
        vm.stopPrank();
        (, address yes,) = cm.universes(universeId);
        vm.prank(bob);
        vm.expectRevert(MultiverseMarkets.NotCreatorOrAdmin.selector);
        cm.resolve(universeId, yes);
    }

    function test_createMarket_storesCreator() public {
        _createUniverse();
        assertEq(cm.creatorOf(universeId), address(this));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Redeem
    // ═══════════════════════════════════════════════════════════════════

    function test_redeem_burnsWinningTokensAndReturnsCollateral() public {
        (address yes,) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        cm.resolve(universeId, yes);

        vm.prank(alice);
        cm.redeem(yes, 100e6);

        assertEq(ERC20(yes).balanceOf(alice), 0);
        assertEq(collateral.balanceOf(alice), 10_000e6);
    }

    function test_redeem_emitsEvent() public {
        (address yes,) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        cm.resolve(universeId, yes);

        vm.expectEmit(true, true, true, true);
        emit MultiverseMarkets.Redeemed(universeId, alice, yes, 100e6);
        vm.prank(alice);
        cm.redeem(yes, 100e6);
    }

    function test_redeem_zeroAmountReverts() public {
        (address yes,) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        cm.resolve(universeId, yes);

        vm.expectRevert(MultiverseMarkets.ZeroAmount.selector);
        vm.prank(alice);
        cm.redeem(yes, 0);
    }

    function test_redeem_unresolvedReverts() public {
        (address yes,) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);

        vm.expectRevert(abi.encodeWithSelector(MultiverseMarkets.UniverseNotResolved.selector, universeId));
        vm.prank(alice);
        cm.redeem(yes, 100e6);
    }

    function test_redeem_losingTokenReverts() public {
        (address yes, address no) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        cm.resolve(universeId, yes);

        vm.expectRevert(abi.encodeWithSelector(MultiverseMarkets.TokenNotWinner.selector, no));
        vm.prank(alice);
        cm.redeem(no, 100e6);
    }

    function test_redeem_unknownTokenReverts() public {
        _createUniverse();
        vm.expectRevert(abi.encodeWithSelector(MultiverseMarkets.UnknownToken.selector, address(0xbeef)));
        cm.redeem(address(0xbeef), 100e6);
    }

    function test_redeem_insufficientBalanceReverts() public {
        (address yes,) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        cm.resolve(universeId, yes);

        vm.expectRevert(abi.encodeWithSelector(MultiverseMarkets.InsufficientBalance.selector, yes, 200e6, 100e6));
        vm.prank(alice);
        cm.redeem(yes, 200e6);
    }

    function test_redeem_partial() public {
        (address yes,) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        cm.resolve(universeId, yes);

        vm.prank(alice);
        cm.redeem(yes, 40e6);

        assertEq(ERC20(yes).balanceOf(alice), 60e6);
        assertEq(collateral.balanceOf(alice), 10_000e6 - 60e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Integration / Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    function test_lifecycle_splitResolveRedeem() public {
        (address yes,) = _createUniverse();

        vm.prank(alice);
        cm.split(universeId, 500e6);

        cm.resolve(universeId, yes);

        vm.prank(alice);
        cm.redeem(yes, 500e6);

        assertEq(collateral.balanceOf(alice), 10_000e6);
        assertEq(cm.collateralBalances(universeId, address(collateral)), 0);
    }

    function test_lifecycle_splitPartialMergeResolveRedeem() public {
        (address yes, address no) = _createUniverse();

        vm.startPrank(alice);
        cm.split(universeId, 100e6);
        cm.merge(universeId, 30e6);
        vm.stopPrank();

        cm.resolve(universeId, yes);

        vm.prank(alice);
        cm.redeem(yes, 70e6);

        assertEq(collateral.balanceOf(alice), 10_000e6);
        assertEq(ERC20(yes).balanceOf(alice), 0);
        assertEq(ERC20(no).balanceOf(alice), 70e6); // losing tokens remain
    }

    function test_lifecycle_transferAndRedeem() public {
        (address yes,) = _createUniverse();

        vm.prank(alice);
        cm.split(universeId, 100e6);

        vm.prank(alice);
        ERC20(yes).transfer(bob, 60e6);

        cm.resolve(universeId, yes);

        vm.prank(alice);
        cm.redeem(yes, 40e6);
        assertEq(collateral.balanceOf(alice), 10_000e6 - 100e6 + 40e6);

        vm.prank(bob);
        cm.redeem(yes, 60e6);
        assertEq(collateral.balanceOf(bob), 10_000e6 + 60e6);
    }

    function test_lifecycle_splitFullMergeZeroResidual() public {
        (address yes, address no) = _createUniverse();

        vm.startPrank(alice);
        cm.split(universeId, 100e6);
        cm.merge(universeId, 100e6);
        vm.stopPrank();

        assertEq(ERC20(yes).balanceOf(alice), 0);
        assertEq(ERC20(no).balanceOf(alice), 0);
        assertEq(collateral.balanceOf(alice), 10_000e6);
        assertEq(cm.collateralBalances(universeId, address(collateral)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Invariants
    // ═══════════════════════════════════════════════════════════════════

    function test_invariant_yesNoSupplyEqualAfterSplit() public {
        (address yes, address no) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        vm.prank(bob);
        cm.split(universeId, 200e6);
        assertEq(ERC20(yes).totalSupply(), ERC20(no).totalSupply());
    }

    function test_invariant_yesNoSupplyEqualAfterMerge() public {
        (address yes, address no) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        vm.prank(alice);
        cm.merge(universeId, 30e6);
        assertEq(ERC20(yes).totalSupply(), ERC20(no).totalSupply());
    }

    function test_invariant_collateralBalanceEqualsSupply() public {
        (address yes,) = _createUniverse();
        vm.prank(alice);
        cm.split(universeId, 100e6);
        vm.prank(bob);
        cm.split(universeId, 200e6);
        vm.prank(alice);
        cm.merge(universeId, 50e6);

        assertEq(cm.collateralBalances(universeId, address(collateral)), ERC20(yes).totalSupply());
    }

    function test_invariant_contractBalanceGteCollateralBalances() public {
        _createUniverse();
        _createUniverse2();

        vm.startPrank(alice);
        cm.split(universeId, 100e6);
        cm.split(universeId2, 200e6);
        vm.stopPrank();

        uint256 totalTracked = cm.collateralBalances(universeId, address(collateral))
            + cm.collateralBalances(universeId2, address(collateral));
        assertGe(collateral.balanceOf(address(cm)), totalTracked);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Edge Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_edge_zeroUniverseIdReverts() public {
        if (!cm.hookSet()) {
            vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
            cm.setHook(IMarketHook(mockHook));
        }
        vm.expectRevert(MultiverseMarkets.InvalidUniverseId.selector);
        cm.createMarket(bytes32(0), address(collateral), 100e6);
    }

    function test_edge_duplicateUniverseIdReverts() public {
        _createUniverse();
        collateral.mint(address(this), 100e6);
        collateral.approve(address(cm), 100e6);
        vm.expectRevert(abi.encodeWithSelector(MultiverseMarkets.UniverseAlreadyExists.selector, universeId));
        cm.createMarket(universeId, address(collateral), 100e6);
    }

    function test_edge_twoUniversesSameCollateralIndependent() public {
        _createUniverse();
        _createUniverse2();

        vm.startPrank(alice);
        cm.split(universeId, 100e6);
        cm.split(universeId2, 200e6);
        vm.stopPrank();

        assertEq(cm.collateralBalances(universeId, address(collateral)), 100e6);
        assertEq(cm.collateralBalances(universeId2, address(collateral)), 200e6);
    }

    function test_edge_multiverseTokenDirectMintByNonOwnerReverts() public {
        (address yes, address no) = _createUniverse();
        vm.expectRevert();
        MultiverseToken(yes).mint(alice, 100e6);
        vm.expectRevert();
        MultiverseToken(no).burn(alice, 100e6);
    }

    function test_edge_redeemAfterPartialMerge() public {
        (address yes,) = _createUniverse();

        vm.startPrank(alice);
        cm.split(universeId, 100e6);
        cm.merge(universeId, 30e6);
        vm.stopPrank();

        cm.resolve(universeId, yes);

        vm.prank(alice);
        cm.redeem(yes, 70e6);

        assertEq(collateral.balanceOf(alice), 10_000e6);
        assertEq(cm.collateralBalances(universeId, address(collateral)), 0);
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
