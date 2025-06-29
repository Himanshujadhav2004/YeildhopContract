// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/**
 * @title CrossChainV3
 * @notice Cross-chain DeFi yield aggregator using Chainlink CCIP and Automation.
 * @dev Simplified automation that directly calls triggerMigration.
 */
contract CrossChainV3 is Ownable, CCIPReceiver, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error NotEnoughBalance(uint256 current, uint256 required);
    error NotEnoughLink(uint256 current, uint256 required);
    error NotEnoughToken(uint256 current, uint256 required);
    error ApprovalFailed();
    error InvalidConfig(string reason);
    error MigrationInProgress();
    error MigrationNotInProgress();
    error APYNotHigher();
    error NothingToWithdraw();
    error NotAllowlisted(uint64 chain, address sender);
    error CCIPSendFailed(string reason);
    error InvalidReceiverAddress();
    error ZeroAmount();
    error InvalidAsset();

    // --- Events ---
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event YieldSimulated(uint256 yieldAmount, uint256 newTotal, uint256 apy, uint256 timestamp);
    event MigrationTriggered(uint256 totalMigrated, uint64 destChain, address destAggregator, uint256 remoteAPY);
    event MigrationCompleted(bytes32 messageId, address yieldReceiver, uint256 amount);
    event MigrationReset();
    event AllowlistUpdated(string listType, uint64 chain, address sender, bool allowed);
    event APYUpdated(uint256 localAPY, uint256 remoteAPY);
    event EmergencyWithdraw(address token, address to, uint256 amount);
    event TransactionRecorded(address indexed user, uint256 amount, uint8 txType, string source, uint256 timestamp);

    // --- Structs ---
    struct Transaction {
        uint256 amount;
        uint256 timestamp;
        uint8 txType; // 0: deposit, 1: withdraw, 2: yield
        string source;
    }
    struct Investment {
        uint256 totalDeposited;
        uint256 totalWithdrawn;
        uint256 lastDepositTime;
        uint256 lastWithdrawTime;
        uint256 lastYieldTime;
        Transaction[] history;
    }

    // --- State Variables ---
    IERC20 public immutable asset;
    IERC20 public immutable linkToken;
    IRouterClient public immutable router;
    address public yieldReceiver;
    address public destAggregator;
    uint64 public destChainSelector;
    uint256 public apy = 5e16; // 5% (scaled by 1e18)
    uint256 public remoteAPY;
    uint256 public rebalanceInterval = 1 days;
    uint256 public lastYieldSimulation;
    uint256 public lastRebalanced;
    uint256 public totalDeposited;
    uint256 public totalYieldSimulated;
    bool public migrationInProgress;

    mapping(address => uint256) public balances;
    mapping(address => Investment) public userInvestments;
    mapping(uint64 => bool) public allowlistedDestinationChains;
    mapping(uint64 => bool) public allowlistedSourceChains;
    mapping(address => bool) public allowlistedSenders;

    // --- User tracking for migration ---
    address[] public allUsers;
    mapping(address => bool) public isUser;

    // --- Modifiers ---
    modifier onlyAllowlistedDestination(uint64 chain) {
        if (!allowlistedDestinationChains[chain]) revert NotAllowlisted(chain, address(0));
        _;
    }
    modifier onlyAllowlistedSource(uint64 chain, address sender) {
        if (!allowlistedSourceChains[chain] || !allowlistedSenders[sender]) revert NotAllowlisted(chain, sender);
        _;
    }
    modifier onlyValidAsset(address token) {
        if (token != address(asset)) revert InvalidAsset();
        _;
    }

    // --- Constructor ---
    constructor(
        address _asset,
        address _router,
        address _linkToken,
        uint64 _destChainSelector,
        address _destAggregator,
        address _yieldReceiver
    ) CCIPReceiver(_router) {
        if (_asset == address(0) || _router == address(0) || _linkToken == address(0) || _destAggregator == address(0) || _yieldReceiver == address(0)) revert InvalidConfig("Zero address");
        asset = IERC20(_asset);
        router = IRouterClient(_router);
        linkToken = IERC20(_linkToken);
        destChainSelector = _destChainSelector;
        destAggregator = _destAggregator;
        yieldReceiver = _yieldReceiver;
        lastYieldSimulation = block.timestamp;
        lastRebalanced = block.timestamp;
        
        // Auto-allowlist destination chain for outgoing migrations
        allowlistedDestinationChains[_destChainSelector] = true;
        emit AllowlistUpdated("destination", _destChainSelector, address(0), true);
        
        // Auto-allowlist source chain for incoming migrations (same chain as destination for bidirectional)
        allowlistedSourceChains[_destChainSelector] = true;
        emit AllowlistUpdated("source", _destChainSelector, address(0), true);
        
        // Auto-allowlist the destination aggregator as a sender
        allowlistedSenders[_destAggregator] = true;
        emit AllowlistUpdated("sender", 0, _destAggregator, true);
        
        // Auto-allowlist the yield receiver as a sender (in case it's different from destAggregator)
        if (_yieldReceiver != _destAggregator) {
            allowlistedSenders[_yieldReceiver] = true;
            emit AllowlistUpdated("sender", 0, _yieldReceiver, true);
        }
    }

    // --- Deposit & Withdraw ---
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        totalDeposited += amount;
        Investment storage inv = userInvestments[msg.sender];
        inv.totalDeposited += amount;
        inv.lastDepositTime = block.timestamp;
        inv.history.push(Transaction(amount, block.timestamp, 0, "deposit"));
        // Track new users for migration
        if (!isUser[msg.sender]) {
            isUser[msg.sender] = true;
            allUsers.push(msg.sender);
        }
        emit Deposited(msg.sender, amount);
        emit TransactionRecorded(msg.sender, amount, 0, "deposit", block.timestamp);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (balances[msg.sender] < amount) revert NotEnoughToken(balances[msg.sender], amount);
        
        // Check if contract has enough tokens (for post-migration scenarios)
        uint256 contractBalance = asset.balanceOf(address(this));
        if (contractBalance < amount) revert NotEnoughToken(contractBalance, amount);
        
        balances[msg.sender] -= amount;
        totalDeposited -= amount;
        asset.safeTransfer(msg.sender, amount);
        Investment storage inv = userInvestments[msg.sender];
        inv.totalWithdrawn += amount;
        inv.lastWithdrawTime = block.timestamp;
        inv.history.push(Transaction(amount, block.timestamp, 1, "withdraw"));
        emit Withdrawn(msg.sender, amount);
        emit TransactionRecorded(msg.sender, amount, 1, "withdraw", block.timestamp);
    }

    // --- APY Simulation ---
    function simulateAPYYield() external onlyOwner {
        uint256 timeElapsed = block.timestamp - lastYieldSimulation;
        if (timeElapsed == 0) revert("No time elapsed");
        uint256 yieldAmount = (totalDeposited * apy * timeElapsed) / (365 days * 1e18);
        if (yieldAmount == 0) revert("No yield");
        totalYieldSimulated += yieldAmount;
        lastYieldSimulation = block.timestamp;
        // Simulate yield as contract balance increase (for demo, just record it)
        Investment storage inv = userInvestments[owner()];
        inv.lastYieldTime = block.timestamp;
        inv.history.push(Transaction(yieldAmount, block.timestamp, 2, "yield"));
        emit YieldSimulated(yieldAmount, totalDeposited + totalYieldSimulated, apy, block.timestamp);
        emit TransactionRecorded(owner(), yieldAmount, 2, "yield", block.timestamp);
    }

    function updateAPY(uint256 _localAPY, uint256 _remoteAPY) external onlyOwner {
        apy = _localAPY;
        remoteAPY = _remoteAPY;
        emit APYUpdated(_localAPY, _remoteAPY);
    }

    // --- Allowlist Management ---
    function allowlistDestinationChain(uint64 chain, bool allowed) external onlyOwner {
        allowlistedDestinationChains[chain] = allowed;
        emit AllowlistUpdated("destination", chain, address(0), allowed);
    }
    function allowlistSourceChain(uint64 chain, bool allowed) external onlyOwner {
        allowlistedSourceChains[chain] = allowed;
        emit AllowlistUpdated("source", chain, address(0), allowed);
    }
    function allowlistSender(address sender, bool allowed) external onlyOwner {
        allowlistedSenders[sender] = allowed;
        emit AllowlistUpdated("sender", 0, sender, allowed);
    }

    // --- Migration Logic (with user data for proper distribution) ---
    function triggerMigration() public {
        if (migrationInProgress) revert MigrationInProgress();
        if (block.timestamp < lastRebalanced + rebalanceInterval) revert("Rebalance interval not met");
        if (remoteAPY <= apy) revert APYNotHigher();
        uint256 bal = asset.balanceOf(address(this));
        if (bal == 0) revert NotEnoughToken(0, 1);
        if (totalDeposited == 0) revert NothingToWithdraw();
        
        // Prepare user data for distribution
        address[] memory users = new address[](allUsers.length);
        uint256[] memory userBalances = new uint256[](allUsers.length);
        uint256 totalUserBalances = 0;
        
        for (uint256 i = 0; i < allUsers.length; i++) {
            users[i] = allUsers[i];
            userBalances[i] = balances[allUsers[i]];
            totalUserBalances += balances[allUsers[i]];
        }
        
        // Build CCIP message with user data
        Client.EVM2AnyMessage memory msgData = _buildCCIPMessageWithUserData(yieldReceiver, bal, address(linkToken), users, userBalances);
        uint256 fee = router.getFee(destChainSelector, msgData);
        
        if (linkToken.balanceOf(address(this)) < fee) revert NotEnoughLink(linkToken.balanceOf(address(this)), fee);
        if (!allowlistedDestinationChains[destChainSelector]) revert NotAllowlisted(destChainSelector, address(0));
        
        migrationInProgress = true;
        
        // Approve router for asset and LINK
        asset.safeApprove(address(router), bal);
        linkToken.safeApprove(address(router), fee);
        
        try router.ccipSend(destChainSelector, msgData) returns (bytes32 messageId) {
            // Clear user balances on source chain after successful migration
            _clearSourceChainBalances();
            
            emit MigrationTriggered(bal, destChainSelector, destAggregator, remoteAPY);
            lastRebalanced = block.timestamp;
            migrationInProgress = false;
            emit MigrationCompleted(messageId, yieldReceiver, bal);
        } catch Error(string memory reason) {
            migrationInProgress = false;
            revert CCIPSendFailed(reason);
        } catch {
            migrationInProgress = false;
            revert CCIPSendFailed("Unknown error");
        }
    }

    // --- Clear source chain balances after migration ---
    function _clearSourceChainBalances() internal {
        for (uint256 i = 0; i < allUsers.length; i++) {
            if (balances[allUsers[i]] > 0) {
                balances[allUsers[i]] = 0;
                // Record the migration in user history
                Investment storage inv = userInvestments[allUsers[i]];
                inv.history.push(Transaction(0, block.timestamp, 3, "migration_sent"));
            }
        }
        totalDeposited = 0;
    }

    function resetMigration() external onlyOwner {
        if (!migrationInProgress) revert MigrationNotInProgress();
        migrationInProgress = false;
        emit MigrationReset();
    }

    // --- CCIP Message Build (with user data) ---
    function _buildCCIPMessageWithUserData(
        address _receiver,
        uint256 _amount,
        address _feeToken,
        address[] memory users,
        uint256[] memory userBalances
    ) internal view returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(asset), amount: _amount});
        // Encode user data and migration tag
        bytes memory data = abi.encode(users, userBalances, "migration");
        return Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true})),
            feeToken: _feeToken
        });
    }

    // --- CCIP Receiver (with user data distribution) ---
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override onlyAllowlistedSource(any2EvmMessage.sourceChainSelector, abi.decode(any2EvmMessage.sender, (address))) {
        // Decode user data and migration tag
        (address[] memory users, uint256[] memory userBalances, string memory msgType) = abi.decode(any2EvmMessage.data, (address[], uint256[], string));
        require(keccak256(bytes(msgType)) == keccak256(bytes("migration")), "Invalid message type");
        
        uint256 totalAmount = any2EvmMessage.destTokenAmounts[0].amount;
        uint256 totalUserBalances = 0;
        
        // Calculate total user balances for proportion calculation
        for (uint256 i = 0; i < userBalances.length; i++) {
            totalUserBalances += userBalances[i];
        }
        
        // Distribute tokens proportionally to users
        for (uint256 i = 0; i < users.length; i++) {
            if (userBalances[i] > 0 && totalUserBalances > 0) {
                uint256 userShare = (totalAmount * userBalances[i]) / totalUserBalances;
                balances[users[i]] = userShare;
                
                // Track new users
                if (!isUser[users[i]]) {
                    isUser[users[i]] = true;
                    allUsers.push(users[i]);
                }
                
                // Update user investment data
                Investment storage inv = userInvestments[users[i]];
                inv.totalDeposited = userShare;
                inv.lastDepositTime = block.timestamp;
                inv.history.push(Transaction(userShare, block.timestamp, 0, "migration"));
            }
        }
        
        // Update total deposited to match the received amount
        totalDeposited = totalAmount;
        
        emit MigrationCompleted(any2EvmMessage.messageId, address(0), totalAmount);
    }

    // --- Migration Condition Check ---
    function shouldMigrate() external view returns (bool) {
        return (
            !migrationInProgress &&
            block.timestamp >= lastRebalanced + rebalanceInterval &&
            remoteAPY > apy &&
            totalDeposited > 0 &&
            asset.balanceOf(address(this)) >= totalDeposited &&
            linkToken.balanceOf(address(this)) >= estimateCCIPFees() &&
            allowlistedDestinationChains[destChainSelector]
        );
    }

    // --- Debug & View Functions ---
    function getDebugInfoBasic() external view returns (
        uint256 _totalDeposited,
        uint256 _totalYieldSimulated,
        uint256 _apy,
        uint256 _remoteAPY,
        uint256 _lastYieldSimulation,
        uint256 _lastRebalanced,
        bool _migrationInProgress
    ) {
        return (totalDeposited, totalYieldSimulated, apy, remoteAPY, lastYieldSimulation, lastRebalanced, migrationInProgress);
    }
    function getDebugInfoConditions() external view returns (
        bool rebalanceDue,
        bool remoteAPYHigher,
        bool hasDeposits,
        bool hasEnoughAsset,
        bool hasEnoughLink,
        bool migrationNotInProgress,
        bool destChainAllowed
    ) {
        rebalanceDue = block.timestamp >= lastRebalanced + rebalanceInterval;
        remoteAPYHigher = remoteAPY > apy;
        hasDeposits = totalDeposited > 0;
        hasEnoughAsset = asset.balanceOf(address(this)) >= totalDeposited;
        hasEnoughLink = linkToken.balanceOf(address(this)) >= estimateCCIPFees();
        migrationNotInProgress = !migrationInProgress;
        destChainAllowed = allowlistedDestinationChains[destChainSelector];
    }
    function getUpkeepStatus() external view returns (string memory) {
        if (migrationInProgress) return "Migration in progress";
        if (block.timestamp < lastRebalanced + rebalanceInterval) return "Rebalance interval not met";
        if (remoteAPY <= apy) return "Remote APY not higher";
        if (totalDeposited == 0) return "No deposits";
        if (asset.balanceOf(address(this)) < totalDeposited) return "Not enough asset";
        if (linkToken.balanceOf(address(this)) < estimateCCIPFees()) return "Not enough LINK";
        if (!allowlistedDestinationChains[destChainSelector]) return "Destination chain not allowed";
        return "Ready for migration";
    }
    function estimateCCIPFees() public view returns (uint256) {
        // For fee estimation, use empty arrays to keep it simple
        address[] memory users = new address[](0);
        uint256[] memory userBalances = new uint256[](0);
        Client.EVM2AnyMessage memory msgData = _buildCCIPMessageWithUserData(yieldReceiver, totalDeposited, address(linkToken), users, userBalances);
        return router.getFee(destChainSelector, msgData);
    }

    // --- Emergency Functions ---
    function emergencyWithdraw(address token, address to) external onlyOwner {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToWithdraw();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }
    function emergencyResetMigration() external onlyOwner {
        migrationInProgress = false;
        emit MigrationReset();
    }
    function setRebalanceInterval(uint256 interval) external onlyOwner {
        rebalanceInterval = interval;
    }
    function setDestAggregator(address aggregator) external onlyOwner {
        if (aggregator == address(0)) revert InvalidConfig("Zero aggregator");
        destAggregator = aggregator;
    }
    function setYieldReceiver(address receiver) external onlyOwner {
        if (receiver == address(0)) revert InvalidReceiverAddress();
        yieldReceiver = receiver;
    }
    function setDestChainSelector(uint64 selector) external onlyOwner {
        destChainSelector = selector;
    }
    // --- User enumeration ---
    function getAllUsers() external view returns (address[] memory) {
        return allUsers;
    }

    // --- Migration Status Functions ---
    function getMigrationStatus() external view returns (
        bool migrated,
        uint256 sourceBalance,
        uint256 userBalance,
        uint256 totalDeposits
    ) {
        migrated = (totalDeposited == 0 && asset.balanceOf(address(this)) == 0);
        sourceBalance = asset.balanceOf(address(this));
        userBalance = balances[msg.sender];
        totalDeposits = totalDeposited;
        return (migrated, sourceBalance, userBalance, totalDeposits);
    }
    
    function getDestinationInfo() external view returns (
        uint64 destChain,
        address destAggregatorAddress,
        uint256 remoteAPYValue
    ) {
        return (destChainSelector, destAggregator, remoteAPY);
    }

    // --- Chainlink Automation (Simplified) ---
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = shouldMigrate();
        performData = "";
    }
    
    function performUpkeep(bytes calldata) external override {
        if (shouldMigrate()) {
            triggerMigration();
        }
    }
} 