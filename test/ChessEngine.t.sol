// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChessEngine} from "../src/ChessEngine.sol";
import {FenLib} from "./FenLib.sol";

contract ChessEngineTest is Test {
    using ChessEngine for ChessEngine.Position;

    // -------------------------------------------------------------- perft (reference node counts from chessprogramming.org)

    function _perft(ChessEngine.Position memory p, uint256 depth) internal pure returns (uint256 nodes) {
        uint16[] memory moves = ChessEngine.legalMoves(p);
        if (depth == 1) return moves.length;
        for (uint256 i; i < moves.length; ++i) {
            (bool ok, ChessEngine.Position memory np) = ChessEngine.applyMove(p, moves[i]);
            assertTrue(ok);
            nodes += _perft(np, depth - 1);
        }
    }

    function _check(string memory fen, uint256[] memory expected) internal pure {
        ChessEngine.Position memory p = FenLib.parse(fen);
        for (uint256 d = 1; d <= expected.length; ++d) {
            assertEq(_perft(p, d), expected[d - 1], fen);
        }
    }

    function test_perft_startpos() public pure {
        uint256[] memory e = new uint256[](3);
        e[0] = 20;
        e[1] = 400;
        e[2] = 8902;
        _check("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", e);
    }

    function test_perft_initialPositionMatchesFen() public pure {
        ChessEngine.Position memory a = ChessEngine.initialPosition();
        ChessEngine.Position memory b = FenLib.parse("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
        assertEq(a.board, b.board);
        assertEq(a.castling, b.castling);
        assertEq(a.whiteKing, b.whiteKing);
        assertEq(a.blackKing, b.blackKing);
    }

    /// castling, pins, en passant, discovered checks everywhere
    function test_perft_kiwipete() public pure {
        uint256[] memory e = new uint256[](3);
        e[0] = 48;
        e[1] = 2039;
        e[2] = 97862;
        _check("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", e);
    }

    /// en passant with horizontal pins
    function test_perft_position3() public pure {
        uint256[] memory e = new uint256[](4);
        e[0] = 14;
        e[1] = 191;
        e[2] = 2812;
        e[3] = 43238;
        _check("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", e);
    }

    /// promotions, castling rights lost by capture
    function test_perft_position4() public pure {
        uint256[] memory e = new uint256[](3);
        e[0] = 6;
        e[1] = 264;
        e[2] = 9467;
        _check("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", e);
    }

    function test_perft_position4_mirrored() public pure {
        uint256[] memory e = new uint256[](3);
        e[0] = 6;
        e[1] = 264;
        e[2] = 9467;
        _check("r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1", e);
    }

    function test_perft_position5() public pure {
        uint256[] memory e = new uint256[](3);
        e[0] = 44;
        e[1] = 1486;
        e[2] = 62379;
        _check("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", e);
    }

    function test_perft_position6() public pure {
        uint256[] memory e = new uint256[](3);
        e[0] = 46;
        e[1] = 2079;
        e[2] = 89890;
        _check("r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", e);
    }

    // -------------------------------------------------------------- hand-written rule checks

    function _legal(string memory fen, string memory uci) internal pure returns (bool) {
        return FenLib.parse(fen).isLegal(FenLib.mv(uci));
    }

    function test_castling_basics() public pure {
        string memory fen = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1";
        assertTrue(_legal(fen, "e1g1"));
        assertTrue(_legal(fen, "e1c1"));
    }

    function test_castling_notThroughCheck() public pure {
        // black rook on f8 attacks f1
        assertFalse(_legal("5r1k/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1"));
        // ...but queenside is fine
        assertTrue(_legal("5r1k/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1c1"));
    }

    function test_castling_notOutOfCheck() public pure {
        assertFalse(_legal("4r2k/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1"));
        assertFalse(_legal("4r2k/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1c1"));
    }

    function test_castling_notIntoCheck() public pure {
        // rook on g8 covers g1
        assertFalse(_legal("6rk/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1"));
    }

    function test_castling_queensideAllowedWhenOnlyBFileAttacked() public pure {
        // b1 attacked is fine for the rook's path; king passes d1,c1 only
        assertTrue(_legal("1r5k/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1c1"));
    }

    function test_castling_blockedAndNoRights() public pure {
        assertFalse(_legal("r3k2r/8/8/8/8/8/8/R2QK2R w KQkq - 0 1", "e1c1"));
        assertFalse(_legal("r3k2r/8/8/8/8/8/8/R3K2R w - - 0 1", "e1g1"));
        assertFalse(_legal("r3k2r/8/8/8/8/8/8/R3K2R w Qkq - 0 1", "e1g1"));
    }

    function test_castling_rightsLostAfterRookMoves() public pure {
        ChessEngine.Position memory p = FenLib.parse("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
        (, p) = ChessEngine.applyMove(p, FenLib.mv("h1h2"));
        assertEq(p.castling, ChessEngine.CASTLE_WQ | ChessEngine.CASTLE_BK | ChessEngine.CASTLE_BQ);
        // black captures the a1 rook with a8 rook
        (, p) = ChessEngine.applyMove(p, FenLib.mv("a8a1"));
        assertEq(p.castling, ChessEngine.CASTLE_BK);
    }

    function test_castling_movesRook() public pure {
        ChessEngine.Position memory p = FenLib.parse("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
        (bool ok, ChessEngine.Position memory n) = ChessEngine.applyMove(p, FenLib.mv("e1g1"));
        assertTrue(ok);
        assertEq(ChessEngine.pieceAt(n.board, FenLib.sq("g1")), 6);
        assertEq(ChessEngine.pieceAt(n.board, FenLib.sq("f1")), 4);
        assertEq(ChessEngine.pieceAt(n.board, FenLib.sq("h1")), 0);
        assertEq(ChessEngine.pieceAt(n.board, FenLib.sq("e1")), 0);
        assertEq(n.whiteKing, FenLib.sq("g1"));
        (ok, n) = ChessEngine.applyMove(n, FenLib.mv("e8c8"));
        assertTrue(ok);
        assertEq(ChessEngine.pieceAt(n.board, FenLib.sq("c8")), 14);
        assertEq(ChessEngine.pieceAt(n.board, FenLib.sq("d8")), 12);
        assertEq(ChessEngine.pieceAt(n.board, FenLib.sq("a8")), 0);
    }

    function test_enPassant() public pure {
        ChessEngine.Position memory p = FenLib.parse("4k3/8/8/8/3p4/8/4P3/4K3 w - - 0 1");
        bool ok;
        (ok, p) = ChessEngine.applyMove(p, FenLib.mv("e2e4"));
        assertTrue(ok);
        assertEq(p.epSquare, FenLib.sq("e3"));
        assertTrue(p.isLegal(FenLib.mv("d4e3")));
        (ok, p) = ChessEngine.applyMove(p, FenLib.mv("d4e3"));
        assertTrue(ok);
        assertEq(ChessEngine.pieceAt(p.board, FenLib.sq("e4")), 0, "victim removed");
        assertEq(ChessEngine.pieceAt(p.board, FenLib.sq("e3")), 9);
    }

    function test_enPassant_onlyImmediately() public pure {
        ChessEngine.Position memory p = FenLib.parse("4k3/8/8/8/3p4/8/4P3/4K3 w - - 0 1");
        bool ok;
        (ok, p) = ChessEngine.applyMove(p, FenLib.mv("e2e4"));
        (ok, p) = ChessEngine.applyMove(p, FenLib.mv("e8e7"));
        (ok, p) = ChessEngine.applyMove(p, FenLib.mv("e1e2"));
        assertFalse(p.isLegal(FenLib.mv("d4e3")), "ep right expired");
    }

    function test_enPassant_illegalWhenExposesKing() public pure {
        // classic: capturing removes both pawns from the 5th rank and opens the rook's attack on the king
        string memory fen = "8/8/8/KPp4r/8/8/8/4k3 w - c6 0 1";
        assertFalse(_legal(fen, "b5c6"));
        assertTrue(_legal(fen, "b5b6"));
    }

    function test_promotion() public pure {
        string memory fen = "7k/P7/8/8/8/8/8/K7 w - - 0 1";
        assertTrue(_legal(fen, "a7a8q"));
        assertTrue(_legal(fen, "a7a8n"));
        assertFalse(_legal(fen, "a7a8"), "promotion piece required");
        assertFalse(_legal(fen, "a7a8k"), "cannot promote to king");
        assertFalse(_legal(fen, "a7a8p"), "cannot stay a pawn");
        ChessEngine.Position memory p = FenLib.parse(fen);
        (, p) = ChessEngine.applyMove(p, FenLib.mv("a7a8n"));
        assertEq(ChessEngine.pieceAt(p.board, FenLib.sq("a8")), 2);
        // black promotion yields a black piece
        ChessEngine.Position memory q;
        q = FenLib.parse("7k/8/8/8/8/8/p7/7K b - - 0 1");
        (, q) = ChessEngine.applyMove(q, FenLib.mv("a2a1q"));
        assertEq(ChessEngine.pieceAt(q.board, FenLib.sq("a1")), 13);
    }

    function test_noPromotionOffLastRank() public pure {
        assertFalse(_legal("7k/8/8/8/8/P7/8/K7 w - - 0 1", "a3a4q"));
    }

    function test_pinnedPieceCannotMove() public pure {
        // bishop on e2 pinned by rook on e8
        string memory fen = "4r2k/8/8/8/8/8/4B3/4K3 w - - 0 1";
        assertFalse(_legal(fen, "e2d3"));
        assertFalse(_legal(fen, "e2f1"));
    }

    function test_mustResolveCheck() public pure {
        string memory fen = "4r2k/8/8/8/8/8/P7/4K3 w - - 0 1";
        assertFalse(_legal(fen, "a2a3"));
        assertTrue(_legal(fen, "e1d1"));
        assertFalse(_legal(fen, "e1e2"), "stays on the e-file");
    }

    function test_kingCannotStepIntoAttack() public pure {
        assertFalse(_legal("7k/8/8/8/8/8/5r2/4K3 w - - 0 1", "e1e2"));
        assertFalse(_legal("7k/8/8/8/8/8/8/K6q w - - 0 1", "a1b1"));
    }

    function test_cannotMoveOpponentsPiecesOrOntoOwn() public pure {
        string memory fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        assertFalse(_legal(fen, "e7e5"));
        assertFalse(_legal(fen, "a1a2"));
        assertFalse(_legal(fen, "e1e2"));
        assertFalse(_legal(fen, "a1a3"), "rook jumping over pawn");
        assertFalse(_legal(fen, "e2e5"), "pawn triple step");
        assertFalse(_legal(fen, "e3e4"), "empty square");
        assertFalse(_legal(fen, "b1b3"), "knight straight");
        assertFalse(_legal(fen, "c1e3"), "bishop through own pawn");
    }

    function test_pawnCannotCaptureForwardOrDoublePushOverPiece() public pure {
        assertFalse(_legal("4k3/8/8/8/4p3/4P3/8/4K3 w - - 0 1", "e3e4"));
        assertFalse(_legal("4k3/8/8/8/8/4n3/4P3/4K3 w - - 0 1", "e2e4"), "jump over knight");
        assertTrue(_legal("4k3/8/8/8/8/3n4/4P3/4K3 w - - 0 1", "e2d3"), "pawn captures diagonally");
        assertFalse(_legal("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1", "e2d3"), "no diagonal step without capture");
    }

    function test_outOfRangeAndGarbageMoves() public pure {
        ChessEngine.Position memory p = ChessEngine.initialPosition();
        assertFalse(p.isLegal(0));
        assertFalse(p.isLegal(type(uint16).max));
        // promotion bits on a non-promotion move
        assertFalse(p.isLegal(ChessEngine.encode(FenLib.sq("e2"), FenLib.sq("e4"), 5)));
    }

    // -------------------------------------------------------------- terminal states

    function test_checkmate_foolsMate() public pure {
        ChessEngine.Position memory p = ChessEngine.initialPosition();
        string[4] memory line = ["f2f3", "e7e5", "g2g4", "d8h4"];
        for (uint256 i; i < 4; ++i) {
            bool ok;
            (ok, p) = ChessEngine.applyMove(p, FenLib.mv(line[i]));
            assertTrue(ok, line[i]);
        }
        assertEq(uint8(ChessEngine.outcome(p)), uint8(ChessEngine.Outcome.Checkmate));
    }

    function test_checkmate_backRank() public pure {
        ChessEngine.Position memory p = FenLib.parse("6k1/5ppp/8/8/8/8/8/R3K3 w - - 0 1");
        (, p) = ChessEngine.applyMove(p, FenLib.mv("a1a8"));
        assertEq(uint8(ChessEngine.outcome(p)), uint8(ChessEngine.Outcome.Checkmate));
    }

    function test_notCheckmate_canBlock() public pure {
        ChessEngine.Position memory p = FenLib.parse("6k1/5ppp/4b3/8/8/8/8/R3K3 w - - 0 1");
        (, p) = ChessEngine.applyMove(p, FenLib.mv("a1a8"));
        assertTrue(p.inCheck());
        assertEq(uint8(ChessEngine.outcome(p)), uint8(ChessEngine.Outcome.Ongoing));
        assertTrue(p.isLegal(FenLib.mv("e6c8")));
        assertFalse(p.isLegal(FenLib.mv("h7h6")), "must answer the check");
    }

    function test_notCheckmate_canCapture() public pure {
        ChessEngine.Position memory p = FenLib.parse("6k1/5ppp/8/8/4b3/8/8/R3K3 w - - 0 1");
        (, p) = ChessEngine.applyMove(p, FenLib.mv("a1a8"));
        assertTrue(p.inCheck());
        assertTrue(p.isLegal(FenLib.mv("e4a8")));
        assertEq(uint8(ChessEngine.outcome(p)), uint8(ChessEngine.Outcome.Ongoing));
    }

    function test_stalemate() public pure {
        // classic: black king h8, white king f7... black to move, no moves, not in check
        ChessEngine.Position memory p = FenLib.parse("7k/5K2/6Q1/8/8/8/8/8 b - - 0 1");
        assertFalse(p.inCheck());
        assertEq(uint8(ChessEngine.outcome(p)), uint8(ChessEngine.Outcome.Stalemate));
    }

    function test_stalemateReachedByMove() public pure {
        ChessEngine.Position memory p = FenLib.parse("7k/8/5K2/8/8/8/8/6Q1 w - - 0 1");
        (, p) = ChessEngine.applyMove(p, FenLib.mv("g1g6"));
        assertEq(uint8(ChessEngine.outcome(p)), uint8(ChessEngine.Outcome.Stalemate));
    }

    function test_insufficientMaterial() public pure {
        assertEq(uint8(ChessEngine.outcome(FenLib.parse("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))), uint8(ChessEngine.Outcome.InsufficientMaterial));
        assertEq(uint8(ChessEngine.outcome(FenLib.parse("4k3/8/8/8/8/8/8/3NK3 w - - 0 1"))), uint8(ChessEngine.Outcome.InsufficientMaterial));
        assertEq(uint8(ChessEngine.outcome(FenLib.parse("4k3/8/8/8/8/8/8/2B1K3 b - - 0 1"))), uint8(ChessEngine.Outcome.InsufficientMaterial));
        assertEq(uint8(ChessEngine.outcome(FenLib.parse("4k3/8/8/8/8/8/8/2BNK3 w - - 0 1"))), uint8(ChessEngine.Outcome.Ongoing));
        assertEq(uint8(ChessEngine.outcome(FenLib.parse("4k3/8/8/8/8/8/P7/4K3 w - - 0 1"))), uint8(ChessEngine.Outcome.Ongoing));
        assertEq(uint8(ChessEngine.outcome(FenLib.parse("4k3/8/8/8/8/8/8/R3K3 w - - 0 1"))), uint8(ChessEngine.Outcome.Ongoing));
    }

    function test_fiftyMoveRule() public pure {
        ChessEngine.Position memory p = FenLib.parse("4k3/8/8/8/8/8/8/R3K3 w - - 0 1");
        p.halfmoveClock = 99;
        (, p) = ChessEngine.applyMove(p, FenLib.mv("a1a2"));
        assertEq(p.halfmoveClock, 100);
        assertEq(uint8(ChessEngine.outcome(p)), uint8(ChessEngine.Outcome.FiftyMoveRule));
    }

    function test_checkmateBeatsFiftyMoveRule() public pure {
        ChessEngine.Position memory p = FenLib.parse("6k1/5ppp/8/8/8/8/8/R3K3 w - - 0 1");
        p.halfmoveClock = 99;
        (, p) = ChessEngine.applyMove(p, FenLib.mv("a1a8"));
        assertEq(uint8(ChessEngine.outcome(p)), uint8(ChessEngine.Outcome.Checkmate));
    }

    function test_halfmoveClockResets() public pure {
        ChessEngine.Position memory p = ChessEngine.initialPosition();
        (, p) = ChessEngine.applyMove(p, FenLib.mv("g1f3"));
        assertEq(p.halfmoveClock, 1);
        (, p) = ChessEngine.applyMove(p, FenLib.mv("g8f6"));
        assertEq(p.halfmoveClock, 2);
        (, p) = ChessEngine.applyMove(p, FenLib.mv("e2e4"));
        assertEq(p.halfmoveClock, 0);
        assertEq(p.fullmove, 2);
    }
}
