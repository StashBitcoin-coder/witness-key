# Origin Key Token Technical and Security Audit

Date: 2026-05-24  
Remediation update: 2026-05-24  
Scope: `src/OriginKeyToken.sol`  
Commit context: local workspace review; dependencies were installed to run Foundry tests.

## Executive Summary

Origin Key Token (`OKT`) is a cbBTC-backed, zero-decimal, ERC20-like token with a fixed 1 satoshi to 1 OKT unit model. The contract implements buy, sell, transfer, dividend withdrawal, dividend reinvestment, vault inscription, and ordinal movement reporting. It has no owner, no upgrade path, and immutable registrar/oracle roles.

No critical fund-draining vulnerability was confirmed in the reviewed implementation. The current sell accounting, dividend withdrawal order, and reinvest accounting are covered by unit and invariant tests and held under the included Foundry suite.

The initial review identified economic, provenance, documentation, and integration risks. The following items have now been remediated in code and tests:

- Sell-fee bypass through sub-100 sat sells. `MIN_SELL = 100` ensures the 7% fee calculation cannot round to zero; at 100 OKT/sats, the minimum sell fee is 7 sats.
- Duplicate and already-moved ordinal registration.
- Sell-accounting comment mismatch.
- Zero-value vault transfer sweep events.
- Reserve-token decimal validation.

Remaining notable risks are operational immutability and deliberate non-ERC20 allowance incompatibility. OKT should be presented as a protocol accounting token, not a standard ERC20, unless allowance support is added later.

## Verification Performed

Command run:

```sh
forge test -vvv
```

Result:

```text
76 tests passed, 0 failed, 0 skipped
```

Included coverage:

- 16 core tests in `OKT.t.sol`
- 24 audit/economic tests in `OKT.audit.t.sol`
- 32 security tests in `OKT.security.t.sol`
- 4 invariant tests in `OKT.invariant.t.sol`
- Each invariant executed 256 runs with 128,000 handler calls.
- Expanded invariant handler calls include `buy`, `sell`, `withdraw`, `reinvest`, `transfer`, `inscribe`, `reportOrdinalMoved`, `vaultSell`, `vaultWithdraw`, and `vaultTransfer`.

Compiler output:

```text
Compiler run successful!
```

Coverage:

```text
src/OriginKeyToken.sol: 100.00% lines, 100.00% statements, 88.14% branches, 100.00% functions
Total: 93.05% lines, 91.55% statements, 86.36% branches, 88.64% functions
```

Static analysis status:

- Slither 0.11.5 was installed in a local project virtualenv and run against `src/OriginKeyToken.sol`.
- Slither command used `HOME=/tmp` and explicit solc `0.8.20` because the default home directory is read-only for solc-select.
- Slither reported no OKT-specific high/medium fund-flow issue.
- Slither informational output: OpenZeppelin dependency assembly usage, mixed dependency pragma directives, Solidity-version warnings, and `CBBTC` naming-convention style.
- `foundry.toml` now pins `evm_version = "shanghai"` so Foundry and Slither use an EVM target supported by Solidity `0.8.20`.
- `aderyn`, `myth`, and `mythril` were not installed by default; Slither was the static-analysis tool completed in this pass.

## System Overview

### Core State

- `CBBTC`: immutable reserve token address set in the constructor.
- `totalSupply`: total OKT units minted.
- `balanceOf`: OKT balances.
- `profitPerToken`: global dividend accumulator using `MAGNITUDE = 2 ** 64`.
- `payoutsOf`: signed per-account dividend baseline.
- `vaultRegistrar`: immutable deployer-only role for `inscribe`.
- `ordinalOracle`: immutable deployer-only role for `reportOrdinalMoved`.

### Economic Flow

- `buy(cbbtcAmount, minTokens)`: transfers cbBTC in, charges 7% after first supply exists, mints OKT.
- `sell(tokens, minCbbtc)`: burns OKT, charges 7%, sends net cbBTC to seller.
- `withdraw()`: sends claimable dividends.
- `reinvest()`: converts claimable dividends into new OKT at 1:1 with no fee.
- `transfer(to, tokens)`: moves OKT and the corresponding dividend baseline with no fee.
- `inscribe(vault, assetId, cbbtcAmount, ordinalNumber)`: registrar-funded vault mint.
- `reportOrdinalMoved(ordinalNumber)`: oracle provenance report; marks associated vault swept if one exists.

### Trust Model

The contract is intentionally immutable. This reduces governance/admin risk but turns deployment mistakes and key compromise into permanent conditions.

Trusted actors:

- cbBTC contract address must be the expected reserve token.
- `vaultRegistrar` must register vaults and ordinals accurately.
- `ordinalOracle` must report ordinal movement accurately.

### ERC20 Compatibility Decision

OKT intentionally remains ERC20-like but not ERC20-compliant in this review pass. The contract exposes metadata, balances, total supply, `transfer`, and `Transfer` events, but it does not expose allowance methods.

Operational implications:

- OKT should not be marketed as a standard ERC20 until `approve`, `allowance`, and `transferFrom` are implemented.
- Integrations that require allowance-based token movement will not work.
- Custodians, indexers, wallets, and token lists should receive explicit integration notes.
- A test now documents this behavior by asserting allowance selectors are not exposed.

## Findings

### M-01: Sell fee can be bypassed by splitting sells into small chunks

Severity: Medium  
Status: Remediated  
Location: `sell`, fee calculation

```solidity
uint256 fee = (tokens * SELL_FEE) / 100;
uint256 taxed = tokens - fee;
```

The sell fee rounds down. For sells below 15 OKT, `tokens * 7 / 100` is zero. A user can sell in chunks of 1 to 14 tokens and pay no sell fee. A contract wallet can batch many sequential sells in one transaction until gas limits are reached.

Impact:

- The advertised 7% sell fee is avoidable.
- Dividend recipients can receive materially less sell-fee income than expected.
- The avoidance is economically viable when avoided fees exceed Base execution costs.

Recommendation:

- Implemented `MIN_SELL = 100` so the minimum sell fee is 7 sats, matching buy/inscribe minimums.
- Alternatively use rounded-up fees for sell operations, with explicit handling for tiny sells.
- Added tests proving below-minimum sells revert and minimum sells charge the expected fee.

### M-02: Ordinal registration does not enforce uniqueness or unmoved status

Severity: Medium  
Status: Remediated  
Location: `inscribe`, `reportOrdinalMoved`

`inscribe` stores:

```solidity
ordinalVaultAddress[ordinalNumber] = vault;
```

but does not require:

- `ordinalVaultAddress[ordinalNumber] == address(0)`
- `!ordinalHasBeenMoved[ordinalNumber]`

The registrar can therefore register the same ordinal to multiple vaults over time. The latest vault overwrites the reverse lookup, while older vaults still keep `vaultOrdinal[vault]`. The registrar can also register an ordinal that the oracle already reported as moved.

Impact:

- Provenance records can become ambiguous.
- `reportOrdinalMoved` will only emit `VaultSwept` for the latest `ordinalVaultAddress`.
- `vaultOrdinalStatus` for multiple vaults may reflect the same global moved flag.

Recommendation:

- Implemented ordinal uniqueness when `ordinalNumber > 0`.
- Implemented rejection of ordinals already marked moved.
- Added tests for duplicate ordinal registration and registration after movement.

### M-03: Immutable registrar/oracle roles create permanent operational risk

Severity: Medium  
Status: Open, accepted if immutable deployer-operated provenance is intentional  
Location: constructor, `onlyRegistrar`, `onlyOracle`

Both privileged roles are set to `msg.sender` in the constructor and cannot be changed:

```solidity
vaultRegistrar = msg.sender;
ordinalOracle = msg.sender;
```

The roles do not directly withdraw user funds, but they are central to provenance integrity. A compromised oracle can falsely mark registered ordinals as moved. A compromised or mistaken registrar can register incorrect vaults or duplicate ordinals. A lost key permanently disables new inscriptions and ordinal reporting.

Impact:

- Permanent provenance corruption or operational dead-end.
- No recovery path if deployer key is lost or compromised.

Recommendation:

- Accept explicit `_vaultRegistrar` and `_ordinalOracle` constructor arguments.
- Use separate hardened multisigs or threshold systems for registrar and oracle.
- If immutability is mandatory, document the irreversible operational tradeoff and deployment key ceremony.

### L-01: Sell accounting comments contradict the implementation

Severity: Low  
Status: Remediated  
Location: header comments and sell comments

The header says sell must subtract `taxed + payout` from `payoutsOf`, while the implementation subtracts only the dividend baseline and transfers `taxed` directly:

```solidity
uint256 payout = (tokens * profitPerToken) / MAGNITUDE;
payoutsOf[msg.sender] = _signedSub(payoutsOf[msg.sender], payout);
CBBTC.safeTransfer(msg.sender, taxed);
```

The implementation is internally coherent and the tests specifically guard against double-spend behavior. The comments are stale and dangerous because following them would inflate seller dividends after direct cbBTC payment.

Impact:

- Future maintenance risk.
- Auditors and integrators may misunderstand the invariant being preserved.

Recommendation:

- Updated comments to match the implemented direct-payment sell model.
- Added explicit commentary around why `taxed` is not added to `payoutsOf`.

### L-02: Zero-value transfer can mark a vault as swept

Severity: Low  
Status: Remediated  
Location: `transfer`

`transfer` does not reject `tokens == 0`. Since `_checkVaultSweep` runs before balance changes, a registered vault can call:

```solidity
transfer(anyAddress, 0)
```

and mark itself swept even though no value left the vault.

Impact:

- `VaultSwept` may not strictly mean value moved.
- Off-chain provenance/indexing systems can receive a false sweep signal.

Recommendation:

- Added `require(tokens > 0, "Zero tokens");` to `transfer`.
- Added a zero-transfer test proving vaults are not marked swept.

### L-03: OKT is ERC20-like, not ERC20-compliant

Severity: Low  
Status: Open by design; covered by explicit test  
Location: full token interface

The contract exposes `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `transfer`, and `Transfer`, but it does not implement ERC20 allowance functions such as `approve`, `allowance`, or `transferFrom`.

Impact:

- Wallets, token lists, indexers, bridges, DeFi integrations, and custodial tooling may treat OKT inconsistently.
- External contracts expecting a standard ERC20 cannot spend OKT by allowance.

Recommendation:

- Either explicitly document OKT as a non-ERC20 accounting token, or implement ERC20 fully.
- If ERC20 compatibility is desired, inherit or mirror OpenZeppelin ERC20 and integrate dividend baseline updates into `_update`.
- Added a test documenting that allowance functions are not exposed.

### I-01: Per-transaction max buy is not a position or rate limit

Severity: Informational  
Status: Open by design  
Location: `buy`, `MAX_BUY`

`MAX_BUY` limits one call to 1,000,000 sats, but any user or contract can call `buy` repeatedly.

Impact:

- This is not an anti-whale or rate-limit control.

Recommendation:

- Document it as a UX/slippage bound, or implement per-address/time-window limits if actual rate limiting is required.

### I-02: Reserve-token assumptions are not enforced beyond nonzero address

Severity: Informational  
Status: Remediated  
Location: constructor

The constructor accepts any nonzero `_cbbtc` address. The accounting assumes a standard, non-rebasing, non-fee-on-transfer token with 8 decimals.

Impact:

- Deployment with a nonstandard token can break the 1 sat to 1 OKT model.

Recommendation:

- Added a constructor check requiring 8 reserve-token decimals.
- Added a test rejecting a non-8-decimal reserve token.

### I-03: Slither informational findings

Severity: Informational  
Status: Reviewed  
Location: dependencies and naming

Slither reported:

- Assembly usage in OpenZeppelin `SafeERC20` and `StorageSlot`.
- Mixed pragma ranges across OpenZeppelin interfaces and utilities.
- Known Solidity-version warning for `0.8.20` and dependency pragma ranges.
- Naming-convention warning for public immutable `CBBTC`.

Impact:

- No direct OKT exploit path was identified by these findings.
- The assembly findings are inherited from audited OpenZeppelin utility code.
- The naming warning is cosmetic and `CBBTC` is intentionally uppercase as an immutable reserve token handle.
- The compiler-version warning should be revisited before production deployment if the project can safely move to a newer compiler.

Recommendation:

- Keep `foundry.toml` pinned to an EVM version supported by the selected compiler.
- Consider upgrading Solidity after running the full test and invariant suite on the target compiler.
- Treat dependency updates as security-sensitive changes requiring a fresh test and static-analysis run.

## Positive Observations

- State is updated before external cbBTC transfers in `sell` and `withdraw`.
- `buy`, `sell`, `withdraw`, `reinvest`, and `inscribe` use `nonReentrant`.
- `SafeERC20` is used for reserve transfers.
- Dividend accounting uses signed payouts and handles negative baselines.
- `sell` prevents burning the entire global supply, avoiding a zero-supply state with remaining accounting complexity.
- `minTokens` and `minCbbtc` give users basic slippage protection.
- Invariant tests cover solvency, supply integrity, phantom dividends, and accumulator monotonicity.

## Test Coverage Gaps

Implemented unit tests for:

- Below-minimum sell rejection and minimum sell fee collection.
- Duplicate ordinal registration rejection.
- Registering an already-moved ordinal rejection.
- Zero-value transfer from a vault.
- Constructor validation for expected 8-decimal reserve tokens.
- ERC20 allowance-function non-exposure.

Implemented invariant coverage for:

- Normal actor buys, sells, transfers, withdrawals, and reinvestment.
- Vault inscription by the immutable registrar.
- Vault sells, withdrawals, and transfers.
- Ordinal movement reports by the immutable oracle.
- Solvency across actors and vaults.
- Total tracked OKT balances across actors and vaults.
- No single actor or vault claiming more dividends than the contract holds.

## Deployment Checklist

### Network and Constructor

- Base mainnet cbBTC: `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf`.
- Base Sepolia cbBTC: `0xcbB7C0006F23900c38EB856149F799620fcb8A4a`.
- Constructor argument: the cbBTC address for the target network.
- Constructor now requires the reserve token to expose `decimals() == 8`.

### Role Key Management

- The deploying address permanently becomes both `vaultRegistrar` and `ordinalOracle`.
- Use the exact multisig or hardened operational key intended to hold both roles.
- If separate registrar/oracle keys are desired, change the constructor before deployment.
- If either key is lost, new inscriptions and/or ordinal reports may become permanently unavailable.
- If either key is compromised, provenance records can be corrupted even though user funds cannot be directly withdrawn by the role.

### Deployment Steps

- Run `forge fmt`.
- Run `forge test -vvv`.
- Run `forge coverage`.
- Run static analysis with Slither; optionally also run Aderyn/Mythril in an environment where those tools are installed.
- Verify source on the target network explorer.
- Publish integration notes stating OKT is non-ERC20-compliant unless allowance support is later added.
- Index `VaultRegistered`, `VaultSwept`, and `OrdinalMoved` events off-chain.

## Remediation Changelog

| Finding | Fix | Proof |
| --- | --- | --- |
| Sell-fee rounding bypass | Added `MIN_SELL = 100` and require sells to meet it | `test_sellBelowMinimumReverts`, `test_sellMinimumChargesFee` |
| Duplicate ordinal registration | Reject ordinals already mapped to a vault | `test_duplicateOrdinalRegistrationReverts` |
| Already-moved ordinal registration | Reject ordinals already reported moved | `test_alreadyMovedOrdinalRegistrationReverts` |
| Sell accounting documentation mismatch | Updated sell comments to match direct-payment accounting | Source review and passing sell/double-spend tests |
| Zero-transfer vault sweep | Reject zero-value transfers | `test_zeroTransferRevertsAndDoesNotSweepVault` |
| Reserve decimal assumption | Constructor requires 8-decimal reserve token | `test_constructorRejectsNonEightDecimalReserve` |
| ERC20 ambiguity | Documented non-ERC20 allowance behavior and added explicit test | `test_erc20AllowanceFunctionsAreNotImplemented` |

## Conclusion

The reviewed implementation is broadly coherent and passed the available unit and invariant test suite. The sell-fee rounding bypass, ordinal uniqueness gap, zero-transfer vault sweep issue, reserve decimal assumption, and sell-comment mismatch have been remediated. Before production deployment, make a deliberate decision on whether immutable deployer roles and nonstandard ERC20 behavior are acceptable for the intended operating model.
