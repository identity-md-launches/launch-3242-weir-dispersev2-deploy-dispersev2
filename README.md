# Weir Disperse

`src/Disperse.sol`: pays many recipients one ERC-20 in a single transaction on Robinhood Chain (chain id 4663,
Arbitrum Orbit). The Weir app uses it to pay several contest winners at once from the admin's own wallet, in USDG,
WEIR, IMD, WETH or any other plain ERC-20. The product never holds the money: funds move straight from the caller
to each recipient.

The source is byte-for-byte the `Disperse` already live on Base and Base Sepolia at
`0x320418D854f3eD0E59e691dD7c767A22B8E5C9E9` (pay-usdc). Nothing in it is chain or token specific.

**Not audited.** Tests and a swarm review are not an audit.

## Contract

- `disperse(token, to[], amounts[])`: `transferFrom(msg.sender → to[i], amounts[i])` for every row. Needs a prior
  approval of at least the sum.
- `disperseWithPermit(token, to[], amounts[], deadline, v, r, s)`: same, with an EIP-2612 permit for exactly the
  sum. `permit` is wrapped in `try/catch`, so a front-run replay of the signature cannot block the send; the
  allowance check afterwards is the real gate. When the permit fails AND the allowance is short, the permit's own
  revert reason is bubbled. On a token without `permit`, pass zeros and approve first.
- `sumOf(to[], amounts[])`: view helper, same validation, returns the total.
- Reverts: `Empty`, `LengthMismatch`, `ZeroRecipient(i)`, `SelfRecipient(i)` (the Disperse contract itself),
  `ZeroAmount(i)`, `InsufficientAllowance(needed, have)`.
- One event per call: `Dispersed(sender, token, total, count)`. Per-recipient detail is in the token's own
  `Transfer` logs, each with `from` = the caller, which is what the app's payout check reads.

Properties: no constructor arguments, no owner, no fee, no pause, no upgrade, no rescue, no storage. The contract
never holds tokens, so reentrancy cannot move anything the caller did not already approve. Fee-on-transfer and
rebasing tokens are unsupported and undetected. A batch is atomic: one recipient the token refuses (a frozen USDG
address, an address on IMD's owner-controlled blocklist) reverts the whole call and nothing moves; the revert
does not say which row.

What the caller (the app) must do, because the contract does not:

- Filter recipients. Only `address(0)` and the Disperse address are rejected. The token's own address,
  `0x…dEaD`, pools and other contracts are paid like anyone else, and holder lists contain them.
- Simulate each batch first (`eth_call`) and split on a revert to find the refused row.
- Trust logs only from known tokens and from the recorded Disperse address. A made-up token can emit
  `Transfer` and `Dispersed` with nothing moved, and `Dispersed.total` is what was asked, not proof of receipt.

## Tokens on Robinhood Chain (checked on a fork, 2026-11-11)

| token | address | decimals | permit |
|---|---|---|---|
| USDG (Paxos Global Dollar) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | 6 | yes, EIP-2612: `disperseWithPermit` works in one transaction |
| WEIR | `0x58b82fa656ecf47a0dca5be6bad06b92e22f7dbe` | 18 | no: approve, then `disperse` |

IMD (`0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, 18 decimals, no permit) and SVO also deliver exact amounts.
None of the four charges a transfer fee. USDG is an upgradeable proxy, so its behaviour can change.

Gas with real USDG: about 34,200 per fresh-balance recipient all in, so 250 recipients is about 8.6M (node
estimate) against the chain's 32M per-transaction maximum. The app caps a batch at 250, splits larger lists and
asks the node for the estimate rather than using a constant.

## Build and test

```sh
forge build
forge test
forge fmt --check
# fork tests against real USDG and WEIR; skipped when the variable is unset
RH_RPC_URL=https://robinhood-rpc.publicnode.com forge test --match-contract DisperseForkTest -vv
```

32 tests: 26 unit and fuzz (mocks for a 6-decimals permit token, a no-return token, a plain token and a reentrant
token) and 6 fork tests (USDG, WEIR, IMD). `foundry.toml`, verbatim:

```toml
[profile.default]
src = "src"
test = "test"
out = "out"
libs = ["lib"]
solc = "0.8.26"
optimizer = true
optimizer_runs = 200
evm_version = "cancun"
via_ir = false
bytecode_hash = "none"
fs_permissions = []

[fuzz]
runs = 256

[profile.ci.fuzz]
runs = 2000

[rpc_endpoints]
robinhood = "${RH_RPC_URL}"
```

Dependencies are vendored under `lib/`: OpenZeppelin Contracts v5.5.0 and forge-std.

## Deploy

The IMD swarm deploys it from `launch.json` (kind `evm_contracts`, chain 4663, contract `Disperse`, no constructor
arguments) after auditing the repository as it arrived; the request is `docs/imd/launch-disperse-robinhood.json`
in the app repo. This folder is pushed to `weircool/disperse-contracts` as a subtree for that, as Townies is.

`script/Deploy.s.sol` is the owner's fallback: a deterministic CREATE2 deploy through the standard proxy at
`0x4e59b44847b379578588920cA78FbF26c0B4956C` (present on Robinhood Chain) that lands at the Base address
`0x320418D854f3eD0E59e691dD7c767A22B8E5C9E9`, refuses to broadcast if the bytecode drifted and skips when the
address already has code. A swarm deployment lands at the swarm deployer's own address instead; either works.

## Deployed

| chain | id | address | tx |
|---|---|---|---|
| Robinhood Chain | 4663 | `0x49959c0326c4dF604a4d62D46CCBAe3C056CC158` | [`0xeae6a300…`](https://robin.etherscan.io/tx/0xeae6a3002240dd9eac8272d9cc27ea116b749a8b7bafc5611bfd55b12fd2bff5) (block 112219060) |

Deployed 2026-11-12 by the IMD swarm as launch 3221 from commit `f402a3a855b2f8f1c97aa0ea9367ebc975327eb3` of
this repository, after its review panel reported nothing at medium or above (two informational notes, both
described above: the atomic batch and the permit replacing a standing allowance). That panel is a first filter,
not an audit.

The deployed code is the tested code: `cast keccak $(cast code <address> --rpc-url $RH_RPC_URL)` gives
`0xb65a4cb1e0ebc66ee4e7d80658ed75d5013b6c01d003638138623e0968ba43ca`, the same runtime as on Base (checked
2026-11-12).

The app reads the address from `src/lib/robinhoodChain.ts` and the ABI from `public/weir/abi/Disperse.json`,
written with `forge inspect src/Disperse.sol:Disperse abi --json`.
