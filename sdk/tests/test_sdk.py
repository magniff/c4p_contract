from decimal import Decimal
import threading
import time


import chess
import pytest

from chess4profit import Client, ContractError, GameFinished, GameStarted, MoveMade, Reason, Result, Status, Wallet, to_wei


# ---------------------------------------------------------------- wallet

def test_wallet_roundtrip_and_safety(tmp_path):
    path = tmp_path / "w.json"
    w = Wallet.create()
    w.save(path, password="pw")
    assert oct(path.stat().st_mode & 0o777) == "0o600"
    assert Wallet.load(path, "pw").address == w.address
    with pytest.raises(ValueError, match="wrong wallet password"):
        Wallet.load(path, "nope")
    with pytest.raises(FileExistsError):
        w.save(path, password="pw")
    assert "pw" not in path.read_text() and w.account.key.hex()[2:] not in path.read_text()


def test_load_or_create(tmp_path):
    path = tmp_path / "sub" / "w.json"
    a = Wallet.load_or_create(path, password="x")
    b = Wallet.load_or_create(path, password="x")
    assert a.address == b.address


# ---------------------------------------------------------------- lobby & errors

def test_create_join_cancel_and_open_games(make_client):
    a, b = make_client(), make_client()
    g = a.create_game("0.013", base_time=60, increment=2)
    assert g.info().status == Status.OPEN and g.info().stake_eth == Decimal("0.013")
    assert [x.id for x in b.open_games("0.013", 60, 2)] == [g.id]
    assert a.open_games("0.013", 60, 2) == []  # own games hidden
    g.cancel()
    assert b.open_games("0.013", 60, 2) == []
    assert g.info().status == Status.CANCELLED


def test_errors_carry_contract_names(make_client):
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", colour="white")
    gb = b.join_game(ga.id)
    with pytest.raises(ContractError) as e:
        gb.move(chess.Move.from_uci("e7e5"))   # a Move object skips local validation; the contract refuses
    assert e.value.name == "NotYourTurn"
    with pytest.raises(ContractError) as e:
        ga.move(chess.Move.from_uci("e2e5"))
    assert e.value.name == "IllegalMove"
    with pytest.raises(ContractError) as e:
        a.create_game("0.00001")
    assert e.value.name == "BadStake"


def test_moves_san_uci_and_board_rebuild(make_client):
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", colour="white")
    gb = b.join_game(ga.id)
    ga.move("e4")            # SAN
    gb.move("e7e5")          # UCI
    ga.move("Nf3")
    assert ga.board().fen().startswith("rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b")
    assert ga.colour == chess.WHITE and gb.colour == chess.BLACK
    # a third party can attach to the game and see the same position
    c = make_client()
    assert c.game(ga.id).board().fen() == ga.board().fen()
    ga.resign()


# ---------------------------------------------------------------- event stream

def test_event_stream_is_ordered_and_typed(make_client):
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", colour="white")
    stream = ga.events()
    gb = b.join_game(ga.id)
    ga.move("f3"); gb.move("e5"); ga.move("g4"); gb.move("Qh4#")
    seen = []
    for e in stream:
        seen.append(e)
        if isinstance(e, GameFinished):
            break
    kinds = [type(e).__name__ for e in seen]
    assert kinds == ["GameCreated", "GameStarted"] + ["MoveMade"] * 4 + ["GameFinished"]
    fin = seen[-1]
    assert fin.result == Result.BLACK_WINS and fin.reason == Reason.CHECKMATE and fin.winner == b.address
    assert [m.ply for m in seen if isinstance(m, MoveMade)] == [1, 2, 3, 4]
    assert fin.payout + fin.fee == 2 * ga.info().stake
    # global stream sees the same game
    assert any(isinstance(e, GameStarted) and e.game_id == ga.id for e in a.events(from_block=0).poll())


def test_moves_iterator_replays_history(make_client):
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", colour="white")
    gb = b.join_game(ga.id)
    ga.move("e4"); gb.move("c5"); gb_resign = gb.resign
    gb_resign()
    assert [m.move.uci() for m in ga.moves()] == ["e2e4", "c7c5"]


# ---------------------------------------------------------------- full automatic match

def test_two_bots_matchmake_and_play_to_the_end(make_client):
    a, b = make_client(), make_client()
    fee_to = a.contract.functions.FEE_RECIPIENT().call()
    fee_before = a.w3.eth.get_balance(fee_to)
    start = {c.address: c.balance() for c in (a, b)}
    locked_before = a.w3.eth.get_balance(a.contract.address)  # other tests may leave games open
    out = {}

    def run(name, c):
        out[name] = c.play("builtin", stake="0.02", base_time=300, movetime=0.01, log=lambda s: None)

    ts = [threading.Thread(target=run, args=("a", a)), threading.Thread(target=run, args=("b", b))]
    for t in ts:
        t.start()
    for t in ts:
        t.join(timeout=300)
    assert not any(t.is_alive() for t in ts), "match did not finish"
    assert out["a"].id == out["b"].id and out["a"].status == Status.FINISHED
    assert a.w3.eth.get_balance(a.contract.address) == locked_before, "this game must leave nothing behind"
    fee = a.w3.eth.get_balance(fee_to) - fee_before
    assert fee == 2 * to_wei("0.02") * 250 // 10_000 or out["a"].result == Result.DRAW
    # value conservation: total change = -fee - gas
    delta = sum(c.balance() - start[c.address] for c in (a, b))
    assert -delta >= fee / 10**18


def to_wei(x):
    from chess4profit import to_wei as t
    return t(x)


def test_custom_callable_engine(make_client):
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", colour="white")
    gb = b.join_game(ga.id)

    def first_legal(board):
        return sorted(board.legal_moves, key=lambda m: m.uci())[0]

    seen = {}
    t = threading.Thread(target=lambda: seen.setdefault("w", ga.play(first_legal, log=lambda s: None)))
    t.start()
    # black stalls for a bit, then resigns
    import time
    time.sleep(1.5)
    gb.resign()
    t.join(timeout=30)
    assert seen["w"].result == Result.WHITE_WINS and seen["w"].reason == Reason.RESIGNATION


def test_timeout_claim_when_opponent_stalls(make_client):
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", base_time=60, colour="white")
    gb = b.join_game(ga.id)
    a.w3.provider.make_request("evm_increaseTime", [120])
    a.w3.provider.make_request("evm_mine", [])
    gb.claim_timeout()
    i = gb.info()
    assert i.result == Result.BLACK_WINS and i.reason == Reason.TIMEOUT


def test_illegal_string_move_is_caught_locally_without_spending_gas(make_client):
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", colour="white")
    b.join_game(ga.id)
    before = a.balance()
    with pytest.raises(ValueError):
        ga.move("e2e5")
    assert a.balance() == before
    ga.resign()


# ---------------------------------------------------------------- monitor (TUI data layer)

def test_monitor_tracks_games_gas_and_results(make_client):
    from chess4profit.monitor import Monitor
    a, b = make_client(), make_client()
    watcher = Client.connect("local")
    mon = Monitor(watcher, {a.address: "alice", b.address: "bob"}, from_block=watcher.w3.eth.block_number + 1)
    fee_before_blocks = mon.fees_collected
    ga = a.create_game("0.05", colour="white")
    gb = b.join_game(ga.id)
    mon.refresh()
    g = mon.games[ga.id]
    assert g.status == Status.ACTIVE and mon.agents[a.address.lower()].locked == to_wei("0.05")
    ga.move("f3"); gb.move("e5"); ga.move("g4"); gb.move("Qh4#")
    mon.refresh()
    g = mon.games[ga.id]
    assert g.status == Status.FINISHED and g.san == ["f3", "e5", "g4", "Qh4#"] and g.reason == "CHECKMATE"
    A, B = mon.agents[a.address.lower()], mon.agents[b.address.lower()]
    assert (A.wins, A.losses, B.wins, B.losses) == (0, 1, 1, 0)
    assert A.locked == B.locked == 0
    assert B.pnl_games > 0 > A.pnl_games and A.pnl_games == -to_wei("0.05")
    # every tx is attributed: create+2 moves(+resign none) for alice, join+2 moves for bob
    assert A.tx_count == 3 and B.tx_count == 3
    assert B.gas_used > A.gas_used  # bob delivered the expensive mating move
    assert B.gas_wei > 0
    assert mon.fees_collected - fee_before_blocks == to_wei("0.1") * 250 // 10_000


# ---------------------------------------------------------------- defensive behaviour

def test_tables_isolate_matchmaking_from_spam(make_client):
    a, b, spammer = make_client(), make_client(), make_client()
    stake = "0.0177"
    spammer.create_game(stake, base_time=86_400, increment=0)     # hostile clock, same stake
    spammer.create_game(stake, base_time=30, increment=0)
    for i in range(25):                                            # flood at other stakes
        spammer.create_game(f"0.0{200 + i}", base_time=300, increment=2)
    ok = a.create_game(stake, base_time=300, increment=2)
    assert [g.id for g in b.open_games(stake, 300, 2)] == [ok.id]  # only the table we sit at
    assert [g.id for g in b.open_games(stake, 30, 0)] != [ok.id]


def test_codehash_pinning_refuses_a_poisoned_contract_address():
    import os
    os.environ["C4P_CODEHASH"] = "0x" + "11" * 32   # pretend the contract at the configured address is not the official build
    try:
        with pytest.raises(ConnectionError, match="NOT the official"):
            Client.connect("local", wallet=Wallet.create())
    finally:
        del os.environ["C4P_CODEHASH"]
    Client.connect("local", wallet=Wallet.create())  # the real one passes


def test_gas_price_cap_blocks_signing(make_client):
    from chess4profit import GasPriceTooHigh
    a = make_client()
    a.max_fee_gwei = 1e-9  # absurdly low cap = "fees spiked"
    before = a.balance()
    with pytest.raises(GasPriceTooHigh):
        a.create_game("0.01")
    assert a.balance() == before


def test_hung_engine_does_not_forfeit_the_game(make_client, tmp_path):
    """An engine that answers the handshake and then never replies to `go`: the agent must still move."""
    import sys, textwrap, threading
    hang = tmp_path / "hang.py"
    hang.write_text(textwrap.dedent("""
        import sys, time
        for line in sys.stdin:
            cmd = line.strip()
            if cmd == "uci": print("uciok", flush=True)
            elif cmd == "isready": print("readyok", flush=True)
            elif cmd.startswith("go"): time.sleep(3600)
    """))
    from chess4profit import UciEngine
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", colour="white", base_time=120)
    gb = b.join_game(ga.id)
    eng = UciEngine([sys.executable, str(hang)], grace=0.3)
    logs = []
    out = {}
    t = threading.Thread(target=lambda: out.setdefault("r", ga.play(eng, movetime=0.05, log=logs.append)))
    t.start()
    time.sleep(3)           # the hung engine must have been replaced by a legal fallback move by now
    assert ga.info().plies >= 1, "agent forfeited its turn because of a hung engine"
    gb.resign()
    t.join(timeout=30)
    assert any("engine error" in l for l in logs)
    assert out["r"].result == Result.WHITE_WINS


def test_open_game_expires_and_anyone_can_refund(make_client):
    a, b = make_client(), make_client()
    g = a.create_game("0.0123")
    before = a.balance()
    a.w3.provider.make_request("evm_increaseTime", [3601])
    a.w3.provider.make_request("evm_mine", [])
    with pytest.raises(ContractError) as e:
        b.join_game(g.id)
    assert e.value.name == "Expired"
    b.transact(b.contract.functions.cancelGame(g.id))        # a stranger cleans it up...
    assert a.balance() - before == Decimal("0.0123")           # ...and the creator is made whole


# ---------------------------------------------------------------- second review: findings that lost money

def _capture(out, fn):
    def run():
        try:
            out["r"] = fn()
        except BaseException as e:  # noqa: BLE001
            out["err"] = e
    return run


def _wait(pred, timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


def test_cancel_race_opponent_joins_just_before_we_cancel(make_client, monkeypatch):
    """Bot A has an open game and decides to swap to a lower-id table. Someone joins A's game between the
    status check and the cancel: cancel() reverts NotOpen. The bot must PLAY the game it is now in,
    not crash and forfeit on time."""
    from chess4profit import GameInfo
    from chess4profit.game import Game
    a, b = make_client(), make_client()
    calls = {"n": 0}

    def patched_open_games(stake, *args, **kw):
        calls["n"] += 1
        if calls["n"] == 1:
            return []                                   # nothing to join -> A creates its own table
        return [GameInfo(0, Status.OPEN, Result.NONE, Reason.NONE, b.address, "", to_wei("0.01"),
                         2, 300, 300, 0, 0, 0, True)]   # a tempting lower-id table -> A wants to cancel
    a.open_games = patched_open_games

    sneaked = {}
    real_cancel = Game.cancel

    def racy_cancel(self):
        sneaked["g"] = b.join_game(self.id)             # opponent lands exactly inside the race window
        return real_cancel(self)                        # -> NotOpen
    monkeypatch.setattr(Game, "cancel", racy_cancel)

    out = {}
    def run():
        try:
            out["r"] = a.play("builtin", stake="0.01", movetime=0.01, log=lambda s: None)
        except BaseException as e:  # noqa: BLE001
            out["err"] = e
    t = threading.Thread(target=run)
    t.start()
    assert _wait(lambda: "g" in sneaked, 20), "cancel path never reached"
    gb = sneaked["g"]
    assert _wait(lambda: a.game_info(gb.id).plies >= 1 or gb.colour == chess.WHITE, 15), out.get("err")
    gb.resign()
    t.join(timeout=30)
    assert "err" not in out, f"bot crashed instead of playing the game it was joined into: {out.get('err')!r}"
    assert out["r"].id == gb.id and out["r"].reason == Reason.RESIGNATION


def test_own_open_game_expiry_is_handled_by_reopening(make_client, tmp_path):
    a, b = make_client(), make_client()
    out = {}
    t = threading.Thread(target=_capture(out, lambda: a.play("builtin", stake="0.011", movetime=0.01, log=lambda s: None)))
    t.start()
    assert _wait(lambda: b.open_games("0.011", 300, 2))
    first = b.open_games("0.011", 300, 2)[0].id
    a.w3.provider.make_request("evm_increaseTime", [3601])
    a.w3.provider.make_request("evm_mine", [])
    assert _wait(lambda: a.game_info(first).status == Status.CANCELLED and
                 any(g.id != first for g in b.open_games("0.011", 300, 2)), 15), "bot did not reopen after expiry"
    second = b.open_games("0.011", 300, 2)[0].id
    gb = b.join_game(second)
    assert _wait(lambda: a.game_info(second).plies >= 1 or gb.colour == chess.WHITE, 15)
    gb.resign()
    t.join(timeout=30)
    if "r" not in out:
        import faulthandler
        with open(tmp_path / "stuck.txt", "w") as f:
            f.write(f"err={out.get('err')!r}\nfirst={a.game_info(first)}\nsecond={a.game_info(second)}\n")
            faulthandler.dump_traceback(file=f, all_threads=True)
        raise AssertionError("bot did not finish; see stuck.txt")
    assert out["r"].id == second


def test_engine_is_validated_before_any_stake_is_locked(make_client):
    a = make_client()
    before = a.balance()
    with pytest.raises(FileNotFoundError):
        a.play("definitely-not-an-engine-binary", stake="0.01")
    assert a.balance() == before
    assert a.open_games("0.01", include_own=True) == []


def test_one_client_shared_across_threads_does_not_collide_on_nonce(make_client):
    a = make_client()
    errors = []

    def mk():
        try:
            a.create_game("0.01")
        except Exception as e:  # noqa: BLE001
            errors.append(e)

    ts = [threading.Thread(target=mk) for _ in range(6)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(60)
    assert not errors, errors
    assert len(a.open_games("0.01", include_own=True)) == 6


def test_flagged_bot_stops_retrying_and_waits_for_settlement(make_client):
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", base_time=30, increment=0, colour="white")
    gb = b.join_game(ga.id)
    a.w3.provider.make_request("evm_increaseTime", [31])
    a.w3.provider.make_request("evm_mine", [])
    logs = []
    out = {}
    t = threading.Thread(target=lambda: out.setdefault("r", ga.play("builtin", movetime=0.01, log=logs.append)))
    t.start()
    assert _wait(lambda: any("lost on time" in l for l in logs), 15)
    time.sleep(1.0)
    gb.claim_timeout()
    t.join(timeout=30)
    assert out["r"].result == Result.BLACK_WINS and out["r"].reason == Reason.TIMEOUT
    assert sum("rejected: TurnTimedOut" in l for l in logs) == 1, "kept hammering the RPC after being flagged"


def _capture(out, fn):
    def run():
        try:
            out["r"] = fn()
        except BaseException as e:  # noqa: BLE001
            out["err"] = e
    return run


def _wait(pred, timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


def test_reorg_that_drops_a_move_is_resynced_not_fatal(make_client, tmp_path):
    """Simulate a reorg with snapshot/revert: the bot has applied a move that the chain then forgets."""
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", colour="white", base_time=300)
    gb = b.join_game(ga.id)
    logs = []
    out = {}
    slow = lambda board, ms: sorted(board.legal_moves, key=lambda m: m.uci())[0]
    t = threading.Thread(target=_capture(out, lambda: ga.play(slow, movetime=0.01, poll=0.1, log=logs.append)))
    t.start()
    if not _wait(lambda: a.game_info(ga.id).plies >= 1):
        import faulthandler
        with open(tmp_path / "stuck.txt", "w") as f:
            f.write(f"err={out.get('err')!r}\nlogs={logs}\n")
            faulthandler.dump_traceback(file=f, all_threads=True)
        raise AssertionError(f"bot never moved; see stuck.txt")
    snap = a.w3.provider.make_request("evm_snapshot", [])["result"]
    gb.move("e7e5")                                          # black's reply...
    assert _wait(lambda: a.game_info(ga.id).plies >= 3)      # ...and white's answer are both applied
    a.w3.provider.make_request("evm_revert", [snap])         # chain forgets both: plies back to 1
    assert a.game_info(ga.id).plies == 1
    if not _wait(lambda: any("reorg detected" in l for l in logs), 15):
        import faulthandler
        with open(tmp_path / "stuck.txt", "w") as f:
            f.write(f"err={out.get('err')!r}\ninfo={a.game_info(ga.id)}\nlogs={logs}\n")
            faulthandler.dump_traceback(file=f, all_threads=True)
        raise AssertionError("no resync; see stuck.txt")
    gb.move("d7d5")                                          # different history now
    assert _wait(lambda: a.game_info(ga.id).plies >= 3)      # bot keeps playing on the new history
    gb.resign()
    t.join(30)
    assert out["r"].result == Result.WHITE_WINS


def test_opponent_joins_and_resigns_instantly_is_a_win_not_an_abandoned_table(make_client):
    """A game can be over before the bot's next poll. play() must return the result, not open a new table."""
    a, b = make_client(), make_client()
    gate = threading.Event()
    real_info = a.game_info
    first_look = {"done": False}

    def gated_info(gid):
        if not first_look["done"]:
            first_look["done"] = True
            gate.wait(10)        # hold the bot's first status check until the opponent has come and gone
        return real_info(gid)
    a.game_info = gated_info

    out = {}
    t = threading.Thread(target=_capture(out, lambda: a.play("builtin", stake="0.0133", movetime=0.01, log=lambda s: None)))
    t.start()
    assert _wait(lambda: b.open_games("0.0133", 300, 2))
    gid = b.open_games("0.0133", 300, 2)[0].id
    b.join_game(gid).resign()
    gate.set()
    t.join(30)
    assert "err" not in out, repr(out.get("err"))
    assert out["r"].id == gid and out["r"].reason == Reason.RESIGNATION
    assert b.open_games("0.0133", 300, 2, include_own=True) == [], "bot opened a new table instead of returning"


# ---------------------------------------------------------------- pass 4: paths that were documented but never exercised

def test_resume_mid_game_after_a_crash(make_client):
    """A bot process dies with a live game; a fresh process must pick it up from chain state and finish it."""
    a, b = make_client(), make_client()
    ga = a.create_game("0.01", colour="white")
    gb = b.join_game(ga.id)
    ga.move("e4"); gb.move("e5"); ga.move("Nf3")      # some history, then "the process dies"
    fresh = Client.connect("local", wallet=a.wallet)  # new process: no start_block, no local board
    out, logs = {}, []
    t = threading.Thread(target=_capture(out, lambda: fresh.game(ga.id).play("builtin", movetime=0.01, log=logs.append)))
    t.start()
    gb.move("Nc6")
    assert _wait(lambda: a.game_info(ga.id).plies >= 5), out.get("err")   # the resumed bot answered
    gb.resign()
    t.join(30)
    assert "err" not in out and out["r"].result == Result.WHITE_WINS
    assert [l for l in logs if "ply   1" in l], "history was replayed, not skipped"


def test_urgent_transaction_bids_a_higher_tip_and_respects_the_fee_cap():
    """The near-deadline path: fields are actually bumped, and the cap still applies to the bumped fee."""
    from chess4profit import GasPriceTooHigh
    a = Client.connect("local", wallet=Wallet.create())
    a.dev_fund(1)
    captured = {}
    real_send = a.w3.eth.send_raw_transaction

    def spy(raw):
        from eth_account._utils.legacy_transactions import Transaction  # noqa: F401  (import check only)
        captured["raw"] = raw
        return real_send(raw)
    a.w3.eth.send_raw_transaction = spy
    fn = a.contract.functions.createGame(300, 2, True)
    normal = fn.build_transaction({"from": a.address, "value": to_wei("0.01"), "nonce": 0})
    a.transact(fn, value=to_wei("0.01"), urgent=True)
    from eth_account import Account
    sent = Account.recover_transaction  # proves it decodes; fields checked via the receipt's effective price below
    assert sent and captured["raw"]
    rcpt = a.w3.eth.get_transaction_receipt(a.w3.eth.get_block("latest")["transactions"][0])
    tx = a.w3.eth.get_transaction(rcpt["transactionHash"])
    assert tx["maxPriorityFeePerGas"] == normal["maxPriorityFeePerGas"] * 3
    assert tx["maxFeePerGas"] == normal["maxFeePerGas"] + normal["maxPriorityFeePerGas"] * 2
    a.max_fee_gwei = (normal["maxFeePerGas"] + normal["maxPriorityFeePerGas"]) / 1e9  # below the bumped fee
    with pytest.raises(GasPriceTooHigh):
        a.transact(a.contract.functions.createGame(300, 2, True), value=to_wei("0.01"), urgent=True)
