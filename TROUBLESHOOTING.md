# Troubleshooting: SafeERC20 Error in performUpkeep

## Error Description
```
SafeERC20: low-level call failed
```

This error occurs in the `performUpkeep` function when trying to migrate funds to a remote chain using Chainlink CCIP.

## Root Causes & Solutions

### 1. **Insufficient LINK Tokens for CCIP Fees** ⭐ MOST COMMON
**Problem**: Contract doesn't have enough LINK tokens to pay for cross-chain message fees.

**Solution**:
```bash
# Run the LINK transfer script
npx hardhat run scripts/add-link-to-contract.js --network <your-network>
```

**Manual Fix**:
- Transfer LINK tokens to your contract address
- Minimum recommended: 1-2 LINK tokens
- Check LINK balance: `await contract.getLinkBalance()`

### 2. **Token Approval Issues**
**Problem**: The asset token approval to the CCIP router is failing.

**Causes**:
- Existing non-zero allowance (some tokens require reset to 0 first)
- Token contract restrictions
- Router address issues

**Solution**: The contract has been updated with improved approval logic that handles these cases.

### 3. **Insufficient Contract Balance**
**Problem**: Contract doesn't have enough asset tokens to migrate.

**Check**:
```javascript
const totalDeposited = await contract.totalDeposited();
const contractBalance = await assetToken.balanceOf(contractAddress);
console.log(`Need: ${totalDeposited}, Have: ${contractBalance}`);
```

**Solution**: Ensure users have deposited tokens before migration.

### 4. **CCIP Router Configuration Issues**
**Problem**: Router address or destination chain configuration is incorrect.

**Check**:
```javascript
const router = await contract.router();
const destinationChainSelector = await contract.destinationChainSelector();
const destinationAggregator = await contract.destinationAggregator();
```

**Solution**: Verify router address and chain selector for your target network.

### 5. **Migration State Issues**
**Problem**: Migration is already in progress or stuck.

**Check**:
```javascript
const migrationInProgress = await contract.getMigrationStatus();
```

**Solution**: Use emergency reset if stuck:
```javascript
await contract.emergencyResetMigration();
```

## Debugging Steps

### Step 1: Run the Debug Script
```bash
# Update the contract address in the script first
npx hardhat run scripts/debug-performUpkeep.js --network <your-network>
```

### Step 2: Check Contract State
```javascript
// Check if upkeep conditions are met
const [upkeepNeeded, performData] = await contract.checkUpkeep("0x");
console.log("Upkeep needed:", upkeepNeeded);

// Check balances
const linkBalance = await contract.getLinkBalance();
const totalDeposited = await contract.totalDeposited();
const migrationStatus = await contract.getMigrationStatus();
```

### Step 3: Verify CCIP Configuration
```javascript
// Check router and destination
const router = await contract.router();
const destChain = await contract.destinationChainSelector();
const destAggregator = await contract.destinationAggregator();

// Test fee estimation
const routerContract = await ethers.getContractAt("IRouterClient", router);
const fee = await routerContract.getFee(destChain, message);
console.log("Estimated fee:", ethers.formatEther(fee));
```

## Common Network-Specific Issues

### Sepolia Testnet
- Ensure you have Sepolia LINK tokens
- Verify router address: `0xD0daae2231E9CB96b94C8512223533293C3693Bf`
- Check destination chain selector for your target chain

### Mainnet
- Ensure you have real LINK tokens
- Verify router address: `0xE561d5E02207fb5eB32cca20a699E0d8919a1476`
- Higher gas costs and fees

## Prevention Measures

### 1. Pre-flight Checks
Add these checks before calling `performUpkeep`:
```javascript
// Check LINK balance
const linkBalance = await contract.getLinkBalance();
if (linkBalance === 0n) {
    console.log("Add LINK tokens first!");
    return;
}

// Check contract balance
const totalDeposited = await contract.totalDeposited();
const contractBalance = await assetToken.balanceOf(contractAddress);
if (contractBalance < totalDeposited) {
    console.log("Insufficient contract balance!");
    return;
}
```

### 2. Monitor Contract State
Regularly check:
- LINK balance for fees
- Contract asset balance
- Migration status
- Upkeep conditions

### 3. Emergency Functions
Use these if migration gets stuck:
```javascript
// Reset migration state
await contract.emergencyResetMigration();

// Emergency withdraw (owner only)
await contract.emergencyWithdraw();
```

## Testing the Fix

After applying fixes:

1. **Add LINK tokens** to the contract
2. **Test checkUpkeep** to ensure conditions are met
3. **Monitor performUpkeep** execution
4. **Check events** for successful migration

## Support

If the issue persists:
1. Run the debug script and share the output
2. Check the transaction logs for specific error messages
3. Verify all contract addresses and configurations
4. Ensure sufficient gas for the transaction 