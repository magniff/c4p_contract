// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Chess4Profit} from "../src/Chess4Profit.sol";

contract ProfilesTest is Test {
    Chess4Profit game;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        game = new Chess4Profit();
    }

    function _set(address who, string memory n, string memory d) internal {
        vm.prank(who);
        game.setProfile(n, d);
    }

    function test_setAndRead() public {
        vm.expectEmit(true, false, false, true);
        emit Chess4Profit.ProfileUpdated(alice, "Deep Pawn 2", "Stockfish 19, skill 20. Plays 300+2 tables.");
        _set(alice, "Deep Pawn 2", "Stockfish 19, skill 20. Plays 300+2 tables.");
        (string memory n, string memory d) = game.profileOf(alice);
        assertEq(n, "Deep Pawn 2");
        assertEq(d, "Stockfish 19, skill 20. Plays 300+2 tables.");
        (n, d) = game.profileOf(bob);
        assertEq(bytes(n).length, 0, "unset profiles are empty");
    }

    function test_onlyOwnProfile_andUpdatesReplace() public {
        _set(alice, "alpha", "first");
        _set(bob, "bravo", "second");
        _set(alice, "alpha.v2", "");
        (string memory n, string memory d) = game.profileOf(alice);
        assertEq(n, "alpha.v2");
        assertEq(bytes(d).length, 0);
        (n,) = game.profileOf(bob);
        assertEq(n, "bravo", "alice's update can't touch bob");
    }

    function test_clearDeletes() public {
        _set(alice, "temp", "x");
        _set(alice, "", "");
        (string memory n, string memory d) = game.profileOf(alice);
        assertEq(bytes(n).length + bytes(d).length, 0);
    }

    function test_unicodeDescriptionAllowed() public {
        _set(alice, "Leela", unicode"Нейросеть ♞ — plays fast 🐎");
        (, string memory d) = game.profileOf(alice);
        assertEq(d, unicode"Нейросеть ♞ — plays fast 🐎");
    }

    function test_lengthLimits() public {
        _set(alice, "abcdefghijklmnopqrstuvwxyz012345", ""); // exactly 32
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.BadName.selector);
        game.setProfile("abcdefghijklmnopqrstuvwxyz0123456", ""); // 33
        bytes memory d = new bytes(280);
        for (uint256 i; i < d.length; ++i) d[i] = "x";
        _set(alice, "a", string(d));
        bytes memory d2 = new bytes(281);
        for (uint256 i; i < d2.length; ++i) d2[i] = "x";
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.BadDescription.selector);
        game.setProfile("a", string(d2));
    }

    /// Everything a renderer could interpret: markup, HTML, terminal escapes, look-alike spacing.
    function test_injectionAndSpoofingNamesRejected() public {
        bytes memory rawHigh = hex"656d6f6a69f09f8e"; // "emoji" + truncated UTF-8: raw high bytes
        vm.prank(alice);
        vm.expectRevert(Chess4Profit.BadName.selector);
        game.setProfile(string(rawHigh), "");

        string[11] memory bad = [
            "[bold red]x",              // Rich markup
            "[link=https://evil]x[/]",  // Rich link
            "<script>",                 // HTML
            "a\u001b[2Jb",              // ANSI clear-screen
            "tab\tname",                // control
            " Magnus",                  // leading space
            "Magnus ",                  // trailing space
            "Mag  nus",                 // double space
            unicode"Magnüs",            // non-ASCII homoglyph territory
            "semi;colon",
            "quote\"d"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(Chess4Profit.BadName.selector);
            game.setProfile(bad[i], "");
        }
    }

    function test_controlBytesInDescriptionRejected() public {
        string[4] memory bad = ["line1\nline2", "a\u001b[31mred", "nul\u0000byte", "del\u007f"];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(Chess4Profit.BadDescription.selector);
            game.setProfile("ok", bad[i]);
        }
    }

    /// A name is accepted iff it satisfies the documented rule, for arbitrary bytes.
    function testFuzz_nameRule(bytes memory raw) public {
        vm.assume(raw.length <= 40);
        bool expect = raw.length <= 32;
        for (uint256 i; i < raw.length && expect; ++i) {
            bytes1 c = raw[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-"
                || c == "_" || c == ".";
            if (c == " ") ok = i != 0 && i != raw.length - 1 && raw[i - 1] != " ";
            expect = ok;
        }
        vm.prank(alice);
        if (expect) {
            game.setProfile(string(raw), "");
            (string memory n,) = game.profileOf(alice);
            assertEq(n, string(raw));
        } else {
            vm.expectRevert(Chess4Profit.BadName.selector);
            game.setProfile(string(raw), "");
        }
    }

    function test_gas_profileWrite() public {
        bytes memory d = new bytes(280);
        for (uint256 i; i < d.length; ++i) d[i] = "x";
        vm.prank(alice);
        uint256 g0 = gasleft();
        game.setProfile("abcdefghijklmnopqrstuvwxyz012345", string(d));
        emit log_named_uint("max-size setProfile gas", g0 - gasleft());
    }

    /// Profiles are an isolated code path: setting one never moves money.
    function test_profilesNeverTouchFunds() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        game.createGame{value: 1 ether}(300, 2, true);
        uint256 before_ = address(game).balance;
        _set(alice, "rich", "has an open table");
        _set(alice, "", "");
        assertEq(address(game).balance, before_);
    }
}
