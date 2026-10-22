# Operator-Driven Smart Wallet

基于 Foundry 的合约钱包代理执行 MVP。Operator 使用自己的 ETH 提交交易，
合约钱包执行经过注册的 Service Adapter，并在同一笔交易中从用户 USDT 余额收取服务费。

初版聚焦同链 USDC/USDT swap，不依赖 ERC-4337 EntryPoint、Bundler 或 Paymaster。

## 快速开始

Foundry 安装在非标准目录时，先将它加入 `PATH`：

```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge install foundry-rs/forge-std@v1.11.0 --no-git --shallow
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-git --shallow
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.4.0 --no-git --shallow
forge build
forge test -vv
```

## 目录

```text
src/
  WalletCore.sol                 UUPS 钱包核心、权限、报价执行和费用结算
  WalletFactory.sol              CREATE2 钱包代理工厂
  AdapterRegistry.sol            Service Adapter 注册与启停
  FeePolicy.sol                  USDT 费用与收款地址策略
  FeeCollector.sol               USDT 收款、对账和提取
  adapters/RouterSwapAdapter.sol 通用 Router swap 适配器
  mocks/                         本地测试 token 与 Router
script/Deploy.s.sol              目标链基础设施部署脚本
test/WalletCore.t.sol            端到端和权限/升级测试
docs/                            设计报告与实现说明
```

## 部署

准备参数：

```bash
cp .env.example .env
```

然后执行：

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

部署账户会成为 Registry、Adapter、FeePolicy 和 WalletFactory 的默认管理员。
`ROUTER` 非零时，脚本会同时允许该 Router 并注册 `RouterSwapAdapter`。

## Router 接入约束

`RouterSwapAdapter` 会在调用 Router 前把输入 token 从钱包拉到 Adapter。
因此真实 Router calldata 必须把输出接收方设置为 Adapter 地址，而不是用户钱包：

```text
Wallet -> RouterSwapAdapter -> allowlisted Router -> RouterSwapAdapter -> Wallet
```

Adapter 根据自身的输出 token 余额变化检查 `minBuyAmount`，再把输出转发给钱包。

## 状态

这是可运行的初版实现，不是已审计的生产代码。当前只实现同链 swap；
Bridge Adapter、目标链收费、动态 Gas Oracle、多 Operator 审批和治理合约仍需后续实现。

详细设计见 [初版设计报告](docs/initial-design.md)，实现边界见
[实现说明](docs/implementation.md)。
