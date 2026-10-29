"""A single game: state, moves, and a ready-made play loop."""
from __future__ import annotations

import time
from typing import Iterator, Optional, Union

import chess

import requests
from web3.exceptions import ProviderConnectionError

from . import events as ev
from .client import Client, ContractError, GameInfo
from .engine import as_chooser
from .events import Status


# RPC transport failures that a game loop should ride out rather than die on (the clock keeps running)
TRANSIENT_RPC_ERRORS = (requests.exceptions.RequestException, ProviderConnectionError, ConnectionError, TimeoutError)


class Game:
    def __init__(self, client: Client, game_id: int, start_block: Optional[int] = None):
        self.client, self.id = client, game_id
        self.start_block = start_block

    def __repr__(self) -> str:
        return f"Game(#{self.id})"

    # ------------------------------------------------------------------ state

    def info(self) -> GameInfo:
        return self.client.game_info(self.id)

    @property
    def colour(self) -> Optional[bool]:
        """chess.WHITE / chess.BLACK for our wallet, None if we're not seated yet or not playing."""
        i, me = self.info(), self.client.address.lower()
        if i.status == Status.OPEN:
            return None
        return chess.WHITE if i.white.lower() == me else chess.BLACK if i.black.lower() == me else None

    def _from_block(self) -> int:
        """Block of this game's GameCreated event, so a replay starts from the very first move.

        Searches for GameCreated specifically: the most recent chunk with *any* event of the game would be
        too late (a resumed bot would replay a partial history and never line up with the chain).
        The search never goes below the contract's deployment block.
        """
        if self.start_block is None:
            c = self.client
            created = next(k for k, v in c._topics.items() if v == "GameCreated")
            head, floor, step = c.w3.eth.block_number, c.deploy_block, 10_000
            hi = head
            while hi >= floor:
                lo = max(floor, hi - step + 1)
                flt = {"address": c.contract.address, "fromBlock": lo, "toBlock": hi,
                       "topics": ["0x" + created, "0x" + hex(self.id)[2:].rjust(64, "0")]}
                logs = c.w3.eth.get_logs(flt)
                if logs:
                    self.start_block = logs[0]["blockNumber"]
                    break
                hi = lo - 1
            else:
                raise RuntimeError(f"game #{self.id} has no GameCreated event at or after block {floor}"
                                   " (wrong deploy block / contract address?)")
        return self.start_block

    def events(self, from_start: bool = True, poll_interval: float = 0.25) -> ev.EventStream:
        """Events of this game; replays history first unless from_start=False."""
        fb = self._from_block() if from_start else None
        return self.client.events(self.id, from_block=fb, poll_interval=poll_interval)

    def moves(self) -> Iterator[ev.MoveMade]:
        """Every move of the game, history then live, until it finishes."""
        for e in self.events():
            if isinstance(e, ev.MoveMade):
                yield e
            elif isinstance(e, (ev.GameFinished, ev.GameCancelled)):
                return

    def board(self) -> chess.Board:
        """The current position rebuilt from on-chain history."""
        b = chess.Board()
        for e in self.events().poll():
            if isinstance(e, ev.MoveMade):
                b.push(e.move)
        return b

    # ------------------------------------------------------------------ actions

    def move(self, move: Union[chess.Move, str], board: Optional[chess.Board] = None, urgent: bool = False):
        """Play a chess.Move, a UCI string ("e2e4") or SAN ("Nf3")."""
        if isinstance(move, str):
            b = board or self.board()
            try:
                move = b.parse_uci(move)
            except ValueError:
                move = b.parse_san(move)
        return self.client.transact(self.client.contract.functions.makeMove(self.id, ev.encode_move(move)), urgent=urgent)

    def resign(self):
        return self.client.transact(self.client.contract.functions.resign(self.id))

    def claim_timeout(self):
        return self.client.transact(self.client.contract.functions.claimTimeout(self.id))

    def cancel(self):
        return self.client.transact(self.client.contract.functions.cancelGame(self.id))

    def wait_for_opponent(self, poll: float = 0.3) -> GameInfo:
        while True:
            i = self.info()
            if i.status != Status.OPEN:
                return i
            time.sleep(poll)

    # ------------------------------------------------------------------ the loop

    def play(self, engine="builtin", *, movetime: float = 0.3, poll: float = 0.2, log=print) -> GameInfo:
        """Play this game to the end with `engine` (UCI command, UciEngine, or callable). Returns the final GameInfo.

        Event driven: replays history, then reacts to each new MoveMade. Claims a timeout win if the
        opponent stalls. Safe to call again after a crash - it resumes from chain state.
        """
        # Spawn/validate the engine first: a broken engine must fail here, not after money is on the table.
        choose = as_chooser(engine)
        try:
            info = self.wait_for_opponent()
            if info.status == Status.CANCELLED:
                raise RuntimeError(f"game #{self.id} expired or was cancelled before anyone joined")
            me = self.client.address.lower()
            colour = self.colour
            if colour is None:
                raise RuntimeError(f"{self.client.address} is not a player in game #{self.id}")
            log(f"game #{self.id}: playing {'white' if colour else 'black'} vs {info.black if colour else info.white}")

            board = chess.Board()
            stream = self.events()
            flagged = False  # we ran out of time: stop submitting, just wait for the claim
            rpc_failures = 0
            while True:
                try:
                    done = self._tick(stream, board, choose, movetime, colour, me, log, flagged)
                except TRANSIENT_RPC_ERRORS as err:
                    # a flaky node must not kill a bot with a live game: back off and retry
                    rpc_failures += 1
                    log(f"  rpc error ({type(err).__name__}: {str(err)[:80]}); retry {rpc_failures}")
                    time.sleep(min(10.0, 0.5 * 2 ** min(rpc_failures, 5)))
                    continue
                rpc_failures = 0
                if done is not None:
                    if done == "finished":
                        return self.info()
                    if done == "flagged":
                        flagged = True
                    elif done == "resync":
                        board = self.board()
                        stream = self.events()
                        stream.poll()  # fast-forward the cursor past the history we just replayed
                        flagged = False
                time.sleep(poll)
        finally:
            close = getattr(choose, "close", None)
            if close:
                close()

    def _tick(self, stream, board, choose, movetime, colour, me, log, flagged) -> Optional[str]:
        """One pass of the loop. Returns 'finished', 'flagged', 'resync' or None."""
        for e in stream.poll():
            if isinstance(e, ev.MoveMade) and e.ply == len(board.move_stack) + 1:
                who = "me " if e.player.lower() == me else "opp"
                log(f"  ply {e.ply:>3} {who}: {board.san(e.move)}")
                board.push(e.move)
            elif isinstance(e, ev.GameFinished):
                log(f"game #{self.id} finished: {e.result.name} by {e.reason.name}")
                return "finished"
        info = self.info()
        if info.status == Status.FINISHED:
            return None  # drain the final events on the next pass
        if info.plies < len(board.move_stack):
            # a reorg dropped a move we had already applied: rebuild from what the chain says now
            log(f"  reorg detected ({len(board.move_stack)} -> {info.plies} plies); resyncing")
            return "resync"
        if info.status == Status.ACTIVE and info.plies == len(board.move_stack):
            now = self.client.chain_time()
            if board.turn == colour:
                if not flagged and self._play_engine_move(choose, board, movetime, info, now, log):
                    return "flagged"
            elif now > info.deadline:
                log("  opponent ran out of time - claiming win")
                try:
                    self.claim_timeout()
                except ContractError as err:
                    log(f"  claim failed: {err.name}")
        return None

    def _play_engine_move(self, choose, board: chess.Board, movetime: float, info: GameInfo, now: int, log) -> bool:
        """Pick and submit a move. Returns True if the contract says we are already out of time."""
        # never think for more than a third of what's left on our clock; bid a higher tip when time is short
        bank = info.white_time if board.turn == chess.WHITE else info.black_time
        remaining = max(0.0, float(info.deadline - now))
        think_ms = int(max(0.05, min(movetime, remaining * 0.3)) * 1000)
        urgent = remaining < max(10.0, bank * 0.25)
        try:
            mv = choose(board, think_ms)
        except Exception as err:  # engine hung, crashed or returned garbage: a legal move beats a forfeit
            log(f"  engine error ({err}); falling back to a legal move")
            mv = None
        if mv is None or mv not in board.legal_moves:
            import random
            mv = random.choice(list(board.legal_moves))
        try:
            self.move(mv, urgent=urgent)
        except ContractError as err:
            log(f"  move {mv.uci()} rejected: {err.name}")
            if err.name == "TurnTimedOut":
                log("  we lost on time; waiting for the game to be settled")
                return True
        return False
