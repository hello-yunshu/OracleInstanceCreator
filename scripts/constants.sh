#!/bin/bash
# Oracle Instance Creator 集中化配置常量
# 本文件包含项目中使用的所有魔法数字和配置常量

# shellcheck disable=SC2034

# 防止重复加载
if [[ -n "${OIC_CONSTANTS_LOADED:-}" ]]; then
    return 0
fi
readonly OIC_CONSTANTS_LOADED=true

# =============================================================================
# GITHUB ACTIONS 与计费优化
# =============================================================================

# GitHub Actions 计费优化 - 控制在 60s 以内避免 2 分钟计费边界
# 计费逻辑：GitHub Actions 按整分钟计费
# - 60s 以下 = 1 分钟计费
# - 60s 以上 = 2 分钟计费
# - 55s 超时提供 5s 安全缓冲用于作业清理
# - 此优化相比 2 分钟计费节省 50% 成本
readonly GITHUB_ACTIONS_BILLING_TIMEOUT=55
readonly GITHUB_ACTIONS_BILLING_BOUNDARY=60

# 进程监控和清理时序
readonly PROCESS_MONITORING_INTERVAL=1
readonly GRACEFUL_TERMINATION_DELAY=2
readonly RESULT_FILE_WAIT_TIMEOUT=30
readonly RESULT_FILE_POLL_INTERVAL=0.1

# =============================================================================
# OCI 性能优化
# =============================================================================

# OCI CLI 性能标志 - 提升 93%（2 分钟 -> 20 秒）
readonly OCI_CONNECTION_TIMEOUT_SECONDS=5
readonly OCI_READ_TIMEOUT_SECONDS=15
readonly OCI_NO_RETRY_FLAG="--no-retry"

# =============================================================================
# 错误处理与重试配置
# =============================================================================

# 重试配置边界
readonly RETRY_WAIT_TIME_MIN=1
readonly RETRY_WAIT_TIME_MAX=300
readonly RETRY_WAIT_TIME_DEFAULT=30

# 瞬态错误重试配置（指数退避）
# 策略：对于 INTERNAL_ERROR 和 NETWORK 错误，在同一 AD 重试后再切换到下一个 AD
readonly TRANSIENT_ERROR_MAX_RETRIES_MIN=1
readonly TRANSIENT_ERROR_MAX_RETRIES_MAX=10
readonly TRANSIENT_ERROR_MAX_RETRIES_DEFAULT=3
readonly TRANSIENT_ERROR_RETRY_DELAY_MIN=1
readonly TRANSIENT_ERROR_RETRY_DELAY_MAX=60
readonly TRANSIENT_ERROR_RETRY_DELAY_DEFAULT=15

# 退出码（遵循 GNU 标准）
readonly OCI_EXIT_SUCCESS=0
readonly OCI_EXIT_GENERAL_ERROR=1
readonly OCI_EXIT_CAPACITY_ERROR=2
readonly OCI_EXIT_CONFIG_ERROR=3
readonly OCI_EXIT_NETWORK_ERROR=4
readonly OCI_EXIT_USER_LIMIT_ERROR=5
readonly OCI_EXIT_RATE_LIMIT_ERROR=6
readonly OCI_EXIT_TIMEOUT=124

# =============================================================================
# 实例配置
# =============================================================================

# 实例验证
readonly INSTANCE_VERIFY_MAX_CHECKS_MIN=1
readonly INSTANCE_VERIFY_MAX_CHECKS_MAX=20
readonly INSTANCE_VERIFY_MAX_CHECKS_DEFAULT=5
readonly INSTANCE_VERIFY_DELAY_MIN=5
readonly INSTANCE_VERIFY_DELAY_MAX=120
readonly INSTANCE_VERIFY_DELAY_DEFAULT=30

# 引导卷配置
readonly BOOT_VOLUME_SIZE_MIN=50
readonly BOOT_VOLUME_SIZE_MAX=200
readonly BOOT_VOLUME_SIZE_DEFAULT=50

# =============================================================================
# ORACLE CLOUD 形状与资源限制
# =============================================================================

# 免费层形状配置
readonly A1_FLEX_SHAPE="VM.Standard.A1.Flex"
readonly A1_FLEX_OCPUS=4
readonly A1_FLEX_MEMORY_GB=24
readonly A1_FLEX_INSTANCE_NAME="a1-flex-sg"

readonly E2_MICRO_SHAPE="VM.Standard.E2.1.Micro"
readonly E2_MICRO_OCPUS=""
readonly E2_MICRO_MEMORY_GB=""
readonly E2_MICRO_INSTANCE_NAME="e2-micro-sg"

# =============================================================================
# 安全与文件权限
# =============================================================================

# 文件权限（八进制表示）
readonly SECURE_DIR_PERMISSIONS=700
readonly SECURE_FILE_PERMISSIONS=600
readonly UMASK_SECURE=077

# =============================================================================
# 网络与代理配置
# =============================================================================

# 代理端口验证
readonly PROXY_PORT_MIN=1
readonly PROXY_PORT_MAX=65535
readonly PROXY_DEFAULT_PORT=3128

# =============================================================================
# 验证模式
# =============================================================================

# OCID 验证模式
readonly OCID_PATTERN='^ocid1\.[a-z0-9]+(\.[a-z0-9-]*)?(\.[a-z0-9-]*)?\..*'

# 可用域模式（逗号分隔）
readonly AD_PATTERN='^[a-zA-Z0-9:._-]+(,[a-zA-Z0-9:._-]+)*$'

# 代理 URL 模式
readonly PROXY_IPV4_PATTERN='^(https?://)?([^:@]+):([^:@]+)@([^:@]+):([0-9]+)/?$'
readonly PROXY_IPV6_PATTERN='^(https?://)?([^:@]+):([^:@]+)@\[([0-9a-fA-F:]+)\]:([0-9]+)/?$'

# =============================================================================
# 调试与日志
# =============================================================================

# 日志级别
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARNING=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_SUCCESS=4

# =============================================================================
# 状态管理与缓存
# =============================================================================

# GitHub Actions 缓存配置
readonly CACHE_ENABLED_DEFAULT="true"
readonly CACHE_TTL_HOURS_MIN=1
readonly CACHE_TTL_HOURS_MAX=168
readonly CACHE_TTL_HOURS_DEFAULT=24
readonly CACHE_VERSION="v1"
readonly STATE_FILE_NAME="instance-state.json"

# 缓存键生成
readonly CACHE_KEY_PREFIX="oci-instances"
readonly CACHE_PATH_DEFAULT=".cache/oci-state"

# 动态 TTL 配置
readonly HIGH_CONTENTION_REGIONS="ap-singapore-1,us-ashburn-1,us-phoenix-1,eu-frankfurt-1"
readonly HIGH_CONTENTION_TTL_MULTIPLIER="0.5"

# 缓存统计追踪
readonly CACHE_STATS_FILE="cache-stats.json"

# =============================================================================
# 常量辅助函数
# =============================================================================

# 获取超时值（带验证）
get_timeout_value() {
    local env_var="$1"
    local default_value="$2"
    local min_value="$3"
    local max_value="$4"

    local value="${!env_var:-$default_value}"

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt "$min_value" ]] || [[ "$value" -gt "$max_value" ]]; then
        echo "$default_value"
    else
        echo "$value"
    fi
}

# 获取重试配置（带验证）
get_retry_config() {
    local config_type="$1"

    case "$config_type" in
        "max_retries")
            get_timeout_value "TRANSIENT_ERROR_MAX_RETRIES" "$TRANSIENT_ERROR_MAX_RETRIES_DEFAULT" \
                                "$TRANSIENT_ERROR_MAX_RETRIES_MIN" "$TRANSIENT_ERROR_MAX_RETRIES_MAX"
            ;;
        "retry_delay")
            get_timeout_value "TRANSIENT_ERROR_RETRY_DELAY" "$TRANSIENT_ERROR_RETRY_DELAY_DEFAULT" \
                                "$TRANSIENT_ERROR_RETRY_DELAY_MIN" "$TRANSIENT_ERROR_RETRY_DELAY_MAX"
            ;;
        *)
            echo "无效的重试配置类型: $config_type" >&2
            return 1
            ;;
    esac
}

# 导出常用常量为环境变量
export_common_constants() {
    export GITHUB_ACTIONS_TIMEOUT_SECONDS="$GITHUB_ACTIONS_BILLING_TIMEOUT"
    export OCI_CONNECTION_TIMEOUT="$OCI_CONNECTION_TIMEOUT_SECONDS"
    export OCI_READ_TIMEOUT="$OCI_READ_TIMEOUT_SECONDS"
    export SECURE_UMASK="$UMASK_SECURE"
}

# =============================================================================
# 配置验证
# =============================================================================

# 验证所有常量是否在预期范围内
validate_constants() {
    local errors=0

    if [[ "$GITHUB_ACTIONS_BILLING_TIMEOUT" -ge "$GITHUB_ACTIONS_BILLING_BOUNDARY" ]]; then
        echo "错误: GITHUB_ACTIONS_BILLING_TIMEOUT ($GITHUB_ACTIONS_BILLING_TIMEOUT) 必须小于计费边界 ($GITHUB_ACTIONS_BILLING_BOUNDARY)" >&2
        ((errors++))
    fi

    if [[ "$OCI_CONNECTION_TIMEOUT_SECONDS" -ge "$OCI_READ_TIMEOUT_SECONDS" ]]; then
        echo "错误: OCI_CONNECTION_TIMEOUT_SECONDS 应小于 OCI_READ_TIMEOUT_SECONDS" >&2
        ((errors++))
    fi

    if [[ "$BOOT_VOLUME_SIZE_MIN" -lt 50 ]]; then
        echo "错误: BOOT_VOLUME_SIZE_MIN ($BOOT_VOLUME_SIZE_MIN) 不能小于 Oracle 最低要求 (50GB)" >&2
        ((errors++))
    fi

    if [[ "$CACHE_TTL_HOURS_MIN" -lt 1 ]]; then
        echo "错误: CACHE_TTL_HOURS_MIN ($CACHE_TTL_HOURS_MIN) 至少为 1 小时" >&2
        ((errors++))
    fi

    if [[ "$CACHE_TTL_HOURS_MAX" -gt 168 ]]; then
        echo "错误: CACHE_TTL_HOURS_MAX ($CACHE_TTL_HOURS_MAX) 不能超过 GitHub Actions 缓存限制 (168 小时)" >&2
        ((errors++))
    fi

    if [[ "$CACHE_TTL_HOURS_DEFAULT" -lt "$CACHE_TTL_HOURS_MIN" ]] || [[ "$CACHE_TTL_HOURS_DEFAULT" -gt "$CACHE_TTL_HOURS_MAX" ]]; then
        echo "错误: CACHE_TTL_HOURS_DEFAULT ($CACHE_TTL_HOURS_DEFAULT) 必须在 $CACHE_TTL_HOURS_MIN 和 $CACHE_TTL_HOURS_MAX 之间" >&2
        ((errors++))
    fi

    return $errors
}

# 加载时自动验证常量
if ! validate_constants; then
    echo "致命错误: 常量验证失败 - 请检查配置" >&2
    exit 1
fi
