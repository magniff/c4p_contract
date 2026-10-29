"""Typed events from the contract."""
from __future__ import annotations

import enum
from dataclasses import dataclass
from typing import Optional

import chess


class Status(enum.IntEnum):
    NONE = 0
    OPEN = 1
    ACTIVE = 2
    FINISHED = 3
    CANCELLED = 4


class Result(enum.IntEnum):
    NONE = 0
    WHITE_WINS = 1
    BLACK_WINS = 2
    DRAW = 3


class Reason(enum.IntEnum):
    NONE = 0
    CHECKMATE = 1
    RESIGNATION = 2
    TIMEOUT = 3
    STALEMATE = 4
    INSUFFICIENT_MATERIAL = 5
    FIFTY_MOVE_RULE = 6
    THREEFOLD_REPETITION = 7


def encode_move(move: chess.Move) -> int:
    """chess.Move -> contract uint16 (from | to << 6 | promotion << 12); numbering matches python-chess."""
    return move.from_square | (move.to_square << 6) | ((move.promotion or 0) << 12)


def decode_move(value: int) -> chess.Move:
    return chess.Move(value & 63, (value >> 6) & 63, (value >> 12) or None)


@dataclass(frozen=True)
class Event:
    game_id: int
    block: int
    log_index: int
    tx: str  # transaction hash (0x...)


@dataclass(frozen=True)
class GameCreated(Event):
    creator: str
    stake: int
    base_time: int
    increment: int
    creator_plays_white: bool


@dataclass(frozen=True)
class GameCancelled(Event):
    pass


@dataclass(frozen=True)
class GameStarted(Event):
    white: str
    black: str


@dataclass(frozen=True)
class MoveMade(Event):
    player: str
    move: chess.Move
    ply: int


@dataclass(frozen=True)
class GameFinished(Event):
    result: Result
    reason: Reason
    winner: Optional[str]  # None on a draw
    payout: int  # per winner (or per player on a draw)
    fee: int


ZERO = "0x0000000000000000000000000000000000000000"


def parse(name: str, log) -> Optional[Event]:
    """Decode a web3 event log into an Event dataclass (None for events we don't expose)."""
    a, base = log["args"], dict(block=log["blockNumber"], log_index=log["logIndex"], tx="0x" + log["transactionHash"].hex().removeprefix("0x"))
    if name == "GameCreated":
        return GameCreated(a["gameId"], **base, creator=a["creator"], stake=a["stake"],
                           base_time=a["baseTime"], increment=a["increment"],
                           creator_plays_white=a["creatorPlaysWhite"])
    if name == "GameCancelled":
        return GameCancelled(a["gameId"], **base)
    if name == "GameStarted":
        return GameStarted(a["gameId"], **base, white=a["white"], black=a["black"])
    if name == "MoveMade":
        return MoveMade(a["gameId"], **base, player=a["player"], move=decode_move(a["move"]), ply=a["ply"])
    if name == "GameFinished":
        w = a["winner"]
        return GameFinished(a["gameId"], **base, result=Result(a["result"]), reason=Reason(a["reason"]),
                            winner=None if w == ZERO else w, payout=a["payout"], fee=a["fee"])
    return None
