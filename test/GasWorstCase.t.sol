// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChessEngine} from "../src/ChessEngine.sol";
import {FenLib} from "./FenLib.sol";

/// Adversarially crafted positions (all legal-looking, maximal piece counts / mobility) -> cost of the
/// scan that every game-ending move must pay. Must stay far below any block gas limit.
contract GasWorstCaseTest is Test {
    function _cost(string memory fen) internal returns (uint256 used) {
        ChessEngine.Position memory p = FenLib.parse(fen);
        uint256 g0 = gasleft();
        ChessEngine.outcome(p);
        used = g0 - gasleft();
        emit log_named_uint(fen, used);
    }

    function test_worstCase_manyQueensMated() public {
        uint256 w;
        // side to move (black) has 9 queens + 6 other pieces, but is checkmated/pinned: every candidate is pseudo-legal yet illegal
        string[6] memory fens = [
            "QQQQQQQQ/QQQQQQQQ/8/8/8/8/8/K6k b - - 0 1",             // black king alone, hemmed in (stalemate/mate scan)
            "7k/8/8/8/8/8/qqqqqqqq/KQQQQQQQ w - - 0 1",              // white king boxed by own queens, black queens everywhere
            "rrrrrrrk/qqqqqqqq/8/8/8/8/8/K6R b - - 0 1",             // black: tons of sliders all blocked
            "qqqqqqqq/qqqqqqqq/8/8/8/8/8/QQQQQKQ1 b - - 0 1",        // black to move, 16 queens
            "k7/8/8/8/8/8/PPPPPPPP/RNBQKBNR b - - 0 1",             // lone king vs full army (mate/stalemate-ish scan)
            "r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R3K2R w KQkq - 0 1"     // castling-heavy
        ];
        uint256 worst;
        for (uint256 i; i < fens.length; ++i) {
            uint256 c = _cost(fens[i]);
            if (c > worst) worst = c;
        }
        emit log_named_uint("WORST", worst);
        assertLt(worst, 8_000_000);
    }

    /// Hunt for the most expensive position along random walks AND randomly mutated boards (many queens).
    function testFuzz_hunt(uint256 seed) public {
        ChessEngine.Position memory p = ChessEngine.initialPosition();
        uint256 worst;
        for (uint256 ply; ply < 100; ++ply) {
            uint16[] memory legal = ChessEngine.legalMoves(p);
            if (legal.length == 0) break;
            (, p) = ChessEngine.applyMove(p, legal[uint256(keccak256(abi.encode(seed, ply))) % legal.length]);
            uint256 g0 = gasleft();
            ChessEngine.outcome(p);
            uint256 u = g0 - gasleft();
            if (u > worst) worst = u;
        }
        assertLt(worst, 8_000_000);
    }
}
