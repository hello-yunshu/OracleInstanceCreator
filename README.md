# Oracle Instance Creator

通过 GitHub Actions 自动化抢占 Oracle Cloud 免费层实例（A1.Flex ARM 和 E2.1.Micro AMD），支持并行执行、智能重试和引导卷迁移。

## 主要特性

- **并行部署** — 同时尝试 ARM 和 AMD 两种形状的实例创建
- **多 AD 循环** — 自动在多个可用域间切换，配合熔断器跳过持续失败的 AD
- **引导卷迁移** — 支持将已有引导卷附加到新实例，保留原有数据和环境
- **智能错误处理** — 层次化错误分类，区分容量不足（正常）、速率限制、配置错误等
- **Telegram 通知** — 实时推送创建成功/失败通知
- **93% 性能优化** — 通过 OCI CLI 参数调优，将执行时间从 2 分钟降至 20 秒
- **代理支持** — 支持 IPv4/IPv6 代理配置
- **熔断器模式** — AD 级别熔断，连续 3 次失败后自动跳过
- **自适应调度** — 根据历史成功模式优化调度策略

## 支持的区域

| 区域 | 标识 | 可用域 | 时区 |
|------|------|--------|------|
| 新加坡 | `ap-singapore-1` | 1 | Asia/Singapore |
| 圣何塞 | `us-sanjose-1` | 1 | America/Los_Angeles |
| 阿什本 | `us-ashburn-1` | 3 | America/New_York |
| 凤凰城 | `us-phoenix-1` | 3 | America/Phoenix |
| 法兰克福 | `eu-frankfurt-1` | 3 | Europe/Berlin |
| 伦敦 | `uk-london-1` | 3 | Europe/London |
| 阿姆斯特丹 | `eu-amsterdam-1` | 1 | Europe/Amsterdam |
| 东京 | `ap-tokyo-1` | 1 | Asia/Tokyo |
| 首尔 | `ap-seoul-1` | 1 | Asia/Seoul |
| 悉尼 | `ap-sydney-1` | 1 | Australia/Sydney |
| 孟买 | `ap-mumbai-1` | 1 | Asia/Kolkata |
| 多伦多 | `ca-toronto-1` | 1 | America/Toronto |
| 圣保罗 | `sa-saopaulo-1` | 1 | America/Sao_Paulo |

## 快速开始

### 1. Fork 本仓库

### 2. 配置 GitHub Secrets

在仓库的 **Settings → Secrets and variables → Actions** 中添加以下 Secrets：

| Secret | 必需 | 说明 |
|--------|------|------|
| `OCI_USER_OCID` | ✅ | OCI 用户 OCID |
| `OCI_KEY_FINGERPRINT` | ✅ | API 密钥指纹 |
| `OCI_TENANCY_OCID` | ✅ | 租户 OCID |
| `OCI_REGION` | ✅ | 区域标识，如 `us-sanjose-1` |
| `OCI_PRIVATE_KEY` | ✅ | API 私钥（PEM 格式） |
| `OCI_SUBNET_ID` | ✅ | 子网 OCID |
| `INSTANCE_SSH_PUBLIC_KEY` | ✅ | SSH 公钥 |
| `TELEGRAM_TOKEN` | ✅ | Telegram Bot Token |
| `TELEGRAM_USER_ID` | ✅ | Telegram 用户 ID |
| `OCI_COMPARTMENT_ID` | ❌ | 隔离舱 OCID（默认使用租户 OCID） |
| `OCI_IMAGE_ID` | ❌ | 自定义镜像 OCID（默认自动查询最新镜像） |
| `OCI_PROXY_URL` | ❌ | 代理 URL（支持 IPv4/IPv6） |
| `OCI_AD` | ❌ | 可用域（默认 `fgaj:AP-SINGAPORE-1-AD-1`） |
| `OCI_REGION_TIMEZONE` | ❌ | 区域时区（默认 `Asia/Singapore`） |
| `OCI_BOOT_VOLUME_ID` | ❌ | 通用引导卷 OCID（留空则创建新引导卷） |
| `OCI_A1_BOOT_VOLUME_ID` | ❌ | A1.Flex 专用引导卷 OCID（留空则创建新引导卷） |

### 3. 启用 GitHub Actions

进入 **Actions** 标签页，启用工作流。

### 4. 运行工作流

手动触发 **Infrastructure Deployment** 工作流。

## 配置说明

### 区域配置

使用 `us-sanjose-1` 区域时，需要修改 `infrastructure-deployment.yml` 中的以下配置：

```yaml
OCI_AD: "AxQf:US-SANJOSE-1-AD-1"
ORACLE_REGION_TIMEZONE: "America/Los_Angeles"
```

同时将 `OCI_REGION` Secret 设置为 `us-sanjose-1`。

> **注意**：缓存镜像 ID 是区域专用的。切换区域时，将 `OCI_CACHED_OL10_ARM_IMAGE` 和 `OCI_CACHED_OL10_AMD_IMAGE` 留空，脚本会自动查询对应区域的最新镜像。

### 引导卷迁移

如果已有旧实例的引导卷，可以将其附加到新抢占的实例上，保留所有数据和环境配置：

1. 在 OCI 控制台终止旧实例时勾选 **"保留引导卷"**
2. 获取引导卷的 OCID
3. 在 `infrastructure-deployment.yml` 中设置：

```yaml
A1_BOOT_VOLUME_ID: "ocid1.bootvolume.oc1.us-sanjose-1.xxxxxx"
```

脚本会自动：
- 跳过镜像查找（不需要新镜像）
- 检查引导卷是否仍附加在旧实例上，如果是则自动分离
- 使用 `--boot-volume-id` 启动新实例

> **注意**：引导卷和新实例必须在同一个可用域（AD）中。

### 实例配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `OCI_SHAPE` | `VM.Standard.A1.Flex` | 实例形状 |
| `OCI_OCPUS` | `4` | CPU 核心数（仅 Flex 形状） |
| `OCI_MEMORY_IN_GBS` | `24` | 内存 GB（仅 Flex 形状） |
| `BOOT_VOLUME_SIZE` | `50` | 引导卷大小（GB，最低 50） |
| `ASSIGN_PUBLIC_IP` | `false` | 是否分配公网 IP |
| `RECOVERY_ACTION` | `RESTORE_INSTANCE` | 实例恢复策略 |

### 重试配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `RETRY_WAIT_TIME` | `30` | AD 切换间隔（秒） |
| `TRANSIENT_ERROR_MAX_RETRIES` | `3` | 同一 AD 瞬态错误重试次数 |
| `TRANSIENT_ERROR_RETRY_DELAY` | `15` | 瞬态错误重试退避基数（秒） |

## 错误处理

项目将 Oracle Cloud 的各种错误响应分为以下类别：

| 错误类型 | 退出码 | 处理策略 |
|----------|--------|----------|
| 成功 | 0 | 记录指标，通知，退出 |
| 容量不足 | 2 | 尝试下一个 AD |
| 配置/认证错误 | 3 | 立即失败并通知 |
| 网络/内部错误 | 4 | 同一 AD 指数退避重试 3 次 |
| 免费层限制 | 5 | 验证实例是否实际创建，缓存限制状态 |
| 速率限制 | 6 | 正常退出（非失败） |
| 超时 | 124 | 遵循 GNU timeout 标准 |

> **核心设计**：Oracle 免费层的容量不足（Out of capacity）是**正常的运营状态**，不是错误。退出码 0/2/5/6 在工作流中均被视为成功。

## 项目结构

```
OracleInstanceCreator/
├── .github/workflows/
│   └── infrastructure-deployment.yml   # GitHub Actions 工作流
├── config/
│   ├── defaults.yml                    # 默认配置
│   ├── instance-profiles.yml           # 实例配置档案
│   ├── regions.yml                     # 区域与可用域定义
│   └── templates/                      # 配置模板
├── scripts/
│   ├── launch-parallel.sh              # 并行启动编排器
│   ├── launch-instance.sh              # 单实例创建核心逻辑
│   ├── utils.sh                        # OCI CLI 封装 + 工具函数
│   ├── constants.sh                    # 集中化常量定义
│   ├── circuit-breaker.sh              # 熔断器模式
│   ├── state-manager.sh                # 实例状态缓存管理
│   ├── adaptive-scheduler.sh           # 自适应调度
│   ├── schedule-optimizer.sh           # 调度优化
│   ├── notify.sh                       # Telegram 通知
│   ├── setup-oci.sh                    # OCI CLI 认证配置
│   ├── setup-ssh.sh                    # SSH 密钥配置
│   ├── preflight-check.sh              # 预检
│   ├── validate-config.sh              # 配置校验
│   └── metrics.sh                      # AD 成功率指标
├── docs/dashboard/                     # 监控仪表板
└── tests/                              # 测试套件
```

## 使用圣何塞区域的具体操作步骤

1. **Fork 本仓库**

2. **配置 GitHub Secrets**：
   - `OCI_REGION` = `us-sanjose-1`
   - 其他 Secrets 按上表配置

3. **修改工作流配置**：
   
   编辑 `.github/workflows/infrastructure-deployment.yml`：
   ```yaml
   OCI_AD: "AxQf:US-SANJOSE-1-AD-1"
   ORACLE_REGION_TIMEZONE: "America/Los_Angeles"
   # 清空缓存镜像 ID，让脚本自动查询
   OCI_CACHED_OL10_ARM_IMAGE: ""
   OCI_CACHED_OL10_AMD_IMAGE: ""
   ```

4. **（可选）配置引导卷迁移**：
   ```yaml
   A1_BOOT_VOLUME_ID: "ocid1.bootvolume.oc1.us-sanjose-1.xxxxxx"
   ```

5. **运行工作流**：手动触发 Infrastructure Deployment

## License

MIT
