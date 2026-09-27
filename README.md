# Doomsday (DOOM) and DoomsdayClock

A Sepolia test game with no real value. DOOM is a fixed-supply ERC-20 launched through the
project factory. DoomsdayClock is a last-buyer timer game paid in DOOM.

Contracts:

| Contract | File | Purpose |
| --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | Doomsday (DOOM), 18 decimals, 1,000,000,000 minted once to the deployer |
| `DoomsdayClock` | `src/DoomsdayClock.sol` | The game. Takes the DOOM address as its only constructor argument |

ABI exports live in `docs/abi/LaunchToken.json` and `docs/abi/DoomsdayClock.json`.

## Launch token

`LaunchToken` is OpenZeppelin `ERC20` plus a constructor that mints `10^27` minor units to
`msg.sender`. On Sepolia `msg.sender` is the project factory, which sends the supply to the
launch pool and the reward distributor. There is no constructor argument, no mint, no owner,
no pause, no blocklist, no fee and no upgrade path. Players get DOOM by swapping Sepolia ETH
in the launch pool; nothing in this repository swaps for them.

## Game rules

Everything below is enforced by `DoomsdayClock`. Times are `block.timestamp` seconds.

- **Rounds.** Round ids start at 1. A round opens with its first key purchase and never starts
  without one. Opening sets `end = now + 1 hour`, then the purchased keys add their time. After
  settlement the id advances to a round with `end == 0` that opens on the next purchase.
- **Keys.** `buyKeys(n, maxCost)` buys `1 <= n <= 100` keys. Key `k` of a round (from 0) costs
  `price_0 = 10^18` and `price_k = ceil(price_(k-1) * 1001 / 1000)`. The total for the batch
  must be `<= maxCost` or the call reverts with `CostExceedsMax`. Payment is `approve` on DOOM
  followed by `safeTransferFrom`; permit is not used. `priceOfNext(n)` quotes the batch.
- **Timer.** Each key adds 30 seconds: `end = min(end + 30 * n, now + 24 hours)`. The cap moves
  with the clock, so time passing lets later keys extend again. `end` never decreases.
- **Last buyer.** Every purchase makes the caller `lastBuyer`. At `block.timestamp >= end` the
  round is over: a buy at exactly `end` settles first and opens the next round.
- **Pot.** The pot is all DOOM paid for keys plus the carry folded in when the round opened.
  Before a round opens `pot()` is 0 and `carry()` holds the pending amount; both are disjoint.
- **Settlement.** Once ended, anyone may call `settle()`, or the next `buyKeys` settles. Of the
  pot `P` with `K` keys: `floor(P * 50%)` is credited to the last buyer; every key holder may
  later call `claimShare(round)` for `floor(P * 30% / K)` per key; the rest, at least 20% plus
  all rounding dust, is the next round's carry. The last buyer also earns the per-key share for
  their own keys. Settling twice reverts with `RoundNotEnded`.
- **Payouts.** All payouts are pull-based. `claimShare` and settlement credit `withdrawable`;
  `withdraw()` transfers the caller's credit. Nothing is pushed to third parties. Every
  state-changing function is `nonReentrant` and follows checks-effects-interactions.
- **No admin.** There is no owner, admin, pause, upgrade, sweep or parameter setter. The
  contract has no payable function and no receive/fallback, so it never holds ETH. It holds no
  DOOM at deployment.

### Views and events

Views: `token()`, `round()`, `end()`, `pot()`, `carry()`, `lastBuyer()`, `priceOfNext(n)`,
`keysOf(round, account)`, `withdrawable(account)`, plus helpers `totalKeys(round)`,
`claimed(round, account)`, `claimable(round, account)`, `roundInfo(round)` and `hasEnded()`.

Events: `KeysBought(round, buyer, n, cost, end)`, `Settled(round, lastBuyer, prize, perKey,
carry)`, `ShareClaimed(round, account, keys, amount)`, `Withdrawn(account, amount)`. The site
lists past rounds from `Settled` events and each wallet's shares from `keysOf` and `claimable`.

## Assumptions and known properties

- **Ordering decides the winner.** The last buyer is decided by transaction ordering and block
  timestamps. Validators can nudge `block.timestamp`, and block stuffing near `end` is a known
  strategy. There is no randomness in the game and none is needed.
- **Same-second boundary.** `block.timestamp >= end` means ended. A purchase mined in the same
  second as `end` does not extend the round; it settles it and starts the next one.
- **Rounding.** `perKey` is floored once, so `perKey * totalKeys <= 30%` of the pot always
  holds and the shortfall lands in the carry. The 50% prize is floored. Carry is therefore at
  least 20% of the pot.
- **Price overflow.** Prices grow by 0.1% per key. Buying the whole DOOM supply into one round
  reaches roughly 13,800 keys, far below any overflow, and all arithmetic is checked.
- **Currency assumptions.** DOOM is a plain OpenZeppelin ERC-20 with no hooks, fees or
  rebasing. The clock trusts the `amount` it charges; a fee-on-transfer currency would break
  the conservation invariant. This is fixed at deployment because `token` is immutable.
- **Unclaimed shares stay forever.** Shares of a settled round can be claimed at any later
  time. Nothing sweeps them and no admin can reach them.
- **Loops are bounded.** Cost computation loops at most 100 times per call.

## Deployment parameters

The Sepolia launch goes through the project factory. The manifest step, not this repository,
writes `launch.json`. What it needs from here:

| Item | Value |
| --- | --- |
| Chain | Sepolia (11155111) |
| Launch token | `LaunchToken` (Doomsday, DOOM), no constructor arguments |
| Application contract | `DoomsdayClock`, constructorArgs `["$token"]` |
| Owner | none; no `$owner` argument exists |
| Deploy-time balances | `DoomsdayClock` holds no DOOM and no ETH at deployment |
| Compiler | solc 0.8.26, optimizer 200 runs, `evm_version = "cancun"`, `bytecode_hash = "none"` |

Constructors run with the factory as `msg.sender`. Neither constructor grants anything to
`msg.sender` beyond the token mint the factory expects. `DoomsdayClock` rejects the zero address
and any address without code, so it must be listed after the token, which `$token` guarantees.

`script/Deploy.s.sol` is a local helper for a dev chain. It reads no environment variables and
is not the Sepolia launch path.

## Operational responsibilities

- **Nobody operates the contract.** There are no keys to hold, no parameters to tune and no
  emergency switch. Once deployed it runs on player transactions alone.
- **Settlement is permissionless.** If no one buys after `end`, anyone may call `settle()`.
  Until then the round stays ended with the pot intact; nothing is lost by waiting.
- **Players hold their own risk.** Slippage is bounded by `maxCost`. Credited DOOM is only paid
  out by `withdraw()` from the owning wallet.
- **Website.** The one-page site reads the DOOM address from `token()`, shows balance,
  allowance and `withdrawable`, has an Approve step before each paying action and a Withdraw
  button, and states that DOOM comes from swapping Sepolia ETH in the launch pool. It reads
  contract views and events only; no backend or indexer. It is built after deployment.
- **Review.** Tests are not an audit. The independent adversarial review should attack share
  rounding, the 24-hour cap arithmetic, buying in the same block as `end`, carry accounting
  across rounds and reentrancy on claim or withdraw. The reentrancy tests use a hooking stand-in
  token because DOOM itself has no hooks.

## Building and testing

```
forge build
forge test
forge fmt --check
```

Dependencies are vendored as plain files under `lib/` (forge-std v1.9.7 and
openzeppelin-contracts v5.1.0, contracts directory only). Tests read no environment variables,
run in any order and in parallel, and include:

- the price sequence against an independent ceil reference, including the first key where
  ceiling differs from flooring (key 7);
- the 100-key and 24-hour caps, `maxCost` reverts, allowance and balance failures;
- buy after end settling first, buy in the same second as `end`, settle twice, claim twice,
  claims on unsettled or unknown rounds, withdraw with nothing owed;
- a round where one address holds every key, carry flowing across rounds;
- reentrancy attempts from a hooking token on withdraw and buy;
- a handler-driven invariant that DOOM held equals current pot + carry + unclaimed shares +
  withdrawable balances, that settled rounds never pay more than their pot, and that `end`
  never exceeds 24 hours ahead.
