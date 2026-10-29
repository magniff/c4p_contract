"""Where the contract lives. Add your deployment here or override with C4P_RPC / C4P_CONTRACT."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass(frozen=True)
class Network:
    rpc: str
    contract: Optional[str]  # None until deployed
    local: bool = False
    codehash: Optional[str] = None  # keccak of the official runtime bytecode; verified on connect
    # Block the contract was deployed at. No game can be older, so log scans never go below it (on a busy
    # L2 the head is hundreds of millions of blocks; scanning from 0 would mean tens of thousands of calls).
    deploy_block: int = 0


def _official_codehash() -> Optional[str]:
    f = Path(__file__).parent / "codehash.json"
    return json.loads(f.read_text())["keccak"] if f.exists() else None


NETWORKS = {
    # anvil's first deployment from its first account lands at this deterministic address.
    # codehash=None here means "the bundled official build" - resolved at connect time, not import time.
    "local": Network("http://127.0.0.1:8545", "0x5FbDB2315678afecb367f032d93F642f64180aa3", local=True),
    "base-sepolia": Network("https://sepolia.base.org", None),
    "base": Network("https://mainnet.base.org", None),
    "arbitrum-sepolia": Network("https://sepolia-rollup.arbitrum.io/rpc", None),
    "arbitrum": Network("https://arb1.arbitrum.io/rpc", None),
}


def resolve(network: str, rpc: Optional[str], contract: Optional[str]) -> Network:
    n = NETWORKS.get(network)
    if n is None:
        raise ValueError(f"unknown network {network!r}; known: {', '.join(NETWORKS)}")
    rpc = rpc or os.environ.get("C4P_RPC") or n.rpc
    contract = contract or os.environ.get("C4P_CONTRACT") or n.contract
    if not contract:
        raise ValueError(
            f"no contract address known for {network!r}: pass contract=... or set C4P_CONTRACT"
        )
    codehash = os.environ.get("C4P_CODEHASH") or n.codehash or _official_codehash()
    deploy_block = int(os.environ.get("C4P_DEPLOY_BLOCK") or n.deploy_block)
    return Network(rpc, contract, n.local, codehash, deploy_block)
