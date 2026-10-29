import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import devchain  # noqa: E402

from chess4profit import Client, Wallet  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def chain():
    anvil = devchain.start_anvil()
    addr = devchain.deploy()
    assert addr == "0x5FbDB2315678afecb367f032d93F642f64180aa3", "default 'local' address drifted"
    yield addr
    anvil.terminate()


@pytest.fixture
def make_client():
    def make(eth=100):
        c = Client.connect("local", wallet=Wallet.create())
        c.dev_fund(eth)
        return c
    return make
