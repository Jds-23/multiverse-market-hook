// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MultiverseToken} from "./MultiverseToken.sol";
import {IMarketHook} from "./IMarketHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Factory + escrow for binary prediction markets.
/// Deploys YES/NO tokens per universe, handles split/merge/redeem lifecycle.
contract MultiverseMarkets {
    // ── Data Model ──────────────────────────────────────────────────────

    struct Universe {
        address collateralToken;
        address yesToken;
        address noToken;
    }

    IPoolManager public immutable poolManager;
    address public immutable admin;

    IMarketHook public hook;
    bool public hookSet;

    mapping(bytes32 => Universe) public universes;
    mapping(bytes32 => mapping(address => uint256)) public collateralBalances;
    mapping(bytes32 => address) public resolved;
    mapping(address => bytes32) public tokenUniverse;
    mapping(bytes32 => address) public creatorOf;

    // ── Errors ──────────────────────────────────────────────────────────

    error InvalidUniverseId();
    error UniverseAlreadyExists(bytes32 universeId);
    error InvalidWinner(address winner);
    error UniverseAlreadyResolved();
    error UniverseNotResolved(bytes32 universeId);
    error TokenNotWinner(address token);
    error UnknownToken(address token);
    error ZeroAmount();
    error InsufficientBalance(address token, uint256 requested, uint256 available);
    error HookAlreadySet();
    error HookNotSet();
    error NotCreatorOrAdmin();

    // ── Events ──────────────────────────────────────────────────────────

    event UniverseCreated(
        bytes32 indexed universeId, address collateralToken, address yesToken, address noToken, address creator
    );
    event Split(bytes32 indexed universeId, address indexed sender, uint256 amount);
    event Merged(bytes32 indexed universeId, address indexed sender, uint256 amount);
    event Resolved(bytes32 indexed universeId, address indexed winner);
    event Redeemed(
        bytes32 indexed universeId, address indexed sender, address indexed token, uint256 amount
    );

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier notResolved(bytes32 universeId) {
        if (resolved[universeId] != address(0)) revert UniverseAlreadyResolved();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        admin = msg.sender;
    }

    // ── External Functions ──────────────────────────────────────────────

    function setHook(IMarketHook _hook) external {
        if (hookSet) revert HookAlreadySet();
        hook = _hook;
        hookSet = true;
    }

    function createMarket(bytes32 universeId, address collateralToken, uint256 amount) external {
        if (!hookSet) revert HookNotSet();
        if (universeId == bytes32(0)) revert InvalidUniverseId();
        if (universes[universeId].collateralToken != address(0)) {
            revert UniverseAlreadyExists(universeId);
        }

        // Deploy YES/NO tokens
        string memory hexId = _bytes32ToHexString(universeId);
        MultiverseToken yesToken = new MultiverseToken(string.concat("YES-", hexId), "YES");
        MultiverseToken noToken = new MultiverseToken(string.concat("NO-", hexId), "NO");

        universes[universeId] = Universe({
            collateralToken: collateralToken,
            yesToken: address(yesToken),
            noToken: address(noToken)
        });

        tokenUniverse[address(yesToken)] = universeId;
        tokenUniverse[address(noToken)] = universeId;
        creatorOf[universeId] = msg.sender;

        emit UniverseCreated(universeId, collateralToken, address(yesToken), address(noToken), msg.sender);

        // Transfer collateral from caller to hook
        SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(hook), amount);

        // Callback: hook splits collateral into YES/NO
        hook.onCreateMarket(universeId, collateralToken, address(yesToken), address(noToken), amount);

        // Initialize 3 pools
        uint160 sqrtPrice1_1 = TickMath.getSqrtPriceAtTick(0);
        poolManager.initialize(_makePoolKey(Currency.wrap(collateralToken), Currency.wrap(address(yesToken))), sqrtPrice1_1);
        poolManager.initialize(_makePoolKey(Currency.wrap(collateralToken), Currency.wrap(address(noToken))), sqrtPrice1_1);
        poolManager.initialize(_makePoolKey(Currency.wrap(address(yesToken)), Currency.wrap(address(noToken))), sqrtPrice1_1);
    }

    function split(bytes32 universeId, uint256 amount) external notResolved(universeId) {
        Universe storage c = universes[universeId];

        SafeTransferLib.safeTransferFrom(c.collateralToken, msg.sender, address(this), amount);
        collateralBalances[universeId][c.collateralToken] += amount;

        MultiverseToken(c.yesToken).mint(msg.sender, amount);
        MultiverseToken(c.noToken).mint(msg.sender, amount);

        emit Split(universeId, msg.sender, amount);
    }

    function merge(bytes32 universeId, uint256 amount) external notResolved(universeId) {
        Universe storage c = universes[universeId];

        MultiverseToken(c.yesToken).burn(msg.sender, amount);
        MultiverseToken(c.noToken).burn(msg.sender, amount);

        collateralBalances[universeId][c.collateralToken] -= amount;
        SafeTransferLib.safeTransfer(c.collateralToken, msg.sender, amount);

        emit Merged(universeId, msg.sender, amount);
    }

    function resolve(bytes32 universeId, address winner) external {
        if (resolved[universeId] != address(0)) revert UniverseAlreadyResolved();
        if (msg.sender != creatorOf[universeId] && msg.sender != admin) revert NotCreatorOrAdmin();

        Universe storage c = universes[universeId];
        if (winner != c.yesToken && winner != c.noToken) revert InvalidWinner(winner);

        resolved[universeId] = winner;

        emit Resolved(universeId, winner);
    }

    function redeem(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        bytes32 universeId = tokenUniverse[token];
        if (universeId == bytes32(0)) revert UnknownToken(token);

        address winner = resolved[universeId];
        if (winner == address(0)) revert UniverseNotResolved(universeId);
        if (token != winner) revert TokenNotWinner(token);

        uint256 balance = ERC20(token).balanceOf(msg.sender);
        if (balance < amount) revert InsufficientBalance(token, amount, balance);

        Universe storage c = universes[universeId];

        MultiverseToken(token).burn(msg.sender, amount);
        collateralBalances[universeId][c.collateralToken] -= amount;
        SafeTransferLib.safeTransfer(c.collateralToken, msg.sender, amount);

        emit Redeemed(universeId, msg.sender, token, amount);
    }

    // ── Internal Helpers ────────────────────────────────────────────────

    function _makePoolKey(Currency a, Currency b) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
        return PoolKey(c0, c1, 0, 60, IHooks(address(hook)));
    }

    function _bytes32ToHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66); // "0x" + 64 hex chars
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }
}
