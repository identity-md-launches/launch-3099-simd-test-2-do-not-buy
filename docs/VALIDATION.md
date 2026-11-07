# Validation record

Compiler: Solidity 0.8.26; EVM: Cancun; optimizer: 200 runs; metadata hash: none.
The exact requested fuzz seed is pinned in `foundry.toml`:
`0x445f0d4d60f0d68f933b0b2981ca523be10a166990570ed4bcd004c70a950adc`.

| Check | Result |
| --- | --- |
| `forge build` / `forge build --sizes` | Passed; hook runtime 6,324 bytes, token runtime 1,722 bytes, both below EIP-170. |
| `forge fmt --check` | Passed after `forge fmt`. |
| `forge test` | 59 passed, zero failures. Two fork **fixtures** are explicitly skipped with no active fork. |
| Local fuzzing | Nine fuzz tests, 1,000 cases each, including both currency orders, four swap modes, partial fills, initialized tick crossings and a differential core-swap comparison. |
| Stateful invariants | Two suites, each 128 runs × 32 calls; 8,192 total actions, zero unexpected reverts. |
| Initial Robinhood fork suite | Eight passed, zero failures, zero skips, at L2 block 108,268,099. |
| Fork suite at live head (2026-11-07) | Scratch copy with only the pinned-header assertions removed: eight passed, zero failures, at L2 block 108,318,098 on `https://rpc.mainnet.chain.robinhood.com`, including the sync-first fee fix. |
| Later fork reruns | General RPC: historical state unavailable. Pinax: HTTP 429, free tier rate limit exceeded. Neither rerun is counted as a pass. |

The local suites cover forbidden callbacks, wrong pools, invalid constructors/flags, tiny and extreme
amounts, empty liquidity, token-only manager reserves, reverting and false-returning transfers,
failed/retried claim redemption, routers that sync IMD before the swap, claim theft attempts, reentrancy attempts, settlement rollback,
fixed fees over time/blocks, no administrative redirection, LP fee collection, liquidity withdrawal,
fixed token supply and runtime escape-hatch checks.

The fork suite checks the actual deployed IMD token and vault with Uniswap's deployed manager:

```sh
forge test --match-path test/RobinhoodFork.t.sol \
  --fork-url https://robinhood.rpc.pinax.network \
  --fork-block-number 108268099
```

Pinned header:

- L2 block: `108268099` (`0x6740a43`)
- Hash: `0x8d0a9028f15930a70af6a07c9498faeabfa570608553ec24ff9c2efe83b8df42`
- L1 block exposed by `block.number`: `26361756`
- Timestamp: `0x6aeedff9`

[`fork-evidence.json`](fork-evidence.json) records external addresses, deployed code lengths and
code hashes read at that block. The first fork run passed on
`https://rpc.mainnet.chain.robinhood.com`; a repeat encountered `historical state ... is not available`.
Pinax served the identical block and code-hash evidence, but its test rerun stopped with HTTP 429:
`Free tier rate limit exceeded. Get a free API key at https://app.pinax.network`. No key or account
was requested or used. The initial eight-test passing run remains the successful fork evidence;
the failed infrastructure reruns are not represented as successful tests. Production logic did
not change between the successful fork run and those retries (only formatting and additional local
tests/documentation). Future fork runs need an endpoint retaining that historical state and enough
RPC capacity. Default `forge test` never contacts an RPC or consults an environment variable.

Fork funds are set up locally with Foundry's balance cheatcode. The new test pool is initialized
and funded on the fork using newly deployed TestToken/TestHook code. No external token, vault or
manager code is replaced; no live transaction is sent. These tests verify fee integration, not
factory allocation policy or the vault's weekly distribution implementation.

Foundry reports non-fatal heuristic lint warnings for checked/sign-constrained casts, the intentional
quotient/remainder fee formula, and events emitted after manager calls. Those patterns are explained
in the source and scoped security review; a warning-free external static analysis is not claimed.

All build dependencies are ordinary vendored files. No compiler binary, environment file, remote
dependency, submodule, FFI setting or filesystem permission is needed by the project. No independent
audit, Slither run, formal verification, deployed launch address or production transaction is claimed.
