# Toradle Synergy Bot with Uniswap Hooks

A sophisticated bot-driven trading system for Uniswap V4 that leverages ZK proofs through Brevis to validate trading conditions and enforce comprehensive safety mechanisms. The system combines oracle price checks, liquidity impact limits, and time-window controls to ensure secure and controlled automated trading.

![Toradle Synergy Bot](./assets/thumbnail.png)

## 🌟 Features

### Core Components

#### Hook System
- **ComprehensiveBotHook**: Main hook implementing multiple safety validations
- **BrevisVerificationHook**: Handles ZK proof verification
- **SwapStrategyHook**: Manages swap strategies
- **MaxSwapSizeEnforcerHook**: Controls maximum swap sizes
- **OraclePriceCheckHook**: Validates prices against oracle
- **AfterSwapLogHook**: Logs swap execution details

#### Execution Layer
- **BotSwapExecutor**: Intermediary contract handling bot interactions and swap execution
- **SignalSwapper**: Manages swap signals and execution flow

### Safety Mechanisms
1. **Multi-Layer Protection**
   - Time window controls
   - Liquidity impact limits
   - Oracle price validation
   - ZK proof verification

2. **Price & Liquidity Guards**
   - Maximum swap size enforcement
   - Price deviation monitoring
   - Dynamic liquidity checks

## 🔧 Technical Architecture

### Smart Contracts Structure
```solidity
src/
├── hooks/
│   ├── ComprehensiveBotHook.sol
│   ├── BrevisVerificationHook.sol
│   ├── SwapStrategyHook.sol
│   ├── MaxSwapSizeEnforcerHook.sol
│   ├── OraclePriceCheckHook.sol
│   ├── AfterSwapLogHook.sol
│   ├── CombinedHook.sol
│   └── SignalSwapper.sol
└── BotSwapExecutor.sol
```

### Key Interfaces

```
Toradle Synergy Bot leverages Brevis to enable traders to declare profits without exposing their wallets or transaction details, ensuring privacy in trade verification. Brevis is also integrated into a beforeSwap hook to verify sufficient historical trading volume before executing a trade. This enhances security and fairness while maintaining data confidentiality in Toradle's predictive trading ecosystem.
```

## 🚀 Getting Started

### Prerequisites
- Foundry/Forge
- Uniswap V4 dependencies
- Brevis SDK

### Installation
```bash
git clone <repository-url>
cd toradle-synergy-bot
forge install
```

### Build and Test
```bash
# Build contracts
forge build

# Run tests
forge test

# Deploy (replace with your network)
forge script script/Deploy.s.sol --rpc-url <your_rpc_url> --broadcast
```

### Configuration
Create a `.env` file:
```env
RPC_URL=your_rpc_url
PRIVATE_KEY=your_private_key
ETHERSCAN_API_KEY=your_etherscan_key
```

## 🔒 Security Features

### Comprehensive Hook System
```solidity
contract ComprehensiveBotHook is BaseHook {
    // Time window checks
    // Liquidity impact validation
    // Oracle price verification
    // Brevis ZK proof integration
}
```

### Swap Size Control
```solidity
contract MaxSwapSizeEnforcerHook is BaseHook {
    // Maximum swap size enforcement
    // Dynamic limits based on pool conditions
}
```

### Oracle Integration
```solidity
contract OraclePriceCheckHook is BaseHook {
    // Price deviation monitoring
    // Staleness checks
    // Multiple oracle support
}
```

## 📈 Performance Considerations

### Gas Optimization
- Efficient hook combinations
- Optimized proof verification
- Strategic use of view functions

### Modularity
- Separate specialized hooks
- Flexible hook combinations
- Upgradeable components

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
- Foundry Team

## 📞 Contact

Project Link: [https://github.com/yourusername/toradle-synergy-bot](https://github.com/yourusername/toradle-synergy-bot)

## 🚨 Disclaimer

This software is in beta. Use at your own risk. Always test thoroughly before deploying to mainnet.