# SIMD TEST 2 — DO NOT BUY

**This is a test token, not a real coin. It has no value and must not be bought.**

Name: `SIMD TEST 2 - DO NOT BUY` · Symbol: `SIMDTEST2` · 18 decimals  
Logo: <https://www.si-md.xyz/logo.jpg> · Launch chain: Robinhood Chain, ID **4663**.

This project delivers `TestHook` and the launch's required plain `TestToken`. There is no new vault,
distributor, claim contract, router or other application contract. The existing SIMD Test Vault's
weekly holder/job/dev/marketing distributions and the launch remainder's claim contract are outside
these contracts. Sending fees to that vault does not implement or guarantee its distribution policy.

## Contracts and deployment

| Contract | Constructor | Deployment behavior |
| --- | --- | --- |
| `src/TestToken.sol:TestToken` | No arguments | Mints exactly `1000000000000000000000000000` minor units (one billion tokens) to its deployer, the launch factory. |
| `src/TestHook.sol:TestHook` | `IPoolManager manager_, address token_` | Permanently binds the manager and the already-deployed launch token; validates its address permission bits. |

For the launch tooling, the hook constructor arguments are **`$poolManager`, `$token`**, in that order.
The manager is an argument, never a production hardcoded address. There is no owner/admin argument.
Constructors neither call external contracts nor require external code to exist. Invalid zero
parameters and a launch token equal to IMD are rejected; these are validation cases, not deployment defaults.

The factory must deploy the token, mine and deploy the hook, and initialize the pool atomically.
Mine CREATE2 against the **actual factory**, exact compiled hook creation code and ABI-encoded
constructor arguments. The low 14 address bits must equal **`0x20cc` (8396)**:
`beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`.
`HookFlags` is an internal-only library for checking these bits; no library linking is needed.
The tests mine salts and deploy the actual constructor without bypassing permission validation.

The required initialization callback authenticates the manager and accepts only this immutable key:

| Parameter | Value |
| --- | --- |
| Currency pair | Sorted addresses of `$token` and IMD |
| IMD | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` (18 decimals) |
| LP fee | `12500`, or 1.25%; static, no override |
| Tick spacing | `60` |
| Hooks | This deployed hook |
| Fee vault | `0xa9d495A0b10EE4A2a735c2E0f6D38C583194813A` |
| Hook fee | `75 / 10000`, or 0.75% of gross executed IMD |

The hook accepts the factory's opening price; it does not impose a one-to-one price. The launch
deployer derives that price from the policy's 2,500 IMD opening market cap and token address order.
The tests use a one-to-one starting price to make accounting easy to inspect, and cover both orders.
The factory performs all supply allocations: 10% to its MerkleDistributor, 26.69% to liquidity,
63.31% to `0xa2d9d0e088f09c92b29a96b59764fdc446ac0d8a`. Neither delivered contract takes an allocation.

No `launch.json` is included: the network's later manifest step supplies it. No deployment or
broadcast has been performed by this project.

## Fee accounting

The token has ordinary ERC-20 transfers and allowances, without a transfer tax or public mint/burn.
The hook takes only IMD, never SIMDTEST2 or ETH, and never swaps fees into another asset.
Fees round down to IMD minor units; dust can pay zero. `hookData` and the router's identity cannot
change a fee or destination. There is no timestamp, block number, anti-sniper rule or time schedule
in either production contract.

Let `P` be the actual IMD input to the core pool (including its LP fee), `G` the actual gross IMD
output, `A` an exact-input IMD budget, and `R` an exact-output IMD request:

| Trade | Fee and result |
| --- | --- |
| Buy, exact input | Full fill: `f = floor(A * 75 / 10000)`, core input `A - f`. Partial fill: `f = floor(P * 75 / 9925)`, total spent `P + f`. |
| Buy, exact output | Requested SIMDTEST2 output is preserved; `f = floor(P * 75 / 9925)`, total IMD spent `P + f`. |
| Sell, exact input | `f = floor(G * 75 / 10000)`, user receives `G - f` IMD. |
| Sell, exact output | Core output request is `R + floor(R * 75 / 9925)`. Charge `floor(G * 75 / 10000)` on the actual fill, preserving `R` net IMD on a full fill. |

In every case `fee = floor(gross executed IMD * 75 / 10000)`. Unfilled budgets are not taxed.
The nominal rates add to **2%**. In v4 they apply sequentially to different bases: absent rounding,
price impact and protocol fees, two sequential deductions leave `0.9925 * 0.9875 = 0.98009375`
of the starting value (a 1.990625% deduction). The hook does not inflate the 0.75% rate to force
an exact 2% deduction, change the factory's LP fee, or control the manager's external protocol-fee policy.

### Partial fills and v4 deltas

v4 only permits the *specified* hook delta to be returned in `beforeSwap`. For exact-input buys and
exact-output sells, the hook previews the core swap in an external **self-only, always-reverting**
call. v4 skips hook callbacks when the hook itself calls `swap`, so the preview cannot recurse.
The revert rolls back its price changes, fee growth, events and transient deltas. No token payment
occurs in the preview. It returns the actual fill through a checked custom-error payload.

The hook returns only the calculated fee as the specified delta; the real pool still executes the
trade. For the other two modes the IMD side is unspecified, so the fee is calculated directly in
`afterSwap`. This also avoids taxing liquidity gaps or no-fill swaps. A differential test compares
pool price and deltas against a single unhooked core swap.

All payouts occur after the actual core swap. `take` or `mint` debits the hook by exactly its
returned positive fee delta. The manager credits that returned delta, so the hook's debt is zero
at unlock completion. The preview costs extra gas for the two specified-IMD modes; it does not
change the pool's curve or LP accounting.

### Delivery failure and recovery

Normal swaps transfer IMD directly from PoolManager to the fixed vault and emit `FeePaid(amount)`.
If IMD is the manager's currently synced currency when `afterSwap` runs (a router that calls
`sync(IMD)` before `swap` and settles afterwards, a legal v4 ordering), moving IMD out would make
that router's `settle` credit the fee short and revert its unlock. In that case the hook skips the
transfer and mints the claim described below (`FeeDeferred`). If that transfer reverts or returns false, the hook catches the failed `take` and instead mints
an IMD ERC-6909 claim **to itself**, emitting `FeeDeferred(amount)`. This requires no IMD balance
and prevents fee delivery from blocking an otherwise valid swap, including a fresh manager seeded
only with the launch token. The fee stays denominated in IMD and is not waived or redirected.

`pendingFees()` reports those claims. Anyone can call `flushFees()` outside an existing manager
unlock. It burns the claims and transfers IMD only to the same fixed vault, emitting
`FeesFlushed(amount)`. A failed redemption reverts atomically and preserves the claims. A zero
balance is a successful no-op. Redemptions process at most `2^127 - 1` minor units per call to
respect v4's signed-delta bounds. No caller can select a recipient, approve claims, or take a reward.

“Never reverts a real swap” means no hook policy, time gate or failed fee payout rejects a valid,
funded v4 swap, whatever order the router uses for `sync` / `swap` / `settle`. Invalid price limits, inadequate router funds, slippage checks, insufficient gas,
nonstandard IMD transfers to the trader, and v4 numeric bounds still apply. In particular the
exact-output request plus its specified fee must fit `int256`, and final balance deltas must fit
`int128`. No contract can force a third-party token to transfer when that token refuses.

## After launch

There are **no setters or privileged operational actions**. Neither the vault, factory, deployer,
an end user nor a router can change the addresses, rates, permissions, token supply or code.
There is no owner, admin, pause, blacklist, proxy, fallback or upgrade function.

- The network deployer supplies and verifies the actual manager and token arguments, mines the
  permission bits, opens the policy pool and handles launch allocations and source verification.
- The existing vault is responsible for its weekly distribution policy. This hook only delivers IMD.
- Anyone may monitor `FeeDeferred` / `pendingFees()` and call `flushFees()` when token delivery and
  manager balances permit. No keeper is needed for normal direct payments; no automatic weekly job
  is introduced. An unrecoverable failure at the immutable recipient cannot be repaired by redirecting it.
- LP fee collection with a zero liquidity change, liquidity removal and donations remain normal v4
  operations. All liquidity and donation callback flags are disabled, so the hook cannot tax or block them.
- Tokens mistakenly transferred directly to the hook cannot be swept. The recovery function only
  redeems the manager's IMD claims. Treat these contracts as immutable after deployment.

## Build and check

All dependencies are vendored as ordinary files under `lib/`, with licenses and pinned commits in
[`docs/dependencies.json`](docs/dependencies.json). No submodules, package installation or network
access are needed for the default suite. Foundry pins Solidity **0.8.26**, Cancun, optimizer 200 and
`bytecode_hash = "none"`. FFI and filesystem permissions are not enabled.

```sh
forge build
forge test
forge fmt --check
```

The configured fuzz seed is
`0x445f0d4d60f0d68f933b0b2981ca523be10a166990570ed4bcd004c70a950adc`.
Fuzz tests run 1,000 cases each. The two invariant suites each run 128 sequences of 32 actions,
mixing swaps, failed delivery, redemption and advancing blocks/time. They track the vault's paid
fees plus outstanding claims, token conservation and zero manager debts. Tests are isolated and
do not read or mutate environment variables.

The offline suite explicitly skips the two fork fixtures when no active fork exists. Run the
Robinhood suite separately, using the Pinax endpoint listed by
[Robinhood](https://docs.robinhood.com/chain/connecting/):

```sh
forge test --match-path test/RobinhoodFork.t.sol \
  --fork-url https://robinhood.rpc.pinax.network \
  --fork-block-number 108268099
```

The fork suite uses the actual deployed IMD, vault and PoolManager, whose address was checked
against [Uniswap's deployment record](https://github.com/Uniswap/contracts/blob/main/deployments/4663.md)
and on-chain code. The tests deploy a new test token/hook/pool and fund only a test actor using
Foundry balance setup; they never replace external contract code or modify production state.
Robinhood's `block.number` is its **L1** number; the pinned L2 block is checked through its L1
number and timestamp. See [`docs/VALIDATION.md`](docs/VALIDATION.md) for recorded results and scope.
An archive-capable endpoint is required for this historical block. Robinhood's general public RPC
passed all eight fork tests initially but subsequently returned `historical state ... is not available`.
Pinax served the same block and code-hash evidence, but its test rerun hit HTTP 429 (`Free tier rate
limit exceeded`). That rerun is not counted as a pass. On 2026-11-07, after the sync-first fix, a scratch copy of
the same suite with only the two pinned-header assertions removed passed all eight tests against
the public RPC at its latest block, 108,318,098; the pinned block was still unavailable there. An RPC's future availability is not a
prerequisite for the offline suite.

The source review and tests are not an independent security audit. The network's independent
review remains a release responsibility.
