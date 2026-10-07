# Basket Protocol

An immutable index vault for Stock Tokens on **Robinhood Chain (chain ID 4663)**.
The vault itself is the ERC-20: **Basket / BASK**, 18 decimals, initial supply zero,
no share supply cap. Deposits mint shares and redemptions burn them. This project
contains contracts, local mocks, tests and a static deployment manifest.

## Build and check

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, optimization at **200 runs**, the IR
pipeline, **Cancun**, and `bytecode_hash = "none"`. Production code has no external
library dependency. The test dependency, forge-std **v1.9.7**, is vendored as
ordinary source files under `lib/forge-std`, with both upstream licenses. A
compiler installation is the only toolchain prerequisite; builds need no network,
submodules, FFI or filesystem cheatcode permissions. Tests use neither forks nor
environment variables and do not broadcast transactions.

The EVM constant optimizer is disabled while the overall optimizer remains on at
200 runs. Otherwise Solidity pools event topics in a trailing raw-data table,
which the pinned deployment check interprets as opcodes. This keeps the bytecode
compatible with that check without changing contract behavior. Runtime is
22,258 bytes under these settings.

## Deployment parameters

Deploy `BaskVault(address owner_, address guardian_)` using `launch.json`:

| Parameter | Literal |
| --- | --- |
| `owner_` | `0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3` |
| `guardian_` | `0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68` |
| Source constant `STOCK_FACTORY` | `0x4783C67b63dE2B358Ac5951a7D41F47A38F3C046` |

The constructor rejects zero or equal roles, makes no external calls and assigns
neither role to the deploying factory. The asset list is initially empty. No lens
is needed because vault runtime fits below 24,000 bytes. There is no chain-ID
restriction in the bytecode; the supplied factory constant and deployment
manifest are intended solely for chain 4663. No other production addresses are
assumed or discovered by this project. Tests simulate the supplied interfaces;
they do not establish that a production token or feed is trustworthy.

The owner must select and verify each Stock Token and its corresponding USD feed,
list at least three assets with `proposeAsset` or `proposeAssets`, then call
`finalizeGenesis` once. Genesis listings are immediate and return proposal ID 0.
Deposits become eligible 72 hours after finalization. The daily listing/feed
execution limit applies to delayed proposals, not to genesis listings.

## Accounting and deposits

Each asset has a permanent position in a list of at most 64 entries. `managed`
records accepted deposits less redemption legs and recognized losses. Direct
transfers never increase it. NAV uses only `managed`, valid feed answers and
unretired assets; actual balances are used for solvency and settlement checks.
Stock Token amounts are raw 18-decimal units. Feed answers have 8 decimals and
mean USD per whole token. All USD caps and the bucket use 18 decimals.

`deposit(token, amount, receiver, minSharesOut, deadline)` requires:

- Genesis finalization plus 72 hours, deposits unpaused, and a listed, open,
  unretired input asset. The receiver must be nonzero and different from the vault.
- Monday through Friday, **15:30:00 <= UTC time < 19:30:00**. The schedule is fixed
  UTC; it does not follow holidays or daylight-saving changes.
- At least three unretired feeds updated within four hours, inclusive. Closed
  assets still count. This freshness count is based on timestamps; a zero-managed
  asset's answer and oracle-pause state need not pass the position-price checks.
- A valid input price and valid prices for all nonzero unretired positions:
  positive answer, inclusive price band, nonfuture timestamp at most 26 hours
  old, and `oraclePaused() == false`. Each feed/oracle read has 100,000 gas.
- Every unretired balance readable and no available balance below `managed`.
  Input balance must also cover its outstanding `totalOwed`.

Value is `floor(amount * answer / 1e8)`. Gross shares are this value on the first
deposit, otherwise `floor(value * totalSupply / NAV)`; noninitial zero NAV rejects
deposits. The fee is `ceil(gross / 200)`. The receiver gets gross less this fee,
and on the first deposit another `1e15` shares go to `address(0xdEaD)`. Receiver
shares must be positive and meet `minSharesOut`. Fees mint only if a fee recipient
has been set; the deduction still applies while unset. Received tokens must
increase the vault balance by exactly `amount`.

The resulting NAV cannot exceed `NAV_CAP`, initially $1,000,000. One global bucket
decays by `floor(bucket * elapsed / 86400)`, down to zero after a full day, then
adds the new deposit value. Its bound is `max(floor(NAV2 / 4), $100,000)`. Deposits
clear all unretired deficit records after succeeding. Redeeming does not lower
the bucket. NAV growth can exceed the cap between deposits; the cap is checked
when accepting another deposit.

## Redemption, owed legs and loss accounting

`redeem(shares, minAmountsOut, deadline)` makes no feed or oracle-pause calls and
ignores genesis, deposit pauses, market hours, asset closes, retirement, NAV caps
and the bucket. The fee is `ceil(shares / 200)` and net shares are shares minus
fee. If set, the recipient receives the fee by an internal BASK transfer and only
net shares burn; otherwise all submitted shares burn. The vault never calls the
fee recipient. A recipient redeeming its own shares retains that fee.

For each permanent asset, available is `max(balance - totalOwed, 0)`. A balance
read is a low-level 50,000-gas staticcall with only 32 bytes copied; failure or a
return length other than 32 uses `managed` as the fallback. The leg is
`floor(min(managed, available) * net / totalSupplyBeforeBurn)`. Full-precision
division avoids intermediate multiplication overflow. Missing minimum-output
entries mean zero; extra entries beyond the asset list are ignored. Minimums
refer to legs allocated, including amounts deferred into claims.

Each nonzero leg reduces `managed` and is paid to the caller in an atomic
250,000-gas call to `payLeg`, callable only by the vault. A payout requires an
empty return or exactly ABI `true`, plus an exact decline of the vault balance.
Failed calls cannot retain token-side effects: the whole payout frame reverts,
and that leg instead increases the caller's `owed` and the token's `totalOwed`.
No unbounded return data is copied. Successful sibling legs continue. Recipient
transfer taxes are not measured: the specified check is the vault's exact debit.

`claim(token, to)` lets the creditor choose any nonzero destination. It attempts
`min(callerOwed, actualVaultBalance)`, without reserving other claims first, using
the same atomic payout with no 250,000-gas frame limit. Its initial balance read
and both balance reads inside `payLeg` use the remaining gas, without a fixed
50,000-gas cap; they still copy only 32 bytes and require exactly 32 returned
bytes. Redeem's allocation read retains its 50,000-gas cap and its entire payout
frame retains its 250,000-gas cap. Failed claims revert and
preserve the credit. A claim may therefore consume more transaction gas than a
redemption leg. Partially funded creditors can claim again after replenishment.
No role can gate either exit function. Token-level restrictions can still defer
or prevent actual payment; claims survive those failures.

`flagDeficit` records available-balance shortfall only when it exceeds the
existing record and resets its timestamp in that case. Equal/smaller shortfalls
do not restart the clock. At least seven days later, anyone can call
`recognizeLoss`: it deducts the smaller of recorded and current shortfall from
`managed` and clears the record. An unreadable balance cannot establish or
recognize a loss. These functions work on retired assets as well. Redemptions
on a shortage distribute the available fraction and leave the remaining loss
recordable; nothing silently writes down the remaining managed balance.

## Roles and proposals

| Action | Authority / delay |
| --- | --- |
| Propose listing, feed replacement, band, reopening, retirement, guardian or cap raise | Owner |
| Execute proposal | Anyone, from creation + 7 days inclusive to + 14 days exclusive |
| Cancel live proposal | Owner; guardian except for guardian replacement |
| Pause deposits, close asset | Owner or guardian, immediate |
| Unpause deposits | Owner, immediate |
| Lower NAV cap | Owner, immediate, including zero; voids all older pending raises |
| Raise NAV cap | Proposal, maximum $10,000,000,000; rechecked at execution |
| Set fee recipient | Owner once; nonzero, different from vault; final |
| Transfer ownership | Owner nominates nonzero nonguardian; nominee accepts; guardian exclusion rechecked |
| Redeem, claim, flag deficit, recognize loss | Users / anyone as described above |

Listing rechecks token uniqueness, 18 decimals, `uid()` factory identity, feed
decimals of 8, nonzero `aggregator()`, feed uniqueness among unretired assets and
a positive answer at both proposal and execution. Listing establishes a band
of answer / 4 through answer * 4 using the execution answer. Feed replacement
rechecks feed metadata, uniqueness and an answer inside the existing band at
both stages; it preserves that band. Bands must fit uint256 arithmetic.

A band proposal takes the positive execution answer, timestamp strictly less
than 26 hours old and not in the future, and establishes a new quarter-to-fourfold
band. It can recenter an out-of-band feed and does not require an unpaused token
oracle. Listing and feed replacement share one execution slot every 24 hours.
Every later close, even a repeated close, voids older reopening proposals.
Retirement requires the asset closed at proposal and execution, permanently
prevents reopening, voids pending/new proposals for that asset, and permits its
old feed to be reused. Its managed assets remain redeemable but count zero in NAV
and are skipped by every deposit health/freshness check.

There are no proxies, upgrades, rescue/sweep paths, administrative asset
transfers, fee changes, extra roles, or external share-mint functions. Every
user-facing state-changing entry point has one shared reentrancy guard and emits
events. `payLeg` is the self-only atomic payout helper called while that guard is
already held. Ownership or guardian changes never modify exit permissions.

## Views and client conventions

- `assets(i)`, `assetCount()`, `managed`, `totalOwed`, `owed`, `deficits` expose
  accounting; `allAssets()` includes feed, raw answer and update time, band,
  open/retired flags, managed, short, owed and feed/balance readability. A failed
  feed read reports answer/time zero. Unreadable balances report short=false and
  balanceReadable=false, using the same managed fallback as redeem.
- `previewDeposit(token, amount)` returns receiver shares, deducted fee, and
  locked shares. It applies the same token/market/price/solvency status checks.
  It quotes the amount before transfer and does not check cap/bucket limits,
  receiver, allowance, deadline or user slippage.
- `previewRedeem(shares)` returns legs and fee, without a price read or a caller
  balance check. It does not predict which transfers will become owed.
- `depositStatus(token)` returns `(Reason, faultAsset)`, using the same routine
  as deposit's `DepositUnavailable(Reason, faultAsset)` error. Global failures use
  zero as the fault address. Amount/receiver/deadline/cap/transfer failures have
  separate custom errors because this view has no corresponding arguments.
- `proposals(id)` exposes proposal details; `proposalState(id)` computes current
  status, including expiry and invalidation. `pendingProposals(start, count)`
  scans that ID range and returns waiting/ready IDs only. IDs start at one.

Reason values are stable enum ordinals:

| Code | Reason | Code | Reason |
| --- | --- | --- | --- |
| 0 | Ok | 11 | FeedUnreadable |
| 1 | Genesis | 12 | NonPositivePrice |
| 2 | WarmingUp | 13 | OutsideBand |
| 3 | Paused | 14 | FuturePrice |
| 4 | Unlisted | 15 | StalePrice |
| 5 | Retired | 16 | OracleUnreadable |
| 6 | Closed | 17 | OraclePaused |
| 7 | BalanceUnreadable | 18 | Deficit |
| 8 | OwedUnderfunded | 19 | ZeroNAV |
| 9 | MarketClosed | | |
| 10 | TooFewFreshFeeds | | |

Checks are deterministic: global state, target state/balance, calendar, then
unretired assets in permanent list order (price if needed, then balance), followed
by freshness quorum and nonzero NAV. Keep minima aligned with that permanent
asset order. Deadlines are inclusive (`now <= deadline`).

## Accepted design and operations

These are accepted economic and operational assumptions, without additional
mechanisms:

1. A lagging feed can permit deposit-then-redeem profit. With a separate fee
   recipient set, the nominal round-trip cost is about 1% (0.9975% before
   rounding). While unset, the unminted deposit fee benefits all holders,
   including the depositor, so the effective cost can approach 0.5% for a
   dominant depositor. The local $1,000 initial position / $10,000 subsequent
   deposit example costs about 54 basis points while unset versus 99 basis
   points with a separate recipient. Select and set the final fee recipient
   before opening deposits if the nominal fee economics are intended.
2. The owner pairs each Stock Token with its true feed. Factory identity and
   feed-format checks cannot establish economic correspondence.
3. An untransferable asset retains its feed value until deposits are paused.
4. A retired asset counts zero in NAV, even with a managed balance.
5. There is no per-asset concentration limit; one asset can represent any share
   of NAV.

The following consequences also follow from the specified accounting and
permissionless execution. No additional contract mechanisms address them:

- Zero NAV with outstanding shares makes deposits permanently unavailable.
  The locked `1e15` shares prevent supply returning to zero after initial use;
  listing new empty assets or sending tokens directly cannot restart deposits.
  Do not retire the last unretired position with positive NAV if continued
  deposits are intended. A complete recognized loss can cause the same state.
  Redeem and claim remain available.
- Anyone can bundle deposit, execution of a ready feed replacement, and redeem
  in one transaction to capture a favorable repricing. The local $100-to-$300
  replacement example returns about $165,279 for a $100,000 deposit. Pause
  deposits before the proposal becomes ready and keep them paused across the
  repricing; attempting to execute first does not guarantee ordering.
- Retired balances remain redeemable even though NAV excludes them. New
  depositors can acquire part of those positions without paying their value:
  the local example with half the original NAV retired returns about $14,887
  for a $10,000 deposit. Pause deposits before retiring a material managed
  position and keep them paused while the remaining retired holdings would
  materially distort share pricing. A ready retirement can also be bundled
  with deposits and redemption by its executor.
- A deposit followed immediately by redeem still consumes the bucket. Filling
  it can reject other deposits despite the assets having left. Capacity returns
  through elapsed-time decay, so this is not necessarily a full day of rejecting
  every amount; the local full-$100,000-bucket example accepts a $100 deposit
  after one hour. Repeated deposits can consume the recovered capacity.
- Raw balance increases outside deposit never increase `managed`. Hypothetical
  splits or in-kind distributions that credit raw units can therefore leave
  surplus outside share accounting, as can tokens restored after a recognized
  loss. Such surplus has no sweep or resynchronization path, although actual
  balances can still fund existing owed claims. A display-only multiplier
  change is different from a raw balance credit. Verify token/feed unit
  correspondence and corporate-action behavior when selecting assets; pause
  deposits and close the affected asset around any raw-balance-changing action.
  These controls do not recover surplus or stop permissionless loss recognition
  after seven days. Monitor and seek restoration of temporary shortfalls before
  that point; a transfer pause alone does not establish a balance shortfall.

The operator must monitor feed freshness, transfer restrictions, deficits,
pending proposals and the effect of retirement on share pricing. The guardian
can stop deposits and cancel ordinary proposals; the owner controls unpausing
and long-term asset/feed selection. Anyone can execute ready proposals and
perform loss recognition. Creditors are responsible for claiming deferred legs
and selecting a working destination. Neither contract logic nor mocks guarantee
chain transaction inclusion or the behavior of independently administered Stock
Tokens. Production feed addresses and their economic correspondence remain the
owner's deployment-time responsibility.

The local adversarial tests cover transfer pauses, recipient blocks, upgraded
unreadable tokens, costly balance reads during claims, gas exhaustion,
malformed/oversized return data, exact debit
rollback, reentrant callbacks, partial claims, solvency/loss delays, proposal
invalidation and role attempts to block exits. Dedicated tests populate all 64
positions and call redeem with less than 28,000,000 gas, including cold accounts
and storage. Their logged measurements exclude preparation of attack states.
Fuzz tests check successful and deferred-leg conservation and full-width
arithmetic. These are local implementation checks, not an independent security
audit; separate contributor review remains necessary before release. Slither and
Mythril were not run.

Recorded local verification: `forge build`, `forge test` (60 retained tests,
including three fuzz tests at 256 runs each, plus the supplied claim proof and
eight advisory reproductions under disposable `test/scratch/`), and
`forge fmt --check` pass. With the pinned compiler configuration, measured cold
64-asset redeem calls used **22,795,771 gas** for near-budget balance reads plus
exhausted payout calls, **22,745,436 gas** for upgraded unreadable tokens, and
**9,677,575 gas** for mixed failure/retirement states. Each test also enforces a
27,999,999-gas call limit directly. Claim regressions cover 60,000-gas balance
reads, 270,000-gas reads that force redemption into owed credit, successful
subsequent claims, and rollback of an inexact debit with costly balance reads.
