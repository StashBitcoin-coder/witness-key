// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  Witness Key (WK)
 * @notice cbBTC-backed token for Immutable Editions.
 *  Distribution (7%) flows to all witness keys. Acquire / Dispose / Inscribe
 *  carry it; Recirculate and Transfer are free. acquire() and inscribe()
 *  credit the MEASURED cbBTC received. reportOrdinalMoved carries a Bitcoin
 *  txid as independently-verifiable proof. No owner, no admin, immutable.
 */
contract WitnessKey is ReentrancyGuard {
    using SafeERC20 for IERC20;

    string  public constant name     = "Witness Key";
    string  public constant symbol   = "WK";
    uint8   public constant decimals = 0;

    IERC20 public immutable CBBTC;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    uint256 public constant ACQUIRE_DISTRIBUTION  = 7;
    uint256 public constant DISPOSE_DISTRIBUTION  = 7;
    uint256 public constant INSCRIBE_DISTRIBUTION = 7;
    uint256 public constant MIN_SATS     = 100;
    uint256 public constant MIN_DISPOSE  = 100;
    uint256 public constant MAX_ACQUIRE  = 1_000_000;

    uint256 public constant MAGNITUDE = 2**64;
    uint256 public recirculationPerToken;
    mapping(address => int256) public claimedOf;

    address public immutable vaultRegistrar;
    mapping(address => bytes32) public vaultRegistry;
    mapping(address => bool)    public isVault;
    mapping(address => bool)    public vaultHasBeenSwept;
    mapping(address => uint256) public vaultOrdinal;
    mapping(address => bool)    public vaultHasOrdinal;
    mapping(address => string)  public vaultInscriptionId;

    address public immutable ordinalOracle;
    mapping(uint256 => bool)    public ordinalHasBeenMoved;
    mapping(uint256 => uint256) public ordinalMovedTimestamp;
    mapping(uint256 => address) public ordinalVaultAddress;
    mapping(uint256 => bytes32) public ordinalMoveTxid;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Acquire(address indexed acquirer, uint256 cbbtcIn, uint256 tokensOut);
    event Dispose(address indexed disposer, uint256 tokensIn, uint256 cbbtcOut);
    event Claimed(address indexed user, uint256 cbbtcAmount);
    event Recirculated(address indexed user, uint256 tokensOut);
    event VaultRegistered(address indexed vault, bytes32 indexed assetId, uint256 ordinalNumber, bool hasOrdinal, uint256 oktEmbedded, uint256 timestamp);
    event VaultSwept(address indexed vault, bytes32 indexed assetId, uint256 amountMoved, uint256 timestamp);
    event OrdinalMoved(uint256 indexed ordinalNumber, address indexed vault, bytes32 indexed assetId, bytes32 btcTxid, uint256 timestamp);

    constructor(address _cbbtc) {
        require(_cbbtc != address(0), "cbBTC: zero address");
        CBBTC          = IERC20(_cbbtc);
        vaultRegistrar = msg.sender;
        ordinalOracle  = msg.sender;
    }

    modifier onlyRegistrar() { require(msg.sender == vaultRegistrar, "Not vault registrar"); _; }
    modifier onlyOracle()    { require(msg.sender == ordinalOracle,  "Not ordinal oracle");  _; }

    function _signedAdd(int256 a, uint256 b) internal pure returns (int256) { return a + int256(b); }
    function _signedSub(int256 a, uint256 b) internal pure returns (int256) { return a - int256(b); }

    function _distribute(uint256 dist) internal {
        if (totalSupply > 0 && dist > 0) {
            recirculationPerToken += (dist * MAGNITUDE) / totalSupply;
        }
    }

    function _checkVaultSweep(address vault, uint256 amount) internal {
        if (isVault[vault] && !vaultHasBeenSwept[vault]) {
            vaultHasBeenSwept[vault] = true;
            emit VaultSwept(vault, vaultRegistry[vault], amount, block.timestamp);
        }
    }

    function acquire(uint256 cbbtcAmount, uint256 minTokens) external nonReentrant {
        require(cbbtcAmount >= MIN_SATS,    "Minimum 100 sats");
        require(cbbtcAmount <= MAX_ACQUIRE, "Maximum 1,000,000 sats per acquire");

        uint256 beforeBal = CBBTC.balanceOf(address(this));
        CBBTC.safeTransferFrom(msg.sender, address(this), cbbtcAmount);
        uint256 received = CBBTC.balanceOf(address(this)) - beforeBal;

        uint256 dist   = (received * ACQUIRE_DISTRIBUTION) / 100;
        uint256 tokens = received - dist;
        require(tokens >= minTokens, "Slippage: too few tokens");

        if (totalSupply > 0) { _distribute(dist); } else { tokens += dist; }

        totalSupply           += tokens;
        balanceOf[msg.sender] += tokens;
        emit Transfer(address(0), msg.sender, tokens);

        claimedOf[msg.sender] = _signedAdd(claimedOf[msg.sender], (tokens * recirculationPerToken) / MAGNITUDE);
        emit Acquire(msg.sender, received, tokens);
    }

    function dispose(uint256 tokens, uint256 minCbbtc) external nonReentrant {
        require(tokens >= MIN_DISPOSE,           "Minimum 100 sats to dispose");
        require(balanceOf[msg.sender] >= tokens, "Insufficient balance");
        require(totalSupply > tokens,            "Cannot dispose entire supply");

        _checkVaultSweep(msg.sender, tokens);

        uint256 dist = (tokens * DISPOSE_DISTRIBUTION) / 100;
        uint256 net  = tokens - dist;
        require(net >= minCbbtc, "Slippage: too little cbBTC");

        balanceOf[msg.sender] -= tokens;
        totalSupply            -= tokens;
        emit Transfer(msg.sender, address(0), tokens);

        uint256 payout = (tokens * recirculationPerToken) / MAGNITUDE;
        claimedOf[msg.sender] = _signedSub(claimedOf[msg.sender], payout);

        _distribute(dist);

        CBBTC.safeTransfer(msg.sender, net);
        emit Dispose(msg.sender, tokens, net);
    }

    function transfer(address to, uint256 tokens) external returns (bool) {
        require(to != address(0),                "Zero address");
        require(tokens > 0,                      "Zero tokens");
        require(balanceOf[msg.sender] >= tokens, "Insufficient balance");

        _checkVaultSweep(msg.sender, tokens);

        balanceOf[msg.sender] -= tokens;
        balanceOf[to]         += tokens;
        emit Transfer(msg.sender, to, tokens);

        uint256 payoutMove = (tokens * recirculationPerToken) / MAGNITUDE;
        claimedOf[msg.sender] = _signedSub(claimedOf[msg.sender], payoutMove);
        claimedOf[to]         = _signedAdd(claimedOf[to], payoutMove);
        return true;
    }

    function claim() external nonReentrant {
        uint256 divs = recirculationOf(msg.sender);
        require(divs > 0, "No recirculation to claim");
        _checkVaultSweep(msg.sender, divs);
        claimedOf[msg.sender] = _signedAdd(claimedOf[msg.sender], divs);
        CBBTC.safeTransfer(msg.sender, divs);
        emit Claimed(msg.sender, divs);
    }

    function recirculate() external nonReentrant {
        uint256 divs = recirculationOf(msg.sender);
        require(divs >= MIN_SATS, "Minimum 100 sats to recirculate");
        claimedOf[msg.sender] = _signedAdd(claimedOf[msg.sender], divs);
        uint256 tokens = divs;
        totalSupply           += tokens;
        balanceOf[msg.sender] += tokens;
        emit Transfer(address(0), msg.sender, tokens);
        claimedOf[msg.sender] = _signedAdd(claimedOf[msg.sender], (tokens * recirculationPerToken) / MAGNITUDE);
        emit Recirculated(msg.sender, tokens);
    }

    function inscribe(address vault, bytes32 assetId, uint256 cbbtcAmount, uint256 ordinalNumber, string calldata inscriptionId) external onlyRegistrar nonReentrant {
        require(vault       != address(0), "Vault: zero address");
        require(assetId     != bytes32(0), "Vault: empty asset ID");
        require(cbbtcAmount >= MIN_SATS,   "Vault: minimum 100 sats");
        require(!isVault[vault],           "Vault: already registered");

        uint256 beforeBal = CBBTC.balanceOf(address(this));
        CBBTC.safeTransferFrom(msg.sender, address(this), cbbtcAmount);
        uint256 received = CBBTC.balanceOf(address(this)) - beforeBal;

        uint256 dist   = (received * INSCRIBE_DISTRIBUTION) / 100;
        uint256 tokens = received - dist;

        if (totalSupply > 0) { _distribute(dist); } else { tokens += dist; }

        totalSupply      += tokens;
        balanceOf[vault] += tokens;
        emit Transfer(address(0), vault, tokens);

        claimedOf[vault] = _signedAdd(claimedOf[vault], (tokens * recirculationPerToken) / MAGNITUDE);

        vaultRegistry[vault]   = assetId;
        isVault[vault]         = true;
        vaultHasOrdinal[vault] = (ordinalNumber > 0);

        if (ordinalNumber > 0) {
            require(ordinalVaultAddress[ordinalNumber] == address(0), "Ordinal: already registered");
            require(!ordinalHasBeenMoved[ordinalNumber], "Ordinal: already moved");
            vaultOrdinal[vault]                = ordinalNumber;
            ordinalVaultAddress[ordinalNumber] = vault;
        }
        if (bytes(inscriptionId).length > 0) { vaultInscriptionId[vault] = inscriptionId; }

        emit VaultRegistered(vault, assetId, ordinalNumber, ordinalNumber > 0, tokens, block.timestamp);
    }

    function reportOrdinalMoved(uint256 ordinalNumber, bytes32 btcTxid) external onlyOracle {
        require(ordinalNumber > 0,                   "Invalid ordinal number");
        require(btcTxid != bytes32(0),               "Missing BTC txid");
        require(!ordinalHasBeenMoved[ordinalNumber], "Already reported as moved");
        address vault   = ordinalVaultAddress[ordinalNumber];
        bytes32 assetId = vault != address(0) ? vaultRegistry[vault] : bytes32(0);
        ordinalHasBeenMoved[ordinalNumber]   = true;
        ordinalMovedTimestamp[ordinalNumber] = block.timestamp;
        ordinalMoveTxid[ordinalNumber]       = btcTxid;
        if (vault != address(0) && !vaultHasBeenSwept[vault]) {
            vaultHasBeenSwept[vault] = true;
            emit VaultSwept(vault, assetId, 0, block.timestamp);
        }
        emit OrdinalMoved(ordinalNumber, vault, assetId, btcTxid, block.timestamp);
    }

    function recirculationOf(address user) public view returns (uint256) {
        uint256 gross = (balanceOf[user] * recirculationPerToken) / MAGNITUDE;
        int256  paid  = claimedOf[user];
        if (paid < 0) { return gross + uint256(-paid); }
        else { uint256 upaid = uint256(paid); if (upaid > gross) return 0; return gross - upaid; }
    }

    function vaultStatus(address vault) external view returns (bool registered, bool swept, uint256 balance, bytes32 assetId) {
        return (isVault[vault], vaultHasBeenSwept[vault], balanceOf[vault], vaultRegistry[vault]);
    }

    function vaultOrdinalStatus(address vault) external view returns (uint256 ordinalNumber, bool hasOrdinal, bool ordinalMoved, uint256 ordinalMovedAt, string memory inscriptionId) {
        uint256 ordNum = vaultOrdinal[vault];
        bool    hasOrd = vaultHasOrdinal[vault];
        return (ordNum, hasOrd, hasOrd ? ordinalHasBeenMoved[ordNum] : false, hasOrd ? ordinalMovedTimestamp[ordNum] : 0, vaultInscriptionId[vault]);
    }
}
