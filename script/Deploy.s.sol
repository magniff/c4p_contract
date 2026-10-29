// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Chess4Profit} from "../src/Chess4Profit.sol";

contract Deploy is Script {
    address constant PLACEHOLDER = 0x000000000000000000000000000000000000dEaD;

    function run() external returns (Chess4Profit game) {
        bool local = block.chainid == 31337 || block.chainid == 1337;

        // Safety net: never ship the placeholder fee address to a real network.
        // This instance lives only in the script's simulation (it is created before startBroadcast).
        address fee = new Chess4Profit().FEE_RECIPIENT();
        if (!local) require(fee != PLACEHOLDER, "FEE_RECIPIENT is still the placeholder; set it in Chess4Profit.sol");

        vm.startBroadcast();
        game = new Chess4Profit();
        vm.stopBroadcast();

        console.log("Chess4Profit deployed at", address(game));
        console.log("fee recipient            ", fee);
    }
}
