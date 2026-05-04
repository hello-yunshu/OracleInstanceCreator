#!/bin/bash

# Production Environment Validation (Preflight Check)
# Validates all configuration and dependencies before instance creation

set -euo pipefail

source "$(dirname "$0")/utils.sh"

# Track validation status
VALIDATION_ERRORS=0

# Display validation header
echo "========================================"
echo "Oracle 实例创建器 - 生产环境预检"
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
        validation_error "$description: $var_name 未设置"
        return 1
    else
        validation_success "$description: $var_name 已配置"
        return 0
    fi
}

# Validate OCID format
validate_ocid_var() {
    local var_name="$1"
    local description="$2"
    local ocid="${!var_name:-}"
    
    if [[ -z "$ocid" ]]; then
        validation_error "$description: $var_name 未设置"
        return 1
    fi
    
    if is_valid_ocid "$ocid"; then
        validation_success "$description: $var_name OCID 格式有效"
        return 0
    else
        validation_error "$description: $var_name OCID 格式无效: $ocid"
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
    validate_ocid_var "OCI_IMAGE_ID" "镜像 OCID"
else
    validation_warning "镜像 OCID: 将自动检测（OCI_IMAGE_ID 未设置）"
fi

echo ""
log_info "3. 检查实例配置..."
echo ""

# Instance shape validation
if [[ -n "${OCI_SHAPE:-}" ]]; then
    validation_success "实例形状: $OCI_SHAPE"
    
    if [[ "$OCI_SHAPE" == *".Flex" ]]; then
        if [[ -n "${OCI_OCPUS:-}" && -n "${OCI_MEMORY_IN_GBS:-}" ]]; then
            validation_success "弹性形状配置: ${OCI_OCPUS} OCPU, ${OCI_MEMORY_IN_GBS} GB 内存"
        else
            validation_error "弹性形状需要 OCI_OCPUS 和 OCI_MEMORY_IN_GBS"
        fi
    fi
else
    validation_error "实例形状未指定 (OCI_SHAPE)"
fi

# Availability domain validation
if [[ -n "${OCI_AD:-}" ]]; then
    if [[ "$OCI_AD" == *","* ]]; then
        IFS=',' read -ra ad_list <<< "$OCI_AD"
        validation_success "多 AD 配置: ${#ad_list[@]} 个域"
        for ad in "${ad_list[@]}"; do
            if validate_availability_domain "$ad"; then
                log_info "  - $ad: 格式有效"
            else
                validation_error "  - $ad: 格式无效"
            fi
        done
    else
        if validate_availability_domain "$OCI_AD"; then
            validation_success "可用性域: $OCI_AD"
        else
            validation_error "可用性域格式无效: $OCI_AD"
        fi
    fi
else
    validation_error "可用性域未指定 (OCI_AD)"
fi

# Operating system validation
if [[ -n "${OPERATING_SYSTEM:-}" ]]; then
    validation_success "操作系统: ${OPERATING_SYSTEM} ${OS_VERSION:-}"
else
    validation_error "操作系统未指定 (OPERATING_SYSTEM)"
fi

echo ""
log_info "4. 检查系统依赖..."
echo ""

# OCI CLI availability
if command -v oci >/dev/null 2>&1; then
    validation_success "OCI CLI 已安装 ($(oci --version 2>/dev/null || echo '版本未知'))"
else
    validation_error "OCI CLI 不可用"
fi

if command -v jq >/dev/null 2>&1; then
    validation_success "jq 可用 ($(jq --version 2>/dev/null || echo '版本未知'))"
else
    validation_warning "jq 不可用 - 将使用正则回退方式解析 JSON"
fi

if command -v curl >/dev/null 2>&1; then
    validation_success "curl 可用 ($(curl --version 2>/dev/null | head -1 || echo '版本未知'))"
else
    validation_error "curl 不可用（Telegram 通知所需）"
fi

echo ""
log_info "5. 验证通知配置..."
echo ""

if [[ -n "${TELEGRAM_TOKEN:-}" && -n "${TELEGRAM_USER_ID:-}" ]]; then
    validation_success "Telegram 凭据已配置"
    
    if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getMe" \
        --connect-timeout 10 --max-time 15 >/dev/null 2>&1; then
        validation_success "Telegram API 连接验证通过"
        
        if [[ "${PREFLIGHT_SEND_TEST_NOTIFICATION:-false}" == "true" ]]; then
            test_message="🔧 Oracle 实例创建器预检完成 $(date)"
            if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
                -d "chat_id=${TELEGRAM_USER_ID}" \
                -d "text=${test_message}" \
                -d "parse_mode=Markdown" >/dev/null 2>&1; then
                validation_success "Telegram 测试通知已发送"
            else
                validation_warning "测试通知发送失败但 API 可访问"
            fi
        fi
    else
        validation_error "Telegram API 连接测试失败 - 请检查令牌和网络"
    fi
else
    validation_warning "Telegram 凭据未配置"
fi

echo ""
echo "========================================"
echo "预检结果"
echo "========================================"

if [[ $VALIDATION_ERRORS -eq 0 ]]; then
    log_success "✓ 所有验证通过！已准备好部署"
    exit 0
else
    log_error "✗ 发现 $VALIDATION_ERRORS 个验证错误"
    log_error "请修复上述问题后再部署"
    exit 1
fi