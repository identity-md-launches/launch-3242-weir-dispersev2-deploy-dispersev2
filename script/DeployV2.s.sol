// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DisperseV2} from "../src/DisperseV2.sol";

/// @dev Deterministic deploy of DisperseV2 through the CREATE2 proxy at 0x4e59b44847b379578588920cA78FbF26c0B4956C
///      (forge uses it automatically when a salt is given). Same salt + same bytecode = same address on every chain.
///      This is the owner's route to the same address on another chain; the IMD swarm deploys from launch.json and
///      lands at its own deployer's address instead.
contract DeployV2 is Script {
    bytes32 public constant SALT = keccak256("weir.disperse.v2");
    /// @dev Pinned so a silent bytecode drift (solc patch, optimizer setting, code change) fails loudly instead of
    ///      landing at a different address. Update it, the README and the app when the source changes on purpose.
    address public constant EXPECTED = 0x32133119DBb4e4C9Ba1b8cEDe3CA49C726F20983;

    function run() external {
        require(predict() == EXPECTED, "bytecode drift: predicted address != EXPECTED");
        if (EXPECTED.code.length != 0) {
            console.log("DisperseV2 already deployed at", EXPECTED);
            return;
        }
        vm.startBroadcast();
        DisperseV2 d = new DisperseV2{salt: SALT}();
        vm.stopBroadcast();
        require(address(d) == EXPECTED, "deployed address != EXPECTED");
        console.log("DisperseV2 deployed at", address(d));
    }

    function predict() public pure returns (address) {
        return vm.computeCreate2Address(SALT, keccak256(type(DisperseV2).creationCode));
    }
}
