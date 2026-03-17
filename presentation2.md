# The Multiverse Market

### A Uniswap v4 Hook for Conditional Finance

---

## What is Multiverse Finance?

Prediction markets let you bet on outcomes, but so much more is possible.

**Multiverse Finance** splits the financial system into parallel universes — so you can short the market today, only if your favorite candidate is going to lose the next election.

- Each possible outcome creates a **parallel financial universe** with its own token economy
- You don't just bet — you build **conditional positions** that only exist in specific universes
- Prediction markets are a subset; Multiverse Finance is the general framework

> **Notes:** Concept introduced by Dave White — ["Multiverse Finance"](https://www.paradigm.xyz/2025/05/multiverse-finance) (Paradigm, 2025). This project implements it as a Uniswap v4 hook.

---

## Market Creation

A market with **n** outcome conditions requires **<sup>n+1</sup>C<sub>2</sub>** pools — one for every pair among the n condition tokens plus collateral.

```
createMarket(conditionId, collateral, amount)
```

1. **Deploy** YES and NO outcome tokens (ERC-20s named from conditionId)
2. **Fund** — collateral is transferred to the hook, which calls `split()` to mint equal YES + NO tokens as initial reserves
3. **Initialize** <sup>n+1</sup>C<sub>2</sub> pools — for binary, that's **³C₂ = 3 pools:**

| Pool | Purpose |
|---|---|
| Collateral ↔ YES | Buy/sell YES against collateral |
| Collateral ↔ NO | Buy/sell NO against collateral |
| YES ↔ NO | Inter-condition swapping |

> **Notes:** Single-deploy pattern — one hook contract serves every market. 4 contracts (~1000 LOC): Hook, ConditionalMarkets, LMSRMath, OutcomeToken. `tokenToCondition` reverse lookup routes any swap to the right market.

---

## How a Swap Works

Every time a buy of a specific condition happens, **equal amounts of YES + NO are minted** against collateral and added to the supply.

```
User buys YES tokens:
    collateral deposited
    → split() mints EQUAL YES + NO tokens
    → user receives YES tokens
    → hook retains NO tokens (added to supply)
```

The supply changes on every trade. This is fundamentally different from a traditional AMM where reserves are fixed — and it's why we need a unique pricing function.

Selling is the reverse: the hook merges equal YES + NO tokens, burns them, and returns collateral to the user.

The hook handles all of it — buying and selling against collateral, and inter-condition swapping (YES ↔ NO) at zero cost with no collateral movement.

> **Notes:** Split/merge invariant — always mint/burn equal YES + NO. Collateral fully backed in ConditionalMarkets escrow. The hook's internal quantity tracking (`markets[id].quantities`) is what LMSR prices against.

---

## The LMSR

**Hanson's Logarithmic Market Scoring Rule (2003):**

```
C(q) = b · ln( Σ exp(qᵢ / b) )
```

The LMSR gives us the **cost of a state change** in a pool of conditional tokens.

When a buy happens for a certain condition, LMSR decides the cost. That cost is taken as collateral from the user to mint tokens — the user gets back their desired amount of the condition token. Selling is the reverse: LMSR determines how much collateral to return when condition tokens are burned.

- **Prices are marginal costs** = probabilities that always sum to 1
- Buy pressure on YES → YES price rises → NO price falls
- `b` parameter controls liquidity depth — bounded market-maker loss ≤ `b · ln(n)`

> **Notes:** Binary case optimizes to sigmoid pricing with analytical inverse. On-chain: `calcNetCost` (exact-output) + `calcTradeAmountBinary` (exact-input). Log2 decomposition on Solady FixedPointMathLib. FFI cross-verified against Python mpmath.

---

## Resolution — Collapsing the Multiverse

```
resolve(conditionId, winner)
```

When the market is resolved, only the **winning token** is allowed to redeem its value — 1:1 against collateral.

- Losing tokens become worthless — that universe collapsed
- Post-resolution sells auto-upgrade to direct 1:1 redemptions (no LMSR needed)

**Election example:** Your candidate wins. Your YES tokens — bought at $0.60 when the outcome was uncertain — now redeem at $1.00 each. The NO holders? Their universe ceased to exist.

> **Notes:** 145 tests covering full lifecycle. FFI cross-verification against Python mpmath reference oracle (8 scenarios, 1 wei tolerance). Resolution currently owner-gated; oracle integration is next.

---

*"Multiverse Finance" concept by Dave White, [Paradigm (2025)](https://www.paradigm.xyz/2025/05/multiverse-finance)*
