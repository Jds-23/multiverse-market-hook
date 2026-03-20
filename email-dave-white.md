# Email to Dave White

**Subject:** Built your Multiverse Finance concept as a Uniswap v4 hook

Hey Dave,

I read your Multiverse Finance paper and couldn't stop thinking about it, so I went ahead and built it. The whole thing runs as a Uniswap v4 hook with LMSR pricing baked directly into the swap flow.

The basic idea is that a single hook deployment can serve unlimited binary markets. When someone swaps through v4, `beforeSwap` intercepts it, prices via Hanson's LMSR, and handles the token minting and settlement. No custom routers needed, no separate contracts for each market. Standard Uniswap infrastructure just works.

Each market spins up three pools automatically (collateral against YES, collateral against NO, and YES against NO), and there's a reverse lookup so the hook always knows which market a given swap belongs to. The split/merge mechanics keep everything fully collateralized: every buy mints equal YES and NO tokens, every sell burns them.

For the math, I implemented the LMSR on-chain using log2 decomposition on top of Solady's fixed-point library. To make sure the pricing is actually correct I wrote a Python reference oracle and cross-verified against it through FFI. 145 tests total, 1 wei tolerance on the FFI checks.

It's deployed on Unichain Sepolia and there's a working frontend at multiverse.joydeeeep.com if you want to poke around.

Would genuinely love to hear what you think. The repo is open source.

Best,
[Your name]
