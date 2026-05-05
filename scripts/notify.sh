#!/bin/bash

# Telegram 通知脚本
# 通过 Telegram 机器人发送通知，支持以下严重级别：
# - critical: 🚨 认证/配置故障，需要立即处理
# - error: ❌ 操作失败
# - warning: ⚠️ 容量问题、速率限制
# - info: ℹ️ 状态更新、信息通知
# - success: ✅ 操作成功

set -euo pipefail

UTILS_PATH="$(dirname "$0")/utils.sh"
if [[ -f "$UTILS_PATH" ]]; then
    source "$UTILS_PATH"
else
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warning() { echo "[WARNING] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    
    retry_with_backoff() {
        local max_attempts="$1"
        local delay="$2"
        shift 2
        
        local attempt=1
        while [[ $attempt -le $max_attempts ]]; do
            if "$@"; then
                return 0
            fi
            
            if [[ $attempt -eq $max_attempts ]]; then
                return 1
            fi
            
            echo "[DEBUG] 第 $attempt 次重试失败，等待 ${delay}s..." >&2
            sleep "$delay"
            ((attempt++))
            delay=$((delay * 2))
        done
        return 1
    }
fi

send_telegram_notification() {
    local notification_type="$1"
    local message="$2"
    
    if [[ -z "${TELEGRAM_TOKEN:-}" ]] || [[ -z "${TELEGRAM_USER_ID:-}" ]]; then
        log_warning "Telegram 凭据未配置，跳过通知"
        return 0
    fi
    
    local formatted_message
    case "$notification_type" in
        "success")
            formatted_message="✅ **成功**: $message"
            ;;
        "error")
            formatted_message="❌ **错误**: $message"
            ;;
        "critical")
            formatted_message="🚨 **严重**: $message"
            ;;
        "warning")
            formatted_message="⚠️ **警告**: $message"
            ;;
        "info")
            formatted_message="ℹ️ **信息**: $message"
            ;;
        *)
            formatted_message="💬 $message"
            ;;
    esac
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S UTC')
    formatted_message="$formatted_message

*时间*: $timestamp
*工作流*: Oracle 实例创建器（并行）"
    
    log_debug "正在发送 Telegram 通知: $notification_type"
    
    local response
    local status
    local masked_token="${TELEGRAM_TOKEN:0:8}...${TELEGRAM_TOKEN: -4}"
    
    set +e
    response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_USER_ID}" \
        -d "parse_mode=Markdown" \
        --data-urlencode "text=${formatted_message}" \
        --connect-timeout 10 \
        --max-time 30 2>&1)
    status=$?
    set -e
    
    if [[ $status -eq 0 ]]; then
        if echo "$response" | grep -q '"ok":true'; then
            log_debug "Telegram 通知发送成功 (token: $masked_token)"
        else
            log_warning "Telegram API 返回错误 (token: $masked_token)"
            log_debug "API 响应详情: $response"
        fi
    else
        log_warning "Telegram 通知发送失败 (curl 退出码: $status, token: $masked_token)"
        log_debug "Curl 错误: $response"
    fi
}

send_telegram_notification_with_retry() {
    local notification_type="$1"
    local message="$2"
    local max_attempts="${3:-3}"
    
    log_debug "尝试发送 Telegram 通知（含重试）"
    
    if retry_with_backoff "$max_attempts" 5 send_telegram_notification "$notification_type" "$message"; then
        log_debug "Telegram 通知发送成功（含重试）"
    else
        log_error "Telegram 通知在 $max_attempts 次尝试后仍发送失败"
    fi
}

notify_instance_created() {
    local instance_name="$1"
    local instance_ocid="$2"
    local region="${OCI_REGION:-未知}"
    local shape="${OCI_SHAPE:-未知}"
    
    local message="Oracle Cloud 实例创建成功！

**实例详情：**
• 名称: $instance_name
• OCID: $instance_ocid
• 区域: $region
• 形状: $shape"
    
    if [[ "$OCI_SHAPE" == *"Flex" ]]; then
        message="$message
• OCPU: ${OCI_OCPUS:-未知}
• 内存: ${OCI_MEMORY_IN_GBS:-未知}GB"
    fi
    
    send_telegram_notification_with_retry "success" "$message"
}

notify_configuration_error() {
    local error_message="$1"
    
    local message="Oracle 实例创建器检测到配置错误。

**错误：** $error_message

**需要操作：** 检查 GitHub 仓库 Secrets 和工作流配置。"
    
    send_telegram_notification_with_retry "error" "$message"
}

notify_authentication_error() {
    local message="Oracle Cloud 认证失败。

**可能原因：**
• OCI 凭据无效
• API 密钥已过期
• 用户权限不足
• 租户/区间配置错误

**需要操作：** 验证 GitHub Secrets 中的 OCI 配置。"
    
    send_telegram_notification_with_retry "critical" "$message"
}

notify_network_error() {
    local message="Oracle Cloud 操作期间发生网络错误。

**可能原因：**
• 临时连接问题
• OCI 服务中断
• 防火墙/网络限制

**操作：** 操作将自动重试。"
    
    send_telegram_notification "warning" "$message"
}

notify_workflow_started() {
    local message="Oracle 实例创建器工作流已启动。

**配置：**
• 区域: ${OCI_REGION:-未知}
• 形状: ${OCI_SHAPE:-未知}
• 实例名称: ${INSTANCE_DISPLAY_NAME:-未知}"
    
    send_telegram_notification "info" "$message"
}

notify_workflow_completed() {
    local status="$1"
    local message="Oracle 实例创建器工作流已完成。

**状态：** $status"
    
    case "$status" in
        "success")
            send_telegram_notification "success" "$message"
            ;;
        "failed")
            send_telegram_notification "error" "$message"
            ;;
        "skipped")
            send_telegram_notification "info" "$message"
            ;;
        *)
            send_telegram_notification "info" "$message"
            ;;
    esac
}

test_telegram_config() {
    log_info "正在测试 Telegram 配置..."
    
    local test_message="Oracle 实例创建器 - 配置测试

这是一条测试消息，用于验证 Telegram 机器人配置是否正常。

如果你收到了这条消息，说明配置有效！"
    
    send_telegram_notification "info" "$test_message"
}

send_notification() {
    local type="$1"
    local message="$2"
    send_telegram_notification "$type" "$message"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    if [[ "${1:-}" == "test" ]]; then
        test_telegram_config
    else
        echo "用法: $0 test"
        echo "  test  - 发送测试通知以验证配置"
    fi
fi
