// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Chess4Profit} from "../src/Chess4Profit.sol";
import {ChessEngine} from "../src/ChessEngine.sol";

/// The storage layout is packed for gas (see `Game` / `State`). These tests pin what that packing must never
/// change: which slots a move may write, that the packed position round-trips exactly, that the creator's seat
/// logic is right for both colours, and the stake bound.
contract StorageTest is Test {
    Chess4Profit game;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant GAMES_SLOT = 1; // `games` mapping (after nextGameId)
    uint256 constant POSITION_COUNT_SLOT = 2; // `positionCount` mapping

    function setUp() public {
        game = new Chess4Profit();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function _start(bool aliceWhite) internal returns (uint256 id) {
        vm.prank(alice);
        id = game.createGame{value: 1 ether}(300, 2, aliceWhite);
        vm.prank(bob);
        game.joinGame{value: 1 ether}(id);
    }

    function _gameSlot(uint256 id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(id, GAMES_SLOT)));
    }

    function _countSlot(uint256 id, bytes32 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, keccak256(abi.encode(id, POSITION_COUNT_SLOT))));
    }

    // ------------------------------------------------------------------ layout

    /// The layout constants above are right: slot 0 holds white|stake, slot 3 the board.
    function test_layoutConstants() public {
        uint256 id = _start(true);
        uint256 base = _gameSlot(id);
        uint256 s0 = uint256(vm.load(address(game), bytes32(base)));
        assertEq(address(uint160(s0)), alice);
        assertEq(s0 >> 160, 1 ether);
        assertEq(address(uint160(uint256(vm.load(address(game), bytes32(base + 1))))), bob);
        assertEq(uint256(vm.load(address(game), bytes32(base + 3))), game.getPosition(id).board);
    }

    /// An ordinary move writes exactly three slots: the packed state, the board, and the repetition counter.
    /// The reentrancy lock is transient, so it leaves no storage write behind.
    function test_moveWritesOnlyStateBoardAndCounter() public {
        uint256 id = _start(true);
        uint256 base = _gameSlot(id);
        vm.record();
        vm.prank(alice);
        game.makeMove(id, ChessEngine.encode(12, 28, 0)); // e2e4
        (, bytes32[] memory writes) = vm.accesses(address(game));
        bytes32 counter = _countSlot(id, ChessEngine.positionKey(game.getPosition(id)));
        for (uint256 i; i < writes.length; ++i) {
            bytes32 w = writes[i];
            assertTrue(w == bytes32(base + 2) || w == bytes32(base + 3) || w == counter, "unexpected storage write");
        }
        assertEq(uint256(vm.load(address(game), counter)), 1);
    }

    /// Over random games, the packed state round-trips exactly against the engine replayed in memory.
    function testFuzz_packedPositionRoundTrips(uint256 seed, bool aliceWhite) public {
        uint256 id = _start(aliceWhite);
        address white = aliceWhite ? alice : bob;
        address black = aliceWhite ? bob : alice;
        ChessEngine.Position memory p = ChessEngine.initialPosition();
        for (uint256 ply = 1; ply <= 160; ++ply) {
            uint16[] memory legal = game.legalMoves(id);
            uint16 m = legal[uint256(keccak256(abi.encode(seed, ply))) % legal.length];
            (, p) = ChessEngine.applyMove(p, m);
            vm.warp(block.timestamp + uint256(keccak256(abi.encode(seed, "t", ply))) % 3);
            vm.prank(p.whiteToMove ? black : white); // p is already after the move
            game.makeMove(id, m);

            assertEq(keccak256(abi.encode(game.getPosition(id))), keccak256(abi.encode(p)), "position");
            Chess4Profit.GameView memory v = game.getGame(id);
            assertEq(v.plies, ply);
            assertEq(v.whiteToMove, p.whiteToMove);
            assertEq(v.white, white);
            assertEq(v.black, black);
            assertEq(v.stake, 1 ether);
            assertEq(v.increment, 2);
            assertEq(v.lastMoveAt, block.timestamp);
            if (v.status != Chess4Profit.Status.Active) break;
        }
    }

    // ------------------------------------------------------------------ seats

    function test_creatorAsBlack_seatsAndEvents() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: 1 ether}(300, 2, false);
        Chess4Profit.GameView memory v = game.getGame(id);
        assertEq(v.white, alice); // creator listed first while open, whatever colour they chose
        assertEq(v.black, address(0));

        vm.prank(alice);
        vm.expectRevert(Chess4Profit.SelfJoin.selector);
        game.joinGame{value: 1 ether}(id);

        vm.expectEmit(true, true, true, true);
        emit Chess4Profit.GameStarted(id, bob, alice);
        vm.prank(bob);
        game.joinGame{value: 1 ether}(id);
        v = game.getGame(id);
        assertEq(v.white, bob);
        assertEq(v.black, alice);

        vm.prank(alice);
        vm.expectRevert(Chess4Profit.NotYourTurn.selector);
        game.makeMove(id, ChessEngine.encode(12, 28, 0));
        vm.prank(bob);
        game.makeMove(id, ChessEngine.encode(12, 28, 0));
    }

    function test_creatorAsBlack_cancelAndSweepRefundTheCreator() public {
        vm.startPrank(alice);
        uint256 a = game.createGame{value: 1 ether}(300, 2, false);
        uint256 b = game.createGame{value: 1 ether}(300, 2, false);
        vm.stopPrank();

        vm.prank(carol);
        vm.expectRevert(Chess4Profit.NotCreator.selector);
        game.cancelGame(a);

        uint256 before = alice.balance;
        vm.prank(alice);
        game.cancelGame(a);
        assertEq(alice.balance, before + 1 ether);
        assertEq(game.getGame(a).white, alice); // still shown as the creator after cancelling

        vm.warp(block.timestamp + game.OPEN_WINDOW() + 1);
        vm.prank(carol);
        assertEq(game.sweepExpired(game.lobbyKey(1 ether, 300, 2), 10), 1);
        assertEq(alice.balance, before + 2 ether);
        assertEq(uint8(game.getGame(b).status), uint8(Chess4Profit.Status.Cancelled));
        assertEq(address(game).balance, 0);
    }

    function test_resignPaysTheRightSeat() public {
        uint256 id = _start(false); // alice black, bob white
        uint256 before = alice.balance;
        vm.prank(bob);
        game.resign(id);
        Chess4Profit.GameView memory v = game.getGame(id);
        assertEq(uint8(v.result), uint8(Chess4Profit.Result.BlackWins));
        assertEq(alice.balance, before + 2 ether - 2 ether * game.FEE_BPS() / 10_000);
    }

    // ------------------------------------------------------------------ stake bound

    function test_stakeBoundIsUint96() public {
        uint256 max = type(uint96).max;
        vm.deal(alice, max + 1);
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.BadStake.selector);
        game.createGame{value: max + 1}(300, 2, true);
        vm.prank(alice);
        uint256 id = game.createGame{value: max}(300, 2, true);
        assertEq(game.getGame(id).stake, max);
        vm.prank(alice);
        game.cancelGame(id);
        assertEq(alice.balance, max + 1);
    }
}
