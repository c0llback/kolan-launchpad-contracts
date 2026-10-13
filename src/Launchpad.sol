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

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {LaunchHook} from "./LaunchHook.sol";
import {WindowExtension} from "./WindowExtension.sol";

contract Launchpad {
    using CurrencyLibrary for Currency;

    struct Config {
        IPoolManager manager;
        address treasury;
        PoolKey kln;
        uint256[] supplies;
        int24[] openTicks;
        uint256 taxBps;
        uint256 referencePremium;
        uint256 baseWindow;
        uint256 minWindow;
        uint256 maxWindow;
        uint256 maxPremiumBps;
    }

    uint256 public constant MAX_NAME = 32;
    uint256 public constant MAX_SYMBOL = 12;
    uint256 public constant MAX_URI = 16_384;
    uint256 public constant MAX_SUPPLIES = 8;
    uint256 internal constant CHUNK = 24_000;
    int24 internal constant TICK_SPACING = 10;

    IPoolManager public immutable POOL_MANAGER;
    address public immutable TREASURY;
    address public immutable KLN;
    uint24 internal immutable KLN_FEE;
    int24 internal immutable KLN_TICK_SPACING;
    address public immutable KLN_HOOK;
    uint256 public immutable TAX_BPS;
    uint256 public immutable REFERENCE_PREMIUM;
    uint256 public immutable BASE_WINDOW;
    uint256 public immutable MIN_WINDOW;
    uint256 public immutable MAX_WINDOW;
    uint256 public immutable MAX_PREMIUM_BPS;
    address internal immutable CODE_A;
    address internal immutable CODE_B;
    address public immutable WINDOW_EXTENSION;

    uint256[] internal _supplies;
    mapping(uint256 supply => int24 tick) public openTickOf;
    LaunchHook[] internal _hooks;
    mapping(address token => LaunchHook) public hookOf;
    mapping(address hook => uint256 blockNumber) public launchedAt;
    mapping(address hook => uint256 supply) public supplyOf;

    event Launched(
        address indexed token,
        address indexed hook,
        address indexed creator,
        string name,
        string symbol,
        string uri,
        uint256 bought
    );

    error BadConfig();
    error BadText();
    error BadSalt();
    error BadSupply();

    constructor(Config memory c) {
        if (address(c.manager) == address(0) || c.treasury == address(0)) revert BadConfig();
        if (!c.kln.currency0.isAddressZero() || Currency.unwrap(c.kln.currency1) == address(0)) {
            revert BadConfig();
        }
        if (c.taxBps > 500) revert BadConfig();
        uint256 count = c.supplies.length;
        if (count == 0 || count > MAX_SUPPLIES || c.openTicks.length != count) revert BadConfig();
        int24 lowest = TickMath.MIN_TICK - (TickMath.MIN_TICK % TICK_SPACING);
        int24 highest = TickMath.MAX_TICK - (TickMath.MAX_TICK % TICK_SPACING);
        for (uint256 i = 0; i < count; ++i) {
            uint256 supply = c.supplies[i];
            int24 tick = c.openTicks[i];
            if (supply == 0 || supply > type(uint96).max || openTickOf[supply] != 0) revert BadConfig();
            if (tick == 0 || tick <= lowest || tick > highest || tick % TICK_SPACING != 0) {
                revert BadConfig();
            }
            openTickOf[supply] = tick;
            _supplies.push(supply);
        }
        if (c.referencePremium == 0 || c.baseWindow == 0 || c.minWindow == 0) revert BadConfig();
        if (c.minWindow > c.maxWindow || c.maxWindow > type(uint32).max) revert BadConfig();
        if (c.maxPremiumBps == 0 || c.maxPremiumBps > 10_000) revert BadConfig();
        if (c.maxWindow * c.referencePremium / c.baseWindow >= type(uint64).max) revert BadConfig();

        POOL_MANAGER = c.manager;
        TREASURY = c.treasury;
        KLN = Currency.unwrap(c.kln.currency1);
        KLN_FEE = c.kln.fee;
        KLN_TICK_SPACING = c.kln.tickSpacing;
        KLN_HOOK = address(c.kln.hooks);
        TAX_BPS = c.taxBps;
        REFERENCE_PREMIUM = c.referencePremium;
        BASE_WINDOW = c.baseWindow;
        MIN_WINDOW = c.minWindow;
        MAX_WINDOW = c.maxWindow;
        MAX_PREMIUM_BPS = c.maxPremiumBps;

        WINDOW_EXTENSION = address(new WindowExtension());

        bytes memory code = type(LaunchHook).creationCode;
        CODE_A = _store(_slice(code, 0, CHUNK));
        CODE_B = _store(_slice(code, CHUNK, code.length));
    }

    function launch(
        string calldata name,
        string calldata symbol,
        uint256 supply,
        string calldata uri,
        uint256 buyEth,
        bytes32 salt
    ) external payable returns (address token, address hook, uint256 bought) {
        uint256 n = bytes(name).length;
        uint256 s = bytes(symbol).length;
        if (n == 0 || n > MAX_NAME || s == 0 || s > MAX_SYMBOL || bytes(uri).length > MAX_URI) {
            revert BadText();
        }

        bytes memory init = initCode(name, symbol, supply, msg.sender);
        assembly ("memory-safe") {
            hook := create2(0, add(init, 0x20), mload(init), salt)
        }
        if (hook == address(0)) revert BadSalt();

        LaunchHook h = LaunchHook(payable(hook));
        token = address(h.TOKEN());
        _hooks.push(h);
        hookOf[token] = h;
        launchedAt[hook] = block.number;
        supplyOf[hook] = supply;
        bought = h.launch{value: msg.value}(openTickOf[supply], buyEth, msg.sender);
        emit Launched(token, hook, msg.sender, name, symbol, uri, bought);
    }

    function claimTreasury(address[] calldata hooks) external returns (uint256 paid) {
        for (uint256 i = 0; i < hooks.length; ++i) {
            LaunchHook h = LaunchHook(payable(hooks[i]));
            if (h.treasuryOwed() == 0) continue;
            paid += h.claimTreasury();
        }
    }

    function initCode(string calldata name, string calldata symbol, uint256 supply, address creator)
        public
        view
        returns (bytes memory)
    {
        if (openTickOf[supply] == 0) revert BadSupply();
        LaunchHook.Config memory c = LaunchHook.Config({
            manager: POOL_MANAGER,
            launcher: address(this),
            dev: creator,
            treasury: TREASURY,
            name: name,
            symbol: symbol,
            supply: supply,
            taxBps: TAX_BPS,
            referencePremium: REFERENCE_PREMIUM,
            baseWindow: BASE_WINDOW,
            minWindow: MIN_WINDOW,
            maxWindow: MAX_WINDOW,
            maxPremiumBps: MAX_PREMIUM_BPS,
            kln: kln(),
            extension: WINDOW_EXTENSION
        });
        return bytes.concat(_read(CODE_A), _read(CODE_B), abi.encode(c));
    }

    function initCodeHash(string calldata name, string calldata symbol, uint256 supply, address creator)
        external
        view
        returns (bytes32)
    {
        return keccak256(initCode(name, symbol, supply, creator));
    }

    function supplies() external view returns (uint256[] memory) {
        return _supplies;
    }

    function kln() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(KLN),
            fee: KLN_FEE,
            tickSpacing: KLN_TICK_SPACING,
            hooks: IHooks(KLN_HOOK)
        });
    }

    function launchCount() external view returns (uint256) {
        return _hooks.length;
    }

    function hookAt(uint256 i) external view returns (LaunchHook) {
        return _hooks[i];
    }

    function hooksBetween(uint256 from, uint256 to) external view returns (address[] memory hooks) {
        if (to > _hooks.length) to = _hooks.length;
        if (from >= to) return hooks;
        hooks = new address[](to - from);
        for (uint256 i = from; i < to; ++i) {
            hooks[i - from] = address(_hooks[i]);
        }
    }

    function _slice(bytes memory data, uint256 from, uint256 to) private pure returns (bytes memory out) {
        out = new bytes(to - from);
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(data, 0x20), from), sub(to, from))
        }
    }

    function _store(bytes memory data) private returns (address pointer) {
        bytes memory init = abi.encodePacked(hex"600B5981380380925939F3", hex"00", data);
        assembly ("memory-safe") {
            pointer := create(0, add(init, 0x20), mload(init))
        }
        if (pointer == address(0)) revert BadConfig();
    }

    function _read(address pointer) private view returns (bytes memory data) {
        uint256 size = pointer.code.length - 1;
        data = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), 1, size)
        }
    }
}
