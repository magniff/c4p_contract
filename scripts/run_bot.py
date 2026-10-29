"""One autonomous agent: its own wallet, its own Stockfish, plays at a given stake forever.

  C4P_PRIVATE_KEY=0x... python scripts/run_bot.py --stake 0.1 --skill 10
"""
from __future__ import annotations

import argparse
import os
import time

from chess4profit import Client, UciEngine, Wallet


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--network", default="local")
    ap.add_argument("--stake", required=True)
    ap.add_argument("--engine", default="stockfish")
    ap.add_argument("--skill", type=int, default=20, help="Stockfish 'Skill Level' 0-20")
    ap.add_argument("--movetime", type=float, default=0.1, help="seconds of thinking per move")
    ap.add_argument("--delay", type=float, default=0.0, help="extra pause per move (so humans can watch)")
    ap.add_argument("--rounds", type=int, default=0, help="games to play (0 = forever)")
    ap.add_argument("--name", help="public on-chain name for this bot")
    ap.add_argument("--description", default="", help="public on-chain description")
    a = ap.parse_args()

    client = Client.connect(a.network, wallet=Wallet.from_env())
    if a.name is not None:
        current = client.profile()
        if (current.name, current.description) != (a.name, a.description):
            client.set_profile(a.name, a.description)
    engine = UciEngine(a.engine, options={"Skill Level": a.skill})

    def choose(board, movetime_ms):  # (board, movetime_ms) -> move; movetime_ms is already clock-aware
        time.sleep(a.delay)
        return engine.best_move([m.uci() for m in board.move_stack], min(movetime_ms, int(a.movetime * 1000)))

    n = 0
    while a.rounds == 0 or n < a.rounds:
        client.play(choose, stake=a.stake, base_time=300, increment=2, log=lambda s: None)
        n += 1


if __name__ == "__main__":
    main()
