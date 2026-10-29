"""Live view-model of the games your agents are playing: state, money, gas. No UI dependencies.

    m = Monitor(client, agents={"0xabc...": "alice"})
    m.refresh()        # call periodically; pulls new events + chain state
    m.games, m.agents  # plain dataclasses to render however you like
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

import chess

from . import events as ev
from .client import Client, GameInfo
from .events import Result, Status


@dataclass
class GameState:
    id: int
    stake: int = 0
    timeout: int = 0
    creator: str = ""
    white: str = ""
    black: str = ""
    status: Status = Status.OPEN
    result: Result = Result.NONE
    reason: str = ""
    plies: int = 0
    deadline: int = 0
    san: List[str] = field(default_factory=list)
    board: chess.Board = field(default_factory=chess.Board)
    last_move: Optional[chess.Move] = None
    updated: float = field(default_factory=time.time)

    @property
    def active(self) -> bool:
        return self.status in (Status.OPEN, Status.ACTIVE)

    def to_move(self) -> Optional[str]:
        return (self.white if self.board.turn == chess.WHITE else self.black) if self.status == Status.ACTIVE else None


@dataclass
class AgentStats:
    address: str
    name: str
    balance: int = 0          # wei, now
    start_balance: int = 0    # wei, when the monitor started
    gas_used: int = 0
    gas_wei: int = 0          # gas actually paid, in wei
    tx_count: int = 0
    wins: int = 0
    draws: int = 0
    losses: int = 0
    locked: int = 0           # stake currently in unfinished games
    won_wei: int = 0          # payouts received from finished games
    staked_wei: int = 0       # stakes put into finished games

    @property
    def pnl_games(self) -> int:
        """Net from the games themselves (payouts - stakes), before gas."""
        return self.won_wei - self.staked_wei

    @property
    def delta(self) -> int:
        return self.balance - self.start_balance


class Monitor:
    def __init__(self, client: Client, agents: Optional[Dict[str, str]] = None, from_block: int = 0,
                 on_event: Optional[Callable[[ev.Event, GameState], None]] = None):
        self.client = client
        self.on_event = on_event
        self.agents: Dict[str, AgentStats] = {}
        for addr, name in (agents or {}).items():
            a = client.w3.to_checksum_address(addr)
            self.agents[a.lower()] = AgentStats(a, name, balance=client.w3.eth.get_balance(a))
            self.agents[a.lower()].start_balance = self.agents[a.lower()].balance
        self.games: Dict[int, GameState] = {}
        self.fee_recipient = client.contract.functions.FEE_RECIPIENT().call()
        self.fee_start = client.w3.eth.get_balance(self.fee_recipient)
        self.fees_collected = 0
        self.locked_total = 0
        self.block = 0
        self._stream = client.events(None, from_block=from_block)
        self._seen_tx: set = set()

    def name(self, addr: str) -> str:
        a = self.agents.get(addr.lower())
        return a.name if a else (addr[:6] + "…" + addr[-4:] if addr else "—")

    def mine(self, g: GameState) -> bool:
        return any(p.lower() in self.agents for p in (g.creator, g.white, g.black) if p)

    # ------------------------------------------------------------------ polling

    def refresh(self) -> List[ev.Event]:
        w3 = self.client.w3
        self.block = w3.eth.block_number
        new = self._stream.poll()
        for e in new:
            self._apply(e)
        # clocks / authoritative status for games still running
        for g in self.games.values():
            if g.active:
                self._sync(g, self.client.game_info(g.id))
        for a in self.agents.values():
            a.balance = w3.eth.get_balance(a.address)
            a.locked = 0
        for g in self.games.values():
            if g.active:
                for p, mult in ((g.creator, 1),) if g.status == Status.OPEN else ((g.white, 1), (g.black, 1)):
                    if p and p.lower() in self.agents:
                        self.agents[p.lower()].locked += g.stake * mult
        self.locked_total = w3.eth.get_balance(self.client.contract.address)
        self.fees_collected = w3.eth.get_balance(self.fee_recipient) - self.fee_start
        return new

    def _sync(self, g: GameState, i: GameInfo) -> None:
        g.status, g.result, g.plies, g.deadline = i.status, i.result, i.plies, i.deadline
        g.stake = i.stake

    def _apply(self, e: ev.Event) -> None:
        g = self.games.setdefault(e.game_id, GameState(e.game_id))
        g.updated = time.time()
        if isinstance(e, ev.GameCreated):
            g.stake, g.timeout, g.creator = e.stake, e.base_time, e.creator
            g.white = e.creator  # provisional until someone joins
        elif isinstance(e, ev.GameStarted):
            g.white, g.black, g.status = e.white, e.black, Status.ACTIVE
        elif isinstance(e, ev.GameCancelled):
            g.status = Status.CANCELLED
        elif isinstance(e, ev.MoveMade):
            if e.ply == len(g.board.move_stack) + 1:
                g.san.append(g.board.san(e.move))
                g.board.push(e.move)
                g.last_move, g.plies = e.move, e.ply
        elif isinstance(e, ev.GameFinished):
            g.status, g.result, g.reason = Status.FINISHED, e.result, e.reason.name
            self._settle(g, e)
        self._account_gas(e)
        if self.on_event:
            self.on_event(e, g)

    def _settle(self, g: GameState, e: ev.GameFinished) -> None:
        for player, colour in ((g.white, chess.WHITE), (g.black, chess.BLACK)):
            a = self.agents.get(player.lower())
            if not a:
                continue
            a.staked_wei += g.stake
            if e.result == Result.DRAW:
                a.draws += 1
                a.won_wei += e.payout
            elif (e.result == Result.WHITE_WINS) == (colour == chess.WHITE):
                a.wins += 1
                a.won_wei += e.payout
            else:
                a.losses += 1

    def _account_gas(self, e: ev.Event) -> None:
        if e.tx in self._seen_tx:
            return
        self._seen_tx.add(e.tx)
        r = self.client.w3.eth.get_transaction_receipt(e.tx)
        a = self.agents.get(r["from"].lower())
        if a:
            a.tx_count += 1
            a.gas_used += r["gasUsed"]
            a.gas_wei += r["gasUsed"] * r.get("effectiveGasPrice", 0)
