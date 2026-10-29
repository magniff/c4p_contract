"""`c4p` command line.

  c4p wallet new            create ~/.chess4profit/wallet.json (encrypted)
  c4p wallet show           address + balance
  c4p games                 open games you could join
  c4p play --engine stockfish --stake 0.01
"""
from __future__ import annotations

import argparse
import sys

from .client import Client
from .wallet import DEFAULT_PATH, Wallet


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="c4p", description="Wagered chess for bots, settled on Ethereum.")
    ap.add_argument("--network", default="local", help="local | base-sepolia | base (default: local)")
    ap.add_argument("--rpc")
    ap.add_argument("--contract")
    ap.add_argument("--wallet", default=str(DEFAULT_PATH), help="wallet file (default %(default)s)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    w = sub.add_parser("wallet")
    w.add_argument("action", choices=["new", "show"])
    w.add_argument("--fund", type=float, help="local chain only: give the wallet this much test ETH")
    gm = sub.add_parser("games", help="open games at a table")
    gm.add_argument("--stake", required=True, help="ETH")
    gm.add_argument("--base-time", type=int, default=300)
    gm.add_argument("--increment", type=int, default=2)
    p = sub.add_parser("play")
    p.add_argument("--engine", default="builtin", help='UCI command e.g. "stockfish", or "builtin"')
    p.add_argument("--stake", required=True, help="ETH per player")
    p.add_argument("--base-time", type=int, default=300, help="clock per player, seconds; you only join this exact clock")
    p.add_argument("--increment", type=int, default=2, help="seconds added per move")
    p.add_argument("--colour", choices=["white", "black", "random"], default="random")
    p.add_argument("--movetime", type=float, default=0.3, help="engine think time, seconds")
    p.add_argument("--join", type=int, metavar="GAME_ID", help="join this specific game instead of matchmaking")
    m = sub.add_parser("monitor", help="terminal dashboard of your agents' games (pip install chess4profit[tui])")
    m.add_argument("--watch", action="append", default=[], metavar="ADDR[=NAME]", help="agent address to follow (repeatable)")
    m.add_argument("--all", action="store_true", help="show every game, not just your agents'")
    a = ap.parse_args(argv)

    if a.cmd == "wallet" and a.action == "new":
        wallet = Wallet.create()
        path = wallet.save(a.wallet)
        print(f"created {wallet.address}\nsaved encrypted keystore to {path}")
        return 0

    if a.cmd == "monitor":
        from .monitor import Monitor
        from .tui import Dashboard
        client = Client.connect(a.network, rpc=a.rpc, contract=a.contract)
        agents = {}
        for w in a.watch:
            addr, _, name = w.partition("=")
            agents[addr] = name or addr[:8]
        if not agents and Wallet.exists(a.wallet):
            ws = Wallet.load(a.wallet)
            agents[ws.address] = "me"
        head = client.w3.eth.block_number
        Dashboard(Monitor(client, agents, from_block=0 if head < 50_000 else head - 50_000), show_all=a.all).run()
        return 0

    wallet = Wallet.load(a.wallet)
    client = Client.connect(a.network, wallet=wallet, rpc=a.rpc, contract=a.contract)

    if a.cmd == "wallet":
        if a.fund:
            client.dev_fund(a.fund)
        print(f"{wallet.address}\nbalance: {client.balance()} ETH   pending withdrawal: {client.pending()} ETH")
    elif a.cmd == "games":
        for g in client.open_games(a.stake, a.base_time, a.increment):
            print(f"#{g.id}  stake {g.stake_eth} ETH  clock {g.base_time}s+{g.increment}  by {g.white}")
    elif a.cmd == "play":
        before = client.balance()
        if a.join is not None:
            final = client.join_game(a.join).play(a.engine, movetime=a.movetime)
        else:
            final = client.play(a.engine, stake=a.stake, base_time=a.base_time, increment=a.increment, colour=a.colour,
                                movetime=a.movetime)
        print(f"result: {final.result.name} ({final.reason.name}); balance change incl. gas: {client.balance() - before:+} ETH")
    return 0


if __name__ == "__main__":
    sys.exit(main())
