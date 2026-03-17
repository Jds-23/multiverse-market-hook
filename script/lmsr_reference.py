#!/usr/bin/env python3
"""Independent LMSR reference oracle using canonical Hanson formulas.

Implements the Logarithmic Market Scoring Rule (LMSR) from first principles:

    C(q) = b · ln(Σᵢ exp(qᵢ / b))          — cost function
    pᵢ(q) = exp(qᵢ / b) / Σⱼ exp(qⱼ / b)  — marginal price
    NetCost(q, Δ) = C(q + Δ) - C(q)         — net cost of trade

CLI: python3 script/lmsr_reference.py <command> <args...>

Commands:
  netcost  balYes balNo dYes dNo funding decimals roundUp  → int256
  price    balYes balNo funding decimals                   → uint256 (WAD)

Output: raw hex (32-byte ABI-encoded), stdout.
"""

import sys
from decimal import Decimal, getcontext, ROUND_DOWN, ROUND_CEILING

getcontext().prec = 50

WAD = Decimal(10**18)
LN2 = Decimal(2).ln()


# ═══════════════════════════════════════════════════════════════════════
# Core LMSR (canonical Hanson formulas, no knowledge of balances/reserves)
# ═══════════════════════════════════════════════════════════════════════

def cost(q: list, b: Decimal) -> Decimal:
    """C(q) = b · ln(Σ exp(qᵢ / b)), computed with log-sum-exp trick."""
    max_q = max(q)
    sum_exp = sum(((qi - max_q) / b).exp() for qi in q)
    return max_q + b * sum_exp.ln()


def marginal_price(q: list, b: Decimal, i: int) -> Decimal:
    """pᵢ = exp(qᵢ / b) / Σ exp(qⱼ / b), computed with log-sum-exp trick."""
    max_q = max(q)
    exps = [((qi - max_q) / b).exp() for qi in q]
    return exps[i] / sum(exps)


def net_cost(q: list, delta: list, b: Decimal) -> Decimal:
    """NetCost(q, Δ) = C(q + Δ) - C(q)."""
    q_after = [qi + di for qi, di in zip(q, delta)]
    return cost(q_after, b) - cost(q, b)


# ═══════════════════════════════════════════════════════════════════════
# CLI layer (balance/reserve conventions, ABI encoding)
# ═══════════════════════════════════════════════════════════════════════

def _b_from_funding(funding: Decimal, decimals: int) -> Decimal:
    """b = funding / ln(2) for a binary market so that C(0,0) = funding."""
    scale = Decimal(10**decimals)
    return (funding / scale) / LN2


def _balances_to_q(bal_yes: int, bal_no: int, funding: int, decimals: int) -> list:
    """Convert reserve balances to shares-outstanding quantities.

    For a binary market funded with `funding` tokens per outcome,
    shares outstanding qᵢ = (funding - balanceᵢ) / scale.
    """
    scale = Decimal(10**decimals)
    q_yes = (Decimal(funding) - Decimal(bal_yes)) / scale
    q_no = (Decimal(funding) - Decimal(bal_no)) / scale
    return [q_yes, q_no]


def cmd_netcost(bal_yes: int, bal_no: int, d_yes: int, d_no: int,
                funding: int, decimals: int, round_up: int) -> str:
    scale = Decimal(10**decimals)
    b = _b_from_funding(Decimal(funding), decimals)
    q = _balances_to_q(bal_yes, bal_no, funding, decimals)
    delta = [Decimal(d_yes) / scale, Decimal(d_no) / scale]

    nc = net_cost(q, delta, b)
    nc_raw = nc * scale

    if round_up and nc_raw > 0:
        nc_int = int(nc_raw.to_integral_value(rounding=ROUND_CEILING))
    else:
        if nc_raw >= 0:
            nc_int = int(nc_raw.to_integral_value(rounding=ROUND_DOWN))
        else:
            nc_int = -int((-nc_raw).to_integral_value(rounding=ROUND_DOWN))

    return _encode_int256(nc_int)


def cmd_price(bal_yes: int, bal_no: int, funding: int, decimals: int) -> str:
    b = _b_from_funding(Decimal(funding), decimals)
    q = _balances_to_q(bal_yes, bal_no, funding, decimals)

    p = marginal_price(q, b, 0)  # price of outcome 0 (YES)
    p_wad = int((p * WAD).to_integral_value(rounding=ROUND_DOWN))
    return _encode_uint256(p_wad)


# ═══════════════════════════════════════════════════════════════════════
# ABI encoding
# ═══════════════════════════════════════════════════════════════════════

def _encode_int256(value: int) -> str:
    raw = value if value >= 0 else value + (1 << 256)
    return "0x" + raw.to_bytes(32, byteorder='big', signed=False).hex()


def _encode_uint256(value: int) -> str:
    return "0x" + value.to_bytes(32, byteorder='big', signed=False).hex()


# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

def main():
    args = sys.argv[1:]
    if not args:
        print("Usage: python3 lmsr_reference.py <command> <args...>", file=sys.stderr)
        sys.exit(1)

    cmd = args[0]

    if cmd == "netcost":
        bal_yes, bal_no, d_yes, d_no, funding, decimals, round_up = (int(x) for x in args[1:8])
        result = cmd_netcost(bal_yes, bal_no, d_yes, d_no, funding, decimals, round_up)
    elif cmd == "price":
        bal_yes, bal_no, funding, decimals = (int(x) for x in args[1:5])
        result = cmd_price(bal_yes, bal_no, funding, decimals)
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

    sys.stdout.write(result)


if __name__ == "__main__":
    main()
