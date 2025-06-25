// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/**
 * @title CrossChainYieldAggregatorV2
 * @notice Cross-chain yield aggregator using Chainlink CCIP, supporting any ERC20, with deposit/withdraw, APY logic, and admin controls.
 */
contract CrossChainYieldAggregatorV2 is AutomationCompatibleInterface, CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Custom errors
    error NotEnoughBalance(uint256 currentBalance, uint256 required);
    error DestinationChainNotAllowed(uint64 destinationChainSelector);
    error SourceChainNotAllowed(uint64 sourceChainSelector);
    error SenderNotAllowed(address sender);
    error InvalidReceiverAddress();
    error InvalidMigrationAmount();
    error MigrationInProgress();

    // State variables
    uint256 public lastRebalanced;
    uint256 public rebalanceInterval = 1 days;
    bool public migrationInProgress;

    IERC20 public asset;
    IRouterClient public router;
    address public feeToken;
    uint64 public destinationChainSelector;
    address public destinationAggregator;
    address public yieldReceiver;

    uint256 public apy = 5; // Local APY (in %)
    uint256 public remoteAPY; // Remote chain APY (in %)
    uint256 public lastYieldSimulation;

    // Allowlist management
    mapping(uint64 => bool) public allowlistedDestinationChains;
    mapping(uint64 => bool) public allowlistedSourceChains;
    mapping(address => bool) public allowlistedSenders;

    // User balances and investment history
    struct Transaction {
        uint256 amount;
        uint256 timestamp;
        string txType;
        string source;
    }
    struct Investment {
        uint256 totalDeposited;
        uint256 totalWithdrawn;
        uint256 lastDepositTime;
        uint256 lastWithdrawTime;
        Transaction[] history;
    }
    mapping(address => Investment) public userInvestments;
    mapping(address => uint256) public balances;
    uint256 public totalDeposited;

    // Events
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event FundsMigrated(uint256 amount, uint256 timestamp);
    event YieldReceived(address indexed user, uint256 amount);
    event YieldSimulated(uint256 amount);
    event AggregatorUpdated(address newAggregator, uint64 newSelector);
    event RemoteAPYUpdated(uint256 newAPY);
    event MigrationCompleted();
    event DestinationChainAllowlisted(uint64 chainSelector, bool allowed);
    event SourceChainAllowlisted(uint64 chainSelector, bool allowed);
    event SenderAllowlisted(address sender, bool allowed);
    event MigrationStarted(uint256 amount, uint256 contractBalance, uint256 timestamp);
    event ApprovalSet(address router, uint256 amount);
    event MigrationSent(uint64 destinationChainSelector, address destinationAggregator, uint256 amount, uint256 timestamp);
    event MigrationReset(uint256 timestamp);

    // Modifiers
    modifier onlyAllowlistedDestinationChain(uint64 _destinationChainSelector) {
        if (!allowlistedDestinationChains[_destinationChainSelector])
            revert DestinationChainNotAllowed(_destinationChainSelector);
        _;
    }
    modifier onlyAllowlistedSourceChain(uint64 _sourceChainSelector) {
        if (!allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowed(_sourceChainSelector);
        _;
    }
    modifier onlyAllowlistedSender(address _sender) {
        if (!allowlistedSenders[_sender]) revert SenderNotAllowed(_sender);
        _;
    }
    modifier noActiveMigration() {
        if (migrationInProgress) revert MigrationInProgress();
        _;
    }

    /**
     * @notice Constructor
     * @param _asset ERC20 asset address
     * @param _ccipRouter Chainlink CCIP router address
     * @param _destChainSelector Destination chain selector
     * @param _destAggregator Destination aggregator address
     * @param _feeToken Fee token address (e.g., LINK)
     * @param _yieldReceiver Address to receive yield on remote chain
     */
    constructor(
        address _asset,
        address _ccipRouter,
        uint64 _destChainSelector,
        address _destAggregator,
        address _feeToken,
        address _yieldReceiver
    ) CCIPReceiver(_ccipRouter) {
        asset = IERC20(_asset);
        router = IRouterClient(_ccipRouter);
        destinationChainSelector = _destChainSelector;
        destinationAggregator = _destAggregator;
        feeToken = _feeToken;
        yieldReceiver = _yieldReceiver;
        lastRebalanced = block.timestamp;
        lastYieldSimulation = block.timestamp;
        // Initialize allowlists
        allowlistedDestinationChains[_destChainSelector] = true;
        allowlistedSourceChains[_destChainSelector] = true;
        allowlistedSenders[_destAggregator] = true;
        _transferOwnership(msg.sender);
    }

    /**
     * @notice Deposit ERC20 tokens
     */
    function deposit(uint256 amount) external nonReentrant noActiveMigration {
        require(amount > 0, "Amount must be > 0");
        asset.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        totalDeposited += amount;
        Investment storage inv = userInvestments[msg.sender];
        inv.totalDeposited += amount;
        inv.lastDepositTime = block.timestamp;
        inv.history.push(Transaction(amount, block.timestamp, "deposit", "CurrentChain"));
        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw ERC20 tokens
     */
    function withdraw(uint256 amount) external nonReentrant noActiveMigration {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        require(asset.balanceOf(address(this)) >= amount, "Contract insufficient funds");
        balances[msg.sender] -= amount;
        totalDeposited -= amount;
        Investment storage inv = userInvestments[msg.sender];
        inv.totalWithdrawn += amount;
        inv.lastWithdrawTime = block.timestamp;
        inv.history.push(Transaction(amount, block.timestamp, "withdraw", "CurrentChain"));
        asset.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Chainlink Automation checkUpkeep
     */
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory) {
        upkeepNeeded = (block.timestamp - lastRebalanced) > rebalanceInterval && 
                      remoteAPY > apy &&
                      !migrationInProgress;
    }

    /**
     * @notice Chainlink Automation performUpkeep
     */
    function performUpkeep(bytes calldata) external override {
        if ((block.timestamp - lastRebalanced) > rebalanceInterval && 
            remoteAPY > apy && 
            !migrationInProgress) {
            _migrateFundsToRemote();
        }
    }

    /**
     * @dev Internal: migrate funds to remote chain using CCIP
     */
    function _migrateFundsToRemote() internal {
        uint256 amountToMigrate = totalDeposited;
        if (amountToMigrate == 0) revert InvalidMigrationAmount();
        uint256 contractBalance = asset.balanceOf(address(this));
        require(contractBalance >= amountToMigrate, "Not enough asset balance for migration");
        migrationInProgress = true;
        emit MigrationStarted(amountToMigrate, contractBalance, block.timestamp);
        // SafeERC20 for compatibility
        asset.safeApprove(address(router), 0);
        asset.safeApprove(address(router), amountToMigrate);
        emit ApprovalSet(address(router), amountToMigrate);
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(asset),
            amount: amountToMigrate
        });
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationAggregator),
            data: abi.encode(yieldReceiver),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: 200_000,
                    allowOutOfOrderExecution: true
                })
            ),
            feeToken: feeToken
        });
        router.ccipSend(destinationChainSelector, message);
        emit MigrationSent(destinationChainSelector, destinationAggregator, amountToMigrate, block.timestamp);
        lastRebalanced = block.timestamp;
        emit FundsMigrated(amountToMigrate, block.timestamp);
    }

    /**
     * @notice CCIP receive handler
     */
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override 
      onlyAllowlistedSourceChain(message.sourceChainSelector)
      onlyAllowlistedSender(abi.decode(message.sender, (address))) 
    {
        if (message.destTokenAmounts.length > 0) {
            Client.EVMTokenAmount memory tokenAmount = message.destTokenAmounts[0];
            if (tokenAmount.token != address(asset)) return;
            address recipient = abi.decode(message.data, (address));
            uint256 amount = tokenAmount.amount;
            if (migrationInProgress) {
                migrationInProgress = false;
                emit MigrationCompleted();
            }
            balances[recipient] += amount;
            Investment storage inv = userInvestments[recipient];
            inv.history.push(Transaction(amount, block.timestamp, "yield", "CrossChain"));
            emit YieldReceived(recipient, amount);
        }
    }

    // ========== Allowlist Management ========== //
    function allowlistDestinationChain(
        uint64 _destinationChainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedDestinationChains[_destinationChainSelector] = allowed;
        emit DestinationChainAllowlisted(_destinationChainSelector, allowed);
    }
    function allowlistSourceChain(
        uint64 _sourceChainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedSourceChains[_sourceChainSelector] = allowed;
        emit SourceChainAllowlisted(_sourceChainSelector, allowed);
    }
    function allowlistSender(address _sender, bool allowed) external onlyOwner {
        allowlistedSenders[_sender] = allowed;
        emit SenderAllowlisted(_sender, allowed);
    }

    // ========== Owner Functions ========== //
    function simulateYield(uint256 amount) external onlyOwner {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit YieldSimulated(amount);
    }
    function updateAPY(uint256 _apy) external onlyOwner {
        require(_apy <= 100, "Unrealistic APY");
        apy = _apy;
    }
    function updateRemoteAPY(uint256 _remoteAPY) external onlyOwner {
        require(_remoteAPY <= 100, "Invalid remote APY");
        remoteAPY = _remoteAPY;
        emit RemoteAPYUpdated(_remoteAPY);
    }
    function simulateAPYYield() external onlyOwner {
        require(block.timestamp > lastYieldSimulation, "Already simulated");
        uint256 duration = block.timestamp - lastYieldSimulation;
        uint256 yearlyYield = (totalDeposited * apy) / 100;
        uint256 yieldAmount = (yearlyYield * duration) / 365 days;
        lastYieldSimulation = block.timestamp;
        asset.safeTransferFrom(msg.sender, address(this), yieldAmount);
        emit YieldSimulated(yieldAmount);
    }
    function updateAggregator(
        address _newAggregator, 
        uint64 _newChainSelector
    ) external onlyOwner {
        destinationAggregator = _newAggregator;
        destinationChainSelector = _newChainSelector;
        emit AggregatorUpdated(_newAggregator, _newChainSelector);
    }
    function updateRebalanceInterval(uint256 interval) external onlyOwner {
        rebalanceInterval = interval;
    }
    function updateYieldReceiver(address _receiver) external onlyOwner {
        require(_receiver != address(0), "Invalid receiver");
        yieldReceiver = _receiver;
    }
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = asset.balanceOf(address(this));
        asset.safeTransfer(owner(), balance);
    }
    function withdrawFeeToken(address beneficiary) external onlyOwner {
        IERC20(feeToken).safeTransfer(beneficiary, IERC20(feeToken).balanceOf(address(this)));
    }
    // ========== Emergency Functions ========== //
    function emergencyResetMigration() external onlyOwner {
        migrationInProgress = false;
        emit MigrationReset(block.timestamp);
    }
    // ========== View Functions ========== //
    function getUserInfo(address user) external view returns (Investment memory) {
        return userInvestments[user];
    }
    function getUserHistory(address user) external view returns (Transaction[] memory) {
        return userInvestments[user].history;
    }
    function getUserProfit(address user) external view returns (int256) {
        Investment memory inv = userInvestments[user];
        return int256(inv.totalWithdrawn) - int256(inv.totalDeposited);
    }
    function getLinkBalance() external view returns (uint256) {
        return IERC20(feeToken).balanceOf(address(this));
    }
    function getFeeToken() external view returns (address) {
        return feeToken;
    }
    function getMigrationStatus() external view returns (bool) {
        return migrationInProgress;
    }
    // Accept native tokens for fee payments
    receive() external payable {}
} 