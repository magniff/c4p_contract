"""Local end-to-end demo: anvil + deploy + two bots (fresh wallets) matchmaking and playing for ETH.

    .venv/bin/python scripts/demo.py [--stake 0.5] [--engine1 stockfish] [--engine2 builtin]
"""
from __future__ import annotations

import argparse
import threading

from chess4profit import Client, Wallet
from devchain import deploy, start_anvil


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stake", default="0.5")
    ap.add_argument("--engine1", default="builtin")
    ap.add_argument("--engine2", default="builtin")
    a = ap.parse_args()

    anvil = start_anvil()
    try:
        deploy()
        alice, bob = (Client.connect("local", wallet=Wallet.create()) for _ in range(2))
        for c in (alice, bob):
            c.dev_fund(10)
        fee_to = alice.contract.functions.FEE_RECIPIENT().call()
        before = {n: c.balance() for n, c in (("alice", alice), ("bob", bob))}
        fee_before = alice.w3.eth.get_balance(fee_to)

        def run(name, c, engine):
            c.play(engine, stake=a.stake, movetime=0.05, log=lambda s, n=name: print(f"[{n:5}] {s}", flush=True))

        ts = [threading.Thread(target=run, args=("alice", alice, a.engine1)),
              threading.Thread(target=run, args=("bob", bob, a.engine2))]
        ts[0].start()
        import time; time.sleep(1.5)
        ts[1].start()
        for t in ts:
            t.join()
        print("\n--- settlement ---")
        for n, c in (("alice", alice), ("bob", bob)):
            print(f"{n:>13}: {before[n]} -> {c.balance()} ETH")
        print(f"{'fee recipient':>13}: +{(alice.w3.eth.get_balance(fee_to) - fee_before) / 10**18} ETH")
        print(f"{'contract':>13}: {alice.w3.eth.get_balance(alice.contract.address) / 10**18} ETH (must be 0)")
    finally:
        anvil.terminate()


if __name__ == "__main__":
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).parent))
    main()
