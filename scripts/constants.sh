#!/bin/bash
# Oracle Instance Creator 集中化配置常量
# 本文件包含项目中使用的所有魔法数字和配置常量

# shellcheck disable=SC2034

if [[ -n "${OIC_CONSTANTS_LOADED:-}" ]]; then
    return 0
fi
readonly OIC_CONSTANTS_LOADED=true

# =============================================================================
# GITHUB ACTIONS 与计费优化
# =============================================================================

readonly GITHUB_ACTIONS_BILLING_TIMEOUT=55
readonly GITHUB_ACTIONS_BILLING_BOUNDARY=60

readonly GRACEFUL_TERMINATION_DELAY=2
readonly RESULT_FILE_WAIT_TIMEOUT=30
readonly RESULT_FILE_POLL_INTERVAL=0.1

# =============================================================================
# OCI 性能优化
# =============================================================================

readonly OCI_CONNECTION_TIMEOUT_SECONDS=5
readonly OCI_READ_TIMEOUT_SECONDS=15

# =============================================================================
# 错误处理与重试配置
# =============================================================================

readonly RETRY_WAIT_TIME_MIN=1
readonly RETRY_WAIT_TIME_MAX=300
readonly RETRY_WAIT_TIME_DEFAULT=30

readonly TRANSIENT_ERROR_MAX_RETRIES_MIN=1
readonly TRANSIENT_ERROR_MAX_RETRIES_MAX=10
readonly TRANSIENT_ERROR_MAX_RETRIES_DEFAULT=3
readonly TRANSIENT_ERROR_RETRY_DELAY_MIN=1
readonly TRANSIENT_ERROR_RETRY_DELAY_MAX=60
readonly TRANSIENT_ERROR_RETRY_DELAY_DEFAULT=15

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

readonly INSTANCE_VERIFY_MAX_CHECKS_MIN=1
readonly INSTANCE_VERIFY_MAX_CHECKS_MAX=20
readonly INSTANCE_VERIFY_MAX_CHECKS_DEFAULT=5
readonly INSTANCE_VERIFY_DELAY_MIN=5
readonly INSTANCE_VERIFY_DELAY_MAX=120
readonly INSTANCE_VERIFY_DELAY_DEFAULT=30

readonly BOOT_VOLUME_SIZE_MIN=50
readonly BOOT_VOLUME_SIZE_DEFAULT=50

# =============================================================================
# ORACLE CLOUD 形状与资源限制
# =============================================================================

readonly A1_FLEX_SHAPE="VM.Standard.A1.Flex"
readonly A1_FLEX_OCPUS=4
readonly A1_FLEX_MEMORY_GB=24

readonly E2_MICRO_SHAPE="VM.Standard.E2.1.Micro"

# =============================================================================
# 安全与文件权限
# =============================================================================

readonly SECURE_DIR_PERMISSIONS=700
readonly SECURE_FILE_PERMISSIONS=600
readonly UMASK_SECURE=077

# =============================================================================
# 状态管理与缓存
# =============================================================================

readonly CACHE_ENABLED_DEFAULT="true"
readonly CACHE_TTL_HOURS_MIN=1
readonly CACHE_TTL_HOURS_MAX=168
readonly CACHE_TTL_HOURS_DEFAULT=24
readonly CACHE_VERSION="v1"
readonly STATE_FILE_NAME="instance-state.json"

readonly CACHE_KEY_PREFIX="oci-instances"
readonly CACHE_PATH_DEFAULT=".cache/oci-state"

readonly CACHE_STATS_FILE="cache-stats.json"

readonly ACTIVE_LIFECYCLE_STATES=(--lifecycle-state MOVING --lifecycle-state PROVISIONING --lifecycle-state RUNNING --lifecycle-state STARTING --lifecycle-state STOPPING --lifecycle-state STOPPED --lifecycle-state CREATING_IMAGE)

readonly HIGH_CONTENTION_REGIONS="ap-singapore-1,us-ashburn-1,us-phoenix-1,eu-frankfurt-1"
readonly HIGH_CONTENTION_TTL_MULTIPLIER="0.5"

# =============================================================================
# 常量辅助函数
# =============================================================================

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

# =============================================================================
# 配置验证
# =============================================================================

validate_constants() {
    local errors=0

    if [[ "$GITHUB_ACTIONS_BILLING_TIMEOUT" -ge "$GITHUB_ACTIONS_BILLING_BOUNDARY" ]]; then
        echo "错误: GITHUB_ACTIONS_BILLING_TIMEOUT ($GITHUB_ACTIONS_BILLING_TIMEOUT) 必须小于计费边界 ($GITHUB_ACTIONS_BILLING_BOUNDARY)" >&2
        ((errors += 1))
    fi

    if [[ "$OCI_CONNECTION_TIMEOUT_SECONDS" -ge "$OCI_READ_TIMEOUT_SECONDS" ]]; then
        echo "警告: OCI_CONNECTION_TIMEOUT_SECONDS 建议小于 OCI_READ_TIMEOUT_SECONDS" >&2
        ((errors += 1))
    fi

    if [[ "$BOOT_VOLUME_SIZE_MIN" -lt 50 ]]; then
        echo "错误: BOOT_VOLUME_SIZE_MIN ($BOOT_VOLUME_SIZE_MIN) 不能小于 Oracle 最低要求 (50GB)" >&2
        ((errors += 1))
    fi

    if [[ "$CACHE_TTL_HOURS_DEFAULT" -lt "$CACHE_TTL_HOURS_MIN" ]] || [[ "$CACHE_TTL_HOURS_DEFAULT" -gt "$CACHE_TTL_HOURS_MAX" ]]; then
        echo "错误: CACHE_TTL_HOURS_DEFAULT ($CACHE_TTL_HOURS_DEFAULT) 必须在 $CACHE_TTL_HOURS_MIN 和 $CACHE_TTL_HOURS_MAX 之间" >&2
        ((errors += 1))
    fi

    return "$errors"
}

if ! validate_constants; then
    echo "警告: 常量验证失败 - 请检查配置" >&2
fi
