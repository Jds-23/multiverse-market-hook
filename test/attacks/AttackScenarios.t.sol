// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MultiverseMarkets} from "../../src/MultiverseMarkets.sol";
import {MultiverseHook} from "../../src/MultiverseHook.sol";
import {IMarketHook} from "../../src/IMarketHook.sol";
import {SimpleERC20} from "../../src/SimpleERC20.sol";
import {MultiverseToken} from "../../src/MultiverseToken.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Attack scenario tests validating all critical/high fixes
contract AttackScenariosTest is Test {
    MultiverseMarkets cm;
    SimpleERC20 collateral;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    bytes32 universeId = keccak256("attack-condition");
    address mockPoolManager = makeAddr("poolManager");
    address mockHook = makeAddr("hook");

    function setUp() public {
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
    // C-1: Front-run setHook — non-admin call reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_attack_frontrunSetHook_reverts() public {
        // Attacker tries to front-run admin's setHook call
        vm.prank(attacker);
        vm.expectRevert(MultiverseMarkets.NotAdmin.selector);
        cm.setHook(IMarketHook(attacker));

        // Admin can still set hook
        cm.setHook(IMarketHook(mockHook));
        assertEq(address(cm.hook()), mockHook);
    }

    // ═══════════════════════════════════════════════════════════════════
    // C-2: Permissionless mint — non-owner call reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_attack_permissionlessMint_reverts() public {
        // Attacker tries to mint collateral tokens
        vm.prank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.mint(attacker, 1_000_000e6);

        // Owner can still mint
        collateral.mint(address(this), 100e6);
        assertEq(collateral.balanceOf(address(this)), 100e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // M-1: Resolution rug — instant finalize reverts, must wait 24h
    // ═══════════════════════════════════════════════════════════════════

    function test_attack_resolutionRug_creatorCannotInstantResolve() public {
        // Setup
        vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
        cm.setHook(IMarketHook(mockHook));

        // Alice creates market
        collateral.mint(alice, 100e6);
        vm.startPrank(alice);
        collateral.approve(address(cm), 100e6);
        cm.createMarket(universeId, address(collateral), 100e6);
        (, address yes,) = cm.universes(universeId);

        // Alice proposes resolution
        cm.proposeResolution(universeId, yes);
        vm.stopPrank();

        // Immediate finalization fails
        vm.expectRevert(MultiverseMarkets.ResolutionNotReady.selector);
        cm.finalizeResolution(universeId);

        // Still fails after 23 hours
        vm.warp(block.timestamp + 23 hours);
        vm.expectRevert(MultiverseMarkets.ResolutionNotReady.selector);
        cm.finalizeResolution(universeId);

        // Succeeds after 24 hours + 1
        vm.warp(block.timestamp + 1 hours + 1);
        cm.finalizeResolution(universeId);
        assertEq(cm.resolved(universeId), yes);
    }

    function test_attack_resolutionRug_cancelDuringDelay() public {
        vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
        cm.setHook(IMarketHook(mockHook));

        collateral.mint(alice, 100e6);
        vm.startPrank(alice);
        collateral.approve(address(cm), 100e6);
        cm.createMarket(universeId, address(collateral), 100e6);
        (, address yes,) = cm.universes(universeId);

        // Propose and then cancel
        cm.proposeResolution(universeId, yes);
        cm.cancelResolution(universeId);
        vm.stopPrank();

        // Cannot finalize cancelled resolution
        vm.warp(block.timestamp + 25 hours);
        vm.expectRevert(MultiverseMarkets.NoResolutionProposed.selector);
        cm.finalizeResolution(universeId);
    }

    function test_attack_resolutionRug_adminCanStillInstantResolve() public {
        vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
        cm.setHook(IMarketHook(mockHook));

        collateral.mint(alice, 100e6);
        vm.startPrank(alice);
        collateral.approve(address(cm), 100e6);
        cm.createMarket(universeId, address(collateral), 100e6);
        vm.stopPrank();

        (, address yes,) = cm.universes(universeId);

        // Admin (address(this)) can still use legacy resolve for emergencies
        cm.resolve(universeId, yes);
        assertEq(cm.resolved(universeId), yes);
    }

    // ═══════════════════════════════════════════════════════════════════
    // L-1: Zero-amount split/merge now revert
    // ═══════════════════════════════════════════════════════════════════

    function test_attack_zeroAmountSplit_reverts() public {
        vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
        cm.setHook(IMarketHook(mockHook));
        collateral.mint(address(this), 100e6);
        collateral.approve(address(cm), 100e6);
        cm.createMarket(universeId, address(collateral), 100e6);

        vm.expectRevert(MultiverseMarkets.ZeroAmount.selector);
        vm.prank(alice);
        cm.split(universeId, 0);
    }

    function test_attack_zeroAmountMerge_reverts() public {
        vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
        cm.setHook(IMarketHook(mockHook));
        collateral.mint(address(this), 100e6);
        collateral.approve(address(cm), 100e6);
        cm.createMarket(universeId, address(collateral), 100e6);

        vm.prank(alice);
        cm.split(universeId, 100e6);

        vm.expectRevert(MultiverseMarkets.ZeroAmount.selector);
        vm.prank(alice);
        cm.merge(universeId, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Donation attack — sending extra tokens to hook should not corrupt reserves
    // ═══════════════════════════════════════════════════════════════════

    function test_attack_donation_doesNotCorruptReserves() public {
        vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
        cm.setHook(IMarketHook(mockHook));

        collateral.mint(address(this), 100e6);
        collateral.approve(address(cm), 100e6);
        cm.createMarket(universeId, address(collateral), 100e6);

        // Attacker donates collateral to the MultiverseMarkets contract
        collateral.mint(attacker, 1_000e6);
        vm.prank(attacker);
        collateral.transfer(address(cm), 1_000e6);

        // collateralBalances tracking should be unaffected
        assertEq(cm.collateralBalances(universeId, address(collateral)), 0);

        // Split still works normally
        vm.prank(alice);
        cm.split(universeId, 50e6);
        assertEq(cm.collateralBalances(universeId, address(collateral)), 50e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Double-propose attack
    // ═══════════════════════════════════════════════════════════════════

    function test_attack_doublePropose_reverts() public {
        vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
        cm.setHook(IMarketHook(mockHook));

        collateral.mint(alice, 100e6);
        vm.startPrank(alice);
        collateral.approve(address(cm), 100e6);
        cm.createMarket(universeId, address(collateral), 100e6);
        (, address yes,) = cm.universes(universeId);

        cm.proposeResolution(universeId, yes);

        vm.expectRevert(MultiverseMarkets.ResolutionPending.selector);
        cm.proposeResolution(universeId, yes);
        vm.stopPrank();
    }
}
