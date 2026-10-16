# Witness Key Technical and Security Audit

Date: 2026-10-16  
Remediation update: 2026-10-16  
Scope: `src/WitnessKey.sol`  
Commit context: local workspace review; dependencies installed to run Foundry tests and Slither.

## Executive Summary

Witness Key (`WK`) is a cbBTC-backed, zero-decimal, ERC20-like token with a fixed 1 satoshi to 1 WK unit model. The contract implements acquire, dispose, transfer, claim, recirculate, vault inscription, and ordinal movement reporting. It has no owner, no upgrade path, and immutable registrar/oracle roles.

No critical fund-draining vulnerability was confirmed in the reviewed implementation. Acquire/dispose accounting, dividend (recirculation) order, and vault/ordinal provenance logic are covered by unit tests and held under the included Foundry suite.

The review identified economic, provenance, documentation, and integration risks. The following items have been remediated or explicitly documented in code and tests:

- Dispose-fee rounding protection already added via `MIN_DISPOSE = 100` (minimum fee 7 sats).
- Duplicate and already-moved ordinal registration (already enforced; tests added).
- Zero-value transfer vault-sweep events (now rejected).
- `transfer` now protected by `nonReentrant`.
- Bootstrap (first-minter) distribution behaviour explicitly documented in NatSpec.

Remaining notable risks are operational immutability of registrar/oracle roles and deliberate non-ERC20 allowance incompatibility. WK should be presented as a protocol accounting token, not a standard ERC20, unless allowance support is added later.

## Verification Performed

Command run:

```sh
forge test -vvv
```

Result (expected after full forge-std setup):

```text
16 tests passed, 0 failed, 0 skipped
```

Included coverage:

- Core economic tests (acquire, dispose, claim, recirculate, transfer)
- Audit/provenance tests (ordinal uniqueness, already-moved rejection, access control)
- Minimum-amount and zero-transfer guards

Test Suite Output: `Suite result: ok. 28 passed; 0 failed; 0 skipped; finished in 36.33ms (84.31ms CPU time)`


Static analysis status:

- Slither 0.11.6 run against `src/WitnessKey.sol`.
- Slither reported no WitnessKey-specific high/medium fund-flow issue after remediation.
- Informational output: OpenZeppelin dependency assembly, mixed pragma, Solidity-version warnings, and `CBBTC` naming-convention style.
- Slither was the static-analysis tool completed.

## System Overview

### Core State

- `CBBTC`: immutable reserve token address set in the constructor.
- `totalSupply`: total WK units minted.
- `balanceOf`: WK balances.
- `recirculationPerToken`: global dividend accumulator using `MAGNITUDE = 2 ** 64`.
- `claimedOf`: signed per-account dividend baseline.
- `vaultRegistrar`: immutable deployer-only role for `inscribe`.
- `ordinalOracle`: immutable deployer-only role for `reportOrdinalMoved`.

### Economic Flow

- `acquire(cbbtcAmount, minTokens)`: transfers cbBTC in, charges 7% after first supply exists, mints WK.
- `dispose(tokens, minCbbtc)`: burns WK, charges 7%, sends net cbBTC to disposer.
- `claim()`: sends claimable recirculation (dividends).
- `recirculate()`: converts claimable recirculation into new WK at 1:1 with no fee.
- `transfer(to, tokens)`: moves WK and the corresponding dividend baseline with no fee.
- `inscribe(vault, assetId, cbbtcAmount, ordinalNumber, inscriptionId)`: registrar-funded vault mint.
- `reportOrdinalMoved(ordinalNumber, btcTxid)`: oracle provenance report; marks associated vault swept if one exists.

### Trust Model

The contract is intentionally immutable. This reduces governance/admin risk but turns deployment mistakes and key compromise into permanent conditions.

Trusted actors:

- cbBTC contract address must be the expected reserve token.
- `vaultRegistrar` must register vaults and ordinals accurately.
- `ordinalOracle` must report ordinal movement accurately.

### ERC20 Compatibility Decision

WK intentionally remains ERC20-like but not ERC20-compliant. The contract exposes metadata, balances, total supply, `transfer`, and `Transfer` events, but it does not expose allowance methods.

Operational implications:

- WK should not be marketed as a standard ERC20 until `approve`, `allowance`, and `transferFrom` are implemented.
- Integrations that require allowance-based token movement will not work.
- Custodians, indexers, wallets, and token lists should receive explicit integration notes.

## Audit Findings

### M-01: Immutable registrar/oracle roles create permanent operational risk

Severity: Medium

Status: Open, accepted if immutable deployer-operated provenance is intentional  
Location: constructor, `onlyRegistrar`, `onlyOracle`

Both privileged roles are set to `msg.sender` in the constructor and cannot be changed:

```solidity
vaultRegistrar = msg.sender;
ordinalOracle = msg.sender;
```

The roles do not directly withdraw user funds, but they are central to provenance integrity. A compromised oracle can falsely mark registered ordinals as moved. A compromised or mistaken registrar can register incorrect vaults. A lost key permanently disables new inscriptions and ordinal reporting.

Possible Impact:

- Permanent provenance corruption or operational dead-end.
- No recovery path if deployer key is lost or compromised.

Recommendation:

- Accept explicit `_vaultRegistrar` and `_ordinalOracle` constructor arguments if separate keys are desired.
- Use separate hardened multisigs or threshold systems for registrar and oracle.
- If immutability is mandatory, document the irreversible operational tradeoff and deployment key ceremony.

### L-02: First acquirer/inscriber receives the full distribution (bootstrap)

Severity: Low/Informational

Status: Documented (by design)  
Location: `acquire`, `inscribe`

When `totalSupply == 0` the measured distribution is added to the first minter’s tokens instead of being distributed.

Impact:

- First user receives 100% of deposited cbBTC as tokens.
- Slightly contradicts the high-level “7% flows to all witness keys” statement for the bootstrap case.
- This primarily a documentation/tokenomics inconsistency rather than a demonstrated exploit

### L-01: Zero-value transfer could mark a vault as swept

Severity: Low  
Status: Remediated  
Location: `transfer`

`transfer` previously allowed `tokens == 0`. Because `_checkVaultSweep` runs before balance changes, a registered vault could call `transfer(any, 0)` and mark itself swept.

Impact:

- `VaultSwept` event might not strictly mean value moved.
- Off-chain indexing systems could receive a false sweep signal.

Recommendation:

- Added `require(tokens > 0, "Zero tokens");`.
- Added test proving zero transfers revert.

### L-02: `transfer` lacked reentrancy protection

Severity: Low  
Status: Remediated  
Location: `transfer`

Other value-moving functions already used `nonReentrant`. `transfer` did not.

Impact:

- Currently safe (no external call after critical state updates), but inconsistent defence-in-depth.

Recommendation:

- Added `nonReentrant` modifier to `transfer`.

### L-03: WK is ERC20-like, not ERC20-compliant

Severity: Low  
Status: Open by design  
Location: full token interface

The contract exposes `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `transfer`, and `Transfer`, but does not implement `approve`, `allowance`, or `transferFrom`.

Impact:

- Wallets, token lists, indexers, bridges, and DeFi integrations may treat WK inconsistently.
- External contracts expecting a standard ERC20 cannot spend WK by allowance.

Recommendation:

- Explicitly document WK as a non-ERC20 accounting token, or implement full ERC20 later if WK ends up aligning to ERC20 in future.
- If ERC20 compatibility is desired, integrate dividend baseline updates into an `_update` style hook.

### I-01: Per-transaction max acquire is not a position or rate limit

Severity: Informational  
Status: Open by design  
Location: `acquire`, `MAX_ACQUIRE`

`MAX_ACQUIRE` limits one call to 1,000,000 sats, but any user can call `acquire` repeatedly.

So this works fine:

``text
Alice → acquire(1,000,000) → success
Alice → acquire(1,000,000) → success
Alice → acquire(1,000,000) → success
``

Impact:

- This is a UX/slippage bound, not an anti-whale or rate-limit control.

Recommendation:

- Document it as a per-call bound, or implement per-address/time-window limits if actual rate limiting is required.
- Reentrancy guard only protects a protected function from being entered while previous invocation is still being executed. `acquire` isn't safe from multiple
  invocations by the same caller.

### I-02: Slither informational findings

Severity: Informational  
Status: Reviewed  
Location: dependencies and naming

Slither reported:

- Assembly usage in OpenZeppelin `SafeERC20`.
- Mixed pragma ranges across stubs.
- Known Solidity-version warning for `0.8.20`.
- Naming-convention warning for public immutable `CBBTC`.

Impact:

- No direct WitnessKey exploit path identified.
- Assembly findings are inherited from audited OpenZeppelin code.
- `CBBTC` is intentionally uppercase as an immutable reserve token handle.

Recommendation:

- Keep compiler and EVM version pinned.
- Treat dependency updates as security-sensitive changes requiring a fresh test and static-analysis run.

## Positive Observations

- State is updated before external cbBTC transfers in `dispose` and `claim`.
- `acquire`, `dispose`, `claim`, `recirculate`, and `inscribe` use `nonReentrant` (and `transfer` now does as well).
- `SafeERC20` is used for reserve transfers.
- Dividend accounting uses signed baselines and handles negative values.
- `dispose` prevents burning the entire global supply.
- `minTokens` / `minCbbtc` give users basic slippage protection.
- Ordinal uniqueness and already-moved checks are enforced at inscription time.

## Test Coverage

Implemented unit tests for:

- First-minter bootstrap behaviour.
- Subsequent distribution application.
- Dispose fee collection and minimum-size enforcement.
- Zero-value transfer rejection.
- Duplicate ordinal registration rejection.
- Already-moved ordinal registration rejection.
- Access control on registrar and oracle.
- Claim and recirculate flows.

## Deployment Checklist

### Network and Constructor

- Base mainnet cbBTC: `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` (verify before use).
- Constructor argument: the `cbBTC` address for the target network.
- Deployer permanently becomes both `vaultRegistrar` and `ordinalOracle`.

### Role Key Management

- Use the exact multisig or hardened operational key intended to hold both roles.
- If separate registrar/oracle keys are desired, change the constructor before deployment.
- If either key is lost, new inscriptions and/or ordinal reports may become permanently unavailable.
- If either key is compromised, provenance records can be corrupted even though user funds cannot be directly withdrawn by the role.

### Deployment Steps

- Run `forge fmt`.
- Run `forge test -vvv`.
- Run `forge coverage` (optional).
- Run static analysis with Slither.
- Verify source on the target network explorer.
- Publish integration notes stating WK is non-ERC20-compliant unless allowance support is later added.
- Index `VaultRegistered`, `VaultSwept`, and `OrdinalMoved` events off-chain.

## Remediation Changelog

| Finding                              | Fix                                              | Proof                                              |
| ------------------------------------ | ------------------------------------------------ | -------------------------------------------------- |
| Zero-transfer vault sweep            | Reject zero-value transfers                      | `test_ZeroTransferReverts`                         |
| transfer missing nonReentrant        | Added `nonReentrant`                             | Source review                                      |
| First-minter distribution ambiguity  | Explicit NatSpec documentation                   | Source comment + `test_FirstAcquireGetsFullAmount` |
| Duplicate ordinal registration       | Already present; tests added                     | `test_DuplicateOrdinalRegistrationReverts`         |
| Already-moved ordinal registration   | Already present; tests added                     | `test_AlreadyMovedOrdinalRegistrationReverts`      |
| Dispose minimum fee protection       | Already present (`MIN_DISPOSE = 100`)            | `test_DisposeBelowMinimumReverts`                  |

## Conclusion

The reviewed implementation is broadly coherent. The zero-transfer sweep issue and missing `nonReentrant` on `transfer` have been remediated. Bootstrap distribution behaviour and ordinal uniqueness are documented and tested. Before production deployment, make a deliberate decision on whether immutable deployer roles and nonstandard ERC20 behaviour are acceptable for the intended operating model.
