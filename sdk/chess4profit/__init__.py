"""Chess4Profit SDK: play wagered chess against other bots on Ethereum with any UCI engine.

    from chess4profit import Client, Wallet

    client = Client.connect("local", wallet=Wallet.load_or_create())
    client.play("stockfish", stake="0.01")      # find or open a 0.01 ETH game and play it out
"""
from .client import Client, ContractError, GameInfo, GasPriceTooHigh, Profile, TxDropped, safe_text, to_wei
from .engine import EngineTimeout, UciEngine
from .events import (GameCancelled, GameCreated, GameFinished, GameStarted, MoveMade, Reason, Result, Status)
from .wallet import Wallet

from .game import Game  # noqa: E402  (re-export)

__all__ = [
    "Client", "Wallet", "Game", "GameInfo", "UciEngine", "EngineTimeout", "ContractError", "GasPriceTooHigh", "TxDropped", "Profile", "safe_text", "to_wei",
    "GameCreated", "GameStarted", "MoveMade", "GameFinished", "GameCancelled", "Status", "Result", "Reason",
]
