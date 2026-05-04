#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/utils.sh"

validate_oci_configuration() {
    log_info "正在验证 OCI 配置..."
    
    require_env_var "OCI_USER_OCID"
    require_env_var "OCI_KEY_FINGERPRINT"
    require_env_var "OCI_TENANCY_OCID" 
    require_env_var "OCI_REGION"
    require_env_var "OCI_PRIVATE_KEY"
    require_env_var "OCI_SUBNET_ID"
    
    if ! is_valid_ocid "$OCI_USER_OCID"; then
        die "OCI_USER_OCID 格式无效: $OCI_USER_OCID"
    fi
    
    if ! is_valid_ocid "$OCI_TENANCY_OCID"; then
        die "OCI_TENANCY_OCID 格式无效: $OCI_TENANCY_OCID"
    fi
    
    if ! is_valid_ocid "$OCI_SUBNET_ID"; then
        die "OCI_SUBNET_ID 格式无效: $OCI_SUBNET_ID"
    fi
    
    if [[ -n "${OCI_COMPARTMENT_ID:-}" ]] && ! is_valid_ocid "$OCI_COMPARTMENT_ID"; then
        die "OCI_COMPARTMENT_ID 格式无效: $OCI_COMPARTMENT_ID"
    fi
    
    if [[ -n "${OCI_IMAGE_ID:-}" ]] && ! is_valid_ocid "$OCI_IMAGE_ID"; then
        die "OCI_IMAGE_ID 格式无效: $OCI_IMAGE_ID"
    fi
    
    log_success "OCI 配置验证通过"
}

validate_instance_configuration() {
    log_info "正在验证实例配置..."
    
    export OCI_AD="${OCI_AD:-fgaj:AP-SINGAPORE-1-AD-1}"
    export OCI_SHAPE="${OCI_SHAPE:-VM.Standard.A1.Flex}"
    export INSTANCE_DISPLAY_NAME="${INSTANCE_DISPLAY_NAME:-oci-free-instance}"
    export OPERATING_SYSTEM="${OPERATING_SYSTEM:-Oracle Linux}"
    export OS_VERSION="${OS_VERSION:-10}"
    export ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"
    
    export BOOT_VOLUME_SIZE="${BOOT_VOLUME_SIZE:-50}"
    export RECOVERY_ACTION="${RECOVERY_ACTION:-RESTORE_INSTANCE}"
    export LEGACY_IMDS_ENDPOINTS="${LEGACY_IMDS_ENDPOINTS:-false}"
    export RETRY_WAIT_TIME="${RETRY_WAIT_TIME:-30}"
    
    validate_timeout_value "RETRY_WAIT_TIME" "$RETRY_WAIT_TIME" 5 300
    
    if [[ -n "${INSTANCE_VERIFY_DELAY:-}" ]]; then
        validate_timeout_value "INSTANCE_VERIFY_DELAY" "$INSTANCE_VERIFY_DELAY" 5 120
    fi
    
    if [[ -n "${INSTANCE_VERIFY_MAX_CHECKS:-}" ]]; then
        if ! [[ "$INSTANCE_VERIFY_MAX_CHECKS" =~ ^[0-9]+$ ]] || [[ "$INSTANCE_VERIFY_MAX_CHECKS" -lt 1 || "$INSTANCE_VERIFY_MAX_CHECKS" -gt 20 ]]; then
            die "INSTANCE_VERIFY_MAX_CHECKS 无效: $INSTANCE_VERIFY_MAX_CHECKS（必须在 1-20 之间）"
        fi
    fi
    
    if ! validate_availability_domain "$OCI_AD"; then
        die "可用性域验证失败"
    fi
    
    if ! validate_boot_volume_size "$BOOT_VOLUME_SIZE"; then
        die "引导卷大小验证失败"
    fi
    
    if [[ "$OCI_SHAPE" == *"Flex" ]]; then
        export OCI_OCPUS="${OCI_OCPUS:-4}"
        export OCI_MEMORY_IN_GBS="${OCI_MEMORY_IN_GBS:-24}"
        
        if ! [[ "$OCI_OCPUS" =~ ^[0-9]+$ ]] || [[ "$OCI_OCPUS" -le 0 ]]; then
            die "OCI_OCPUS 必须为正整数，当前值: $OCI_OCPUS"
        fi
        
        if ! [[ "$OCI_MEMORY_IN_GBS" =~ ^[0-9]+$ ]] || [[ "$OCI_MEMORY_IN_GBS" -le 0 ]]; then
            die "OCI_MEMORY_IN_GBS 必须为正整数，当前值: $OCI_MEMORY_IN_GBS"
        fi
        
        log_info "弹性形状配置: ${OCI_OCPUS} OCPU, ${OCI_MEMORY_IN_GBS}GB 内存"
    fi
    
    if [[ "$ASSIGN_PUBLIC_IP" != "true" && "$ASSIGN_PUBLIC_IP" != "false" ]]; then
        die "ASSIGN_PUBLIC_IP 必须为 'true' 或 'false'，当前值: $ASSIGN_PUBLIC_IP"
    fi
    
    if [[ "$LEGACY_IMDS_ENDPOINTS" != "true" && "$LEGACY_IMDS_ENDPOINTS" != "false" ]]; then
        die "LEGACY_IMDS_ENDPOINTS 必须为 'true' 或 'false'，当前值: $LEGACY_IMDS_ENDPOINTS"
    fi
    
    if ! [[ "$RETRY_WAIT_TIME" =~ ^[0-9]+$ ]] || [[ "$RETRY_WAIT_TIME" -lt 1 || "$RETRY_WAIT_TIME" -gt 300 ]]; then
        die "RETRY_WAIT_TIME 必须在 1-300 秒之间，当前值: $RETRY_WAIT_TIME"
    fi
    
    local max_retries="${TRANSIENT_ERROR_MAX_RETRIES:-3}"
    local retry_delay="${TRANSIENT_ERROR_RETRY_DELAY:-15}"
    
    if ! [[ "$max_retries" =~ ^[0-9]+$ ]] || [[ "$max_retries" -lt 1 || "$max_retries" -gt 10 ]]; then
        die "TRANSIENT_ERROR_MAX_RETRIES 必须在 1-10 之间，当前值: $max_retries"
    fi
    
    if ! [[ "$retry_delay" =~ ^[0-9]+$ ]] || [[ "$retry_delay" -lt 1 || "$retry_delay" -gt 60 ]]; then
        die "TRANSIENT_ERROR_RETRY_DELAY 必须在 1-60 秒之间，当前值: $retry_delay"
    fi
    
    if [[ -n "${OCI_AD:-}" ]]; then
        if ! [[ "$OCI_AD" =~ ^[a-zA-Z0-9:._-]+(,[a-zA-Z0-9:._-]+)*$ ]]; then
            die "OCI_AD 格式无效。期望逗号分隔的 AD 名称，当前值: $OCI_AD"
        fi
        log_debug "AD 格式验证通过: $OCI_AD"
    fi
    
    if [[ "$RECOVERY_ACTION" != "RESTORE_INSTANCE" && "$RECOVERY_ACTION" != "STOP_INSTANCE" ]]; then
        die "RECOVERY_ACTION 必须为 'RESTORE_INSTANCE' 或 'STOP_INSTANCE'，当前值: $RECOVERY_ACTION"
    fi
    
    log_success "实例配置验证通过"
}

validate_ssh_configuration() {
    log_info "正在验证 SSH 配置..."
    
    require_env_var "INSTANCE_SSH_PUBLIC_KEY"
    
    if ! echo "$INSTANCE_SSH_PUBLIC_KEY" | grep -q "^ssh-"; then
        log_warning "SSH 公钥不以 'ssh-' 开头，可能导致问题"
    fi
    
    log_success "SSH 配置验证通过"
}

validate_notification_configuration() {
    log_info "正在验证通知配置..."
    
    require_env_var "TELEGRAM_TOKEN"
    require_env_var "TELEGRAM_USER_ID"
    
    if ! [[ "$TELEGRAM_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        log_warning "Telegram 令牌格式可能无效"
    fi
    
    if ! [[ "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]]; then
        die "TELEGRAM_USER_ID 必须为数字，当前值: $TELEGRAM_USER_ID"
    fi
    
    log_success "通知配置验证通过"
}

validate_proxy_configuration() {
    log_info "正在验证代理配置..."
    
    if [[ -z "${OCI_PROXY_URL:-}" ]]; then
        log_debug "未提供代理 URL - 跳过代理验证"
        return 0
    fi
    
    local proxy_url_regex='^(https?://)?([^:@]+):([^:@]+)@(\[([0-9a-fA-F:]+)\]|([^:@]+)):[0-9]+/?$'
    
    if ! [[ "$OCI_PROXY_URL" =~ $proxy_url_regex ]]; then
        die "OCI_PROXY_URL 格式无效。期望格式:
  IPv4: [http://]用户:密码@主机:端口[/]
  IPv6: [http://]用户:密码@[主机]:端口[/]
  特殊字符支持 URL 编码"
    fi
    
    local port
    if [[ "$OCI_PROXY_URL" =~ @\[([^]]+)\]:([0-9]+) ]]; then
        port="${BASH_REMATCH[2]}"
    elif [[ "$OCI_PROXY_URL" =~ @([^:]+):([0-9]+) ]]; then
        port="${BASH_REMATCH[2]}"
    fi
    
    if [[ -n "$port" ]] && (( port < 1 || port > 65535 )); then
        die "代理端口无效: $port（必须在 1-65535 之间）"
    fi
    
    log_success "代理 URL 格式验证通过"
    parse_and_configure_proxy true
}

print_configuration_summary() {
    log_info "配置摘要:"
    echo "  区域: $OCI_REGION"
    echo "  可用性域: $OCI_AD"
    echo "  形状: $OCI_SHAPE"
    if [[ "$OCI_SHAPE" == *"Flex" ]]; then
        echo "  OCPU: $OCI_OCPUS"
        echo "  内存: ${OCI_MEMORY_IN_GBS}GB"
    fi
    echo "  实例名称: $INSTANCE_DISPLAY_NAME"
    echo "  操作系统: $OPERATING_SYSTEM $OS_VERSION"
    echo "  公网 IP: $ASSIGN_PUBLIC_IP"
    echo "  引导卷大小: ${BOOT_VOLUME_SIZE}GB"
    echo "  恢复操作: $RECOVERY_ACTION"
    echo "  旧版 IMDS 端点: $LEGACY_IMDS_ENDPOINTS"
    echo "  重试等待时间: ${RETRY_WAIT_TIME}s"
    echo "  区间: ${OCI_COMPARTMENT_ID:-$OCI_TENANCY_OCID (租户)}"
}

validate_constants_configuration() {
    log_info "正在验证集中常量..."
    
    if [[ "$GITHUB_ACTIONS_BILLING_TIMEOUT" -ge "$GITHUB_ACTIONS_BILLING_BOUNDARY" ]]; then
        die "GITHUB_ACTIONS_BILLING_TIMEOUT ($GITHUB_ACTIONS_BILLING_TIMEOUT) 必须小于计费边界 ($GITHUB_ACTIONS_BILLING_BOUNDARY)"
    fi
    
    if [[ "$OCI_CONNECTION_TIMEOUT_SECONDS" -ge "$OCI_READ_TIMEOUT_SECONDS" ]]; then
        die "OCI_CONNECTION_TIMEOUT_SECONDS ($OCI_CONNECTION_TIMEOUT_SECONDS) 应小于 OCI_READ_TIMEOUT_SECONDS ($OCI_READ_TIMEOUT_SECONDS)"
    fi
    
    if [[ "$TRANSIENT_ERROR_MAX_RETRIES_DEFAULT" -lt "$TRANSIENT_ERROR_MAX_RETRIES_MIN" ]] || 
       [[ "$TRANSIENT_ERROR_MAX_RETRIES_DEFAULT" -gt "$TRANSIENT_ERROR_MAX_RETRIES_MAX" ]]; then
        die "TRANSIENT_ERROR_MAX_RETRIES_DEFAULT ($TRANSIENT_ERROR_MAX_RETRIES_DEFAULT) 必须在 $TRANSIENT_ERROR_MAX_RETRIES_MIN-$TRANSIENT_ERROR_MAX_RETRIES_MAX 之间"
    fi
    
    if [[ "$BOOT_VOLUME_SIZE_DEFAULT" -lt "$BOOT_VOLUME_SIZE_MIN" ]]; then
        die "BOOT_VOLUME_SIZE_DEFAULT ($BOOT_VOLUME_SIZE_DEFAULT) 不能小于最低要求 ($BOOT_VOLUME_SIZE_MIN)"
    fi
    
    log_success "常量配置验证通过"
}

validate_all_configuration() {
    log_info "开始配置验证..."
    
    validate_constants_configuration
    
    if ! validate_configuration; then
        die "综合配置验证失败"
    fi
    
    validate_oci_configuration
    validate_instance_configuration
    validate_ssh_configuration
    validate_notification_configuration
    validate_proxy_configuration
    
    print_configuration_summary
    
    log_success "所有配置验证通过"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    validate_all_configuration
fi
