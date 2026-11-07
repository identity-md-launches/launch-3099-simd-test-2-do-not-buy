# Scoped source review

This is a local implementation review, not an independent audit. The security boundary is the
immutable TestHook/TestToken code and its interaction with a correct Uniswap v4 PoolManager and
the specified IMD contract. The token and vault are external dependencies; their future behavior
cannot be controlled by this hook.

| Surface | Property and evidence |
| --- | --- |
| Configuration | Pair/vault/fee/LP tier/spacing are constants; manager/token/pool ID are immutable. No administrative inheritance, setters, fallback, upgrade or arbitrary execution path. |
| Callback authentication | Every implemented callback checks `msg.sender == poolManager`. The simulation checks `msg.sender == address(this)` and always reverts. Direct and token-reentrant forgery tests refuse both. |
| Pool binding | Full pool ID is derived in the constructor. Initialization rejects different currencies, fees, spacing or hook address. No mutable first-caller registration. |
| Initialization race | Required initialization permission makes initialization fail while the predicted hook has no code. Deployment and initialization must be atomic. No sender or initial-price gate can exclude the real factory. |
| Specified deltas | Only a proportional fee is returned; no user input is diverted wholesale and the core swap still executes. Partial fills are previewed with the same pool, direction and price limit. |
| Preview rollback | The manager sees the hook as caller and skips its callbacks. A deliberate revert rolls back core state. A checked selector and length prevent interpreting an unrelated failure as a fill. Tests compare real execution against an unhooked pool and cross initialized ticks. |
| Arithmetic | Rounding favors the trader. Quotient plus remainder computes `floor(amount * 75 / denominator)` without multiplication overflow. Signed absolute value handles `int256.min`. Narrow fee returns use v4 checked casts. Extreme partial requests and dust boundaries are tested. |
| Settlement | Returned fee credits exactly cancel `take`/`mint` debits. Per-trade and stateful tests assert zero transient debts and token conservation. Router-settlement failure rolls back both the pool swap and fee transfer. |
| Delivery failure | A reverted/false-returning IMD payment is replaced with an ERC-6909 claim. Local tests cover all four swap modes, lack of prefunded IMD and failed/retried redemption. |
| Redemption | Claims are burned before taking funds. Failure restores them. The recipient is constant. No claim allowance/operator authorization is issued, and attempts to transfer the hook's claims fail. |
| Reentrancy | There is no shared per-swap mutable hook state. Direct callbacks and the preview require authenticated callers. Calling `flushFees` from a token transfer encounters the manager's already-unlocked guard. Tests exercise both paths. IMD is not assumed to support ERC-777 or arbitrary callback semantics. |
| LP rights | Removal and donation hooks are disabled. Tests collect fees through a zero liquidity change and withdraw all liquidity after swaps, including on the live fork. |
| Runtime finality | Deployed runtime scans step over PUSH data and check reachable code for SELFDESTRUCT, DELEGATECALL and CALLCODE, matching the supplied admission test's approach. These scans are a floor, not a proof of security. |

There are no signatures, randomness, oracles, dynamic fees, conversion pools, time-dependent taxes,
or launch token transfer fees. No value depends on a caller-provided address in `hookData`.

The v4 manager and IMD implementation must be verified again by the launch deployer. The fork
tests establish their observed compatibility at the pinned block, not a promise about subsequent
external upgrades or protocol administration. A fee-on-transfer/rebasing IMD would violate the
exact-transfer assumption; the pinned fork checks actual vault balance increases.

The self-preview intentionally spends additional swap-computation gas for specified-IMD modes.
Its cost scales with the same tick traversal as the real swap. Callers must supply sufficient gas
and obey the manager's numeric limits; no gas-independent availability guarantee is possible.

No Slither or Mythril run, formal proof, external audit, factory deployment transaction or launch
allocation rehearsal is claimed. The network verifier supplies its own static and independent review.
