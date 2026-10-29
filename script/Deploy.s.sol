// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Chess4Profit} from "../src/Chess4Profit.sol";

contract Deploy is Script {
    address constant PLACEHOLDER = 0x000000000000000000000000000000000000dEaD;

    /// Chains where real money lives: the placeholder fee address is refused here unconditionally.
    function _isMainnet(uint256 id) internal pure returns (bool) {
        return id == 1 // Ethereum
            || id == 10 // Optimism
            || id == 137 // Polygon
            || id == 8453 // Base
            || id == 42161 // Arbitrum One
            || id == 42170; // Arbitrum Nova
    }

    function run() external returns (Chess4Profit game) {
        bool local = block.chainid == 31337 || block.chainid == 1337;

        // Safety net: never ship the placeholder fee address with real money at stake. On a public testnet it
        // is allowed only with an explicit opt-in (fees then go to the burn address, which is harmless there).
        // This instance lives only in the script's simulation (it is created before startBroadcast).
        address fee = new Chess4Profit().FEE_RECIPIENT();
        if (fee == PLACEHOLDER && !local) {
            require(!_isMainnet(block.chainid), "FEE_RECIPIENT is still the placeholder; set it in Chess4Profit.sol");
            require(
                vm.envOr("C4P_ALLOW_PLACEHOLDER_FEE", false),
                "placeholder FEE_RECIPIENT on a public chain: set C4P_ALLOW_PLACEHOLDER_FEE=true for a testnet"
            );
        }

        vm.startBroadcast();
        game = new Chess4Profit();
        vm.stopBroadcast();

        console.log("Chess4Profit deployed at", address(game));
        console.log("fee recipient            ", fee);
    }
}
