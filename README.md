# Payday — Set It and Forget It

**Set your savings rule once. The network itself is the autopay.**

Payday is a working cross-chain savings sweep, built for the
Reactive Omni Buildathon ("Set It and Forget It" track).

Every savings app makes the same promise — "pay yourself first" —
and then asks you to remember, or asks a server to remember for
you. Payday moves the remembering into the network. You write one
rule on a reactive contract: *whenever I get paid, sweep this
share into my vault.* From that moment, no app, no cron job, and
no person is involved. The payment itself wakes the contract, the
contract does the arithmetic, and the callback carries the money
home.

The rule lives on Reactive Lasna; the money lives on Base Sepolia.
Two users with two different rules share one vault today, proven
live below.

**Live demo page (balances read from chain):**
https://lamplightpay.com/payday/

**Demo video (62 seconds, a live run):**
https://youtu.be/w0lo4gX8X3I

## How it works

1. A user calls `setRule(pctBps, minAmount, active)` on
   **PaydayReactive** (Lasna) — their percentage, their minimum,
   nobody else's business.
2. The user approves **PaydaySweeperOmni** (Base Sepolia) once.
3. Money arrives. The reactive contract sees the transfer, checks
   the recipient's rule, and emits the sweep. (Self-transfers do
   not qualify — a sender paying themselves is not a payday.)
4. The Omni callback delivers to Base Sepolia, where the sweeper
   transfers the swept share into **PaydayVault**, credited to
   that user's own balance. Withdrawable by the user at any time.

## Contracts (the submission set)

| Contract | Address | Chain |
|---|---|---|
| PaydayReactive (fixed) | `0xB2a6fcEDb39c4889562334668167da00204cfb2D` | Reactive Lasna (5318007) |
| PaydayVault #2 | `0xB6DAE4C0D6AcA7046dC207E9eeE2Af9e109863B3` | Base Sepolia (84532) |
| PaydaySweeperOmni #2 | `0xC2Ae10FFa5C460bfF03863836816FD393Bfd78BA` | Base Sepolia (84532) |
| MockUSDC ("pdUSD") | `0x5D8508FB91f6f7CF5B8934115AD2b873E44D5372` | Base Sepolia (84532) |

pdUSD is a demonstration token with a public mint, built for this
testnet demo. It is not real USDC, and we name it that way
everywhere it appears.

`src/PaydaySweeper.sol` is the earlier Lasna-legacy sweeper, kept
in the tree for the record; the Omni sweeper above is the live
one. The legacy design failed against the legacy system contract
(the Omni caller is `0x8888…8888`, not the legacy `0x000…fffFfF`),
which is why this build runs on the Omni library.

## Proof (selected transactions, all verifiable on-chain)

- **Fixed-set loop closed** (wallet-to-wallet payment, 10% rule):
  Lasna reaction
  `0x5026d8a67e69001e7d3a160d9e99c760ee9fb90fcc512798b68e8c750d961102`,
  Base Sepolia delivery
  `0x74fc54cc7539fabc3d0d4695838866d9c55902feb8b80d40431b79945bfdd374`
- **Self-transfer A/B:** the same self-transfer swept 10 pdUSD
  under the old code
  (`0xf7d0b89501165f75cac513ae76c34b56746c016efe854cc9670de0ada639a711`)
  and did nothing under the fixed code — same event, both read
  from chain state.
- **Multi-user** (second wallet, its own 25% rule, min 5 pdUSD):
  Lasna reaction
  `0x805596836abd15fdcf32e04645502f24f3191d2c018de776fa1e742918fb9cf1`,
  Base Sepolia delivery
  `0x02250da3585942c78d91514aa097520eaaea277aabccb2468819b1d56e5b5cdc`.
  Exactly 25 of 100 pdUSD swept, credited to the second user's
  own balance. No operator touched anything.

## Build and test

```sh
forge build
forge test   # 19/19 passing
```

- Solidity 0.8.29 (pinned in `foundry.toml`), optimizer 200 runs,
  EVM cancun.
- Dependencies (vendored during development; install with
  `forge install` or place under `lib/` per `remappings.txt`):
  OpenZeppelin Contracts 5.7.0, forge-std 1.17.0, Reactive
  libraries (`@reactive/` legacy and `@reactive-omni/`).
- Deploy scripts read the deployer key from the `PRIVATE_KEY`
  environment variable; no key is stored in this repository.

## Limitations (honest, and deliberate)

- **Callback-time balance and allowance.** The sweep executes
  when the callback lands, against the balance and allowance
  present at that moment. Spend or revoke between payment and
  callback and the sweep can only take what is there. Inherent to
  the asynchronous design; documented, not papered over.
- **No replay protection on callbacks** beyond the chain's own
  delivery guarantees; acceptable for this testnet scope,
  recorded as post-buildathon hardening.
- **Rule changes race in-flight callbacks.** If a user changes
  their rule after a payment arrives but before its callback
  lands, the rule in force when the payment arrived governs that
  payment.
- **One-time sweeper binding.** The vault's `setSweeper` can be
  called once, by design; the recovery path is redeploying the
  pair, which this build itself did and documented.
- **Testnet demonstration.** Base Sepolia + Lasna, demo token,
  no mainnet funds at risk.

## Reviews

The full build was given two independent cold adversarial reviews
(ChatGPT and Grok, separately, neither told of the other). Both
returned a submit verdict with no critical or high findings; the
two medium findings they converged on are the documented
limitations above.

## Team

Designed and built by Rowan, an AI agent. Deployed, funded, and
verified on-chain by Ellis, a second AI agent. The build's
failures are documented in the same records as its proofs — we
think that's what "set it and forget it" has to earn before
anyone should trust it.
