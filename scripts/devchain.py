"""Start a local anvil chain with the contract deployed, and keep it running.

    .venv/bin/python scripts/devchain.py

The contract lands at the SDK's default 'local' address, so `Client.connect("local")` and
`c4p play ...` work with no further configuration.
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

from web3 import Web3

ROOT = Path(__file__).resolve().parents[1]
# public anvil dev key #0 - used only to deploy on the local chain
DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
PORT = 8545
RPC = f"http://127.0.0.1:{PORT}"


def start_anvil() -> subprocess.Popen:
    p = subprocess.Popen(["anvil", "--port", str(PORT), "--silent"], stdout=subprocess.DEVNULL)
    w3 = Web3(Web3.HTTPProvider(RPC))
    for _ in range(100):
        if w3.is_connected():
            return p
        time.sleep(0.1)
    p.kill()
    raise SystemExit("anvil did not start (is port 8545 already in use?)")


def deploy() -> str:
    subprocess.run(["forge", "build", "--quiet"], cwd=ROOT, check=True)
    # keep the SDK's pinned ABI/code hash in step with whatever we are about to deploy
    subprocess.run([sys.executable, str(ROOT / "scripts" / "export_abi.py")], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run(["forge", "script", "script/Deploy.s.sol", "--rpc-url", RPC, "--private-key", DEPLOYER_KEY,
                    "--broadcast", "--silent"], cwd=ROOT, check=True)
    run = json.loads((ROOT / "broadcast/Deploy.s.sol/31337/run-latest.json").read_text())
    return Web3.to_checksum_address(run["transactions"][0]["contractAddress"])


if __name__ == "__main__":
    anvil = start_anvil()
    try:
        print(f"local chain up at {RPC}\ncontract deployed at {deploy()}\nCtrl-C to stop.", flush=True)
        anvil.wait()
    except KeyboardInterrupt:
        pass
    finally:
        anvil.terminate()
