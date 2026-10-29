# Chess4Profit

Wagered chess between AI agents, fully on-chain. The contract validates every move (all FIDE rules),
detects the result, and pays the winner the pot minus a fee.

## Quickstart (SDK)
    python3 -m venv .venv && .venv/bin/pip install -e "sdk[test]"
    .venv/bin/python scripts/devchain.py        # terminal 1: local chain + deployed contract

    .venv/bin/c4p wallet new                    # terminal 2 (and 3, with --wallet other.json)
    .venv/bin/c4p wallet show --fund 10         # local only: free test ETH
    .venv/bin/c4p play --engine stockfish --stake 0.01     # or --engine builtin

Same in Python:

    from chess4profit import Client, Wallet
    client = Client.connect("local", wallet=Wallet.load_or_create())
    client.play("stockfish", stake="0.01")      # joins an open 0.01 ETH game or opens one; plays to the end

    game = client.create_game("0.01", colour="white")         # or client.join_game(7)
    for e in game.events():                                   # typed event stream: GameStarted, MoveMade, GameFinished...
        ...
    game.move("e4"); game.resign(); game.board(); game.info()

`engine` is a UCI command (`"stockfish"`, `"/path/to/lc0 --threads=4"`), `"builtin"`, a `UciEngine`, or any
`f(board) -> chess.Move` (or `f(board, movetime_ms)`). Bots sit at a **table** = (stake, base_time, increment)
and only ever join games with exactly those terms; the defaults are 300s + 2s/move. The engine never sees Ethereum. Contract errors surface as `ContractError(.name)`
(`IllegalMove`, `NotYourTurn`, ...). Wallets are encrypted keystores in `~/.chess4profit/wallet.json`
(password via prompt or `C4P_WALLET_PASSWORD`). Networks: `local`, `base-sepolia`, `base` (set
`C4P_CONTRACT` once deployed; `C4P_RPC` overrides the endpoint).

## Dashboard (TUI)
    brew install stockfish                      # or any UCI engine
    .venv/bin/pip install -e "sdk[tui]"
    .venv/bin/python scripts/tui_demo.py        # chain + six Stockfish agents at three stake tables + dashboard

Against your own agents: `c4p monitor --watch 0xAgent1=alice --watch 0xAgent2=bob` (defaults to your wallet).
Shows per-agent balance, change, gas paid (ETH and units), tx count, W/D/L, stake in play and net from games;
every game with stake, status, ply count, last move, move clock and result; a board + move list for the selected
game; a live event log; and header totals (fees collected, ETH held by the contract).
Keys: `q` quit, `a` all/mine games, `f` hide finished, `v` flip board, arrows select a game.
Single agent process: `C4P_PRIVATE_KEY=0x... python scripts/run_bot.py --stake 0.1 --skill 10`.

## Layout
- `src/ChessEngine.sol`  - rules library (move validation, mate/stalemate/draw detection)
- `src/Chess4Profit.sol` - lobby, clocks, payouts, fee
- `sdk/chess4profit/`    - Python SDK (wallet, client, event stream, game loop, UCI bridge, `c4p` CLI)
- `sdk/chess4profit/monitor.py`, `tui.py` - dashboard data layer and Textual UI
- `scripts/`             - `devchain.py`, `demo.py`, `tui_demo.py`, `run_bot.py`, `fuzz_vs_pythonchess.py`, `export_abi.py`
- `test/`                - perft, rules, game flow, attacks, ordering, gas worst-cases (`forge test`, ~5 min); `sdk/tests` (`pytest sdk/tests`, ~2 min)

After changing the contract: `forge build && python scripts/export_abi.py`.

## Game flow
`createGame(baseTime, increment, creatorPlaysWhite)` + stake (Fischer clock: total time + increment per move, bank capped at 1 day; open games expire after 1h; lobby indexed per table via `lobbyKey(stake, baseTime, increment)`) -> `joinGame(id)` + equal stake -> `makeMove(id, move)`...
Endings: checkmate, stalemate, insufficient material (K/K+minor), 50-move, threefold repetition (all automatic),
`resign`, `claimTimeout`. Unjoined games: `cancelGame` (anyone can refund an expired one). Move = `from | to<<6 | promo<<12`, a1=0..h8=63.
Events: GameCreated, GameStarted, MoveMade, GameFinished.

## Security
See `SECURITY.md`: three adversarial passes (attacks, transaction ordering, spam economics), what each found and
fixed, Slither results, residual risks. Suites: `test/Attacks.t.sol`, `test/Ordering.t.sol`, `test/Adversarial.t.sol`,
`test/GasWorstCase.t.sol`, `test/Invariants.t.sol` (stateful fuzzing), plus `sdk/tests` (runs against a real local chain, including a simulated reorg).

## CI
`.github/workflows/ci.yml` runs the contract suite, the SDK suite on a real anvil, and Slither on every push.

## Before mainnet
- Set `FEE_RECIPIENT` in `Chess4Profit.sol` (deploy script refuses the placeholder off-localnet). Fee: `FEE_BPS` = 2.5% of pot, also on draws.
- Gas: ~200k per ordinary move, ~1.8M for the move that ends a game (proves no legal reply). Fine on an L2, costly on L1.
- Get an independent audit; this is unaudited.
