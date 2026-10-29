// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Chess4Profit} from "../src/Chess4Profit.sol";
import {FenLib} from "./FenLib.sol";

/// Creates games from a contract that refuses ETH (so its refunds must fall back to `pending`).
contract RejectingCreator {
    function create(Chess4Profit g, uint32 base) external payable returns (uint256) {
        return g.createGame{value: msg.value}(base, 0, true);
    }

    receive() external payable {
        revert();
    }
}

contract AttacksTest is Test {
    Chess4Profit game;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");
    uint256 constant STAKE = 1 ether;
    bytes32 T; // the (1 ether, 120s, +0) table most tests sit at

    function setUp() public {
        game = new Chess4Profit();
        T = game.lobbyKey(STAKE, 120, 0);
        vm.deal(alice, 1_000_000 ether);
        vm.deal(bob, 1_000_000 ether);
        vm.deal(mallory, 1_000_000 ether);
    }

    function _start(uint32 base, uint32 inc) internal returns (uint256 id, address white, address black) {
        vm.prank(alice);
        id = game.createGame{value: STAKE}(base, inc, true);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        white = alice;
        black = bob;
    }

    // =============================================================== slow-play / capital lock-up

    /// Old design: each move could take the whole per-move timeout, so a game could be dragged out for hours.
    /// Fischer clock: total time per side is bounded by base + increments, no matter how slowly the opponent plays.
    function test_slowPlay_gameDurationIsBoundedByTheClock() public {
        (uint256 id, address w, address b) = _start(100, 0);
        uint256 t0 = block.timestamp;
        string[8] memory line = ["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"];
        uint256 i;
        // both sides burn 40s per move; with a 100s bank each, somebody must be flagged within 2*100s of total play
        for (; i < line.length; ++i) {
            vm.warp(block.timestamp + 40);
            Chess4Profit.GameView memory v = game.getGame(id);
            if (block.timestamp - v.lastMoveAt > (v.whiteToMove ? v.whiteTime : v.blackTime)) break;
            vm.prank(i % 2 == 0 ? w : b);
            game.makeMove(id, FenLib.mv(line[i]));
        }
        assertLt(i, line.length, "someone must have run out of time");
        vm.prank(mallory);
        game.claimTimeout(id);
        assertEq(uint8(game.getGame(id).reason), uint8(Chess4Profit.Reason.Timeout));
        assertLe(block.timestamp - t0, 2 * 100 + 40, "game cannot outlast the combined bank (+1 move)");
    }

    function test_clock_incrementAndAccounting() public {
        (uint256 id, address w, address b) = _start(60, 5);
        vm.warp(block.timestamp + 10);
        vm.prank(w);
        game.makeMove(id, FenLib.mv("e2e4"));
        Chess4Profit.GameView memory v = game.getGame(id);
        assertEq(v.whiteTime, 60 - 10 + 5);
        assertEq(v.blackTime, 60, "black's clock hasn't started yet");
        vm.warp(block.timestamp + 60); // black uses everything: exactly 60 is still legal
        vm.prank(b);
        game.makeMove(id, FenLib.mv("e7e5"));
        assertEq(game.getGame(id).blackTime, 0 + 5);
        vm.warp(block.timestamp + 6); // white has 55; fine. black now has 5, white to move
        vm.prank(w);
        game.makeMove(id, FenLib.mv("g1f3"));
        vm.warp(block.timestamp + 6); // black has 5 left, 6 elapsed -> flagged
        vm.prank(b);
        vm.expectRevert(Chess4Profit.TurnTimedOut.selector);
        game.makeMove(id, FenLib.mv("b8c6"));
        game.claimTimeout(id);
        assertEq(uint8(game.getGame(id).result), uint8(Chess4Profit.Result.WhiteWins));
    }

    function test_clock_deadlineViewMatchesBehaviour() public {
        (uint256 id,,) = _start(90, 0);
        Chess4Profit.GameView memory v = game.getGame(id);
        assertEq(v.deadline, block.timestamp + 90);
        vm.warp(v.deadline);
        vm.expectRevert(Chess4Profit.NotTimedOut.selector);
        game.claimTimeout(id);
        vm.warp(v.deadline + 1);
        game.claimTimeout(id);
    }

    function test_clock_boundsRejected() public {
        vm.startPrank(alice);
        vm.expectRevert(Chess4Profit.BadTimeout.selector);
        game.createGame{value: STAKE}(29, 0, true);
        vm.expectRevert(Chess4Profit.BadTimeout.selector);
        game.createGame{value: STAKE}(1 days + 1, 0, true);
        vm.expectRevert(Chess4Profit.BadTimeout.selector);
        game.createGame{value: STAKE}(60, 10 minutes + 1, true);
        game.createGame{value: STAKE}(1 days, 10 minutes, true); // extremes are accepted
        vm.stopPrank();
    }

    function test_stallingJoiner_costsThemTheirStake_andVictimIsFreedAfterBaseTime() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(120, 0, false); // alice black, so mallory (white) must move first
        vm.prank(mallory);
        game.joinGame{value: STAKE}(id);
        uint256 before_ = alice.balance;
        vm.warp(block.timestamp + 121);
        vm.prank(alice);
        game.claimTimeout(id);
        assertEq(alice.balance, before_ + 2 * STAKE - 2 * STAKE * game.FEE_BPS() / 10_000);
        assertEq(address(game).balance, 0);
    }

    /// Regression for an overclaim in the first review: with increment > 0 a player could bank time by moving
    /// fast (200 instant moves at +10min = 33 extra hours) and then stall. The bank is now capped.
    function test_clock_bankCannotBeHoardedBeyondMaxBaseTime() public {
        (uint256 id, address w, address b) = _start(1 days, 10 minutes);
        // 32 instant, non-repeating plies (pawns march file by file); without the cap white's bank
        // would be 1 day + 16 * 10 min
        bytes memory files = "abcdefgh";
        for (uint256 i; i < 32; ++i) {
            bytes1 f = files[i / 4];
            string memory mv = (i % 4 == 0) ? string(abi.encodePacked(f, "2", f, "3"))
                : (i % 4 == 1) ? string(abi.encodePacked(f, "7", f, "6"))
                : (i % 4 == 2) ? string(abi.encodePacked(f, "3", f, "4"))
                : string(abi.encodePacked(f, "6", f, "5"));
            vm.prank(i % 2 == 0 ? w : b);
            game.makeMove(id, FenLib.mv(mv));
            Chess4Profit.GameView memory v = game.getGame(id);
            assertLe(v.whiteTime, game.MAX_BASE_TIME());
            assertLe(v.blackTime, game.MAX_BASE_TIME());
        }
        // ...and the hoarder can still be flagged after at most MAX_BASE_TIME
        Chess4Profit.GameView memory v = game.getGame(id);
        assertEq(v.deadline, block.timestamp + 1 days);
        vm.warp(block.timestamp + 1 days + 1);
        game.claimTimeout(id);
        assertEq(uint8(game.getGame(id).reason), uint8(Chess4Profit.Reason.Timeout));
    }

    function test_clock_incrementStillWorksBelowTheCap() public {
        (uint256 id, address w,) = _start(60, 30);
        vm.warp(block.timestamp + 20);
        vm.prank(w);
        game.makeMove(id, FenLib.mv("e2e4"));
        assertEq(game.getGame(id).whiteTime, 60 - 20 + 30);
    }

    function test_worstCaseLockup_isBoundedByMaxBaseTime() public {
        vm.prank(mallory);
        uint256 id = game.createGame{value: STAKE}(1 days, 0, true); // hostile creator picks the longest clock
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        game.claimTimeout(id); // victim is made whole (and wins the pot) after at most MAX_BASE_TIME
        assertEq(uint8(game.getGame(id).result), uint8(Chess4Profit.Result.BlackWins));
    }

    // =============================================================== lobby spam / orphans

    function test_flood_otherStakes_cannotHideAnHonestGame() public {
        vm.prank(alice);
        uint256 honest = game.createGame{value: STAKE}(120, 0, true);
        // attacker mass-creates 300 games at many other stakes (and the same stake in separate bucket queries)
        vm.startPrank(mallory);
        for (uint256 i; i < 300; ++i) {
            game.createGame{value: game.MIN_STAKE() + i}(30, 0, true);
        }
        vm.stopPrank();
        uint256[] memory ids = game.openGames(T, 10, 100);
        assertEq(ids.length, 1);
        assertEq(ids[0], honest);
    }

    function test_flood_sameTable_costsRealCapitalAndIsBoundedForReaders() public {
        vm.prank(alice);
        uint256 honest = game.createGame{value: STAKE}(120, 0, true);
        uint256 locked0 = address(game).balance;
        vm.startPrank(mallory);
        for (uint256 i; i < 200; ++i) {
            game.createGame{value: STAKE}(120, 0, true); // same table as the honest game
        }
        vm.stopPrank();
        assertEq(address(game).balance - locked0, 200 * STAKE, "spam at a real stake locks real capital");
        // a reader's work is bounded by the limits it chooses, however many entries exist
        uint256 g0 = gasleft();
        uint256[] memory ids = game.openGames(T, 20, 50);
        uint256 used = g0 - gasleft();
        assertEq(ids.length, 20);
        assertLt(used, 1_000_000);
        emit log_named_uint("openGames(20 of 201) gas", used);
        // and the honest game is still reachable with a larger window
        ids = game.openGames(T, 500, 500);
        bool found;
        for (uint256 i; i < ids.length; ++i) if (ids[i] == honest) found = true;
        assertTrue(found);
    }

    function test_spamJoiners_areJustDonors() public {
        // a hostile joiner who never plays loses their whole stake to the creator
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(60, 0, false);
        vm.prank(mallory);
        game.joinGame{value: STAKE}(id);
        uint256 m0 = mallory.balance;
        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        game.claimTimeout(id);
        assertEq(mallory.balance, m0, "staller gets nothing back");
    }

    function test_expiry_joinRejected_afterWindow() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(120, 0, true);
        vm.warp(block.timestamp + game.OPEN_WINDOW());
        vm.prank(bob);
        game.joinGame{value: STAKE}(id); // exactly at the edge is still joinable
        vm.prank(alice);
        uint256 id2 = game.createGame{value: STAKE}(120, 0, true);
        vm.warp(block.timestamp + game.OPEN_WINDOW() + 1);
        assertEq(game.openGames(T, 10, 10).length, 0, "expired games are not advertised");
        vm.prank(bob);
        vm.expectRevert(Chess4Profit.Expired.selector);
        game.joinGame{value: STAKE}(id2);
    }

    function test_orphan_anyoneCanRefundExpired_creatorGetsMoneyBack() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(120, 0, true);
        vm.prank(mallory);
        vm.expectRevert(Chess4Profit.NotCreator.selector);
        game.cancelGame(id); // not before expiry
        vm.warp(block.timestamp + game.OPEN_WINDOW() + 1);
        uint256 a0 = alice.balance;
        uint256 m0 = mallory.balance;
        vm.prank(mallory);
        game.cancelGame(id);
        assertEq(alice.balance, a0 + STAKE, "refund goes to the creator, never the caller");
        assertEq(mallory.balance, m0);
        assertEq(game.openGameCount(T), 0);
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.cancelGame(id); // no double refund
    }

    function test_sweep_cleansExpired_keepsFresh_andHostileCreatorCannotBlockIt() public {
        RejectingCreator rc = new RejectingCreator();
        vm.deal(address(rc), 10 ether);
        vm.prank(alice);
        uint256 a1 = game.createGame{value: STAKE}(120, 0, true);
        uint256 r1 = rc.create{value: STAKE}(game, 120);
        vm.prank(bob);
        uint256 b1 = game.createGame{value: STAKE}(120, 0, true);
        vm.warp(block.timestamp + game.OPEN_WINDOW() + 1);
        vm.prank(alice);
        uint256 fresh = game.createGame{value: STAKE}(120, 0, true);

        uint256 a0 = alice.balance;
        uint256 b0 = bob.balance;
        uint256 swept = game.sweepExpired(T, 50);
        assertEq(swept, 3);
        assertEq(alice.balance, a0 + STAKE);
        assertEq(bob.balance, b0 + STAKE);
        assertEq(game.pending(address(rc)), STAKE, "rejecting creator is credited, others are unaffected");
        assertEq(game.openGameCount(T), 1);
        assertEq(game.openGames(T, 5, 5)[0], fresh);
        assertEq(uint8(game.getGame(a1).status), uint8(Chess4Profit.Status.Cancelled));
        assertEq(uint8(game.getGame(r1).status), uint8(Chess4Profit.Status.Cancelled));
        assertEq(uint8(game.getGame(b1).status), uint8(Chess4Profit.Status.Cancelled));
        assertEq(address(game).balance, 2 * STAKE - STAKE + STAKE, "fresh stake + rejected credit remain");
    }

    function test_cannotJoinAfterCancel_orTwice_andIndexStaysExact() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(120, 0, true);
        vm.prank(alice);
        game.cancelGame(id);
        assertEq(game.openGameCount(T), 0);
        vm.prank(bob);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.joinGame{value: STAKE}(id);
        vm.prank(alice);
        uint256 id2 = game.createGame{value: STAKE}(120, 0, true);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id2);
        assertEq(game.openGameCount(T), 0);
        vm.prank(mallory);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.joinGame{value: STAKE}(id2);
    }

    function test_gas_lobbyOperations() public {
        uint256 g0 = gasleft();
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(120, 0, true);
        emit log_named_uint("createGame gas", g0 - gasleft());
        g0 = gasleft();
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        emit log_named_uint("joinGame gas", g0 - gasleft());
    }

    // =============================================================== randomized: index + money stay exact

    /// Random lobby actions (create at a few stakes / join / cancel by anyone / sweep / time travel):
    /// the bucket index must equal exactly the set of Open games, and the balance must equal locked stakes + pending.
    function testFuzz_indexAndMoneyStayExact(uint256 seed) public {
        address[3] memory who = [alice, bob, mallory];
        uint256[3] memory stakes = [uint256(0.001 ether), 0.002 ether, 0.003 ether];
        for (uint256 s; s < 80; ++s) {
            uint256 r = uint256(keccak256(abi.encode(seed, s)));
            address a = who[r % 3];
            uint256 st = stakes[(r >> 8) % 3];
            uint256 n = game.nextGameId() - 1;
            uint256 id = n == 0 ? 1 : 1 + ((r >> 16) % n);
            uint256 act = (r >> 40) % 7;
            vm.startPrank(a);
            if (act <= 1) {
                game.createGame{value: st}(120, 0, (r >> 60) & 1 == 1);
            } else if (act == 2 && n > 0) {
                try game.joinGame{value: game.getGame(id).stake}(id) {} catch {}
            } else if (act == 3 && n > 0) {
                try game.cancelGame(id) {} catch {}
            } else if (act == 4) {
                game.sweepExpired(game.lobbyKey(st, 120, 0), 1 + (r >> 52) % 5);
            } else if (act == 5) {
                vm.warp(block.timestamp + (r >> 24) % (2 hours));
            } else if (n > 0) {
                try game.resign(id) {} catch {}
            }
            vm.stopPrank();

            uint256 openCount;
            uint256 locked;
            for (uint256 g = 1; g <= game.nextGameId() - 1; ++g) {
                Chess4Profit.GameView memory v = game.getGame(g);
                if (v.status == Chess4Profit.Status.Open) {
                    ++openCount;
                    locked += v.stake;
                } else if (v.status == Chess4Profit.Status.Active) {
                    locked += 2 * v.stake;
                }
            }
            uint256 inIndex;
            for (uint256 k; k < 3; ++k) inIndex += game.openGameCount(game.lobbyKey(stakes[k], 120, 0));
            assertEq(inIndex, openCount, "lobby index drifted from reality");
            uint256 pend = game.pending(alice) + game.pending(bob) + game.pending(mallory) + game.pending(game.FEE_RECIPIENT());
            assertEq(address(game).balance, locked + pend, "money not conserved");
        }
    }
}
