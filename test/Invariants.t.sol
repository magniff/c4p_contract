// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Chess4Profit} from "../src/Chess4Profit.sol";
import {ChessEngine} from "../src/ChessEngine.sol";

/// Foundry drives this handler with random call sequences (see [invariant] in foundry.toml); after every call the
/// invariants below are re-checked. Every action is attempted by a random actor, in a random order, with random
/// time travel in between, which is exactly what a hostile, reordering network looks like to the contract.
contract Handler is Test {
    Chess4Profit public game;
    address[3] public actors;
    uint256[2] public stakes = [uint256(0.001 ether), 0.002 ether];
    uint32 constant BASE = 120;
    uint32 constant INC = 1;

    uint256 public totalFeePaid;
    uint256 public settledPots;

    constructor(Chess4Profit g) {
        game = g;
        actors = [makeAddr("a"), makeAddr("b"), makeAddr("c")];
        for (uint256 i; i < 3; ++i) vm.deal(actors[i], 1_000_000 ether);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _anyGame(uint256 seed) internal view returns (uint256) {
        uint256 n = game.nextGameId() - 1;
        return n == 0 ? 1 : 1 + seed % n;
    }

    function create(uint256 who, uint256 s, bool white) external {
        vm.prank(_actor(who));
        game.createGame{value: stakes[s % 2]}(BASE, INC, white);
    }

    function join(uint256 who, uint256 g) external {
        uint256 id = _anyGame(g);
        if (game.nextGameId() == 1) return;
        uint256 st = game.getGame(id).stake;
        vm.prank(_actor(who));
        try game.joinGame{value: st}(id) {} catch {}
    }

    function cancel(uint256 who, uint256 g) external {
        if (game.nextGameId() == 1) return;
        vm.prank(_actor(who));
        try game.cancelGame(_anyGame(g)) {} catch {}
    }

    function sweep(uint256 who, uint256 s, uint256 limit) external {
        vm.prank(_actor(who));
        game.sweepExpired(game.lobbyKey(stakes[s % 2], BASE, INC), 1 + limit % 5);
    }

    function resign(uint256 who, uint256 g) external {
        if (game.nextGameId() == 1) return;
        vm.prank(_actor(who));
        try game.resign(_anyGame(g)) {} catch {}
    }

    function claim(uint256 who, uint256 g) external {
        if (game.nextGameId() == 1) return;
        vm.prank(_actor(who));
        try game.claimTimeout(_anyGame(g)) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + dt % 2 hours);
    }

    /// A legal move by the right player most of the time; sometimes the wrong player, sometimes garbage.
    function move(uint256 who, uint256 g, uint256 pick, uint16 garbage) external {
        if (game.nextGameId() == 1) return;
        uint256 id = _anyGame(g);
        Chess4Profit.GameView memory v = game.getGame(id);
        if (v.status != Chess4Profit.Status.Active) return;
        address mover = pick % 8 == 0 ? _actor(who) : (v.whiteToMove ? v.white : v.black);
        uint16 m = garbage;
        if (pick % 8 != 1) {
            uint16[] memory legal = game.legalMoves(id);
            if (legal.length == 0) return;
            m = legal[pick % legal.length];
        }
        vm.prank(mover);
        try game.makeMove(id, m) {} catch {}
    }
}

contract InvariantsTest is StdInvariant, Test {
    Chess4Profit game;
    Handler h;

    function setUp() public {
        game = new Chess4Profit();
        h = new Handler(game);
        targetContract(address(h));
    }

    function _locked() internal view returns (uint256 total) {
        for (uint256 id = 1; id < game.nextGameId(); ++id) {
            Chess4Profit.GameView memory v = game.getGame(id);
            if (v.status == Chess4Profit.Status.Open) total += v.stake;
            else if (v.status == Chess4Profit.Status.Active) total += 2 * v.stake;
        }
    }

    function _pending() internal view returns (uint256 total) {
        for (uint256 i; i < 3; ++i) total += game.pending(h.actors(i));
        total += game.pending(game.FEE_RECIPIENT());
    }

    /// The contract never holds more or less than the stakes still in play plus unclaimed credits.
    function invariant_moneyConserved() public view {
        assertEq(address(game).balance, _locked() + _pending());
    }

    /// The lobby index is exactly the set of Open games (no stale entries, nothing missing).
    function invariant_lobbyIndexExact() public view {
        uint256 openCount;
        for (uint256 id = 1; id < game.nextGameId(); ++id) {
            if (game.getGame(id).status == Chess4Profit.Status.Open) ++openCount;
        }
        uint256 inIndex = game.openGameCount(game.lobbyKey(0.001 ether, 120, 1))
            + game.openGameCount(game.lobbyKey(0.002 ether, 120, 1));
        assertEq(inIndex, openCount);
    }

    /// Every game is in a sane state: finished games have a result and reason, active games have two
    /// distinct players and clocks within bounds, and nothing is ever "half settled".
    function invariant_gameStatesConsistent() public view {
        for (uint256 id = 1; id < game.nextGameId(); ++id) {
            Chess4Profit.GameView memory v = game.getGame(id);
            if (v.status == Chess4Profit.Status.Finished) {
                assertTrue(v.result != Chess4Profit.Result.None && v.reason != Chess4Profit.Reason.None);
            } else {
                assertTrue(v.result == Chess4Profit.Result.None && v.reason == Chess4Profit.Reason.None);
            }
            if (v.status == Chess4Profit.Status.Active) {
                assertTrue(v.white != v.black && v.white != address(0) && v.black != address(0));
                assertLe(v.whiteTime, game.MAX_BASE_TIME());
                assertLe(v.blackTime, game.MAX_BASE_TIME());
            }
        }
    }
}
