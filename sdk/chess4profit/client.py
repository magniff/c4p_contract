"""Client: wallet + contract + event stream, with human-friendly units (ETH, UCI/SAN moves)."""
from __future__ import annotations

import json
import random
import re
import threading
import time
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Iterator, List, Optional, Union

import chess
from eth_utils import keccak
from web3 import Web3
from web3.exceptions import TransactionNotFound

from . import events as ev
from .events import Reason, Result, Status
from .networks import resolve
from .wallet import Wallet



def load_abi() -> list:
    """Read at connect time (not import time) so a freshly exported ABI is always the one used."""
    return json.loads((Path(__file__).parent / "abi.json").read_text())
Amount = Union[int, float, str, Decimal]


class GasPriceTooHigh(Exception):
    """Refused to sign: the network fee exceeds Client.max_fee_gwei (protects the wallet from fee spikes)."""


class ContractError(Exception):
    """The contract refused the call; `.name` is its custom error (e.g. IllegalMove, NotYourTurn)."""

    def __init__(self, name: str):
        super().__init__(name)
        self.name = name


class TxDropped(ContractError):
    """A sent transaction vanished before being mined (mempool drop or reorg). State must be re-read."""

    def __init__(self, detail: str):
        super().__init__("TxDropped")
        self.detail = detail

    def __str__(self) -> str:
        return self.detail


@dataclass(frozen=True)
class GameInfo:
    id: int
    status: Status
    result: Result
    reason: Reason
    white: str
    black: str
    stake: int  # wei, per player
    increment: int  # seconds added per move
    white_time: int  # seconds on white's clock as of last_move_at
    black_time: int
    last_move_at: int
    deadline: int  # Open: last moment to join. Active: when the side to move can be flagged.
    plies: int
    white_to_move: bool

    @property
    def stake_eth(self) -> Decimal:
        return Decimal(self.stake) / 10**18

    @property
    def base_time(self) -> int:
        """Initial clock (only meaningful while the game is still Open)."""
        return self.white_time


def to_wei(eth: Amount) -> int:
    return int(Decimal(str(eth)) * 10**18)


class EventStream:
    """Ordered contract events. `poll()` is non-blocking; iterating blocks and yields forever (or until stop())."""

    CHUNK = 2000

    def __init__(self, client: "Client", game_id: Optional[int], from_block: int, poll_interval: float = 0.25):
        self.client, self.game_id, self.cursor, self.interval = client, game_id, from_block, poll_interval
        self._stop = False

    def poll(self) -> List[ev.Event]:
        c = self.client
        head = c.w3.eth.block_number
        out: List[ev.Event] = []
        while self.cursor <= head:
            to = min(head, self.cursor + self.CHUNK - 1)
            flt = {"address": c.contract.address, "fromBlock": self.cursor, "toBlock": to}
            if self.game_id is not None:
                flt["topics"] = [None, "0x" + hex(self.game_id)[2:].rjust(64, "0")]
            for log in c.w3.eth.get_logs(flt):
                name = c._topics.get(log["topics"][0].hex().removeprefix("0x"))
                if name is None:
                    continue
                parsed = ev.parse(name, c.contract.events[name]().process_log(log))
                if parsed is not None:
                    out.append(parsed)
            self.cursor = to + 1
        out.sort(key=lambda e: (e.block, e.log_index))
        return out

    def stop(self) -> None:
        self._stop = True

    def __iter__(self) -> Iterator[ev.Event]:
        while not self._stop:
            batch = self.poll()
            yield from batch
            if not batch:
                time.sleep(self.interval)


class Client:
    """
        c = Client.connect("local", wallet=Wallet.load_or_create())
        game = c.create_game(stake="0.01")        # or c.join_game(id) / c.play(...)
    """

    def __init__(self, w3: Web3, contract_address: str, wallet: Optional[Wallet] = None, local: bool = False,
                 max_fee_gwei: Optional[float] = 200.0):
        self.w3 = w3
        self.wallet = wallet
        self.local = local
        self.max_fee_gwei = max_fee_gwei  # never sign a tx whose max fee per gas exceeds this (None = no cap)
        self._tx_lock = threading.Lock()  # serialises nonce allocation when one Client is shared across threads
        abi = load_abi()
        self.contract = w3.eth.contract(address=Web3.to_checksum_address(contract_address), abi=abi)
        self._errors = {
            keccak(text=f"{e['name']}({','.join(i['type'] for i in e['inputs'])})")[:4].hex(): e["name"]
            for e in abi if e["type"] == "error"
        }
        self._topics = {
            keccak(text=f"{e['name']}({','.join(i['type'] for i in e['inputs'])})").hex().removeprefix("0x"): e["name"]
            for e in abi if e["type"] == "event"
        }

    @classmethod
    def connect(cls, network: str = "local", *, wallet: Optional[Wallet] = None, rpc: Optional[str] = None,
                contract: Optional[str] = None) -> "Client":
        n = resolve(network, rpc, contract)
        # explicit timeout: a silent RPC node must surface as an error the game loop can retry, not a hang
        w3 = Web3(Web3.HTTPProvider(n.rpc, request_kwargs={"timeout": 15}))
        if not w3.is_connected():
            raise ConnectionError(f"cannot reach {n.rpc}" + (" - is anvil running?" if n.local else ""))
        code = w3.eth.get_code(Web3.to_checksum_address(n.contract))
        if not code:
            raise ConnectionError(f"no contract at {n.contract} on {n.rpc} (deploy it, or set C4P_CONTRACT)")
        if n.codehash and "0x" + keccak(bytes(code)).hex() != n.codehash.lower():
            raise ConnectionError(
                f"the code at {n.contract} is NOT the official Chess4Profit build - refusing to connect "
                "(a wrong/poisoned address would send your stake to someone else's contract)"
            )
        return cls(w3, n.contract, wallet, n.local)

    # ------------------------------------------------------------------ account

    @property
    def address(self) -> str:
        if self.wallet is None:
            raise RuntimeError("this Client has no wallet")
        return self.wallet.address

    def balance(self) -> Decimal:
        return Decimal(self.w3.eth.get_balance(self.address)) / 10**18

    def pending(self) -> Decimal:
        """Payouts that couldn't be pushed to you (e.g. a contract wallet that rejected ETH)."""
        return Decimal(self.contract.functions.pending(self.address).call()) / 10**18

    def withdraw(self):
        return self.transact(self.contract.functions.withdraw())

    def chain_time(self) -> int:
        """The chain's notion of now. Clocks are judged against block timestamps, not your machine's clock."""
        return self.w3.eth.get_block("latest")["timestamp"]

    def dev_fund(self, eth: Amount = 100) -> None:
        """Local chains only: top up the wallet from thin air (anvil/hardhat)."""
        if not self.local:
            raise RuntimeError("dev_fund only works on a local dev chain")
        self.w3.provider.make_request("anvil_setBalance", [self.address, hex(to_wei(eth))])

    # ------------------------------------------------------------------ transactions

    def explain(self, exc: Exception) -> str:
        for sel in re.findall(r"0x([0-9a-fA-F]{8})", str(exc)):
            if sel.lower() in self._errors:
                return self._errors[sel.lower()]
        return str(exc)

    def transact(self, fn, value: int = 0, urgent: bool = False, receipt_timeout: float = 120.0):
        """Sign locally, send, wait for the receipt. Raises ContractError with the contract's error name.

        `urgent=True` triples the priority fee: used when a move clock is nearly out, so a congested
        or deliberately stuffed block can't flag you.
        """
        try:
            gas = fn.estimate_gas({"from": self.address, "value": value})
        except Exception as e:
            raise ContractError(self.explain(e)) from e
        with self._tx_lock:  # nonce fetch + send must be atomic per wallet
            tx = fn.build_transaction({
                "from": self.address, "value": value, "gas": int(gas * 1.25) + 20_000,
                "nonce": self.w3.eth.get_transaction_count(self.address, "pending"),
            })
            if urgent and "maxPriorityFeePerGas" in tx:
                tip = tx["maxPriorityFeePerGas"]
                tx["maxPriorityFeePerGas"] = tip * 3
                tx["maxFeePerGas"] += tip * 2
            cap = self.max_fee_gwei
            fee = tx.get("maxFeePerGas", tx.get("gasPrice", 0))
            if cap is not None and fee > cap * 10**9:
                raise GasPriceTooHigh(f"network fee {fee / 1e9:.2f} gwei exceeds the {cap} gwei safety cap")
            signed = self.wallet.account.sign_transaction(tx)
            h = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        rcpt = self._wait_receipt(h, receipt_timeout)
        if rcpt["status"] != 1:
            raise ContractError(f"transaction {h.hex()} reverted")
        return rcpt

    def _wait_receipt(self, h, timeout: float):
        """Like web3's wait_for_transaction_receipt, but gives up as soon as the transaction has vanished
        (dropped from the pool, or mined and then reorged out) instead of blocking for the full timeout
        while a chess clock is running. The game loop re-reads chain state and carries on."""
        end = time.monotonic() + timeout
        missing_since: Optional[float] = None
        while True:
            try:
                return self.w3.eth.get_transaction_receipt(h)
            except TransactionNotFound:
                pass
            try:
                self.w3.eth.get_transaction(h)
                missing_since = None
            except TransactionNotFound:
                missing_since = missing_since or time.monotonic()
                if time.monotonic() - missing_since > 3.0:  # tolerate brief propagation gaps
                    raise TxDropped(f"transaction {h.hex()} vanished (dropped or reorged out)")
            if time.monotonic() > end:
                raise TxDropped(f"transaction {h.hex()} not mined within {timeout:.0f}s")
            time.sleep(0.3)

    # ------------------------------------------------------------------ lobby

    def create_game(self, stake: Optional[Amount] = None, *, stake_wei: Optional[int] = None,
                    base_time: int = 300, increment: int = 2, colour: str = "random") -> "Game":
        """Lock `stake` (ETH) and open a game. Each player gets `base_time` seconds plus `increment` per move
        (a total clock, so an opponent cannot stretch the game by playing slowly). `colour`: white|black|random.
        Open games expire after an hour; the stake is refundable at any time with game.cancel()."""
        from .game import Game
        wei = stake_wei if stake_wei is not None else to_wei(stake)
        white = {"white": True, "black": False, "random": random.random() < 0.5}[colour]
        rcpt = self.transact(self.contract.functions.createGame(base_time, increment, white), value=wei)
        gid = self.contract.events.GameCreated().process_receipt(rcpt)[0]["args"]["gameId"]
        return Game(self, gid, start_block=rcpt["blockNumber"])

    def join_game(self, game_id: int) -> "Game":
        from .game import Game
        info = self.game_info(game_id)
        rcpt = self.transact(self.contract.functions.joinGame(game_id), value=info.stake)
        return Game(self, game_id, start_block=rcpt["blockNumber"])

    def game(self, game_id: int) -> "Game":
        from .game import Game
        return Game(self, game_id)

    def game_info(self, game_id: int) -> GameInfo:
        r = self.contract.functions.getGame(game_id).call()
        return GameInfo(r[0], Status(r[1]), Result(r[2]), Reason(r[3]), *r[4:])

    def table(self, stake: Amount, base_time: int, increment: int) -> bytes:
        """Identifier of a table. Games are matched only with an identical stake AND clock."""
        return self.contract.functions.lobbyKey(to_wei(stake), base_time, increment).call()

    def open_games(self, stake: Amount, base_time: int = 300, increment: int = 2, limit: int = 20,
                   include_own: bool = False) -> List[GameInfo]:
        """Joinable games at exactly this table, newest first. The contract indexes per table, so games with
        other stakes or other clocks (however many) can't crowd these out, and anything that IS listed here
        has terms you already agreed to."""
        t = self.table(stake, base_time, increment)
        ids = self.contract.functions.openGames(t, limit, limit * 4).call()
        out = []
        for gid in ids:
            g = self.game_info(gid)
            if g.status != Status.OPEN:
                continue
            if not include_own and g.white.lower() == self.address.lower():
                continue  # while open, `white` holds the creator
            out.append(g)
        return out

    def sweep_expired(self, stake: Amount, base_time: int = 300, increment: int = 2, limit: int = 10):
        """Refund up to `limit` expired open games at a table to their creators (anyone may do this)."""
        return self.transact(self.contract.functions.sweepExpired(self.table(stake, base_time, increment), limit))

    # ------------------------------------------------------------------ events

    def events(self, game_id: Optional[int] = None, from_block: Optional[int] = None,
               poll_interval: float = 0.25) -> EventStream:
        """Stream of typed events (all games, or one). Starts at `from_block` (default: now)."""
        start = self.w3.eth.block_number if from_block is None else from_block
        return EventStream(self, game_id, start, poll_interval)

    # ------------------------------------------------------------------ one-liners

    def play(self, engine="builtin", *, stake: Amount, base_time: int = 300, increment: int = 2,
             colour: str = "random", movetime: float = 0.3, auto_sweep: bool = True, log=print) -> GameInfo:
        """Sit at the (stake, base_time, increment) table: join the oldest open game there, or open one and
        wait. Then play it to the end.

        You only ever join games whose terms equal the ones you would create, so a hostile creator cannot
        hand you a clock you didn't agree to, and two copies of this bot always find each other. The defaults
        (300s + 2s/move) leave room for block latency: a 30s-total clock is legal for the contract but
        unplayable on-chain.

        Transaction ordering caveat: if someone joins your table in the instant before you cancel it, the
        cancel reverts and you are in a live game. This loop then plays it. Don't exit a bot that may have a
        live game: the clock keeps running and the stake is forfeited on time.
        """
        from .engine import as_chooser
        from .game import Game

        choose = as_chooser(engine)  # validate the engine BEFORE any stake is at risk
        mine: Optional[Game] = None
        try:
            while True:
                candidates = self.open_games(stake, base_time, increment)
                target = min((g.id for g in candidates), default=None)  # oldest first: converge, don't churn
                if auto_sweep and not candidates:
                    self._maybe_sweep(stake, base_time, increment, log)
                if mine is not None:
                    info = self.game_info(mine.id)
                    if info.status in (Status.ACTIVE, Status.FINISHED):
                        # FINISHED here means someone joined and the game ended before we looked (e.g. an
                        # instant resignation): that is a result to return, not a table to abandon
                        return mine.play(choose, movetime=movetime, log=log)
                    if info.status == Status.CANCELLED:  # swept under us
                        log(f"game #{mine.id} was cancelled while waiting; reopening")
                        mine = None
                    elif self.chain_time() >= info.deadline or (target is not None and target < mine.id):
                        # expired (joins are refused now), or an older table exists: take our stake back
                        try:
                            mine.cancel()
                            mine = None
                        except ContractError as e:
                            # NotOpen = somebody joined in the meantime: we are in a live game, play it
                            if self.game_info(mine.id).status == Status.ACTIVE:
                                return mine.play(choose, movetime=movetime, log=log)
                            log(f"cancel of #{mine.id} failed: {e.name}")
                if mine is None and target is not None:
                    try:
                        return self.join_game(target).play(choose, movetime=movetime, log=log)
                    except ContractError as e:  # taken, expired or cancelled under us: just look again
                        log(f"could not join #{target}: {e.name}")
                elif mine is None:
                    mine = self.create_game(stake, base_time=base_time, increment=increment, colour=colour)
                    log(f"opened game #{mine.id}, waiting for an opponent...")
                time.sleep(0.5)
        except KeyboardInterrupt:
            if mine is not None:
                try:
                    mine.cancel()
                    log(f"stake of game #{mine.id} refunded")
                except ContractError:
                    if self.game_info(mine.id).status == Status.ACTIVE:
                        log(f"WARNING: game #{mine.id} went LIVE as you quit. Restart the bot now or you "
                            "forfeit the stake on time: client.game({}).play(...)".format(mine.id))
            raise
        finally:
            close = getattr(choose, "close", None)
            if close:
                close()

    def _maybe_sweep(self, stake: Amount, base_time: int, increment: int, log) -> None:
        """A table clogged with expired entries makes lookups miss; refund a few (anyone may)."""
        t = self.table(stake, base_time, increment)
        if self.contract.functions.openGameCount(t).call() > 25:
            try:
                rcpt = self.transact(self.contract.functions.sweepExpired(t, 10))
                log(f"swept expired games at the table (tx {rcpt['transactionHash'].hex()[:10]}...)")
            except ContractError as e:
                log(f"sweep failed: {e.name}")
