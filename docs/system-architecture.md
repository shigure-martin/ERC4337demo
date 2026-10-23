# 多链代理执行系统总体架构设计

| 项目 | 内容 |
| --- | --- |
| 状态 | Review Draft |
| 版本 | 0.1 |
| 日期 | 2026-10-23 |
| 范围 | 多 EVM、Solana、Swap、Bridge、Go Backend |
| 关联文档 | [初版设计报告](initial-design.md)、[EVM MVP 实现说明](implementation.md) |

## 1. 文档目的

本文定义代理执行系统的完整技术架构，覆盖：

- EVM 智能合约钱包。
- Solana Wallet Program。
- Router、Selector、Program 和 Instruction 白名单。
- 同链 Swap。
- EVM → EVM、EVM → Solana、Solana → EVM 的跨链执行。
- Go 报价、执行、签名、广播、索引和对账后端。
- 部署、可观测性、故障恢复、测试和实施顺序。

本文是当前架构审阅基线。`initial-design.md` 描述业务需求和用户流程，本文件描述系统如何实现这些需求。

## 2. 核心结论

系统采用“**链上受限执行 + 链下统一编排 + 独立签名服务**”架构：

1. 用户只提交业务意图，不提交任意 EVM calldata、Solana CPI 或任意 Program 指令。
2. EVM `WalletCore` 和 Solana Wallet Program 在授权资产前强制调用白名单。
3. Router、Selector、Bridge 合约和 Solana Program/Instruction 由独立白名单控制。
4. Go 后端负责报价、路由选择、模拟、交易构造、签名调度、广播、重试、跨链状态和对账。
5. 后端运行时全部使用 Go，不依赖 Node.js。
6. 初版不使用多签和 timelock；使用独立 Operator、Config Admin 和 Upgrade Admin 密钥。
7. 链上结果是资金事实来源；数据库只保存工作流、幂等键、交易尝试和对账数据。

## 3. 范围与非目标

### 3.1 范围内

- 一条或多条 EVM 链。
- Solana mainnet/devnet 或指定 cluster。
- Gobull 控制用户 EVM 钱包和 Solana WalletState。
- 用户首次使用 Gobull 产品前，系统必须为其创建并初始化合约钱包。
- 同链 Swap。
- EVM ↔ EVM 以及 EVM ↔ Solana 跨链 Swap 或资金桥接。
- 可升级 EVM WalletCore 和 Solana Wallet Program。
- 白名单驱动的 DEX、Aggregator 和 Bridge 接入。
- Go 后端、数据库、队列、索引器、签名器和运维接口。

### 3.2 非目标

- 不实现非托管或无需信任管理员的钱包。
- 不实现 ERC-4337 Bundler 和 Paymaster。
- 不实现链下资产托管。
- 不实现 KYC、风控决策系统、做市和完整财务系统。
- 不承诺跨链 source 与 destination 交易原子完成。
- 不支持未经审计的任意 Router、Program 或 Instruction。
- 不把 EVM ABI 直接复用到 Solana。
- 不定义产品费用、费率、收费时点、退款、补偿或业务失败处置规则。

### 3.3 产品策略边界

费用和业务失败处理由产品经理另行设计。本文件只讨论网络费用支付、交易执行和系统可靠性，
不定义向用户收取多少费用、何时收取、如何退款，以及业务失败后的补偿规则。

这些产品策略接入系统时，通过独立接口和配置提供给执行层。本文不约束其计算公式和业务状态。

## 4. 信任模型

### 4.1 参与方

| 参与方 | 职责 |
| --- | --- |
| 用户 | Gobull 产品的使用者；信任 Gobull 并持有其创建的链上钱包 |
| Gobull | 产品运营方和钱包控制方，负责钱包创建、执行、后端和密钥基础设施 |
| Operator | Gobull 的热执行地址，提交 Swap/Bridge 请求 |
| Config Admin | 修改白名单、暂停状态和执行配置 |
| Upgrade Admin | 升级 EVM WalletCore 和 Solana Wallet Program |
| Backend | 生成报价、构造交易、模拟、调度和状态跟踪 |
| Provider | DEX、Aggregator、Bridge 或 Intent 协议 |

### 4.2 安全边界

- 用户无需持有 ETH 或 SOL。
- EVM Operator 使用自己的 ETH 支付外层交易 Gas。
- Solana Operator 作为 fee payer 和 signer 支付 SOL。
- 用户不签署 EVM 交易或 Solana 顶层交易。
- 链上只承认白名单内的执行目标。
- Backend 不能直接升级合约、Program 或修改白名单。
- Provider 必须视为不可信外部系统，所有返回结果必须模拟和校验。

### 4.3 明文信任假设

用户完全信任 Gobull。Gobull 拥有账户资产控制权，因此以下能力无法通过技术架构消除：

- Gobull 可以通过白名单内协议执行用户资产。
- Upgrade Admin 可以改变钱包实现或 Program 代码。
- Config Admin 可以调整白名单和暂停状态。

技术架构必须保证：

- Operator 不能修改白名单。
- Operator 不能升级合约或 Program。
- Config Admin 和 Upgrade Admin 不进入日常在线执行环境。
- 任一权限密钥泄漏后都有独立暂停路径。

### 4.4 用户钱包创建前置流程

用户开始使用 Gobull 产品时，必须先完成链上钱包创建。任何 Swap、Bridge 或提现请求都不得
在钱包未完成创建和验证前进入执行阶段。

创建流程：

```text
User 登录 / 开通 Gobull
  -> 查询 user_id + chain_id 钱包映射
  -> 不存在时创建 EVM Smart Wallet 或 Solana WalletState
  -> 初始化 Operator、配置引用和权限
  -> 创建所需 Token Account / Working Account
  -> 验证链上代码、PDA、Owner 和版本
  -> 保存钱包映射并标记 ACTIVE
  -> 允许创建交易 Intent
```

EVM：

- 由 WalletFactory 通过 CREATE2 创建 ERC-1967 Proxy。
- 调用 WalletCore 初始化。
- 验证代理 code、实现版本和角色。

Solana：

- 由 Gobull 后端发起 WalletState PDA 创建。
- 初始化 ServiceConfig 引用、Operator、nonce 和版本。
- 创建用户需要的 Associated Token Account 和 Working Token Account。
- 验证 PDA、Account Owner、Mint、Token Program 和 authority。

创建流程必须幂等。若链上钱包已存在，只做配置和版本校验，不重复部署。

## 5. 系统上下文

```text
                      +----------------------+
                      | User / Business API  |
                      +----------+-----------+
                                 |
                                 v
                    +----------------------------+
                    | Go API / Intent Service    |
                    | Auth, Idempotency, Limits  |
                    +-------------+--------------+
                                  |
              +-------------------+-------------------+
              |                                       |
              v                                       v
     +------------------+                    +------------------+
     | Quote/Policy     |                    | Admin Control    |
     | Asset Registry   |                    | Adapter/Whitelist|
     +--------+---------+                    +------------------+
              |
              v
     +-----------------------------+
     | Execution Orchestrator      |
     | State Machine + Outbox      |
     +------+---------------+------+
            |               |
            v               v
     +------------+   +-------------+
     | EVM Worker |   | Solana      |
     | per chain  |   | Worker      |
     +-----+------+   +------+------+
           |                 |
           +------+----------+
                  v
          +----------------+
          | Signer Service |
          | KMS / HSM      |
          +-------+--------+
                  |
        +---------+---------+
        |                   |
        v                   v
  EVM WalletCore      Solana Wallet Program
        |                   |
  WhitelistRegistry    Whitelist Program
        |                   |
  Swap/Bridge Adapter  Swap/Bridge Adapter
        |                   |
        +---------+---------+
                  v
             DEX / Bridge
                  |
                  v
      Indexer + Reconciler + Alerts
                  |
                  v
        PostgreSQL / NATS / Redis
```

## 6. 服务边界

### 6.1 API Service

用户和内部业务方唯一入口：

- 创建 Swap Intent。
- 创建 Bridge/Cross-chain Intent。
- 查询报价、执行状态、交易哈希和失败原因。
- 查询最终到账数量。
- Webhook 或回调重试。

API 不接受任意 EVM calldata、Solana Instruction、私钥或外部签名文件。

### 6.2 Quote Service

统一生成客户端无关的报价：

```text
quote_id
user_id
source_chain
destination_chain
service_type
sell_asset
buy_asset
sell_amount
expected_buy_amount
min_buy_amount
deadline
generated_at
source_block_height_or_slot
route_digest
```

Quote Service 负责调用 DEX/Bridge Provider，但不负责签名和广播。

### 6.3 Policy Service

执行前检查：

- 用户和钱包是否启用。
- 钱包是否暂停。
- 单笔、单日和单资产限制。
- 目标链、Adapter、Router、Program 是否启用。
- 报价是否过期。
- 目标地址和 Token Account 是否有效。

Policy Service 的检查不替代链上 Whitelist。

### 6.4 Execution Orchestrator

负责工作流和状态机：

- 将 Intent 分解为 source/destination execution legs。
- 锁定报价和 route digest。
- 调用链下模拟。
- 请求 Signer Service 签名。
- 派发 EVM/Solana Worker。
- 跟踪确认并推进状态。
- 处理技术重试、交易替换和人工介入。

### 6.5 Chain Worker

EVM Worker 负责：

- ABI 编码。
- nonce 分配和锁。
- Gas、priority fee 和 fee bump。
- 调用 WalletCore。
- 交易广播、receipt 和 reorg 检查。

Solana Worker 负责：

- 生成 Instruction 和 Account Meta。
- 获取最新 blockhash。
- 请求或复用 Address Lookup Table。
- 设置 Compute Unit limit 和 price。
- 构造 legacy/v0 transaction。
- 模拟、签名、广播和 finalized 确认。
- blockhash 过期后安全重建交易。

### 6.6 Signer Service

独立网络和权限边界：

- 私钥保存在 KMS/HSM 或隔离签名进程。
- Backend 只能发送待签名交易摘要和策略上下文。
- 签名前验证 chain ID、Wallet/Program ID、白名单目标、金额和 deadline。
- 记录每次签名请求、审批结果和交易摘要。
- Operator 密钥和 Upgrade/Config 密钥不得共存于同一服务。

### 6.7 Cross-chain Coordinator

负责：

- source leg 和 destination leg 关联。
- 链上最终性判断。
- Bridge/message ID 跟踪。
- 目标链执行调度。
- 技术超时、重试和人工处置状态。
- 双链事件对账。

### 6.8 Indexer / Reconciler

订阅 EVM event 和 Solana Program logs/账户变化：

- 确认交易最终状态。
- 校验钱包资产变化。
- 发现数据库与链上状态不一致。
- 触发卡单、余额异常和 RPC 异常告警。

### 6.9 Admin Control Plane

管理：

- 链和 RPC。
- 资产和 Token Program。
- Whitelist 规则。
- Adapter 版本。
- 全局/单钱包暂停。
- 运维手动重试和故障处置。

Admin API 与用户 API 使用不同认证、网络和审计日志。

### 6.10 Swap Calldata 时效性

Swap/Bridge Provider 返回的 calldata、Solana Instruction 和账户列表具有时效性。路由生成后
价格、流动性、Pool/Route Account、白名单版本和链上状态都可能发生变化。过期 artifact
不能继续签名或广播。

每次执行保存完整 route artifact：

```text
route_id
quote_id
chain_id / cluster
generated_at
expires_at
deadline
source_block_height / slot
route_digest
target
selector_or_instruction_discriminator
calldata_or_instruction_data
account_metas
adapter_version
whitelist_version
min_buy_amount
```

执行约束：

1. Route TTL 必须小于或等于 Provider deadline 和业务 quote deadline。
2. 签名前重新获取 nonce、blockhash、block height/slot 和钱包状态。
3. 若链上高度/slot、Pool 状态、账户列表或白名单版本超出允许偏差，必须重新报价。
4. 签名前重新执行 `eth_call`、`simulateTransaction` 或 Solana 本地模拟。
5. 模拟结果必须仍满足 `min_buy_amount`，且实际 target/selector/discriminator 与白名单一致。
6. Signer Service 拒绝已过期 artifact。
7. 每次技术重试都必须重新创建 route artifact，不能复用旧 calldata 或旧 Solana blockhash。

EVM：

- 校验 Provider calldata 内的 deadline、recipient、amount 和 min output。
- 重新模拟时使用即将签名交易的 nonce 和最新 block。
- Router/Selector 白名单检查在交易执行时再次生效。

Solana：

- blockhash、Address Lookup Table、Route accounts 和 Compute Unit limit 必须重新确认。
- 任何 Account Meta 或 Token Account 变化都要重新构建交易。
- 旧 blockhash 或旧 account list 不得在新交易中重新使用。

## 7. EVM 链上架构

### 7.1 当前与目标状态

| 模块 | 当前状态 | 目标 |
| --- | --- | --- |
| `WalletCore` | 已实现 UUPS MVP | 接入独立 WhitelistRegistry |
| `WalletFactory` | 已实现 CREATE2 | 保持 |
| `AdapterRegistry` | 已实现 | 保留 ServiceType 与 Adapter 状态 |
| `RouterSwapAdapter` | 本地 Router 白名单 | 删除本地 Router 白名单，改为统一验证 |
| WhitelistRegistry | 未实现 | 新增 |
| BridgeAdapter | 未实现 | 新增 |

### 7.2 合约职责

```text
WalletFactory
  -> 部署 WalletCore ERC-1967 Proxy

WalletCore
  -> 校验 Operator、quote、nonce、deadline、金额
  -> 查询 WhitelistRegistry
  -> 精确 approve
  -> 调用 Adapter
  -> 校验输出

WhitelistRegistry
  -> 管理 Adapter、target、selector 和 service type

Adapter
  -> 调用已通过链上验证的 DEX/Bridge target
```

### 7.3 WhitelistRegistry

建议接口：

```solidity
struct WhitelistEntry {
    bool enabled;
    uint32 policyVersion;
}

function isAllowed(
    ServiceType serviceType,
    address adapter,
    address target,
    bytes4 selector
) external view returns (bool);
```

规则键：

```text
serviceType + adapter + target + selector
```

约束：

- 只有 Config Admin 可以新增、修改和停用规则。
- Operator 和 Adapter 不得修改规则。
- 规则变更必须发出 event。
- `target.code.length > 0`。
- `selector` 必须来自实际调用 calldata。
- WhitelistRegistry 本身建议使用稳定 ABI 和非可升级实现，降低升级攻击面。
- WalletCore 通过稳定接口读取规则；需要替换 Registry 时由 Config Admin 更新引用。

### 7.4 EVM 执行流程

```text
Operator
  -> WalletCore.execute(request)
       1. 校验 wallet、quote、nonce 和 deadline
       2. WhitelistRegistry.isAllowed(service, adapter, target, selector)
       3. 校验 sell/buy token 和 USDT 余额
       4. 精确 approve adapter
       5. Adapter.execute(target, callData)
       6. target / Router / Bridge 执行
       7. 校验 buy token 余额增量
       8. 清除 allowance
       9. emit ExecutionSettled
```

`ExecutionRequest` 应显式包含：

```solidity
address adapter;
address target;
bytes4 selector;
bytes callData;
```

禁止仅把 `target` 和 `selector` 隐藏在 `adapterData` 中，否则无法保证白名单检查目标与实际调用目标一致。

### 7.5 Bridge Adapter

Bridge Adapter 与 Swap Adapter 使用同一白名单模型。请求至少包含：

- source/destination chain ID。
- source target 和 selector。
- destination domain/chain ID。
- destination recipient。
- sell amount。
- min destination amount。
- bridge message 参数。
- quote 和 deadline。

`target` 通常是 Bridge 合约，`selector` 是存款、发送或消息提交入口。

## 8. Solana 链上架构

### 8.1 Program 组成

```text
Wallet Program
  - ServiceConfig
  - WalletState
  - 白名单引用与暂停配置

Whitelist Program
  - Adapter Program 规则
  - Target Program 规则
  - Instruction discriminator/tag

Swap Adapter Program
  - DEX/Aggregator CPI

Bridge Adapter Program
  - Bridge/Intent CPI
```

初版允许 Swap Adapter 和 Bridge Adapter 位于同一个 Program 中，但必须按 service type 隔离指令。

### 8.2 账户模型

| Account | Owner | 用途 |
| --- | --- | --- |
| `ServiceConfig` PDA | Wallet Program | Operator、USDT Mint、白名单引用和暂停 |
| `WalletState` PDA | Wallet Program | 用户 ID、nonce、权限、版本 |
| 用户主 Token Account | Token Program | WalletState 作为 authority |
| Working Token Account | Token Program | 单次执行隔离输入资产 |
| `AdapterConfig` PDA | Whitelist Program | Adapter 和 target Program 白名单 |
| Whitelist Config PDA | Whitelist Program | 管理员、版本和全局暂停 |

`WalletState` seeds：

```text
[b"wallet", user_id]
```

Program 使用 `invoke_signed` 代表 WalletState 签名。

### 8.3 Solana 白名单

Solana 没有 EVM selector。白名单键定义为：

```text
service_type
+ adapter_program_id
+ target_program_id
+ instruction_discriminator_or_tag
+ policy_version
```

Wallet Program 执行 Adapter CPI 前：

1. 验证 Whitelist Program ID 和 Config PDA。
2. CPI 调用白名单 verify instruction 或读取受信 Whitelist Account。
3. 验证 Adapter Program ID。
4. 验证 Target Program ID。
5. 验证 instruction data 的 discriminator/tag。
6. 验证 route 账户没有引入未经允许的用户 Token Account。

白名单检查必须发生在 Token 授权和 Adapter CPI 之前。

### 8.4 Working Token Account 隔离

Solana 没有 ERC-20 allowance。不得把 WalletState 的全部主 Token Account 暴露给 Adapter。

执行流程：

1. 从用户主 sell ATA 将精确 `sell_amount` 转入 Working ATA。
2. 只把 Working ATA、目标 buy ATA 和 Route accounts 传给 Adapter。
3. Adapter 通过 WalletState PDA signer 执行 CPI。
4. Wallet Program 校验 Working ATA 的输入余额已耗尽。
5. Wallet Program 校验用户 buy ATA 的余额增量。
6. 成功后发出执行结果事件。

Working ATA 只接收本次 `sell_amount`，执行完成后不得有预期外残留。

### 8.5 Solana fee payer

- 每笔交易只有一个 fee payer。
- fee payer 必须是 message 的第一个账户和 signer。
- fee payer 必须是 System Program 所有账户或合法 nonce account。
- WalletState PDA 不能作为顶层 fee payer。
- Gobull 的 Operator 作为 fee payer，支付 base fee 和 priority fee。
- Gobull 的 Operator 和 fee payer 初版使用同一地址，减少签名和账户开销。

### 8.6 交易构建限制

Solana Worker 必须处理：

- legacy/v0 交易大小 1,232 bytes。
- versioned transaction 和 Address Lookup Table。
- Compute Unit limit 与 price。
- blockhash 有效期。
- Account Meta 排序和去重。
- Adapter CPI account 数量。
- Token-2022 transfer hook 的附加账户。

无法在单笔交易中原子执行的 Route 必须拒绝，不能拆成可被单独利用的多笔交易。

## 9. 跨链架构

### 9.1 支持的路由类型

| 路由 | 源链执行 | 目标链执行 | 初版优先级 |
| --- | --- | --- | --- |
| 同链 | Swap Adapter | 无 | 必须 |
| EVM → EVM | EVM Bridge Adapter | 目标 EVM Swap/Bridge Adapter | 必须 |
| EVM → Solana | EVM Bridge Adapter | Solana Adapter Program | 必须 |
| Solana → EVM | Solana Bridge Adapter Program | 目标 EVM Swap/Bridge Adapter | 必须 |

所有路由共享同一个 Intent、Quote、Execution Leg 和 Reconciliation 模型。具体桥、资产表示和
目标链执行方式由 Chain Pair Policy 决定。

### 9.2 总体流程

```text
Intent
  -> Chain/Asset/Risk Validation
  -> Source Quote
  -> Source Execution
  -> Source Finality
  -> Bridge / Intent Message
  -> Destination Detection
  -> Destination Execution
  -> Final Reconciliation
```

### 9.3 EVM → EVM 执行模型

EVM → EVM 不允许假设“同一条链上的合约可以跨链原子调用”。源链和目标链各自有独立交易、
nonce、Gas 和最终性。

初版推荐使用“两段式编排”：

```text
Source EVM Operator
  -> Source WalletCore
  -> Source BridgeAdapter
  -> Bridge
  -> Destination User Wallet / Bridge Receiver

Destination EVM Operator
  -> Destination WalletCore
  -> Destination SwapAdapter
  -> Destination USDT / Target Asset
```

执行步骤：

1. 确认目标链已存在用户 WalletCore 和目标 Token Account。
2. Source Worker 在源链执行 Bridge，并记录 bridge message/deposit ID。
3. Coordinator 等待源链 finality 和 Bridge Provider 的目标链状态。
4. Destination Worker 等待跨链资产到账或 Bridge Receiver 完成验证。
5. Gobull 的目标链 Operator 执行目标链 Swap。
6. Indexer 校验目标钱包余额。
7. Coordinator 将 Intent 标记为 `COMPLETED`。

初版不建议给目标 WalletCore 开放通用 Bridge Executor 权限。Gobull 已控制目标钱包，由目标链
Operator 执行第二段更简单，也避免在不同 Bridge Provider 之间引入复杂的跨链消息验证逻辑。

对于需要全自动目标链执行的 Provider，可以增加受限 `BridgeReceiver`：

- 验证 source chain/domain、sender、nonce、message ID 和 payload hash。
- 只允许调用预先授权的一次性 settlement intent。
- 不授予通用 `execute` 权限。
- 必须防重复领取和跨链重放。

### 9.4 EVM 钱包与资产映射

- 用户身份使用内部 `user_id`，不能假设各 EVM 链钱包地址相同。
- 如果使用 CREATE2 得到相同地址，只作为一种地址复用优化，不作为业务约束。
- 数据库必须保存 `user_id + chain_id -> wallet address`。
- `USDT` 是业务资产标识，实际合约地址按 EVM chain ID 配置。
- 原生 USDT、第三方桥接 USDT 和 wrapped USDT 必须视为不同链上资产，除非资产策略明确将其等价。
- 目标链接收地址必须是用户目标 WalletCore 或经过验证的 Bridge Receiver。
- 目标链必须先部署目标 WalletCore 和所需 Token Account，不能让桥直接发往无法处理的地址。

### 9.5 Bridge Adapter 与 Chain Pair Policy

每个 EVM 源链的 Bridge Adapter 仍通过 WhitelistRegistry 检查：

```text
serviceType + bridgeAdapter + bridgeTarget + bridgeSelector
```

Chain Pair Policy 至少记录：

- source chain ID。
- destination chain ID 或 Solana cluster。
- Bridge Provider。
- source bridge target 和 selector。
- destination receiver/Program。
- bridge domain ID。
- source/destination token address 或 Mint。
- source/destination decimals。
- source required confirmations。
- destination execution adapter。

目标链 Bridge Receiver 或目标 WalletCore 也必须验证 Provider 身份和消息来源。

### 9.6 统一标识

- 全局 `quote_id`: 32 bytes。
- 链身份：EVM chain ID 或 Solana genesis hash/cluster。
- 用户身份：内部 `user_id`。
- 钱包身份：EVM address 或 Solana WalletState PDA。
- Bridge ID：Provider 返回的 message/deposit ID。
- Transaction 引用：EVM hash 或 Solana signature。

### 9.7 状态机

```text
CREATED
  -> QUOTED
  -> VALIDATED
  -> SOURCE_SIGNING
  -> SOURCE_SUBMITTED
  -> SOURCE_CONFIRMED
  -> BRIDGE_IN_FLIGHT
  -> DESTINATION_SUBMITTED
  -> DESTINATION_CONFIRMED
  -> COMPLETED
```

### 9.8 产品策略边界

跨链费用、退款、补偿和业务失败处置由产品经理设计，不在本文件定义。Coordinator 只向产品
工作流上报源链/目标链交易结果、Bridge 状态和异常，不自行决定业务补偿。

## 10. Go 后端架构

### 10.1 推荐部署形态

初版采用 Go 模块化单体，运行多个进程模式：

```text
cmd/api
cmd/worker-evm
cmd/worker-solana
cmd/crosschain
cmd/indexer
cmd/signer
cmd/admin
```

模块边界：

```text
internal/intent
internal/quote
internal/policy
internal/execution
internal/evm
internal/solana
internal/crosschain
internal/signer
internal/indexer
internal/reconciler
internal/store
internal/transport
internal/observability
```

初期可以共享一个代码库和基础设施，但 Signer、Chain Worker 和 Admin 必须独立进程、权限和网络策略。

### 10.2 Go 依赖建议

- EVM：`go-ethereum`，ABI 绑定由 `abigen` 在构建期生成。
- Solana：`solana-go`，Anchor instruction encoder 由固定 IDL 生成并纳入版本控制。
- PostgreSQL：`pgx`、`sqlc`。
- 事件队列：NATS JetStream；低流量阶段可使用 PostgreSQL Outbox。
- Redis：钱包锁、nonce 锁和短期缓存。
- HTTP：标准库 `net/http`，需要路由时使用轻量 router。
- 内部 RPC：gRPC 或 HTTP JSON。
- 监控：OpenTelemetry、Prometheus。

不引入 Node.js 后端运行时。

### 10.3 执行并发

- 所有交易使用 `wallet_id + chain_id` 分布式锁。
- EVM nonce 由单 Worker 分配，避免并发 nonce gap。
- Solana 每个 WalletState 的 `execution_nonce` 串行更新。
- 重试不能重新生成新的业务 quote。
- 每个 transaction attempt 记录网络 fee、signature/hash、提交时间和 RPC。

### 10.4 幂等和可靠性

- API 接受 `Idempotency-Key`。
- `quote_id`、`intent_id` 和 `transaction_attempt_id` 全局唯一。
- DB 状态变更和事件发布使用 transactional outbox。
- Worker 至少一次消费，业务处理必须幂等。
- EVM 交易使用 replacement transaction 处理卡单。
- Solana 交易使用新 blockhash 重建签名，同时防止重复业务执行。
- 状态推进以链上确认结果为准，不能依据提交成功直接标记完成。

### 10.5 RPC 和高可用

- EVM 和 Solana 均配置多个独立 RPC Provider。
- RPC 按 read、simulate、broadcast 分类限流。
- 对 block height、slot、同步延迟和错误率设置健康检查。
- 交易广播后由独立确认器跟踪，不依赖原请求连接。
- 原始 RPC 请求和响应按隐私策略保存用于故障分析。

### 10.6 Go 供应链安全

- 固定 Go toolchain 和依赖版本。
- 提交 `go.sum`。
- CI 执行 `go test`、`go vet`、`govulncheck` 和静态分析。
- 生成 SBOM。
- 使用最小依赖集和静态二进制。
- 容器使用 non-root、只读根文件系统和最小基础镜像。
- Signer 与公网 API 不共享网络和凭据。

## 11. 数据模型

至少包含：

| 表 | 关键字段 |
| --- | --- |
| `users` | `user_id`, status |
| `wallets` | `user_id`, chain, address/PDA, version, status |
| `assets` | chain, asset id, token address/mint, token program, decimals |
| `intents` | intent id, user, service type, amount, status |
| `quotes` | quote id, route digest, min output, deadline |
| `execution_legs` | intent id, source/destination chain, status |
| `transaction_attempts` | hash/signature, nonce, network fee, RPC, status |
| `bridge_messages` | bridge id, source tx, destination tx, status |
| `whitelist_snapshots` | policy version, target, selector/discriminator |
| `incidents` | severity, affected intents, remediation |

关键约束：

- `quote_id` 全局唯一。
- 同一 intent 在同一链最多一个 active execution leg。
- 任何状态变更都必须有 correlation ID。
- 数据库不得保存明文私钥。

## 12. 执行记录与对账

### 12.1 Route Artifact

Quote 保存 `generated_at`、`expires_at`、`deadline` 和链上状态快照。执行前必须按
[6.10](#610-swap-calldata-时效性) 的规则重新模拟。

### 12.2 对账

Indexer 读取链上事件后生成：

- expected wallet balance。
- actual wallet balance。
- route success/failure。

不一致时自动创建 incident，并暂停相关钱包或 Provider。

## 13. 安全架构

### 13.1 权限

| 权限 | 使用环境 | 不应具备的能力 |
| --- | --- | --- |
| Operator | 在线执行 | 修改白名单、升级、提款 |
| Config Admin | 受控运维 | 日常交易签名 |
| Upgrade Admin | 离线/低频 | 日常交易签名 |

初版不使用多签和 timelock，但必须使用不同公私钥、不同存储介质和不同访问策略。

### 13.2 主要威胁

| 威胁 | 控制 |
| --- | --- |
| Backend 被入侵 | 链上白名单、Signer policy、交易限额、暂停 |
| Operator 私钥泄漏 | Operator 不能修改白名单或升级，链上额度限制 |
| Whitelist 被错误配置 | 独立 Config Admin、变更审计和模拟 |
| 恶意 Router/Program | target + selector/discriminator 白名单 |
| Quote 被重放 | wallet nonce、quote ID、deadline |
| RPC 返回错误状态 | 多 Provider、交易回执和链上事件交叉验证 |
| Solana Adapter 越权 | Working ATA 隔离、Account/PDA/Mint 校验 |
| 供应链攻击 | 固定版本、锁文件、`govulncheck`、SBOM |

### 13.3 白名单是核心安全边界

Whitelist 的正确性必须通过：

- 单元测试。
- Selector/Instruction discriminator 精确匹配测试。
- 恶意规则变更测试。
- WalletCore 和 Solana Wallet Program 的端到端测试。
- 独立安全审计。

## 14. 部署与运维

### 14.1 环境

- `local`：Anvil、Solana local validator、mock token/router。
- `dev`：开发链和 devnet。
- `staging`：生产配置镜像和测试资金。
- `production`：真实链、真实 RPC、真实 Provider。

每个环境使用独立 Operator、白名单、链配置和数据库。

### 14.2 部署顺序

EVM：

1. WhitelistRegistry。
2. AdapterRegistry。
3. WalletCore implementation。
4. WalletFactory。
5. Swap/Bridge Adapter。
6. 白名单规则。

Solana：

1. Whitelist Program。
2. Wallet Program。
3. Swap/Bridge Adapter Program。
4. ServiceConfig 和 Whitelist Config。
5. Adapter 规则。
6. 新钱包和 Working ATA。

Go：

1. PostgreSQL/Redis/NATS。
2. API、Worker、Signer、Indexer。
3. 链配置和资产配置。
4. 只读模式和对账验证。
5. 小流量执行。

### 14.3 发布与回滚

- EVM WalletCore 升级前做存储布局和 fork 测试。
- Solana Program 升级前做 verifiable build 和旧账户兼容测试。
- Go 服务使用版本化配置和数据库 migration。
- 新 Adapter/Provider 先进入 disabled 状态。
- 先执行模拟和小额 canary，再开放路由。
- 回滚通过停用白名单规则或回滚旧版本完成。

## 15. 可观测性

必须采集：

- Intent 创建、报价、模拟、提交、确认和完成耗时。
- EVM gas 与 Solana base/priority fee。
- Provider 成功率、延迟和滑点偏差。
- RPC 健康、block/slot lag 和限流。
- EVM nonce gap、Solana blockhash 过期。
- 白名单拒绝次数。
- 钱包余额差异和跨链卡单。
- Signer 请求、批准、拒绝和异常。
- 事故等级、影响范围和人工处理结果。

告警按用户影响分级，不能只监控服务存活。

## 16. 测试架构

### 16.1 EVM

- Foundry unit/fuzz/invariant。
- 真实链 fork 测试。
- Whitelist target/selector 绕过测试。
- nonce、deadline、calldata 时效和重放测试。
- Adapter 失败和余额回滚测试。
- UUPS 升级兼容测试。

### 16.2 Solana

- Anchor/Bankrun/LiteSVM unit test。
- account substitution、错误 PDA、Mint、authority 和 Program 测试。
- Working ATA 残留和主 ATA 隔离测试。
- Compute Unit、交易大小和 ALT 测试。
- Program 升级和迁移测试。

### 16.3 Go

- State machine 和幂等测试。
- EVM nonce/fee bump 测试。
- Solana blockhash 重建测试。
- RPC timeout、partial failure 和重试测试。
- PostgreSQL outbox 和 consumer replay 测试。
- Signer policy 和 KMS 故障测试。

### 16.4 E2E

- EVM 同链 Swap。
- Solana 同链 Swap。
- EVM -> EVM，包括 bridge-only 和 destination swap。
- EVM -> Solana。
- Solana -> EVM。
- Bridge Provider 超时和技术错误传播。
- Provider 不可用、RPC 切换和 backend restart。

## 17. 实施顺序

### Phase 1：EVM 白名单重构

- 新增 WhitelistRegistry。
- WalletCore 接入白名单。
- Adapter 移除本地 Router 白名单。
- 更新测试和部署脚本。

### Phase 2：Solana MVP

- Wallet Program、Whitelist Program。
- ServiceConfig、WalletState、AdapterConfig。
- USDT 输入/输出收费。
- Working ATA 和执行测试。

### Phase 3：Go Backend

- API、Quote、Policy。
- EVM Worker。
- Solana Worker。
- Signer Service。
- Indexer/Reconciler。

### Phase 4：Cross-chain

- Swap/Bridge Adapter。
- EVM → EVM Chain Pair Policy 和目标链执行器。
- Cross-chain Coordinator。
- 状态机、最终性和对账。

### Phase 5：生产化

- 多 RPC、监控、限流。
- 故障演练和容量测试。
- 第三方安全审计。
- 小额 canary 和逐步开放。

## 18. 待技术确认

- 首批 EVM 链、EVM 间 Chain Pair 和 Solana cluster。
- 首批 DEX/Aggregator 和 Bridge/Intent Provider。
- USDT Mint、Token Program 和 decimals。
- EVM WhitelistRegistry 是否可升级。
- Config Admin 和 Upgrade Admin 是否使用同一离线密钥。
- 单用户、单日和 Provider 级限额。
- 是否需要用户提现和普通资产转出功能。
- Operator 签名使用云 KMS、HSM 还是隔离软件签名服务。

## 19. 参考资料

- [Solana Program Derived Addresses](https://solana.com/docs/core/pda)
- [Solana Cross Program Invocation](https://solana.com/docs/core/cpi)
- [Solana Program Deployment and Upgrades](https://solana.com/docs/core/programs/program-deployment)
- [Solana Transactions](https://solana.com/docs/core/transactions)
- [Solana Fees](https://solana.com/docs/core/fees)
