// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {DisperseV2} from "../src/DisperseV2.sol";

interface IPermitToken is IERC20, IERC20Permit {}

/// @dev Runs only when RH_RPC_URL is set. DisperseV2 against the real tokens on Robinhood Chain (4663): USDG (Paxos,
///      6 decimals, EIP-2612 permit, can freeze an address), WEIR and IMD (18 decimals, no permit).
contract DisperseV2ForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WEIR = 0x58b82fa656ECF47a0dca5bE6BAd06B92E22f7dbE;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

    DisperseV2 internal d;
    IPermitToken internal usdg = IPermitToken(USDG);
    uint256 internal senderKey = 0xBA5E;
    address internal sender;
    DisperseV2.Permit internal noPermit;
    bytes32 internal constant REF = keccak256("fork-payout");

    event Memo(
        address indexed sender, address indexed token, bytes32 indexed ref, uint256 total, uint256 count, string memo
    );
    event Paid(
        address indexed sender, address indexed to, address indexed token, uint256 amount, bytes32 ref, string memo
    );

    function setUp() public {
        string memory url = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        assertEq(block.chainid, 4663, "RH_RPC_URL is not Robinhood Chain");
        d = new DisperseV2();
        sender = vm.addr(senderKey);
        deal(USDG, sender, 100_000e6);
        deal(WEIR, sender, 100_000e18);
        deal(IMD, sender, 1_000e18);
    }

    modifier onFork() {
        if (address(d) == address(0)) {
            vm.skip(true);
        }
        _;
    }

    function _two(string memory x, string memory y) internal pure returns (string[] memory m) {
        m = new string[](2);
        m[0] = x;
        m[1] = y;
    }

    function test_fork_usdgPermit_withMemos() public onFork {
        address[] memory to = new address[](2);
        uint256[] memory amts = new uint256[](2);
        to[0] = makeAddr("r1");
        to[1] = makeAddr("r2");
        amts[0] = 1_000e6;
        amts[1] = 1;
        uint256 total = 1_000e6 + 1;
        uint256 deadline = block.timestamp + 20 minutes;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                sender,
                address(d),
                total,
                usdg.nonces(sender),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(senderKey, keccak256(abi.encodePacked("\x19\x01", usdg.DOMAIN_SEPARATOR(), structHash)));

        vm.expectEmit(true, true, true, true, address(d));
        emit Paid(sender, to[0], USDG, 1_000e6, REF, "first");
        vm.expectEmit(true, true, true, true, address(d));
        emit Memo(sender, USDG, REF, 1_000e6 + 1, 2, "paid with one signature");
        vm.prank(sender);
        d.disperseWithMemo(
            usdg, to, amts, REF, "paid with one signature", _two("first", ""), DisperseV2.Permit(deadline, v, r, s)
        );

        assertEq(usdg.balanceOf(to[0]), 1_000e6);
        assertEq(usdg.balanceOf(to[1]), 1);
        assertEq(usdg.allowance(sender, address(d)), 0);
        assertEq(usdg.balanceOf(address(d)), 0);
    }

    function test_fork_weirAndImd_exactAmounts_inEveryEntryPoint() public onFork {
        address[] memory to = new address[](2);
        uint256[] memory amts = new uint256[](2);
        to[0] = makeAddr("w1");
        to[1] = makeAddr("w2");
        amts[0] = 5e17;
        amts[1] = 3e18;
        address[2] memory tokens = [WEIR, IMD];
        for (uint256 k; k < 2; ++k) {
            IERC20 t = IERC20(tokens[k]);
            vm.startPrank(sender);
            t.approve(address(d), 3 * 35e17);
            d.disperse(t, to, amts);
            d.disperseWithPermit(t, to, amts, 0, 0, bytes32(0), bytes32(0)); // no permit on these: allowance is the gate
            d.disperseWithMemo(t, to, amts, REF, "m", _two("x", "y"), noPermit);
            vm.stopPrank();
            assertEq(t.balanceOf(to[0]), 3 * 5e17);
            assertEq(t.balanceOf(to[1]), 3 * 3e18);
            assertEq(t.allowance(sender, address(d)), 0);
        }
    }

    function test_fork_usdgItselfAsRecipient_isRefused() public onFork {
        address[] memory to = new address[](2);
        uint256[] memory amts = new uint256[](2);
        to[0] = makeAddr("ok");
        to[1] = USDG;
        amts[0] = 1e6;
        amts[1] = 1e6;
        vm.startPrank(sender);
        usdg.approve(address(d), 2e6);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.SelfRecipient.selector, 1));
        d.disperse(usdg, to, amts);
        vm.stopPrank();
    }

    /// @dev A recipient the real USDG has frozen: the whole payout reverts and says which row.
    function test_fork_frozenUsdgRecipient_namesTheRow() public onFork {
        // USDG is AccessControl-gated: its owner holds the admin role, which may hand out the freezing role.
        (bool found, bytes memory who) = USDG.staticcall(abi.encodeWithSignature("owner()"));
        if (!found || who.length != 32) {
            emit log("USDG exposes no owner(): freezing not exercised on this fork");
            vm.skip(true);
        }
        vm.prank(abi.decode(who, (address)));
        (bool granted,) = USDG.call(
            abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("ASSET_PROTECTION_ROLE"), address(this))
        );
        address[] memory to = new address[](3);
        uint256[] memory amts = new uint256[](3);
        to[0] = makeAddr("ok1");
        to[1] = makeAddr("ok2");
        to[2] = makeAddr("frozen");
        amts[0] = 1e6;
        amts[1] = 1e6;
        amts[2] = 1e6;
        (bool froze,) = USDG.call(abi.encodeWithSignature("freeze(address)", to[2]));
        if (!granted || !froze) {
            emit log("could not freeze an address on this fork: not exercised");
            vm.skip(true);
        }
        vm.startPrank(sender);
        usdg.approve(address(d), 3e6);
        vm.expectPartialRevert(DisperseV2.TransferFailed.selector);
        d.disperse(usdg, to, amts);
        (bool ok, bytes memory ret) = address(d).call(abi.encodeCall(d.disperse, (usdg, to, amts)));
        vm.stopPrank();
        assertFalse(ok);
        // TransferFailed(uint256 index, bytes reason): the index is the first word after the selector.
        uint256 index;
        assembly {
            index := mload(add(ret, 36))
        }
        assertEq(index, 2);
        assertEq(usdg.balanceOf(to[0]), 0);
        assertEq(usdg.balanceOf(sender), 100_000e6);
    }

    /// @dev Real-token gas per fresh-balance recipient, scaled to the app's cap of 250 per transaction. A sample of
    ///      40 keeps the fork's storage reads few enough for a public (non-archive) RPC.
    function test_fork_gas_plainAndWithRowMemos() public onFork {
        uint256 n = 40;
        address[] memory to = new address[](n);
        uint256[] memory amts = new uint256[](n);
        string[] memory memos = new string[](n);
        bytes memory row = new bytes(140);
        for (uint256 i; i < 140; ++i) {
            row[i] = "x";
        }
        for (uint256 i; i < n; ++i) {
            to[i] = address(uint160(uint256(keccak256(abi.encode("plain", i)))));
            amts[i] = 1e6;
            memos[i] = string(row);
        }
        string[] memory none = new string[](0);
        vm.startPrank(sender);
        usdg.approve(address(d), 2 * n * 1e6);
        uint256 g = gasleft();
        d.disperse(usdg, to, amts);
        uint256 plain = (g - gasleft()) / n;
        for (uint256 i; i < n; ++i) {
            to[i] = address(uint160(uint256(keccak256(abi.encode("memo", i)))));
        }
        g = gasleft();
        d.disperseWithMemo(usdg, to, amts, REF, "payout", memos, noPermit);
        uint256 withMemos = (g - gasleft()) / n;
        vm.stopPrank();
        none;
        emit log_named_uint("real USDG gas per fresh recipient, no memo", plain);
        emit log_named_uint("real USDG gas per fresh recipient, 140-byte memo each", withMemos);
        assertLt(
            withMemos * 250 + 200_000, 16_000_000, "250 recipients with memos must fit in half of a 32M transaction"
        );
    }
}
