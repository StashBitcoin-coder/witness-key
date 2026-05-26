// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/OriginKeyToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockCbBTC is ERC20 {
    constructor() ERC20("Coinbase Wrapped BTC", "cbBTC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

contract OKTSecurityTest is Test {
    OriginKeyToken public okt;
    MockCbBTC public cbbtc;

    address public registrar = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public attacker = makeAddr("attacker");
    address public vault1 = makeAddr("vault1");
    address public vault2 = makeAddr("vault2");

    function setUp() public {
        cbbtc = new MockCbBTC();
        okt = new OriginKeyToken(address(cbbtc));

        // Fund wallets generously
        cbbtc.mint(alice, 100_000_000); // 1 BTC
        cbbtc.mint(bob, 100_000_000);
        cbbtc.mint(carol, 100_000_000);
        cbbtc.mint(attacker, 100_000_000);
        cbbtc.mint(registrar, 100_000_000);

        // Approve
        vm.prank(alice);
        cbbtc.approve(address(okt), type(uint256).max);
        vm.prank(bob);
        cbbtc.approve(address(okt), type(uint256).max);
        vm.prank(carol);
        cbbtc.approve(address(okt), type(uint256).max);
        vm.prank(attacker);
        cbbtc.approve(address(okt), type(uint256).max);
        cbbtc.approve(address(okt), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DIVIDEND DRIFT — does repeated buy/sell/withdraw slowly leak value?
    // ═══════════════════════════════════════════════════════════════════════════

    function test_dividendDrift_100Cycles() public {
        // Seed the contract
        vm.prank(alice);
        okt.buy(1_000_000, 0);

        // Bob does 100 buy/sell/withdraw cycles
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(bob);
            okt.buy(10_000, 0);
            uint256 bobBal = okt.balanceOf(bob);
            if (bobBal > 1) {
                vm.prank(bob);
                okt.sell(bobBal - 1, 0);
            }
            uint256 bobDivs = okt.dividendsOf(bob);
            if (bobDivs > 0) {
                vm.prank(bob);
                okt.withdraw();
            }
        }

        // Contract must still cover Alice's dividends
        uint256 contractBalAfter = cbbtc.balanceOf(address(okt));
        uint256 aliceDivs = okt.dividendsOf(alice);
        assertGe(contractBalAfter, aliceDivs, "Dividend drift: contract underfunded after 100 cycles");
    }

    function test_dividendDrift_multipleActors() public {
        // Three actors trading simultaneously
        vm.prank(alice);
        okt.buy(500_000, 0);
        vm.prank(bob);
        okt.buy(500_000, 0);
        vm.prank(carol);
        okt.buy(500_000, 0);

        for (uint256 i = 0; i < 50; i++) {
            // Each actor buys, sells, withdraws in rotation
            vm.prank(alice);
            okt.buy(10_000, 0);
            vm.prank(bob);
            okt.buy(10_000, 0);

            uint256 aliceBal = okt.balanceOf(alice);
            if (aliceBal > 1000) {
                vm.prank(alice);
                okt.sell(1000, 0);
            }

            uint256 bobDivs = okt.dividendsOf(bob);
            if (bobDivs > 0) {
                vm.prank(bob);
                okt.withdraw();
            }

            vm.prank(carol);
            okt.buy(5_000, 0);
        }

        // Final solvency check
        uint256 contractBal = cbbtc.balanceOf(address(okt));
        uint256 totalOwed = okt.dividendsOf(alice) + okt.dividendsOf(bob) + okt.dividendsOf(carol);
        assertGe(contractBal, totalOwed, "Dividend drift: multi-actor solvency broken");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRECISION LOSS — small amounts, edge cases, rounding attacks
    // ═══════════════════════════════════════════════════════════════════════════

    function test_precisionLoss_minimumBuy() public {
        // First buyer
        vm.prank(alice); // minimum buy
        okt.buy(100, 0);

        // Second buyer minimum
        vm.prank(bob);
        okt.buy(100, 0);

        // Contract should hold exactly 200 sats
        assertEq(cbbtc.balanceOf(address(okt)), 200);
        // Alice got 100 (first buyer fee returned)
        assertEq(okt.balanceOf(alice), 100);
        // Bob got 93 (7% fee)
        assertEq(okt.balanceOf(bob), 93);
    }

    function test_precisionLoss_manySmallBuys() public {
        // First buyer
        vm.prank(alice);
        okt.buy(100_000, 0);

        // 200 minimum buys from different senders
        for (uint256 i = 0; i < 200; i++) {
            vm.prank(bob);
            okt.buy(100, 0);
        }

        uint256 contractAfter = cbbtc.balanceOf(address(okt));
        uint256 totalOwed = okt.dividendsOf(alice) + okt.dividendsOf(bob);

        // Contract must cover all dividends even after many small operations
        assertGe(contractAfter, totalOwed, "Precision loss after 200 minimum buys");
    }

    function test_precisionLoss_manySmallSells() public {
        vm.prank(alice);
        okt.buy(100_000, 0);
        vm.prank(bob);
        okt.buy(100_000, 0);

        // Bob sells the minimum sell amount repeatedly.
        for (uint256 i = 0; i < 100; i++) {
            uint256 bobBal = okt.balanceOf(bob);
            if (bobBal >= 100 && okt.totalSupply() > 100) {
                vm.prank(bob);
                okt.sell(100, 0);
            }
        }

        uint256 contractBal = cbbtc.balanceOf(address(okt));
        uint256 totalOwed = okt.dividendsOf(alice) + okt.dividendsOf(bob);
        assertGe(contractBal, totalOwed, "Precision loss after 100 single-token sells");
    }

    function test_precisionLoss_largeSpread() public {
        // One whale, one small buyer — tests precision with very different balances
        vm.prank(alice); // max buy whale
        okt.buy(1_000_000, 0);
        vm.prank(bob); // minimum buy
        okt.buy(100, 0);

        uint256 aliceDivs = okt.dividendsOf(alice);
        uint256 bobDivs = okt.dividendsOf(bob);

        // Alice should get vastly more dividends than Bob (proportional to holdings)
        // Bob's buy fee goes to Alice who holds ~99.99% of supply
        assertGt(aliceDivs, 0, "Whale should earn dividends");

        uint256 contractBal = cbbtc.balanceOf(address(okt));
        uint256 totalOwed = aliceDivs + bobDivs;
        assertGe(contractBal, totalOwed, "Precision loss with large balance spread");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REINVEST DUST LOOP — confirm the minimum blocks exploitation
    // ═══════════════════════════════════════════════════════════════════════════

    function test_reinvestDustLoop_blocked() public {
        vm.prank(alice);
        okt.buy(10_000, 0);
        vm.prank(bob); // tiny buy generates small dividend
        okt.buy(200, 0);

        uint256 supplyBefore = okt.totalSupply();

        // Try to reinvest 50 times — should all fail
        for (uint256 i = 0; i < 50; i++) {
            uint256 divs = okt.dividendsOf(alice);
            if (divs < 100) {
                vm.prank(alice);
                vm.expectRevert("Minimum 100 sats to reinvest");
                okt.reinvest();
            }
        }

        // Supply should not have changed
        assertEq(okt.totalSupply(), supplyBefore, "Dust loop created phantom tokens");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VAULT DRAIN ATTACKS — can attacker drain vault or manipulate provenance?
    // ═══════════════════════════════════════════════════════════════════════════

    function test_onlyRegistrarCanInscribe() public {
        vm.prank(attacker);
        vm.expectRevert("Not vault registrar");
        okt.inscribe(vault1, bytes32("FAKE-001"), 10_000, 0);
    }

    function test_onlyOracleCanReportOrdinalMoved() public {
        // First inscribe a real vault
        okt.inscribe(vault1, bytes32("TEST-001"), 10_000, 12345);

        vm.prank(attacker);
        vm.expectRevert("Not ordinal oracle");
        okt.reportOrdinalMoved(12345);
    }

    function test_cannotInscribeSameVaultTwice() public {
        okt.inscribe(vault1, bytes32("TEST-001"), 10_000, 0);

        vm.expectRevert("Vault: already registered");
        okt.inscribe(vault1, bytes32("TEST-002"), 10_000, 0);
    }

    function test_cannotReportSameOrdinalTwice() public {
        okt.inscribe(vault1, bytes32("TEST-001"), 10_000, 12345);
        okt.reportOrdinalMoved(12345);

        vm.expectRevert("Already reported as moved");
        okt.reportOrdinalMoved(12345);
    }

    function test_vaultSweptOnSell() public {
        // Inscribe vault
        okt.inscribe(vault1, bytes32("TEST-001"), 50_000, 0);

        // Vault sells — should trigger VaultSwept
        vm.prank(vault1);
        okt.sell(1000, 0);

        // Check vault is marked as swept
        (bool registered, bool swept,,) = okt.vaultStatus(vault1);
        assertTrue(registered, "Vault should be registered");
        assertTrue(swept, "Vault should be swept after sell");
    }

    function test_vaultSweptOnTransfer() public {
        okt.inscribe(vault1, bytes32("TEST-001"), 50_000, 0);

        // Need another holder to transfer to
        vm.prank(alice);
        okt.buy(10_000, 0);

        // Vault transfers — should trigger sweep
        vm.prank(vault1);
        okt.transfer(alice, 100);

        (bool registered, bool swept,,) = okt.vaultStatus(vault1);
        assertTrue(registered);
        assertTrue(swept, "Vault should be swept after transfer");
    }

    function test_vaultSweptOnWithdraw() public {
        okt.inscribe(vault1, bytes32("TEST-001"), 50_000, 0);

        // Generate some dividends for the vault
        vm.prank(alice);
        okt.buy(100_000, 0);

        uint256 vaultDivs = okt.dividendsOf(vault1);
        if (vaultDivs > 0) {
            vm.prank(vault1);
            okt.withdraw();

            (bool registered, bool swept,,) = okt.vaultStatus(vault1);
            assertTrue(registered);
            assertTrue(swept, "Vault should be swept after withdraw");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DOUBLE SPEND — confirm sell + withdraw cannot extract more than deposited
    // ═══════════════════════════════════════════════════════════════════════════

    function test_doubleSpend_sellThenWithdraw() public {
        vm.prank(alice);
        okt.buy(1_000_000, 0);
        vm.prank(bob);
        okt.buy(1_000_000, 0);

        uint256 bobCbbtcBefore = cbbtc.balanceOf(bob);

        // Bob sells everything except 1
        uint256 bobTokens = okt.balanceOf(bob);
        vm.prank(bob);
        okt.sell(bobTokens - 1, 0);

        // Bob tries to withdraw any remaining dividends
        uint256 bobDivs = okt.dividendsOf(bob);
        if (bobDivs > 0) {
            vm.prank(bob);
            okt.withdraw();
        }

        uint256 bobCbbtcAfter = cbbtc.balanceOf(bob);
        uint256 bobTotalReceived = bobCbbtcAfter - bobCbbtcBefore;

        // Bob should never receive more than he put in (1_000_000)
        // He loses 7% on buy and 7% on sell so should receive significantly less
        assertLt(bobTotalReceived, 1_000_000, "Double spend: Bob got more than deposited");
    }

    function test_doubleSpend_rapidBuySellCycle() public {
        vm.prank(alice); // seed
        okt.buy(1_000_000, 0);

        uint256 attackerBefore = cbbtc.balanceOf(attacker);

        // Attacker tries rapid buy/sell/withdraw 20 times
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(attacker);
            okt.buy(10_000, 0);
            uint256 bal = okt.balanceOf(attacker);
            if (bal > 1 && okt.totalSupply() > bal) {
                vm.prank(attacker);
                okt.sell(bal - 1, 0);
            }
            uint256 divs = okt.dividendsOf(attacker);
            if (divs > 0) {
                vm.prank(attacker);
                okt.withdraw();
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
        okt.buy(0, 0);
    }

    function test_zeroSellReverts() public {
        vm.prank(alice);
        okt.buy(10_000, 0);
        vm.prank(alice);
        vm.expectRevert("Minimum 100 sats to sell");
        okt.sell(0, 0);
    }

    function test_sellBelowMinimumReverts() public {
        vm.prank(alice);
        okt.buy(10_000, 0);
        vm.prank(alice);
        vm.expectRevert("Minimum 100 sats to sell");
        okt.sell(99, 0);
    }

    function test_sellMoreThanBalanceReverts() public {
        vm.prank(alice);
        okt.buy(10_000, 0);
        vm.prank(alice);
        vm.expectRevert("Insufficient balance");
        okt.sell(999_999, 0);
    }

    function test_transferToZeroReverts() public {
        vm.prank(alice);
        okt.buy(10_000, 0);
        vm.prank(alice);
        vm.expectRevert("Zero address");
        okt.transfer(address(0), 100);
    }

    function test_zeroTransferRevertsAndDoesNotSweepVault() public {
        okt.inscribe(vault1, bytes32("TEST-001"), 50_000, 0);

        vm.prank(vault1);
        vm.expectRevert("Zero tokens");
        okt.transfer(alice, 0);

        (, bool swept,,) = okt.vaultStatus(vault1);
        assertFalse(swept, "Zero transfer must not mark vault swept");
    }

    function test_withdrawWithNoDivsReverts() public {
        vm.prank(alice);
        okt.buy(10_000, 0);
        vm.prank(alice);
        vm.expectRevert("No dividends to withdraw");
        okt.withdraw();
    }

    function test_sellEntireSupplyReverts() public {
        vm.prank(alice);
        okt.buy(10_000, 0);
        uint256 bal = okt.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert("Cannot sell entire supply");
        okt.sell(bal, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORDINAL INTEGRITY — provenance records cannot be faked
    // ═══════════════════════════════════════════════════════════════════════════

    function test_ordinalLinkedCorrectly() public {
        okt.inscribe(vault1, bytes32("ART-001"), 50_000, 92588651);

        (uint256 ordNum, bool hasOrd, bool moved, uint256 movedAt) = okt.vaultOrdinalStatus(vault1);
        assertEq(ordNum, 92588651);
        assertTrue(hasOrd);
        assertFalse(moved);
        assertEq(movedAt, 0);
    }

    function test_duplicateOrdinalRegistrationReverts() public {
        okt.inscribe(vault1, bytes32("ART-001"), 50_000, 92588651);

        vm.expectRevert("Ordinal: already registered");
        okt.inscribe(vault2, bytes32("ART-002"), 50_000, 92588651);
    }

    function test_alreadyMovedOrdinalRegistrationReverts() public {
        okt.reportOrdinalMoved(92588651);

        vm.expectRevert("Ordinal: already moved");
        okt.inscribe(vault1, bytes32("ART-001"), 50_000, 92588651);
    }

    function test_ordinalMovedTriggersVaultSwept() public {
        okt.inscribe(vault1, bytes32("ART-001"), 50_000, 92588651);

        // Vault should not be swept yet
        (, bool sweptBefore,,) = okt.vaultStatus(vault1);
        assertFalse(sweptBefore);

        // Report ordinal moved
        okt.reportOrdinalMoved(92588651);

        // Vault should now be marked as swept
        (, bool sweptAfter,,) = okt.vaultStatus(vault1);
        assertTrue(sweptAfter, "Ordinal movement should trigger VaultSwept");
    }

    function test_ordinalMovedReportsCorrectly() public {
        okt.inscribe(vault1, bytes32("ART-001"), 50_000, 92588651);
        okt.reportOrdinalMoved(92588651);

        (uint256 ordNum, bool hasOrd, bool moved, uint256 movedAt) = okt.vaultOrdinalStatus(vault1);
        assertEq(ordNum, 92588651);
        assertTrue(hasOrd);
        assertTrue(moved);
        assertGt(movedAt, 0);
    }

    function test_noOrdinalVaultWorksCorrectly() public {
        okt.inscribe(vault1, bytes32("SERIES-001"), 50_000, 0);

        (uint256 ordNum, bool hasOrd, bool moved,) = okt.vaultOrdinalStatus(vault1);
        assertEq(ordNum, 0);
        assertFalse(hasOrd);
        assertFalse(moved);
    }

    function test_vaultStatusReturnsCorrectly() public {
        okt.inscribe(vault1, bytes32("ART-001"), 50_000, 0);

        (bool registered, bool swept, uint256 balance, bytes32 assetId) = okt.vaultStatus(vault1);
        assertTrue(registered);
        assertFalse(swept);
        assertEq(balance, 50_000); // first vault gets fee returned
        assertEq(assetId, bytes32("ART-001"));
    }

    function test_unregisteredVaultReturnsEmpty() public view {
        (bool registered, bool swept, uint256 balance, bytes32 assetId) = okt.vaultStatus(address(0xDEAD));
        assertFalse(registered);
        assertFalse(swept);
        assertEq(balance, 0);
        assertEq(assetId, bytes32(0));
    }
}
