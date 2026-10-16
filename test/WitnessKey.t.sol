// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/WitnessKey.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mock cbBTC — included in this file for now
// ─────────────────────────────────────────────────────────────────────────────

contract MockCBBTC {
    string public name = "Coinbase Wrapped BTC";
    string public symbol = "cbBTC";
    uint8 public constant decimals = 8;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount)
    external
    returns (bool)
    {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount)
    external
    returns (bool)
    {
        require(balanceOf[msg.sender] >= amount, "balance");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
    external
    returns (bool)
    {
        require(balanceOf[from] >= amount, "balance");

        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");

        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// WitnessKey test suite
// ─────────────────────────────────────────────────────────────────────────────

contract WitnessKeyTest is Test {
    WitnessKey public wk;
    MockCBBTC public cbbtc;

    address public registrar;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public vault = makeAddr("vault");

    uint256 constant SATS = 10_000;

    function setUp() public {
        registrar = address(this);

        cbbtc = new MockCBBTC();
        wk = new WitnessKey(address(cbbtc));

        // Fund test participants.
        cbbtc.mint(alice, 10_000_000);
        cbbtc.mint(bob, 10_000_000);
        cbbtc.mint(carol, 10_000_000);
        cbbtc.mint(registrar, 10_000_000);

        // Approve WitnessKey to transfer cbBTC.
        vm.prank(alice);
        cbbtc.approve(address(wk), type(uint256).max);

        vm.prank(bob);
        cbbtc.approve(address(wk), type(uint256).max);

        vm.prank(carol);
        cbbtc.approve(address(wk), type(uint256).max);

        cbbtc.approve(address(wk), type(uint256).max);
    }

    // ─── Basic buy tests ──────────────────────────────────────────────────────
    // Acquisition

    function test_firstBuyGetsFullAmount() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);
        assertEq(wk.balanceOf(alice), SATS); // first buyer gets fee back
    }

    function test_secondBuyPays7PercentFee() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        assertEq(wk.balanceOf(bob), SATS * 93 / 100);
        assertGt(wk.recirculationOf(alice), 0);
    }

    function test_AcquireBelowMinimumReverts() public {
        vm.prank(alice);
        vm.expectRevert("Minimum 100 sats");
        wk.acquire(99, 0);
    }

    function test_AcquireAboveMaximumReverts() public {
        vm.prank(alice);
        vm.expectRevert("Maximum 1,000,000 sats per acquire");
        wk.acquire(1_000_001, 0);
    }

    // MAX_ACQUIRE limits a single call, not cumulative acquisitions.
    function test_MaxAcquireAppliesPerCallOnly() public {
        vm.startPrank(alice);

        wk.acquire(wk.MAX_ACQUIRE(), 0);
        wk.acquire(wk.MAX_ACQUIRE(), 0);

        vm.stopPrank();

        assertEq(
            wk.balanceOf(alice),
            1_000_000 + (1_000_000 * 93 / 100)
        );
    }

    function test_AcquireEnforcesMinimumOutput() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        vm.expectRevert("Slippage: too few tokens");
        wk.acquire(SATS, SATS);
    }

    // ─── Recirculation tests ──────────────────────────────────────────────────
    // Recirculation and claims

    function test_recirculateMintsTokens() public {
        // Each acquisition must be <= 1,000,000 sats.
        vm.prank(alice);
        wk.acquire(1_000_000, 0);

        vm.prank(bob);
        wk.acquire(1_000_000, 0);

        uint256 claimable = wk.recirculationOf(alice);
        assertGe(claimable, 100);

        uint256 balanceBefore = wk.balanceOf(alice);
        uint256 supplyBefore = wk.totalSupply();

        vm.prank(alice);
        wk.recirculate();

        assertEq(wk.balanceOf(alice), balanceBefore + claimable);
        assertEq(wk.totalSupply(), supplyBefore + claimable);
        // Allow for dust / integer rounding.
        assertEq(wk.recirculationOf(alice), 1);
    }

    function test_claimGivesCorrectAmount() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        uint256 divs = wk.recirculationOf(alice);
        uint256 balBefore = cbbtc.balanceOf(alice);

        vm.prank(alice);
        wk.claim();

        uint256 balAfter = cbbtc.balanceOf(alice);
        uint256 remainingDivs = wk.recirculationOf(alice);

        assertEq(balAfter - balBefore, divs, "Claim payout mismatch");
        assertEq(remainingDivs, 0, "Rewards remain after claim");
    }

    function test_ClaimWithoutRewardsReverts() public {
        vm.prank(alice);
        vm.expectRevert("No recirculation to claim");
        wk.claim();
    }

    // ─── Reinvest dust loop prevention ────────────────────────────────────────

    function test_recirculateBelowMinimumReverts() public {
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(bob);
        wk.acquire(1_000, 0);

        assertLt(wk.recirculationOf(alice), 100);

        vm.prank(alice);
        vm.expectRevert("Minimum 100 sats to recirculate");
        wk.recirculate();
    }

    function test_recirculateDustLoopBlocked() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(200, 0);

        assertLt(wk.recirculationOf(alice), 100);

        vm.prank(alice);
        vm.expectRevert("Minimum 100 sats to recirculate");
        wk.recirculate();
    }

    // ─── Sell tests ───────────────────────────────────────────────────────────
    // Disposal

    function test_sellSendsCbbtcDirectly() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        uint256 beforeBalance = cbbtc.balanceOf(bob);
        uint256 bobTokens = wk.balanceOf(bob);

        vm.prank(bob);
        wk.dispose(bobTokens - 1, 0);

        uint256 received = cbbtc.balanceOf(bob) - beforeBalance;

        // Bob should receive cbBTC directly from the sale.
        assertGt(received, 0);
    }

    function test_DisposeCharges7PercentDistribution() public {
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(bob);
        wk.acquire(1_000, 0);

        uint256 beforeBalance = cbbtc.balanceOf(alice);

        vm.prank(alice);
        wk.dispose(500, 0);

        assertEq(cbbtc.balanceOf(alice) - beforeBalance, 465);
    }

    function test_CannotDisposeEntireSupply() public {
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(alice);
        vm.expectRevert("Cannot dispose entire supply");
        wk.dispose(1_000, 0);
    }

    function test_DisposeBelowMinimumReverts() public {
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(alice);
        vm.expectRevert("Minimum 100 sats to dispose");
        wk.dispose(99, 0);
    }

    function test_DisposeEnforcesMinimumPayout() public {
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(bob);
        wk.acquire(1_000, 0);

        vm.prank(alice);
        vm.expectRevert("Slippage: too little cbBTC");
        wk.dispose(500, 466);
    }

    function test_sellAndRebuyStillEarnsRecirculation() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.dispose(1_000, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        vm.prank(carol);
        wk.acquire(SATS, 0);

        assertGt(wk.recirculationOf(bob), 0);
    }

    function test_sellEverythingRecirculationRemains() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        uint256 divsBefore = wk.recirculationOf(alice);

        vm.prank(alice);
        wk.dispose(1_000, 0);

        uint256 divsAfter = wk.recirculationOf(alice);

        assertGe(divsAfter, divsBefore);
    }

    // ─── Double-spend protection test ─────────────────────────────────────────

    function test_noDoubleSpendOnSell() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        uint256 beforeBalance = cbbtc.balanceOf(bob);

        vm.prank(bob);
        wk.dispose(1_000, 0);

        uint256 proceeds = cbbtc.balanceOf(bob) - beforeBalance;
        uint256 remainingDivs = wk.recirculationOf(bob);

        assertGt(proceeds, 0);
        assertLt(
            remainingDivs,
            proceeds,
            "Recirculation unexpectedly equals sell proceeds"
        );
    }

    // ─── Minimal sell isolation test ──────────────────────────────────────────

    function test_minimalSell() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        uint256 beforeBalance = cbbtc.balanceOf(bob);

        vm.prank(bob);
        wk.dispose(100, 0);

        assertEq(cbbtc.balanceOf(bob) - beforeBalance, 93);
    }

    // ─── Transfer tests ──────────────────────────────────────────────────────

    function test_ZeroTransferReverts() public {
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(alice);
        vm.expectRevert("Zero tokens");
        wk.transfer(bob, 0);
    }

    function test_TransferToZeroAddressReverts() public {
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(alice);
        vm.expectRevert("Zero address");
        wk.transfer(address(0), 100);
    }

    function test_TransferMovesBalances() public {
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(bob);
        wk.acquire(1_000, 0);

        vm.prank(alice);
        wk.transfer(bob, 200);

        assertEq(wk.balanceOf(alice), 800);
        assertEq(wk.balanceOf(bob), 1_130);
    }

    function test_TransferPreservesAccruedRewardsWithinRoundingDust()
    public
    {
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(bob);
        wk.acquire(1_000, 0);

        uint256 aliceClaimBefore = wk.recirculationOf(alice);

        vm.prank(alice);
        wk.transfer(bob, 200);

        uint256 aliceClaimAfter = wk.recirculationOf(alice);

        // Transferring tokens should not erase previously accrued rewards.
        // Integer division can introduce a small rounding difference.
        assertApproxEqAbs(aliceClaimAfter, aliceClaimBefore, 1);

        // Bob should not inherit Alice's entire historical claim.
        assertLe(wk.recirculationOf(bob), 1);
    }

    function test_TransferInsufficientBalanceReverts() public {
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(alice);
        vm.expectRevert("Insufficient balance");
        wk.transfer(bob, 1_001);
    }

    // ─── Vault registration and ordinal tracking ──────────────────────────────

    function test_RegistrarCanInscribe() public {
        wk.inscribe(vault, bytes32("asset1"), 500, 42, "insc1");

        assertTrue(wk.isVault(vault));
        assertEq(wk.balanceOf(vault), 500);
        assertEq(wk.vaultOrdinal(vault), 42);
        assertTrue(wk.vaultHasOrdinal(vault));
        assertEq(wk.vaultRegistry(vault), bytes32("asset1"));
    }

    function test_OnlyRegistrarCanInscribe() public {
        vm.prank(alice);
        vm.expectRevert("Not vault registrar");

        wk.inscribe(vault, bytes32("asset1"), 500, 42, "insc1");
    }

    function test_DuplicateVaultRegistrationReverts() public {
        wk.inscribe(vault, bytes32("asset1"), 500, 42, "insc1");

        vm.expectRevert("Vault: already registered");
        wk.inscribe(vault, bytes32("asset2"), 500, 43, "insc2");
    }

    function test_DuplicateOrdinalRegistrationReverts() public {
        wk.inscribe(vault, bytes32("asset1"), 500, 42, "insc1");

        address vault2 = makeAddr("vault2");

        vm.expectRevert("Ordinal: already registered");
        wk.inscribe(vault2, bytes32("asset2"), 500, 42, "insc2");
    }

    function test_AlreadyMovedOrdinalRegistrationReverts() public {
        // The oracle can record a movement before a vault is registered.
        wk.reportOrdinalMoved(42, bytes32("btcTx"));

        address vault2 = makeAddr("vault2");

        vm.expectRevert("Ordinal: already moved");
        wk.inscribe(vault2, bytes32("asset2"), 500, 42, "insc2");
    }

    // ─── Ordinal movement and oracle tests ────────────────────────────────────

    function test_OracleCanReportMovedAndSweep() public {
        wk.inscribe(vault, bytes32("asset1"), 500, 42, "insc1");

        wk.reportOrdinalMoved(42, bytes32("btcTxid123"));

        (,, bool moved,,) = wk.vaultOrdinalStatus(vault);

        assertTrue(moved);
        assertTrue(wk.vaultHasBeenSwept(vault));
        assertTrue(wk.ordinalHasBeenMoved(42));
        assertEq(wk.ordinalMoveTxid(42), bytes32("btcTxid123"));
    }

    function test_OnlyOracleCanReportMoved() public {
        wk.inscribe(vault, bytes32("asset1"), 500, 42, "insc1");

        vm.prank(alice);
        vm.expectRevert("Not ordinal oracle");
        wk.reportOrdinalMoved(42, bytes32("btcTx"));
    }

    function test_CannotReportInvalidOrdinal() public {
        vm.expectRevert("Invalid ordinal number");
        wk.reportOrdinalMoved(0, bytes32("btcTx"));
    }

    function test_CannotReportMissingTxid() public {
        vm.expectRevert("Missing BTC txid");
        wk.reportOrdinalMoved(42, bytes32(0));
    }

    function test_CannotReportSameOrdinalTwice() public {
        wk.reportOrdinalMoved(42, bytes32("btcTx"));

        vm.expectRevert("Already reported as moved");
        wk.reportOrdinalMoved(42, bytes32("btcTx2"));
    }

    // ─── Vault sweep marker ───────────────────────────────────────────────────

    function test_TransferFromVaultMarksItSwept() public {
        wk.inscribe(vault, bytes32("asset1"), 500, 42, "insc1");

        vm.prank(vault);
        wk.transfer(alice, 100);

        assertTrue(wk.vaultHasBeenSwept(vault));
    }

    function test_DisposeFromVaultMarksItSwept() public {
        wk.inscribe(vault, bytes32("asset1"), 500, 42, "insc1");

        // Ensure supply remains after disposal.
        vm.prank(alice);
        wk.acquire(1_000, 0);

        vm.prank(vault);
        wk.dispose(100, 0);

        assertTrue(wk.vaultHasBeenSwept(vault));
    }

    // ─── THE KEY INVARIANT ────────────────────────────────────────────────────
    // cbBTC in contract must always cover all claimable recirculation.

    function test_solvency_after_buys() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        vm.prank(carol);
        wk.acquire(SATS, 0);

        uint256 contractBalance = cbbtc.balanceOf(address(wk));

        uint256 totalOwed =
            wk.recirculationOf(alice)
            + wk.recirculationOf(bob)
            + wk.recirculationOf(carol);

        assertGe(contractBalance, totalOwed);
    }

    function test_solvency_after_sell() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        vm.prank(carol);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.dispose(1_000, 0);

        uint256 contractBalance = cbbtc.balanceOf(address(wk));

        uint256 totalOwed =
            wk.recirculationOf(alice)
            + wk.recirculationOf(bob)
            + wk.recirculationOf(carol);

        assertGe(contractBalance, totalOwed);
    }

    function test_solvency_after_claim() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        vm.prank(carol);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.dispose(1_000, 0);

        vm.prank(alice);
        wk.claim();

        uint256 contractBalance = cbbtc.balanceOf(address(wk));

        uint256 totalOwed =
            wk.recirculationOf(alice)
            + wk.recirculationOf(bob)
            + wk.recirculationOf(carol);

        assertGe(contractBalance, totalOwed);
    }

    function test_solvency_after_recirculate() public {
        vm.prank(alice);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.acquire(SATS, 0);

        vm.prank(carol);
        wk.acquire(SATS, 0);

        vm.prank(bob);
        wk.dispose(1_000, 0);

        uint256 claimable = wk.recirculationOf(alice);
        assertGe(claimable, 100);

        vm.prank(alice);
        wk.recirculate();

        uint256 contractBalance = cbbtc.balanceOf(address(wk));

        uint256 totalOwed =
            wk.recirculationOf(alice)
            + wk.recirculationOf(bob)
            + wk.recirculationOf(carol);

        assertGe(contractBalance, totalOwed);
    }
}