// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title DisperseV2
/// @notice Pays many recipients one ERC-20 in a single transaction, optionally with a public message for the whole
///         payout and one per recipient.
/// @dev Funds move straight from the caller to each recipient with `transferFrom`; the contract never holds tokens,
///      has no owner, no fee, no pause and no upgrade path, and no function is payable. Reentrancy cannot move
///      anything the caller did not already approve, so there is no guard. Fee-on-transfer and rebasing tokens are
///      not supported: recipients would receive less than `amounts[i]` and nothing here detects it.
///
///      `disperse`, `disperseWithPermit`, `sumOf` and the `Dispersed` event keep v1's exact signatures. Two things
///      differ from v1 for those callers: the token's own address is refused as a recipient, and a transfer the token
///      refuses reverts with `TransferFailed(index, reason)` instead of the token's bare reason.
///
///      Messages are copied from calldata into events and nothing else: they cannot change who is paid or how much.
///      Everything in an event is public and permanent.
contract DisperseV2 {
    error LengthMismatch();
    error Empty();
    error ZeroRecipient(uint256 index);
    /// @dev Paying this contract or the token's own address would lock the funds forever (no rescue path).
    error SelfRecipient(uint256 index);
    error ZeroAmount(uint256 index);
    error InsufficientAllowance(uint256 needed, uint256 have);
    /// @dev `memos` must be empty or have one entry per recipient.
    error MemoLengthMismatch();
    /// @dev `index` is the recipient's row, or `type(uint256).max` for the payout's own memo.
    error MemoTooLong(uint256 index);
    /// @dev The transfer for row `index` failed: the token reverted or did not answer `true`. `reason` is what the
    ///      token returned, cut to 256 bytes (so a long reason may not decode: match on its first four bytes).
    ///      Nothing moved: the whole call reverts. `index` is WHERE it failed, not WHOSE fault it is. The recipient
    ///      of that row may be refused by the token (frozen, blocked), but the same error at row 0 is also what a
    ///      frozen SENDER or a frozen spender (this contract) looks like, and a balance that runs out part-way
    ///      names the first row it could not cover. Only the first failing row is ever named.
    error TransferFailed(uint256 index, bytes reason);

    /// @notice One per call. Per-recipient detail is in the token's own `Transfer` logs.
    event Dispersed(address indexed sender, address indexed token, uint256 total, uint256 count);
    /// @notice One per `disperseWithMemo` call that carries a reference or a payout memo. `total` and `count` repeat
    ///         the `Dispersed` event of the same call, so a reference is tied to what that call sent.
    /// @dev `sender` is the direct caller. `ref` and `memo` are whatever the caller chose: anyone can emit any
    ///      reference, for any token including one they made up, by paying a dust amount. A reader should trust this
    ///      event only for a sender and a token it already knows.
    event Memo(
        address indexed sender, address indexed token, bytes32 indexed ref, uint256 total, uint256 count, string memo
    );
    /// @notice One per recipient whose own memo is not empty.
    /// @dev Anyone can address a `Paid` to anyone, with a token they made up or a dust amount of a real one. It is a
    ///      note attached to a transfer, not proof of one: the token's own `Transfer` log is.
    event Paid(
        address indexed sender, address indexed to, address indexed token, uint256 amount, bytes32 ref, string memo
    );

    /// @dev An EIP-2612 signature for exactly the sum of `amounts`. `deadline == 0` means "none: use the allowance".
    struct Permit {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    uint256 public constant MAX_MEMO_BYTES = 280;
    uint256 public constant MAX_ROW_MEMO_BYTES = 140;
    uint256 private constant PAYOUT_MEMO = type(uint256).max;
    uint256 private constant MAX_REASON_BYTES = 256;

    /// @notice Sends `amounts[i]` of `token` from the caller to `to[i]` for every i.
    /// @dev Requires a prior approval of at least the sum of `amounts`.
    function disperse(IERC20 token, address[] calldata to, uint256[] calldata amounts) external {
        uint256 total = _validate(address(token), to, amounts);
        _requireAllowance(token, total);
        _transferAll(token, to, amounts);
        emit Dispersed(msg.sender, address(token), total, to.length);
    }

    /// @notice Same as `disperse`, with an EIP-2612 permit for exactly the sum of `amounts`.
    /// @dev See `_tryPermit`: a front-run permit cannot block the send.
    function disperseWithPermit(
        IERC20 token,
        address[] calldata to,
        uint256[] calldata amounts,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        uint256 total = _validate(address(token), to, amounts);
        _tryPermit(token, total, deadline, v, r, s);
        _requireAllowance(token, total);
        _transferAll(token, to, amounts);
        emit Dispersed(msg.sender, address(token), total, to.length);
    }

    /// @notice `disperse` with messages. `ref` is the sender's own reference for the payout (zero if unused), `memo`
    ///         a message for the whole payout (may be empty), `memos` one message per recipient (empty array, or one
    ///         entry per recipient, any of which may be empty). `permit` is optional: see `Permit`.
    /// @dev Emits `Dispersed` always, `Memo` when `ref` is non-zero or `memo` non-empty, and `Paid` for each
    ///      recipient with a non-empty memo.
    function disperseWithMemo(
        IERC20 token,
        address[] calldata to,
        uint256[] calldata amounts,
        bytes32 ref,
        string calldata memo,
        string[] calldata memos,
        Permit calldata permit
    ) external {
        uint256 total = _validate(address(token), to, amounts);
        _validateMemos(to.length, memo, memos);
        if (permit.deadline != 0) _tryPermit(token, total, permit.deadline, permit.v, permit.r, permit.s);
        _requireAllowance(token, total);
        if (memos.length == 0) _transferAll(token, to, amounts);
        else _transferAllWithMemos(token, to, amounts, ref, memos);
        emit Dispersed(msg.sender, address(token), total, to.length);
        if (ref != bytes32(0) || bytes(memo).length != 0) {
            emit Memo(msg.sender, address(token), ref, total, to.length, memo);
        }
    }

    /// @notice Sum of `amounts`, after the checks every send applies that do not depend on the token. Reverts on
    ///         invalid input. (v1's signature has no token, so "recipient is the token" is not checked here.)
    function sumOf(address[] calldata to, uint256[] calldata amounts) external view returns (uint256) {
        return _validate(address(0), to, amounts);
    }

    /// @dev `token` is only compared with recipients. With `address(0)` (sumOf) the comparison can never match,
    ///      because a zero recipient is refused first.
    function _validate(address token, address[] calldata to, uint256[] calldata amounts)
        private
        view
        returns (uint256 sum)
    {
        uint256 n = to.length;
        if (n == 0) revert Empty();
        if (n != amounts.length) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            address recipient = to[i];
            if (recipient == address(0)) revert ZeroRecipient(i);
            if (recipient == address(this) || recipient == token) revert SelfRecipient(i);
            if (amounts[i] == 0) revert ZeroAmount(i);
            sum += amounts[i];
        }
    }

    function _validateMemos(uint256 n, string calldata memo, string[] calldata memos) private pure {
        if (bytes(memo).length > MAX_MEMO_BYTES) revert MemoTooLong(PAYOUT_MEMO);
        uint256 m = memos.length;
        if (m == 0) return;
        if (m != n) revert MemoLengthMismatch();
        for (uint256 i; i < m; ++i) {
            if (bytes(memos[i]).length > MAX_ROW_MEMO_BYTES) revert MemoTooLong(i);
        }
    }

    /// @dev The permit owner is always the caller. The call is wrapped so a front-run permit (someone replaying the
    ///      signature first) cannot block the send: if `permit` reverts but the allowance is already sufficient, the
    ///      send proceeds. If the allowance is short, the permit's own revert reason is bubbled up so an expired
    ///      deadline, wrong domain or bad signature is reported as such instead of as a bare allowance shortfall.
    function _tryPermit(IERC20 token, uint256 total, uint256 deadline, uint8 v, bytes32 r, bytes32 s) private {
        try IERC20Permit(address(token)).permit(msg.sender, address(this), total, deadline, v, r, s) {}
        catch (bytes memory reason) {
            if (token.allowance(msg.sender, address(this)) < total) {
                if (reason.length == 0) {
                    revert InsufficientAllowance(total, token.allowance(msg.sender, address(this)));
                }
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }

    function _requireAllowance(IERC20 token, uint256 needed) private view {
        uint256 have = token.allowance(msg.sender, address(this));
        if (have < needed) revert InsufficientAllowance(needed, have);
    }

    function _transferAll(IERC20 token, address[] calldata to, uint256[] calldata amounts) private {
        uint256 n = to.length;
        for (uint256 i; i < n; ++i) {
            _pull(token, to[i], amounts[i], i);
        }
    }

    function _transferAllWithMemos(
        IERC20 token,
        address[] calldata to,
        uint256[] calldata amounts,
        bytes32 ref,
        string[] calldata memos
    ) private {
        uint256 n = to.length;
        for (uint256 i; i < n; ++i) {
            _pull(token, to[i], amounts[i], i);
            if (bytes(memos[i]).length != 0) emit Paid(msg.sender, to[i], address(token), amounts[i], ref, memos[i]);
        }
    }

    /// @dev `token.transferFrom(msg.sender, recipient, amount)`, accepted when the call succeeds and either returns
    ///      nothing from an address that has code, or returns at least 32 bytes whose first word is exactly 1. That
    ///      is SafeERC20's rule, and never looser: an answer of 1 to 31 bytes is always refused here. A refusal
    ///      reverts with the row it happened on. This function copies at most 32 bytes of the answer on success and
    ///      256 on failure, so a token cannot make the caller pay to copy a huge answer to a transfer. (The permit
    ///      call in `_tryPermit` has no such cap: a token chosen by the caller can make its own permit expensive.)
    ///      A token address with no code never gets this far: its `allowance` call reverts first.
    function _pull(IERC20 token, address recipient, uint256 amount, uint256 index) private {
        bytes memory data = abi.encodeCall(IERC20.transferFrom, (msg.sender, recipient, amount));
        bool ok;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            // The first return word lands in scratch space (0x00..0x1f).
            ok := call(gas(), token, 0, add(data, 0x20), mload(data), 0x00, 0x20)
            size := returndatasize()
            word := mload(0x00)
        }
        if (ok && (size == 0 ? address(token).code.length != 0 : (size >= 32 && word == 1))) return;

        bytes memory reason;
        assembly ("memory-safe") {
            let len := returndatasize()
            if gt(len, MAX_REASON_BYTES) { len := MAX_REASON_BYTES }
            reason := mload(0x40)
            mstore(reason, len)
            returndatacopy(add(reason, 0x20), 0, len)
            mstore(0x40, add(add(reason, 0x20), and(add(len, 0x1f), not(0x1f))))
        }
        revert TransferFailed(index, reason);
    }
}
