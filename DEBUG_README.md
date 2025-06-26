# Debugging Guide for SafeERC20 Error

## 🚨 Problem
You're getting a `SafeERC20: low-level call failed` error when calling `performUpkeep`.

## 🔧 Quick Fix Steps

### Step 1: Quick Debug Check
```bash
# 1. Edit the contract address in quick-debug.js
# 2. Run quick debug
npx hardhat run scripts/quick-debug.js --network <your-network>
```

### Step 2: Full Debug Analysis
```bash
# 1. Edit the contract address in debug-performUpkeep.js
# 2. Run full debug
npx hardhat run scripts/debug-performUpkeep.js --network <your-network>
```

### Step 3: Add LINK Tokens (Most Common Fix)
```bash
# 1. Edit the contract address in add-link-to-contract.js
# 2. Add LINK tokens
npx hardhat run scripts/add-link-to-contract.js --network <your-network>
```

## 📁 Debug Scripts Available

### 1. `scripts/quick-debug.js` ⚡ FAST
- Quick state check
- Essential balance verification
- Basic issue detection
- **Use this first for a quick overview**

### 2. `scripts/debug-performUpkeep.js` 🔍 DETAILED
- Comprehensive analysis
- CCIP fee estimation
- Detailed condition checking
- **Use this for deep debugging**

### 3. `scripts/add-link-to-contract.js` 💰 FIX
- Adds LINK tokens to contract
- Verifies transfer success
- **Use this to fix the most common issue**

## 🎯 How to Use

### 1. Update Contract Address
In each script, replace:
```javascript
const contractAddress = "YOUR_CONTRACT_ADDRESS_HERE";
```
With your actual deployed contract address.

### 2. Run Debug Scripts
```bash
# Quick check
npx hardhat run scripts/quick-debug.js --network sepolia

# Full analysis
npx hardhat run scripts/debug-performUpkeep.js --network sepolia

# Add LINK tokens
npx hardhat run scripts/add-link-to-contract.js --network sepolia
```

## 🔍 What to Look For

### Expected Output (Good):
```
📊 ESSENTIAL STATE:
   Total Deposited: 1.0 tokens
   LINK Balance: 2.0 LINK ✅
   Migration Status: false
   Local APY: 5%
   Remote APY: 8%

🔍 UPKEEP CHECK:
   Upkeep Needed: true ✅
```

### Expected Output (Problem):
```
📊 ESSENTIAL STATE:
   Total Deposited: 1.0 tokens
   LINK Balance: 0.0 LINK ❌
   Migration Status: false
   Local APY: 5%
   Remote APY: 8%

🚨 ISSUE DETECTION:
   ❌ NO LINK BALANCE - Add LINK tokens!
```

## 🛠️ Common Fixes

### 1. No LINK Balance
```bash
npx hardhat run scripts/add-link-to-contract.js --network <your-network>
```

### 2. Migration Stuck
```javascript
// In hardhat console
await contract.emergencyResetMigration();
```

### 3. No Deposits
```javascript
// Users need to deposit first
await contract.deposit(ethers.parseEther("1"));
```

### 4. Remote APY Not Higher
```javascript
// Owner needs to update remote APY
await contract.updateRemoteAPY(10); // 10% APY
```

## 📞 Need Help?

1. **Run the debug scripts** and share the output
2. **Check the troubleshooting guide**: `TROUBLESHOOTING.md`
3. **Verify your network configuration** in `hardhat.config.js`

## 🎯 Quick Commands

```bash
# Quick state check
npx hardhat run scripts/quick-debug.js --network sepolia

# Add LINK tokens
npx hardhat run scripts/add-link-to-contract.js --network sepolia

# Full analysis
npx hardhat run scripts/debug-performUpkeep.js --network sepolia
```

**Start with `quick-debug.js` - it will tell you exactly what's wrong!** 