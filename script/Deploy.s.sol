// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BCA} from "../src/BCA.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        BCA bca = new BCA(
            deployer,
            5e17,
            15e16,
            7e17
        );

        console.log("BCA deployed at:", address(bca));
        console.log("Brasil supply (tokens):", bca.balanceOf(deployer) / 1e18);

        vm.stopBroadcast();
    }
}
