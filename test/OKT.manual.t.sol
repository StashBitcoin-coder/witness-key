pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OriginKeyToken} from "../src/OriginKeyToken.sol";

contract MockCbBTC is ERC20 {
    constructor() ERC20("Coinbase Wrapped BTC", "cbBTC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

contract OKTManualTest is Test {
    MockCbBTC cbbtc;
    OriginKeyToken okt;

    address o = address(this);
    address a = makeAddr("a");
    address b = makeAddr("b");

    function setUp() public {
        cbbtc = new MockCbBTC();
        okt = new OriginKeyToken(address(cbbtc));

        cbbtc.mint(o, 1000000);
        cbbtc.mint(a, 1000000);
        cbbtc.mint(b, 1000000);

        cbbtc.approve(address(okt), type(uint256).max);
        vm.prank(a);
        cbbtc.approve(address(okt), type(uint256).max);
        vm.prank(b);
        cbbtc.approve(address(okt), type(uint256).max);
    }

    function test() public {
        assertCbbtcBalance(1000000, 1000000, 1000000, 0);
        assertOktBalance(0, 0, 0, 0);
        assertDividends(0, 0, 0);

        vm.prank(a);
        okt.buy(1000, 0);
        assertCbbtcBalance(1000000, 999000, 1000000, 1000);
        assertOktBalance(0, 1000, 0, 1000);
        assertDividends(0, 0, 0);

        vm.prank(a);
        okt.transfer(b, 100);
        assertCbbtcBalance(1000000, 999000, 1000000, 1000);
        assertOktBalance(0, 900, 100, 1000);
        assertDividends(0, 0, 0);

        vm.prank(b);
        okt.buy(1000, 0);
        assertCbbtcBalance(1000000, 999000, 999000, 2000);
        assertOktBalance(0, 900, 1030, 1930);
        assertDividends(0, 62, 7);

        vm.prank(b);
        okt.transfer(b, 200);
        assertCbbtcBalance(1000000, 999000, 999000, 2000);
        assertOktBalance(0, 900, 1030, 1930);
        assertDividends(0, 62, 7);

        vm.prank(b);
        okt.transfer(a, 250);
        assertCbbtcBalance(1000000, 999000, 999000, 2000);
        assertOktBalance(0, 1150, 780, 1930);
        assertDividends(0, 63, 6);

        vm.prank(a);
        okt.sell(150, 0);
        assertCbbtcBalance(1000000, 999140, 999000, 1860);
        assertOktBalance(0, 1000, 780, 1780);
        assertDividends(0, 68, 10);

        okt.buy(30000, 0);
        assertCbbtcBalance(970000, 999140, 999000, 31860);
        assertOktBalance(27900, 1000, 780, 29680);
        assertDividends(0, 1248, 931);

        vm.prank(a);
        okt.reinvest();
        assertCbbtcBalance(970000, 999140, 999000, 31860);
        assertOktBalance(27900, 2248, 780, 30928);
        assertDividends(0, 1, 931);

        vm.prank(b);
        okt.sell(180, 0);
        assertCbbtcBalance(970000, 999140, 999168, 31692);
        assertOktBalance(27900, 2248, 600, 30748);
        assertDividends(11, 2, 930);

        okt.buy(18000, 0);
        assertCbbtcBalance(952000, 999140, 999168, 49692);
        assertOktBalance(44640, 2248, 600, 47488);
        assertDividends(1155, 94, 955);

        vm.prank(a);
        okt.buy(180000, 0);
        assertCbbtcBalance(952000, 819140, 999168, 229692);
        assertOktBalance(44640, 169648, 600, 214888);
        assertDividends(12999, 690, 1114);

        okt.withdraw();
        assertCbbtcBalance(964999, 819140, 999168, 216693);
        assertOktBalance(44640, 169648, 600, 214888);
        assertDividends(0, 690, 1114);

        vm.prank(a);
        okt.reinvest();
        assertCbbtcBalance(964999, 819140, 999168, 216693);
        assertOktBalance(44640, 170338, 600, 215578);
        assertDividends(0, 1, 1114);

        okt.sell(44640, 0);
        assertCbbtcBalance(1006515, 819140, 999168, 175177);
        assertOktBalance(0, 170338, 600, 170938);
        assertDividends(0, 3114, 1125);

        vm.prank(a);
        okt.sell(170338, 0);
        assertCbbtcBalance(1006515, 977555, 999168, 16762);
        assertOktBalance(0, 0, 600, 600);
        assertDividends(0, 3114, 13048);

        vm.prank(b);
        okt.sell(599, 0);
        assertCbbtcBalance(1006515, 977555, 999726, 16204);
        assertOktBalance(0, 0, 1, 1);
        assertDividends(0, 3114, 13088);

        vm.prank(b);
        okt.withdraw();
        assertCbbtcBalance(1006515, 977555, 1012814, 3116);
        assertOktBalance(0, 0, 1, 1);
        assertDividends(0, 3114, 0);

        vm.prank(a);
        okt.withdraw();
        assertCbbtcBalance(1006515, 980669, 1012814, 2);
        assertOktBalance(0, 0, 1, 1);
        assertDividends(0, 0, 0);
    }

    function assertCbbtcBalance(uint256 cbbtcO, uint256 cbbtcA, uint256 cbbtcB, uint256 cbbtcOkt) private view {
        assertEq(cbbtc.balanceOf(o), cbbtcO);
        assertEq(cbbtc.balanceOf(a), cbbtcA);
        assertEq(cbbtc.balanceOf(b), cbbtcB);
        assertEq(cbbtc.balanceOf(address(okt)), cbbtcOkt);
    }

    function assertOktBalance(uint256 oktO, uint256 oktA, uint256 oktB, uint256 oktTotal) private view {
        assertEq(okt.balanceOf(o), oktO);
        assertEq(okt.balanceOf(a), oktA);
        assertEq(okt.balanceOf(b), oktB);
        assertEq(okt.totalSupply(), oktTotal);
    }

    function assertDividends(uint256 divO, uint256 divA, uint256 divB) private view {
        assertEq(okt.dividendsOf(o), divO);
        assertEq(okt.dividendsOf(a), divA);
        assertEq(okt.dividendsOf(b), divB);
    }
}
