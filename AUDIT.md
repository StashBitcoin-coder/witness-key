# OriginKeyToken Audit

Date: 2026-06-14

## Scope

- `src/OriginKeyToken.sol`
- Existing tests were reviewed for intent and coverage, but no contract or test files were changed.

## Tooling

- `forge test`: 75 tests passed, 0 failed, 0 skipped.
- `slither .`: completed with Slither 0.11.5 after installing `slither-analyzer`. Slither reported dependency-level assembly usage in OpenZeppelin, mixed pragma ranges in dependencies, Solidity 0.8.20 version warnings, and one naming-convention warning for `CBBTC`.
- `slither src/OriginKeyToken.sol --foundry-ignore-compile`: completed with the same detector classes and no additional OKT-specific security findings.

The audit findings below are based on manual source review, review of the existing Foundry tests, Foundry test execution, and Slither static analysis.

## Summary

No direct reserve-draining issue was identified in the reviewed source. The buy, sell, withdraw, transfer, and reinvest accounting follows a coherent per-share accumulator model, and the external reserve transfers in `buy`, `sell`, `withdraw`, `reinvest`, and `inscribe` are either protected by `nonReentrant` or contain no external call.

The main risks found are operational and integration risks around immutable privileged roles, the breadth of ordinal invalidation, vault-sweep semantics, and intentional non-standard token behavior.

## Findings

### M-01: Oracle can permanently invalidate unregistered ordinals

`reportOrdinalMoved()` accepts any positive `ordinalNumber`, even if no vault is registered for that ordinal.

- Location: `src/OriginKeyToken.sol:421`
- Registration block: `src/OriginKeyToken.sol:400`

When the oracle reports an unregistered ordinal as moved, `ordinalHasBeenMoved[ordinalNumber]` is permanently set. A later `inscribe()` for that ordinal will revert with `Ordinal: already moved`. Since `ordinalOracle` is immutable, an oracle compromise or operator mistake can permanently block future registration of targeted ordinals without any recovery path.

Recommendation: Require reported ordinals to already be registered if the oracle is only meant to monitor registered vaults. If pre-invalidation of unregistered ordinals is intentional, document that power explicitly and consider an operational process around oracle custody, review, and deployment.

### L-01: The final OKT supply cannot be fully redeemed

`sell()` requires both `tokens >= MIN_SELL` and `totalSupply > tokens`.

- Location: `src/OriginKeyToken.sol:276`

This prevents division-by-zero behavior when distributing the sell fee, but it also means the last token or any residual balance below `MIN_SELL` is permanently non-redeemable through `sell()`. A sole holder can sell down to dust and withdraw dividends, but at least one OKT unit and its backing sat can remain locked.

Recommendation: Treat this as an intentional economic constraint and disclose it clearly. If full redemption is required, the sell path needs a separate final-supply branch.

### L-02: `VaultSwept` does not cover every possible value movement from a vault address

The contract marks a vault as swept when the vault sells OKT, transfers OKT, withdraws dividends, or when the oracle reports its ordinal moved.

- Sweep helper: `src/OriginKeyToken.sol:223`
- Sell hook: `src/OriginKeyToken.sol:281`
- Transfer hook: `src/OriginKeyToken.sol:312`
- Withdraw hook: `src/OriginKeyToken.sol:330`
- Ordinal hook: `src/OriginKeyToken.sol:421`

The contract cannot detect ETH, cbBTC, NFT, or other token movements made directly by the vault address outside this contract. If product copy or downstream systems interpret `VaultSwept` as proof that any value left a vault, that claim is broader than the on-chain enforcement.

Recommendation: Define `VaultSwept` as an OKT-contract-level signal, or pair it with off-chain/indexer monitoring for other assets held by the same vault address.

### I-01: OKT exposes ERC20-like metadata and `transfer`, but not full ERC20 behavior

The contract provides `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `transfer`, and `Transfer`, but intentionally omits `approve`, `allowance`, and `transferFrom`.

- Token surface: `src/OriginKeyToken.sol:118`
- Transfer function: `src/OriginKeyToken.sol:307`

This is tested as intentional behavior, but wallets, explorers, indexers, bridges, and exchanges may partially classify OKT as ERC20 and then fail on allowance-based flows.

Recommendation: Document OKT as a custom non-ERC20 token interface wherever integrations are expected.

### I-02: Reserve accounting assumes canonical, non-rebasing cbBTC behavior

The constructor checks only that the reserve token address is nonzero and reports 8 decimals.

- Location: `src/OriginKeyToken.sol:187`

The accounting assumes exact `safeTransferFrom` and `safeTransfer` amounts, no transfer fees, no rebasing, and no blacklist/freeze behavior that would unexpectedly block reserve exits. This is reasonable for the documented canonical cbBTC deployment, but unsafe for arbitrary 8-decimal ERC20s.

Recommendation: Deploy only with the canonical cbBTC address for the target network and document that substituting another 8-decimal token is unsupported.

## Notes

- The sell path updates balances and payout accounting before distributing the sell fee and before transferring cbBTC out, which matches the stated accounting model.
- `buy`, `sell`, `withdraw`, `reinvest`, and `inscribe` use `nonReentrant`; `transfer` has no external call.
- Direct cbBTC transfers into the contract create surplus backing and do not appear to create extra claimable dividends.
- Fee distribution floors division dust in favor of the contract, not users.

## Verification Addendum

Automated verification was completed after the initial manual audit:

- `forge test`: 75 passed, 0 failed, 0 skipped.
- Invariant coverage included 4 invariant tests with 256 runs and 128,000 handler calls per invariant.
- `slither .`: analyzed 8 contracts with 101 detectors and produced 18 results. The results were informational/noise from OpenZeppelin assembly, dependency pragma ranges, Solidity version warnings, and the `CBBTC` naming convention.
- `slither src/OriginKeyToken.sol --foundry-ignore-compile`: completed with the same detector classes and no additional OKT-specific security findings.

No new exploitable issue was identified by the completed automated verification.
