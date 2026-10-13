// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/WitnessKey.sol";

contract MockCBBTC {
    string public name = "Mock cbBTC";
    string public symbol = "cbBTC";
    uint8  public constant decimals = 8;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply   += amt;
    }
    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a, "bal");
        require(allowance[f][msg.sender] >= a, "allw");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract Handler is Test {
    WitnessKey public wk;
    MockCBBTC  public cbbtc;
    address[] public actors;
    uint256 public constant MAGNITUDE = 2**64;

    constructor(WitnessKey _wk, MockCBBTC _cbbtc, address[] memory _actors) {
        wk = _wk;
        cbbtc = _cbbtc;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function sumClaimed() public view returns (int256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += wk.claimedOf(actors[i]);
        }
    }

    // The TRUE liability: sum of what every actor could actually pull right now.
    // For each actor: what they could get by selling all tokens (taxed) + claiming
    // all dividends. This is the real "run on the bank" number.
    function totalWithdrawable() public view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            uint256 bal = wk.balanceOf(a);
            // sell payout is taxed (fee stays in contract), so sellable cash =
            // bal - 7% fee. Use same integer math as the contract.
            uint256 sellFee = (bal * wk.DISPOSE_DISTRIBUTION()) / 100;
            uint256 sellCash = bal - sellFee;
            total += sellCash;
            total += wk.recirculationOf(a);
        }
    }

    function buy(uint256 actorSeed, uint256 amt) public {
        address a = _actor(actorSeed);
        amt = bound(amt, 100, 1_000_000);
        cbbtc.mint(a, amt);
        vm.startPrank(a);
        cbbtc.approve(address(wk), amt);
        try wk.acquire(amt, 0) {} catch {}
        vm.stopPrank();
    }

    function sell(uint256 actorSeed, uint256 amt) public {
        address a = _actor(actorSeed);
        uint256 bal = wk.balanceOf(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.startPrank(a);
        try wk.dispose(amt, 0) {} catch {}
        vm.stopPrank();
    }

    function recirculate(uint256 actorSeed) public {
        address a = _actor(actorSeed);
        vm.startPrank(a);
        try wk.recirculate() {} catch {}
        vm.stopPrank();
    }

    function claim(uint256 actorSeed) public {
        address a = _actor(actorSeed);
        vm.startPrank(a);
        try wk.claim() {} catch {}
        vm.stopPrank();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amt) public {
        address from = _actor(fromSeed);
        address to   = _actor(toSeed);
        uint256 bal = wk.balanceOf(from);
        if (bal == 0 || from == to) return;
        amt = bound(amt, 1, bal);
        vm.startPrank(from);
        try wk.transfer(to, amt) {} catch {}
        vm.stopPrank();
    }
}

contract WitnessKeyInvariantTest is Test {
    WitnessKey public wk;
    MockCBBTC  public cbbtc;
    Handler    public handler;
    uint256 public constant MAGNITUDE = 2**64;

    address[] internal actors;

    function setUp() public {
        cbbtc = new MockCBBTC();
        wk = new WitnessKey(address(cbbtc));

        for (uint256 i = 0; i < 5; i++) {
            actors.push(address(uint160(0xA11CE + i)));
        }

        handler = new Handler(wk, cbbtc, actors);
        targetContract(address(handler));
    }

    // ── INVARIANT 1: THE REAL ONE — contract can cover a full "run on the bank" ──
    //
    // This is the property that actually protects money: if EVERY holder sold all
    // their tokens AND claimed all their dividends at once, the contract must have
    // enough cbBTC to pay them all. If this holds, no one can ever be left short —
    // the contract is genuinely solvent no matter the sequence of events.
    //
    // This uses the contract's OWN integer math (via recirculationOf and the same
    // fee formula), so it measures REAL withdrawable value, not an idealized
    // fractional identity. No rounding tolerance needed — this is what people can
    // actually take out.
    //
    function invariant_coversFullBankRun() public view {
        uint256 held = cbbtc.balanceOf(address(wk));
        uint256 owed = handler.totalWithdrawable();
        assertGe(held, owed, "UNDER-RESERVED: cannot cover a full withdrawal");
    }

    // ── INVARIANT 2: the accounting identity holds within tiny rounding dust ──
    //
    // The theoretical identity  held == supply + supply*ppt/M - sum(claimedOf)
    // can't be exact because the contract floor-rounds integer division. So we
    // assert the two sides match within a small bound in EITHER direction. If the
    // drift ever grows beyond a few sats per operation, that signals a real leak;
    // staying tiny proves it's only rounding.
    //
    function invariant_identityWithinRoundingDust() public view {
        uint256 supply = wk.totalSupply();
        uint256 ppt    = wk.recirculationPerToken();

        int256 owed =
            int256(supply)
          + int256((supply * ppt) / MAGNITUDE)
          - handler.sumClaimed();

        int256 held = int256(cbbtc.balanceOf(address(wk)));

        int256 diff = held - owed;
        if (diff < 0) diff = -diff;

        // Allow a few sats of rounding per actor (5 actors, floor-rounding in
        // multiple places). 1000 sats is a hard ceiling far below any real leak
        // but generous enough for pure accumulator dust.
        assertLt(uint256(diff), 1000, "DRIFT TOO LARGE: not just rounding");
    }

    // ── INVARIANT 3: original simple solvency (dividends only) ──
    function invariant_contractIsSolvent() public view {
        uint256 held = cbbtc.balanceOf(address(wk));
        uint256 owedDivs;
        for (uint256 i = 0; i < actors.length; i++) {
            owedDivs += wk.recirculationOf(actors[i]);
        }
        assertGe(held, owedDivs, "INSOLVENT: owed dividends exceed cbBTC held");
    }
}
