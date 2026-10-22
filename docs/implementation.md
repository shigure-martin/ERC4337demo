# 同链代理执行 MVP 实现说明

## 1. 实现范围

本实现对应 [初版设计报告](initial-design.md) 的 Phase 1 主体能力：

- B 控制的 Operator 代为执行合约钱包交易。
- 钱包采用 ERC-1967 代理和 UUPS 升级。
- 自定义状态使用 ERC-7201 命名空间。
- Operator、Upgrader、Pauser、Config Admin 权限分离。
- Service Adapter 注册和启停。
- USDT 输入或输出的服务费结算。
- USDC/USDT 同链 Router swap。
- deadline、nonce、quote 重放保护和最小输出。
- 失败时整笔原子回滚。

不在当前范围：

- ERC-4337 UserOperation、Bundler 和 Paymaster。
- 实际 Bridge Adapter。
- 目标链 USDT 收费。
- 动态 Gas/USDT Oracle。
- 多签和 timelock 治理合约。
- 协议级审计和形式化验证。

## 2. 合约职责

| 合约 | 职责 |
| --- | --- |
| `WalletCore` | 资金主体、角色权限、请求校验、Adapter 调用、费用结算、暂停与升级 |
| `WalletFactory` | 使用 CREATE2 部署可预测地址的 ERC-1967 钱包代理 |
| `AdapterRegistry` | 注册 Adapter 的 ServiceType 并控制启停 |
| `RouterSwapAdapter` | 授权 Router、检查最小输出、转发结果和清理残余输入 |
| `FeePolicy` | 校验 USDT token pair、费用上限和 FeeCollector 地址 |
| `FeeCollector` | 拉取 USDT、记录总额、防止同一 quote 重复收款和提取资金 |

## 3. 执行流程

```text
Backend 生成 ExecutionRequest
          |
          v
OPERATOR_ROLE 调用 WalletCore.execute
          |
          +--> 校验 wallet、quote、nonce、deadline、Adapter 和 ServiceType
          +--> FeePolicy 校验 USDT pair、feeUSDT 和 maxFeeUSDT
          +--> 检查输入余额，USDT 输入时预留 feeUSDT
          +--> approve 精确 sellAmount 给 Adapter
          +--> Adapter 拉取输入并调用白名单 Router
          +--> 校验 buyToken 余额增量 >= minBuyAmount
          +--> 清零 Adapter allowance
          +--> FeeCollector 拉取 feeUSDT
          +--> 清零 FeeCollector allowance
          +--> 发出 ExecutionSettled
```

任何一步失败都会使整笔交易回滚。成功交易的 `quoteId` 和钱包 nonce 会前移，
避免相同请求被重复执行。

## 4. USDT 收费规则

### 4.1 USDT 为输入

请求要求钱包余额至少为 `sellAmount + feeUSDT`。Adapter 只会获得 `sellAmount` 的授权，
因此 swap 后仍有 `feeUSDT` 留在钱包中用于支付服务费。

### 4.2 USDT 为输出

Router 输出先返回 Adapter，再由 Adapter 转给钱包。钱包确认 `buyToken` 的余额增量后，
从 USDT 余额中向 FeeCollector 支付 `feeUSDT`。

`minBuyAmount` 表示收费前的输出下限。用户最终保留的 USDT 数量为：

```text
实际输出 - feeUSDT
```

### 4.3 非 USDT 交易

`FeePolicy` 会拒绝输入和输出都不是 USDT 的请求。当前实现不处理 USDT 只在目标链出现的跨链场景。

## 5. Router Adapter 约束

`adapterData` 的 ABI 编码为：

```solidity
abi.encode(router, routerCalldata)
```

Adapter 会：

1. 验证 Router 是管理员配置的白名单地址。
2. 从调用钱包拉取精确的 `sellAmount`。
3. 只向 Router 授权该数量。
4. 调用 Router 后检查输出 token 的实际余额增量。
5. 把输出转给钱包。
6. 如果 Router 未消耗全部输入，把剩余输入退回钱包。
7. 清零对 Router 的授权。

Router calldata 必须把输出接收方设置为 `RouterSwapAdapter`，否则 Adapter 无法检查输出，
交易会因最小输出不足而回滚。

## 6. 升级设计

`WalletCore` 使用 OZ v5 UUPS：

- Operator 与 Upgrader 是两个独立角色。
- `_authorizeUpgrade` 只允许 `UPGRADER_ROLE`。
- 自定义状态使用 `WalletStorage` 的 ERC-7201 slot。
- 后续实现不修改已部署的继承状态 slot。
- 测试验证升级后角色、nonce 和 token 余额保留。

生产部署必须把 `UPGRADER_ROLE` 转交多签加 timelock，并对每次实现升级进行存储布局校验。

## 7. 测试覆盖

当前测试覆盖：

- USDC -> USDT 后从输出收取 USDT。
- USDT -> USDC 时预留输入 USDT 作为费用。
- 非 Operator 无法执行。
- 过期报价、重放报价和错误 nonce。
- 费用超过策略上限。
- Adapter 被禁用。
- 滑点不足时全部状态回滚。
- 最小输出不能为 0。
- FeeCollector 拒绝重复 quote。
- 钱包暂停。
- 非 Upgrader 无法升级。
- UUPS 升级后状态和权限保持。
- Factory 预测地址与实际部署地址一致。

运行：

```bash
forge test -vv
```

## 8. 上线前必须补齐

- 将 Registry/FeePolicy/Upgrader 管理权迁移到多签和 timelock。
- 使用目标链真实 USDT 地址和实际 decimals 配置 `MAX_FEE_USDT`。
- 对每个 Router 和 Adapter 做接口、代码哈希和行为审计。
- 增加 Router calldata 的仿真、价格影响、MEV 和滑点保护。
- 实现跨链源链费用预留和失败退款策略。
- 增加 Bridge Adapter 及目标链执行器。
- 增加链上/链下对账、告警和异常报价冻结机制。
- 完成第三方安全审计后再承载真实用户资产。
