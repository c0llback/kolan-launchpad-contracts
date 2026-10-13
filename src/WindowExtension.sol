// SPDX-License-Identifier: BUSL-1.1
/*
 *        ▄▄▄▄▄▄▄▄▄▄
 *     ▄▄████████████▄▄
 *    ▄████████████████▄
 *   ████████████████████
 *  ████████▀    ▀████████
 *  ███████        ███████
 *  ███████        ███████
 *  ███████        ███████
 *  ███████        ███████
 *  ███████  ▄██▄  ███████
 *  ███████ ██████ ███████
 *  ███████  ▀██▀  ███████
 *
 *  Kolan Launchpad
 *
 *  Website   https://kolan.c0llback.com/launchpad
 *  Twitter   https://x.com/kolan_protocol
 */
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {LaunchHook} from "./LaunchHook.sol";

/// @notice More time for an open window. It runs only inside a `LaunchHook`, which
///         delegatecalls it from `extend`: the hook is 190 bytes under the size limit
///         and this does not fit in it. One is deployed by the Launchpad and shared by
///         every hook it launches; it holds nothing and has no parameters of its own,
///         reading the window rules from the hook that called it.
/// @dev    Writes the hook's storage at the two slots below, which `forge inspect
///         LaunchHook storageLayout` gives and `Extend.t.sol` pins.
contract WindowExtension is ReentrancyGuardTransient {
    using SafeCast for uint256;

    uint256 internal constant HELD_SLOT = 4;
    uint256 internal constant WINDOWS_SLOT = 5;
    uint256 internal constant BPS = 10_000;

    event WindowExtended(uint256 indexed id, uint256 premium, uint256 expiry);

    error NoWindow();
    error NotOwner();
    error WindowExpired();
    error AlreadyLongest();
    error PremiumTooLow();
    error PremiumTooHigh();
    error PayoutFailed();
    error Insolvent();

    /// @notice Buys `id` more time at the rate it was opened at: `msg.value` is the premium
    ///         added. The window's whole length, counted from its opening, stays at most
    ///         `MAX_WINDOW`, and its whole premium at most `MAX_PREMIUM_BPS` of what it
    ///         holds. A premium that would buy past `MAX_WINDOW` buys up to it and the rest
    ///         is refunded, as when a window opens. The premium is spent when the window
    ///         closes, with the rest of it.
    function extend(uint256 id) external payable nonReentrant returns (uint256 expiry) {
        LaunchHook.Window storage w = _windows()[id];
        if (w.owner == address(0)) revert NoWindow();
        if (msg.sender != w.owner) revert NotOwner();
        expiry = w.expiry;
        if (block.timestamp >= expiry) revert WindowExpired();

        LaunchHook hook = LaunchHook(payable(address(this)));
        uint256 longest = hook.MAX_WINDOW();
        uint256 referencePremium = hook.REFERENCE_PREMIUM();
        uint256 base = hook.BASE_WINDOW();

        uint256 before = w.premium;
        uint256 was = before * base / referencePremium;
        if (was >= longest) revert AlreadyLongest();

        uint256 premium = before + msg.value;
        uint256 length = premium * base / referencePremium;
        if (length > longest) {
            length = longest;
            premium = (longest * referencePremium + base - 1) / base;
        }
        if (length == was) revert PremiumTooLow();
        if (premium * BPS > uint256(w.eth) * hook.MAX_PREMIUM_BPS()) revert PremiumTooHigh();

        uint256 kept = premium - before;
        expiry += length - was;
        w.expiry = expiry.toUint40();
        w.premium = premium.toUint64();
        LaunchHook.Held storage held = _held();
        held.eth = (held.eth + kept).toUint128();

        if (msg.value > kept) {
            (bool ok,) = msg.sender.call{value: msg.value - kept}("");
            if (!ok) revert PayoutFailed();
        }
        if (address(this).balance < held.eth) revert Insolvent();
        emit WindowExtended(id, kept, expiry);
    }

    function _windows() private pure returns (mapping(uint256 => LaunchHook.Window) storage windows) {
        assembly ("memory-safe") {
            windows.slot := WINDOWS_SLOT
        }
    }

    function _held() private pure returns (LaunchHook.Held storage held) {
        assembly ("memory-safe") {
            held.slot := HELD_SLOT
        }
    }
}
