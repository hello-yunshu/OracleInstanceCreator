#!/bin/bash

# Configuration validation script
# Validates all required environment variables and provides defaults

set -euo pipefail

source "$(dirname "$0")/utils.sh"

validate_oci_configuration() {
    log_info "正在验证 OCI 配置..."
    
    # Required OCI configuration
    require_env_var "OCI_USER_OCID"
    require_env_var "OCI_KEY_FINGERPRINT"
    require_env_var "OCI_TENANCY_OCID" 
    require_env_var "OCI_REGION"
    require_env_var "OCI_PRIVATE_KEY"
    require_env_var "OCI_SUBNET_ID"
    
    # Validate OCID formats
    if ! is_valid_ocid "$OCI_USER_OCID"; then
        die "Invalid OCI_USER_OCID format: $OCI_USER_OCID"
    fi
    
    if ! is_valid_ocid "$OCI_TENANCY_OCID"; then
        die "Invalid OCI_TENANCY_OCID format: $OCI_TENANCY_OCID"
    fi
    
    if ! is_valid_ocid "$OCI_SUBNET_ID"; then
        die "Invalid OCI_SUBNET_ID format: $OCI_SUBNET_ID"
    fi
    
    # Optional compartment ID (defaults to tenancy)
    if [[ -n "${OCI_COMPARTMENT_ID:-}" ]] && ! is_valid_ocid "$OCI_COMPARTMENT_ID"; then
        die "Invalid OCI_COMPARTMENT_ID format: $OCI_COMPARTMENT_ID"
    fi
    
    # Optional image ID validation
    if [[ -n "${OCI_IMAGE_ID:-}" ]] && ! is_valid_ocid "$OCI_IMAGE_ID"; then
        die "Invalid OCI_IMAGE_ID format: $OCI_IMAGE_ID"
    fi
    
    log_success "OCI 配置验证通过"
}

validate_instance_configuration() {
    log_info "正在验证实例配置..."
    
    # Required instance configuration with defaults
    export OCI_AD="${OCI_AD:-fgaj:AP-SINGAPORE-1-AD-1}"
    export OCI_SHAPE="${OCI_SHAPE:-VM.Standard.A1.Flex}"
    export INSTANCE_DISPLAY_NAME="${INSTANCE_DISPLAY_NAME:-oci-free-instance}"
    export OPERATING_SYSTEM="${OPERATING_SYSTEM:-Oracle Linux}"
    export OS_VERSION="${OS_VERSION:-10}"
    export ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"
    
    # New configuration options with defaults
    export BOOT_VOLUME_SIZE="${BOOT_VOLUME_SIZE:-50}"
    export RECOVERY_ACTION="${RECOVERY_ACTION:-RESTORE_INSTANCE}"
    export LEGACY_IMDS_ENDPOINTS="${LEGACY_IMDS_ENDPOINTS:-false}"
    export RETRY_WAIT_TIME="${RETRY_WAIT_TIME:-30}"
    
    # Validate timeout values are within reasonable bounds
    validate_timeout_value "RETRY_WAIT_TIME" "$RETRY_WAIT_TIME" 5 300
    
    if [[ -n "${INSTANCE_VERIFY_DELAY:-}" ]]; then
        validate_timeout_value "INSTANCE_VERIFY_DELAY" "$INSTANCE_VERIFY_DELAY" 5 120
    fi
    
    if [[ -n "${INSTANCE_VERIFY_MAX_CHECKS:-}" ]]; then
        if ! [[ "$INSTANCE_VERIFY_MAX_CHECKS" =~ ^[0-9]+$ ]] || [[ "$INSTANCE_VERIFY_MAX_CHECKS" -lt 1 || "$INSTANCE_VERIFY_MAX_CHECKS" -gt 20 ]]; then
            die "Invalid INSTANCE_VERIFY_MAX_CHECKS: $INSTANCE_VERIFY_MAX_CHECKS (must be between 1-20)"
        fi
    fi
    
    # Validate availability domain format (supports comma-separated list)
    if ! validate_availability_domain "$OCI_AD"; then
        die "Availability domain validation failed"
    fi
    
    # Validate boot volume size
    if ! validate_boot_volume_size "$BOOT_VOLUME_SIZE"; then
        die "Boot volume size validation failed"
    fi
    
    # Flexible shape configuration
    if [[ "$OCI_SHAPE" == *"Flex" ]]; then
        export OCI_OCPUS="${OCI_OCPUS:-4}"
        export OCI_MEMORY_IN_GBS="${OCI_MEMORY_IN_GBS:-24}"
        
        # Validate numeric values
        if ! [[ "$OCI_OCPUS" =~ ^[0-9]+$ ]] || [[ "$OCI_OCPUS" -le 0 ]]; then
            die "OCI_OCPUS must be a positive integer, got: $OCI_OCPUS"
        fi
        
        if ! [[ "$OCI_MEMORY_IN_GBS" =~ ^[0-9]+$ ]] || [[ "$OCI_MEMORY_IN_GBS" -le 0 ]]; then
            die "OCI_MEMORY_IN_GBS must be a positive integer, got: $OCI_MEMORY_IN_GBS"
        fi
        
        log_info "弹性形状配置: ${OCI_OCPUS} OCPU, ${OCI_MEMORY_IN_GBS}GB 内存"
    fi
    
    # Validate boolean values
    if [[ "$ASSIGN_PUBLIC_IP" != "true" && "$ASSIGN_PUBLIC_IP" != "false" ]]; then
        die "ASSIGN_PUBLIC_IP must be 'true' or 'false', got: $ASSIGN_PUBLIC_IP"
    fi
    
    if [[ "$LEGACY_IMDS_ENDPOINTS" != "true" && "$LEGACY_IMDS_ENDPOINTS" != "false" ]]; then
        die "LEGACY_IMDS_ENDPOINTS must be 'true' or 'false', got: $LEGACY_IMDS_ENDPOINTS"
    fi
    
    # Validate timeout configurations with bounds checking
    if ! [[ "$RETRY_WAIT_TIME" =~ ^[0-9]+$ ]] || [[ "$RETRY_WAIT_TIME" -lt 1 || "$RETRY_WAIT_TIME" -gt 300 ]]; then
        die "RETRY_WAIT_TIME must be between 1-300 seconds, got: $RETRY_WAIT_TIME"
    fi
    
    # Validate transient error retry configuration
    local max_retries="${TRANSIENT_ERROR_MAX_RETRIES:-3}"
    local retry_delay="${TRANSIENT_ERROR_RETRY_DELAY:-15}"
    
    if ! [[ "$max_retries" =~ ^[0-9]+$ ]] || [[ "$max_retries" -lt 1 || "$max_retries" -gt 10 ]]; then
        die "TRANSIENT_ERROR_MAX_RETRIES must be between 1-10, got: $max_retries"
    fi
    
    if ! [[ "$retry_delay" =~ ^[0-9]+$ ]] || [[ "$retry_delay" -lt 1 || "$retry_delay" -gt 60 ]]; then
        die "TRANSIENT_ERROR_RETRY_DELAY must be between 1-60 seconds, got: $retry_delay"
    fi
    
    # Validate AD format (comma-separated OCID-like values)
    if [[ -n "${OCI_AD:-}" ]]; then
        if ! [[ "$OCI_AD" =~ ^[a-zA-Z0-9:._-]+(,[a-zA-Z0-9:._-]+)*$ ]]; then
            die "OCI_AD format invalid. Expected comma-separated AD names, got: $OCI_AD"
        fi
        log_debug "AD 格式验证通过: $OCI_AD"
    fi
    
    # Validate recovery action
    if [[ "$RECOVERY_ACTION" != "RESTORE_INSTANCE" && "$RECOVERY_ACTION" != "STOP_INSTANCE" ]]; then
        die "RECOVERY_ACTION must be 'RESTORE_INSTANCE' or 'STOP_INSTANCE', got: $RECOVERY_ACTION"
    fi
    
    log_success "实例配置验证通过"
}

validate_ssh_configuration() {
    log_info "正在验证 SSH 配置..."
    
    require_env_var "INSTANCE_SSH_PUBLIC_KEY"
    
    # Basic SSH public key format validation
    if ! echo "$INSTANCE_SSH_PUBLIC_KEY" | grep -q "^ssh-"; then
        log_warning "SSH 公钥不以 'ssh-' 开头，可能导致问题"
    fi
    
    log_success "SSH 配置验证通过"
}

validate_notification_configuration() {
    log_info "正在验证通知配置..."
    
    require_env_var "TELEGRAM_TOKEN"
    require_env_var "TELEGRAM_USER_ID"
    
    # Basic Telegram token format validation (should be numeric:alphanumeric)
    if ! [[ "$TELEGRAM_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        log_warning "Telegram 令牌格式可能无效"
    fi
    
    # Telegram user ID should be numeric
    if ! [[ "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]]; then
        die "TELEGRAM_USER_ID must be numeric, got: $TELEGRAM_USER_ID"
    fi
    
    log_success "通知配置验证通过"
}

validate_proxy_configuration() {
    log_info "正在验证代理配置..."
    
    if [[ -z "${OCI_PROXY_URL:-}" ]]; then
        log_debug "未提供代理 URL - 跳过代理验证"
        return 0
    fi
    
    # Enhanced proxy URL validation with comprehensive regex
    local proxy_url_regex='^(https?://)?([^:@]+):([^:@]+)@(\[([0-9a-fA-F:]+)\]|([^:@]+)):[0-9]+/?$'
    
    if ! [[ "$OCI_PROXY_URL" =~ $proxy_url_regex ]]; then
        die "Invalid OCI_PROXY_URL format. Expected formats:
  IPv4: [http://]user:pass@host:port[/]
  IPv6: [http://]user:pass@[host]:port[/]
  URL encoding supported for special characters"
    fi
    
    # Validate port range
    local port
    if [[ "$OCI_PROXY_URL" =~ @\[([^]]+)\]:([0-9]+) ]]; then
        port="${BASH_REMATCH[2]}"  # IPv6 format
    elif [[ "$OCI_PROXY_URL" =~ @([^:]+):([0-9]+) ]]; then
        port="${BASH_REMATCH[2]}"  # IPv4 format
    fi
    
    if [[ -n "$port" ]] && (( port < 1 || port > 65535 )); then
        die "Invalid proxy port: $port (must be between 1-65535)"
    fi
    
    log_success "代理 URL 格式验证通过"
    parse_and_configure_proxy true
}

print_configuration_summary() {
    log_info "配置摘要:"
    echo "  Region: $OCI_REGION"
    echo "  Availability Domain(s): $OCI_AD"
    echo "  Shape: $OCI_SHAPE"
    if [[ "$OCI_SHAPE" == *"Flex" ]]; then
        echo "  OCPUs: $OCI_OCPUS"
        echo "  Memory: ${OCI_MEMORY_IN_GBS}GB"
    fi
    echo "  Instance Name: $INSTANCE_DISPLAY_NAME"
    echo "  Operating System: $OPERATING_SYSTEM $OS_VERSION"
    echo "  Public IP: $ASSIGN_PUBLIC_IP"
    echo "  Boot Volume Size: ${BOOT_VOLUME_SIZE}GB"
    echo "  Recovery Action: $RECOVERY_ACTION"
    echo "  Legacy IMDS Endpoints: $LEGACY_IMDS_ENDPOINTS"
    echo "  Retry Wait Time: ${RETRY_WAIT_TIME}s"
    echo "  Compartment: ${OCI_COMPARTMENT_ID:-$OCI_TENANCY_OCID (tenancy)}"
}

# Validate constants from constants.sh are within acceptable ranges
validate_constants_configuration() {
    log_info "正在验证集中常量..."
    
    # Validate GitHub Actions timeout is within billing boundary
    if [[ "$GITHUB_ACTIONS_BILLING_TIMEOUT" -ge "$GITHUB_ACTIONS_BILLING_BOUNDARY" ]]; then
        die "GITHUB_ACTIONS_BILLING_TIMEOUT ($GITHUB_ACTIONS_BILLING_TIMEOUT) must be less than boundary ($GITHUB_ACTIONS_BILLING_BOUNDARY)"
    fi
    
    # Validate OCI timeout configuration
    if [[ "$OCI_CONNECTION_TIMEOUT_SECONDS" -ge "$OCI_READ_TIMEOUT_SECONDS" ]]; then
        die "OCI_CONNECTION_TIMEOUT_SECONDS ($OCI_CONNECTION_TIMEOUT_SECONDS) should be less than OCI_READ_TIMEOUT_SECONDS ($OCI_READ_TIMEOUT_SECONDS)"
    fi
    
    # Validate retry configuration bounds
    if [[ "$TRANSIENT_ERROR_MAX_RETRIES_DEFAULT" -lt "$TRANSIENT_ERROR_MAX_RETRIES_MIN" ]] || 
       [[ "$TRANSIENT_ERROR_MAX_RETRIES_DEFAULT" -gt "$TRANSIENT_ERROR_MAX_RETRIES_MAX" ]]; then
        die "TRANSIENT_ERROR_MAX_RETRIES_DEFAULT ($TRANSIENT_ERROR_MAX_RETRIES_DEFAULT) must be between $TRANSIENT_ERROR_MAX_RETRIES_MIN-$TRANSIENT_ERROR_MAX_RETRIES_MAX"
    fi
    
    # Validate boot volume size bounds
    if [[ "$BOOT_VOLUME_SIZE_DEFAULT" -lt "$BOOT_VOLUME_SIZE_MIN" ]]; then
        die "BOOT_VOLUME_SIZE_DEFAULT ($BOOT_VOLUME_SIZE_DEFAULT) cannot be less than minimum ($BOOT_VOLUME_SIZE_MIN)"
    fi
    
    log_success "常量配置验证通过"
}

# Main validation function
validate_all_configuration() {
    log_info "开始配置验证..."
    
    # Validate centralized constants first
    validate_constants_configuration
    
    # Run comprehensive validation (includes space checking and OCID validation)
    if ! validate_configuration; then
        die "Comprehensive configuration validation failed"
    fi
    
    validate_oci_configuration
    validate_instance_configuration
    validate_ssh_configuration
    validate_notification_configuration
    validate_proxy_configuration
    
    print_configuration_summary
    
    log_success "所有配置验证通过"
}

# Run validation if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    validate_all_configuration
fi
