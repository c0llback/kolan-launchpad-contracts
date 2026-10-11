# Kolan Launchpad

**Kolan's mechanism, for any token: launch one, and every buyer gets a way out.**

[Website](https://kolan.c0llback.com/launchpad) · [Kolan](https://github.com/c0llback/kolan-contracts) ·
[Docs](https://kolan.c0llback.com/docs) · [X](https://x.com/kolan_protocol)

Anyone launches a token in one transaction. It opens on its own Uniswap v4 pool,
with the whole supply in it and liquidity nobody can take out, and any purchase of
it can carry a window: until the window ends, the buyer can undo the purchase and
get back every wei of the ETH spent on the tokens.

Every launch is a Kolan hook of its own — Kolan's code, line for line — with two
differences: the fee is split between the token's dev and the launchpad, and the
premium buys back KLN as well as the token.

---

## How it works

### A hook per launch

`Launchpad.launch` deploys the launch's `LaunchHook`, which creates its token, and
has it open the token's pool with the whole supply in it, tokens only, at the same
opening price for every launch. One hook, one token, one pool, one record of its
liquidity: no launch shares anything with another, so nothing one launch does can
reach another's windows, ETH or fee.

The hook is deployed with CREATE2, at a salt mined so that its address carries the
permissions Uniswap reads off it. The code it deploys names its creator, so a salt
mined for one creator is of no use to anyone else, and a salt that misses the
permissions is refused (`BadSalt`).

The creator may buy first, in the same transaction (`buyEth`): a plain swap by the
hook, so nobody can buy ahead of it, taxed like any other and without a window.
Whoever launches the token is its dev, for good.

What a launch says about itself — a description, a picture, links — is the `uri`,
emitted in `Launched` and never stored. The picture travels inline, as a `data:`
URI of a few kilobytes, so a launch depends on nothing hosted anywhere.

### What is Kolan's

`LaunchHook` is Kolan's `KolanHook`. It inherits Kolan's `LiquidityBook` and
creates Kolan's `KolanToken`, both imported unmodified from
[kolan-contracts](https://github.com/c0llback/kolan-contracts). The windows
(`buy`, `cancel`, `accept`), the record of the liquidity, the tax, the solvency
checks, the storage and the events are Kolan's: Kolan's README explains how a
window takes tokens out of the pool and where they go back.

What differs:

1. **The fee.** 1% of the ETH side of every swap and of what every window spends,
   as on Kolan, but half to the token's dev and half to the launchpad's treasury
   (`DEV_SHARE_BPS = 5_000`). Both are booked as ERC-6909 claims during the swap
   and paid in ETH by `claimDev()` and `claimTreasury()`: two functions, so a dev
   whose address refuses ETH can never block the treasury's payout, nor the other
   way round.
2. **The premium.** When a window closes, half of its premium buys KLN on Kolan's
   own pool and the rest buys the launch's token on its pool, and both are burned
   (`KLN_SHARE_BPS = 5_000`). The KLN swap is tried rather than trusted: if Kolan's
   pool ever refused it, its half would buy the token instead and the window would
   close all the same.
3. **The launch.** Only the Launchpad can call `launch`, once, with the creator's
   optional first purchase.
4. Kolan's stubs for the callbacks the hook never registers are left out: Uniswap
   never calls them, and the hook needs the room to stay under 24 KB.

### The Launchpad

The factory. It holds the hook's creation code, too large for one contract, as a
blueprint in two data contracts, and deploys a hook from it for every launch. It
keeps the list of hooks, finds a launch's hook by its token, records the block each
one was launched in, and pays the treasury from many hooks in one transaction.

## Parameters

| | |
|---|---|
| Supply | 1,000,000 tokens a launch, fixed. Nothing can mint more; anyone can burn their own. |
| Pool | native ETH / the token, LP fee 0, tick spacing 10 |
| Opening market cap | the same for every launch, fixed in ETH when the Launchpad is deployed |
| Fee | 1% of the ETH side: half to the token's dev, half to the launchpad's treasury |
| Premium | half buys back and burns KLN, half buys back and burns the token |
| Window | 6 hours per 0.05 ETH of premium |
| Window bounds | 30 minutes to 7 days |
| Premium cap | 30% of the ETH the purchase spends |

All are immutables of the Launchpad and of every hook: no function can change them.

## Contracts

```
src/
  Launchpad.sol    the factory: deploys each launch's hook, keeps the list, emits
                   what a launch says, pays the treasury from many hooks at once
  LaunchHook.sol   Kolan's hook, one per launch: the token, the pool, the fee and
                   its split, the windows, the buybacks
```

Imported unmodified from [kolan-contracts](https://github.com/c0llback/kolan-contracts):
`LiquidityBook.sol` and `KolanToken.sol`.

Where to look first: [`LaunchHook._tax`](src/LaunchHook.sol) is the fee's split,
[`LaunchHook._spendPremium`](src/LaunchHook.sol) the premium's, and
[`Launchpad.launch`](src/Launchpad.sol) a launch.

## Interface

### The Launchpad

| Function | Who | What it does |
|---|---|---|
| `launch(name, symbol, uri, buyEth, salt)` | anyone | Deploys a token's hook at `salt` and opens its pool. The caller is the token's dev; `buyEth`, if any, is their first purchase. Returns `(token, hook, bought)`. |
| `claimTreasury(hooks)` | anyone | Pays the treasury its half from every hook listed that owes it. |

`launch` takes as value the first purchase, the tax on it, and a few wei that keep
the pool's liquidity live at the opening price; the rest is refunded:

```
msg.value = buyEth + buyEth × TAX_BPS / 10_000 + 10_000
```

| Reading | Returns |
|---|---|
| `initCode(name, symbol, creator)`, `initCodeHash(…)` | the code a launch deploys, and its hash: the salt is mined against it, CREATE2 from the Launchpad, until the address's low 14 bits are `LaunchHook.FLAGS` |
| `launchCount()`, `hookAt(i)`, `hooksBetween(from, to)` | the launches, by their hooks |
| `hookOf(token)`, `launchedAt(hook)` | a token's hook, and the block it was launched in |
| `kln()` | Kolan's pool, where half of every premium buys KLN |
| `TREASURY`, `SUPPLY`, `OPEN_TICK`, `TAX_BPS`, … | the parameters |

Event: `Launched(token, hook, creator, name, symbol, uri, bought)`.

### A launch's hook

Kolan's interface — `buy`, `cancel`, `accept`, `claimDev`, `quote`, `windowFor`,
`windows`, `cutsOf`, `held`, `devOwed`, `poolKey`, `poolId` — with the same value
for `buy`:

```
msg.value = eth + eth × TAX_BPS / 10_000 + premium + 1_000
```

and, of its own:

| Function | Who | What it does |
|---|---|---|
| `claimTreasury()` | anyone | Pays the treasury's half collected so far to `TREASURY`. |
| `treasuryOwed()` | — | The treasury's half collected and not yet paid. |

Events: Kolan's `Taxed`, `DevPaid`, `WindowOpened`, `WindowClosed` and
`Launched` (with what the creator bought), and `TreasuryPaid` and `KlnBurned`.

## What the code guarantees

- **No owner.** Nothing is upgradeable, pausable or ownable, and no function
  changes a parameter. The treasury is fixed when the Launchpad is deployed, and
  each token's dev when it is launched; both only ever receive their half of the fee.
- **Locked liquidity.** As on Kolan: only the hook can open its pool, add liquidity
  or donate to it, and the only liquidity it ever takes out is a window's tokens,
  which go to the buyer who paid for them or back into the pool.
- **Solvency.** Every hook tracks the ETH and tokens of its open windows and checks
  after every `buy`, `cancel` and `accept` that it still holds them.
- **Exact refunds.** `cancel` returns exactly the ETH the window spent on tokens.
- **Launches apart.** Each launch is its own hook: no launch can spend another's
  window, ETH or fee.
- **A refund never waits on Kolan's pool.** The KLN half of a premium is a swap on
  another contract, tried, with the token as its fallback.
- **Bounded work.** A window touches at most 16 ranges of liquidity, as on Kolan.

The contracts are tested — Kolan's own tests, every refund exact and every token
accounted for under random sequences, and each launch run side by side with Kolan's
hook to the same outcome — but they are not audited.

## Building

The dependencies go in `lib/`, at the versions the contracts were built with:

| | |
|---|---|
| `lib/openzeppelin-contracts` | [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) v5.7.0, `cab19933` |
| `lib/v4-core` | [Uniswap v4 core](https://github.com/Uniswap/v4-core), `46c68346` |
| `lib/kolan-contracts` | [Kolan](https://github.com/c0llback/kolan-contracts), `46b7688b` |

Solidity 0.8.26, via-IR, 200 optimizer runs, Cancun. `forge build` compiles the
same code as the deployment's build; only the metadata hash at the end of the
bytecode differs, as it records the source paths. The exact sources are verified on
Etherscan.

## License

Business Source License 1.1 (`BUSL-1.1`), with no additional use grant. It
converts to MIT on 2030-09-23.
