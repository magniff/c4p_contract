"""Showcase: a local chain, six Stockfish agents at three tables, and the live dashboard.

    .venv/bin/python scripts/tui_demo.py            # q quits (and stops everything)
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from chess4profit import Client, Wallet
from chess4profit.monitor import Monitor
from chess4profit.tui import Dashboard
from devchain import deploy, start_anvil

HERE = Path(__file__).resolve().parent

# (name, table stake in ETH, Stockfish skill level 0-20)
BOTS = [
    ("Magnus", "0.25", 20), ("Hikaru", "0.25", 14),
    ("Fabi", "0.10", 11), ("Ding", "0.10", 6),
    ("Anish", "0.05", 8), ("Nepo", "0.05", 2),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--delay", type=float, default=0.6, help="pause per move so you can watch")
    ap.add_argument("--movetime", type=float, default=0.1)
    a = ap.parse_args()

    anvil = start_anvil()
    procs = []
    try:
        deploy()
        watcher = Client.connect("local")
        wallets = {}
        for name, stake, skill in BOTS:
            w = Wallet.create()
            Client.connect("local", wallet=w).dev_fund(50)
            wallets[name] = w
        monitor = Monitor(watcher, {w.address: n for n, w in wallets.items()}, from_block=0)
        for name, stake, skill in BOTS:
            env = dict(os.environ, C4P_PRIVATE_KEY=wallets[name].account.key.hex(), PYTHONWARNINGS="ignore")
            procs.append(subprocess.Popen(
                [sys.executable, str(HERE / "run_bot.py"), "--stake", stake, "--skill", str(skill),
                 "--delay", str(a.delay), "--movetime", str(a.movetime)],
                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        Dashboard(monitor).run()
    finally:
        for p in procs:
            p.terminate()
        anvil.terminate()


if __name__ == "__main__":
    sys.path.insert(0, str(HERE))
    main()
