"""Differential fuzzer: random games played through the real contract on anvil, checked move by move
against python-chess. Verifies for every position:
  * contract legalMoves == python-chess legal moves (completeness + soundness)
  * sampled illegal moves are rejected (soundness)
  * packed board / castling / en-passant / clocks / king squares match
  * game-over detection (mate, stalemate, insufficient material, 50-move, threefold) fires exactly when expected
  * payouts conserve value (contract ends with 0 balance)

  .venv/bin/python scripts/fuzz_vs_pythonchess.py --games 20 --seed 1
"""
from __future__ import annotations

import argparse
import collections
import random
import sys
import time
from pathlib import Path

import chess
from web3 import Web3

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from chess4profit import Client, Reason, Result, Status, Wallet  # noqa: E402
from chess4profit.events import encode_move  # noqa: E402
from devchain import deploy, start_anvil  # noqa: E402

# public anvil dev keys #1 and #2
KEYS = [None,
        "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"]

PIECE_NIBBLE = {chess.PAWN: 1, chess.KNIGHT: 2, chess.BISHOP: 3, chess.ROOK: 4, chess.QUEEN: 5, chess.KING: 6}


def expected_board_int(board: chess.Board) -> int:
    v = 0
    for sq, pc in board.piece_map().items():
        v |= (PIECE_NIBBLE[pc.piece_type] | (0 if pc.color == chess.WHITE else 8)) << (4 * sq)
    return v


def castling_bits(board: chess.Board) -> int:
    return (
        (1 if board.has_kingside_castling_rights(chess.WHITE) else 0)
        | (2 if board.has_queenside_castling_rights(chess.WHITE) else 0)
        | (4 if board.has_kingside_castling_rights(chess.BLACK) else 0)
        | (8 if board.has_queenside_castling_rights(chess.BLACK) else 0)
    )


def contract_insufficient(board: chess.Board) -> bool:
    """Contract rule: K vs K, K+minor vs K."""
    minors = 0
    for pc in board.piece_map().values():
        if pc.piece_type in (chess.PAWN, chess.ROOK, chess.QUEEN):
            return False
        if pc.piece_type in (chess.KNIGHT, chess.BISHOP):
            minors += 1
    return minors <= 1


def expected_end(board: chess.Board):
    if board.is_checkmate():
        return Reason.CHECKMATE
    if board.is_stalemate():
        return Reason.STALEMATE
    if contract_insufficient(board):
        return Reason.INSUFFICIENT_MATERIAL
    if board.halfmove_clock >= 100:
        return Reason.FIFTY_MOVE_RULE
    if repetition3(board):
        return Reason.THREEFOLD_REPETITION
    return None


def repetition3(board: chess.Board) -> bool:
    """Same key the contract uses: placement, side to move, castling rights, ep square only if a pawn can take."""
    def key(b: chess.Board):
        ep = b.ep_square if b.has_pseudo_legal_en_passant() else None
        return (b.board_fen(), b.turn, castling_bits(b), ep)

    replay = chess.Board()
    seen = collections.Counter([key(replay)])
    for m in board.move_stack:
        replay.push(m)
        seen[key(replay)] += 1
    return seen[key(board)] >= 3


def pick_move(board: chess.Board, rng: random.Random) -> chess.Move:
    moves = list(board.legal_moves)
    weights = []
    for m in moves:
        w = 1.0
        if m.promotion:
            w *= 25
        if board.is_castling(m):
            w *= 12
        if board.is_en_passant(m):
            w *= 40
        elif board.is_capture(m):
            w *= 3
        weights.append(w)
    return rng.choices(moves, weights)[0]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--games", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--max-plies", type=int, default=500)
    ap.add_argument("--illegal-samples", type=int, default=4)
    a = ap.parse_args()

    rng = random.Random(a.seed)
    anvil = start_anvil()
    stats = collections.Counter()
    t0 = time.time()
    try:
        addr = deploy()
        w1 = Client.connect("local", wallet=Wallet.from_private_key(KEYS[1]), contract=addr)
        w2 = Client.connect("local", wallet=Wallet.from_private_key(KEYS[2]), contract=addr)
        by_addr = {w1.address: w1, w2.address: w2}
        fn = w1.contract.functions
        stake = Web3.to_wei(1, "ether")

        for gi in range(a.games):
            gid = by_addr[w1.address].contract.events.GameCreated().process_receipt(
                w1.transact(fn.createGame(3600, 0, rng.random() < 0.5), value=stake)
            )[0]["args"]["gameId"]
            w2.transact(w2.contract.functions.joinGame(gid), value=stake)
            g = w1.game_info(gid)
            players = {chess.WHITE: by_addr[g.white], chess.BLACK: by_addr[g.black]}
            board = chess.Board()
            plies = 0
            while True:
                # --- completeness / soundness of the legal move set
                want = sorted(encode_move(m) for m in board.legal_moves)
                got = sorted(fn.legalMoves(gid).call({"gas": 100_000_000}))
                assert got == want, f"game {gi} ply {plies}: legalMoves mismatch\n{board.fen()}\nextra={set(got)-set(want)} missing={set(want)-set(got)}"
                legal_set = set(want)
                for _ in range(a.illegal_samples):
                    cand = rng.randrange(1 << 16) if rng.random() < 0.3 else (rng.randrange(64) | (rng.randrange(64) << 6) | (rng.choice([0, 0, 2, 3, 4, 5, 6]) << 12))
                    assert fn.isMoveLegal(gid, cand).call() == (cand in legal_set), f"isMoveLegal({cand}) wrong at {board.fen()}"
                    stats["illegal_probes"] += 1

                # --- play
                m = pick_move(board, rng)
                stats["promotions"] += bool(m.promotion)
                stats["castles"] += board.is_castling(m)
                stats["en_passant"] += board.is_en_passant(m)
                stats["captures"] += board.is_capture(m)
                mover = players[board.turn]
                if rng.random() < 0.1:  # wrong player must be refused
                    other = players[not board.turn]
                    try:
                        other.transact(other.contract.functions.makeMove(gid, encode_move(m)))
                        raise AssertionError("opponent was allowed to move out of turn")
                    except Exception as e:
                        assert "NotYourTurn" in str(e), e
                mover.transact(mover.contract.functions.makeMove(gid, encode_move(m)))
                board.push(m)
                plies += 1
                stats["plies"] += 1

                # --- state equality
                pos = fn.getPosition(gid).call()
                board_i, white_to_move, castling, ep, halfmove, wk, bk, fullmove = pos
                assert board_i == expected_board_int(board), f"board mismatch at {board.fen()}"
                assert white_to_move == board.turn
                assert castling == castling_bits(board), f"castling {castling} vs {castling_bits(board)} at {board.fen()}"
                want_ep = board.ep_square if board.has_pseudo_legal_en_passant() else 0
                assert ep == want_ep, f"ep {ep} vs {want_ep} at {board.fen()}"
                assert halfmove == board.halfmove_clock and fullmove == board.fullmove_number
                assert wk == board.king(chess.WHITE) and bk == board.king(chess.BLACK)

                # --- game over detection
                g = w1.game_info(gid)
                end = expected_end(board)
                if end is not None:
                    assert g.status == Status.FINISHED, f"game should be over ({end.name}) at {board.fen()}"
                    assert g.reason == end, f"reason {g.reason.name} vs {end.name} at {board.fen()}"
                    if end == Reason.CHECKMATE:
                        assert g.result == (Result.BLACK_WINS if board.turn == chess.WHITE else Result.WHITE_WINS)
                    else:
                        assert g.result == Result.DRAW
                    stats[f"end:{end.name}"] += 1
                    break
                assert g.status == Status.ACTIVE, f"contract ended game early ({g.reason.name}) at {board.fen()}"
                if plies >= a.max_plies:
                    mover = players[board.turn]
                    mover.transact(mover.contract.functions.resign(gid))
                    stats["end:RESIGN(cap)"] += 1
                    break
            assert w1.w3.eth.get_balance(addr) == 0, "contract holds stranded funds"
            print(f"game {gi + 1}/{a.games}: {plies} plies, {g.reason.name}", flush=True)
    finally:
        anvil.terminate()
    print(f"\nALL GOOD in {time.time() - t0:.0f}s")
    for k in sorted(stats):
        print(f"  {k}: {stats[k]}")


if __name__ == "__main__":
    main()
