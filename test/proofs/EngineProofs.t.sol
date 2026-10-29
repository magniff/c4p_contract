// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChessEngine} from "../../src/ChessEngine.sol";
import {ChessEngineRef} from "../reference/ChessEngineRef.sol";

/// Symbolic proofs (Halmos): every input, not samples. `forge test` skips these (check_ prefix); run with
///     .venv-halmos/bin/halmos --contract EngineProofs
contract EngineProofs is Test {
    /// Branch-free "does `piece` occur on `board`" (one solver query instead of 2^64 paths).
    function _scan(uint256 board, uint256 piece) internal pure returns (bool found) {
        assembly {
            for { let sq := 0 } lt(sq, 64) { sq := add(sq, 1) } {
                found := or(found, eq(and(shr(mul(sq, 4), board), 0xf), piece))
            }
        }
    }

    /// The SWAR piece-presence test is exact for every board and every piece value.
    function check_hasPieceIsExact(uint256 board, uint8 piece) public pure {
        vm.assume(piece < 16);
        assert(ChessEngine.hasPiece(board, piece) == _scan(board, piece));
    }
}
