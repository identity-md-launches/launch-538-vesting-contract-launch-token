# Launch Token vesting

Anyone holding the launch token can fund an irrevocable linear vesting schedule for
a beneficiary. Only that beneficiary can claim, and every claim goes directly to
that same address. There are no owners, administrators, revocation, pause, upgrade,
beneficiary-change, or withdrawal functions.

## Contracts and deployment parameters

| Artifact | Constructor arguments | Purpose |
| --- | --- | --- |
| `src/LaunchToken.sol:LaunchToken` | None | ERC-20 named **Launch Token**, symbol **TOKEN**, 18 decimals. Exactly 1,000,000,000 tokens (`10^27` minor units) minted to its deployer. |
| `src/TokenVesting.sol:TokenVesting` | `address token_` | The launch token address, bound immutably at deployment. Must be nonzero and have deployed code. |

The brief uses `$token` as the launch token reference and supplies no separate
branding; the name and symbol above are defaults. The token has no public mint,
burn, owner, fee, blocklist, or upgrade facilities. Vesting uses deposited existing
tokens and never creates additional supply.

Deploy `LaunchToken` first, then `TokenVesting` with the resulting token address.
For the project launch manifest, the application identifier is `TokenVesting` and
its constructor argument is `$token`. Both constructors are nonpayable and fully
configure their contracts; no initialization call is required. Neither constructor
grants control to `msg.sender`. The token mints to the deployment factory, and the
vesting constructor leaves the entire token supply there. The launch factory is
responsible for supply allocation and liquidity under its policy; the vesting
contract does not reserve or redirect any launch allocation.

No chain address, wallet, private key, or RPC endpoint is hard-coded. No deployment
or transaction broadcast is part of this project. The actual chain and `$token`
address must come from the launch handoff. `test/Deployment.t.sol` uses a local
factory stand-in to check constructor behavior, supply preservation, runtime size,
and absence of forbidden opcodes. It does not test the production factory's launch
policy or liquidity operations. `launch.json` belongs to the separate manifest step.

## Creating and claiming a schedule

1. Verify the deployed vesting contract and its `token()` address.
2. As the funder, call `LaunchToken.approve(vestingAddress, amount)` for the intended
   deposit, expressed in minor units (`1 TOKEN = 10^18` units).
3. From the same funder address, call
   `createSchedule(beneficiary, amount, start, cliff, duration)`.
4. Record the returned schedule ID, or read it from `ScheduleCreated`. IDs begin at
   1 and increase globally; obtain the actual ID from execution, not a prediction.
5. The beneficiary calls `claim(scheduleId)` when `claimableAmount(scheduleId)` is
   positive. It transfers the entire available amount and returns that amount.

| Argument | Meaning and constraints |
| --- | --- |
| `beneficiary` | Immutable payout address; nonzero and not the vesting contract itself. A contract beneficiary must be able to call `claim`. |
| `amount` | Positive deposit in minor units, entirely paid by the caller via `transferFrom`. |
| `start` | Absolute Unix timestamp in seconds; zero, past, current, and future starts are supported. |
| `cliff` | **Absolute Unix timestamp**, not a duration. Must satisfy `start <= cliff <= start + duration`. Use `cliff = start` for no cliff. |
| `duration` | Positive number of seconds measured from `start`. `start + duration` must fit in `uint256`. |

A schedule accrues from `start` even when claims are blocked by the cliff. For a
schedule amount `A`, at timestamp `t`:

```text
vested(t) = 0                                      if t < cliff
            A                                      if t >= start + duration
            floor(A * (t - start) / duration)       otherwise

claimable(t) = vested(t) - previously claimed
```

At the exact cliff, all accrual since `start` becomes available. A cliff equal to
the end locks the entire amount until the end. Backdated schedules can have an
immediate claim, and schedules already ended at creation can be claimed in full
immediately. For example, a 1,000 TOKEN schedule lasting 100 days with a 20-day
cliff makes 200 TOKEN available at the cliff, 500 TOKEN cumulatively at day 50,
and all 1,000 TOKEN at day 100.

Full-precision multiplication/division avoids intermediate overflow. Rounding is
down in minor units; all remaining dust is released at the end. Claim frequency
does not change total entitlement. Early, duplicate-without-new-accrual, and
fully-exhausted claims revert with `NothingToClaim`. Non-beneficiary claims and
unknown schedule IDs revert. Any transfer failure reverts the whole transaction,
including its accounting changes, so a valid unpaid claim remains retryable.

There is no automatic payout, third-party claim trigger, delegated payout address,
claim deadline, or keeper requirement. Multiple schedules for the same beneficiary
are independent. A funder may also be their own beneficiary. `getSchedule(id)`
returns the immutable terms and cumulative claimed amount;
`vestedAmount(id, timestamp)` is a cumulative historical/forecast view independent
of earlier claims. `totalLocked()` is the sum of all unpaid obligations, including
amounts already vested. `ScheduleCreated` and `Claimed` events support indexing;
on-chain operations never iterate over every schedule.

## Custody assumptions and operational responsibilities

- Use the delivered immutable `LaunchToken` as the configured asset. The constructor
  checks for code, not token identity. The deployer must verify this address and the
  deployed bytecode. Rebasing, outgoing transfer fees, dishonest balance reporting,
  and mutable or administratively restricted tokens are unsupported. SafeERC20
  handles missing/false return values, and exact incoming balance changes are checked,
  but those defenses do not make arbitrary tokens trustworthy.
- A funder must verify the beneficiary, amount, timestamps, and ability of the
  beneficiary to call the contract before depositing. There is no cancellation or
  correction path, even for mistakes. Approval alone does not create a schedule;
  only `createSchedule` funds one, always from its own caller.
- Beneficiaries manage their own keys or contract-wallet access and pay gas to
  claim. Lost access can permanently strand tokens. Claims follow chain timestamps,
  so they inherit the chain's timestamp precision and ordering assumptions.
- Tokens transferred directly to the vesting address create no schedule and no
  claim rights. Such donations, including unrelated tokens, cannot be recovered.
  Normal ETH transfers are rejected; forced ETH is also unrecoverable. No one has a
  rescue or sweep power. Monitor balance against `totalLocked` with donations kept
  separate: for the launch token, balance equals outstanding obligations plus
  unsolicited deposits.
- The deployment operator is responsible for chain selection, source/bytecode
  verification, correct constructor arguments, and publishing addresses and ABI.
  Interfaces should index creation events and verify schedule terms rather than
  treating an unsolicited schedule as proof of a relationship with its creator.
- An independent adversarial review is required before releasing a contract that
  holds other people's funds. These tests and the local deployment checks are not a
  security audit. Slither, Mythril, and live-chain integration checks were not run.

## Build and tests

Install Foundry and provision **Solidity 0.8.26** in its compiler cache. All project
dependencies are vendored as ordinary files in `lib/`; there are no submodules or
package-install steps. With the compiler provisioned, build and tests work without
network access. See `lib/DEPENDENCIES.md` for exact upstream versions and licenses.

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Paris EVM output, optimization at 200 runs, and
`bytecode_hash = "none"`. FFI and filesystem permissions are disabled. Tests use
local contracts and independent setup; they do not read or modify environment
variables, fork a network, or require wallet configuration.

The suite includes token supply/transfers/allowances, factory-style deployment,
schedule funding and authorization, cliff/start/end boundaries, retrospective
starts, rounding and final dust, multiple schedules, invalid parameters, failed
funding/payout rollback, fee and false/no-return token mocks, and reentrancy into
both entry points during deposits and payouts. Arithmetic includes maximum-width
inputs. Fuzz tests check transfer conservation and claim-frequency independence.
The stateful invariant campaign runs 128 sequences of 64 calls, interleaving funding,
time advances, claims, and donations across four actors. It checks immutable terms,
fully backed obligations, payout limits, and token conservation after every call,
then advances to maturity and settles all remaining claims after each sequence.

Local verification passed `forge build`, all 41 tests, and `forge fmt --check` with
Solidity 0.8.26. Foundry 1.8.3 emitted a `reentrancy-events` lint warning on `Claimed`.
On source review, that event follows the accounting updates and precedes the only
external call in `claim`. Both state-changing entry points use `nonReentrant`, and
the callback tests verify exclusion during funding and payout. The warning is
retained for reviewers rather than suppressed.
