# Kolan Launchpad

**Kolan's mechanism, for any token: launch one, and every buyer gets a way out.**

[Website](https://kolan.c0llback.com/launchpad) · [Kolan](https://github.com/c0llback/kolan-contracts) ·
[Docs](https://kolan.c0llback.com/docs) · [X](https://x.com/kolan_protocol)

Anyone launches a token in one transaction, with a supply of their choosing: 1
million, 1 billion or 10 billion tokens. It opens on its own Uniswap v4 pool, with
the whole supply in it and liquidity nobody can take out, and any purchase of it can
carry a window: until the window ends, the buyer can undo the purchase and get back
every wei of the ETH spent on the tokens. While it runs, the buyer can buy it more
time.

Every launch is a Kolan hook of its own — Kolan's code, line for line — with three
differences: the fee is split between the token's dev and the launchpad, the premium
buys back KLN as well as the token, and a window can be extended.

---

## Deployments

| | Launchpad | Source | |
|---|---|---|---|
| **v2** | [`0x7144B37F8d77dcc76Af9b1ED84E5643e67A8d714`](https://etherscan.io/address/0x7144B37F8d77dcc76Af9b1ED84E5643e67A8d714) | this branch | new launches |
| v1 | [`0x8F89905624E3613b3A578Ff1EC690463A33e940e`](https://etherscan.io/address/0x8F89905624E3613b3A578Ff1EC690463A33e940e) | [`fa4ed06`](https://github.com/c0llback/kolan-launchpad-contracts/tree/fa4ed0665f5a4f873f61c152bbc1fc17ea35ac94) | its launches still trade |

v2's window extension, which every v2 hook delegatecalls, is at
[`0xc4eC845C40601AFbddBaF324e4842183D8CaB4f4`](https://etherscan.io/address/0xc4eC845C40601AFbddBaF324e4842183D8CaB4f4).
Both Launchpads are on Ethereum mainnet. Neither can be changed or paused, so v1 and
its launches run exactly as they did: the site lists both, marked v1 and v2.

What v2 adds:

- **Extending a window.** The buyer who owns an open window can buy it more time,
  at the rate it was opened at, until it has run 7 days in all. v1's windows keep
  the length they were bought with.
- **A choice of supply.** A creator picks 1,000,000, 1,000,000,000 or
  10,000,000,000 tokens. Every supply opens at the same market cap, so a larger one
  is a cheaper token, not a larger launch: the same ETH buys the same share of any
  of them. Every v1 launch has 1,000,000.

Nothing else changed: the fee, its split, the buybacks, the window rules and the
liquidity are v1's.

## How it works

### A hook per launch

`Launchpad.launch` deploys the launch's `LaunchHook`, which creates its token, and
has it open the token's pool with the whole supply in it, tokens only, at the
opening price of the supply chosen. One hook, one token, one pool, one record of its
liquidity: no launch shares anything with another, so nothing one launch does can
reach another's windows, ETH or fee.

The hook is deployed with CREATE2, at a salt mined so that its address carries the
permissions Uniswap reads off it. The code it deploys names its creator and its
supply, so a salt mined for one creator, or for one supply, is of no use for any
other, and a salt that misses the permissions is refused (`BadSalt`). A supply the
Launchpad does not offer is refused too (`BadSupply`).

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
3. **Extending a window.** `extend(id)`, which Kolan's hook does not have: see
   below.
4. **The launch.** Only the Launchpad can call `launch`, once, with the opening
   price of the supply chosen and the creator's optional first purchase.
5. Kolan's stubs for the callbacks the hook never registers are left out: Uniswap
   never calls them, and the hook needs the room to stay under 24 KB.

### Extending a window

A window is priced by its length: 0.05 ETH of premium buys 6 hours, and the premium
is spent when the window closes. `extend(id)` buys an open window more time at that
same rate: `msg.value` is the premium added, and the window ends that much later.
Only the window's owner can extend it, and only before it ends; an expired window
is closed, not extended.

The window's whole length, counted from its opening, stays at most `MAX_WINDOW`
(7 days), and its whole premium at most `MAX_PREMIUM_BPS` (30%) of the ETH it
holds, as when it is bought. A premium that would buy past 7 days buys up to it, and
the rest is sent back. The premium added joins the window's own: it is held by the
hook, counted in its solvency check, and spent with the rest when the window closes,
half on KLN and half on the token. Like any premium, it is never refunded.

The hook is 21 bytes under the 24 KB limit, and extending does not fit in it. Its
`extend` relays the call, by `delegatecall`, to `WindowExtension`: one contract,
deployed by the Launchpad in its constructor and shared by every hook it launches,
which holds nothing and has no parameters of its own. It runs in the hook's storage,
reads the window rules off the hook, and takes the same reentrancy lock as `buy`,
`cancel` and `accept`. It reaches the hook's `held` and `windows` at their storage
slots, 4 and 5, which the tests read back on a live hook.

### The Launchpad

The factory. It holds the hook's creation code, too large for one contract, as a
blueprint in two data contracts, and deploys a hook from it for every launch. It
deploys the window extension every hook shares, keeps the supplies it offers and
the opening price of each, keeps the list of hooks, finds a launch's hook by its
token, records the block each one was launched in and the supply it was launched
with, and pays the treasury from many hooks in one transaction.

## Parameters

| | |
|---|---|
| Supply | 1,000,000, 1,000,000,000 or 10,000,000,000 tokens, chosen at launch and fixed. Nothing can mint more; anyone can burn their own. |
| Pool | native ETH / the token, LP fee 0, tick spacing 10 |
| Opening market cap | the same for every launch and every supply, fixed in ETH when the Launchpad was deployed: 3.97 ETH, about $10,000 then |
| Fee | 1% of the ETH side: half to the token's dev, half to the launchpad's treasury |
| Premium | half buys back and burns KLN, half buys back and burns the token |
| Window | 6 hours per 0.05 ETH of premium, when it is bought and when it is extended |
| Window bounds | 30 minutes to 7 days, extensions included |
| Premium cap | 30% of the ETH the purchase spends, extensions included |

All are immutables of the Launchpad and of every hook: no function can change them.

## Contracts

```
src/
  Launchpad.sol         the factory: deploys each launch's hook, keeps the list and
                        the supplies, emits what a launch says, pays the treasury
                        from many hooks at once
  LaunchHook.sol        Kolan's hook, one per launch: the token, the pool, the fee
                        and its split, the windows, the buybacks
  WindowExtension.sol   extending a window, delegatecalled by every hook
```

Imported unmodified from [kolan-contracts](https://github.com/c0llback/kolan-contracts):
`LiquidityBook.sol` and `KolanToken.sol`.

Where to look first: [`LaunchHook._tax`](src/LaunchHook.sol) is the fee's split,
[`LaunchHook._spendPremium`](src/LaunchHook.sol) the premium's,
[`WindowExtension.extend`](src/WindowExtension.sol) more time for a window, and
[`Launchpad.launch`](src/Launchpad.sol) a launch.

## Interface

### The Launchpad

| Function | Who | What it does |
|---|---|---|
| `launch(name, symbol, supply, uri, buyEth, salt)` | anyone | Deploys a token's hook at `salt` and opens its pool with `supply` tokens, one of `supplies()`. The caller is the token's dev; `buyEth`, if any, is their first purchase. Returns `(token, hook, bought)`. |
| `claimTreasury(hooks)` | anyone | Pays the treasury its half from every hook listed that owes it. |

`launch` takes as value the first purchase, the tax on it, and a few wei that keep
the pool's liquidity live at the opening price; the rest is refunded:

```
msg.value = buyEth + buyEth × TAX_BPS / 10_000 + 10_000
```

| Reading | Returns |
|---|---|
| `supplies()`, `openTickOf(supply)` | the supplies a creator picks from, and the tick each one's pool opens at |
| `initCode(name, symbol, supply, creator)`, `initCodeHash(…)` | the code a launch deploys, and its hash: the salt is mined against it, CREATE2 from the Launchpad, until the address's low 14 bits are `LaunchHook.FLAGS` |
| `launchCount()`, `hookAt(i)`, `hooksBetween(from, to)` | the launches, by their hooks |
| `hookOf(token)`, `launchedAt(hook)`, `supplyOf(hook)` | a token's hook, the block it was launched in, and its supply |
| `kln()` | Kolan's pool, where half of every premium buys KLN |
| `WINDOW_EXTENSION` | the window extension every hook delegatecalls |
| `TREASURY`, `TAX_BPS`, `REFERENCE_PREMIUM`, `BASE_WINDOW`, … | the parameters |

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
| `extend(id)` | the window's owner, before it ends | Buys window `id` more time: `msg.value` is the premium added, 0.05 ETH per 6 hours. Returns the new expiry. |
| `claimTreasury()` | anyone | Pays the treasury's half collected so far to `TREASURY`. |
| `treasuryOwed()` | — | The treasury's half collected and not yet paid. |
| `EXTENSION` | — | The window extension `extend` delegatecalls. |

`extend` is refused for a window that does not exist (`NoWindow`), by anyone but its
owner (`NotOwner`), once it has ended (`WindowExpired`), when it already runs 7 days
(`AlreadyLongest`), for a premium too small to add a second (`PremiumTooLow`), and
past the premium cap (`PremiumTooHigh`).

Events: Kolan's `Taxed`, `DevPaid`, `WindowOpened`, `WindowClosed` and
`Launched` (with what the creator bought), and `WindowExtended(id, premium,
expiry)`, `TreasuryPaid` and `KlnBurned`. After an extension, a window's expiry is
the one in its last `WindowExtended`, or `windows(id)`: `WindowOpened` gives the
expiry it was bought with.

## What the code guarantees

- **No owner.** Nothing is upgradeable, pausable or ownable, and no function
  changes a parameter. The treasury is fixed when the Launchpad is deployed, and
  each token's dev when it is launched; both only ever receive their half of the fee.
- **Locked liquidity.** As on Kolan: only the hook can open its pool, add liquidity
  or donate to it, and the only liquidity it ever takes out is a window's tokens,
  which go to the buyer who paid for them or back into the pool.
- **Solvency.** Every hook tracks the ETH and tokens of its open windows and checks
  after every `buy`, `cancel`, `accept` and `extend` that it still holds them.
- **Exact refunds.** `cancel` returns exactly the ETH the window spent on tokens,
  however many times the window was extended.
- **Time only moves forward.** `extend` only lengthens a window, only for its
  owner and only while it runs, within the same bounds and cap as a purchase.
- **Launches apart.** Each launch is its own hook: no launch can spend another's
  window, ETH or fee. The window extension they share holds nothing and runs in the
  storage of the hook that calls it.
- **A refund never waits on Kolan's pool.** The KLN half of a premium is a swap on
  another contract, tried, with the token as its fallback.
- **Bounded work.** A window touches at most 16 ranges of liquidity, as on Kolan;
  extending it touches none.

The contracts are tested — Kolan's own tests, every refund exact and every token
accounted for under random sequences, extensions included, on 1 million and on 10
billion tokens, and each launch run side by side with Kolan's hook to the same
outcome — but they are not audited.

## Building

The dependencies go in `lib/`, at the versions the contracts were built with:

| | |
|---|---|
| `lib/openzeppelin-contracts` | [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) v5.7.0, `cab19933` |
| `lib/v4-core` | [Uniswap v4 core](https://github.com/Uniswap/v4-core), `46c68346` |
| `lib/kolan-contracts` | [Kolan](https://github.com/c0llback/kolan-contracts), `fcdf858a` |

Solidity 0.8.26, via-IR, 200 optimizer runs, Cancun. `forge build` compiles the
same code as the deployment's build; only the metadata hash at the end of the
bytecode differs, as it records the source paths. The exact sources are verified on
Etherscan.

## License

Business Source License 1.1 (`BUSL-1.1`), with no additional use grant. It
converts to MIT on 2030-09-23.
