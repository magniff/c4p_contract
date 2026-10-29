"""A tiny UCI engine so the SDK runs without Stockfish. Greedy 1-ply: mates > captures > checks > random.
Run as:  python -m chess4profit.randomfish   (then speak UCI on stdin)"""
from __future__ import annotations

import random
import sys

import chess

VALUES = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3, chess.ROOK: 5, chess.QUEEN: 9, chess.KING: 0}


def score(board: chess.Board, move: chess.Move) -> float:
    s = random.random() * 0.5
    victim = board.piece_at(move.to_square)
    if board.is_en_passant(move):
        s += 1
    elif victim:
        s += VALUES[victim.piece_type] * 2
    if move.promotion:
        s += VALUES[move.promotion]
    board.push(move)
    if board.is_checkmate():
        s += 1000
    elif board.is_stalemate() or board.is_insufficient_material():
        s -= 50
    elif board.is_check():
        s += 0.7
    board.pop()
    return s


def main() -> None:
    board = chess.Board()
    for line in sys.stdin:
        parts = line.split()
        if not parts:
            continue
        cmd = parts[0]
        if cmd == "uci":
            print("id name randomfish\nid author chess4profit\nuciok", flush=True)
        elif cmd == "isready":
            print("readyok", flush=True)
        elif cmd == "ucinewgame":
            board = chess.Board()
        elif cmd == "position":
            board = chess.Board()
            if "moves" in parts:
                for m in parts[parts.index("moves") + 1 :]:
                    board.push_uci(m)
        elif cmd == "go":
            moves = list(board.legal_moves)
            best = max(moves, key=lambda m: score(board, m))
            print(f"bestmove {best.uci()}", flush=True)
        elif cmd == "quit":
            return


if __name__ == "__main__":
    main()
