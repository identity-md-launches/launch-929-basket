# Basket vault property tests

The existing unit, governance, loss, adversarial and 64-asset gas suites remain intact.
All external dependencies are local mocks on chain ID 4663. No installation, RPC,
environment variables, fork, or external service is needed.

Run the complete submission with `forge build` and `forge test`.

`BaskInvariant.t.sol` targets only the 13 action selectors in `handlers/BaskHandler.sol`.
Its inline settings run 256 sequences of 96 calls, failing on unexpected reverts.
Four funded actors and four assets enter every sequence. Actions include partial,
zero and complete redemptions; deposits; directed claims; share transfers and
allowances; donations; confiscations; loss reporting and recognition; dependency
failures and recovery; time advancement; pauses; close/reopen/cancel/retire; and
setting the final fee recipient. The fourth asset can retire while three assets
remain to satisfy the fresh-feed quorum.

After each action the invariant checks:

- Physical custody plus payouts plus confiscations equals deposits plus donations.
- Managed assets plus deferred debts plus payouts plus recognized losses equals
  deposits. Donations never enter this accounting identity.
- Each claimant's debt and total debt match independent handler records.
- Total share supply equals actor balances, the fee recipient's included balance,
  and the fixed initial lock.
- Retirement cannot remove an asset or reopen it.

Redemption postconditions independently bound the rounded pro rata entitlement
and require either exact payment or the corresponding deferred credit. Claim
postconditions check the caller's debt, destination, partial payment and rollback
on failure. After every sequence, every actor attempts a full redemption; recovered
Stock Tokens then permit claims even with the generated vault role restrictions
still in place. Deterministic handler tests exercise failed payments, recovered
claims, timed losses, retirement and the distinction between incoming credit and
outgoing debit checks.

`BaskEconomicProperties.t.sol` adds two 1,000-case fuzz campaigns: unequal-price
multi-asset share and fee rounding, and repeated deposit/redeem cycles interspersed
with donations. It also pins the first-deposit threshold, zero and one-wei inputs,
excess shares, receiver attribution and deposit/deferred-payment/claim events.

The no-profit properties hold prices fixed during each round trip. They do not
claim protection against the explicitly accepted stale-feed arbitrage or the NAV
effect of retirement. The accounting invariant permits unrecognized and
underfunded losses instead of incorrectly assuming custody always covers all
liabilities. The random handler uses partial confiscations to keep recovery paths
reachable; the existing loss suite covers complete and debt-underfunding cases.
The existing 64-asset suite separately attacks gas exhaustion and hostile upgrades.
