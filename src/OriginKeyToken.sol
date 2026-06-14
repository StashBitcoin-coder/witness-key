// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title  Origin Key Token (OKT)
 * @notice cbBTC-backed token for RealWorldInscriptions.com / AnalogBitcoin.com
 *
 * ─── Invention & Attribution ─────────────────────────────────────────────────
 *
 *  DIVIDEND MATH — ATTRIBUTION CHAIN
 *
 *  Dr. Jochen Hoenicke — Foundation
 *  Computer scientist and Trezor hardware wallet developer. Created the
 *  original "PonziToken" on the Ethereum testnet as a satirical experiment
 *  to demonstrate smart contract transparency. His linear bonding curve
 *  concept is the mathematical foundation this entire system builds upon.
 *  He never intended it for production — but the math was sound.
 *  https://test.jochen-hoenicke.de/crypto/ponzitoken/
 *
 *  Team JUST — PoWH3D
 *  Built Proof of Weak Hands 3D (PoWH3D) from Hoenicke's original concept,
 *  bringing the bonding curve model into production on Ethereum mainnet.
 *
 *  aqoleg — PITcoin
 *  Refined and reimplemented the per-share accumulator dividend distribution
 *  pattern in PITcoin. This contract follows that pattern exactly.
 *  Full credit to aqoleg.
 *  https://github.com/aqoleg/pitcoin
 *
 *  EVERYTHING ELSE
 *  The following concepts, systems, and intellectual property are the
 *  original invention of Michael James Slattery and Lora Green, authors of this contract:
 *
 *  Physical concept:
 *  - Analog Bitcoin — physical art destroyed to redeem digital assets
 *  - SeedPod — embedding a wallet private key inside physical art
 *  - NFC tap verification of physical assets on chain
 *  - Read-only NFC tag as a permanent tamper seal
 *  - Two-wallet system — Ordinal wallet and OKT vault sharing one SeedPod
 *
 *  On-chain architecture:
 *  - Vault registration system linking physical art to blockchain permanently
 *  - Ordinal oracle — reporting Bitcoin Ordinal movement on Base
 *  - VaultSwept event — tamper detection across all exit paths
 *  - Series pieces with optional Ordinal — ordinalNumber = 0 pattern
 *  - cbBTC as reserve asset — Bitcoin-denominated yield on physical art
 *  - inscribe() — cbBTC in, OKT sealed in vault, fee distributed to holders
 *
 *  Economic model:
 *  - 1 OKT = 1 sat fixed price peg — no AMM, no speculation, no extraction
 *  - Physical art earns cbBTC yield while hanging on a wall
 *  - Destroying art to redeem digital assets — the redemption mechanism
 *  - cbBTC dividends from every trade distributed to all holders and vaults
 *
 *  Brands & intellectual property:
 *  - Immutable Editions
 *  - Analog Bitcoin
 *  - Real World Inscriptions
 *  - Origin Key Token (OKT)
 *  - The Key Exchange / TheKeyExchange.io
 *  - SeedPod
 *  - "Where Provenance and Interest meet Market Integrity"
 *
 * ─── Network ─────────────────────────────────────────────────────────────────
 *  Base Sepolia testnet cbBTC : 0xcbB7C0006F23900c38EB856149F799620fcb8A4a
 *  Base mainnet        cbBTC : 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf
 *
 * ─── Fixed Price ─────────────────────────────────────────────────────────────
 *  1 Satoshi (1 cbBTC unit, 8 decimals) = 1 OKT token (0 decimals).
 *  Because the peg is 1:1, token units and sat units are interchangeable
 *  throughout the dividend math — no price conversion needed.
 *
 * ─── Fees ────────────────────────────────────────────────────────────────────
 *  Buy     : 7% redistributed to all holders as cbBTC dividends
 *  Sell    : 7% redistributed to all holders as cbBTC dividends
 *  Inscribe: 7% redistributed to all holders as cbBTC dividends
 *  Reinvest: 0% — compounding is always free
 *  Transfer: 0% — always feeless
 *
 * ─── Minimum amounts ─────────────────────────────────────────────────────────
 *  Buy/Inscribe minimum: 100 sats
 *
 * ─── Dividend math ───────────────────────────────────────────────────────────
 *  Follows PITcoin by aqoleg exactly. Key invariant:
 *
 *  cbbtcInContract = totalSupply
 *                  + totalSupply * profitPerToken / MAGNITUDE
 *                  - sum(payoutsOf)
 *
 *  Every function maintains this equation. The sell function is the most
 *  critical — it must use signedSub with taxed included in payout, and
 *  must distribute the fee AFTER updating payoutsOf. This is PITcoin exact.
 *
 *  payoutsOf is int256 — it CAN and WILL go negative. This is correct.
 *  DO NOT change to uint256. DO NOT change signedSub to signedAdd in sell.
 *
 * ─── Immutability ────────────────────────────────────────────────────────────
 *  No owner. No admin. No governance. No upgrades. NO INTERVENTION.
 *
 * ─── Vault System ────────────────────────────────────────────────────────────
 *  vaultRegistrar : deployer only — can call inscribe()
 *  ordinalOracle  : deployer only — can call reportOrdinalMoved()
 *  Both set at deploy time. Permanently immutable. Zero financial control.
 *  ordinalNumber = 0 is valid — for series pieces without an Ordinal.
 *
 *  VaultSwept   : fires when ANY value leaves a registered vault — permanent
 *  OrdinalMoved : fires when oracle reports Bitcoin Ordinal has moved
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract OriginKeyToken is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Token metadata ───────────────────────────────────────────────────────
    string  public constant name     = "Origin Key Token";
    string  public constant symbol   = "OKT";
    uint8   public constant decimals = 0;

    // ─── Reserve asset ────────────────────────────────────────────────────────
    IERC20 public immutable CBBTC;

    // ─── Supply ───────────────────────────────────────────────────────────────
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // ─── Fees & minimums ──────────────────────────────────────────────────────
    uint256 public constant BUY_FEE      = 7;
    uint256 public constant SELL_FEE     = 7;
    uint256 public constant INSCRIBE_FEE = 7;
    uint256 public constant MIN_SATS     = 100;
    uint256 public constant MIN_SELL     = 100;   // prevents sell-fee rounding bypass
    uint256 public constant MAX_BUY      = 1_000_000; // 0.01 BTC per transaction

    // ─── Dividend accumulator — PITcoin exact ────────────────────────────────
    // payoutsOf MUST be int256. MUST use signedSub in sell. Never change this.
    // The accounting equation requires payoutsOf to go negative in normal use.
    uint256 public constant MAGNITUDE = 2**64;
    uint256 public profitPerToken;
    mapping(address => int256) public payoutsOf;

    // ─── Vault registrar ──────────────────────────────────────────────────────
    address public immutable vaultRegistrar;
    mapping(address => bytes32) public vaultRegistry; // bytes32(0) means no vault
    mapping(address => bool)    public vaultHasBeenSwept;
    mapping(address => uint256) public vaultOrdinal;
    mapping(address => bool)    public vaultHasOrdinal;
    mapping(address => string)  public vaultInscriptionId; // Bitcoin Ordinal inscription ID for content rendering

    // ─── Ordinal oracle ───────────────────────────────────────────────────────
    address public immutable ordinalOracle;
    mapping(uint256 => bool)    public ordinalHasBeenMoved;
    mapping(uint256 => uint256) public ordinalMovedTimestamp;
    mapping(uint256 => address) public ordinalVaultAddress;

    // ─── Events ───────────────────────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Buy(address indexed buyer, uint256 cbbtcIn, uint256 tokensOut);
    event Sell(address indexed seller, uint256 tokensIn, uint256 cbbtcOut);
    event Withdraw(address indexed user, uint256 cbbtcAmount);
    event Reinvest(address indexed user, uint256 tokensOut);
    event VaultRegistered(
        address indexed vault,
        bytes32 indexed assetId,
        uint256 ordinalNumber,
        bool    hasOrdinal,
        uint256 oktEmbedded,
        uint256 timestamp
    );
    event VaultSwept(
        address indexed vault,
        bytes32 indexed assetId,
        uint256 amountMoved,
        uint256 timestamp
    );
    event OrdinalMoved(
        uint256 indexed ordinalNumber,
        address indexed vault,
        bytes32 indexed assetId,
        uint256 timestamp
    );

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address _cbbtc) {
        require(_cbbtc != address(0), "cbBTC: zero address");
        require(IERC20Metadata(_cbbtc).decimals() == 8, "cbBTC: expected 8 decimals");
        CBBTC          = IERC20(_cbbtc);
        vaultRegistrar = msg.sender;
        ordinalOracle  = msg.sender;
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyRegistrar() {
        require(msg.sender == vaultRegistrar, "Not vault registrar");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == ordinalOracle, "Not ordinal oracle");
        _;
    }

    // ─── Signed math helpers ──────────────────────────────────────────────────
    function _signedAdd(int256 a, uint256 b) internal pure returns (int256) {
        return a + int256(b);
    }

    function _signedSub(int256 a, uint256 b) internal pure returns (int256) {
        return a - int256(b);
    }

    // ─── Distribute fee ───────────────────────────────────────────────────────
    function _distributeFee(uint256 fee) internal {
        if (totalSupply > 0 && fee > 0) {
            profitPerToken += (fee * MAGNITUDE) / totalSupply;
        }
    }

    // ─── Vault sweep check ───────────────────────────────────────────────────
    function _checkVaultSweep(address vault, uint256 amount) internal {
        if (vaultRegistry[vault] != bytes32(0) && !vaultHasBeenSwept[vault]) {
            vaultHasBeenSwept[vault] = true;
            emit VaultSwept(vault, vaultRegistry[vault], amount, block.timestamp);
        }
    }

    // ─── Buy ──────────────────────────────────────────────────────────────────
    // PITcoin exact — fee returned to first buyer, distributed to holders after
    function buy(uint256 cbbtcAmount) external nonReentrant {
        require(cbbtcAmount >= MIN_SATS, "Minimum 100 sats");
        require(cbbtcAmount <= MAX_BUY, "Maximum 1,000,000 sats per buy");
        CBBTC.safeTransferFrom(msg.sender, address(this), cbbtcAmount);

        uint256 fee    = (cbbtcAmount * BUY_FEE) / 100;
        uint256 tokens = cbbtcAmount - fee;

        if (totalSupply > 0) {
            _distributeFee(fee);
        } else {
            tokens += fee; // first buyer gets fee back
        }

        totalSupply           += tokens;
        balanceOf[msg.sender] += tokens;
        emit Transfer(address(0), msg.sender, tokens);

        // PITcoin exact — set baseline to current profitPerToken * tokens
        payoutsOf[msg.sender] = _signedAdd(
            payoutsOf[msg.sender],
            (tokens * profitPerToken) / MAGNITUDE
        );

        emit Buy(msg.sender, cbbtcAmount, tokens);
    }

    // ─── Sell — PITcoin exact ─────────────────────────────────────────────────
    //
    // The accounting equation that must hold at all times:
    //   cbbtcInContract = totalSupply + totalSupply*ppt/M - sum(payoutsOf)
    //
    // When selling `tokens` for `taxed` cbBTC:
    //   - totalSupply decreases by tokens
    //   - cbbtcInContract decreases by taxed
    //   - Direct cbBTC payment handles `taxed`
    //   - payoutsOf must decrease only by the burned-token dividend baseline:
    //     (tokens * profitPerToken) / MAGNITUDE
    //   - Including `taxed` in payoutsOf would double-count seller proceeds
    //   - _distributeFee happens AFTER payoutsOf update
    //
    // DO NOT change signedSub to signedAdd — that breaks dividend distribution
    // for any wallet that sells and rebuys. PITcoin uses signedSub. Always.
    //
    function sell(uint256 tokens) external nonReentrant {
        require(tokens >= MIN_SELL,                  "Minimum 100 sats to sell");
        require(balanceOf[msg.sender] >= tokens, "Insufficient balance");
        require(totalSupply > tokens,             "Cannot sell entire supply");

        _checkVaultSweep(msg.sender, tokens);

        uint256 fee   = (tokens * SELL_FEE) / 100;
        uint256 taxed = tokens - fee;

        // 1. Burn tokens
        balanceOf[msg.sender] -= tokens;
        totalSupply            -= tokens;
        emit Transfer(msg.sender, address(0), tokens);

        // 2. Release ONLY the dividend baseline for burned tokens.
        // DO NOT include taxed here — safeTransfer below handles payment.
        // Including taxed would allow double-spend: user gets cbBTC via
        // safeTransfer AND via withdraw() on the inflated dividend balance.
        uint256 payout = (tokens * profitPerToken) / MAGNITUDE;
        payoutsOf[msg.sender] = _signedSub(payoutsOf[msg.sender], payout);

        // 3. Distribute fee AFTER payoutsOf update
        _distributeFee(fee);

        // 4. Send cbBTC directly to seller
        CBBTC.safeTransfer(msg.sender, taxed);
        emit Sell(msg.sender, tokens, taxed);
    }

    // ─── Transfer — zero fee ──────────────────────────────────────────────────
    function transfer(address to, uint256 tokens) external returns (bool) {
        require(to != address(0),                "Zero address");
        require(tokens > 0,                      "Zero tokens");
        require(balanceOf[msg.sender] >= tokens, "Insufficient balance");

        _checkVaultSweep(msg.sender, tokens);

        balanceOf[msg.sender] -= tokens;
        balanceOf[to]         += tokens;
        emit Transfer(msg.sender, to, tokens);

        uint256 payoutMove = (tokens * profitPerToken) / MAGNITUDE;
        payoutsOf[msg.sender] = _signedSub(payoutsOf[msg.sender], payoutMove);
        payoutsOf[to]         = _signedAdd(payoutsOf[to], payoutMove);

        return true;
    }

    // ─── Withdraw — 100% of earned dividends, zero fee ───────────────────────
    function withdraw() external nonReentrant {
        uint256 divs = dividendsOf(msg.sender);
        require(divs > 0, "No dividends to withdraw");

        _checkVaultSweep(msg.sender, divs);

        payoutsOf[msg.sender] = _signedAdd(payoutsOf[msg.sender], divs);

        CBBTC.safeTransfer(msg.sender, divs);
        emit Withdraw(msg.sender, divs);
    }

    // ─── Reinvest — zero fee, converts dividends 1:1 to OKT ─────────────────
    function reinvest() external nonReentrant {
        uint256 divs = dividendsOf(msg.sender);
        require(divs >= MIN_SATS, "Minimum 100 sats to reinvest");

        // Settle dividends first
        payoutsOf[msg.sender] = _signedAdd(payoutsOf[msg.sender], divs);

        // Mint 1:1 — no fee on reinvest
        uint256 tokens = divs;
        totalSupply           += tokens;
        balanceOf[msg.sender] += tokens;
        emit Transfer(address(0), msg.sender, tokens);

        // Set baseline for newly minted tokens
        payoutsOf[msg.sender] = _signedAdd(
            payoutsOf[msg.sender],
            (tokens * profitPerToken) / MAGNITUDE
        );

        emit Reinvest(msg.sender, tokens);
    }

    // ─── Inscribe ─────────────────────────────────────────────────────────────
    function inscribe(
        address vault,
        bytes32 assetId,
        uint256 cbbtcAmount,
        uint256 ordinalNumber,
        string calldata inscriptionId
    ) external onlyRegistrar nonReentrant {
        require(vault       != address(0), "Vault: zero address");
        require(assetId     != bytes32(0), "Vault: empty asset ID");
        require(cbbtcAmount >= MIN_SATS,   "Vault: minimum 100 sats");
        require(vaultRegistry[vault] == bytes32(0), "Vault: already registered");

        CBBTC.safeTransferFrom(msg.sender, address(this), cbbtcAmount);

        uint256 fee    = (cbbtcAmount * INSCRIBE_FEE) / 100;
        uint256 tokens = cbbtcAmount - fee;

        if (totalSupply > 0) {
            _distributeFee(fee);
        } else {
            tokens += fee;
        }

        // Mint directly into vault
        totalSupply      += tokens;
        balanceOf[vault] += tokens;
        emit Transfer(address(0), vault, tokens);

        // Set vault payout baseline
        payoutsOf[vault] = _signedAdd(
            payoutsOf[vault],
            (tokens * profitPerToken) / MAGNITUDE
        );

        // Register vault
        vaultRegistry[vault]   = assetId;
        vaultHasOrdinal[vault] = (ordinalNumber > 0);

        if (ordinalNumber > 0) {
            require(ordinalVaultAddress[ordinalNumber] == address(0), "Ordinal: already registered");
            require(!ordinalHasBeenMoved[ordinalNumber], "Ordinal: already moved");
            vaultOrdinal[vault]                = ordinalNumber;
            ordinalVaultAddress[ordinalNumber] = vault;
        }

        // Store inscription ID for content rendering (empty string if no ordinal)
        if (bytes(inscriptionId).length > 0) {
            vaultInscriptionId[vault] = inscriptionId;
        }

        emit VaultRegistered(
            vault, assetId, ordinalNumber,
            ordinalNumber > 0, tokens, block.timestamp
        );
    }

    // ─── Report Ordinal Moved ─────────────────────────────────────────────────
    // When a Bitcoin Ordinal moves, the provenance link is broken.
    // This also marks the vault as swept — the art's integrity is compromised.
    function reportOrdinalMoved(uint256 ordinalNumber) external onlyOracle {
        require(ordinalNumber > 0,                   "Invalid ordinal number");
        require(!ordinalHasBeenMoved[ordinalNumber], "Already reported as moved");
        address vault   = ordinalVaultAddress[ordinalNumber];
        bytes32 assetId = vault != address(0) ? vaultRegistry[vault] : bytes32(0);
        ordinalHasBeenMoved[ordinalNumber]   = true;
        ordinalMovedTimestamp[ordinalNumber] = block.timestamp;

        // Mark vault as swept — Ordinal movement breaks provenance
        if (vault != address(0) && !vaultHasBeenSwept[vault]) {
            vaultHasBeenSwept[vault] = true;
            emit VaultSwept(vault, assetId, 0, block.timestamp);
        }

        emit OrdinalMoved(ordinalNumber, vault, assetId, block.timestamp);
    }

    // ─── dividendsOf — PITcoin exact ─────────────────────────────────────────
    function dividendsOf(address user) public view returns (uint256) {
        uint256 gross = (balanceOf[user] * profitPerToken) / MAGNITUDE;
        int256  paid  = payoutsOf[user];
        if (paid < 0) {
            return gross + uint256(-paid);
        } else {
            uint256 upaid = uint256(paid);
            if (upaid > gross) return 0;
            return gross - upaid;
        }
    }

    // ─── View: core vault info ────────────────────────────────────────────────
    function vaultStatus(address vault) external view returns (
        bool    registered,
        bool    swept,
        uint256 balance,
        bytes32 assetId
    ) {
        return (
            vaultRegistry[vault] != bytes32(0),
            vaultHasBeenSwept[vault],
            balanceOf[vault],
            vaultRegistry[vault]
        );
    }

    // ─── View: ordinal info ───────────────────────────────────────────────────
    function vaultOrdinalStatus(address vault) external view returns (
        uint256 ordinalNumber,
        bool    hasOrdinal,
        bool    ordinalMoved,
        uint256 ordinalMovedAt,
        string memory inscriptionId
    ) {
        uint256 ordNum = vaultOrdinal[vault];
        bool    hasOrd = vaultHasOrdinal[vault];
        return (
            ordNum,
            hasOrd,
            hasOrd ? ordinalHasBeenMoved[ordNum] : false,
            hasOrd ? ordinalMovedTimestamp[ordNum] : 0,
            vaultInscriptionId[vault]
        );
    }
}
