# Witness Key (WK) — The Glass Vault™

![tests](https://github.com/StashBitcoin-coder/okt-tests/actions/workflows/test.yml/badge.svg)
![license](https://img.shields.io/badge/license-MIT-blue)
![solidity](https://img.shields.io/badge/solidity-0.8.20-363636)

A cbBTC-backed token that seals real Bitcoin value inside physical fine-art
pieces and proves their authenticity on-chain. Part of
[Immutable Editions](https://immutableeditions.com).

> Integrity, Witnessed. — see everything, touch nothing, until the seal is broken.

## What it is

Each physical piece carries a Bitcoin wallet (a **vault**) sealed inside the
art. Witness Keys (WK) are minted into that vault, backed 1:1 by **cbBTC**
(1 sat = 1 WK). A 7% **distribution** on every acquire/dispose flows to all
holders. The art can be verified by anyone on-chain via an NFC tap — and the
value is only redeemable by physically destroying the piece to reach the
sealed key.

- **No owner. No admin. No upgrades.** The contract is immutable; it does
  exactly what its code says and no one can intervene.
- **1 Satoshi = 1 WK**, permanently pegged. No AMM, no speculation.
- **acquire / dispose / recirculate / transfer / inscribe** — distribution is
  7% on acquire, dispose, and inscribe; recirculate and transfer are free.
- **Measured receipts** — `acquire()` and `inscribe()` credit the cbBTC that
  actually arrives, not the amount requested.
- **Proof-in-report** — ordinal-moved reports carry the Bitcoin txid, so the
  oracle's claim is independently verifiable on a Bitcoin explorer.

## Security posture

| Check | Result |
|---|---|
| Unit tests | **73 passing** |
| Invariant fuzzing | **3 invariants · 128,000 calls each · 0 reverts** |
| Static analysis (Slither) | **0 vulnerabilities** (only library/style notes) |
| Professional audit | **Exglos** (re-audit of current version in progress) |

The invariants prove real solvency: the contract can always cover a full
"run on the bank," never owes more than it holds, and never drifts beyond
rounding dust — across 128k random operation sequences.

## Deployed (testnet)

- **Network:** Base Sepolia
- **Contract:** `0xc54063714d4Fda87b6ebadCA10110348bc334F37`
- **Verified:** [Blockscout](https://base-sepolia.blockscout.com/address/0xc54063714d4Fda87b6ebadCA10110348bc334F37) · Sourcify

## Run the tests

```bash
forge test          # 73 unit tests + 3 invariant-fuzz suites
slither .           # static analysis
```

## License

MIT © 2026 Michael James Slattery. The Glass Vault™ — patent pending.
