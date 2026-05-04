#!/bin/bash

# Production Environment Validation (Preflight Check)
# Validates all configuration and dependencies before instance creation

set -euo pipefail

source "$(dirname "$0")/utils.sh"

# Track validation status
VALIDATION_ERRORS=0

# Display validation header
echo "========================================"
echo "Oracle Instance Creator - Preflight Check"
echo "========================================"
echo ""

# Increment error counter and log error
validation_error() {
    local message="$1"
    ((VALIDATION_ERRORS++))
    log_error "✗ $message"
}

# Log successful validation
validation_success() {
    local message="$1"
    log_success "✓ $message"
}

# Log warning (non-blocking)
validation_warning() {
    local message="$1"
    log_warning "⚠ $message"
}

# Check required environment variable
check_required_var() {
    local var_name="$1"
    local description="$2"
    
    if [[ -z "${!var_name:-}" ]]; then
        validation_error "$description: $var_name is not set"
        return 1
    else
        validation_success "$description: $var_name is configured"
        return 0
    fi
}

# Validate OCID format
validate_ocid_var() {
    local var_name="$1"
    local description="$2"
    local ocid="${!var_name:-}"
    
    if [[ -z "$ocid" ]]; then
        validation_error "$description: $var_name is not set"
        return 1
    fi
    
    if is_valid_ocid "$ocid"; then
        validation_success "$description: $var_name has valid OCID format"
        return 0
    else
        validation_error "$description: $var_name has invalid OCID format: $ocid"
        return 1
    fi
}

log_info "1. 检查必需的 GitHub Secrets..."
echo ""

# OCI Configuration
check_required_var "OCI_USER_OCID" "OCI User OCID"
check_required_var "OCI_KEY_FINGERPRINT" "OCI Key Fingerprint"
check_required_var "OCI_TENANCY_OCID" "OCI Tenancy OCID"
check_required_var "OCI_REGION" "OCI Region"
check_required_var "OCI_PRIVATE_KEY" "OCI Private Key"

# Instance Configuration
# OCI_COMPARTMENT_ID is optional - falls back to tenancy if not specified
check_required_var "OCI_SUBNET_ID" "OCI Subnet ID"
check_required_var "INSTANCE_SSH_PUBLIC_KEY" "SSH Public Key"

# Telegram Configuration
check_required_var "TELEGRAM_TOKEN" "Telegram Bot Token"
check_required_var "TELEGRAM_USER_ID" "Telegram User ID"

echo ""
log_info "2. 验证 OCID 格式..."
echo ""

# Validate OCID formats
validate_ocid_var "OCI_USER_OCID" "User OCID"
validate_ocid_var "OCI_TENANCY_OCID" "Tenancy OCID"
# Validate compartment OCID if provided (falls back to tenancy if not)
if [[ -n "${OCI_COMPARTMENT_ID:-}" ]]; then
    validate_ocid_var "OCI_COMPARTMENT_ID" "Compartment OCID"
fi
validate_ocid_var "OCI_SUBNET_ID" "Subnet OCID"

# Validate image OCID if provided
if [[ -n "${OCI_IMAGE_ID:-}" ]]; then
    validate_ocid_var "OCI_IMAGE_ID" "Image OCID"
else
    validation_warning "Image OCID: Will be auto-detected (OCI_IMAGE_ID not set)"
fi

echo ""
log_info "3. 检查实例配置..."
echo ""

# Instance shape validation
if [[ -n "${OCI_SHAPE:-}" ]]; then
    validation_success "Instance shape: $OCI_SHAPE"
    
    # Check for flexible shape configuration
    if [[ "$OCI_SHAPE" == *".Flex" ]]; then
        if [[ -n "${OCI_OCPUS:-}" && -n "${OCI_MEMORY_IN_GBS:-}" ]]; then
            validation_success "Flexible shape config: ${OCI_OCPUS} OCPUs, ${OCI_MEMORY_IN_GBS} GB RAM"
        else
            validation_error "Flexible shape requires OCI_OCPUS and OCI_MEMORY_IN_GBS"
        fi
    fi
else
    validation_error "Instance shape not specified (OCI_SHAPE)"
fi

# Availability domain validation
if [[ -n "${OCI_AD:-}" ]]; then
    # Check if it's multi-AD format
    if [[ "$OCI_AD" == *","* ]]; then
        IFS=',' read -ra ad_list <<< "$OCI_AD"
        validation_success "Multi-AD configuration: ${#ad_list[@]} domains"
        for ad in "${ad_list[@]}"; do
            if validate_availability_domain "$ad"; then
                log_info "  - $ad: Valid format"
            else
                validation_error "  - $ad: Invalid format"
            fi
        done
    else
        if validate_availability_domain "$OCI_AD"; then
            validation_success "Availability domain: $OCI_AD"
        else
            validation_error "Invalid availability domain format: $OCI_AD"
        fi
    fi
else
    validation_error "Availability domain not specified (OCI_AD)"
fi

# Operating system validation
if [[ -n "${OPERATING_SYSTEM:-}" ]]; then
    validation_success "Operating system: ${OPERATING_SYSTEM} ${OS_VERSION:-}"
else
    validation_error "Operating system not specified (OPERATING_SYSTEM)"
fi

echo ""
log_info "4. 检查系统依赖..."
echo ""

# OCI CLI availability
if command -v oci >/dev/null 2>&1; then
    validation_success "OCI CLI is installed ($(oci --version 2>/dev/null || echo 'version unknown'))"
else
    validation_error "OCI CLI is not available"
fi

# jq availability (optional but recommended)
if command -v jq >/dev/null 2>&1; then
    validation_success "jq is available ($(jq --version 2>/dev/null || echo 'version unknown'))"
else
    validation_warning "jq not available - will use regex fallback for JSON parsing"
fi

# curl availability (for Telegram notifications)
if command -v curl >/dev/null 2>&1; then
    validation_success "curl is available ($(curl --version 2>/dev/null | head -1 || echo 'version unknown'))"
else
    validation_error "curl is not available (required for Telegram notifications)"
fi

echo ""
log_info "5. 验证通知配置..."
echo ""

if [[ -n "${TELEGRAM_TOKEN:-}" && -n "${TELEGRAM_USER_ID:-}" ]]; then
    validation_success "Telegram credentials configured"
    
    # Test Telegram API connectivity silently (no actual notification sent)
    # Use getMe API endpoint for silent connectivity validation
    if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getMe" \
        --connect-timeout 10 --max-time 15 >/dev/null 2>&1; then
        validation_success "Telegram API connectivity verified"
        
        # Only send test notification if explicitly requested via environment variable
        if [[ "${PREFLIGHT_SEND_TEST_NOTIFICATION:-false}" == "true" ]]; then
            test_message="🔧 Oracle Instance Creator preflight check completed at $(date)"
            if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
                -d "chat_id=${TELEGRAM_USER_ID}" \
                -d "text=${test_message}" \
                -d "parse_mode=Markdown" >/dev/null 2>&1; then
                validation_success "Telegram test notification sent"
            else
                validation_warning "Test notification failed but API is accessible"
            fi
        fi
    else
        validation_error "Telegram API connectivity test failed - check token and network"
    fi
else
    validation_warning "Telegram credentials not configured"
fi

echo ""
echo "========================================"
echo "Preflight Check Results"
echo "========================================"

if [[ $VALIDATION_ERRORS -eq 0 ]]; then
    log_success "✓ 所有验证通过！已准备好部署"
    exit 0
else
    log_error "✗ 发现 $VALIDATION_ERRORS 个验证错误"
    log_error "请修复上述问题后再部署"
    exit 1
fi