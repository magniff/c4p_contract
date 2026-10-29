# Security review: adversarial analysis

Scope: `Chess4Profit.sol`, `ChessEngine.sol`, the Python SDK and the dashboard. Assumed adversaries: hostile
players, spammers, contract wallets that misbehave on receiving ETH, block builders / sequencers that reorder,
delay or censor transactions, mempool watchers, and anyone able to poison a bot's configuration.
**This is a self-review with tests, not an audit.** Three passes were made; the second and third each found
real defects the previous one missed (listed honestly below), which is the strongest argument for an
independent audit before real money.

## Threat model in one paragraph

Money only moves in three ways: a stake in (`createGame`/`joinGame`), a stake back (`cancelGame`/`sweepExpired`),
and the pot out (`_finish`, via push-or-credit). Every other function only changes game state. So the questions
are: can anyone take money that isn't theirs (no owner, no admin, so only via game outcomes); can anyone lock
someone else's money for longer than that person agreed to; can anyone make a game unfinishable; and can the
*order* in which transactions land change any of those answers.

## Transaction ordering (pass 3)

Ordering is not guaranteed: two pending transactions land in either order, a builder can delay one, and a
third party can insert its own between them. `test/Ordering.t.sol` executes every racing pair in both orders.

| Race | Outcome, either order | Who can lose what |
|---|---|---|
| join vs join | first lands; second reverts `NotOpen` | loser: gas |
| cancel vs join | cancel first: join reverts. **Join first: cancel reverts and the creator is in a live game.** | creator: at most their own stake, and only if they then go offline |
| join vs stranger-cancel at expiry | same block = same timestamp, so exactly one is valid | gas |
| sweep vs join | expired games can't be joined; sweep only touches expired ones | gas |
| move vs move (same player) | only the side to move can act; replays/duplicates revert `NotYourTurn` | nothing |
| move vs claimTimeout at the clock boundary | valid at `elapsed == left`, claim valid at `>`: never both | nothing |
| resign vs opponent's mate / claim | whichever lands ends the game; the other reverts `NotActive`; same winner, paid once | nothing |
| delayed move (builder holds it past the deadline) | reverts with no state change | the timeout the player already incurred |
| random permutations of a bag of pending lobby txs (fuzz) | money conserved after every step; terminal state consistent | — |

The one race the contract cannot neutralise is **join-front-runs-cancel**: it *is* the ordering problem.
A mempool watcher who sees your `cancelGame` can front-run it with `joinGame`, trapping you at the table.
Its damage is bounded: they must lock an equal stake, the clock then runs for both, and if you are online you
simply play (the SDK's `play()` handles exactly this; see S1 below). It only pays against a creator who cancels
and then goes offline, which is the same exposure as "opened a table and walked away".

Things ordering **cannot** affect, by construction: the result of a position (deterministic), who the players
are after a join (immutable), the terms of a game (immutable after creation), the amount paid (computed from
stakes, not balances), and whether a payout happens twice (status is set before any transfer; every transfer
is push-with-cap-or-credit).

What was deliberately **not** adopted, and why:
- *Commit-reveal for moves.* Hides nothing useful: a chess move is public the moment it is played, and the
  opponent cannot act until it lands. It would double transaction count and add a reveal deadline to grief.
- *Commit-reveal or randomness for colour.* Replaced by creator-declares-colour. Any on-chain randomness read in
  the same transaction can be rejected by a contract joiner until it likes the result.
- *Private order flow / MEV protection.* Nothing here is sandwichable (no prices, no slippage). Recommend it
  only as an ordinary latency improvement for moves on L1.

## Found and fixed

### Pass 1
| # | Weakness | Fix | Test |
|---|---|---|---|
| 1 | Per-move timeout: an opponent could hold your stake for hours by using the whole timeout every move | Fischer clock (bank + increment) | `test_slowPlay_*`, `test_clock_*` |
| 2 | Colour from `prevrandao`: a contract joiner could revert until lucky | creator declares colour | `test_contractJoinerCannotPickColour` |
| 3 | Lobby = newest-100-ids; dust games hid honest ones | per-stake index (superseded in pass 3) | — |
| 4 | Open games lived forever; crashed bots left orphans | `OPEN_WINDOW` expiry; anyone can refund an expired game | `test_expiry_*`, `test_orphan_*`, `test_sweep_*` |
| 5 | Dust stakes | `MIN_STAKE` | `test_stakeBounds` |
| 6-10 | SDK: joined any clock; hung engine = forfeit; blind trust in contract address; no fee cap; no priority bump near deadline | join policy; engine deadlines + restart + fallback move; code-hash pinning; `max_fee_gwei`; `urgent` tip | `test_hung_engine_*`, `test_codehash_*`, `test_gas_price_cap_*` |

### Pass 2 (what pass 1 missed)
| # | Weakness | Fix | Test |
|---|---|---|---|
| C1 | **Pass 1 overclaimed.** The clock bank was only bounded for `increment == 0`; with increment a player could move fast, bank hours, then stall for days. The pass-1 test only used `inc = 0`. | bank capped at `MAX_BASE_TIME` | `test_clock_bankCannotBeHoardedBeyondMaxBaseTime` |
| C2 | `createGame`/`joinGame` lacked `nonReentrant` (unreachable only because payouts forward 50k gas) | added | — |
| S1 | **Loses the stake.** `Client.play()` called `cancel()` unguarded; if someone joined in that window the bot crashed with a live game and forfeited on time | cancel failure → check status → play the game | `test_cancel_race_*` |
| S2 | Own open game expired after 1h → bot waited forever | detect expiry, refund, reopen | `test_own_open_game_expiry_*` |
| S3 | **Loses the stake.** Engine spawned *after* staking; a bad binary raised out of the loop with a live game | engine validated before any stake moves | `test_engine_is_validated_*` |
| S4 | Nonce race when one `Client` is shared across threads | lock around nonce+send | `test_one_client_shared_*` |
| S5 | Clock math on local `time.time()`; a skewed clock meant thinking too long | chain time | — |
| S6 | Default join policy accepted a 30s-total clock, unplayable on-chain | realistic defaults | superseded by tables |
| S7 | After being flagged the bot retried the move every 200ms until the opponent claimed | stop after `TurnTimedOut` | `test_flagged_bot_*` |
| S8 | `codehash.json` read at import time, so the pin went stale across rebuilds | read at connect time | — |

### Pass 3 (ordering, spam economics, static analysis)
| # | Weakness | Fix | Test |
|---|---|---|---|
| C3 | **Cheap lobby flood.** Spam at *your* stake with clocks your policy rejects costs the attacker only gas: the stakes are refunded after an hour by `sweepExpired` (which the attacker can call). Those games still filled your bucket and hid honest tables, so honest bots never met. | lobby keyed by **table** = `(stake, baseTime, increment)`. Spam at your exact table is joinable, so it costs the spammer a stake per game somebody joins; spam anywhere else is invisible. | `test_flood_otherStakes_*`, `test_flood_sameTable_*`, `test_tables_isolate_matchmaking_from_spam` |
| S9 | **Reorg hang.** A move mined then reorged out left the SDK in `wait_for_transaction_receipt` for up to 180s *with the clock running* | receipt wait that notices a vanished tx (`TxDropped`) and returns to the loop | `test_reorg_that_drops_a_move_*` |
| S10 | A reorg that removed a move left the local board ahead of the chain; the loop could never resync | detect `plies < local` → rebuild from chain | same |
| S11 | Create/join defaults differed (`120+1` vs `300+2`), so a bot could open a table it would never join | one set of defaults; `play()` creates exactly the table it sits at | `test_two_bots_matchmake_*` |
| S12 | Ctrl-C with an open table left the stake locked until someone swept it | on interrupt: cancel; if that fails because someone joined, warn loudly that a live game exists | — |
| S13 | ABI read at import time (same bug as S8) | lazy | — |
| S14 | **Abandoned a won game.** If the opponent joined and resigned before the bot's next poll, `play()` saw `FINISHED`, treated it as "swept", opened a *new* table and waited there forever (found by a thread dump, not by reasoning) | `FINISHED` is a result to return; only `CANCELLED` reopens | `test_opponent_joins_and_resigns_instantly_*` |
| S15 | Any transient RPC exception inside the game loop killed the bot (forfeit); the HTTP provider had no timeout | 15s request timeout; transport errors are retried with backoff inside the loop | — |

### Pass 4 (verification depth and process)
| # | Gap | Fix |
|---|---|---|
| V1 | Stateful fuzzing was a hand-rolled loop | Foundry invariant suite (`test/Invariants.t.sol`): a handler exposes every action to random actors in random order with random time travel; money conservation, lobby-index exactness and per-game state consistency are re-checked after every call |
| V2 | `urgent` fee path never executed in tests (the flagged move failed at estimation first) | test asserts the mined tx carries 3x tip and that the fee cap applies to the bumped fee |
| V3 | "Resumes after a crash" was a docstring claim | test: fresh process attaches mid-game, replays history, finishes the game |
| P1 | No CI: every guarantee decayed on the next edit | `.github/workflows/ci.yml`: forge build+test, SDK tests on a real anvil, Slither failing on anything beyond the known-benign detectors |
| P2 | Unpinned Python dependencies (supply chain) | upper-bounded pins in `sdk/pyproject.toml` |
| P3 | Dead `FEE_PLACEHOLDER` constant | removed |

### Bot profiles (pass 5)
Profiles are untrusted text that other people's software renders, so they were designed against display attacks.
| Threat | Defence | Test |
|---|---|---|
| Markup / terminal / HTML injection through a **name** (`[link=…]`, `\x1b[2J`, `<script>`) | contract accepts only `[A-Za-z0-9 _.-]` | `test_injectionAndSpoofingNamesRejected`, `testFuzz_nameRule` |
| Look-alike names (`"Magnus "`, `"Mag  nus"`, homoglyphs) | no leading/trailing/double spaces, ASCII only | same |
| Control bytes in a **description** | contract rejects bytes < 0x20 and 0x7F | `test_controlBytesInDescriptionRejected` |
| Invisible Unicode in a description (RTL override, zero-width, BOM): valid UTF-8, too costly to police on-chain | every SDK read passes through `safe_text`, which strips Unicode format/control categories | `test_profile_sanitizes_invisible_unicode_from_chain` |
| Impersonation: names are not unique | every label carries an address fragment (`Name·3f2a`); a local label always wins in the dashboard | `test_monitor_names_come_from_chain_*` |
| Storage spam | 32 / 280 byte caps; the writer pays the gas (~377k max) | `test_lengthLimits`, `test_gas_profileWrite` |
| Writing someone else's profile | keyed by `msg.sender` only | `test_onlyOwnProfile_*` |
| Interference with games or money | isolated code path, no external calls; included in the invariant handler | `test_profilesNeverTouchFunds`, `invariant_moneyConserved` |

For the website: render profile text as text (React's default), never as HTML, strip Unicode format characters
the way `safe_text` does, and always show the address fragment next to a name.

### Real-chain findings (pass 5)
| # | Weakness | Fix | Test |
|---|---|---|---|
| S16 | **Resume replayed a partial history.** Attaching to a game searched backwards for the newest log chunk with *any* event of the game, not its creation; on a long chain a resumed bot replayed half a game and stalled on time. Invisible locally (a whole game fits one chunk). | search for `GameCreated` specifically | `test_resume_finds_creation_even_when_history_spans_many_chunks` |
| S17 | **Unbounded log scans.** Scans went back to block 0: tens of thousands of RPC calls on a 300M-block L2 | floor at the deployment block (`C4P_DEPLOY_BLOCK`) | same |

### Gas optimisation (pass 6)
Goal: cut cost without changing any rule, any money path or the ABI. Receipts on anvil, same four Stockfish games
before and after: ordinary move 184.6k → 97.2k gas, worst single move 1.61M → 420k, whole game 23.1M → 12.2M;
worst-case terminal evaluation 1.12M → 196k.

| Change | Why it is safe | Evidence |
|---|---|---|
| `hasLegalMove` tries only the squares a piece can geometrically reach instead of all 64 | every candidate still passes the same `_legal` used for submitted moves, so the candidate set only needs to be a *superset* of legal moves; a mistake could only miss a move, and that is what the tests hunt for | `test/EngineEquivalence.t.sol` |
| `isAttacked` rewritten with unsigned, unchecked square arithmetic and explicit edge bounds; rays walk past their first square only when a matching slider exists (exact SWAR piece-presence test) | compared on every square, for both colours, against the frozen pre-optimisation engine, on game positions and raw random 256-bit boards; `hasPiece` compared against a plain scan | same |
| `applyMove` applies the move once instead of twice | identical computation, reused | same |
| Storage repacked: everything a move changes except the board fits one slot; seats stored as `white`/`black` (the creator sits in their chosen seat while Open); stake `uint96` (79 billion ETH) shares a slot with an address | a move now writes exactly 2 game slots + the repetition counter; position round-trips exactly through storage; both seat assignments, refunds and payouts covered | `test/Storage.t.sol` |
| Reentrancy lock in EIP-1153 transient storage (`bool transient`) | same lock semantics, cleared at the end of each call and reverted with it; the reentrant-receiver attack tests still fail to re-enter. Needs Cancun: Arbitrum and Base both have it | `test/Attacks.t.sol`, `test/Adversarial.t.sol` |

Oracle for the engine changes: `test/reference/ChessEngineRef.sol`, a frozen copy of the engine as of b72136c
(perft- and python-chess-verified), never deployed. Checked against it: all 65,536 move encodings in the six perft
positions and a sample of hard positions; every node and move two plies deep from each perft position; 310 hard
positions labelled by python-chess (mates, stalemates, single legal replies, en passant as the only escape,
castling, promotion) with python-chess's legal-move counts as a third oracle; random games; random piece-soup
boards. Plus the unchanged perft suite and `scripts/fuzz_vs_pythonchess.py` through the real contract.

Considered and **not** done:
- *Optimizer runs > 200*: under 1% saving, and at 10,000 runs the contract would land 32 bytes under the 24 KB
  limit. (As shipped, at 200 runs, it is 20.0 KB: 4.5 KB of headroom.)
- *via-IR codegen*: a different compiler pipeline with its own bug history, for a modest gain.
- *Pin-aware legality shortcuts* (skip the king-safety check for pieces not aligned with their king): exact if
  done right, but a classic source of subtle bugs (en passant discovered checks) for ~5k per move.
- *Truncated repetition keys* packed several per slot: a player could search offline for colliding positions
  and force a false draw.
- *Repetition by claim* instead of automatic (the remaining big item, ~22k per move, about 23%): a rules change.
  See "Recommended but not done".

### Independent review of pass 6
A second reviewer, given only the code and the diff, mutation-tested the suite and found **no defect in the
contract**, but a hole in the safety net the engine argument relies on:
| # | Finding | Fix |
|---|---|---|
| R1 | The candidate generator can only fail by *missing* a move, and that only matters when the missed move is the **only** legal move. No test position had a sole legal move of some classes, so a generator without pawn double steps, or missing one knight jump, passed every test (promotions were caught only by one lucky fuzz seed). The next edit to `_pieceHasLegalMove` could have shipped a false checkmate. | `test_onlyLegalMove_everyCandidateClass`: a position whose only legal move is of each of the 80 classes the generator produces (both colours: every pawn move kind incl. en passant and promotions, 8 knight jumps, 8 king steps, every slider direction), plus the reviewer's reproducers. `scripts/mutate_engine.py` drops each candidate class in turn (32 mutants: every pawn move kind, promotion probing, each knight jump, each king step, each slider direction, slider captures, slider range, castling): all 31 harmful ones now fail the suite; the castling one survives, as it must (castling is never the only legal move). |
| R2 | The size-headroom sentence above described a rejected build setting | corrected |
| R3 | The transient lock needs Cancun (TSTORE/TLOAD). Forge simulates with its own EVM, so a deploy to a pre-Cancun chain would "succeed" and then revert on every call (no funds at risk: `createGame` itself reverts) | release checklist step 5 |
| R4 | Internal helpers are only defined on their domain: `isAttacked` for squares < 64, `hasPiece` for pieces < 16, `fullmove` < 65535 (checked, reverts; ~12k plies is the longest possible game). The contract never passes anything else: squares come from `& 63`, kings from validated moves | documented here; no code change |

### Formal verification (pass 7, Halmos symbolic execution)
Proofs, not samples: each property below holds for **every** value of its symbolic inputs, executed on the
compiled bytecode. Run with `scripts/prove.sh` (~20 s); `scripts/prove_reachability.py` guards against vacuous
proofs (Halmos silently drops paths that revert for reasons other than an assertion, so it injects
`assert(false)` into every proof and every branch and requires a counterexample each time).

| Proof | Symbolic inputs | Property |
|---|---|---|
| `check_hasPieceIsExact` | all 2^256 boards, all 16 piece values | the SWAR presence test equals a plain scan |
| `check_resignationPaysExactly` | every stake ≥ MIN_STAKE (all of uint96), both seats, either player resigning | winner gets pot − fee, fee recipient the fee, loser 0, contract keeps 0, result names the right colour |
| `check_drawSplitsExactly` | every stake, both seats (via a real 19-ply stalemate) | equal halves; fee plus the odd wei to the fee recipient; sum = pot; contract keeps 0 |
| `check_flagFallTimingIsExact` | every base time, increment, delay, seat | a flag can be claimed iff the time is exceeded, never a second earlier |
| `check_flagFallPaysExactly` | every stake, both seats | the flagged player's opponent is paid exactly; the caller gets nothing |
| `check_moveClockIsExact` | every base, increment, and both players' delays | a move is accepted iff in time; the clock charges exactly the elapsed time, adds the increment, caps at one day, leaves the other clock alone; deadline consistent |
| `check_lateMoveIsRefused` | every base and every late delay | a late move always reverts `TurnTimedOut` |
| `check_onlySideToMoveCanMove` | every caller address, both seats | nobody but the side to move can move |
| `check_openGameRefundsExactly` | every stake, seat, delay, creator or stranger | an unjoined stake always returns exactly to its creator; strangers only after the window, and the refund still goes to the creator |
| `check_joinWindowIsExact` | every stake and delay | joinable iff within the open window |

**Not proved, and why.** `isAttacked` (and so `applyMove`, which uses it) could not be proved equivalent to the
reference: Halmos explores paths one by one, every ray step branches in both implementations, and the rays
compose sequentially, so a central square has on the order of 20^8 paths (a corner, with 3 rays, already takes
21k paths and 7 minutes). Case splitting only partitions the same work. These stay covered by the exhaustive
differential tests and mutation testing above; a path-merging prover (Certora) is the tool to try next. Also
open: contract-wide invariants over arbitrary call sequences (money conservation, lobby exactness); the Foundry
invariant suite checks them by random sequences, a prover would check all of them.

## Static analysis (Slither 0.11, 74 detectors)
No reentrancy, unchecked-call, arbitrary-send, delegatecall, tx.origin, selfdestruct or access-control findings.
Reported: `timestamp` comparisons (every one is the chess clock or the lobby expiry; deliberate and bounded),
`divide-before-multiply` on the odd-wei line in `_finish` (deliberate: the remainder goes to the fee so nothing
is stranded), and uninitialized mapping/local false positives.

## Verified safe (tests exist, nothing to fix)
- **Illegal moves**: accepted iff in the enumerated legal set (fuzzed with random and bit-flipped moves; perft
  matches reference counts on six positions; thousands of live probes vs python-chess through the real contract).
- **Gas DoS via position**: worst-case terminal evaluation ~200k gas even with 16 queens; no game can be
  wedged by making its last move too expensive.
- **Reentrancy**: a winner re-entering every entrypoint from `receive()` fails everywhere; paid once.
- **Hostile receivers**: 50k-gas capped push with no return-data copy, falling back to a `pending` credit.
- **Forced ETH**: accounting never reads `address(this).balance`.
- **Value conservation**: random action sequences keep `balance == locked stakes + pending credits`, and the
  lobby index == the set of open games, after every step.
- **No admin surface**: no owner, proxy, pause, upgrade; `FEE_RECIPIENT` is a constant.

## Residual risks (tell your users)
- **Sequencer / builder censorship**: if your transactions are withheld, your clock runs. On an L2 the
  sequencer operator can do this; forced-inclusion paths are hours, longer than any clock here.
- **Timestamps** are producer-controlled within bounds; clocks under ~30s are inside that noise.
- **Going offline with a live game** forfeits the stake. The SDK keeps you in the loop; don't kill it.
- **Same-table spam** can make your bot sit down against a stall-bot. You win its stake, but you spend time.
- **Collusion / wash games** only burn the fee. There is nothing to farm.
- **Deep reorgs**: a finished game's payout can be reorged like any transfer; wait for finality before relying on it.
- **Fee recipient must be an EOA** (or a contract that can call `withdraw()`); a reverting recipient just accrues `pending`.
- **Unchecked**: formal verification of the chess engine and of contract-wide invariants (money and clock arithmetic are proved, see pass 7), third-party audit, economic simulation at scale, mainnet MEV behaviour.

## Best-practice checklist (mapped)
From the general guidance reviewed (Checks-Effects-Interactions, reentrancy guards, pull payments, bounded
external calls, no `tx.origin`, pinned compiler, timestamp caution, front-running awareness, static analysis):
CEI everywhere (`_finish` sets status before paying); `nonReentrant` on every state-changing entrypoint;
push-with-cap **and** pull (`withdraw`) — the hybrid is deliberate so a game can always end; no `tx.origin`,
`delegatecall`, `selfdestruct`, assembly beyond the capped call; compiler pinned to 0.8.28; timestamps only
for coarse clocks; ordering analysed above; Slither clean of high/medium findings.

## Recommended but not done (judgement calls for the owner)
- **Draw by agreement** (`offerDraw`/`acceptDraw`): two bots in a dead-drawn ending currently shuffle until the
  50-move or repetition rule, ~100 plies of gas each. Not a security issue; a cost one.
- **Threefold repetition by claim** (as in FIDE) instead of automatic: replace the per-move counter (a fresh
  storage slot, ~22k gas, about 23% of a move) with a running hash of the move list (~5k), and let a player
  prove a repetition by submitting the moves, which the contract replays. Saves ~17k per move, but it is a rules
  change and a new entrypoint to harden (claim vs. flag-fall races; the SDK would claim automatically).
- **Keeper bounty on `claimTimeout`**: if *both* bots die, stakes stay locked until someone calls it. A small
  slice of the pot for a non-player caller would make cleanup self-funding.
- **Source verification** on the block explorer at deploy time, so users can check the pinned code hash against
  public source rather than trusting the SDK bundle.
- **Python 3.11+** (3.9 is end-of-life; the venv here uses 3.9 only because it is the system interpreter).
- **Pin `forge-std`** to a commit (it was vendored without git metadata).
- **Independent audit.** Four passes each found something the previous one missed.

## Release checklist
1. Set `FEE_RECIPIENT` (the deploy script refuses the placeholder off-localnet).
2. `forge build && python scripts/export_abi.py` (refreshes ABI + official code hash), then deploy.
3. Put the deployed address and code hash into `sdk/chess4profit/networks.py` (or `C4P_CONTRACT` / `C4P_CODEHASH`).
4. Independent audit; testnet soak with `scripts/fuzz_vs_pythonchess.py` and the dashboard.
5. Right after deploying, check the chain runs Cancun (the reentrancy lock uses transient storage):
   `cast call <address> "withdraw()" --rpc-url <rpc>` must revert with custom error `0xd0d04f60`
   (`NothingToWithdraw()`), not with an invalid opcode. Arbitrum and Base both have Cancun.
