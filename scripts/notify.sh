#!/bin/bash

# Telegram notification script
# Handles sending notifications via Telegram bot with severity levels:
# - critical: 🚨 Authentication/config failures requiring immediate attention
# - error: ❌ Operational failures
# - warning: ⚠️ Capacity issues, rate limits
# - info: ℹ️ Status updates, informational
# - success: ✅ Successful operations

set -euo pipefail

# Try to source utils.sh with fallback functions
UTILS_PATH="$(dirname "$0")/utils.sh"
if [[ -f "$UTILS_PATH" ]]; then
    # shellcheck source=scripts/utils.sh
    source "$UTILS_PATH"
else
    # Fallback functions when utils.sh is not available (e.g., in GitHub Actions notification job)
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warning() { echo "[WARNING] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    
    # Simple retry implementation as fallback
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
            
            echo "[DEBUG] Retry attempt $attempt failed, waiting ${delay}s..." >&2
            sleep "$delay"
            ((attempt++))
            delay=$((delay * 2))  # Exponential backoff
        done
        return 1
    }
fi

# Send Telegram notification
send_telegram_notification() {
    local notification_type="$1"  # success, error, critical, warning, info
    local message="$2"
    
    # Validate required environment variables
    if [[ -z "${TELEGRAM_TOKEN:-}" ]] || [[ -z "${TELEGRAM_USER_ID:-}" ]]; then
        log_warning "Telegram 凭据未配置，跳过通知"
        return 0
    fi
    
    # Add emoji and formatting based on notification type
    local formatted_message
    case "$notification_type" in
        "success")
            formatted_message="✅ **SUCCESS**: $message"
            ;;
        "error")
            formatted_message="❌ **ERROR**: $message"
            ;;
        "critical")
            formatted_message="🚨 **CRITICAL**: $message"
            ;;
        "warning")
            formatted_message="⚠️ **WARNING**: $message"
            ;;
        "info")
            formatted_message="ℹ️ **INFO**: $message"
            ;;
        *)
            formatted_message="💬 $message"
            ;;
    esac
    
    # Add timestamp
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S UTC')
    formatted_message="$formatted_message

*Time*: $timestamp
*Workflow*: Oracle Instance Creator (Parallel)"
    
    log_debug "正在发送 Telegram 通知: $notification_type"
    
    # Send notification using curl
    local response
    local status
    
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
        # Check if Telegram API returned success
        if echo "$response" | grep -q '"ok":true'; then
            log_debug "Telegram 通知发送成功"
        else
            log_warning "Telegram API 返回错误: $response"
        fi
    else
        log_warning "Telegram 通知发送失败 (curl 退出码: $status)"
        log_debug "Curl 错误: $response"
    fi
}

# Send notification with retry logic
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

# Send instance creation success notification
notify_instance_created() {
    local instance_name="$1"
    local instance_ocid="$2"
    local region="${OCI_REGION:-unknown}"
    local shape="${OCI_SHAPE:-unknown}"
    
    local message="Oracle Cloud instance created successfully!

**Instance Details:**
• Name: $instance_name
• OCID: $instance_ocid
• Region: $region
• Shape: $shape"
    
    if [[ "$OCI_SHAPE" == *"Flex" ]]; then
        message="$message
• OCPUs: ${OCI_OCPUS:-unknown}
• Memory: ${OCI_MEMORY_IN_GBS:-unknown}GB"
    fi
    
    send_telegram_notification_with_retry "success" "$message"
}

# notify_capacity_unavailable() function removed - capacity issues are expected operational conditions
# and should not generate notifications per the notification policy

# Send configuration error notification
notify_configuration_error() {
    local error_message="$1"
    
    local message="Oracle Instance Creator configuration error detected.

**Error:** $error_message

**Action Required:** Check GitHub repository secrets and workflow configuration."
    
    send_telegram_notification_with_retry "error" "$message"
}

# Send authentication error notification
notify_authentication_error() {
    local message="Oracle Cloud authentication failed.

**Possible Causes:**
• Invalid OCI credentials
• Expired API key
• Incorrect user permissions
• Invalid tenancy/compartment configuration

**Action Required:** Verify OCI configuration in GitHub secrets."
    
    send_telegram_notification_with_retry "critical" "$message"
}

# Send network error notification
notify_network_error() {
    local message="Network error occurred during Oracle Cloud operation.

**Possible Causes:**
• Temporary connectivity issues
• OCI service outage
• Firewall/network restrictions

**Action:** Operation will be retried automatically."
    
    send_telegram_notification "warning" "$message"
}

# Send workflow started notification
notify_workflow_started() {
    local message="Oracle Instance Creator workflow started.

**Configuration:**
• Region: ${OCI_REGION:-unknown}
• Shape: ${OCI_SHAPE:-unknown}
• Instance Name: ${INSTANCE_DISPLAY_NAME:-unknown}"
    
    send_telegram_notification "info" "$message"
}

# Send workflow completed notification
notify_workflow_completed() {
    local status="$1"  # success, failed, skipped
    local message="Oracle Instance Creator workflow completed.

**Status:** $status"
    
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

# Test Telegram configuration
test_telegram_config() {
    log_info "正在测试 Telegram 配置..."
    
    local test_message="Oracle Instance Creator - Configuration Test

This is a test message to verify Telegram bot configuration is working correctly.

If you receive this message, the configuration is valid!"
    
    send_telegram_notification "info" "$test_message"
}

# Function to be called from other scripts (backward compatibility)
# This maintains compatibility with the launch-instance.sh script
send_notification() {
    local type="$1"
    local message="$2"
    send_telegram_notification "$type" "$message"
}

# Run test if called directly with 'test' argument
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    if [[ "${1:-}" == "test" ]]; then
        test_telegram_config
    else
        echo "Usage: $0 test"
        echo "  test  - Send test notification to verify configuration"
    fi
fi