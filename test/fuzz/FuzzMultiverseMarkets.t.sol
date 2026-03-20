// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MultiverseMarkets} from "../../src/MultiverseMarkets.sol";
import {IMarketHook} from "../../src/IMarketHook.sol";
import {SimpleERC20} from "../../src/SimpleERC20.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Fuzz tests for MultiverseMarkets split/merge/redeem
contract FuzzMultiverseMarketsTest is Test {
    MultiverseMarkets cm;
    SimpleERC20 collateral;

    address alice = makeAddr("alice");
    bytes32 universeId = keccak256("fuzz-condition");
    address mockPoolManager = makeAddr("poolManager");
    address mockHook = makeAddr("hook");

    function setUp() public {
        vm.mockCall(mockPoolManager, abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(int24(0)));
        cm = new MultiverseMarkets(IPoolManager(mockPoolManager));
        collateral = new SimpleERC20("USD Coin", "USDC");

        // Setup hook and market
        vm.mockCall(mockHook, abi.encodeWithSelector(IMarketHook.onCreateMarket.selector), "");
        cm.setHook(IMarketHook(mockHook));
        collateral.mint(address(this), 1_000e6);
        collateral.approve(address(cm), 1_000e6);
        cm.createMarket(universeId, address(collateral), 1_000e6);
    }

    function testFuzz_splitMerge_collateralConservation(uint256 splitAmt, uint256 mergeAmt) public {
        // Bound amounts to reasonable range
        splitAmt = bound(splitAmt, 1, 1_000_000e6);
        mergeAmt = bound(mergeAmt, 1, splitAmt);

        collateral.mint(alice, splitAmt);
        vm.startPrank(alice);
        collateral.approve(address(cm), splitAmt);

        uint256 colBefore = collateral.balanceOf(alice);
        cm.split(universeId, splitAmt);
        cm.merge(universeId, mergeAmt);
        vm.stopPrank();

        uint256 colAfter = collateral.balanceOf(alice);
        uint256 remaining = splitAmt - mergeAmt;

        // Collateral conservation: alice should have colBefore - remaining
        assertEq(colAfter, colBefore - remaining, "Collateral not conserved");

        // Token balances should equal remaining
        (, address yes, address no) = cm.universes(universeId);
        assertEq(ERC20(yes).balanceOf(alice), remaining, "YES balance mismatch");
        assertEq(ERC20(no).balanceOf(alice), remaining, "NO balance mismatch");
    }

    function testFuzz_splitMerge_fullRoundTrip(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);

        collateral.mint(alice, amount);
        vm.startPrank(alice);
        collateral.approve(address(cm), amount);

        uint256 colBefore = collateral.balanceOf(alice);
        cm.split(universeId, amount);
        cm.merge(universeId, amount);
        vm.stopPrank();

        // Full round-trip: alice gets all collateral back
        assertEq(collateral.balanceOf(alice), colBefore, "Full round-trip should return all collateral");
    }

    function testFuzz_split_yesNoSupplyEqual(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);

        collateral.mint(alice, amount);
        vm.startPrank(alice);
        collateral.approve(address(cm), amount);
        cm.split(universeId, amount);
        vm.stopPrank();

        (, address yes, address no) = cm.universes(universeId);
        assertEq(ERC20(yes).totalSupply(), ERC20(no).totalSupply(), "YES/NO supply should be equal after split");
    }

    function testFuzz_splitResolveRedeem_fullLifecycle(uint256 amount, bool yesWins) public {
        amount = bound(amount, 1, 1_000_000e6);

        collateral.mint(alice, amount);
        vm.startPrank(alice);
        collateral.approve(address(cm), amount);
        cm.split(universeId, amount);
        vm.stopPrank();

        (, address yes, address no) = cm.universes(universeId);
        address winner = yesWins ? yes : no;

        // Admin resolves
        cm.resolve(universeId, winner);

        // Alice redeems winning tokens
        vm.prank(alice);
        cm.redeem(winner, amount);

        // Alice got all collateral back
        assertEq(collateral.balanceOf(alice), amount, "Should redeem full amount");
        assertEq(ERC20(winner).balanceOf(alice), 0, "Winning tokens should be burned");
    }
}
