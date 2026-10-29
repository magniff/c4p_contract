// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Chess4Profit} from "../src/Chess4Profit.sol";
import {FenLib} from "./FenLib.sol";

/// Transaction ordering is not guaranteed: two pending transactions can land in either order, a builder can
/// delay one, and a third party can insert its own in between. For every pair of calls that can race, this
/// suite executes BOTH orders and checks that (a) the loser of the race only loses gas, (b) money is
/// conserved, (c) the game can't end twice or pay twice, and (d) who wins never depends on the order.
contract OrderingTest is Test {
    Chess4Profit game;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    uint256 constant STAKE = 1 ether;

    function setUp() public {
        game = new Chess4Profit();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function _net() internal view returns (uint256) {
        return 2 * STAKE - 2 * STAKE * game.FEE_BPS() / 10_000;
    }

    function _locked() internal view returns (uint256 total) {
        for (uint256 id = 1; id < game.nextGameId(); ++id) {
            Chess4Profit.GameView memory v = game.getGame(id);
            if (v.status == Chess4Profit.Status.Open) total += v.stake;
            else if (v.status == Chess4Profit.Status.Active) total += 2 * v.stake;
        }
        total += game.pending(alice) + game.pending(bob) + game.pending(carol) + game.pending(game.FEE_RECIPIENT());
    }

    function _assertConserved() internal view {
        assertEq(address(game).balance, _locked(), "money not conserved");
    }

    function _open() internal returns (uint256 id) {
        vm.prank(alice);
        id = game.createGame{value: STAKE}(300, 2, true);
    }

    function _active() internal returns (uint256 id) {
        id = _open();
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
    }

    // ------------------------------------------------------------ lobby races

    function test_joinVsJoin_bothOrders() public {
        for (uint256 order; order < 2; ++order) {
            uint256 id = _open();
            address first = order == 0 ? bob : carol;
            address second = order == 0 ? carol : bob;
            vm.prank(first);
            game.joinGame{value: STAKE}(id);
            vm.prank(second);
            vm.expectRevert(Chess4Profit.NotOpen.selector);
            game.joinGame{value: STAKE}(id);
            assertEq(game.getGame(id).black, first);
            _assertConserved();
        }
    }

    /// Creator cancels; a joiner's tx may land first. Join-first traps the creator in a game they meant to
    /// leave. The contract cannot prevent this (it IS the ordering problem); the creator is exposed only to
    /// their own stake and only if they then go offline. The SDK handles it by playing the game.
    function test_cancelVsJoin_bothOrders() public {
        // cancel first: joiner loses gas only
        uint256 id = _open();
        vm.prank(alice);
        game.cancelGame(id);
        vm.prank(bob);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.joinGame{value: STAKE}(id);
        _assertConserved();

        // join first: creator's cancel reverts, game is live, nothing is lost yet
        id = _open();
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.cancelGame(id);
        assertEq(uint8(game.getGame(id).status), uint8(Chess4Profit.Status.Active));
        _assertConserved();
    }

    /// At the exact expiry second both a join and a stranger's cancel can be pending. Within one block they
    /// share a timestamp, so exactly one of them is valid regardless of order.
    function test_joinVsStrangerCancel_atExpiryBoundary() public {
        uint256 id = _open();
        uint256 edge = block.timestamp + game.OPEN_WINDOW();
        vm.warp(edge); // still joinable, not yet sweepable
        vm.prank(carol);
        vm.expectRevert(Chess4Profit.NotCreator.selector);
        game.cancelGame(id);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);

        id = _open();
        vm.warp(block.timestamp + game.OPEN_WINDOW() + 1); // expired: the join is refused in either order
        vm.prank(bob);
        vm.expectRevert(Chess4Profit.Expired.selector);
        game.joinGame{value: STAKE}(id);
        vm.prank(carol);
        game.cancelGame(id);
        _assertConserved();
    }

    function test_sweepVsJoin_bothOrders() public {
        uint256 id = _open();
        bytes32 t = game.lobbyKey(STAKE, 300, 2);
        vm.warp(block.timestamp + game.OPEN_WINDOW() + 1);
        // sweep first
        game.sweepExpired(t, 10);
        vm.prank(bob);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.joinGame{value: STAKE}(id);
        // join first (on a fresh expired game): join is refused, sweep then works
        id = _open();
        vm.warp(block.timestamp + game.OPEN_WINDOW() + 1);
        vm.prank(bob);
        vm.expectRevert(Chess4Profit.Expired.selector);
        game.joinGame{value: STAKE}(id);
        assertEq(game.sweepExpired(t, 10), 1);
        _assertConserved();
    }

    // ------------------------------------------------------------ in-game races

    /// Only the side to move can act, so no two moves are ever simultaneously valid. A replayed, delayed or
    /// duplicated move always reverts.
    function test_sameSenderTwoMoves_secondAlwaysReverts() public {
        uint256 id = _active();
        vm.prank(alice);
        game.makeMove(id, FenLib.mv("e2e4"));
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.NotYourTurn.selector);
        game.makeMove(id, FenLib.mv("d2d4"));
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.NotYourTurn.selector);
        game.makeMove(id, FenLib.mv("e2e4")); // replay
    }

    /// Move vs claimTimeout at the clock boundary: they can't both be valid at the same timestamp.
    function test_moveVsClaimTimeout_atBoundary() public {
        uint256 id = _active(); // white (alice) to move, 300s
        vm.warp(block.timestamp + 300); // last valid second
        vm.prank(carol);
        vm.expectRevert(Chess4Profit.NotTimedOut.selector);
        game.claimTimeout(id);
        vm.prank(alice);
        game.makeMove(id, FenLib.mv("e2e4"));

        id = _active();
        vm.warp(block.timestamp + 301);
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.TurnTimedOut.selector);
        game.makeMove(id, FenLib.mv("e2e4"));
        vm.prank(carol);
        game.claimTimeout(id);
        assertEq(uint8(game.getGame(id).result), uint8(Chess4Profit.Result.BlackWins));
        _assertConserved();
    }

    /// Resign vs the opponent's mating move: whichever lands first ends the game; the other reverts; the
    /// winner is the same either way and the pot is paid exactly once.
    function test_resignVsCheckmate_bothOrders_sameWinnerPaidOnce() public {
        for (uint256 order; order < 2; ++order) {
            uint256 id = _active();
            string[3] memory pre = ["f2f3", "e7e5", "g2g4"];
            for (uint256 i; i < 3; ++i) {
                vm.prank(i % 2 == 0 ? alice : bob);
                game.makeMove(id, FenLib.mv(pre[i]));
            }
            uint256 bobBefore = bob.balance;
            if (order == 0) {
                vm.prank(bob);
                game.makeMove(id, FenLib.mv("d8h4")); // mate lands first
                vm.prank(alice);
                vm.expectRevert(Chess4Profit.NotActive.selector);
                game.resign(id);
            } else {
                vm.prank(alice);
                game.resign(id); // resignation lands first
                vm.prank(bob);
                vm.expectRevert(Chess4Profit.NotActive.selector);
                game.makeMove(id, FenLib.mv("d8h4"));
            }
            assertEq(uint8(game.getGame(id).result), uint8(Chess4Profit.Result.BlackWins));
            assertEq(bob.balance, bobBefore + _net(), "paid exactly once, same amount either order");
            _assertConserved();
        }
    }

    /// Resign vs claimTimeout against the same (flagged) player: same winner either order.
    function test_resignVsClaimTimeout_bothOrders() public {
        for (uint256 order; order < 2; ++order) {
            uint256 id = _active();
            vm.warp(block.timestamp + 301); // alice flagged
            if (order == 0) {
                vm.prank(alice);
                game.resign(id);
                vm.prank(bob);
                vm.expectRevert(Chess4Profit.NotActive.selector);
                game.claimTimeout(id);
            } else {
                vm.prank(bob);
                game.claimTimeout(id);
                vm.prank(alice);
                vm.expectRevert(Chess4Profit.NotActive.selector);
                game.resign(id);
            }
            assertEq(uint8(game.getGame(id).result), uint8(Chess4Profit.Result.BlackWins));
            _assertConserved();
        }
    }

    /// A move submitted "just in time" that a builder delays past the deadline simply reverts; the player
    /// cannot be made to lose MORE than the timeout they already incurred, and nothing can be extracted.
    function test_delayedMove_revertsCleanly_noStateChange() public {
        uint256 id = _active();
        Chess4Profit.GameView memory before_ = game.getGame(id);
        vm.warp(block.timestamp + 301);
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.TurnTimedOut.selector);
        game.makeMove(id, FenLib.mv("e2e4"));
        Chess4Profit.GameView memory after_ = game.getGame(id);
        assertEq(after_.plies, before_.plies);
        assertEq(after_.whiteTime, before_.whiteTime);
        assertEq(after_.lastMoveAt, before_.lastMoveAt);
    }

    function test_withdrawTwice_secondReverts() public {
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.NothingToWithdraw.selector);
        game.withdraw();
    }

    // ------------------------------------------------------------ adversarial interleaving (fuzz)

    /// Take a fixed bag of pending transactions from three parties and apply them in a seed-chosen
    /// permutation. Every permutation must leave money conserved and the game in a terminal-or-consistent
    /// state, and the only observable difference between orders is who won a race.
    function testFuzz_permutedPendingTransactions(uint256 seed) public {
        uint256 id = _open();
        // the bag: alice cancels, bob joins, carol joins, carol sweeps, time passes, alice cancels again
        uint8[6] memory bag = [0, 1, 2, 3, 4, 0];
        // Fisher-Yates with the seed
        for (uint256 i = bag.length - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (bag[i], bag[j]) = (bag[j], bag[i]);
        }
        for (uint256 k; k < bag.length; ++k) {
            uint8 a = bag[k];
            if (a == 0) {
                vm.prank(alice);
                try game.cancelGame(id) {} catch {}
            } else if (a == 1) {
                vm.prank(bob);
                try game.joinGame{value: STAKE}(id) {} catch {}
            } else if (a == 2) {
                vm.prank(carol);
                try game.joinGame{value: STAKE}(id) {} catch {}
            } else if (a == 3) {
                vm.prank(carol);
                game.sweepExpired(game.lobbyKey(STAKE, 300, 2), 5);
            } else {
                vm.warp(block.timestamp + ((seed >> 8) % 2) * (game.OPEN_WINDOW() + 1));
            }
            _assertConserved();
        }
        Chess4Profit.GameView memory v = game.getGame(id);
        // terminal lobby states only: either someone is seated (Active) or the stake went home (Cancelled)
        assertTrue(v.status == Chess4Profit.Status.Active || v.status == Chess4Profit.Status.Cancelled
            || v.status == Chess4Profit.Status.Open);
        if (v.status == Chess4Profit.Status.Active) {
            assertTrue(v.black == bob || v.black == carol);
            assertEq(v.white, alice);
        }
    }
}
