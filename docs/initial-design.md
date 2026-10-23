# 多 EVM 与 Solana 代理执行初版设计报告

| 项目 | 内容 |
| --- | --- |
| 状态 | Draft |
| 版本 | 0.3 |
| 日期 | 2026-10-23 |
| 目标网络 | EVM 兼容链、Solana |
| 费用策略 | 由产品设计另行提供 |

## 1. 摘要

本方案面向 Gobull 产品。A 是用户，B 是 Gobull 产品运营方。用户使用 Gobull 前，系统必须
先为其创建 EVM 智能合约钱包或 Solana WalletState。用户资产存放于 Gobull 控制的钱包中，
用户没有原生 Gas，但完全信任 Gobull。用户请求 Gobull 代替其执行 swap 或跨链操作，
Gobull 使用自己的 ETH 或 SOL 提交交易。

由于以下三个条件同时成立：

1. 用户首次使用 Gobull 时会先创建 EVM Smart Wallet 或 Solana WalletState；
2. Gobull 控制该钱包的执行权限；
3. Gobull 可以自行提交外层 EVM 交易或签名 Solana 交易。

EVM 初版不需要 ERC-4337 的 EntryPoint、Bundler 或 Paymaster。Gobull 直接调用钱包合约的
受限执行入口，钱包再调用经过白名单批准的 Swap Adapter。

Solana 初版不复用 EVM 合约，而是部署一个共享的可升级 Wallet Program。每个用户对应一个
`WalletState` PDA，该 PDA 同时作为用户 Token Account 的 authority。Gobull 作为 fee payer 和
operator 签名外层交易，Program 通过 `invoke_signed` 代表 Wallet PDA 调用 Token Program、
Swap/Bridge Adapter Program。

ERC-4337 保留为 EVM 的后续兼容方向，用于接入第三方 Bundler、多签验证、Session Key、
标准钱包 SDK 或跨应用统一赞助，不作为第一版的必要依赖。Solana 侧使用自身的 PDA、CPI、
instructions sysvar 和程序升级模型，不尝试照搬账户抽象的 ABI。

## 2. 前提与范围

### 2.1 业务前提

- A 是 Gobull 用户；B 是 Gobull。
- 用户首次使用 Gobull 产品时，系统必须先为其创建并初始化链上钱包。
- 在 EVM 上，A 的资产钱包是智能合约钱包；在 Solana 上，A 的钱包由 WalletState PDA
  和 Token Account 组成。
- 两条链上的钱包控制权都属于 Gobull。
- 用户完全信任 Gobull，允许 Gobull 代为构造和执行交易。
- Gobull 在 EVM 使用 ETH、在 Solana 使用 SOL 支付外层网络费用和优先费。
- 每条链上的 swap 至少一侧涉及该链的 USDT，即 USDT 为输入资产或输出资产。
- EVM 钱包与 Solana Wallet Program 需要支持后续升级。
- 后续服务不限于 swap，还可能包括跨链、桥接或其他 DeFi 操作。

### 2.2 初版范围

- EVM 与 Solana 各自的同链 swap。
- EVM ↔ EVM、EVM ↔ Solana 跨链 swap。
- 用户首次使用 Gobull 时的链上钱包创建与初始化。
- Gobull Operator 代为提交 EVM 交易和签名 Solana 交易。
- 可升级的 EVM WalletCore 和 Solana Wallet Program。
- 可扩展的 EVM Adapter、Solana Adapter Program 和 Bridge Adapter 接口。
- 交易模拟、最小输出、deadline、重放保护和 calldata 时效性检查。

### 2.3 非目标

- 初版不实现面向不信任管理员的非托管钱包。
- 初版不实现 ERC-4337 Paymaster、Bundler 或 UserOperation 基础设施。
- 初版不实现完整的做市、流动性或跨链结算网络。
- 初版不承诺支持任意 Solana Token-2022 extension、transfer hook 或匿名 Router。
- 初版不为 EVM 与 Solana 构造完全相同的账户状态；两端只共享业务协议和报价模型。
- 费用和业务失败处理由产品经理另行设计，本文不展开收费、退款或补偿规则。

## 3. 核心设计决策

| 决策 | EVM | Solana |
| --- | --- | --- |
| 钱包开户 | WalletFactory 创建 Smart Wallet | 创建 WalletState PDA 与 Token Account |
| 交易发起 | Gobull EOA 调用 WalletCore | Gobull fee payer/operator 签名交易 |
| 用户身份 | 每用户一个 ERC-1967 钱包代理 | 每用户一个 `WalletState` PDA |
| 资金授权 | 合约精确 approve | Wallet PDA 作为 Token Account authority |
| 网络费用 | Gobull 支付 ETH | Gobull 支付 SOL 和 Compute Budget 优先费 |
| 可升级性 | UUPS + ERC-1967 + ERC-7201 | Loader-v3 Program 升级 + 状态版本迁移 |
| 业务扩展 | Adapter Registry | Adapter Program Registry |
| Calldata 时效 | deadline + 最新区块模拟 | blockhash + account/CU 模拟 |
| 跨链 | 统一 32-byte quote ID 和链上回执 | 统一 32-byte quote ID 和链上回执 |
| ERC-4337 | 后续可选兼容 | 不适用 |

## 4. EVM 实现设计

```text
用户请求
   |
   v
Gobull Backend
   |  1. 生成报价和调用数据
   |  2. 链上模拟
   v
Gobull Operator EOA
   |  3. 提交交易，支付 ETH Gas
   v
WalletCore (A / User 的可升级钱包)
   |  4. 校验权限、报价和资金
   |  5. 授权并调用 Adapter
   +--------> SwapAdapter --------> DEX / Aggregator
   |
   +--------> BridgeAdapter ------> Bridge / Intent Protocol
```

### 4.1 WalletCore

WalletCore 保存用户资产、执行权限、升级权限和基础会计状态。其职责包括：

- 验证调用者具有 `OPERATOR_ROLE`。
- 验证钱包未暂停、报价未过期且未执行。
- 验证 Adapter 已启用。
- 校验 calldata/route artifact 仍在有效期内。
- 仅对 Adapter 授权本次所需的输入资产。
- 调用 Adapter 并检查最小输出。
- 发出可审计的执行事件。

WalletCore 不应直接硬编码 DEX Router 或 Bridge 合约地址。

### 4.2 WalletFactory

WalletFactory 使用可预测地址部署钱包代理，并初始化：

- 钱包管理员；
- Operator；
- Upgrader 地址；
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
而不是升级所有用户钱包。Registry 的写权限属于独立 Config Admin。

Router/Selector 白名单不由 Adapter 自己维护，而由独立 `WhitelistRegistry` 管理。
WalletCore 必须在执行 Adapter 前校验 `serviceType + adapter + target + selector`。
具体架构见 [系统架构设计](system-architecture.md#73-whitelistregistry)。

### 4.5 产品策略边界

费用、收费时点、退款和业务失败处置由产品经理另行设计。本文件只定义钱包创建、链上执行、
白名单和 calldata 时效性等技术能力，不定义相关产品策略。

### 4.6 用户钱包创建

用户开始使用 Gobull 产品时，系统必须先完成钱包创建：

1. 查询 `user_id + chain_id` 的钱包映射。
2. EVM 不存在钱包时，由 WalletFactory 创建并初始化 ERC-1967 Proxy。
3. Solana 不存在钱包时，创建 WalletState PDA、Token Account 和 Working Account。
4. 校验合约 code、PDA、Owner、Token Program、authority 和版本。
5. 将钱包状态标记为 `ACTIVE` 后才允许创建 Swap/Bridge Intent。

钱包创建必须幂等。已存在的钱包只执行配置和版本校验，不重复部署。

## 5. Solana Program 实现设计

### 5.1 实现选择

Solana 初版采用 Rust + Anchor，形成一套独立部署、独立升级、独立测试的 Program：

- Anchor 用于账户约束、指令编码、IDL、客户端生成和集成测试。
- 所有业务状态存放在 Program 拥有的独立 Account 中，而不是 Program Account 本身。
- 每用户钱包由 PDA 表示，不使用 EVM 风格的每用户代理合约。
- Gobull 的 Operator 是外层交易 signer 和 fee payer，Wallet PDA 只在 CPI 中通过
  `invoke_signed` 签名。
- Token 转账优先使用 `TransferChecked`，并显式传入 Mint、Token Program 和 decimals。
- 初版以经典 SPL Token 的 USDT 为基准，同时把 Token Program 作为可配置账户，
  为 Token-2022 留出接口。

不建议把 EVM Solidity 合约直接移植为 Solana Program。两边的账户所有权、授权、
重放保护、升级和交易原子性模型不同，应共享业务协议而不是共享底层 ABI。

### 5.2 Program 组成

建议代码目录：

```text
solana/
  Anchor.toml
  Cargo.toml
  programs/
    operator_wallet/
      src/
        lib.rs
        state.rs
        instructions/
        cpi/
        error.rs
    whitelist/
      src/lib.rs
    swap_adapter/
      src/lib.rs
  tests/
```

`operator_wallet` 保存配置、WalletState 和调度逻辑。`swap_adapter` 负责具体 DEX
或 Aggregator CPI，`whitelist` 负责 Adapter Program、Target Program 和 instruction
discriminator 规则。跨链桥在后续单独实现为 Adapter Program，而不是把桥逻辑堆进 Wallet Program。

### 5.3 账户模型

| Account | Owner | Seeds | 用途 |
| --- | --- | --- | --- |
| `ServiceConfig` PDA | Wallet Program | `[b"config"]` | 全局 Operator、USDT Mint、Whitelist 引用、暂停和版本 |
| `WalletState` PDA | Wallet Program | `[b"wallet", user_id]` | 用户钱包身份、nonce、暂停、版本和内部记录 |
| 用户主 Token Account | Token Program | 标准 ATA | Wallet PDA 作为 authority，保存用户资产 |
| Working Token Account | Token Program | Wallet PDA + Mint | 单次执行临时接收精确输入，隔离 Route 的权限 |
| `AdapterConfig` PDA | Whitelist Program | `[b"adapter", adapter_program_id]` | Adapter Program、Target Program 和 Instruction 白名单 |
| Adapter Program | BPF Loader | 固定 Program ID | 执行 DEX、Aggregator 或 Bridge CPI |

`user_id` 使用 32 字节的业务用户 ID，可由后端生成并在 EVM/Solana 之间共享。
`WalletState` PDA 同时作为用户主 Token Account 的 authority。Program 使用
`invoke_signed` 和 `[b"wallet", user_id, bump]` 代表该 PDA 签名。

Solana PDA 没有私钥，也不能直接作为顶层交易的 fee payer。Gobull 的 Operator 必须签名并支付
外层交易费用，Program 只能在 CPI 中让 Wallet PDA 成为 signer。

### 5.4 ServiceConfig

`ServiceConfig` 至少保存：

```text
admin: Pubkey
operator: Pubkey
usdt_mint: Pubkey
usdt_token_program: Pubkey
whitelist_program: Pubkey
paused: bool
config_version: u16
bump: u8
```

约束：

- 只有 `admin` 可以修改 Operator、暂停状态和配置版本。
- 只有 `operator` 可以提交用户执行请求。
- `usdt_token_program` 必须与 `usdt_mint.owner` 一致。
- 配置变更必须发出 Anchor event。

### 5.5 WalletState

`WalletState` 至少保存：

```text
user_id: [u8; 32]
admin: Pubkey
operator: Pubkey
execution_nonce: u64
paused: bool
account_version: u16
bump: u8
```

`admin` 用于暂停、权限恢复和后续迁移；`operator` 默认继承全局 Operator，也可以升级为
每用户独立 Operator。初版为简化执行可只使用全局 Operator，但账户结构中应保留字段，
避免未来重新分配账户。

建议在部署时为 WalletState 预留 padding bytes。Solana Account 的 realloc 受交易和 CPI
限制，预留空间可以降低小版本升级时的迁移成本。

### 5.6 Instruction 集合

初版 Program 至少包含：

```text
initialize_config(operator, usdt_mint, usdt_token_program, whitelist_program)
set_operator(new_operator)
set_paused(paused)
create_wallet(user_id, wallet_admin, optional_operator)
set_wallet_paused(user_id, paused)
register_adapter(adapter_program, service_type, instruction_tag, version)
set_adapter_enabled(adapter_program, enabled)
execute_service(request, adapter_instruction_data)
```

执行请求建议定义为：

```rust
pub struct ExecutionRequest {
    pub quote_id: [u8; 32],
    pub service_type: ServiceType,
    pub sell_mint: Pubkey,
    pub buy_mint: Pubkey,
    pub sell_amount: u64,
    pub min_buy_amount: u64,
    pub deadline: i64,
    pub nonce: u64,
}
```

执行 instruction 的显式账户应包括：

- Config、WalletState、AdapterConfig。
- 用户卖出 Token Account、用户买入 Token Account、Working Token Account。
- USDT Mint 和对应 Token Program。
- Adapter Program、DEX/Router Program 以及 route 所需的 remaining accounts。
- Clock/Sysvar 和必要的 Token-2022 transfer-hook accounts。

Program 必须逐项检查 Account 的 Program Owner、PDA seeds、Mint、Token Program、
authority、token account 唯一性和账户是否 writable/signer。Solana 不会替 Program
自动完成 EVM 合约中常见的类型和权限检查。

### 5.7 同链 Swap 流程

```text
Gobull Backend
  -> 生成 route accounts、instruction data、deadline 和报价
  -> 本地 Bankrun/LiteSVM 或 RPC simulateTransaction

Gobull Operator (fee payer + signer)
  -> operator_wallet::execute_service
       -> 校验 Operator、nonce、deadline、Adapter 和配置
       -> 确认 sell_mint 或 buy_mint 等于配置 USDT
       -> 调用 Whitelist Program 校验 Adapter/Target/Discriminator
       -> 从用户主 sell ATA 把精确 sell_amount 转入 Working ATA
       -> invoke_signed Adapter Program
       -> Adapter 通过 Wallet PDA signer 调用 DEX/Router
       -> 校验用户 buy ATA 余额增量 >= min_buy_amount
       -> 校验 Working ATA 没有残留输入
       -> 增加 execution_nonce
       -> emit ExecutionSettled
```

执行失败时整笔 Solana 交易及其所有 CPI 回滚，Gobull 承担失败的 base fee 和 priority fee。

### 5.8 Working Token Account 与 Adapter 隔离

Solana 没有 ERC-20 那种原生 allowance。Wallet PDA 作为 authority 时，如果直接把它传给
任意 Adapter，恶意或错误 Adapter 理论上可以操作它在当前 instruction 中获得的全部账户。

初版采用 Working Token Account 隔离：

1. Wallet 先把精确的 `sell_amount` 从用户主 sell ATA 转入 Working ATA。
2. 只把 Working ATA、目标 buy ATA 和 route accounts 传给 Adapter CPI。
3. 不把用户的其它主 Token Account 传给 Adapter。
4. Adapter 完成后，Working ATA 的卖出 Token 余额必须回到执行前水平。
5. Wallet 检查用户 buy ATA 的实际余额增量。

Working ATA 的 authority 仍是 Wallet PDA，但其余额只包含本次允许消耗的输入。

每个用户可在钱包创建时预先创建 USDT 和常用卖出 Token 的 Working ATA。创建 ATA 消耗的
rent 由 Gobull 垫付；Working ATA 可重复使用，不应每次交易重新创建。

Adapter Program 必须在 `AdapterConfig` 中启用。配置至少绑定 Program ID、ServiceType、
允许的 instruction discriminator/tag 和版本。Adapter Program 升级会改变所有用户共享的
代码，因此必须使用与 Wallet Program 同等级的升级治理和 build verification。

### 5.9 Compute Budget 与网络费用

所有 Token 转账使用 `TransferChecked`，并校验 Mint decimals。

Solana 费用模型：

```text
base fee = 5,000 lamports × 签名数量
priority fee = ceil(compute_unit_price × compute_unit_limit / 1,000,000) lamports
总 SOL 成本 = base fee + priority fee
```

优先费按请求的 Compute Unit limit 计算，而不是按实际消耗计算。Backend 必须：

1. 使用 `simulateTransaction` 获取 CU 消耗。
2. 设置实际所需 CU limit，并增加约 10% 缓冲。
3. 在 quote 中记录 deadline、生成时 slot 和 route digest。

初版建议 Gobull 的 fee payer 与 operator 使用同一个签名者，避免额外签名和账户复杂度。
面向用户的产品费用策略不在本文定义。

### 5.10 交易大小与 Route 限制

当前 legacy/v0 Solana 标准交易大小为 1,232 bytes，通常最多加载 64 个账户。DEX 聚合器
可能返回大量 route accounts，因此设计必须预留以下能力：

- 使用 versioned transaction 和 Address Lookup Table 压缩重复地址。
- 由 Backend 根据 route 复杂度拆分不依赖原子性的准备步骤。
- Swap 的输入转移、Route 和最小输出检查必须保持原子，不得拆成可被单独利用的
  多笔交易。
- 对无法放入单笔交易且无法安全拆分的 Route 直接拒绝。
- 不把 v1 transaction 或更高账户上限作为初版假设；使用时必须检查目标 cluster 的 feature
  activation 状态。

Adapter 设计和测试必须同时覆盖 account 数量、instruction data 大小和 Compute Unit 上限。

### 5.11 Program 可升级设计

Solana Program 使用 Loader-v3 的 upgrade authority 管理升级。升级时：

- Program ID 保持不变。
- 新 bytecode 先写入临时 Buffer，再更新 ProgramData Account。
- 新版本在下一 slot 生效。
- 撤销 upgrade authority 会使 Program 永久不可升级。

初版 Upgrade authority 使用独立离线 Upgrade Admin 密钥，不使用多签或 timelock。
Operator 热钥绝不能成为 upgrade authority，Config Admin 与 Upgrade Admin 也应使用不同密钥。

升级要求：

- Anchor Account discriminator、字段顺序和账户版本显式管理。
- 新代码必须兼容旧 WalletState/ServiceConfig，或提供幂等 migration instruction。
- 部署前预留 ProgramData 空间，避免升级时频繁扩容和补充 rent。
- 每次升级执行 verifiable build、bytecode hash 公布、Upgrade authority 变更审计。
- 升级前全局暂停新的 execution；已有资产和 Token Account 不迁移。
- 若需要不兼容的数据布局，优先部署新 Program 和迁移入口，而不是直接覆盖旧布局。

### 5.12 Solana 测试范围

Solana 实现至少需要：

- Anchor Bankrun/LiteSVM 上的 Config、Wallet、ATA 和 Adapter 端到端测试。
- 错误 Mint、错误 Token Program、错误 PDA、错误 authority 和伪造 Adapter Program 测试。
- USDC -> USDT 与 USDT -> USDC 两条同链 swap 路径。
- Route 失败、余额不足、Working ATA 残留和最小输出不足的原子回滚测试。
- nonce/quote 重放、deadline、calldata 时效、暂停和 Operator 权限测试。
- versioned transaction、Address Lookup Table 和 Compute Unit 预算测试。
- Program 升级后旧账户可读性与 migration 测试。
- Backend `simulateTransaction` 结果与链上执行结果的一致性测试。

## 6. 通用权限模型

建议至少拆分以下角色：

| 角色 | EVM 权限 | Solana 对应权限 | 建议持有方式 |
| --- | --- | --- | --- |
| Operator | 提交 UserRequest | `ServiceConfig.operator` 签名执行 | Gobull 热钱包、HSM 或 API Signer |
| Upgrader | 升级 WalletCore | Loader-v3 upgrade authority | EVM/Solana 独立离线密钥 |
| Pauser | 暂停执行 | `ServiceConfig.paused` 管理权限 | 独立安全账户 |
| Whitelist/Config Admin | 修改 Adapter、Target、Selector 和 Program 规则 | 注册、启停 Adapter/Target 规则 | 独立 Config Admin 密钥 |

“用户完全信任 Gobull”是业务前提，但不能因此让日常热钥同时拥有升级权限。即使 Gobull 不会主动作恶，
热钥泄漏或后端漏洞仍可能导致全部钱包被转移。

Operator 不应直接获得无限制的任意 EVM `call` 或 Solana CPI 能力，而应通过已注册的
Service Adapter/Adapter Program 执行业务。Solana 侧还需限制 Adapter Program ID、
instruction tag、传入 Token Account 和 Route Program 集合。

## 7. EVM 执行数据结构

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
    uint64 deadline;
    uint256 nonce;
    address target;
    bytes4 selector;
    bytes callData;
}
```

字段约束：

- `quoteId` 全局唯一，并参与链上重放检查。
- `adapter` 必须处于启用状态。
- `sellToken` 或 `buyToken` 必须是当前链的 USDT。
- 同链 swap 必须校验 `buyToken` 的实际余额增量不低于 `minBuyAmount`。
- `deadline` 防止旧报价被延迟执行。
- `nonce` 防止同一钱包的请求被重复提交。
- `target + selector` 必须通过 WhitelistRegistry。
- `callData` 必须与 `target`、`selector`、Token、金额和收款地址绑定。

后端在签名或发送交易前应先模拟完整执行，包括：

- 授权和余额检查；
- Router 返回值和实际输出检查；
- 最小输出；
- calldata deadline 和生成时区块；
- Gas 估算及安全缓冲。

### 7.1 Calldata 与 Route Artifact 时效性

Swap Provider 返回的 calldata、Solana instruction data 和账户列表都具有时效性。价格、流动性、
Pool/Route Account、白名单版本或链上状态可能随时变化，过期 artifact 不得签名或广播。

每次报价保存：

- `generated_at`、`expires_at` 和链上 deadline。
- 生成时 EVM block height 或 Solana slot。
- target、selector/instruction discriminator 和 route digest。
- 输入金额、最小输出和完整 calldata/instruction data。
- Adapter 和 Whitelist 版本。
- Solana account metas 和 Compute Unit 预算。

签名前必须：

1. 重新读取 nonce、blockhash、EVM block height 或 Solana slot。
2. 重新执行 `eth_call`、`simulateTransaction` 或本地 Solana 模拟。
3. 校验白名单 target/selector/discriminator 未变化。
4. 校验 deadline、最小输出、Token Account 和 route accounts 仍然有效。
5. 任一条件变化时丢弃旧 artifact 并重新报价。

技术重试不得复用旧 calldata 或旧 Solana blockhash。WalletCore 和 Solana Wallet Program
仍需在链上校验 deadline，不能只依赖 Backend 的时间检查。

## 8. EVM 同链 Swap 流程

1. 用户向 Gobull 提交 swap 意图。
2. Gobull Backend 获取报价，生成 `ExecutionRequest` 和执行 artifact。
3. Backend 在目标区块状态下执行 `eth_call` 或节点模拟。
4. Gobull Operator 调用 WalletCore。
5. WalletCore 校验 Operator、Adapter、deadline、nonce 和 calldata 时效。
6. WalletCore 调用 WhitelistRegistry 校验 Adapter、target 和 selector。
7. WalletCore 仅授权 Adapter 所需的 `sellAmount`。
8. Adapter 调用白名单 target。
9. WalletCore 检查实际输出。
10. WalletCore 清零 Adapter allowance，并发送执行事件。

以上步骤必须在同一笔 EVM 交易内原子完成。任何一步失败，整笔交易回滚，Gobull 承担网络费用。

## 9. 产品费用与失败策略边界

费用、收费时点、退款和业务失败处置由产品经理另行设计。本文件不定义相关规则、公式、
用户扣费流程和补偿流程。

链上系统只需预留可扩展的执行结果和结算接口。产品策略确定后，再通过独立设计文档定义接入口。

## 10. 多链跨链设计

### 10.1 总体拓扑

不同 EVM 链之间以及 EVM 与 Solana 之间不共享执行环境，无法通过单笔交易原子完成
跨链 swap。建议增加链下 Cross-chain Coordinator 和两端 Bridge Adapter：

```text
用户跨链请求
      |
      v
Cross-chain Coordinator
  - 生成统一 quote_id
  - 选择源链、目标链和桥
  - 跟踪两端交易
      |
      +---- Source Wallet/BridgeAdapter -----+
      |           EVM 或 Solana              |
      +---- Destination Wallet/Adapter ------+----> Bridge/Intent
                                             |
                                             v
                                       目标链执行器
```

Coordinator 不托管用户资产，只维护状态、报价和幂等重试。源链与目标链交易分别由各自
Operator 签名和支付原生 Gas。

支持的路由类型：

- 同链 EVM Swap。
- EVM → EVM。
- EVM → Solana。
- Solana → EVM。

### 10.2 EVM → EVM 执行

EVM → EVM 初版采用两段式编排：

```text
Source WalletCore
  -> BridgeAdapter
  -> Bridge
  -> Destination WalletCore / Bridge Receiver
  -> Destination SwapAdapter
```

1. 确认目标 EVM 链已存在用户 WalletCore 和目标 Token Account。
2. Source Operator 执行 Source WalletCore 和 BridgeAdapter。
3. Coordinator 等待源链 finality 和 Bridge 的目标链状态。
4. 目标资产到账后，Destination Operator 执行目标链 Swap。
5. 分别记录两条链的交易、Bridge ID 和到账金额。

初版不给目标 WalletCore 开放通用 Bridge Executor 权限。需要自动目标链执行时，可增加受限
`BridgeReceiver`，验证 source chain/domain、sender、nonce、message ID 和 payload hash，
并仅允许执行预先绑定的一次性 settlement intent。

同一个用户在不同 EVM 链上的钱包地址可能相同，但业务上必须使用
`user_id + chain_id -> wallet` 映射。原生 USDT、桥接 USDT 和 wrapped USDT 必须按链上资产
分别管理，不能仅凭符号相同就视为同一资产。

### 10.3 统一业务标识

所有跨链路由统一使用 32-byte `quote_id`，并至少记录：

- EVM chain ID 或 Solana cluster/genesis hash。
- EVM wallet address 或 Solana user_id/WalletState PDA。
- 源链与目标链 Asset ID。
- 源链 source transaction signature/hash。
- Bridge/message ID。
- 目标链 transaction signature/hash。
- 报价、deadline 和 route digest。

业务用户 ID 应与链上地址分离，避免假设同一个 EVM 地址或 Solana PDA 能在所有链上复用。

### 10.4 状态机

跨链请求应使用显式状态机：

```text
CREATED
  -> SOURCE_SUBMITTED
  -> SOURCE_CONFIRMED
  -> BRIDGE_IN_FLIGHT
  -> DESTINATION_SUBMITTED
  -> DESTINATION_CONFIRMED
  -> COMPLETED

技术异常会中止当前链路并把链上结果上报产品工作流；业务失败状态由产品经理定义。
```

链上 Program 只负责记录本链的确定性结果；完整状态机由 Coordinator 汇总。不得仅凭 RPC
签名返回就标记跨链完成，必须确认源链最终性、Bridge 状态和目标链执行结果。

### 10.5 Bridge Adapter

EVM `BridgeAdapter` 和 Solana `BridgeAdapter Program` 应统一处理：

- 源链和目标链标识；
- 目标地址和目标 Token Account/PDA；
- USDT Mint 及其 decimals；
- 最小跨链数量；
- 源链实际扣款；
- bridge/message ID；
- 目标链执行 payload；
- 重复领取保护。

不同桥的最终性和状态语义不同，Adapter 不应假装所有桥具有相同的同步返回结果。Solana
Adapter 的 route accounts 还必须满足交易大小和 CPI account 数量限制。

### 10.6 产品策略边界

跨链费用、退款、补偿和业务失败处理由产品经理另行设计。本文只定义 source/destination
交易、Bridge ID、最终性、技术异常上报和对账数据，不定义用户收费与补偿规则。

## 11. 链上升级设计

### 11.1 EVM 代理模式

初版推荐 UUPS：

- 钱包地址和用户资产地址保持不变；
- 每次钱包可以单独选择是否升级；
- 使用 ERC-1967 实现槽；
- 使用 ERC-7201 命名空间存储业务状态；
- `_authorizeUpgrade` 只允许 `UPGRADER_ROLE` 调用。

如果钱包数量很大且业务逻辑始终统一，可在实施前评估 Beacon Proxy。Beacon 的优点是升级一次即可
影响所有钱包，缺点是单个钱包难以独立升级，升级故障的影响范围更大。

### 11.2 升级安全要求

- 实现合约的初始化函数必须防止被重复初始化。
- Upgrade Admin 与 Operator 热钥隔离。
- Solana Upgrade authority 与 EVM Upgrader 均不得由 Operator 热钥持有。
- 初版不使用 timelock；升级前由 Upgrade Admin 审批并提前发布实现地址和代码哈希。
- 每次升级必须有存储布局检查、单元测试和链上 fork 测试。
- Solana 升级必须使用可验证构建，并公布 ProgramData/bytecode hash。
- 新实现必须能读取旧版本的所有关键状态。
- 钱包升级不能改变用户地址，也不能要求用户迁移资产。
- Adapter 或 Router 变更后，应清理旧授权。
- 升级期间可以暂停新请求，但不应影响现有资金的查看和紧急提取。

Solana 的详细升级约束见 [5.11](#511-program-可升级设计)。Solana Program 升级会影响全部
用户 WalletState，因此应先全局暂停新请求，执行兼容性检查和 migration，再恢复执行。

### 11.3 两端版本与迁移

WalletCore 至少维护：

- `implementationVersion`；
- 配置版本；
- Adapter Registry 版本。

Solana `ServiceConfig` 和 `WalletState` 至少维护 `config_version`、`account_version` 和
预留 padding。需要迁移时采用显式、幂等的 migration instruction。两端迁移都只能由治理
权限触发，并记录迁移前后版本。

## 12. 安全与风控

### 12.1 执行安全

- 使用 `ReentrancyGuard` 保护执行入口。
- 使用 SafeERC20 兼容不标准返回值的 token。
- 对非标准转账 Token 使用实际余额差而不是假定转账数量。
- 校验 Adapter 的实际拉取数量和钱包余额变化。
- Approve 精确数量，并在执行后清零。
- 禁止通过 delegatecall 调用未审计实现。
- 对 WalletFactory 部署地址实施 CREATE2 地址验证。
- 对 Owner/Operator/Upgrader 变更发出事件。
- 对暂停状态和紧急提取设置独立权限。
- Solana 显式校验 PDA seeds、Account owner、Mint、Token Program、authority 和 signer。
- Solana Adapter CPI 只暴露 Working Token Account，不向 Route 传入其它用户主 Token Account。
- Solana 使用 `TransferChecked`，并校验 CLOCK、deadline、nonce 和 Working ATA 残留。

### 12.2 执行限额

- 报价包含 deadline、最小输出和 route digest。
- 钱包余额不足或最小输出不满足时整笔回滚。
- Backend 设置 Gas/Compute Unit 上限和安全缓冲。
- Solana quote 记录 base fee、priority fee、ATA rent 和 Compute Unit 预算。

### 12.3 运营安全

- Backend 在发送前执行模拟，并检查 Router/Adapter 的代码哈希。
- 对单用户、单日和服务类型设置交易额和频率上限。
- Operator 不得修改 Adapter/Target 白名单。
- Config Admin、Upgrade Admin 和 Operator 使用不同密钥与访问策略。
- 监控技术执行异常、授权残留和升级事件。
- 对用户展示报价、最小到账和 deadline。
- 对 EVM 与 Solana 的 quote_id、用户 ID 和 source/destination transaction 建立统一对账索引。
- Solana Route 发布前执行 account list、CU、transaction size 和 Address Lookup Table 检查。

## 13. EVM ERC-4337 的后续接入

当出现以下需求时，再评估接入 ERC-4337：

- 用户需要自行签名 UserOperation；
- 需要第三方 Bundler 提交交易；
- 需要标准 Sponsorship Paymaster；
- 需要 Session Key、社交恢复或多验证器；
- 需要兼容现有以 UserOperation 为中心的钱包和 SDK。

接入时可以让 WalletCore 同时实现 `IAccount.validateUserOp`，并保持现有 Operator 执行入口。
ERC-4337 只改变交易提交和授权入口，不应改变底层 Swap/Bridge Adapter。

当前场景中，4337 会额外引入 EntryPoint、Bundler、Paymaster 签名和 UserOperation 模拟，
却没有减少 Gobull 的 ETH Gas 成本，因此不作为 MVP。

## 14. 多链分阶段实施

### Phase 1：EVM 同链 MVP

- WalletProxy、WalletFactory、WalletCore。
- Operator 执行与暂停。
- Adapter Registry。
- WhitelistRegistry，负责 Adapter、Target 和 Selector。
- 一个 USDC/USDT SwapAdapter。
- 最小输出、deadline、nonce 和 calldata 时效检查。
- 基础事件与模拟脚本。

当前 Solidity MVP 已完成并在 Anvil 上验证，详见 `docs/implementation.md`。

### Phase 2：Solana 同链 MVP

- Anchor `operator_wallet` Program 和 `swap_adapter` Program。
- ServiceConfig、WalletState 和 AdapterConfig PDA。
- Wallet PDA 的主 Token Account 与 Working Token Account。
- Operator 权限、暂停、nonce、deadline 和最小输出。
- Compute Unit 模拟、versioned transaction 和 Address Lookup Table 验证。
- Bankrun/LiteSVM 端到端测试和升级兼容测试。

### Phase 3：运营能力

- 多协议 EVM SwapAdapter 与 Solana Adapter Program。
- 报价服务、报价签名或请求摘要。
- 多链统一对账、监控和技术异常告警。
- EVM 批量部署、Solana Program 升级和账户版本管理。

### Phase 4：多 EVM 与 Solana 跨链

- BridgeAdapter 接口和首个桥实现。
- BridgeAdapter Program 和 Solana route 限制。
- EVM → EVM Chain Pair Policy、目标钱包和目标链执行器。
- Coordinator 跨链状态机和统一 quote_id。

### Phase 5：可选 4337

- `IAccount` 兼容层。
- Sponsorship Paymaster。
- Session Key 和更细粒度授权。
- 第三方 Bundler 接入。

## 15. 验收标准

- `USDC -> USDT` 成功后，用户收到不低于最小输出的余额。
- `USDT -> USDC` 时，输入 USDT 被正确扣减，不能导致余额不足。
- 非 Operator 无法执行钱包业务交易。
- 非 Upgrader 无法升级钱包。
- 过期报价、重复报价和过期 calldata 均被拒绝。
- Adapter 失败或滑点不足时整笔回滚。
- 钱包升级后余额、角色、nonce 和历史状态保持不变。
- 新增 Adapter 不需要逐个升级所有用户钱包。
- 所有执行和权限变更都有可对账事件。
- Solana 错误 Mint、Token Program、PDA、authority 和 Adapter Program 均被拒绝。
- Solana Working ATA 在成功执行后没有预期外残留，Route 无法接触其它主 Token Account。
- Solana 交易满足账户数量、1,232-byte 大小和 Compute Unit 限制，或明确拒绝该 Route。
- Solana Program 升级后旧 ServiceConfig 和 WalletState 可正常读取或完成幂等迁移。
- 跨链流程可分别追踪各源/目标链的交易引用、bridge message ID 和目标链执行结果。

## 16. 待确认事项

- 首版 EVM 目标链及 USDT 合约版本。
- Solana 目标 cluster 和 USDT Mint/Token Program。
- Solana 初版是否采用 Anchor，还是改用 Anchor 之外的 sBPF 框架。
- WalletCore 最终采用 UUPS 还是统一 Beacon 升级。
- 是否需要在初版就支持多个 Operator。
- 用户只持有 USDT 输出、USDT 输入，还是两种都需要首批支持。
- EVM Operator、Config Admin 和 Upgrade Admin 分别使用哪些地址。
- Solana Operator、Whitelist Admin 和 Program upgrade authority 使用哪些地址。
- Solana Working ATA 预创建哪些 Mint，rent 由 Gobull 垫付还是向用户收取。
- 首批 EVM Swap、Solana DEX、EVM ↔ EVM Chain Pair 和 Bridge/Intent 协议。

## 17. 参考资料

- [ERC-4337: Account Abstraction Using Alt Mempool](https://eips.ethereum.org/EIPS/eip-4337)
- [ERC-4337 Paymaster Types](https://docs.erc4337.io/paymasters/types.html)
- [EIP-7702: Set EOA account code](https://eips.ethereum.org/EIPS/eip-7702)
- [account-abstraction v0.9.0](https://github.com/eth-infinitism/account-abstraction/releases/tag/v0.9.0)
- [ERC-7201: Namespaced Storage Layout](https://eips.ethereum.org/EIPS/eip-7201)
- [Solana Programs](https://solana.com/docs/core/programs)
- [Solana Program Derived Addresses](https://solana.com/docs/core/pda)
- [Solana Cross Program Invocation](https://solana.com/docs/core/cpi)
- [Solana Program Deployment and Upgrades](https://solana.com/docs/core/programs/program-deployment)
- [Solana Transactions](https://solana.com/docs/core/transactions)
- [Solana Fees](https://solana.com/docs/core/fees)
