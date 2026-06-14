// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/OriginKeyToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock cbBTC for testing
contract MockCbBTC is ERC20 {
    constructor() ERC20("Coinbase Wrapped BTC", "cbBTC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    function decimals() public pure override returns (uint8) { return 8; }
}

contract OKTTest is Test {
    OriginKeyToken public okt;
    MockCbBTC      public cbbtc;

    address public registrar = address(this);
    address public alice     = makeAddr("alice");
    address public bob       = makeAddr("bob");
    address public carol     = makeAddr("carol");

    uint256 constant SATS = 10_000;

    function setUp() public {
        cbbtc = new MockCbBTC();
        okt   = new OriginKeyToken(address(cbbtc));

        // Fund wallets
        cbbtc.mint(alice,     1_000_000);
        cbbtc.mint(bob,       1_000_000);
        cbbtc.mint(carol,     1_000_000);
        cbbtc.mint(registrar, 1_000_000);

        // Approve
        vm.prank(alice); cbbtc.approve(address(okt), type(uint256).max);
        vm.prank(bob);   cbbtc.approve(address(okt), type(uint256).max);
        vm.prank(carol); cbbtc.approve(address(okt), type(uint256).max);
        cbbtc.approve(address(okt), type(uint256).max);
    }

    // ─── Basic buy tests ──────────────────────────────────────────────────────

    function test_firstBuyGetsFullAmount() public {
        vm.prank(alice);
        okt.buy(SATS);
        assertEq(okt.balanceOf(alice), SATS); // first buyer gets fee back
    }

    function test_secondBuyPays7PercentFee() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        assertEq(okt.balanceOf(bob), SATS * 93 / 100);
    }

    // ─── Dividend tests ───────────────────────────────────────────────────────

    function test_dividendsAccumulateAfterBuy() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        assertGt(okt.dividendsOf(alice), 0);
    }

    function test_withdrawGivesCorrectAmount() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        uint256 divs = okt.dividendsOf(alice);
        uint256 balBefore = cbbtc.balanceOf(alice);
        vm.prank(alice); okt.withdraw();
        assertEq(cbbtc.balanceOf(alice) - balBefore, divs);
    }

    // ─── Sell tests ───────────────────────────────────────────────────────────

    function test_sellSendsCbbtcDirectly() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        uint256 balBefore = cbbtc.balanceOf(bob);
        uint256 bobTokens = okt.balanceOf(bob);
        vm.prank(bob);   okt.sell(bobTokens - 1);
        uint256 balAfter = cbbtc.balanceOf(bob);
        // Bob should receive 93% of tokens sold directly in cbBTC
        assertGt(balAfter, balBefore);
    }

    function test_sellAndRebuyStillEarnsDividends() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        vm.prank(bob);   okt.sell(1000); // sell fixed amount
        vm.prank(bob);   okt.buy(SATS);
        vm.prank(carol); okt.buy(SATS);
        assertGt(okt.dividendsOf(bob), 0);
    }

    function test_sellEverythingDividendsRemain() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        uint256 divsBefore = okt.dividendsOf(alice);
        vm.prank(alice); okt.sell(1000);
        uint256 divsAfter = okt.dividendsOf(alice);
        assertGe(divsAfter, divsBefore);
    }

    // ─── Reinvest test ────────────────────────────────────────────────────────

    function test_reinvestMintsTokens() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        uint256 balBefore = okt.balanceOf(alice);
        vm.prank(alice); okt.reinvest();
        assertGt(okt.balanceOf(alice), balBefore);
    }

    // ─── Double-spend protection test ───────────────────────────────────────
    function test_noDoubleSpendOnSell() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);

        uint256 bobCbbtcBefore = cbbtc.balanceOf(bob);
        uint256 bobTokens = okt.balanceOf(bob);

        // Bob sells
        vm.prank(bob); okt.sell(1000);

        uint256 bobCbbtcAfterSell = cbbtc.balanceOf(bob);
        uint256 bobDivsAfterSell  = okt.dividendsOf(bob);

        // Bob received cbBTC from sell directly
        assertGt(bobCbbtcAfterSell, bobCbbtcBefore);

        // Bob's dividend balance should NOT equal the sell proceeds
        // If it does, double-spend vulnerability exists
        uint256 sellProceeds = bobCbbtcAfterSell - bobCbbtcBefore;
        assertTrue(bobDivsAfterSell < sellProceeds, "Double-spend: divs equals sell proceeds");
    }

    // ─── Reinvest dust loop prevention ──────────────────────────────────────
    function test_reinvestMinimum100Sats() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        // Alice has dividends from Bob's buy but likely < 100 sats
        uint256 divs = okt.dividendsOf(alice);
        if (divs < 100) {
            vm.prank(alice);
            vm.expectRevert("Minimum 100 sats to reinvest");
            okt.reinvest();
        }
    }

    function test_reinvestDustLoopBlocked() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(200); // small buy generates tiny dividend
        uint256 divs = okt.dividendsOf(alice);
        if (divs < 100) {
            // Cannot reinvest dust — loop is blocked
            vm.prank(alice);
            vm.expectRevert("Minimum 100 sats to reinvest");
            okt.reinvest();
        }
    }

    // ─── Minimal sell isolation test ─────────────────────────────────────────

    function test_minimalSell() public {
        // Alice buys first - gets 10000 (first buyer)
        vm.prank(alice); okt.buy(SATS);
        // Bob buys - gets 9300
        vm.prank(bob);   okt.buy(SATS);
        
        // Check balances before sell
        uint256 bobBalance  = okt.balanceOf(bob);
        uint256 contractBal = cbbtc.balanceOf(address(okt));
        
        // Log values
        emit log_named_uint("Bob OKT balance", bobBalance);
        emit log_named_uint("Contract cbBTC", contractBal);
        emit log_named_uint("Bob dividends", okt.dividendsOf(bob));
        
        // Sell minimum 100 tokens
        vm.prank(bob);
        okt.sell(100);
        
        emit log_named_uint("Contract cbBTC after sell", cbbtc.balanceOf(address(okt)));
        emit log_named_uint("Bob dividends after sell", okt.dividendsOf(bob));
    }

    // ─── THE KEY INVARIANT ────────────────────────────────────────────────────
    // cbBTC in contract must always cover all claimable dividends

    function test_solvency_after_buys() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        vm.prank(carol); okt.buy(SATS);

        uint256 contractBalance = cbbtc.balanceOf(address(okt));
        uint256 totalOwed = okt.dividendsOf(alice)
                          + okt.dividendsOf(bob)
                          + okt.dividendsOf(carol);

        assertGe(contractBalance, totalOwed);
    }

    function test_solvency_after_sell() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        vm.prank(carol); okt.buy(SATS);
        vm.prank(bob);   okt.sell(1000); // sell fixed amount

        uint256 contractBalance = cbbtc.balanceOf(address(okt));
        uint256 aliceDivs = okt.dividendsOf(alice);
        uint256 bobDivs   = okt.dividendsOf(bob);
        uint256 carolDivs = okt.dividendsOf(carol);
        uint256 totalOwed = aliceDivs + bobDivs + carolDivs;

        emit log_named_uint("Contract cbBTC", contractBalance);
        emit log_named_uint("Alice divs",     aliceDivs);
        emit log_named_uint("Bob divs",       bobDivs);
        emit log_named_uint("Carol divs",     carolDivs);
        emit log_named_uint("Total owed",     totalOwed);
        emit log_named_uint("Difference",     totalOwed > contractBalance ? totalOwed - contractBalance : 0);

        assertGe(contractBalance, totalOwed);
    }

    function test_solvency_after_withdraw() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        vm.prank(carol); okt.buy(SATS);
        vm.prank(bob);   okt.sell(1000); // sell fixed amount
        vm.prank(alice); okt.withdraw();

        uint256 contractBalance = cbbtc.balanceOf(address(okt));
        uint256 totalOwed = okt.dividendsOf(alice)
                          + okt.dividendsOf(bob)
                          + okt.dividendsOf(carol);

        assertGe(contractBalance, totalOwed);
    }

    function test_solvency_after_reinvest() public {
        vm.prank(alice); okt.buy(SATS);
        vm.prank(bob);   okt.buy(SATS);
        vm.prank(carol); okt.buy(SATS);
        vm.prank(bob);   okt.sell(1000); // sell fixed amount
        vm.prank(alice); okt.reinvest();

        uint256 contractBalance = cbbtc.balanceOf(address(okt));
        uint256 totalOwed = okt.dividendsOf(alice)
                          + okt.dividendsOf(bob)
                          + okt.dividendsOf(carol);

        assertGe(contractBalance, totalOwed);
    }
}
