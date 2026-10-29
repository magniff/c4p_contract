"""Refresh the SDK's bundled ABI + official code hash after changing the contract:
       forge build && python scripts/export_abi.py"""
import json
from pathlib import Path

from eth_utils import keccak

root = Path(__file__).resolve().parents[1]
art = json.loads((root / "out/Chess4Profit.sol/Chess4Profit.json").read_text())
(root / "sdk/chess4profit/abi.json").write_text(json.dumps(art["abi"], indent=1))
code = bytes.fromhex(art["deployedBytecode"]["object"][2:])
(root / "sdk/chess4profit/codehash.json").write_text(json.dumps({"keccak": "0x" + keccak(code).hex()}))
print("wrote ABI and code hash 0x" + keccak(code).hex())
