// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ChessEngineRef — frozen copy of the engine as of b72136c (perft- and python-chess-verified). Test oracle only.
/// @notice Full FIDE move validation (castling, en passant, promotion, pins, checks) plus
///         checkmate / stalemate / insufficient-material / 50-move detection.
///
/// Conventions
///  - Squares are 0..63 with a1 = 0, b1 = 1, ... h1 = 7, a2 = 8, ... h8 = 63 (same as python-chess).
///  - The board is a uint256 holding 64 nibbles, nibble `sq` at bits [4*sq, 4*sq+4).
///  - Piece nibble: 0 empty; 1..6 = P N B R Q K; add 8 for black.
///  - A move is a uint16: from | to << 6 | promotionPieceType << 12 (promotion type 2..5, else 0).
library ChessEngineRef {
    uint8 internal constant PAWN = 1;
    uint8 internal constant KNIGHT = 2;
    uint8 internal constant BISHOP = 3;
    uint8 internal constant ROOK = 4;
    uint8 internal constant QUEEN = 5;
    uint8 internal constant KING = 6;

    uint8 internal constant CASTLE_WK = 1;
    uint8 internal constant CASTLE_WQ = 2;
    uint8 internal constant CASTLE_BK = 4;
    uint8 internal constant CASTLE_BQ = 8;

    /// @dev Halfmove clock at which the game is automatically drawn (50 full moves).
    uint8 internal constant FIFTY_MOVE_PLIES = 100;

    enum Outcome {
        Ongoing,
        Checkmate, // side to move is mated
        Stalemate,
        InsufficientMaterial,
        FiftyMoveRule
    }

    struct Position {
        uint256 board;
        bool whiteToMove;
        uint8 castling; // bitmask of CASTLE_*
        uint8 epSquare; // en-passant target square, 0 = none (rank 1 can never be a target)
        uint8 halfmoveClock;
        uint8 whiteKing;
        uint8 blackKing;
        uint16 fullmove;
    }

    // ---------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------

    function initialPosition() internal pure returns (Position memory p) {
        uint256 b;
        uint8[8] memory back = [ROOK, KNIGHT, BISHOP, QUEEN, KING, BISHOP, KNIGHT, ROOK];
        for (uint8 f; f < 8; ++f) {
            b = _set(b, f, back[f]);
            b = _set(b, 8 + f, PAWN);
            b = _set(b, 48 + f, PAWN | 8);
            b = _set(b, 56 + f, back[f] | 8);
        }
        p.board = b;
        p.whiteToMove = true;
        p.castling = 15;
        p.whiteKing = 4;
        p.blackKing = 60;
        p.fullmove = 1;
    }

    // ---------------------------------------------------------------------------------------
    // Board helpers
    // ---------------------------------------------------------------------------------------

    function pieceAt(uint256 board, uint8 sq) internal pure returns (uint8) {
        return uint8((board >> (uint256(sq) << 2)) & 0xF);
    }

    function _set(uint256 board, uint8 sq, uint8 piece) private pure returns (uint256) {
        uint256 shift = uint256(sq) << 2;
        return (board & ~(uint256(0xF) << shift)) | (uint256(piece) << shift);
    }

    function _at(uint256 board, int256 r, int256 f) private pure returns (uint8) {
        return uint8((board >> (uint256(r * 8 + f) << 2)) & 0xF);
    }

    function _on(int256 r, int256 f) private pure returns (bool) {
        return r >= 0 && r < 8 && f >= 0 && f < 8;
    }

    function _abs(int256 x) private pure returns (int256) {
        return x < 0 ? -x : x;
    }

    function _sign(int256 x) private pure returns (int256) {
        return x > 0 ? int256(1) : (x < 0 ? int256(-1) : int256(0));
    }

    // ---------------------------------------------------------------------------------------
    // Attack detection
    // ---------------------------------------------------------------------------------------

    /// @notice Is `sq` attacked by any piece of the given colour?
    function isAttacked(uint256 board, uint8 sq, bool byBlack) internal pure returns (bool) {
        int256 r = int256(uint256(sq >> 3));
        int256 f = int256(uint256(sq & 7));
        uint8 col = byBlack ? 8 : 0;
        return _pawnAttacks(board, r, f, byBlack, col) || _knightAttacks(board, r, f, col)
            || _rayAttacks(board, r, f, col);
    }

    // an attacking white pawn sits one rank below the target, a black pawn one rank above
    function _pawnAttacks(uint256 board, int256 r, int256 f, bool byBlack, uint8 col) private pure returns (bool) {
        int256 pr = byBlack ? r + 1 : r - 1;
        if (pr < 0 || pr > 7) return false;
        return (f > 0 && _at(board, pr, f - 1) == (PAWN | col)) || (f < 7 && _at(board, pr, f + 1) == (PAWN | col));
    }

    function _knightAttacks(uint256 board, int256 r, int256 f, uint8 col) private pure returns (bool) {
        for (uint256 i; i < 8; ++i) {
            int256 a = (i & 4) == 0 ? int256(1) : int256(2);
            int256 nr = r + ((i & 1) == 0 ? a : -a);
            int256 nf = f + ((i & 2) == 0 ? 3 - a : a - 3);
            if (_on(nr, nf) && _at(board, nr, nf) == (KNIGHT | col)) return true;
        }
        return false;
    }

    /// @dev King (adjacent square) and sliding pieces (rays) in all 8 directions.
    function _rayAttacks(uint256 board, int256 r, int256 f, uint8 col) private pure returns (bool) {
        for (uint256 i; i < 9; ++i) {
            if (i == 4) continue;
            if (_ray(board, r, f, int256(i / 3) - 1, int256(i % 3) - 1, col)) return true;
        }
        return false;
    }

    function _ray(uint256 board, int256 r, int256 f, int256 dr, int256 df, uint8 col) private pure returns (bool) {
        bool diag = dr != 0 && df != 0;
        r += dr;
        f += df;
        bool adjacent = true;
        while (_on(r, f)) {
            uint8 p = _at(board, r, f);
            if (p != 0) {
                if ((p & 8) != col) return false;
                uint8 t = p & 7;
                return t == QUEEN || (diag ? t == BISHOP : t == ROOK) || (adjacent && t == KING);
            }
            adjacent = false;
            r += dr;
            f += df;
        }
        return false;
    }

    function inCheck(Position memory p) internal pure returns (bool) {
        return isAttacked(p.board, p.whiteToMove ? p.whiteKing : p.blackKing, p.whiteToMove);
    }

    // ---------------------------------------------------------------------------------------
    // Move validation
    // ---------------------------------------------------------------------------------------

    function encode(uint8 from, uint8 to, uint8 promo) internal pure returns (uint16) {
        return uint16(from) | (uint16(to) << 6) | (uint16(promo) << 12);
    }

    /// @notice Apply `move` for the side to move. `ok` is false if the move is not fully legal.
    function applyMove(Position memory p, uint16 move) internal pure returns (bool ok, Position memory np) {
        uint8 from = uint8(move & 63);
        uint8 to = uint8((move >> 6) & 63);
        uint8 promo = uint8(move >> 12);
        if (!_legal(p, from, to, promo)) return (false, p);
        return (true, _apply(p, from, to, promo));
    }

    function isLegal(Position memory p, uint16 move) internal pure returns (bool) {
        return _legal(p, uint8(move & 63), uint8((move >> 6) & 63), uint8(move >> 12));
    }

    function _legal(Position memory p, uint8 from, uint8 to, uint8 promo) private pure returns (bool) {
        if (!_pseudoLegal(p, from, to, promo)) return false;
        Position memory n = _apply(p, from, to, promo);
        // mover's king must not be attacked afterwards
        return !isAttacked(n.board, p.whiteToMove ? n.whiteKing : n.blackKing, p.whiteToMove);
    }

    /// @dev Geometry, occupancy, castling preconditions. Does not check that the mover's king is safe after the move.
    function _pseudoLegal(Position memory p, uint8 from, uint8 to, uint8 promo) private pure returns (bool) {
        if (from == to) return false;
        uint256 board = p.board;
        uint8 piece = pieceAt(board, from);
        if (piece == 0) return false;
        bool white = p.whiteToMove;
        if (((piece & 8) == 0) != white) return false;
        uint8 target = pieceAt(board, to);
        if (target != 0 && ((target & 8) == 0) == white) return false; // own piece
        if ((target & 7) == KING) return false;

        int256 dr = int256(uint256(to >> 3)) - int256(uint256(from >> 3));
        int256 df = int256(uint256(to & 7)) - int256(uint256(from & 7));
        uint8 t = piece & 7;

        if (t == PAWN) return _pawnOk(p, white, from, to, promo, target, dr, df);
        if (promo != 0) return false;

        if (t == KNIGHT) {
            int256 ar = _abs(dr);
            int256 af = _abs(df);
            return (ar == 1 && af == 2) || (ar == 2 && af == 1);
        }
        if (t == BISHOP) return _abs(dr) == _abs(df) && _clear(board, from, to, dr, df);
        if (t == ROOK) return (dr == 0 || df == 0) && _clear(board, from, to, dr, df);
        if (t == QUEEN) {
            return (dr == 0 || df == 0 || _abs(dr) == _abs(df)) && _clear(board, from, to, dr, df);
        }
        // king
        if (_abs(dr) <= 1 && _abs(df) <= 1) return true;
        if (dr == 0 && (df == 2 || df == -2)) return _castleOk(p, white, from, df > 0);
        return false;
    }

    function _pawnOk(
        Position memory p,
        bool white,
        uint8 from,
        uint8 to,
        uint8 promo,
        uint8 target,
        int256 dr,
        int256 df
    ) private pure returns (bool) {
        // promotion piece must be given exactly when reaching the last rank
        if ((to >> 3) == (white ? 7 : 0)) {
            if (promo < KNIGHT || promo > QUEEN) return false;
        } else if (promo != 0) {
            return false;
        }

        int256 dir = white ? int256(1) : int256(-1);
        if (df == 0) {
            if (target != 0) return false;
            if (dr == dir) return true;
            if (dr == 2 * dir && (from >> 3) == (white ? 1 : 6)) {
                return pieceAt(p.board, uint8(uint256(int256(uint256(from)) + 8 * dir))) == 0;
            }
            return false;
        }
        if ((df == 1 || df == -1) && dr == dir) {
            if (target != 0) return true; // enemy piece, own pieces rejected by caller
            if (p.epSquare != 0 && to == p.epSquare) {
                // the pawn being captured sits beside us, on our rank and the target's file
                uint8 victim = pieceAt(p.board, uint8(uint256(int256(uint256(from)) + df)));
                return victim == (PAWN | (white ? 8 : 0));
            }
        }
        return false;
    }

    function _clear(uint256 board, uint8 from, uint8 to, int256 dr, int256 df) private pure returns (bool) {
        int256 sr = _sign(dr);
        int256 sf = _sign(df);
        int256 r = int256(uint256(from >> 3)) + sr;
        int256 f = int256(uint256(from & 7)) + sf;
        int256 tr = int256(uint256(to >> 3));
        int256 tf = int256(uint256(to & 7));
        while (r != tr || f != tf) {
            if (_at(board, r, f) != 0) return false;
            r += sr;
            f += sf;
        }
        return true;
    }

    function _castleOk(Position memory p, bool white, uint8 from, bool kingside) private pure returns (bool) {
        uint8 base = white ? 0 : 56;
        if (from != base + 4) return false;
        uint256 board = p.board;
        uint8 rook = ROOK | (white ? 0 : 8);
        bool byBlack = white; // attackers are the opponent

        if (kingside) {
            if ((p.castling & (white ? CASTLE_WK : CASTLE_BK)) == 0) return false;
            if (pieceAt(board, base + 7) != rook) return false;
            if (pieceAt(board, base + 5) != 0 || pieceAt(board, base + 6) != 0) return false;
            // can't castle out of, or through, check (the landing square is checked after the move)
            return !isAttacked(board, base + 4, byBlack) && !isAttacked(board, base + 5, byBlack);
        }
        if ((p.castling & (white ? CASTLE_WQ : CASTLE_BQ)) == 0) return false;
        if (pieceAt(board, base) != rook) return false;
        if (pieceAt(board, base + 1) != 0 || pieceAt(board, base + 2) != 0 || pieceAt(board, base + 3) != 0) {
            return false;
        }
        return !isAttacked(board, base + 4, byBlack) && !isAttacked(board, base + 3, byBlack);
    }

    /// @dev Right bits that disappear when a piece moves from or to `sq`.
    function _rightsLostAt(uint8 sq) private pure returns (uint8) {
        if (sq == 0) return CASTLE_WQ;
        if (sq == 7) return CASTLE_WK;
        if (sq == 56) return CASTLE_BQ;
        if (sq == 63) return CASTLE_BK;
        return 0;
    }

    /// @dev Applies a pseudo-legal move; no validation.
    function _apply(Position memory p, uint8 from, uint8 to, uint8 promo) private pure returns (Position memory n) {
        bool white = p.whiteToMove;
        uint256 b = p.board;
        uint8 piece = pieceAt(b, from);
        uint8 t = piece & 7;
        bool capture = pieceAt(b, to) != 0;
        uint8 placed = piece;

        b = _set(b, from, 0);

        n.whiteKing = p.whiteKing;
        n.blackKing = p.blackKing;

        if (t == PAWN) {
            if (promo != 0) {
                placed = promo | (white ? 0 : 8);
            } else if (!capture && (from & 7) != (to & 7)) {
                // en passant: remove the pawn on our rank, target file
                b = _set(b, (from & 0xF8) | (to & 7), 0);
                capture = true;
            }
        } else if (t == KING) {
            if (white) n.whiteKing = to;
            else n.blackKing = to;
            if (to == from + 2) {
                b = _set(_set(b, from + 3, 0), from + 1, ROOK | (white ? 0 : 8));
            } else if (from == to + 2) {
                b = _set(_set(b, from - 4, 0), from - 1, ROOK | (white ? 0 : 8));
            }
        }
        b = _set(b, to, placed);
        n.board = b;

        uint8 c = p.castling;
        if (t == KING) c &= white ? uint8(CASTLE_BK | CASTLE_BQ) : uint8(CASTLE_WK | CASTLE_WQ);
        c &= ~(_rightsLostAt(from) | _rightsLostAt(to));
        n.castling = c;

        // en-passant square is only recorded when an enemy pawn is actually next to the pushed pawn
        if (t == PAWN && (to == from + 16 || from == to + 16)) {
            uint8 enemyPawn = PAWN | (white ? 8 : 0);
            uint8 tf = to & 7;
            if ((tf > 0 && pieceAt(b, to - 1) == enemyPawn) || (tf < 7 && pieceAt(b, to + 1) == enemyPawn)) {
                n.epSquare = (from + to) / 2;
            }
        }

        if (t == PAWN || capture) {
            n.halfmoveClock = 0;
        } else {
            n.halfmoveClock = p.halfmoveClock == type(uint8).max ? p.halfmoveClock : p.halfmoveClock + 1;
        }
        n.fullmove = white ? p.fullmove : p.fullmove + 1;
        n.whiteToMove = !white;
    }

    // ---------------------------------------------------------------------------------------
    // Move generation / game state
    // ---------------------------------------------------------------------------------------

    /// @dev Pawn moves onto the last rank need a promotion piece; any one legal promotion implies queen is legal.
    function _probePromo(uint256 board, uint8 from, uint8 to, bool white) private pure returns (uint8) {
        if ((pieceAt(board, from) & 7) == PAWN && (to >> 3) == (white ? 7 : 0)) return QUEEN;
        return 0;
    }

    /// @notice True if the side to move has at least one legal move.
    function hasLegalMove(Position memory p) internal pure returns (bool) {
        bool white = p.whiteToMove;
        uint256 board = p.board;
        for (uint8 from; from < 64; ++from) {
            uint8 piece = pieceAt(board, from);
            if (piece == 0 || ((piece & 8) == 0) != white) continue;
            for (uint8 to; to < 64; ++to) {
                if (_legal(p, from, to, _probePromo(board, from, to, white))) return true;
            }
        }
        return false;
    }

    /// @notice All legal moves for the side to move (promotions expanded into 4 moves).
    function legalMoves(Position memory p) internal pure returns (uint16[] memory moves) {
        bool white = p.whiteToMove;
        uint256 board = p.board;
        moves = new uint16[](256);
        uint256 n;
        for (uint8 from; from < 64; ++from) {
            uint8 piece = pieceAt(board, from);
            if (piece == 0 || ((piece & 8) == 0) != white) continue;
            for (uint8 to; to < 64; ++to) {
                uint8 probe = _probePromo(board, from, to, white);
                if (probe == 0) {
                    if (_legal(p, from, to, 0)) moves[n++] = encode(from, to, 0);
                } else if (_legal(p, from, to, probe)) {
                    for (uint8 pr = KNIGHT; pr <= QUEEN; ++pr) moves[n++] = encode(from, to, pr);
                }
            }
        }
        assembly {
            mstore(moves, n)
        }
    }

    /// @notice Terminal-state evaluation for the side to move (repetition is tracked by the caller).
    function outcome(Position memory p) internal pure returns (Outcome) {
        if (!hasLegalMove(p)) return inCheck(p) ? Outcome.Checkmate : Outcome.Stalemate;
        if (insufficientMaterial(p.board)) return Outcome.InsufficientMaterial;
        if (p.halfmoveClock >= FIFTY_MOVE_PLIES) return Outcome.FiftyMoveRule;
        return Outcome.Ongoing;
    }

    /// @notice K vs K, K+B vs K, K+N vs K. (Other dead positions are left to the 50-move / repetition rules.)
    function insufficientMaterial(uint256 board) internal pure returns (bool) {
        uint256 minors;
        for (uint8 sq; sq < 64; ++sq) {
            uint8 t = pieceAt(board, sq) & 7;
            if (t == PAWN || t == ROOK || t == QUEEN) return false;
            if (t == KNIGHT || t == BISHOP) {
                if (++minors > 1) return false;
            }
        }
        return true;
    }

    /// @notice Identity of a position for repetition purposes.
    function positionKey(Position memory p) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(p.board, p.whiteToMove, p.castling, p.epSquare));
    }
}
