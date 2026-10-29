"""Plug in anything that plays chess. The engine never learns it is playing on Ethereum.

`as_chooser(x)` accepts:
  * "stockfish" / "/path/to/engine --args"   any UCI engine command
  * "builtin"                                 the bundled toy engine (no install needed)
  * a UciEngine
  * a callable  f(board: chess.Board) -> chess.Move | "e2e4"
"""
from __future__ import annotations

import inspect
import queue
import shlex
import shutil
import subprocess
import sys
import threading
import time
from typing import Callable, Dict, List, Optional, Sequence, Union

import chess


class EngineTimeout(RuntimeError):
    """The engine did not answer in time (hung/crashed). The caller should play a fallback move."""


class UciEngine:
    """Minimal UCI client (works with Stockfish, Leela, Berserk, ... anything speaking the protocol).

    Every read has a deadline: a hung engine must never make an agent forfeit on time.
    """

    def __init__(self, cmd: Union[str, Sequence[str]], options: Optional[Dict[str, object]] = None,
                 grace: float = 5.0):
        self.argv = shlex.split(cmd) if isinstance(cmd, str) else list(cmd)
        self.options = dict(options or {})
        self.grace = grace  # seconds beyond movetime we tolerate before declaring the engine hung
        if shutil.which(self.argv[0]) is None:
            raise FileNotFoundError(
                f"engine {self.argv[0]!r} not found on PATH (install it, or pass a full path / engine='builtin')"
            )
        self._spawn()

    def _spawn(self) -> None:
        self.proc = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1
        )
        self._lines: "queue.Queue[Optional[str]]" = queue.Queue()
        threading.Thread(target=self._pump, args=(self.proc, self._lines), daemon=True).start()
        self._send("uci")
        self._read_until("uciok", 10.0)
        for k, v in self.options.items():
            self._send(f"setoption name {k} value {v}")
        self._ready()

    @staticmethod
    def _pump(proc, lines) -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            lines.put(line)
        lines.put(None)

    def _send(self, line: str) -> None:
        assert self.proc.stdin is not None
        try:
            self.proc.stdin.write(line + "\n")
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            raise EngineTimeout("engine pipe closed") from e

    def _read_until(self, prefix: str, timeout: float) -> str:
        end = time.monotonic() + timeout
        while True:
            try:
                line = self._lines.get(timeout=max(0.01, end - time.monotonic()))
            except queue.Empty:
                raise EngineTimeout(f"no {prefix!r} from engine within {timeout:.1f}s") from None
            if line is None:
                raise EngineTimeout("engine terminated unexpectedly")
            if line.startswith(prefix):
                return line.strip()

    def _ready(self) -> None:
        self._send("isready")
        self._read_until("readyok", 10.0)

    def restart(self) -> None:
        """Kill and respawn after a hang/crash."""
        self.close()
        self._spawn()

    def new_game(self) -> None:
        self._send("ucinewgame")
        self._ready()

    def best_move(self, moves: List[str], movetime_ms: int = 300) -> str:
        """`moves` = the whole game so far (UCI notation) from the standard start position."""
        self._send("position startpos" + (" moves " + " ".join(moves) if moves else ""))
        self._send(f"go movetime {movetime_ms}")
        try:
            line = self._read_until("bestmove", movetime_ms / 1000 + self.grace)
        except EngineTimeout:
            self.restart()  # a hung engine is useless for the rest of the game; start clean
            raise
        parts = line.split()
        if len(parts) < 2 or parts[1] in ("(none)", "0000"):
            raise EngineTimeout(f"engine gave no move: {line!r}")
        return parts[1]

    def close(self) -> None:
        try:
            self._send("quit")
            self.proc.wait(timeout=2)
        except Exception:
            self.proc.kill()

    def __enter__(self) -> "UciEngine":
        return self

    def __exit__(self, *exc) -> None:
        self.close()


Chooser = Callable[[chess.Board, int], chess.Move]


class _Owned:
    """Wraps a chooser that owns a subprocess so callers can close it."""

    def __init__(self, engine: UciEngine):
        self.engine = engine

    def __call__(self, board: chess.Board, movetime_ms: int) -> chess.Move:
        return chess.Move.from_uci(self.engine.best_move([m.uci() for m in board.move_stack], movetime_ms))

    def close(self) -> None:
        self.engine.close()


def as_chooser(engine) -> Chooser:
    if isinstance(engine, _Owned):
        return engine  # already prepared (e.g. by Client.play before staking)
    if isinstance(engine, str):
        if engine == "builtin":
            engine = UciEngine([sys.executable, "-m", "chess4profit.randomfish"])
        else:
            engine = UciEngine(engine)
    if isinstance(engine, UciEngine):
        engine.new_game()
        return _Owned(engine)
    if callable(engine):
        # callables may take (board) or (board, movetime_ms); the latter gets the clock-aware budget
        takes_time = len(inspect.signature(engine).parameters) >= 2

        def call(board: chess.Board, movetime_ms: int) -> chess.Move:
            m = engine(board, movetime_ms) if takes_time else engine(board)
            return chess.Move.from_uci(m) if isinstance(m, str) else m
        return call
    raise TypeError(f"don't know how to use {engine!r} as a chess engine")
