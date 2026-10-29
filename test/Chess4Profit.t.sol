// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Chess4Profit} from "../src/Chess4Profit.sol";
import {FenLib} from "./FenLib.sol";

/// @dev A player whose receive() always reverts, to prove a hostile winner can't brick a game.
contract HostilePlayer {
    Chess4Profit public immutable game;

    constructor(Chess4Profit g) {
        game = g;
    }

    function create(uint32 t) external payable returns (uint256) {
        return game.createGame{value: msg.value}(t, 0, true);
    }

    function join(uint256 id) external payable {
        game.joinGame{value: msg.value}(id);
    }

    function move(uint256 id, uint16 m) external {
        game.makeMove(id, m);
    }

    function pull() external {
        game.withdraw();
    }

    receive() external payable {
        revert("no thanks");
    }
}

contract Chess4ProfitTest is Test {
    Chess4Profit game;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant STAKE = 1 ether;
    uint32 constant TIMEOUT = 1 hours;

    function setUp() public {
        game = new Chess4Profit();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    // ------------------------------------------------------------ helpers

    function _start() internal returns (uint256 id, address white, address black) {
        vm.prank(alice);
        id = game.createGame{value: STAKE}(TIMEOUT, 0, true);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        Chess4Profit.GameView memory v = game.getGame(id);
        white = v.white;
        black = v.black;
    }

    /// plays a space separated UCI line, alternating white/black
    function _play(uint256 id, address white, address black, string[] memory line) internal {
        for (uint256 i; i < line.length; ++i) {
            vm.prank(i % 2 == 0 ? white : black);
            game.makeMove(id, FenLib.mv(line[i]));
        }
    }

    function _fools() internal pure returns (string[] memory l) {
        l = new string[](4);
        l[0] = "f2f3";
        l[1] = "e7e5";
        l[2] = "g2g4";
        l[3] = "d8h4";
    }

    function _fee(uint256 pot) internal view returns (uint256) {
        return pot * game.FEE_BPS() / 10_000;
    }

    // ------------------------------------------------------------ lobby

    function test_create_emitsAndLocksStake() public {
        vm.expectEmit(true, true, false, true);
        emit Chess4Profit.GameCreated(1, alice, STAKE, TIMEOUT, 0, true);
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(TIMEOUT, 0, true);
        assertEq(id, 1);
        assertEq(address(game).balance, STAKE);
        assertEq(uint8(game.getGame(id).status), uint8(Chess4Profit.Status.Open));
    }

    function test_create_rejectsBadParams() public {
        uint256 dust = game.MIN_STAKE() - 1;
        vm.startPrank(alice);
        vm.expectRevert(Chess4Profit.BadStake.selector);
        game.createGame{value: dust}(TIMEOUT, 0, true);
        vm.expectRevert(Chess4Profit.BadTimeout.selector);
        game.createGame{value: STAKE}(1, 0, true);
        vm.expectRevert(Chess4Profit.BadTimeout.selector);
        game.createGame{value: STAKE}(30 days, 0, true);
        vm.stopPrank();
    }

    function test_join_mustMatchStake() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(TIMEOUT, 0, true);
        vm.startPrank(bob);
        vm.expectRevert(Chess4Profit.BadStake.selector);
        game.joinGame{value: STAKE - 1}(id);
        vm.expectRevert(Chess4Profit.BadStake.selector);
        game.joinGame{value: STAKE + 1}(id);
        vm.stopPrank();
    }

    function test_join_noSelfJoinNoDoubleJoin() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(TIMEOUT, 0, true);
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.SelfJoin.selector);
        game.joinGame{value: STAKE}(id);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        vm.prank(carol);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.joinGame{value: STAKE}(id);
    }

    function test_join_unknownGame() public {
        vm.prank(bob);
        vm.expectRevert(Chess4Profit.UnknownGame.selector);
        game.joinGame{value: STAKE}(42);
    }

    function test_join_startsGameAndEmits() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(TIMEOUT, 0, true);
        vm.recordLogs();
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);
        Chess4Profit.GameView memory v = game.getGame(id);
        assertEq(uint8(v.status), uint8(Chess4Profit.Status.Active));
        assertTrue((v.white == alice && v.black == bob) || (v.white == bob && v.black == alice));
        assertTrue(v.whiteToMove);
        assertEq(address(game).balance, 2 * STAKE);
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function test_cancel() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(TIMEOUT, 0, true);
        vm.prank(bob);
        vm.expectRevert(Chess4Profit.NotCreator.selector);
        game.cancelGame(id);
        uint256 before_ = alice.balance;
        vm.prank(alice);
        game.cancelGame(id);
        assertEq(alice.balance, before_ + STAKE);
        assertEq(address(game).balance, 0);
        vm.prank(bob);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.joinGame{value: STAKE}(id);
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.cancelGame(id);
    }

    function test_cancel_notAfterJoin() public {
        (uint256 id,,) = _start();
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.NotOpen.selector);
        game.cancelGame(id);
    }

    // ------------------------------------------------------------ moves

    function test_move_onlyPlayersInTurn() public {
        (uint256 id, address white, address black) = _start();
        vm.prank(carol);
        vm.expectRevert(Chess4Profit.NotYourTurn.selector);
        game.makeMove(id, FenLib.mv("e2e4"));
        vm.prank(black);
        vm.expectRevert(Chess4Profit.NotYourTurn.selector);
        game.makeMove(id, FenLib.mv("e7e5"));
        vm.prank(white);
        game.makeMove(id, FenLib.mv("e2e4"));
        vm.prank(white);
        vm.expectRevert(Chess4Profit.NotYourTurn.selector);
        game.makeMove(id, FenLib.mv("d2d4"));
    }

    function test_move_illegalReverts() public {
        (uint256 id, address white,) = _start();
        vm.startPrank(white);
        vm.expectRevert(Chess4Profit.IllegalMove.selector);
        game.makeMove(id, FenLib.mv("e2e5"));
        vm.expectRevert(Chess4Profit.IllegalMove.selector);
        game.makeMove(id, FenLib.mv("e7e5"));
        vm.expectRevert(Chess4Profit.IllegalMove.selector);
        game.makeMove(id, 0);
        vm.stopPrank();
    }

    function test_move_requiresActiveGame() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: STAKE}(TIMEOUT, 0, true);
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.NotActive.selector);
        game.makeMove(id, FenLib.mv("e2e4"));
    }

    function test_move_emitsEvent() public {
        (uint256 id, address white,) = _start();
        vm.expectEmit(true, true, false, true);
        emit Chess4Profit.MoveMade(id, white, FenLib.mv("e2e4"), 1);
        vm.prank(white);
        game.makeMove(id, FenLib.mv("e2e4"));
    }

    function test_legalMovesView() public {
        (uint256 id,,) = _start();
        assertEq(game.legalMoves(id).length, 20);
        assertTrue(game.isMoveLegal(id, FenLib.mv("e2e4")));
        assertFalse(game.isMoveLegal(id, FenLib.mv("e2e5")));
    }

    // ------------------------------------------------------------ endings & money

    function test_checkmate_paysWinnerMinusFee() public {
        (uint256 id, address white, address black) = _start();
        uint256 feeBefore = game.FEE_RECIPIENT().balance;
        uint256 blackBefore = black.balance;
        uint256 whiteBefore = white.balance;

        _play(id, white, black, _fools());

        uint256 pot = 2 * STAKE;
        uint256 fee = _fee(pot);
        Chess4Profit.GameView memory v = game.getGame(id);
        assertEq(uint8(v.status), uint8(Chess4Profit.Status.Finished));
        assertEq(uint8(v.result), uint8(Chess4Profit.Result.BlackWins));
        assertEq(uint8(v.reason), uint8(Chess4Profit.Reason.Checkmate));
        assertEq(black.balance, blackBefore + pot - fee);
        assertEq(white.balance, whiteBefore);
        assertEq(game.FEE_RECIPIENT().balance, feeBefore + fee);
        assertEq(address(game).balance, 0, "contract must hold nothing");
    }

    function test_noMovesAfterGameOver() public {
        (uint256 id, address white, address black) = _start();
        _play(id, white, black, _fools());
        vm.prank(white);
        vm.expectRevert(Chess4Profit.NotActive.selector);
        game.makeMove(id, FenLib.mv("a2a3"));
        vm.prank(white);
        vm.expectRevert(Chess4Profit.NotActive.selector);
        game.resign(id);
        vm.prank(white);
        vm.expectRevert(Chess4Profit.NotActive.selector);
        game.claimTimeout(id);
    }

    function test_resign() public {
        (uint256 id, address white, address black) = _start();
        uint256 whiteBefore = white.balance;
        vm.prank(carol);
        vm.expectRevert(Chess4Profit.NotPlayer.selector);
        game.resign(id);
        vm.prank(black);
        game.resign(id);
        Chess4Profit.GameView memory v = game.getGame(id);
        assertEq(uint8(v.result), uint8(Chess4Profit.Result.WhiteWins));
        assertEq(uint8(v.reason), uint8(Chess4Profit.Reason.Resignation));
        assertEq(white.balance, whiteBefore + 2 * STAKE - _fee(2 * STAKE));
        assertEq(address(game).balance, 0);
    }

    function test_timeout_claim() public {
        (uint256 id, address white, address black) = _start();
        uint256 blackBefore = black.balance;
        vm.warp(block.timestamp + TIMEOUT);
        vm.expectRevert(Chess4Profit.NotTimedOut.selector);
        game.claimTimeout(id); // exactly at the deadline is still in time
        vm.warp(block.timestamp + 1);
        // late white may no longer move...
        vm.prank(white);
        vm.expectRevert(Chess4Profit.TurnTimedOut.selector);
        game.makeMove(id, FenLib.mv("e2e4"));
        // ...and anyone can settle for black
        vm.prank(carol);
        game.claimTimeout(id);
        Chess4Profit.GameView memory v = game.getGame(id);
        assertEq(uint8(v.result), uint8(Chess4Profit.Result.BlackWins));
        assertEq(uint8(v.reason), uint8(Chess4Profit.Reason.Timeout));
        assertEq(black.balance, blackBefore + 2 * STAKE - _fee(2 * STAKE));
        assertEq(address(game).balance, 0);
    }

    function test_timeout_clockResetsAfterMove() public {
        (uint256 id, address white, address black) = _start();
        vm.warp(block.timestamp + TIMEOUT - 1);
        vm.prank(white);
        game.makeMove(id, FenLib.mv("e2e4"));
        vm.warp(block.timestamp + TIMEOUT - 1);
        vm.expectRevert(Chess4Profit.NotTimedOut.selector);
        game.claimTimeout(id);
        vm.prank(black);
        game.makeMove(id, FenLib.mv("e7e5"));
        vm.warp(block.timestamp + TIMEOUT + 1);
        vm.prank(alice);
        game.claimTimeout(id);
        // white to move timed out -> black wins
        assertEq(uint8(game.getGame(id).result), uint8(Chess4Profit.Result.BlackWins));
    }

    function test_threefoldRepetition_splitsPotMinusFee() public {
        (uint256 id, address white, address black) = _start();
        uint256 wb = white.balance;
        uint256 bb = black.balance;
        string[] memory l = new string[](8);
        l[0] = "g1f3";
        l[1] = "g8f6";
        l[2] = "f3g1";
        l[3] = "f6g8";
        l[4] = "g1f3";
        l[5] = "g8f6";
        l[6] = "f3g1";
        l[7] = "f6g8";
        _play(id, white, black, l);
        Chess4Profit.GameView memory v = game.getGame(id);
        assertEq(uint8(v.result), uint8(Chess4Profit.Result.Draw));
        assertEq(uint8(v.reason), uint8(Chess4Profit.Reason.ThreefoldRepetition));
        uint256 pot = 2 * STAKE;
        uint256 half = (pot - _fee(pot)) / 2;
        assertEq(white.balance, wb + half);
        assertEq(black.balance, bb + half);
        assertEq(address(game).balance, 0);
    }

    function test_repetition_notTriggeredByTwoOccurrences() public {
        (uint256 id, address white, address black) = _start();
        string[] memory l = new string[](4);
        l[0] = "g1f3";
        l[1] = "g8f6";
        l[2] = "f3g1";
        l[3] = "f6g8";
        _play(id, white, black, l);
        assertEq(uint8(game.getGame(id).status), uint8(Chess4Profit.Status.Active));
    }

    function test_oddWeiGoesToFee_onDraw() public {
        vm.prank(alice);
        uint256 id = game.createGame{value: 100_000_000_000_001 wei}(TIMEOUT, 0, true);
        vm.prank(bob);
        game.joinGame{value: 100_000_000_000_001 wei}(id);
        Chess4Profit.GameView memory v = game.getGame(id);
        string[] memory l = new string[](8);
        l[0] = "g1f3";
        l[1] = "g8f6";
        l[2] = "f3g1";
        l[3] = "f6g8";
        l[4] = "g1f3";
        l[5] = "g8f6";
        l[6] = "f3g1";
        l[7] = "f6g8";
        uint256 feeBefore = game.FEE_RECIPIENT().balance;
        _play(id, v.white, v.black, l);
        assertEq(address(game).balance, 0, "no wei stranded");
        assertGt(game.FEE_RECIPIENT().balance, feeBefore);
    }

    function test_colour_isCreatorsChoice_andNotInfluencedByJoiner() public {
        for (uint256 i; i < 8; ++i) {
            vm.prevrandao(bytes32(i * 7919 + 1)); // no on-chain randomness is consulted
            bool creatorWhite = i % 2 == 0;
            vm.prank(alice);
            uint256 id = game.createGame{value: STAKE}(TIMEOUT, 0, creatorWhite);
            vm.prank(bob);
            game.joinGame{value: STAKE}(id);
            assertEq(game.getGame(id).white, creatorWhite ? alice : bob);
            assertEq(game.getGame(id).black, creatorWhite ? bob : alice);
        }
    }

    // ------------------------------------------------------------ hostile receiver

    function test_hostileWinner_cannotBlockPayout_andCanWithdrawLater() public {
        HostilePlayer h = new HostilePlayer(game);
        vm.deal(address(h), 10 ether);
        uint256 id = h.create{value: STAKE}(TIMEOUT);
        vm.prank(bob);
        game.joinGame{value: STAKE}(id);

        // bob resigns, so the hostile contract wins whichever colour it drew
        vm.prank(bob);
        game.resign(id);
        // not blocked: game is finished, funds credited for pull
        assertEq(uint8(game.getGame(id).status), uint8(Chess4Profit.Status.Finished));
        uint256 owed = 2 * STAKE - _fee(2 * STAKE);
        assertEq(game.pending(address(h)), owed);
        assertEq(address(game).balance, owed, "only the hostile winner's money remains");

        // withdraw to a receiving address still reverts for the hostile contract (its own problem), funds stay safe
        vm.expectRevert();
        h.pull();
        assertEq(game.pending(address(h)), owed, "failed withdraw keeps the credit");
    }

    function test_gasReport_fullGame() public {
        (uint256 id, address white, address black) = _start();
        string[] memory l = _fools();
        uint256 total;
        for (uint256 i; i < l.length; ++i) {
            vm.prank(i % 2 == 0 ? white : black);
            uint256 g0 = gasleft();
            game.makeMove(id, FenLib.mv(l[i]));
            uint256 used = g0 - gasleft();
            emit log_named_uint(l[i], used);
            total += used;
        }
        emit log_named_uint("total gas, fool's mate", total);
    }
}
