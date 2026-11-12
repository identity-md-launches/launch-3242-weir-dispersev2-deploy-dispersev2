// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Disperse} from "../src/Disperse.sol";
import {DisperseV2} from "../src/DisperseV2.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {PlainToken} from "./mocks/PlainToken.sol";
import {NoReturnToken} from "./mocks/NoReturnToken.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

/// @dev v1's own suite run against DisperseV2: the three kept functions must behave as before. Differences from
///      Disperse.t.sol are marked "v2:" and are exactly the two the contract documents (token as recipient, and a
///      refused transfer reverting with its row).
contract DisperseV2CompatTest is Test {
    DisperseV2 internal d;
    MockUSDC internal usdc;

    uint256 internal senderKey = 0xA11CE;
    address internal sender;
    address internal a = makeAddr("a");
    address internal b = makeAddr("b");
    address internal c = makeAddr("c");

    event Dispersed(address indexed sender, address indexed token, uint256 total, uint256 count);

    function setUp() public {
        d = new DisperseV2();
        usdc = new MockUSDC();
        sender = vm.addr(senderKey);
        usdc.mint(sender, 1_000_000e6);
    }

    function _three() internal view returns (address[] memory to, uint256[] memory amts) {
        to = new address[](3);
        amts = new uint256[](3);
        to[0] = a;
        to[1] = b;
        to[2] = c;
        amts[0] = 100e6;
        amts[1] = 250e6;
        amts[2] = 1;
    }

    // ---- disperse ------------------------------------------------------------------------------

    function test_disperse_happy() public {
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        usdc.approve(address(d), 350e6 + 1);
        vm.expectEmit(true, true, false, true, address(d));
        emit Dispersed(sender, address(usdc), 350e6 + 1, 3);
        d.disperse(usdc, to, amts);
        vm.stopPrank();

        assertEq(usdc.balanceOf(a), 100e6);
        assertEq(usdc.balanceOf(b), 250e6);
        assertEq(usdc.balanceOf(c), 1);
        assertEq(usdc.balanceOf(sender), 1_000_000e6 - 350e6 - 1);
        assertEq(usdc.allowance(sender, address(d)), 0);
        assertEq(usdc.balanceOf(address(d)), 0, "contract must hold nothing");
    }

    function test_disperse_duplicateRecipientSums() public {
        address[] memory to = new address[](2);
        uint256[] memory amts = new uint256[](2);
        to[0] = a;
        to[1] = a;
        amts[0] = 5e6;
        amts[1] = 7e6;
        vm.startPrank(sender);
        usdc.approve(address(d), 12e6);
        d.disperse(usdc, to, amts);
        vm.stopPrank();
        assertEq(usdc.balanceOf(a), 12e6);
    }

    function test_disperse_revert_empty() public {
        address[] memory to;
        uint256[] memory amts;
        vm.prank(sender);
        vm.expectRevert(DisperseV2.Empty.selector);
        d.disperse(usdc, to, amts);
    }

    function test_disperse_revert_lengthMismatch() public {
        address[] memory to = new address[](2);
        uint256[] memory amts = new uint256[](1);
        to[0] = a;
        to[1] = b;
        amts[0] = 1;
        vm.prank(sender);
        vm.expectRevert(DisperseV2.LengthMismatch.selector);
        d.disperse(usdc, to, amts);
    }

    function test_disperse_revert_zeroRecipient() public {
        (address[] memory to, uint256[] memory amts) = _three();
        to[1] = address(0);
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.ZeroRecipient.selector, 1));
        d.disperse(usdc, to, amts);
    }

    function test_disperse_revert_zeroAmount() public {
        (address[] memory to, uint256[] memory amts) = _three();
        amts[2] = 0;
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.ZeroAmount.selector, 2));
        d.disperse(usdc, to, amts);
    }

    function test_disperse_revert_insufficientAllowance() public {
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        usdc.approve(address(d), 350e6); // one short
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.InsufficientAllowance.selector, 350e6 + 1, 350e6));
        d.disperse(usdc, to, amts);
        vm.stopPrank();
    }

    function test_disperse_revert_insufficientBalance() public {
        address poor = makeAddr("poor");
        usdc.mint(poor, 10e6);
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(poor);
        usdc.approve(address(d), type(uint256).max);
        // v2: the token's refusal arrives wrapped, with the row it happened on.
        vm.expectRevert(
            abi.encodeWithSelector(
                DisperseV2.TransferFailed.selector,
                0,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 10e6, 100e6)
            )
        );
        d.disperse(usdc, to, amts);
        vm.stopPrank();
    }

    function test_disperse_revert_sumOverflow() public {
        address[] memory to = new address[](2);
        uint256[] memory amts = new uint256[](2);
        to[0] = a;
        to[1] = b;
        amts[0] = type(uint256).max;
        amts[1] = 1;
        vm.prank(sender);
        vm.expectRevert(stdError.arithmeticError);
        d.disperse(usdc, to, amts);
    }

    function test_sumOf() public view {
        (address[] memory to, uint256[] memory amts) = _three();
        assertEq(d.sumOf(to, amts), 350e6 + 1);
    }

    function testFuzz_disperse_conserves(uint96[8] calldata raw) public {
        address[] memory to = new address[](8);
        uint256[] memory amts = new uint256[](8);
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            to[i] = address(uint160(0x1000 + i));
            amts[i] = uint256(raw[i]) + 1;
            sum += amts[i];
        }
        usdc.mint(sender, sum);
        uint256 before = usdc.balanceOf(sender);
        vm.startPrank(sender);
        usdc.approve(address(d), sum);
        d.disperse(usdc, to, amts);
        vm.stopPrank();
        assertEq(before - usdc.balanceOf(sender), sum);
        for (uint256 i; i < 8; ++i) {
            assertEq(usdc.balanceOf(to[i]), amts[i]);
        }
    }

    // ---- token variants ------------------------------------------------------------------------

    function test_disperse_noReturnToken() public {
        NoReturnToken t = new NoReturnToken();
        t.mint(sender, 100e6);
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        t.approve(address(d), 350e6 + 1);
        // v2: the token's refusal arrives wrapped, with the row it happened on.
        vm.expectRevert(
            abi.encodeWithSelector(
                DisperseV2.TransferFailed.selector, 1, abi.encodeWithSignature("Error(string)", "balance")
            )
        );
        d.disperse(IERC20(address(t)), to, amts);
        t.mint(sender, 300e6);
        d.disperse(IERC20(address(t)), to, amts);
        vm.stopPrank();
        assertEq(t.balanceOf(b), 250e6);
    }

    function test_disperse_reentrantTokenCannotAmplify() public {
        ReentrantToken t = new ReentrantToken();
        t.mint(sender, 1_000e6);
        (address[] memory to, uint256[] memory amts) = _three();
        t.arm(Disperse(address(d)), to, amts);
        vm.startPrank(sender);
        t.approve(address(d), 350e6 + 1);
        // The re-entrant call is made by the token contract, which has approved nothing; it is swallowed
        // inside the token, so the outer send completes and moves exactly what the sender approved.
        d.disperse(IERC20(address(t)), to, amts);
        vm.stopPrank();
        assertEq(t.reentered(), 1, "token re-entered once");
        assertEq(t.balanceOf(a), 100e6);
        assertEq(t.balanceOf(b), 250e6);
        assertEq(t.balanceOf(c), 1);
        assertEq(t.balanceOf(sender), 1_000e6 - 350e6 - 1);
        assertEq(t.balanceOf(address(d)), 0);
        assertEq(t.balanceOf(address(t)), 0);
    }

    function test_disperse_revert_selfRecipient() public {
        (address[] memory to, uint256[] memory amts) = _three();
        to[2] = address(d);
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.SelfRecipient.selector, 2));
        d.disperse(usdc, to, amts);
    }

    function test_disperse_revert_noCodeToken() public {
        (address[] memory to, uint256[] memory amts) = _three();
        // A call to an address without code reverts with empty data in both paths.
        vm.prank(sender);
        vm.expectRevert(bytes(""));
        d.disperse(IERC20(address(0xdead)), to, amts);
        vm.prank(sender);
        vm.expectRevert(bytes(""));
        d.disperseWithPermit(IERC20(address(0xdead)), to, amts, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev v2: the token's own address is refused as a recipient (v1 paid it, and the money was stuck).
    function test_disperse_revert_tokenAsRecipient() public {
        (address[] memory to, uint256[] memory amts) = _three();
        to[1] = address(usdc);
        vm.startPrank(sender);
        usdc.approve(address(d), amts[0] + amts[1] + amts[2]);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.SelfRecipient.selector, 1));
        d.disperse(usdc, to, amts);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(usdc)), 0);
    }

    function testFuzz_disperse_lengths(uint8 nRaw, uint64 each) public {
        uint256 n = bound(uint256(nRaw), 1, 250);
        uint256 amt = uint256(each) + 1;
        address[] memory to = new address[](n);
        uint256[] memory amts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            to[i] = address(uint160(uint256(keccak256(abi.encode("r", i)))));
            amts[i] = amt;
        }
        usdc.mint(sender, n * amt);
        uint256 before = usdc.balanceOf(sender);
        vm.startPrank(sender);
        usdc.approve(address(d), n * amt);
        d.disperse(usdc, to, amts);
        vm.stopPrank();
        assertEq(before - usdc.balanceOf(sender), n * amt);
        for (uint256 i; i < n; ++i) {
            assertEq(usdc.balanceOf(to[i]), amt);
        }
    }

    // ---- permit --------------------------------------------------------------------------------

    function _permitSig(uint256 value, uint256 deadline, uint256 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                sender,
                address(d),
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(senderKey, digest);
    }

    function test_permit_happy() public {
        (address[] memory to, uint256[] memory amts) = _three();
        uint256 total = 350e6 + 1;
        uint256 deadline = block.timestamp + 20 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(total, deadline, usdc.nonces(sender));
        vm.prank(sender);
        d.disperseWithPermit(usdc, to, amts, deadline, v, r, s);
        assertEq(usdc.balanceOf(a), 100e6);
        assertEq(usdc.balanceOf(b), 250e6);
        assertEq(usdc.balanceOf(c), 1);
        assertEq(usdc.allowance(sender, address(d)), 0);
        assertEq(usdc.nonces(sender), 1);
    }

    function test_permit_frontRunStillSucceeds() public {
        (address[] memory to, uint256[] memory amts) = _three();
        uint256 total = 350e6 + 1;
        uint256 deadline = block.timestamp + 20 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(total, deadline, usdc.nonces(sender));

        // Griefer replays the permit first; nonce is consumed, allowance set.
        vm.prank(makeAddr("griefer"));
        usdc.permit(sender, address(d), total, deadline, v, r, s);
        assertEq(usdc.allowance(sender, address(d)), total);

        // Our call's inner permit reverts (nonce used) but the allowance is there.
        vm.prank(sender);
        d.disperseWithPermit(usdc, to, amts, deadline, v, r, s);
        assertEq(usdc.balanceOf(b), 250e6);
    }

    function test_permit_revert_expired_bubblesReason() public {
        (address[] memory to, uint256[] memory amts) = _three();
        uint256 total = 350e6 + 1;
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(total, deadline, usdc.nonces(sender));
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        d.disperseWithPermit(usdc, to, amts, deadline, v, r, s);
    }

    function test_permit_revert_wrongValue_bubblesSignerError() public {
        (address[] memory to, uint256[] memory amts) = _three();
        uint256 deadline = block.timestamp + 20 minutes;
        // signed for less than the sum: recovers a different signer, so the token reports an invalid signer
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(350e6, deadline, usdc.nonces(sender));
        vm.prank(sender);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        d.disperseWithPermit(usdc, to, amts, deadline, v, r, s);
        assertEq(usdc.allowance(sender, address(d)), 0);
    }

    function test_permit_revert_wrongSigner_bubblesSignerError() public {
        (address[] memory to, uint256[] memory amts) = _three();
        uint256 total = 350e6 + 1;
        uint256 deadline = block.timestamp + 20 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(total, deadline, usdc.nonces(sender));
        address other = makeAddr("other");
        usdc.mint(other, total);
        vm.prank(other);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        d.disperseWithPermit(usdc, to, amts, deadline, v, r, s);
    }

    function test_permit_tokenWithoutPermit_fallsBackToAllowance() public {
        PlainToken t = new PlainToken();
        t.mint(sender, 1_000e6);
        (address[] memory to, uint256[] memory amts) = _three();
        uint256 total = 350e6 + 1;
        vm.startPrank(sender);
        // no approval: permit call reverts (no such function), allowance check fails
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.InsufficientAllowance.selector, total, 0));
        d.disperseWithPermit(IERC20(address(t)), to, amts, 0, 0, bytes32(0), bytes32(0));
        // with approval: garbage permit args are ignored and the send goes through
        t.approve(address(d), total);
        d.disperseWithPermit(IERC20(address(t)), to, amts, 0, 0, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertEq(t.balanceOf(b), 250e6);
    }

    function test_permit_existingAllowanceIgnoresPermit() public {
        (address[] memory to, uint256[] memory amts) = _three();
        uint256 total = 350e6 + 1;
        vm.startPrank(sender);
        usdc.approve(address(d), total);
        d.disperseWithPermit(usdc, to, amts, 0, 0, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertEq(usdc.balanceOf(b), 250e6);
        assertEq(usdc.nonces(sender), 0);
    }

    // ---- deploy ---------------------------------------------------------------------------------

    function test_gas_250recipients() public {
        uint256 n = 250;
        address[] memory to = new address[](n);
        uint256[] memory amts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            to[i] = address(uint160(0x2000 + i));
            amts[i] = 1e6;
        }
        vm.startPrank(sender);
        usdc.approve(address(d), n * 1e6);
        uint256 g = gasleft();
        d.disperse(usdc, to, amts);
        g -= gasleft();
        vm.stopPrank();
        emit log_named_uint("gas for 250 recipients (fresh balances)", g);
        // Sized against the tightest chain this bytecode runs on (Base: 16,777,216 per transaction, EIP-7825).
        // Keep 2x headroom on the mock; the fork suite measures the real tokens on Robinhood Chain.
        assertLt(g, 16_777_216 / 2, "must leave 2x headroom under a 16,777,216 per-tx gas cap");
    }
}
