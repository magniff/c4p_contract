"""Local wallet: create, encrypt to disk (standard Ethereum keystore JSON), load."""
from __future__ import annotations

import getpass
import json
import os
import sys
from pathlib import Path
from typing import Optional, Union

from eth_account import Account
from eth_account.signers.local import LocalAccount

DEFAULT_PATH = Path.home() / ".chess4profit" / "wallet.json"


def _password(password: Optional[str], confirm: bool = False) -> str:
    if password is not None:
        return password
    env = os.environ.get("C4P_WALLET_PASSWORD")
    if env is not None:
        return env
    if sys.stdin.isatty():
        p = getpass.getpass("wallet password: ")
        if confirm and getpass.getpass("repeat password: ") != p:
            raise ValueError("passwords differ")
        return p
    raise ValueError("no wallet password: pass password=..., or set C4P_WALLET_PASSWORD")


class Wallet:
    """A signing key. Never leaves the machine; the SDK only ever asks it to sign transactions."""

    def __init__(self, account: LocalAccount):
        self.account = account

    @property
    def address(self) -> str:
        return self.account.address

    def __repr__(self) -> str:
        return f"Wallet({self.address})"

    # ------------------------------------------------------------------ creation

    @classmethod
    def create(cls) -> "Wallet":
        return cls(Account.create())

    @classmethod
    def from_private_key(cls, key: str) -> "Wallet":
        return cls(Account.from_key(key))

    @classmethod
    def from_env(cls, var: str = "C4P_PRIVATE_KEY") -> "Wallet":
        key = os.environ.get(var)
        if not key:
            raise ValueError(f"environment variable {var} is not set")
        return cls.from_private_key(key)

    # ------------------------------------------------------------------ persistence

    @staticmethod
    def exists(path: Union[str, Path] = DEFAULT_PATH) -> bool:
        return Path(path).expanduser().exists()

    def save(self, path: Union[str, Path] = DEFAULT_PATH, password: Optional[str] = None) -> Path:
        path = Path(path).expanduser()
        if path.exists():
            raise FileExistsError(f"{path} already exists - refusing to overwrite a wallet")
        path.parent.mkdir(parents=True, exist_ok=True)
        keystore = Account.encrypt(self.account.key, _password(password, confirm=True))
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(keystore, f)
        return path

    @classmethod
    def load(cls, path: Union[str, Path] = DEFAULT_PATH, password: Optional[str] = None) -> "Wallet":
        path = Path(path).expanduser()
        keystore = json.loads(path.read_text())
        try:
            key = Account.decrypt(keystore, _password(password))
        except ValueError as e:
            raise ValueError("wrong wallet password") from e
        return cls(Account.from_key(key))

    @classmethod
    def load_or_create(cls, path: Union[str, Path] = DEFAULT_PATH, password: Optional[str] = None) -> "Wallet":
        """The 'just give me a wallet' call: loads ~/.chess4profit/wallet.json, creating it on first use."""
        if cls.exists(path):
            return cls.load(path, password)
        w = cls.create()
        w.save(path, password)
        return w
