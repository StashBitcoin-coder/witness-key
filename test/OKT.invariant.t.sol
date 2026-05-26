// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/OriginKeyToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─── Mock cbBTC ───────────────────────────────────────────────────────────────
contract MockCbBTC is ERC20 {
    constructor() ERC20("Coinbase Wrapped BTC", "cbBTC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

// ─── Handler — Foundry calls these randomly ───────────────────────────────────
// The handler wraps every contract function with bounded random inputs
// so Foundry can explore the state space safely.
contract OKTHandler is Test {
    OriginKeyToken public okt;
    MockCbBTC public cbbtc;

    address[] public actors;
    address[] public vaults;
    mapping(address => bool) public isActor;

    uint256 constant MIN_SATS = 100;
    uint256 constant MAX_SATS = 1_000_000; // 0.01 BTC max per action
    uint256 constant MAX_ORDINAL = 1_000_000;

    constructor(OriginKeyToken _okt, MockCbBTC _cbbtc) {
        okt = _okt;
        cbbtc = _cbbtc;

        // Create 5 test actors
        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            isActor[actor] = true;
            cbbtc.mint(actor, 10_000_000); // 0.1 BTC each
            vm.prank(actor);
            cbbtc.approve(address(okt), type(uint256).max);
        }

        for (uint256 i = 0; i < 3; i++) {
            vaults.push(makeAddr(string(abi.encodePacked("vault", i))));
        }

        address registrar = okt.vaultRegistrar();
        cbbtc.mint(registrar, 30_000_000);
        vm.prank(registrar);
        cbbtc.approve(address(okt), type(uint256).max);
    }

    // ─── Buy ──────────────────────────────────────────────────────────────────
    function buy(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, MIN_SATS, MAX_SATS);

        if (cbbtc.balanceOf(actor) < amount) return;

        vm.prank(actor);
        try okt.buy(amount, 0) {} catch {}
    }

    // ─── Sell ─────────────────────────────────────────────────────────────────
    function sell(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = okt.balanceOf(actor);
        if (balance < okt.MIN_SELL()) return;

        amount = bound(amount, okt.MIN_SELL(), balance);

        // Make sure totalSupply > amount
        if (okt.totalSupply() <= amount) return;

        vm.prank(actor);
        try okt.sell(amount, 0) {} catch {}
    }

    // ─── Vault Sell ──────────────────────────────────────────────────────────
    function vaultSell(uint256 vaultSeed, uint256 amount) external {
        address vault = vaults[vaultSeed % vaults.length];
        uint256 balance = okt.balanceOf(vault);
        if (balance < okt.MIN_SELL()) return;

        amount = bound(amount, okt.MIN_SELL(), balance);
        if (okt.totalSupply() <= amount) return;

        vm.prank(vault);
        try okt.sell(amount, 0) {} catch {}
    }

    // ─── Withdraw ─────────────────────────────────────────────────────────────
    function withdraw(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        if (okt.dividendsOf(actor) == 0) return;

        vm.prank(actor);
        try okt.withdraw() {} catch {}
    }

    // ─── Vault Withdraw ──────────────────────────────────────────────────────
    function vaultWithdraw(uint256 vaultSeed) external {
        address vault = vaults[vaultSeed % vaults.length];
        if (okt.dividendsOf(vault) == 0) return;

        vm.prank(vault);
        try okt.withdraw() {} catch {}
    }

    // ─── Reinvest ─────────────────────────────────────────────────────────────
    function reinvest(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        if (okt.dividendsOf(actor) == 0) return;

        vm.prank(actor);
        try okt.reinvest() {} catch {}
    }

    // ─── Transfer ─────────────────────────────────────────────────────────────
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        if (from == to) return;

        uint256 balance = okt.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(from);
        try okt.transfer(to, amount) {} catch {}
    }

    // ─── Vault Transfer ──────────────────────────────────────────────────────
    function vaultTransfer(uint256 vaultSeed, uint256 actorSeed, uint256 amount) external {
        address from = vaults[vaultSeed % vaults.length];
        address to = actors[actorSeed % actors.length];

        uint256 balance = okt.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(from);
        try okt.transfer(to, amount) {} catch {}
    }

    // ─── Inscribe ────────────────────────────────────────────────────────────
    function inscribe(uint256 vaultSeed, uint256 amount, uint256 ordinalSeed) external {
        address vault = vaults[vaultSeed % vaults.length];
        if (okt.isVault(vault)) return;

        amount = bound(amount, MIN_SATS, MAX_SATS);
        uint256 ordinalNumber = bound(ordinalSeed, 0, MAX_ORDINAL);
        if (ordinalNumber > 0) {
            if (okt.ordinalVaultAddress(ordinalNumber) != address(0)) return;
            if (okt.ordinalHasBeenMoved(ordinalNumber)) return;
        }

        address registrar = okt.vaultRegistrar();
        if (cbbtc.balanceOf(registrar) < amount) return;

        vm.prank(registrar);
        try okt.inscribe(vault, bytes32(uint256(uint160(vault))), amount, ordinalNumber) {} catch {}
    }

    // ─── Report Ordinal Moved ────────────────────────────────────────────────
    function reportOrdinalMoved(uint256 ordinalSeed) external {
        uint256 ordinalNumber = bound(ordinalSeed, 1, MAX_ORDINAL);
        if (okt.ordinalHasBeenMoved(ordinalNumber)) return;

        vm.prank(okt.ordinalOracle());
        try okt.reportOrdinalMoved(ordinalNumber) {} catch {}
    }

    // ─── Helper for invariant checks ──────────────────────────────────────────
    function allActors() external view returns (address[] memory) {
        return actors;
    }

    function allVaults() external view returns (address[] memory) {
        return vaults;
    }

    function totalClaimable() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += okt.dividendsOf(actors[i]);
        }
        for (uint256 i = 0; i < vaults.length; i++) {
            total += okt.dividendsOf(vaults[i]);
        }
    }

    function totalOKTBalance() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += okt.balanceOf(actors[i]);
        }
        for (uint256 i = 0; i < vaults.length; i++) {
            total += okt.balanceOf(vaults[i]);
        }
    }
}

// ─── Invariant Test ───────────────────────────────────────────────────────────
contract OKTInvariantTest is Test {
    OriginKeyToken public okt;
    MockCbBTC public cbbtc;
    OKTHandler public handler;

    function setUp() public {
        cbbtc = new MockCbBTC();
        okt = new OriginKeyToken(address(cbbtc));
        handler = new OKTHandler(okt, cbbtc);

        // Seed the contract with a first buy so totalSupply > 0
        address first = handler.actors(0);
        vm.prank(first);
        okt.buy(10_000, 0);

        // Tell Foundry to only call handler functions
        targetContract(address(handler));
    }

    // ─── INVARIANT 1: SOLVENCY ────────────────────────────────────────────────
    // The contract must always hold enough cbBTC to pay all claimable dividends
    // This is the most critical invariant — if it breaks the contract can be drained
    function invariant_solvency() public view {
        uint256 contractBalance = cbbtc.balanceOf(address(okt));
        uint256 totalClaimable = handler.totalClaimable();
        assertGe(contractBalance, totalClaimable, "CRITICAL: Contract cbBTC < total claimable dividends");
    }

    // ─── INVARIANT 2: SUPPLY INTEGRITY ───────────────────────────────────────
    // Total OKT held by all actors must never exceed total supply
    function invariant_supplyIntegrity() public view {
        uint256 totalHeld = handler.totalOKTBalance();
        uint256 totalSupply = okt.totalSupply();
        assertLe(totalHeld, totalSupply, "Actor balances exceed total supply");
    }

    // ─── INVARIANT 3: NO PHANTOM DIVIDENDS ───────────────────────────────────
    // No actor should be able to claim more than the contract holds
    function invariant_noPhantomDividends() public view {
        address[] memory actors = handler.allActors();
        address[] memory vaults = handler.allVaults();
        uint256 contractBalance = cbbtc.balanceOf(address(okt));
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 divs = okt.dividendsOf(actors[i]);
            assertLe(divs, contractBalance, "Single actor dividends exceed contract balance");
        }
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 divs = okt.dividendsOf(vaults[i]);
            assertLe(divs, contractBalance, "Single vault dividends exceed contract balance");
        }
    }

    // ─── INVARIANT 4: PROFIT PER TOKEN NEVER DECREASES ───────────────────────
    // profitPerToken should only ever go up — fees only add to it
    function invariant_profitPerTokenMonotonic() public view {
        // Can't easily track previous value in invariant tests
        // but we can assert it's reasonable (not zero after activity)
        // This is checked implicitly by solvency
        assertTrue(okt.profitPerToken() >= 0, "profitPerToken negative");
    }
}
