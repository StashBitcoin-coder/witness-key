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

contract OKTHandler is Test {
    MockCbBTC cbbtc;
    OriginKeyToken okt;

    uint16 holdersN = 10;
    address[] holders; // including vaults
    uint256 constant MAGNITUDE = 2 ** 64;
    mapping(address => uint256) scaledDivsOf;

    constructor() {
        cbbtc = new MockCbBTC();
        okt = new OriginKeyToken(address(cbbtc));

        for (uint16 i = 0; i < holdersN; i++) {
            address holder = i == 0 ? address(this) : makeAddr(vm.toString(i));
            holders.push(holder);
            cbbtc.mint(holder, 1e12);
            vm.prank(holder);
            cbbtc.approve(address(okt), type(uint256).max);
        }

        okt.buy(100, 0);
    }

    function buy(uint256 senderN, uint256 cbbtcAmount) public {
        address sender = holders[senderN % holdersN];
        cbbtcAmount = cbbtcAmount % 999901 + 100;
        uint256 totalSupply = okt.totalSupply();
        uint256 addScaledDivs = cbbtcAmount * 7 / 100 * MAGNITUDE;
        for (uint16 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            scaledDivsOf[holder] += addScaledDivs * okt.balanceOf(holder) / totalSupply;
        }

        vm.prank(sender);
        okt.buy(cbbtcAmount, 0);
    }

    function sell(uint256 senderN, uint256 oktAmount) public {
        address sender = holders[senderN % holdersN];
        vm.assume(okt.balanceOf(sender) >= 100);
        oktAmount = oktAmount % (okt.balanceOf(sender) - 99) + 100;
        uint256 totalSupply = okt.totalSupply();
        vm.assume(oktAmount < totalSupply);
        uint256 addScaledDivs = oktAmount * 7 / 100 * MAGNITUDE;

        vm.prank(sender);
        okt.sell(oktAmount, 0);

        for (uint16 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            scaledDivsOf[holder] += addScaledDivs * okt.balanceOf(holder) / totalSupply;
        }
    }

    function transfer(uint256 senderN, uint256 recipientN, uint256 oktAmount) public {
        address sender = holders[senderN % holdersN];
        address recipient = holders[recipientN % holdersN];
        vm.assume(okt.balanceOf(sender) > 0);
        oktAmount = oktAmount % okt.balanceOf(sender) + 1;

        vm.prank(sender);
        okt.transfer(recipient, oktAmount);
    }

    function withdraw(uint256 senderN) public {
        address sender = holders[senderN % holdersN];
        vm.assume(okt.dividendsOf(sender) > 0);
        scaledDivsOf[sender] = 0;

        vm.prank(sender);
        okt.withdraw();
    }

    function reinvest(uint256 senderN) public {
        address sender = holders[senderN % holdersN];
        vm.assume(okt.dividendsOf(sender) >= 100);
        scaledDivsOf[sender] = 0;

        vm.prank(sender);
        okt.reinvest();
    }

    function inscribe(
        address vault,
        bytes32 assetId,
        uint256 cbbtcAmount,
        uint256 ordinalNumber,
        string calldata inscriptionId
    ) public {
        vm.assume(vault != address(0));
        vm.assume(!okt.isVault(vault));
        vm.assume(assetId != bytes32(0));
        cbbtcAmount = cbbtcAmount % 999901 + 100;
        if (ordinalNumber > 0) {
            vm.assume(okt.ordinalVaultAddress(ordinalNumber) == address(0));
        }
        uint256 totalSupply = okt.totalSupply();
        uint256 addScaledDivs = cbbtcAmount * 7 / 100 * MAGNITUDE;
        for (uint16 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            scaledDivsOf[holder] += addScaledDivs * okt.balanceOf(holder) / totalSupply;
        }
        holders.push(vault);

        okt.inscribe(vault, assetId, cbbtcAmount, ordinalNumber, inscriptionId);
    }

    function checkDivs() public view {
        uint256 sumOkt = 0;
        uint256 sumDivs = 0;
        for (uint16 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            sumOkt += okt.balanceOf(holder);

            uint256 divs = okt.dividendsOf(holder);
            assertApproxEqAbs(divs, scaledDivsOf[holder] / MAGNITUDE, 3000);
            sumDivs += divs;
        }

        assertEq(okt.totalSupply(), sumOkt);
        assertApproxEqAbs(cbbtc.balanceOf(address(okt)), sumOkt + sumDivs, 10000);
    }
}

/// forge-config: default.invariant.runs = 1
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail_on_revert = true
contract OKTTest is Test {
    OKTHandler handler;

    function setUp() public {
        handler = new OKTHandler();
        targetContract(address(handler));
    }

    function invariant_divs() public view {
        handler.checkDivs();
    }
}
