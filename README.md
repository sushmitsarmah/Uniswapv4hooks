# Toradle Synergy Bot with Uniswap Hooks

A sophisticated bot-driven trading system for Uniswap V4 that leverages ZK proofs through Brevis to validate trading conditions and enforce comprehensive safety mechanisms. The system combines oracle price checks, liquidity impact limits, and time-window controls to ensure secure and controlled automated trading.

![Toradle Synergy Bot](./assets/thumbnail.png)

## 🌟 Features

### Core Components
- **ComprehensiveBotHook**: Advanced Uniswap V4 hook implementing multiple safety validations
- **BotSwapExecutor**: Intermediary contract handling bot interactions and swap execution
- **Brevis Integration**: ZK proof generation and verification for historical data validation

### Safety Mechanisms
1. **Time Window Controls**
   - Configurable trading hours
   - Day-of-week trading restrictions
   - Granular time-based access control

2. **Liquidity Protection**
   - Maximum impact thresholds
   - Dynamic liquidity checks
   - Swap size limitations

3. **Price Validation**
   - Chainlink oracle integration
   - Price deviation monitoring
   - Stale price protection

4. **ZK Proof Verification**
   - Historical volatility validation
   - Proof freshness checks
   - Custom circuit integration

## 🔧 Technical Architecture

### Smart Contracts
```solidity
ComprehensiveBotHook.sol
├── Time Window Checks
├── Liquidity Impact Validation
├── Oracle Price Verification
└── Brevis ZK Proof Integration

BotSwapExecutor.sol
├── Bot Interface
├── Swap Execution Logic
└── Proof Data Management
```

### Key Interfaces

```solidity
interface IBrevisProof {
    function verifyProof(
        bytes32 circuitId,
        bytes calldata proof,
        bytes calldata publicInputs
    ) external view returns (bool);
}

struct YourCircuitPublicInputs {
    uint256 historicalVolatilityBps;
    uint256 relevantTimestamp;
}
```

## 🚀 Getting Started

### Prerequisites
- Node.js v14+
- Hardhat
- Uniswap V4 dependencies
- Brevis SDK

### Installation
```bash
git clone <repository-url>
cd toradle-synergy-bot
npm install
```

### Configuration
1. Create `.env` file:
```env
PRIVATE_KEY=your_private_key
INFURA_KEY=your_infura_key
ETHERSCAN_API_KEY=your_etherscan_key
```

2. Configure trading parameters in `config.js`:
```javascript
module.exports = {
    TRADING_START_HOUR_UTC: 0,
    TRADING_END_HOUR_UTC: 24,
    MAX_LIQUIDITY_IMPACT_BPS: 500,
    MAX_PRICE_DEVIATION_BPS: 300
}
```

### Deployment
```bash
npx hardhat compile
npx hardhat deploy --network <network>
```

## 🔒 Security Features

### Time-Based Controls
- Configurable trading windows
- Day-of-week restrictions
- UTC time standardization

### Liquidity Protection
```solidity
uint256 public constant MAX_LIQUIDITY_IMPACT_BPS = 500; // 5%
```
- Prevents excessive market impact
- Dynamic liquidity checks
- Configurable thresholds

### Oracle Integration
```solidity
function checkOraclePriceDeviation(PoolKey calldata key) internal view {
    // Price deviation checks
    // Staleness validation
    // Normalization logic
}
```

### ZK Proof Verification
- Historical volatility validation
- Timestamp freshness checks
- Circuit-specific validations

## 🔍 Testing

```bash
# Run all tests
npx hardhat test

# Run specific test file
npx hardhat test test/ComprehensiveBotHook.test.js
```

## 📈 Performance Considerations

### Gas Optimization
- Efficient storage usage
- Optimized proof verification
- Minimal state changes

### Scalability
- Modular design
- Upgradeable components
- Configurable parameters

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.

## 🙏 Acknowledgments

- Uniswap V4 Team
- Brevis Protocol
- Chainlink
- OpenZeppelin

## 📞 Contact

Project Link: [https://github.com/yourusername/toradle-synergy-bot](https://github.com/yourusername/toradle-synergy-bot)

## 🚨 Disclaimer

This software is in beta. Use at your own risk. Always test thoroughly before deploying to mainnet.