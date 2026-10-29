// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Chess4Profit} from "../src/Chess4Profit.sol";

/// Gas yardstick: four Stockfish games replayed through the real contract (two end in mate, two stop where python-chess
/// first sees a repetition claim).
/// `forge test --mc GasBench -vv` prints per-game totals; the assert only guards against regressions. Numbers are
/// in-test gas, not receipts: no 21k base cost, and storage touched by earlier moves stays warm.
contract GasBenchTest is Test {
    Chess4Profit game;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // each move is 2 bytes, big-endian: from | to << 6 | promotion << 12
    bytes[4] games = [
        bytes(hex"05cf0871070c0c7a0845073105460b3406cb0ab204e104dc04c308f3068a0afd089a0cab06490cf901840e7802c20d3e06080fbc03130f3d04010bb40a0c092c0aa807240850077208ea055c074b076e0563031d03c60b7300c508fb04000d3c05100534050d0563054e0a300ae1048c00830212068206480aa208d90caa0ca30c9a08ed0ab205230a2a09f708180279058f09b6075507a6079707a70aa8038907d603ce099f059e0eaa0dfe0f2b0bcf0b7c0b6f0b66039600ba01540882058500a201560882058500a2"),
        bytes(hex"05460ab906cb08f3050c07ba08450b3401840cfb05cf055e05430a30062109f7031508710458082a048a097502910b7e054d0d7c02c107e7010506a0068b06a1071409ed08dc08f3044905a702cc0f3800ca0828004009b6069106a304430a1a028b0b7505020bad03540dbd04080d3c06110ebf08410b7608a10e7a04580ae80691092c08db072402ca055c04da0134010b03160304031503130dae014c076b0aa20279010d092d02c403dd0346074f018d02dd01c60049018702410caa0fb60eb20dfe0cba0bf70305010b014c034401c60ca4058e014d"),
        bytes(hex"050c0871048a0a3a060806210a050a3906cb0b7e03060ab206030e68058c0af307cf0b3408180d3d09df0cf90ee00efc0be70bf6080008aa02c10fbf0bc70cbb03040bbe05ef06e2070b049b0220072d071607ae049c07de05570b7502c209df0008083006490c72081909a702120e780a200a3105d50f7306480a68071408a6078e0c790e00092206380724014c06dc0e1808a9049708620292069b024a0c9a08d908a10c490c720d230cfd0eb8086200ba093300420a210c410c68074b0a7103850ca9058e0ce405560933059504e4051d0ef20fb40bf70b7e0d3b09ed08eb054d0d740755025305560bb506d404c90a5b01130315028401a9040a05a7092c054c0690095d0b6e0c0609ad053007e60bd40ada00af0c6b050206e302d40831080b05df02e003d7064b0724071605cf0b6507d7011905df0d6d04db058402d3035c"),
        bytes(hex"050c0ab2068a0b3404810b7e071408f3091c06e30b64049b0dad0dbd0489092c02830cf9030608b3058c0b2204c5076c07130b3a089a09750956096c095c039d01440b7b07250fbc04cb07ce00400d7d01870b2d044a05ec03050f7804080b9f058603d705020ffe0d51076e02cc0d7d01c101cf01dc08dd028b0b7605d60fbf0bd40dad059707630610083007070f7e0d960db5095c0fbd0daf0dbe06d306e406d208dd044a0d230ce509f7049108f404d207e703130f7607b30d3d055e0b74079508710a620a63055e08e903950763014c039d0385096d03ce0b6501cf09ad0387096605ce09a503d707a6038f")
    ];

    function setUp() public {
        game = new Chess4Profit();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _play(bytes memory moves) internal returns (uint256 total, uint256 worst, uint256 last, uint256 plies) {
        vm.prank(alice);
        uint256 id = game.createGame{value: 0.01 ether}(300, 2, true);
        vm.prank(bob);
        game.joinGame{value: 0.01 ether}(id);
        for (uint256 i; i + 1 < moves.length; i += 2) {
            uint16 m = uint16(uint8(moves[i])) << 8 | uint16(uint8(moves[i + 1]));
            vm.prank(i % 4 == 0 ? alice : bob);
            uint256 g0 = gasleft();
            game.makeMove(id, m);
            last = g0 - gasleft();
            total += last;
            if (last > worst) worst = last;
            ++plies;
            if (game.getGame(id).status != Chess4Profit.Status.Active) break;
        }
    }

    function test_gasBench() public {
        uint256 sum;
        uint256 n;
        for (uint256 i; i < games.length; ++i) {
            (uint256 total, uint256 worst, uint256 last, uint256 plies) = _play(games[i]);
            emit log_named_uint("plies", plies);
            emit log_named_uint("  avg gas / move", total / plies);
            emit log_named_uint("  worst move", worst);
            emit log_named_uint("  final move", last);
            sum += total;
            n += plies;
        }
        emit log_named_uint("AVERAGE gas / move (all games)", sum / n);
        // in-test gas (one transaction, so storage stays warm): ~102k now, ~211k before the pass-6 optimisation
        assertLt(sum / n, 115_000);
    }
}
