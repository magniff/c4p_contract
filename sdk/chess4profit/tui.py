"""Terminal dashboard for your agents' games.   c4p monitor   (needs: pip install chess4profit[tui])"""
from __future__ import annotations

import time
from collections import deque
from typing import Deque, Optional

import chess
from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import DataTable, Footer, RichLog, Static

from . import events as ev
from .events import Result, Status
from .monitor import GameState, Monitor

GLYPH = {chess.PAWN: "♟", chess.KNIGHT: "♞", chess.BISHOP: "♝", chess.ROOK: "♜", chess.QUEEN: "♛", chess.KING: "♚"}
LIGHT, DARK, HILITE_L, HILITE_D = "#b58863", "#8a5a3c", "#d6c25a", "#a8962f"
RESULT_TXT = {Result.WHITE_WINS: "1-0", Result.BLACK_WINS: "0-1", Result.DRAW: "½-½"}


def eth(wei: int, places: int = 4) -> str:
    return f"{wei / 10**18:.{places}f}"


def signed_eth(wei: int, places: int = 4) -> Text:
    t = Text(f"{wei / 10**18:+.{places}f}")
    t.stylize("green" if wei > 0 else "red" if wei < 0 else "dim")
    return t


def render_board(g: Optional[GameState], flip: bool = False) -> Text:
    out = Text()
    if g is None:
        return Text("select a game", style="dim")
    last = {g.last_move.from_square, g.last_move.to_square} if g.last_move else set()
    ranks = range(8) if flip else range(7, -1, -1)
    files = range(7, -1, -1) if flip else range(8)
    for r in ranks:
        out.append(f" {r + 1} ", style="dim")
        for f in files:
            sq = chess.square(f, r)
            light = (f + r) % 2 == 1
            bg = (HILITE_L if light else HILITE_D) if sq in last else (LIGHT if light else DARK)
            p = g.board.piece_at(sq)
            if p:
                fg = "#ffffff" if p.color == chess.WHITE else "#101010"
                out.append(f" {GLYPH[p.piece_type]} ", style=f"bold {fg} on {bg}")
            else:
                out.append("   ", style=f"on {bg}")
        out.append("\n")
    out.append("    " + "".join(f" {chr(97 + f)} " for f in files), style="dim")
    return out


class Dashboard(App):
    TITLE = "Chess4Profit"
    CSS = """
    Screen { layout: vertical; }
    #head { height: auto; padding: 0 1; background: $boost; }
    #agents { height: auto; max-height: 9; }
    #mid { height: 1fr; }
    #games { width: 2fr; }
    #side { width: 1fr; min-width: 34; border-left: solid $primary-darken-2; padding: 0 1; }
    #board { height: 11; }
    #moves { height: 1fr; }
    #log { height: 9; border-top: solid $primary-darken-2; }
    DataTable { height: 1fr; }
    """
    BINDINGS = [
        Binding("q", "quit", "quit"),
        Binding("a", "toggle_all", "all/mine games"),
        Binding("f", "toggle_finished", "show/hide finished"),
        Binding("v", "flip", "flip board"),
    ]

    def __init__(self, monitor: Monitor, show_all: bool = False, interval: float = 0.5):
        super().__init__()
        self.mon = monitor
        self.show_all = show_all or not monitor.agents
        self.show_finished = True
        self.flip = False
        self.interval = interval
        self.selected: Optional[int] = None
        self._events: Deque[ev.Event] = deque()
        monitor.on_event = lambda e, g: self._events.append(e)

    def compose(self) -> ComposeResult:
        yield Static(id="head")
        yield DataTable(id="agents", cursor_type="none", zebra_stripes=True)
        with Horizontal(id="mid"):
            yield DataTable(id="games", cursor_type="row", zebra_stripes=True)
            with Vertical(id="side"):
                yield Static(id="title")
                yield Static(id="board")
                yield Static(id="moves")
        yield RichLog(id="log", markup=True, wrap=True)
        yield Footer()

    def on_mount(self) -> None:
        a = self.query_one("#agents", DataTable)
        a.add_columns("Agent", "Balance", "Δ balance", "Gas paid", "Gas used", "Txs", "W/D/L", "In play", "Games net")
        g = self.query_one("#games", DataTable)
        g.add_columns("#", "Status", "White", "Black", "Stake", "Plies", "Last", "Clock", "Result")
        self.poll()

    # ------------------------------------------------------------------ data loop (background thread)

    @work(thread=True, exclusive=True)
    def poll(self) -> None:
        while True:
            try:
                self.mon.refresh()
                err = None
            except Exception as e:  # keep the dashboard alive through RPC hiccups
                err = e
            self.call_from_thread(self.redraw, err)
            time.sleep(self.interval)

    # ------------------------------------------------------------------ drawing

    def redraw(self, err: Optional[Exception] = None) -> None:
        m = self.mon
        head = Text.assemble(
            ("♞ Chess4Profit ", "bold"), (f"block {m.block}  ", "dim"),
            ("fees collected ", "dim"), (f"{eth(m.fees_collected)} ETH  ", "bold yellow"),
            ("held in contract ", "dim"), (f"{eth(m.locked_total)} ETH  ", "bold"),
            (f"games {sum(1 for g in m.games.values() if g.active)} live / {len(m.games)} total", "dim"),
        )
        if err:
            head.append(f"\nRPC error: {err}", style="bold red")
        self.query_one("#head", Static).update(head)
        self._draw_agents()
        self._draw_games()
        self._draw_side()
        self._drain_events()

    def _draw_agents(self) -> None:
        t = self.query_one("#agents", DataTable)
        t.clear()
        for a in sorted(self.mon.agents.values(), key=lambda x: x.name):
            t.add_row(
                Text(a.name, style="bold cyan"), eth(a.balance), signed_eth(a.delta),
                Text(eth(a.gas_wei, 6), style="magenta"), f"{a.gas_used:,}", str(a.tx_count),
                Text.assemble((str(a.wins), "green"), "/", (str(a.draws), "yellow"), "/", (str(a.losses), "red")),
                eth(a.locked) if a.locked else "—", signed_eth(a.pnl_games),
            )

    def _visible(self):
        gs = [g for g in self.mon.games.values()
              if (self.show_all or self.mon.mine(g)) and (self.show_finished or g.active)
              and g.status != Status.CANCELLED]
        return sorted(gs, key=lambda g: (not g.active, -g.id))

    def _draw_games(self) -> None:
        t = self.query_one("#games", DataTable)
        keep = self.selected
        t.clear()
        now = time.time()
        rows = self._visible()
        for g in rows:
            if g.status == Status.OPEN:
                status, white, black = Text("waiting", style="yellow"), self.mon.name(g.creator), Text("—", style="dim")
            elif g.status == Status.ACTIVE:
                status, white, black = Text("● playing", style="bold green"), self.mon.name(g.white), self.mon.name(g.black)
            else:
                status, white, black = Text("finished", style="dim"), self.mon.name(g.white), self.mon.name(g.black)
            if g.status == Status.ACTIVE:
                left = int(g.deadline - now)
                clock = Text(f"{max(left, 0)}s", style="bold red" if left < 10 else "")
                mover = g.to_move()
                if mover:
                    clock.append(f"  {self.mon.name(mover)}", style="dim")
            else:
                clock = Text("")
            if g.status == Status.FINISHED:
                res = Text(f"{RESULT_TXT.get(g.result, '')} {g.reason.lower().replace('_', ' ')}")
                res.stylize("bold")
            else:
                res = Text("")
            last = (str(len(g.san) + 1 >> 1) + ("." if len(g.san) % 2 else "...") + g.san[-1]) if g.san else ""
            t.add_row(str(g.id), status, white, black, f"{eth(g.stake, 3)}", str(g.plies), last, clock, res,
                      key=str(g.id))
        if rows:
            ids = [str(g.id) for g in rows]
            want = str(keep) if keep is not None and str(keep) in ids else ids[0]
            t.move_cursor(row=ids.index(want), animate=False)
            self.selected = int(want)
        else:
            self.selected = None

    def _draw_side(self) -> None:
        g = self.mon.games.get(self.selected) if self.selected is not None else None
        title = Text("select a game", style="dim")
        if g:
            title = Text.assemble((f"Game #{g.id}  ", "bold"), (f"{eth(g.stake, 3)} ETH each  ", "yellow"),
                                  (f"{self.mon.name(g.white)}", "bold"), " vs ", (f"{self.mon.name(g.black)}", "bold"))
        self.query_one("#title", Static).update(title)
        self.query_one("#board", Static).update(render_board(g, self.flip))
        mv = Text()
        if g:
            for i in range(0, len(g.san), 2):
                mv.append(f"{i // 2 + 1}. ", style="dim")
                mv.append(g.san[i] + " ")
                if i + 1 < len(g.san):
                    mv.append(g.san[i + 1] + "  ")
            if len(mv) > 600:  # keep the tail visible
                mv = Text("… ") + mv[-600:]
        self.query_one("#moves", Static).update(mv)

    def _drain_events(self) -> None:
        log = self.query_one("#log", RichLog)
        while self._events:
            e = self._events.popleft()
            g = self.mon.games.get(e.game_id)
            n = self.mon.name
            if isinstance(e, ev.GameCreated):
                msg = f"[yellow]#{e.game_id}[/] {n(e.creator)} opens a table for {eth(e.stake, 3)} ETH"
            elif isinstance(e, ev.GameStarted):
                msg = f"[green]#{e.game_id}[/] {n(e.white)} (white) vs {n(e.black)} (black) — game on"
            elif isinstance(e, ev.MoveMade):
                msg = f"[dim]#{e.game_id}[/] {n(e.player)} plays [bold]{g.san[-1] if g and g.san else e.move.uci()}[/]"
            elif isinstance(e, ev.GameFinished):
                who = f"{n(e.winner)} wins {eth(e.payout, 4)} ETH" if e.winner else "draw, pot split"
                msg = f"[bold magenta]#{e.game_id}[/] finished: {e.reason.name.lower().replace('_', ' ')} — {who} (fee {eth(e.fee, 4)})"
            else:
                msg = f"#{e.game_id} {type(e).__name__}"
            if self.show_all or (g and self.mon.mine(g)):
                log.write(msg)

    # ------------------------------------------------------------------ interaction

    @on(DataTable.RowHighlighted, "#games")
    def _row(self, event: DataTable.RowHighlighted) -> None:
        if event.row_key and event.row_key.value is not None:
            self.selected = int(event.row_key.value)
            self._draw_side()

    def action_toggle_all(self) -> None:
        self.show_all = not self.show_all
        self.notify("showing all games" if self.show_all else "showing my agents' games only")

    def action_toggle_finished(self) -> None:
        self.show_finished = not self.show_finished

    def action_flip(self) -> None:
        self.flip = not self.flip
        self._draw_side()
