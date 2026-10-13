// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/WitnessKey.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockCbBTC is ERC20 {
    constructor() ERC20("Coinbase Wrapped BTC", "cbBTC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 8; }
}

contract WitnessKeySecurityTest is Test {
    WitnessKey public wk;
    MockCbBTC      public cbbtc;

    address public registrar = address(this);
    address public alice     = makeAddr("alice");
    address public bob       = makeAddr("bob");
    address public carol     = makeAddr("carol");
    address public attacker  = makeAddr("attacker");
    address public vault1    = makeAddr("vault1");
    address public vault2    = makeAddr("vault2");

    function setUp() public {
        cbbtc = new MockCbBTC();
        wk   = new WitnessKey(address(cbbtc));

        // Fund wallets generously
        cbbtc.mint(alice,     100_000_000); // 1 BTC
        cbbtc.mint(bob,       100_000_000);
        cbbtc.mint(carol,     100_000_000);
        cbbtc.mint(attacker,  100_000_000);
        cbbtc.mint(registrar, 100_000_000);

        // Approve
        vm.prank(alice);    cbbtc.approve(address(wk), type(uint256).max);
        vm.prank(bob);      cbbtc.approve(address(wk), type(uint256).max);
        vm.prank(carol);    cbbtc.approve(address(wk), type(uint256).max);
        vm.prank(attacker); cbbtc.approve(address(wk), type(uint256).max);
        cbbtc.approve(address(wk), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DIVIDEND DRIFT — does repeated buy/sell/withdraw slowly leak value?
    // ═══════════════════════════════════════════════════════════════════════════

    function test_recirculationDrift_100Cycles() public {
        // Seed the contract
        vm.prank(alice); wk.acquire(1_000_000, 0);

        uint256 contractBalBefore = cbbtc.balanceOf(address(wk));

        // Bob does 100 buy/sell/withdraw cycles
        for (uint i = 0; i < 100; i++) {
            vm.prank(bob); wk.acquire(10_000, 0);
            uint256 bobBal = wk.balanceOf(bob);
            if (bobBal > 1) {
                vm.prank(bob); wk.dispose(bobBal - 1, 0);
            }
            uint256 bobDivs = wk.recirculationOf(bob);
            if (bobDivs > 0) {
                vm.prank(bob); wk.claim();
            }
        }

        // Contract must still cover Alice's recirculation
        uint256 contractBalAfter = cbbtc.balanceOf(address(wk));
        uint256 aliceDivs = wk.recirculationOf(alice);
        assertGe(contractBalAfter, aliceDivs, "Recirculation drift: contract underfunded after 100 cycles");
    }

    function test_recirculationDrift_multipleActors() public {
        // Three actors trading simultaneously
        vm.prank(alice); wk.acquire(500_000, 0);
        vm.prank(bob);   wk.acquire(500_000, 0);
        vm.prank(carol); wk.acquire(500_000, 0);

        for (uint i = 0; i < 50; i++) {
            // Each actor buys, sells, withdraws in rotation
            vm.prank(alice); wk.acquire(10_000, 0);
            vm.prank(bob);   wk.acquire(10_000, 0);

            uint256 aliceBal = wk.balanceOf(alice);
            if (aliceBal > 1000) {
                vm.prank(alice); wk.dispose(1000, 0);
            }

            uint256 bobDivs = wk.recirculationOf(bob);
            if (bobDivs > 0) {
                vm.prank(bob); wk.claim();
            }

            vm.prank(carol); wk.acquire(5_000, 0);
        }

        // Final solvency check
        uint256 contractBal = cbbtc.balanceOf(address(wk));
        uint256 totalOwed = wk.recirculationOf(alice)
                          + wk.recirculationOf(bob)
                          + wk.recirculationOf(carol);
        assertGe(contractBal, totalOwed, "Recirculation drift: multi-actor solvency broken");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRECISION LOSS — small amounts, edge cases, rounding attacks
    // ═══════════════════════════════════════════════════════════════════════════

    function test_precisionLoss_minimumBuy() public {
        // First buyer
        vm.prank(alice); wk.acquire(100, 0); // minimum buy

        // Second buyer minimum
        vm.prank(bob); wk.acquire(100, 0);

        // Contract should hold exactly 200 sats
        assertEq(cbbtc.balanceOf(address(wk)), 200);
        // Alice got 100 (first buyer fee returned)
        assertEq(wk.balanceOf(alice), 100);
        // Bob got 93 (7% fee)
        assertEq(wk.balanceOf(bob), 93);
    }

    function test_precisionLoss_manySmallBuys() public {
        // First buyer
        vm.prank(alice); wk.acquire(100_000, 0);

        uint256 contractBefore = cbbtc.balanceOf(address(wk));

        // 200 minimum buys from different senders
        for (uint i = 0; i < 200; i++) {
            vm.prank(bob); wk.acquire(100, 0);
        }

        uint256 contractAfter = cbbtc.balanceOf(address(wk));
        uint256 totalOwed = wk.recirculationOf(alice) + wk.recirculationOf(bob);

        // Contract must cover all recirculation even after many small operations
        assertGe(contractAfter, totalOwed, "Precision loss after 200 minimum buys");
    }

    function test_precisionLoss_manySmallSells() public {
        vm.prank(alice); wk.acquire(100_000, 0);
        vm.prank(bob);   wk.acquire(100_000, 0);

        // Bob sells 1 token at a time, 100 times
        for (uint i = 0; i < 100; i++) {
            uint256 bobBal = wk.balanceOf(bob);
            if (bobBal > 1 && wk.totalSupply() > 1) {
                vm.prank(bob); wk.dispose(100, 0);
            }
        }

        uint256 contractBal = cbbtc.balanceOf(address(wk));
        uint256 totalOwed = wk.recirculationOf(alice) + wk.recirculationOf(bob);
        assertGe(contractBal, totalOwed, "Precision loss after 100 single-token sells");
    }

    function test_precisionLoss_largeSpread() public {
        // One whale, one small buyer — tests precision with very different balances
        vm.prank(alice); wk.acquire(1_000_000, 0); // max buy whale
        vm.prank(bob);   wk.acquire(100, 0);        // minimum buy

        uint256 aliceDivs = wk.recirculationOf(alice);
        uint256 bobDivs   = wk.recirculationOf(bob);

        // Alice should get vastly more recirculation than Bob (proportional to holdings)
        // Bob's buy fee goes to Alice who holds ~99.99% of supply
        assertGt(aliceDivs, 0, "Whale should earn recirculation");

        uint256 contractBal = cbbtc.balanceOf(address(wk));
        uint256 totalOwed = aliceDivs + bobDivs;
        assertGe(contractBal, totalOwed, "Precision loss with large balance spread");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REINVEST DUST LOOP — confirm the minimum blocks exploitation
    // ═══════════════════════════════════════════════════════════════════════════

    function test_recirculateDustLoop_blocked() public {
        vm.prank(alice); wk.acquire(10_000, 0);
        vm.prank(bob);   wk.acquire(200, 0); // tiny buy generates small recirculation

        uint256 supplyBefore = wk.totalSupply();

        // Try to reinvest 50 times — should all fail
        for (uint i = 0; i < 50; i++) {
            uint256 divs = wk.recirculationOf(alice);
            if (divs < 100) {
                vm.prank(alice);
                vm.expectRevert("Minimum 100 sats to recirculate");
                wk.recirculate();
            }
        }

        // Supply should not have changed
        assertEq(wk.totalSupply(), supplyBefore, "Dust loop created phantom tokens");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VAULT DRAIN ATTACKS — can attacker drain vault or manipulate provenance?
    // ═══════════════════════════════════════════════════════════════════════════

    function test_onlyRegistrarCanInscribe() public {
        vm.prank(attacker);
        vm.expectRevert("Not vault registrar");
        wk.inscribe(vault1, bytes32("FAKE-001"), 10_000, 0, "");
    }

    function test_onlyOracleCanReportOrdinalMoved() public {
        // First inscribe a real vault
        wk.inscribe(vault1, bytes32("TEST-001"), 10_000, 12345, "");

        vm.prank(attacker);
        vm.expectRevert("Not ordinal oracle");
        wk.reportOrdinalMoved(12345, bytes32("btctx"));
    }

    function test_cannotInscribeSameVaultTwice() public {
        wk.inscribe(vault1, bytes32("TEST-001"), 10_000, 0, "");

        vm.expectRevert("Vault: already registered");
        wk.inscribe(vault1, bytes32("TEST-002"), 10_000, 0, "");
    }

    function test_cannotReportSameOrdinalTwice() public {
        wk.inscribe(vault1, bytes32("TEST-001"), 10_000, 12345, "");
        wk.reportOrdinalMoved(12345, bytes32("btctx"));

        vm.expectRevert("Already reported as moved");
        wk.reportOrdinalMoved(12345, bytes32("btctx"));
    }

    function test_vaultSweptOnSell() public {
        // Inscribe vault
        wk.inscribe(vault1, bytes32("TEST-001"), 50_000, 0, "");

        // Vault sells — should trigger VaultSwept
        vm.prank(vault1);
        wk.dispose(1000, 0);

        // Check vault is marked as swept
        (bool registered, bool swept,,) = wk.vaultStatus(vault1);
        assertTrue(registered, "Vault should be registered");
        assertTrue(swept, "Vault should be swept after sell");
    }

    function test_vaultSweptOnTransfer() public {
        wk.inscribe(vault1, bytes32("TEST-001"), 50_000, 0, "");

        // Need another holder to transfer to
        vm.prank(alice); wk.acquire(10_000, 0);

        // Vault transfers — should trigger sweep
        vm.prank(vault1);
        wk.transfer(alice, 100);

        (bool registered, bool swept,,) = wk.vaultStatus(vault1);
        assertTrue(registered);
        assertTrue(swept, "Vault should be swept after transfer");
    }

    function test_vaultSweptOnWithdraw() public {
        wk.inscribe(vault1, bytes32("TEST-001"), 50_000, 0, "");

        // Generate some recirculation for the vault
        vm.prank(alice); wk.acquire(100_000, 0);

        uint256 vaultDivs = wk.recirculationOf(vault1);
        if (vaultDivs > 0) {
            vm.prank(vault1);
            wk.claim();

            (bool registered, bool swept,,) = wk.vaultStatus(vault1);
            assertTrue(registered);
            assertTrue(swept, "Vault should be swept after withdraw");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DOUBLE SPEND — confirm sell + withdraw cannot extract more than deposited
    // ═══════════════════════════════════════════════════════════════════════════

    function test_doubleSpend_sellThenWithdraw() public {
        vm.prank(alice); wk.acquire(1_000_000, 0);
        vm.prank(bob);   wk.acquire(1_000_000, 0);

        uint256 bobCbbtcBefore = cbbtc.balanceOf(bob);

        // Bob sells everything except 1
        uint256 bobTokens = wk.balanceOf(bob);
        vm.prank(bob); wk.dispose(bobTokens - 1, 0);

        // Bob tries to withdraw any remaining recirculation
        uint256 bobDivs = wk.recirculationOf(bob);
        if (bobDivs > 0) {
            vm.prank(bob); wk.claim();
        }

        uint256 bobCbbtcAfter = cbbtc.balanceOf(bob);
        uint256 bobTotalReceived = bobCbbtcAfter - bobCbbtcBefore;

        // Bob should never receive more than he put in (1_000_000)
        // He loses 7% on buy and 7% on sell so should receive significantly less
        assertLt(bobTotalReceived, 1_000_000, "Double spend: Bob got more than deposited");
    }

    function test_doubleSpend_rapidBuySellCycle() public {
        vm.prank(alice); wk.acquire(1_000_000, 0); // seed

        uint256 attackerBefore = cbbtc.balanceOf(attacker);

        // Attacker tries rapid buy/sell/withdraw 20 times
        for (uint i = 0; i < 20; i++) {
            vm.prank(attacker); wk.acquire(10_000, 0);
            uint256 bal = wk.balanceOf(attacker);
            if (bal > 1 && wk.totalSupply() > bal) {
                vm.prank(attacker); wk.dispose(bal - 1, 0);
            }
            uint256 divs = wk.recirculationOf(attacker);
            if (divs > 0) {
                vm.prank(attacker); wk.claim();
            }
        }

        uint256 attackerAfter = cbbtc.balanceOf(attacker);

        // Attacker should have LESS than they started with (fees consumed)
        assertLt(attackerAfter, attackerBefore, "Rapid cycle: attacker gained value");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE MANIPULATION — can we get the contract into an invalid state?
    // ═══════════════════════════════════════════════════════════════════════════

    function test_zeroBuyReverts() public {
        vm.prank(alice);
        vm.expectRevert("Minimum 100 sats");
        wk.acquire(0, 0);
    }

    function test_zeroSellReverts() public {
        vm.prank(alice); wk.acquire(10_000, 0);
        vm.prank(alice);
        vm.expectRevert("Minimum 100 sats to dispose");
        wk.dispose(0, 0);
    }

    function test_sellMoreThanBalanceReverts() public {
        vm.prank(alice); wk.acquire(10_000, 0);
        vm.prank(alice);
        vm.expectRevert("Insufficient balance");
        wk.dispose(999_999, 0);
    }

    function test_transferToZeroReverts() public {
        vm.prank(alice); wk.acquire(10_000, 0);
        vm.prank(alice);
        vm.expectRevert("Zero address");
        wk.transfer(address(0), 100);
    }

    function test_claimWithNoRecirculationReverts() public {
        vm.prank(alice); wk.acquire(10_000, 0);
        vm.prank(alice);
        vm.expectRevert("No recirculation to claim");
        wk.claim();
    }

    function test_sellEntireSupplyReverts() public {
        vm.prank(alice); wk.acquire(10_000, 0);
        uint256 bal = wk.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert("Cannot dispose entire supply");
        wk.dispose(bal, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORDINAL INTEGRITY — provenance records cannot be faked
    // ═══════════════════════════════════════════════════════════════════════════

    function test_ordinalLinkedCorrectly() public {
        wk.inscribe(vault1, bytes32("ART-001"), 50_000, 92588651, "");

        (uint256 ordNum, bool hasOrd, bool moved, uint256 movedAt,) = wk.vaultOrdinalStatus(vault1);
        assertEq(ordNum, 92588651);
        assertTrue(hasOrd);
        assertFalse(moved);
        assertEq(movedAt, 0);
    }

    function test_ordinalMovedTriggersVaultSwept() public {
        wk.inscribe(vault1, bytes32("ART-001"), 50_000, 92588651, "");

        // Vault should not be swept yet
        (,bool sweptBefore,,) = wk.vaultStatus(vault1);
        assertFalse(sweptBefore);

        // Report ordinal moved
        wk.reportOrdinalMoved(92588651, bytes32("btctx"));

        // Vault should now be marked as swept
        (,bool sweptAfter,,) = wk.vaultStatus(vault1);
        assertTrue(sweptAfter, "Ordinal movement should trigger VaultSwept");
    }

    function test_ordinalMovedReportsCorrectly() public {
        wk.inscribe(vault1, bytes32("ART-001"), 50_000, 92588651, "");
        wk.reportOrdinalMoved(92588651, bytes32("btctx"));

        (uint256 ordNum, bool hasOrd, bool moved, uint256 movedAt,) = wk.vaultOrdinalStatus(vault1);
        assertEq(ordNum, 92588651);
        assertTrue(hasOrd);
        assertTrue(moved);
        assertGt(movedAt, 0);
    }

    function test_noOrdinalVaultWorksCorrectly() public {
        wk.inscribe(vault1, bytes32("SERIES-001"), 50_000, 0, "");

        (uint256 ordNum, bool hasOrd, bool moved,,) = wk.vaultOrdinalStatus(vault1);
        assertEq(ordNum, 0);
        assertFalse(hasOrd);
        assertFalse(moved);
    }

    function test_vaultStatusReturnsCorrectly() public {
        wk.inscribe(vault1, bytes32("ART-001"), 50_000, 0, "");

        (bool registered, bool swept, uint256 balance, bytes32 assetId) = wk.vaultStatus(vault1);
        assertTrue(registered);
        assertFalse(swept);
        assertEq(balance, 50_000); // first vault gets fee returned
        assertEq(assetId, bytes32("ART-001"));
    }

    function test_unregisteredVaultReturnsEmpty() public {
        (bool registered, bool swept, uint256 balance, bytes32 assetId) = wk.vaultStatus(address(0xDEAD));
        assertFalse(registered);
        assertFalse(swept);
        assertEq(balance, 0);
        assertEq(assetId, bytes32(0));
    }
}
