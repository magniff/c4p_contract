// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChessEngine} from "../src/ChessEngine.sol";

/// @dev Test-only FEN parser (kept out of src/ so it never ships on-chain).
library FenLib {
    function parse(string memory fen) internal pure returns (ChessEngine.Position memory p) {
        bytes memory s = bytes(fen);
        uint256 i;
        uint256 board;
        uint8 rank = 7;
        uint8 file;
        for (; i < s.length && s[i] != " "; ++i) {
            bytes1 c = s[i];
            if (c == "/") {
                rank--;
                file = 0;
            } else if (c >= "1" && c <= "8") {
                file += uint8(c) - 48;
            } else {
                uint8 piece = _piece(c);
                uint8 square = rank * 8 + file;
                board |= uint256(piece) << (uint256(square) << 2);
                if (piece == 6) p.whiteKing = square;
                if (piece == 14) p.blackKing = square;
                file++;
            }
        }
        p.board = board;
        p.whiteToMove = s[++i] == "w";
        i += 2;
        for (; s[i] != " "; ++i) {
            if (s[i] == "K") p.castling |= ChessEngine.CASTLE_WK;
            if (s[i] == "Q") p.castling |= ChessEngine.CASTLE_WQ;
            if (s[i] == "k") p.castling |= ChessEngine.CASTLE_BK;
            if (s[i] == "q") p.castling |= ChessEngine.CASTLE_BQ;
        }
        ++i;
        if (s[i] != "-") {
            p.epSquare = (uint8(s[i + 1]) - 49) * 8 + (uint8(s[i]) - 97);
            ++i;
        }
        ++i;
        p.fullmove = 1;
    }

    function _piece(bytes1 c) private pure returns (uint8) {
        bytes memory w = "PNBRQK";
        bytes memory b = "pnbrqk";
        for (uint8 i; i < 6; ++i) {
            if (c == w[i]) return i + 1;
            if (c == b[i]) return i + 9;
        }
        revert("bad fen piece");
    }

    function sq(string memory name) internal pure returns (uint8) {
        bytes memory b = bytes(name);
        return (uint8(b[1]) - 49) * 8 + (uint8(b[0]) - 97);
    }

    /// @dev "e2e4", "e7e8q"
    function mv(string memory uci) internal pure returns (uint16) {
        bytes memory b = bytes(uci);
        uint8 from = (uint8(b[1]) - 49) * 8 + (uint8(b[0]) - 97);
        uint8 to = (uint8(b[3]) - 49) * 8 + (uint8(b[2]) - 97);
        uint8 promo;
        if (b.length == 5) {
            promo = b[4] == "p" ? 1 : b[4] == "n" ? 2 : b[4] == "b" ? 3 : b[4] == "r" ? 4 : b[4] == "q" ? 5 : 6;
        }
        return ChessEngine.encode(from, to, promo);
    }
}
