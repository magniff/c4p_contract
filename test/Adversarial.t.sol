// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Chess4Profit} from "../src/Chess4Profit.sol";
import {ChessEngine} from "../src/ChessEngine.sol";
import {FenLib} from "./FenLib.sol";

/// @dev Winner that tries to re-enter every state-changing entrypoint from its receive hook.
contract ReentrantWinner {
    Chess4Profit public game;
    uint256 public gameId;
    uint256 public attempts;
    uint256 public succeeded;

    function setUp(Chess4Profit g) external {
        game = g;
    }

    function create(uint256 stake) external returns (uint256) {
        gameId = game.createGame{value: stake}(1 hours, 0, true);
        return gameId;
    }

    function join(uint256 id, uint256 stake) external {
        gameId = id;
        game.joinGame{value: stake}(id);
    }

    function move(uint256 id, uint16 m) external {
        game.makeMove(id, m);
    }

    receive() external payable {
        bytes[6] memory calls = [
            abi.encodeCall(Chess4Profit.makeMove, (gameId, uint16(0))),
            abi.encodeCall(Chess4Profit.resign, (gameId)),
            abi.encodeCall(Chess4Profit.claimTimeout, (gameId)),
            abi.encodeCall(Chess4Profit.cancelGame, (gameId)),
            abi.encodeCall(Chess4Profit.withdraw, ()),
            abi.encodeCall(Chess4Profit.joinGame, (gameId))
        ];
        for (uint256 i; i < calls.length; ++i) {
            ++attempts;
            (bool ok,) = address(game).call(calls[i]);
            if (ok) ++succeeded;
        }
    }
}

/// @dev Winner whose receive burns all the gas it is given.
contract GasBurner {
    Chess4Profit public game;

    function setUp(Chess4Profit g) external {
        game = g;
    }

    function create(uint256 stake) external returns (uint256) {
        return game.createGame{value: stake}(1 hours, 0, true);
    }

    receive() external payable {
        while (true) {}
    }

    function pull(address payable to) external {
        game.withdraw();
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok);
    }
}

/// @dev Contract that tries to cherry-pick the colour it gets by reverting when unlucky.
contract ColourSniper {
    function tryJoin(Chess4Profit g, uint256 id, bool wantWhite) external payable returns (bool) {
        g.joinGame{value: msg.value}(id);
        return g.getGame(id).white == address(this) == wantWhite;
    }
}

contract AdversarialTest is Test {
    using ChessEngine for ChessEngine.Position;

    Chess4Profit game;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    uint256 constant STAKE = 1 ether;

    function setUp() public {
        game = new Chess4Profit();
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
    }

    function _fee(uint256 pot) internal view returns (uint256) {
        return pot * game.FEE_BPS() / 10_000;
    }

    // ------------------------------------------------------------ invalid moves, fuzzed

    /// Walk a random game with the pure engine; at every position a random 16-bit value must be
    /// accepted exactly when it is in the enumerated legal move list.
    function testFuzz_randomMovesAcceptedIffLegal(uint256 seed, uint16[8] memory junk) public pure {
        ChessEngine.Position memory p = ChessEngine.initialPosition();
        for (uint256 ply; ply < 60; ++ply) {
            uint16[] memory legal = ChessEngine.legalMoves(p);
            if (legal.length == 0) return;
            for (uint256 j; j < junk.length; ++j) {
                uint16 cand = uint16(uint256(keccak256(abi.encode(junk[j], ply, j)))) ^ (j < 3 ? 0 : legal[seed % legal.length]);
                bool inList;
                for (uint256 k; k < legal.length; ++k) {
                    if (legal[k] == cand) inList = true;
                }
                (bool ok,) = ChessEngine.applyMove(p, cand);
                assertEq(ok, inList, "applyMove disagrees with legalMoves");
            }
            // mutate each legal move slightly: change one field and require rejection unless still listed
            uint16 base = legal[seed % legal.length];
            for (uint16 bit; bit < 16; ++bit) {
                uint16 cand = base ^ uint16(1 << bit);
                bool inList;
                for (uint256 k; k < legal.length; ++k) {
                    if (legal[k] == cand) inList = true;
                }
                (bool ok,) = ChessEngine.applyMove(p, cand);
                assertEq(ok, inList, "bit-flipped move mismatch");
            }
            (, p) = ChessEngine.applyMove(p, legal[uint256(keccak256(abi.encode(seed, ply))) % legal.length]);
            if (ChessEngine.outcome(p) != ChessEngine.Outcome.Ongoing) return;
        }
    }

    /// No legal move may ever remove a king or leave the mover's own king attacked.
    function testFuzz_legalMovesNeverLeaveKingInCheckOrCaptureKing(uint256 seed) public pure {
        ChessEngine.Position memory p = ChessEngine.initialPosition();
        for (uint256 ply; ply < 80; ++ply) {
            uint16[] memory legal = ChessEngine.legalMoves(p);
            if (legal.length == 0) return;
            bool white = p.whiteToMove;
            for (uint256 i; i < legal.length; ++i) {
                (, ChessEngine.Position memory n) = ChessEngine.applyMove(p, legal[i]);
                uint8 king = white ? n.whiteKing : n.blackKing;
                assertEq(ChessEngine.pieceAt(n.board, king), white ? 6 : 14, "king tracking wrong");
                assertFalse(ChessEngine.isAttacked(n.board, king, white), "left own king in check");
                uint8 enemyKing = white ? n.blackKing : n.whiteKing;
                assertEq(ChessEngine.pieceAt(n.board, enemyKing), white ? 14 : 6, "enemy king vanished");
            }
            (, p) = ChessEngine.applyMove(p, legal[uint256(keccak256(abi.encode(seed, ply))) % legal.length]);
            if (ChessEngine.outcome(p) != ChessEngine.Outcome.Ongoing) return;
        }
    }

    function test_cannotMovePastCheckmateOrThroughStaleState() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(1 hours, 0, true);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        string[4] memory line = ["f2f3", "e7e5", "g2g4", "d8h4"];
        for (uint256 i; i < 4; ++i) {
            vm.prank(i % 2 == 0 ? alice : bob);
            game.makeMove(id, FenLib.mv(line[i]));
        }
        // finished: nothing further works for anyone, and the pot isn't paid twice
        uint256 bal = address(game).balance;
        vm.startPrank(alice);
        vm.expectRevert(Chess4Profit.NotActive.selector);
        game.makeMove(id, FenLib.mv("a2a3"));
        vm.expectRevert(Chess4Profit.NotActive.selector);
        game.resign(id);
        vm.expectRevert(Chess4Profit.NotActive.selector);
        game.claimTimeout(id);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.cancelGame(id);
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.joinGame{value: STAKE}(id);
        assertEq(address(game).balance, bal);
    }

    // ------------------------------------------------------------ colour can't be sniped

    function test_contractJoinerCannotPickColour() public {
        ColourSniper sniper = new ColourSniper();
        vm.deal(address(sniper), 100 ether);
        for (uint256 i; i < 16; ++i) {
            vm.prevrandao(bytes32(i + 1));
            bool creatorWhite = i % 2 == 0;
            vm.prank(alice);
            uint256 id = game.createGame{value: STAKE}(1 hours, 0, creatorWhite);
            // whatever the sniper wants, it gets the colour the creator left for it
            bool gotWhite = sniper.tryJoin{value: STAKE}(game, id, true) == (!creatorWhite);
            assertTrue(gotWhite || creatorWhite);
            assertEq(game.getGame(id).white == address(sniper), !creatorWhite);
        }
    }

    // ------------------------------------------------------------ reentrancy

    function test_reentrantWinner_cannotDrainOrDoubleSpend() public {
        ReentrantWinner w = new ReentrantWinner();
        w.setUp(game);
        vm.deal(address(w), 10 ether);
        uint256 id = w.create(STAKE); // w is white
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        vm.prank(bob);
        // bob (black) resigns -> w wins and its receive() hammers every entrypoint
        game.resign(id);

        assertGt(w.attempts(), 0, "receive hook ran");
        assertEq(w.succeeded(), 0, "no reentrant call may succeed");
        uint256 expected = 2 * STAKE - _fee(2 * STAKE);
        assertEq(address(w).balance, 10 ether - STAKE + expected, "paid exactly once");
        assertEq(address(game).balance, 0);
    }

    function test_reentrantWinnerOnCheckmate() public {
        ReentrantWinner w = new ReentrantWinner();
        w.setUp(game);
        vm.deal(address(w), 10 ether);
        // w creates as BLACK so fool's mate (black wins) pays it
        uint256 id;
        {
            // create as black through the raw call path
            vm.prank(address(w));
            id = game.createGame{value: STAKE}(1 hours, 0, false);
        }
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        vm.prank(bob);
        game.makeMove(id, FenLib.mv("f2f3"));
        w.move(id, FenLib.mv("e7e5"));
        vm.prank(bob);
        game.makeMove(id, FenLib.mv("g2g4"));
        w.move(id, FenLib.mv("d8h4")); // mate; payout is pushed to w inside its own makeMove
        assertEq(w.succeeded(), 0);
        assertEq(address(game).balance, 0);
        assertEq(address(w).balance, 10 ether - STAKE + 2 * STAKE - _fee(2 * STAKE));
    }

    // ------------------------------------------------------------ hostile receivers

    function test_gasBurningWinner_cannotBlockSettlement() public {
        GasBurner b = new GasBurner();
        b.setUp(game);
        vm.deal(address(b), 10 ether);
        uint256 id = b.create(STAKE);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        uint256 g0 = gasleft();
        vm.prank(bob);
        game.resign(id);
        uint256 used = g0 - gasleft();
        assertLt(used, 300_000, "settlement gas bounded despite receiver burning gas");
        assertEq(uint8(game.getGame(id).status), uint8(Chess4Profit.Status.Finished));
        assertEq(game.pending(address(b)), 2 * STAKE - _fee(2 * STAKE));
    }

    function test_gasBurningLoser_neverBlocksWinner() public {
        GasBurner b = new GasBurner();
        b.setUp(game);
        vm.deal(address(b), 10 ether);
        uint256 id = b.create(STAKE);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        // burner is white and never moves: bob claims the timeout win
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 before_ = bob.balance;
        vm.prank(bob);
        game.claimTimeout(id);
        assertEq(bob.balance, before_ + 2 * STAKE - _fee(2 * STAKE));
    }

    function test_withdrawGoesToCreditedAccountOnly() public {
        GasBurner b = new GasBurner();
        b.setUp(game);
        vm.deal(address(b), 10 ether);
        uint256 id = b.create(STAKE);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        vm.prank(bob);
        game.resign(id);
        uint256 owed = game.pending(address(b));
        assertGt(owed, 0);
        vm.prank(carol);
        vm.expectRevert(Chess4Profit.NothingToWithdraw.selector);
        game.withdraw();
        assertEq(game.pending(address(b)), owed, "strangers can't touch another's credit");
    }

    // ------------------------------------------------------------ forced ETH / accounting

    function test_forceSentEthDoesNotBreakAccounting() public {
        vm.deal(address(game), 5 ether); // simulates selfdestruct / coinbase ETH
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(1 hours, 0, true);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        uint256 before_ = alice.balance;
        vm.prank(bob);
        game.resign(id);
        assertEq(alice.balance, before_ + 2 * STAKE - _fee(2 * STAKE), "payout uses stakes, not contract balance");
        assertEq(address(game).balance, 5 ether, "stray ETH stays untouched");
    }

    function test_directTransfersRejected() public {
        vm.prank(alice);
        (bool ok,) = address(game).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(game).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok);
    }

    function test_stakeBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(Chess4Profit.BadStake.selector);
        game.createGame{value: 1}(1 hours, 0, true);
        game.createGame{value: game.MIN_STAKE()}(1 hours, 0, true);
        vm.stopPrank();
    }

    function test_noGameCanBeTouchedBeforeItExists() public {
        vm.startPrank(alice);
        vm.expectRevert(Chess4Profit.UnknownGame.selector);
        game.makeMove(0, 1);
        vm.expectRevert(Chess4Profit.UnknownGame.selector);
        game.resign(999);
        vm.expectRevert(Chess4Profit.UnknownGame.selector);
        game.claimTimeout(1);
        vm.expectRevert(Chess4Profit.UnknownGame.selector);
        game.cancelGame(1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ gas ceilings (a game must always be finishable)

    function test_gasCeiling_terminalEvaluation() public {
        // worst cases for the full scan: no legal move at all (mate / stalemate) with many pieces on the board
        string[3] memory fens = [
            "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2", // pre-mate, plenty to scan
            "5bnr/4p1pq/4Qpkr/7p/7P/4P3/PPPP1PP1/RNB1KBNR b KQ - 2 10", // stalemate-ish, many black pieces
            "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3" // checkmate, white has 16 pieces
        ];
        uint256 worst;
        for (uint256 i; i < fens.length; ++i) {
            ChessEngine.Position memory p = FenLib.parse(fens[i]);
            uint256 g0 = gasleft();
            ChessEngine.outcome(p);
            uint256 used = g0 - gasleft();
            if (used > worst) worst = used;
        }
        emit log_named_uint("worst terminal-evaluation gas", worst);
        assertLt(worst, 6_000_000);
    }

    function testFuzz_gasCeiling_anyReachablePosition(uint256 seed) public {
        ChessEngine.Position memory p = ChessEngine.initialPosition();
        uint256 worst;
        for (uint256 ply; ply < 120; ++ply) {
            uint16[] memory legal = ChessEngine.legalMoves(p);
            if (legal.length == 0) break;
            (, p) = ChessEngine.applyMove(p, legal[uint256(keccak256(abi.encode(seed, ply))) % legal.length]);
            uint256 g0 = gasleft();
            ChessEngine.Outcome o = ChessEngine.outcome(p);
            uint256 used = g0 - gasleft();
            if (used > worst) worst = used;
            if (o != ChessEngine.Outcome.Ongoing) break;
        }
        assertLt(worst, 6_000_000, "outcome() too expensive for a single block-safe move");
    }

    // ------------------------------------------------------------ randomized action sequences: money is conserved

    /// Random lobby/play actions by three actors. After every step the contract's balance must equal
    /// the stakes still locked in open/active games plus all credited-but-unwithdrawn payouts.
    function testFuzz_fundsConservedUnderRandomActions(uint256 seed) public {
        address[3] memory actors = [alice, bob, carol];
        uint256 locked;
        uint256 steps = 60;
        for (uint256 s; s < steps; ++s) {
            uint256 r = uint256(keccak256(abi.encode(seed, s)));
            address who = actors[r % 3];
            uint256 action = (r >> 8) % 7;
            uint256 n = game.nextGameId() - 1;
            uint256 id = n == 0 ? 1 : 1 + ((r >> 16) % n);
            uint256 stake = game.MIN_STAKE() * (1 + ((r >> 40) % 5));

            vm.startPrank(who);
            if (action == 0) {
                game.createGame{value: stake}(uint32(60 + (r >> 48) % 3600), uint32((r >> 70) % 30), (r >> 60) & 1 == 1);
            } else if (action == 1 && n > 0) {
                try game.joinGame{value: game.getGame(id).stake}(id) {} catch {}
            } else if (action == 2 && n > 0) {
                try game.cancelGame(id) {} catch {}
            } else if (action == 3 && n > 0) {
                try game.resign(id) {} catch {}
            } else if (action == 4 && n > 0) {
                vm.warp(block.timestamp + ((r >> 24) % 2 hours));
                try game.claimTimeout(id) {} catch {}
            } else if (n > 0) {
                // a legal move for whoever is on turn (sometimes the wrong caller, which must just revert)
                try game.legalMoves(id) returns (uint16[] memory ms) {
                    if (ms.length > 0) {
                        try game.makeMove(id, ms[(r >> 32) % ms.length]) {} catch {}
                    }
                } catch {}
            }
            vm.stopPrank();

            // invariant
            uint256 expected;
            for (uint256 g = 1; g <= game.nextGameId() - 1; ++g) {
                Chess4Profit.GameView memory v = game.getGame(g);
                if (v.status == Chess4Profit.Status.Open) expected += v.stake;
                else if (v.status == Chess4Profit.Status.Active) expected += 2 * v.stake;
            }
            for (uint256 a; a < 3; ++a) expected += game.pending(actors[a]);
            expected += game.pending(game.FEE_RECIPIENT());
            locked = expected;
            assertEq(address(game).balance, locked, "contract balance != locked stakes + pending credits");
        }
    }
}
