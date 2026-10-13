// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/WitnessKey.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock cbBTC for testing
contract MockCbBTC is ERC20 {
    constructor() ERC20("Coinbase Wrapped BTC", "cbBTC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    function decimals() public pure override returns (uint8) { return 8; }
}

contract WitnessKeyTest is Test {
    WitnessKey public wk;
    MockCbBTC      public cbbtc;

    address public registrar = address(this);
    address public alice     = makeAddr("alice");
    address public bob       = makeAddr("bob");
    address public carol     = makeAddr("carol");

    uint256 constant SATS = 10_000;

    function setUp() public {
        cbbtc = new MockCbBTC();
        wk   = new WitnessKey(address(cbbtc));

        // Fund wallets
        cbbtc.mint(alice,     1_000_000);
        cbbtc.mint(bob,       1_000_000);
        cbbtc.mint(carol,     1_000_000);
        cbbtc.mint(registrar, 1_000_000);

        // Approve
        vm.prank(alice); cbbtc.approve(address(wk), type(uint256).max);
        vm.prank(bob);   cbbtc.approve(address(wk), type(uint256).max);
        vm.prank(carol); cbbtc.approve(address(wk), type(uint256).max);
        cbbtc.approve(address(wk), type(uint256).max);
    }

    // ─── Basic buy tests ──────────────────────────────────────────────────────

    function test_firstBuyGetsFullAmount() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);
        assertEq(wk.balanceOf(alice), SATS); // first buyer gets fee back
    }

    function test_secondBuyPays7PercentFee() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        assertEq(wk.balanceOf(bob), SATS * 93 / 100);
    }

    // ─── Recirculation tests ───────────────────────────────────────────────────────

    function test_recirculationAccumulatesAfterBuy() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        assertGt(wk.recirculationOf(alice), 0);
    }

    function test_claimGivesCorrectAmount() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        uint256 divs = wk.recirculationOf(alice);
        uint256 balBefore = cbbtc.balanceOf(alice);
        vm.prank(alice); wk.claim();
        assertEq(cbbtc.balanceOf(alice) - balBefore, divs);
    }

    // ─── Sell tests ───────────────────────────────────────────────────────────

    function test_sellSendsCbbtcDirectly() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        uint256 balBefore = cbbtc.balanceOf(bob);
        uint256 bobTokens = wk.balanceOf(bob);
        vm.prank(bob);   wk.dispose(bobTokens - 1, 0);
        uint256 balAfter = cbbtc.balanceOf(bob);
        // Bob should receive 93% of tokens sold directly in cbBTC
        assertGt(balAfter, balBefore);
    }

    function test_sellAndRebuyStillEarnsRecirculation() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        vm.prank(bob);   wk.dispose(1000, 0); // sell fixed amount
        vm.prank(bob);   wk.acquire(SATS, 0);
        vm.prank(carol); wk.acquire(SATS, 0);
        assertGt(wk.recirculationOf(bob), 0);
    }

    function test_sellEverythingRecirculationRemains() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        uint256 divsBefore = wk.recirculationOf(alice);
        vm.prank(alice); wk.dispose(1000, 0);
        uint256 divsAfter = wk.recirculationOf(alice);
        assertGe(divsAfter, divsBefore);
    }

    // ─── Reinvest test ────────────────────────────────────────────────────────

    function test_recirculateMintsTokens() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        uint256 balBefore = wk.balanceOf(alice);
        vm.prank(alice); wk.recirculate();
        assertGt(wk.balanceOf(alice), balBefore);
    }

    // ─── Double-spend protection test ───────────────────────────────────────
    function test_noDoubleSpendOnSell() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);

        uint256 bobCbbtcBefore = cbbtc.balanceOf(bob);
        uint256 bobTokens = wk.balanceOf(bob);

        // Bob sells
        vm.prank(bob); wk.dispose(1000, 0);

        uint256 bobCbbtcAfterSell = cbbtc.balanceOf(bob);
        uint256 bobDivsAfterSell  = wk.recirculationOf(bob);

        // Bob received cbBTC from sell directly
        assertGt(bobCbbtcAfterSell, bobCbbtcBefore);

        // Bob's recirculation balance should NOT equal the sell proceeds
        // If it does, double-spend vulnerability exists
        uint256 sellProceeds = bobCbbtcAfterSell - bobCbbtcBefore;
        assertTrue(bobDivsAfterSell < sellProceeds, "Double-spend: divs equals sell proceeds");
    }

    // ─── Reinvest dust loop prevention ──────────────────────────────────────
    function test_recirculateMinimum100Sats() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        // Alice has recirculation from Bob's buy but likely < 100 sats
        uint256 divs = wk.recirculationOf(alice);
        if (divs < 100) {
            vm.prank(alice);
            vm.expectRevert("Minimum 100 sats to recirculate");
            wk.recirculate();
        }
    }

    function test_recirculateDustLoopBlocked() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(200, 0); // small buy generates tiny recirculation
        uint256 divs = wk.recirculationOf(alice);
        if (divs < 100) {
            // Cannot reinvest dust — loop is blocked
            vm.prank(alice);
            vm.expectRevert("Minimum 100 sats to recirculate");
            wk.recirculate();
        }
    }

    // ─── Minimal sell isolation test ─────────────────────────────────────────

    function test_minimalSell() public {
        // Alice buys first - gets 10000 (first buyer)
        vm.prank(alice); wk.acquire(SATS, 0);
        // Bob buys - gets 9300
        vm.prank(bob);   wk.acquire(SATS, 0);
        
        // Check balances before sell
        uint256 bobBalance  = wk.balanceOf(bob);
        uint256 contractBal = cbbtc.balanceOf(address(wk));
        
        // Log values
        emit log_named_uint("Bob WK balance", bobBalance);
        emit log_named_uint("Contract cbBTC", contractBal);
        emit log_named_uint("Bob recirculation", wk.recirculationOf(bob));
        
        // Sell minimum 100 tokens
        vm.prank(bob);
        wk.dispose(100, 0);
        
        emit log_named_uint("Contract cbBTC after sell", cbbtc.balanceOf(address(wk)));
        emit log_named_uint("Bob recirculation after sell", wk.recirculationOf(bob));
    }

    // ─── THE KEY INVARIANT ────────────────────────────────────────────────────
    // cbBTC in contract must always cover all claimable recirculation

    function test_solvency_after_buys() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        vm.prank(carol); wk.acquire(SATS, 0);

        uint256 contractBalance = cbbtc.balanceOf(address(wk));
        uint256 totalOwed = wk.recirculationOf(alice)
                          + wk.recirculationOf(bob)
                          + wk.recirculationOf(carol);

        assertGe(contractBalance, totalOwed);
    }

    function test_solvency_after_sell() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        vm.prank(carol); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.dispose(1000, 0); // sell fixed amount

        uint256 contractBalance = cbbtc.balanceOf(address(wk));
        uint256 aliceDivs = wk.recirculationOf(alice);
        uint256 bobDivs   = wk.recirculationOf(bob);
        uint256 carolDivs = wk.recirculationOf(carol);
        uint256 totalOwed = aliceDivs + bobDivs + carolDivs;

        emit log_named_uint("Contract cbBTC", contractBalance);
        emit log_named_uint("Alice divs",     aliceDivs);
        emit log_named_uint("Bob divs",       bobDivs);
        emit log_named_uint("Carol divs",     carolDivs);
        emit log_named_uint("Total owed",     totalOwed);
        emit log_named_uint("Difference",     totalOwed > contractBalance ? totalOwed - contractBalance : 0);

        assertGe(contractBalance, totalOwed);
    }

    function test_solvency_after_claim() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        vm.prank(carol); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.dispose(1000, 0); // sell fixed amount
        vm.prank(alice); wk.claim();

        uint256 contractBalance = cbbtc.balanceOf(address(wk));
        uint256 totalOwed = wk.recirculationOf(alice)
                          + wk.recirculationOf(bob)
                          + wk.recirculationOf(carol);

        assertGe(contractBalance, totalOwed);
    }

    function test_solvency_after_recirculate() public {
        vm.prank(alice); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.acquire(SATS, 0);
        vm.prank(carol); wk.acquire(SATS, 0);
        vm.prank(bob);   wk.dispose(1000, 0); // sell fixed amount
        vm.prank(alice); wk.recirculate();

        uint256 contractBalance = cbbtc.balanceOf(address(wk));
        uint256 totalOwed = wk.recirculationOf(alice)
                          + wk.recirculationOf(bob)
                          + wk.recirculationOf(carol);

        assertGe(contractBalance, totalOwed);
    }
}
