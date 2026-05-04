# Oracle 实例创建器 - 配置指南

## 概述

Oracle 实例创建器是一个模块化的自动化工具，通过 GitHub Actions 定时调度，持续尝试在 Oracle Cloud 免费层创建计算实例。

## 架构

### 文件结构
```
├── .github/workflows/
│   └── infrastructure-deployment.yml   # GitHub Actions 工作流
├── config/
│   └── templates/                      # 配置模板
├── scripts/
│   ├── launch-parallel.sh              # 并行启动编排器
│   ├── launch-instance.sh              # 单实例创建核心逻辑
│   ├── utils.sh                        # OCI CLI 封装 + 工具函数
│   ├── constants.sh                    # 集中化常量定义
│   ├── circuit-breaker.sh              # 熔断器模式
│   ├── state-manager.sh                # 实例状态缓存管理
│   ├── validate-config.sh              # 配置验证
│   ├── setup-oci.sh                    # OCI CLI 配置
│   ├── setup-ssh.sh                    # SSH 密钥配置
│   ├── notify.sh                       # Telegram 通知
│   ├── preflight-check.sh              # 生产环境预检
│   ├── adaptive-scheduler.sh           # 自适应调度器
│   ├── schedule-optimizer.sh           # 调度优化器
│   ├── metrics.sh                      # 指标收集
│   └── test-runner.sh                  # 测试运行器
└── docs/
    └── configuration.md                # 本文件
```

### 工作流作业

GitHub Actions 工作流包含两个作业：

1. **部署 OCI 基础设施（并行编排）**: 验证配置、设置环境、并行创建 A1.Flex 和 E2.1.Micro 实例
2. **失败时通知**: 主作业失败时发送 Telegram 通知

## 配置

### 必需的 GitHub Secrets

| Secret 名称 | 说明 | 示例 |
|-------------|------|------|
| `OCI_USER_OCID` | OCI 用户 OCID | `ocid1.user.oc1..aaaa...` |
| `OCI_KEY_FINGERPRINT` | API 密钥指纹 | `12:34:56:78:90:ab:cd:ef...` |
| `OCI_TENANCY_OCID` | OCI 租户 OCID | `ocid1.tenancy.oc1..aaaa...` |
| `OCI_REGION` | OCI 区域标识符 | `us-sanjose-1` |
| `OCI_PRIVATE_KEY` | 私有 API 密钥内容 | `-----BEGIN RSA PRIVATE KEY-----...` |
| `OCI_SUBNET_ID` | 目标子网 OCID | `ocid1.subnet.oc1..aaaa...` |
| `INSTANCE_SSH_PUBLIC_KEY` | SSH 公钥 | `ssh-rsa AAAA...` |
| `TELEGRAM_TOKEN` | Telegram 机器人令牌 | `123456:ABC-DEF...` |
| `TELEGRAM_USER_ID` | Telegram 用户 ID | `123456789` |

### 可选的 GitHub Secrets

| Secret 名称 | 说明 | 默认值 |
|-------------|------|--------|
| `OCI_COMPARTMENT_ID` | 目标区间 OCID | 使用租户 OCID |
| `OCI_IMAGE_ID` | 指定镜像 OCID | 自动检测 |
| `OCI_A1_BOOT_VOLUME_ID` | A1 引导卷 OCID | 新建引导卷 |
| `SKIP_SHAPES` | 跳过的形状（逗号分隔） | `E2` |
| `OCI_AD` | 可用性域 | 自动检测 |

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `OCI_SHAPE` | 实例形状 | `VM.Standard.A1.Flex` |
| `OCI_OCPUS` | OCPU 数量（弹性形状） | `4` |
| `OCI_MEMORY_IN_GBS` | 内存 GB（弹性形状） | `24` |
| `ASSIGN_PUBLIC_IP` | 分配公网 IP | `true` |
| `OPERATING_SYSTEM` | 操作系统 | `Oracle Linux` |
| `OS_VERSION` | 操作系统版本 | `10` |
| `BOOT_VOLUME_SIZE` | 引导卷大小 GB | `50` |
| `OCI_REGION_TIMEZONE` | 区域时区 | `America/Los_Angeles` |

## 退出码

| 退出码 | 含义 | 工作流处理 |
|--------|------|-----------|
| 0 | 成功 | ✅ 成功 |
| 2 | 容量不足 | ✅ 成功（预期行为） |
| 5 | 用户限额已达 | ✅ 成功（预期行为） |
| 6 | 速率限制 | ✅ 成功（预期行为） |
| 124 | 超时 | ❌ 失败 |
| 其他 | 真实错误 | ❌ 失败 |

## 错误处理

### 错误分类

1. **CAPACITY**: 无可用容量（不视为失败）
2. **USER_LIMIT_REACHED**: 用户限额已达（不视为失败）
3. **RATE_LIMIT**: API 速率限制（不视为失败）
4. **AUTH**: 认证/授权错误
5. **CONFIG**: 配置错误（无效 OCID、缺少资源）
6. **NETWORK**: 网络连接问题
7. **DUPLICATE**: 实例已存在
8. **INTERNAL_ERROR**: Oracle 内部错误

### 重试逻辑

- 网络错误: 指数退避重试
- 容量错误: 下次调度自动重试
- 配置/认证错误: 立即失败并发送通知
- 速率限制: 下次调度自动重试

## 通知

### Telegram 集成

通知系统仅在以下情况发送消息：

- ✅ 实例创建成功
- ❌ 认证/授权失败
- ❌ 配置错误
- ❌ 真实错误（非容量/限额/速率限制）

**不发送通知的情况**（预期行为）：
- 容量不足
- 用户限额已达
- API 速率限制

## 调度

工作流包含 4 层调度：

1. **激进层**: 每 15 分钟一次（离峰时段）
2. **保守层**: 每小时一次（高峰时段）
3. **周末层**: 每 20 分钟一次（周末离峰）
4. **手动触发**: 随时可手动运行

调度模式根据区域自动优化（美西、美东、新加坡、欧洲等）。

## 故障排除

### 常见问题

1. **OCID 格式无效**
   - 错误: `OCI_USER_OCID 格式无效`
   - 解决: 验证 OCID 格式匹配 `ocid1.type.region.realm.id`

2. **SSH 密钥格式**
   - 错误: SSH 公钥验证警告
   - 解决: 确保密钥以 `ssh-rsa`、`ssh-ed25519` 等开头

3. **容量错误**
   - 错误: `Out of host capacity`
   - 解决: 这是预期行为 - 工作流将自动重试

4. **Telegram 通知不工作**
   - 错误: Telegram API 错误
   - 解决: 验证机器人令牌和用户 ID 是否正确

### 调试模式

设置 `DEBUG=true` 环境变量启用调试日志输出。

## 安全注意事项

1. **私钥**: 绝不将私钥提交到仓库
2. **Secrets 管理**: 使用 GitHub Secrets 存储敏感信息
3. **文件权限**: 脚本自动设置 OCI 配置文件的正确权限
4. **网络安全**: 考虑对 OCI 资源设置 IP 限制
