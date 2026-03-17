# Prediction Markets as Uniswap v4 Hooks

---

## Slide 1: Prediction Markets as Uniswap v4 Hooks

- **Problem:** prediction markets need custom pricing (LMSR), token lifecycle, multi-market — none fit x·y=k
- Existing solutions use separate contracts, fragmented liquidity, incompatible with Uniswap routing
- **This project:** one hook contract turns any v4 pool into a fully functional prediction market
- Polymarket uses a CLOB; this brings prediction markets natively into Uniswap infrastructure

> **Notes:** Judges know hooks — emphasize that this isn't a wrapper, it's a native integration. All swaps flow through the v4 PoolManager, so routers and aggregators work out of the box.

---

## Slide 2: What is LMSR?

- Robin Hanson (2003) invented LMSR — Logarithmic Market Scoring Rule
- Automated market maker for prediction markets: always offers prices, bounded loss
- Cost function: C(q) = b·ln(Σ exp(qᵢ/b)) — prices = marginal costs = probabilities
- Key property: prices always sum to 1, move along sigmoid curve as shares are bought/sold
- Why not x·y=k? AMM prices aren't probabilities, no bounded loss, no outcome token lifecycle

> **Notes:** Hanson was an economist at George Mason. LMSR solved the "thin market" problem — traditional order books need counterparties, LMSR is always willing to trade. The `b` parameter controls liquidity depth and max subsidy (market maker's bounded loss).

---

## Slide 3: Single Deploy, Multi-Market Architecture

- **4 contracts (~1000 LOC):** Hook, ConditionalMarkets, LMSRMath, OutcomeToken
- `markets[conditionId]` mapping + `tokenToCondition` reverse lookup routes all swaps to the right market
- Per condition: **3 pools auto-initialized** (collateral↔YES, collateral↔NO, YES↔NO)
- Factory pattern: `createMarket()` deploys tokens + splits collateral + inits pools in one tx

> **Notes:** Single-deploy pattern is the key architectural insight — no per-market hook deployment. The reverse lookup lets `beforeSwap` identify the market from any incoming token pair.

---

## Slide 4: beforeSwap — Token Splitting & Merging

- `beforeSwap` + `beforeSwapReturnDelta` bypasses x·y=k — hook controls all token deltas
- **Buy (split):** `take` collateral from PM → `split()` mints equal YES+NO to hook → `settle` requested token to user
- **Sell (merge):** `take` outcome tokens from PM → `merge()` burns equal YES+NO, releases collateral → `settle` collateral to user
- Split/merge invariant: always mint/burn equal YES+NO — collateral fully backed in ConditionalMarkets escrow
- All 4 swap modes: buy/sell × exact-input/exact-output, fully router-compatible

> **Notes:** Key insight: hook is the intermediary — PM never touches ConditionalMarkets directly. `split()` mints both tokens but only the requested one goes to user; hook retains the other. `merge()` burns both, so hook must hold matching pairs.

---

## Slide 5: LMSR Pricing — Bounded Loss, Sigmoid Prices

- **Hanson's LMSR:** C(q) = b·ln(Σ exp(qᵢ/b)) — prices are probabilities (0–1, sum to 1)
- Binary optimization: sigmoid pricing, analytical inverse via `calcTradeAmountBinary`
- Two core functions: `calcNetCost` (exact-output) + `calcTradeAmountBinary` (exact-input)
- WAD 1e18 fixed-point arithmetic, log2-based, built on Solady FixedPointMathLib

> **Notes:** Bounded market-maker loss = initial funding amount (b parameter). Offset trick subtracts max(q) before exponentiation for numerical stability. This is the first on-chain LMSR we're aware of using log2 decomposition.

---

## Slide 6: Create → Trade → Resolve → Redeem

- **`createMarket()`** — one tx deploys outcome tokens, seeds initial liquidity, initializes 3 pools
- **Trade** via standard `swap()` — any Uniswap router or aggregator works unmodified
- **`resolve(conditionId, winner)`** locks the market → **`redeem()`** pays winning token holders 1:1
- **145 tests:** unit math, FFI cross-verification against Python arbitrary-precision reference, full lifecycle integration

> **Notes:** FFI test harness shells out to Python mpmath for 8 scenarios, verifying Solidity results within 1 wei tolerance. Lifecycle tests cover creation through redemption end-to-end.

---

## Slide 7: What's Next + Demo

- **Working today:** multi-market creation, all 4 swap directions, resolution, redemption
- **Next:** oracle integration (UMA / Reality.eth), LP fee sharing, multi-outcome markets (N > 2)
- **Novel contribution:** first LMSR prediction market implemented as a Uniswap v4 hook — pattern is reusable for any custom pricing curve

> **Notes:** Demo the full lifecycle in Foundry test output if time allows. The hook pattern generalizes — any pricing function that can express deltas can replace x·y=k through `beforeSwapReturnDelta`.
