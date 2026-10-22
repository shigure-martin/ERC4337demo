# 代理执行与 USDT Gas 补偿初版设计报告

| 项目 | 内容 |
| --- | --- |
| 状态 | Draft |
| 版本 | 0.1 |
| 日期 | 2026-10-21 |
| 目标网络 | EVM 兼容链 |
| 结算资产 | USDT |

## 1. 摘要

本方案面向以下业务：用户资产存放于由服务方 B 控制的智能合约钱包，用户没有原生 Gas，
但完全信任 B。用户请求 B 代替其执行 swap 或跨链操作，B 使用自己的 ETH 提交交易，
成功后将约定数量的 USDT 转给 B 作为 Gas 和服务的补偿。

由于以下三个条件同时成立：

1. 用户账户已经是智能合约钱包；
2. B 控制该钱包的执行权限；
3. B 可以自行提交外层交易。

初版不需要 ERC-4337 的 EntryPoint、Bundler 或 Paymaster。B 直接调用钱包合约的受限执行入口，
钱包再调用经过白名单批准的 Swap Adapter，并在同一笔交易中完成 USDT 费用结算。

ERC-4337 保留为后续兼容方向，用于接入第三方 Bundler、多签验证、Session Key、
标准钱包 SDK 或跨应用统一赞助，不作为第一版的必要依赖。

## 2. 前提与范围

### 2.1 业务前提

- A 是 EVM 智能合约钱包，不是普通 EOA。
- A 的钱包控制权属于 B。
- 用户完全信任 B，允许 B 代为构造和执行交易。
- B 使用自己的 ETH 支付外层交易 Gas。
- 所有 swap 至少一侧涉及 USDT，即 USDT 为输入资产或输出资产。
- 用户在交易结束后以 USDT 向 B 支付约定的 Gas/服务补偿。
- 钱包和业务合约需要支持后续升级。
- 后续服务不限于 swap，还可能包括跨链、桥接或其他 DeFi 操作。

### 2.2 初版范围

- 同链 swap。
- USDT 作为输入或输出资产的服务费结算。
- B Operator 代为提交交易。
- 可升级的钱包核心合约。
- 可扩展的 Swap Adapter 和 Bridge Adapter 接口。
- 交易模拟、最小输出、deadline、重放保护和费用上限。
- 跨链接口预留，但初版只保证源链 USDT 可原子结算的场景。

### 2.3 非目标

- 初版不实现面向不信任管理员的非托管钱包。
- 初版不实现 ERC-4337 Paymaster、Bundler 或 UserOperation 基础设施。
- 初版不保证目标链完成交易与源链收费之间的跨链原子性。
- 初版不实现完整的做市、流动性或跨链结算网络。
- 初版不通过链上 Oracle 精确计算实际 Gas 成本，费用以 B 的报价为准。

## 3. 核心设计决策

| 决策 | 选择 | 原因 |
| --- | --- | --- |
| 交易发起方式 | B EOA 直接调用钱包 | B 已控制钱包，路径最短 |
| Gas 支付 | B 支付外层交易 Gas | 无需 Paymaster |
| 合约可升级性 | UUPS + ERC-1967 + ERC-7201 | 单钱包可独立升级，存储隔离清晰 |
| 业务扩展 | Adapter Registry | 新增 DEX 或桥无需频繁升级钱包 |
| 执行权限 | Operator 与 Upgrader 分离 | 降低热钥泄漏和误升级风险 |
| 费用资产 | USDT | 满足统一计价和收款 |
| 费用时点 | 同一交易内结算 | 避免用户先拿结果后不付费 |
| ERC-4337 | 后续可选兼容 | 当前场景没有收益足以抵消复杂度 |

## 4. 总体架构

```text
用户请求
   |
   v
B Backend
   |  1. 生成报价、调用数据和费用
   |  2. 链上模拟
   v
B Operator EOA
   |  3. 提交交易，支付 ETH Gas
   v
WalletCore (A 的可升级钱包)
   |  4. 校验权限、报价和资金
   |  5. 授权并调用 Adapter
   +--------> SwapAdapter --------> DEX / Aggregator
   |
   +--------> BridgeAdapter ------> Bridge / Intent Protocol
   |
   |  6. 成功后转 USDT 费用
   v
FeeCollector (B)
```

### 4.1 WalletCore

WalletCore 保存用户资产、执行权限、升级权限和基础会计状态。其职责包括：

- 验证调用者具有 `OPERATOR_ROLE`。
- 验证钱包未暂停、报价未过期且未执行。
- 验证 Adapter 已启用。
- 计算并预留 USDT 费用。
- 仅对 Adapter 授权本次所需的输入资产。
- 调用 Adapter 并检查最小输出。
- 成功后将 USDT 费用转给 FeeCollector。
- 发出可审计的执行和收费事件。

WalletCore 不应直接硬编码 DEX Router 或 Bridge 合约地址。

### 4.2 WalletFactory

WalletFactory 使用可预测地址部署钱包代理，并初始化：

- 钱包管理员；
- Operator；
- Upgrader 地址；
- FeeCollector；
- Adapter Registry；
- 初始实现版本。

初版使用 UUPS 代理。如果后续确认所有钱包始终共享同一实现版本，可评估切换为 Beacon Proxy，
以降低大规模统一升级的运维复杂度。

### 4.3 Service Adapter

Adapter 是协议适配层，负责封装不同 DEX 聚合器、跨链桥和 Intent 协议。

初版至少包含：

- `SwapAdapter`：执行同链 swap。
- `BridgeAdapter`：预留跨链接口。

Adapter 设计原则：

- 只有已授权的 Wallet 可以调用。
- 每次执行必须消耗任务中声明的输入数量。
- 输出应直接返回用户钱包。
- 不长期托管用户资产。
- 不允许钱包对 Adapter 保留无限授权。
- Adapter 升级或替换不能改变钱包余额和用户身份。

Adapter 可以通过 `delegatecall` 以外的受控调用完成资产转移。钱包对 Adapter 的授权必须精确到
本次交易数量，并在调用结束后清零。

### 4.4 Adapter Registry

Registry 维护 Adapter 地址、协议类型、启停状态和版本。新增服务时优先注册新 Adapter，
而不是升级所有用户钱包。Registry 的写权限应属于治理多签或专用管理员。

### 4.5 FeePolicy 与 FeeCollector

FeePolicy 负责：

- 校验 USDT 费用上限；
- 记录报价有效期；
- 允许按服务类型设置固定费用或费率；
- 在紧急情况下暂停收费；
- 保证 FeeCollector 地址发生变更时旧报价不能继续使用。

FeeCollector 负责接收钱包转出的 USDT，不参与用户资金托管。

## 5. 权限模型

建议至少拆分以下角色：

| 角色 | 权限 | 建议持有方式 |
| --- | --- | --- |
| `OPERATOR_ROLE` | 提交业务执行请求 | B 的热钱包或 HSM/API Signer |
| `UPGRADER_ROLE` | 升级 WalletCore | 多签 + timelock |
| `PAUSER_ROLE` | 暂停执行 | 多签或受监控的运维地址 |
| `ADAPTER_ADMIN_ROLE` | 新增、停用 Adapter | 多签 + timelock |
| `FEE_ADMIN_ROLE` | 修改 FeeCollector 和费用策略 | 多签 + timelock |

“用户完全信任 B”是业务前提，但不能因此让日常热钥同时拥有升级权限。即使 B 不会主动作恶，
热钥泄漏或后端漏洞仍可能导致全部钱包被转移。

Operator 不应直接获得无限制的任意 `call` 能力，而应通过 Service Adapter 执行已注册的业务。
如果确有通用调用需求，应使用严格的 target、selector 和参数策略。

## 6. 执行数据结构

建议的交易请求至少包含：

```solidity
struct ExecutionRequest {
    bytes32 quoteId;
    address wallet;
    uint8 serviceType;
    address adapter;
    address sellToken;
    address buyToken;
    uint256 sellAmount;
    uint256 minBuyAmount;
    uint256 feeUSDT;
    uint256 maxFeeUSDT;
    uint64 deadline;
    uint256 nonce;
    bytes adapterData;
}
```

字段约束：

- `quoteId` 全局唯一，并参与链上重放检查。
- `adapter` 必须处于启用状态。
- `sellToken` 或 `buyToken` 必须是当前链的 USDT。
- `feeUSDT <= maxFeeUSDT`。
- 同链 swap 必须校验 `buyToken` 的实际余额增量不低于 `minBuyAmount`。
- `deadline` 防止旧报价被延迟执行。
- `nonce` 防止同一钱包的请求被重复提交。
- `adapterData` 至少绑定 Router、method selector、滑点参数和收款地址摘要。

后端在签名或发送交易前应先模拟完整执行，包括：

- 授权和余额检查；
- Router 返回值和实际输出检查；
- 最小输出；
- USDT 费用转账；
- Gas 估算及安全缓冲。

## 7. 同链 Swap 流程

1. 用户向 B 提交 swap 意图。
2. B Backend 获取报价，生成 `ExecutionRequest` 和费用。
3. Backend 在目标区块状态下执行 `eth_call` 或节点模拟。
4. B Operator 调用 WalletCore。
5. WalletCore 校验 Operator、Adapter、deadline、nonce 和费用上限。
6. WalletCore 根据输入或输出资产是否为 USDT，预留或确认可用费用。
7. WalletCore 仅授权 Adapter 所需的 `sellAmount`。
8. Adapter 调用 DEX 或 Aggregator。
9. WalletCore 检查实际输出。
10. WalletCore 将 `feeUSDT` 转给 FeeCollector。
11. WalletCore 清零 Adapter allowance，并发送执行事件。

以上步骤必须在同一笔 EVM 交易内原子完成。任何一步失败，整笔交易回滚，B 自行承担失败交易的 Gas。

## 8. USDT Gas 补偿设计

### 8.1 USDT 为输出资产

适用于 `USDC -> USDT` 等场景：

1. 输入资产被换成 USDT。
2. 钱包收到至少 `minBuyAmount` 的 USDT。
3. 从钱包 USDT 余额中扣除 `feeUSDT`。
4. 剩余 USDT 保留在用户钱包。

这是最直接的结算路径。

### 8.2 USDT 为输入资产

适用于 `USDT -> USDC` 等场景：

1. 钱包可用 USDT 余额必须不少于 `sellAmount + feeUSDT`。
2. Adapter 只获得 `sellAmount` 的授权。
3. swap 完成后，钱包仍保留 `feeUSDT`。
4. 再将 `feeUSDT` 转给 FeeCollector。

虽然链上顺序是 swap 后收费，但费用必须在报价和可执行余额检查阶段就已预留。

### 8.3 USDT 同时为输入和输出

适用于 USDT 币种或链间形式转换。默认从输出 USDT 中收费；如果 Adapter 无法保证输出余额，
则由 FeePolicy 明确指定费用来源，禁止同一请求同时从输入和输出重复扣费。

### 8.4 费用报价

链上无法直接获知完整实际成本，尤其是：

- 最终 `gasUsed`；
- L2 的 L1 data fee；
- Operator 的基础设施成本；
- 业务服务费；
- Gas 价格在执行期间的波动。

因此初版由 B Backend 计算并传入 `feeUSDT`，WalletCore 只负责校验和执行。建议报价公式为：

```text
报价费用 =
  预估原生 Gas 成本换算为 USDT
  + 安全缓冲
  + 服务费
```

报价必须有 deadline 和最大费用上限。实际收款以报价中的 USDT 数量为准，不承诺与交易回执中的
实际 Gas 严格相等。Backend 应保存报价时的 Gas 估算、原生币价格、缓冲比例和实际回执，用于对账。

### 8.5 事件记录

建议至少发出以下事件：

```solidity
event ExecutionSettled(
    bytes32 indexed quoteId,
    address indexed wallet,
    address indexed adapter,
    address sellToken,
    address buyToken,
    uint256 sellAmount,
    uint256 buyAmount,
    uint256 feeUSDT
);
```

执行成功但未收费、收费但 Adapter 返回异常等状态应在 Adapter 返回值或业务事件中明确区分。

## 9. 跨链设计

### 9.1 一致性边界

跨链操作无法依靠单笔源链交易保证目标链一定成功，因此不能直接沿用同链“目标资产到账后收费”的模型。

初版只承诺以下跨链收费模式：

1. 源链钱包持有 USDT；
2. 在发起 bridge 前预留 `feeUSDT`；
3. bridge 成功发起后，将预留费用转给 FeeCollector；
4. 目标链失败时的退款和补偿由 Bridge Adapter 的业务规则处理。

如果 USDT 只在目标链出现，源链无法在同一笔交易中取得该 USDT，必须采用以下方案之一：

- 目标链执行器确认到账后二次收费；
- 用户在源链预存 USDT；
- 使用支持源链费用结算的 Intent/Bridge 协议；
- 引入目标链信用额度或做市流动性。

上述模式存在额外信任、流动性和失败处理成本，不纳入初版强保证。

### 9.2 Bridge Adapter

BridgeAdapter 应统一处理：

- 源链和目标链标识；
- 目标地址；
- 跨链消息 ID；
- 源链实际扣款；
- bridge 状态回调或事件；
- 目标链执行失败策略；
- 重复领取和重放保护。

不同桥的最终性和失败语义不同，Adapter 不应假装所有桥具有相同的同步返回结果。

## 10. 可升级设计

### 10.1 代理模式

初版推荐 UUPS：

- 钱包地址和用户资产地址保持不变；
- 每次钱包可以单独选择是否升级；
- 使用 ERC-1967 实现槽；
- 使用 ERC-7201 命名空间存储业务状态；
- `_authorizeUpgrade` 只允许 `UPGRADER_ROLE` 调用。

如果钱包数量很大且业务逻辑始终统一，可在实施前评估 Beacon Proxy。Beacon 的优点是升级一次即可
影响所有钱包，缺点是单个钱包难以独立升级，升级故障的影响范围更大。

### 10.2 升级安全要求

- 实现合约的初始化函数必须防止被重复初始化。
- 升级多签与 Operator 热钥隔离。
- 升级通过 timelock 执行，并提前发布实现地址和代码哈希。
- 每次升级必须有存储布局检查、单元测试和链上 fork 测试。
- 新实现必须能读取旧版本的所有关键状态。
- 钱包升级不能改变用户地址，也不能要求用户迁移资产。
- Adapter 或 Router 变更后，应清理旧授权。
- 升级期间可以暂停新请求，但不应影响现有资金的查看和紧急提取。

### 10.3 版本与迁移

WalletCore 至少维护：

- `implementationVersion`；
- 配置版本；
- Adapter Registry 版本；
- FeePolicy 版本。

需要迁移时采用显式、幂等的 `migrate` 函数。迁移只能由 timelock 触发，并记录迁移前后版本。

## 11. 安全与风控

### 11.1 合约安全

- 使用 `ReentrancyGuard` 保护执行入口。
- 使用 SafeERC20 兼容不标准返回值的 token。
- 对 fee-on-transfer token 使用实际余额差而不是假定转账数量。
- 校验 Adapter 的实际拉取数量和钱包余额变化。
- Approve 精确数量，并在执行后清零。
- 禁止通过 delegatecall 调用未审计实现。
- 对 WalletFactory 部署地址实施 CREATE2 地址验证。
- 对 Owner/Operator/Upgrader 变更发出事件。
- 对暂停状态和紧急提取设置独立权限。

### 11.2 经济安全

- 报价包含 deadline、最大 USDT 费用和滑点限制。
- 钱包余额不足以同时满足输入和费用时，整笔回滚。
- 交易失败不收费，B 承担失败 Gas。
- 跨链费用在源链结算时，必须定义目标链失败后的退款规则。
- FeeCollector 和 Operator 地址应分离，允许只更换收款地址而不更换执行权限。

### 11.3 运营安全

- Backend 在发送前执行模拟，并检查 Router/Adapter 的代码哈希。
- 对单用户、单日和服务类型设置费用和交易额上限。
- 对 adapter allowlist、费率、FeeCollector 的变更设置 timelock。
- 监控执行失败、费用异常、授权残留和升级事件。
- 对用户展示报价、最小到账、费用和跨链失败规则。

## 12. ERC-4337 的后续接入

当出现以下需求时，再评估接入 ERC-4337：

- 用户需要自行签名 UserOperation；
- 需要第三方 Bundler 提交交易；
- 需要标准 Sponsorship Paymaster；
- 需要 Session Key、社交恢复或多验证器；
- 需要兼容现有以 UserOperation 为中心的钱包和 SDK。

接入时可以让 WalletCore 同时实现 `IAccount.validateUserOp`，并保持现有 Operator 执行入口。
ERC-4337 只改变交易提交和授权入口，不应改变底层 Swap/Bridge Adapter 与 USDT FeePolicy。

当前场景中，4337 会额外引入 EntryPoint、Bundler、Paymaster 签名和 UserOperation 模拟，
却没有减少 B 的 ETH Gas 成本，因此不作为 MVP。

## 13. 分阶段实施

### Phase 1：同链 MVP

- WalletProxy、WalletFactory、WalletCore。
- Operator 执行与暂停。
- Adapter Registry。
- 一个 USDC/USDT SwapAdapter。
- USDT 输入和输出两种收费路径。
- 最小输出、deadline、nonce 和费用上限。
- 基础事件与模拟脚本。

### Phase 2：运营能力

- FeePolicy 和 FeeCollector 管理。
- 多协议 SwapAdapter。
- 报价服务、报价签名或请求摘要。
- 监控、对账和失败告警。
- 批量部署和版本管理。

### Phase 3：跨链

- BridgeAdapter 接口和首个桥实现。
- 源链 USDT 费用预留。
- 跨链状态跟踪。
- 目标链失败处理和退款策略。

### Phase 4：可选 4337

- `IAccount` 兼容层。
- Sponsorship Paymaster。
- Session Key 和更细粒度授权。
- 第三方 Bundler 接入。

## 14. 验收标准

- `USDC -> USDT` 成功后，用户收到最小输出扣除 USDT 服务费后的余额。
- `USDT -> USDC` 时，输入 USDT 和服务费被正确预留，不能导致余额不足。
- 非 Operator 无法执行钱包业务交易。
- 非 Upgrader 无法升级钱包。
- 过期报价、重复报价和超限费用均被拒绝。
- Adapter 失败、滑点不足或费用转账失败时整笔回滚。
- 钱包升级后余额、角色、nonce 和历史状态保持不变。
- 新增 Adapter 不需要逐个升级所有用户钱包。
- 跨链源链收费不会把目标链成功作为同步前提。
- 所有执行、费用和权限变更都有可对账事件。

## 15. 待确认事项

- 首版目标链及 USDT 合约版本。
- WalletCore 最终采用 UUPS 还是统一 Beacon 升级。
- 是否需要在初版就支持多个 Operator。
- 用户只持有 USDT 输出、USDT 输入，还是两种都需要首批支持。
- FeeCollector、Operator、治理多签分别使用哪些地址。
- 首批 Swap 和 Bridge 协议。
- 跨链失败后的退款责任和用户告知方式。
- USDT 服务费采用固定费用、按比例收费，还是两者组合。

## 16. 参考资料

- [ERC-4337: Account Abstraction Using Alt Mempool](https://eips.ethereum.org/EIPS/eip-4337)
- [ERC-4337 Paymaster Types](https://docs.erc4337.io/paymasters/types.html)
- [EIP-7702: Set EOA account code](https://eips.ethereum.org/EIPS/eip-7702)
- [account-abstraction v0.9.0](https://github.com/eth-infinitism/account-abstraction/releases/tag/v0.9.0)
- [ERC-7201: Namespaced Storage Layout](https://eips.ethereum.org/EIPS/eip-7201)
