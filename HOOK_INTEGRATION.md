# Hook Integration Guide

Technical reference for integrating with MultiverseHook — an LMSR-based binary prediction market system built on Uniswap v4.

---

## 1. Contracts & Roles

| Contract | Role | Key Detail |
|---|---|---|
| `MultiverseMarkets` | Factory + escrow | Deploys YES/NO tokens, handles split/merge/redeem, manages resolution |
| `MultiverseHook` | Pricing engine | Uniswap v4 `beforeSwap` hook; LMSR-based virtual AMM |
| `MultiverseToken` | Outcome token | Mintable/burnable ERC-20; one per outcome per market |
| `LMSRMath` | Pricing library | Logarithmic Market Scoring Rule math (softmax pricing) |

### Deployment Addresses

| Contract | Address |
|---|---|
| `MultiverseMarkets` | `TBD` |
| `MultiverseHook` | `TBD` |
| Collateral (e.g. USDC) | `TBD` |

---

## 2. Pool Configuration

Each market creates **3 Uniswap v4 pools**:

| Pool | Purpose |
|---|---|
| Collateral ↔ YES | Buy/sell YES tokens |
| Collateral ↔ NO | Buy/sell NO tokens |
| YES ↔ NO | Cross-outcome swaps (not yet supported — reverts with `CrossUniverseSwapsNotSupportedYet`) |

### PoolKey Parameters

```solidity
PoolKey({
    currency0: <lower address>,
    currency1: <higher address>,
    fee: 0,
    tickSpacing: 60,
    hooks: IHooks(hookAddress)
})
```

- **Currency ordering**: `currency0 < currency1` (enforced by Uniswap v4)
- **Initial price**: tick 0 → `sqrtPriceX96 = 79228162514264337593543950336` (1:1)
- **Fee**: 0 — the hook handles all pricing via LMSR
- **Tick spacing**: 60

---

## 3. Swap Integration

All swaps route through the hook's `beforeSwap`. The hook intercepts the swap entirely and returns a `BeforeSwapDelta` — the Uniswap v4 AMM curve is never used.

### Action Classification

| tokenIn | tokenOut | Market State | Action | Code |
|---|---|---|---|---|
| Collateral | YES or NO | Unresolved | **Buy** | `1` |
| YES or NO | Collateral | Unresolved | **Sell** | `2` |
| Winner token | Collateral | Resolved | **Redeem** | `3` |
| Loser token | Collateral | Resolved | Reverts `TokenNotWinner` | — |
| Collateral | YES or NO | Resolved | Reverts `MarketResolved` | — |
| YES | NO (or vice versa) | Any | Reverts `CrossUniverseSwapsNotSupportedYet` | — |

### Swap Modes

Both `exactInput` and `exactOutput` are supported:

| Mode | `amountSpecified` | Behavior |
|---|---|---|
| Exact input (buy) | `> 0` | Specify exact outcome tokens to receive; hook calculates collateral cost |
| Exact output (buy) | `< 0` | Specify exact collateral to spend; hook calculates outcome tokens received |
| Exact input (sell) | `< 0` | Specify exact outcome tokens to sell; hook calculates collateral returned |
| Exact output (sell) | `> 0` | Specify exact collateral to receive; hook calculates outcome tokens needed |

### Buy Example (Exact Input of Collateral)

```solidity
// Buy YES tokens by spending exact collateral
IERC20(collateral).approve(address(swapRouter), amountIn);

PoolKey memory poolKey = PoolKey({
    currency0: Currency.wrap(min(collateral, yesToken)),
    currency1: Currency.wrap(max(collateral, yesToken)),
    fee: 0,
    tickSpacing: 60,
    hooks: IHooks(hookAddress)
});

swapRouter.swapExactTokensForTokens({
    amountIn: amountIn,
    amountOutMin: 0,
    zeroForOne: collateral < yesToken,
    poolKey: poolKey,
    hookData: new bytes(0),
    receiver: msg.sender,
    deadline: block.timestamp + 300
});
```

### Sell Example (Exact Input of Outcome Tokens)

```solidity
// Sell YES tokens back for collateral
IERC20(yesToken).approve(address(swapRouter), amountIn);

swapRouter.swapExactTokensForTokens({
    amountIn: amountIn,
    amountOutMin: 0,
    zeroForOne: yesToken < collateral,
    poolKey: poolKey,
    hookData: new bytes(0),
    receiver: msg.sender,
    deadline: block.timestamp + 300
});
```

### Token Approvals

| Action | Token to Approve | Approve To |
|---|---|---|
| Buy | Collateral | `swapRouter` |
| Sell | Outcome token (YES or NO) | `swapRouter` |
| Redeem (via swap) | Winner token | `swapRouter` |
| Split (direct) | Collateral | `MultiverseMarkets` |

### Notes

- `sqrtPriceLimitX96` is ignored — the hook handles pricing entirely
- `hookData` is unused — pass `new bytes(0)`
- Redeem via swap is 1:1 (winner token → collateral, no LMSR pricing)

---

## 4. Reading Market State

### Hook State

```solidity
// Full market state (reserves + tokens)
(
    Currency collateralToken,
    Currency yesToken,
    Currency noToken,
    uint256 funding,
    uint256 reserveYes,
    uint256 reserveNo,
    uint256 reserveCollateral
) = hook.markets(universeId);

// Marginal price of a token (returns WAD — 1e18 = 100%)
uint256 yesPrice = hook.calcMarginalPrice(universeId, Currency.wrap(yesToken));
// noPrice = 1e18 - yesPrice
```

### MultiverseMarkets State

```solidity
// Token addresses
(address collateral, address yesToken, address noToken) = multiverseMarkets.universes(universeId);

// Resolution status (address(0) = unresolved, otherwise winner token address)
address winner = multiverseMarkets.resolved(universeId);

// Reverse lookups: token address → universeId
bytes32 uid = multiverseMarkets.tokenUniverse(outcomeTokenAddress);  // on MultiverseMarkets
bytes32 uid = hook.tokenToUniverse(outcomeTokenAddress);             // on MultiverseHook

// Market creator
address creator = multiverseMarkets.creatorOf(universeId);
```

---

## 5. Lifecycle Integration

### Create Market

```solidity
bytes32 universeId = keccak256("my-market");
uint256 initialFunding = 1000e6; // 1000 USDC

IERC20(collateral).approve(address(multiverseMarkets), initialFunding);
multiverseMarkets.createMarket(universeId, collateral, initialFunding);
```

**Prereqs**: `setHook()` must have been called. `universeId` must be non-zero and unused.

**What happens**:
1. Deploys YES/NO `MultiverseToken` contracts
2. Transfers collateral from caller → hook
3. Hook calls `split()` to mint initial YES/NO tokens
4. Initializes 3 Uniswap v4 pools at tick 0

### Split (Collateral → YES + NO)

```solidity
IERC20(collateral).approve(address(multiverseMarkets), amount);
multiverseMarkets.split(universeId, amount);
// Caller receives `amount` YES tokens + `amount` NO tokens
```

**Prereqs**: Market must be unresolved.

### Merge (YES + NO → Collateral)

```solidity
// Caller must hold ≥ amount of BOTH YES and NO tokens
multiverseMarkets.merge(universeId, amount);
// Burns `amount` YES + `amount` NO, returns `amount` collateral
```

**Prereqs**: Market must be unresolved. Caller needs both YES and NO tokens.

### Resolve

```solidity
multiverseMarkets.resolve(universeId, winnerTokenAddress);
```

**Access control**: Only the market creator (`creatorOf[universeId]`) or the contract `admin` can resolve.

### Redeem (Winner Token → Collateral)

```solidity
multiverseMarkets.redeem(winnerToken, amount);
// Burns winner tokens, returns equal collateral
```

**Prereqs**: Market must be resolved. Token must be the winner. Can also redeem via a swap through the hook (routed as action `3`).

---

## 6. Error Reference

### MultiverseHook Errors

| Error | When |
|---|---|
| `NotImplementedYet()` | `addLiquidity` or `removeLiquidity` called on a hook pool |
| `UnknownToken()` | Neither swap token belongs to any market |
| `MarketResolved()` | Attempting to buy on a resolved market |
| `InsufficientLiquidity()` | Trade results in zero cost or zero delta |
| `CrossUniverseSwapsNotSupportedYet()` | Swapping YES ↔ NO directly |
| `TokenNotWinner()` | Attempting to redeem a losing token after resolution |
| `OnlyMultiverseMarket()` | `onCreateMarket` called by non-factory address |
| `MarketAlreadyExists()` | `onCreateMarket` called for existing universeId |

### MultiverseMarkets Errors

| Error | When |
|---|---|
| `InvalidUniverseId()` | `createMarket` with `bytes32(0)` |
| `UniverseAlreadyExists(bytes32)` | `createMarket` with existing universeId |
| `InvalidWinner(address)` | `resolve` with address that isn't YES or NO token |
| `UniverseAlreadyResolved()` | `resolve` or `split`/`merge` on already-resolved market |
| `UniverseNotResolved(bytes32)` | `redeem` on unresolved market |
| `TokenNotWinner(address)` | `redeem` with losing token |
| `UnknownToken(address)` | `redeem` with token not in any universe |
| `ZeroAmount()` | `redeem` with amount = 0 |
| `InsufficientBalance(address, uint256, uint256)` | `redeem` when caller balance < amount |
| `HookAlreadySet()` | `setHook` called more than once |
| `HookNotSet()` | `createMarket` before `setHook` |
| `NotCreatorOrAdmin()` | `resolve` by unauthorized caller |

### LMSRMath Errors

| Error | When |
|---|---|
| `InvalidNumOutcomes()` | Fewer than 2 outcomes |
| `ZeroFunding()` | Funding amount is 0 |
| `ArrayLengthMismatch()` | `balances` and `amounts` arrays differ in length |
| `InvalidDecimals()` | Decimals = 0 or > 18 |
| `InvalidOutcomeIndex()` | Outcome index ≥ number of outcomes |
| `InsufficientLiquidity()` | Sell inverse calculation underflows |

---

## 7. Limitations & Gotchas

- **6-decimal collateral hardcoded** — `DECIMALS = 6` constant in `MultiverseHook`. Collateral must be 6-decimal (e.g. USDC, USDT).
- **No standard LPs** — `addLiquidity` and `removeLiquidity` revert with `NotImplementedYet`. All liquidity is virtual via LMSR.
- **No cross-outcome swaps** — YES ↔ NO pool exists but swaps revert. To swap YES→NO, sell YES for collateral then buy NO.
- **`setHook` is one-time** — Cannot change the hook after it's set. Reverts `HookAlreadySet`.
- **Binary markets only** — Each universe has exactly 2 outcomes (YES/NO).
- **Split/merge bypass LMSR** — These are 1:1 operations on `MultiverseMarkets` and don't affect LMSR reserves tracked in the hook. Only swaps update hook reserves.
- **Redeem is 1:1** — After resolution, 1 winner token = 1 collateral. No LMSR pricing applies.
- **Admin is immutable** — Set to deployer in constructor, no transfer function.

---

## 8. Events

All events are emitted by `MultiverseMarkets`:

| Event | Parameters | When |
|---|---|---|
| `UniverseCreated` | `universeId` (indexed), `collateralToken`, `yesToken`, `noToken`, `creator` | New market created |
| `Split` | `universeId` (indexed), `sender` (indexed), `amount` | Collateral split into YES + NO |
| `Merged` | `universeId` (indexed), `sender` (indexed), `amount` | YES + NO merged back to collateral |
| `Resolved` | `universeId` (indexed), `winner` (indexed) | Market resolved to a winner |
| `Redeemed` | `universeId` (indexed), `sender` (indexed), `token` (indexed), `amount` | Winner tokens redeemed for collateral |
