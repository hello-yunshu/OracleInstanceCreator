#!/bin/bash

# Oracle Instance Creator 工具函数
# Common functions for logging, error handling, and validation

set -euo pipefail

# Source centralized constants
source "$(dirname "${BASH_SOURCE[0]:-$0}")/constants.sh"

# Colors for logging (if terminal supports it)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    RESET=""
fi

# 带颜色的日志函数 for clear output and optional JSON format
# Set LOG_FORMAT=json to enable structured logging

log_json() {
    local level="$1"
    local message="$2"
    local context="${3:-}"
    
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')
    
    if [[ -n "$context" ]]; then
        echo "{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"message\":\"$message\",\"context\":$context}" >&2
    else
        echo "{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"message\":\"$message\"}" >&2
    fi
}

log_info() {
    if [[ "${LOG_FORMAT:-}" == "json" ]]; then
        log_json "info" "$*"
    else
        echo "${BLUE}[INFO]${RESET} $*" >&2
    fi
}

log_success() {
    if [[ "${LOG_FORMAT:-}" == "json" ]]; then
        log_json "success" "$*"
    else
        echo "${GREEN}[SUCCESS]${RESET} $*" >&2
    fi
}

log_warning() {
    if [[ "${LOG_FORMAT:-}" == "json" ]]; then
        log_json "warning" "$*"
    else
        echo "${YELLOW}[WARNING]${RESET} $*" >&2
    fi
}

log_error() {
    if [[ "${LOG_FORMAT:-}" == "json" ]]; then
        log_json "error" "$*"
    else
        echo "${RED}[ERROR]${RESET} $*" >&2
    fi
}

log_debug() {
    # Use INTERNAL_DEBUG for internal script logging
    if [[ "${INTERNAL_DEBUG:-}" == "true" ]]; then
        if [[ "${LOG_FORMAT:-}" == "json" ]]; then
            log_json "debug" "$*"
        else
            echo "${BOLD}[DEBUG]${RESET} $*" >&2
        fi
    fi
}

# Enhanced logging with context (useful for structured logging)
# Parameters: level, message, optional JSON context object
log_with_context() {
    local level="$1"
    local message="$2"
    local context="${3:-}"
    
    if [[ "${LOG_FORMAT:-}" == "json" ]]; then
        log_json "$level" "$message" "$context"
    else
        # For text format, just log normally (context ignored)
        case "$level" in
            "info") log_info "$message" ;;
            "success") log_success "$message" ;;
            "warning") log_warning "$message" ;;
            "error") log_error "$message" ;;
            "debug") log_debug "$message" ;;
            *) echo "[$level] $message" >&2 ;;
        esac
    fi
}

# 性能监控计时函数
# Note: Using bash 4+ associative arrays if available, otherwise simple variables
if [[ -n "${BASH_VERSION:-}" ]] && [[ ${BASH_VERSION%%.*} -ge 4 ]]; then
    declare -A TIMER_START_TIMES
else
    # Fallback for older bash versions - use simple timer variable
    TIMER_START_TIME=""
fi

start_timer() {
    local timer_name="$1"
    if [[ -n "${BASH_VERSION:-}" ]] && [[ ${BASH_VERSION%%.*} -ge 4 ]]; then
        TIMER_START_TIMES[$timer_name]=$(date +%s.%N)
    else
        # Fallback - only support one timer at a time
        TIMER_START_TIME=$(date +%s.%N)
    fi
    log_debug "Started timer: $timer_name"
}

log_elapsed() {
    local timer_name="$1"
    local start_time=""
    
    if [[ -n "${BASH_VERSION:-}" ]] && [[ ${BASH_VERSION%%.*} -ge 4 ]]; then
        start_time="${TIMER_START_TIMES[$timer_name]:-}"
        if [[ -n "$start_time" ]]; then
            unset "TIMER_START_TIMES[$timer_name]"
        fi
    else
        # Fallback - use single timer
        start_time="$TIMER_START_TIME"
        TIMER_START_TIME=""
    fi
    
    if [[ -n "$start_time" ]]; then
        # shellcheck disable=SC2155  # Date commands rarely fail
        local end_time=$(date +%s.%N)
        # shellcheck disable=SC2155  # Mathematical calculation with fallback
        local elapsed=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
        log_info "Timer '$timer_name' elapsed: ${elapsed}s"
    else
        log_warning "Timer '$timer_name' was not started"
    fi
}

# 错误处理
die() {
    local message="$1"
    local exit_code="${2:-1}"  # Default to general error
    log_error "$message"
    exit "$exit_code"
}

# Standardized error handling functions using OCI constants
die_config_error() {
    die "$1" "$OCI_EXIT_CONFIG_ERROR"
}

die_capacity_error() {
    die "$1" "$OCI_EXIT_CAPACITY_ERROR"
}

die_timeout_error() {
    die "$1" "$TIMEOUT_EXIT_CODE"
}

# Return standardized exit codes based on error type
handle_error_by_type() {
    local error_message="$1"
    local error_type
    error_type=$(get_error_type "$error_message")
    
    case "$error_type" in
        "USER_LIMIT_REACHED")
            return "$OCI_EXIT_USER_LIMIT_ERROR"
            ;;
        "ORACLE_CAPACITY_UNAVAILABLE"|"CAPACITY"|"LIMIT_EXCEEDED")
            return "$OCI_EXIT_CAPACITY_ERROR"
            ;;
        "RATE_LIMIT")
            return "$OCI_EXIT_RATE_LIMIT_ERROR"
            ;;
        "AUTH"|"CONFIG"|"DUPLICATE")
            return "$OCI_EXIT_CONFIG_ERROR"
            ;;
        "NETWORK"|"INTERNAL_ERROR")
            return "$OCI_EXIT_GENERAL_ERROR"
            ;;
        *)
            return "$OCI_EXIT_GENERAL_ERROR"
            ;;
    esac
}

# Environment variable validation
require_env_var() {
    local var_name="$1"
    local var_value="${!var_name:-}"
    
    if [[ -z "$var_value" ]]; then
        die "Required environment variable $var_name is not set"
    fi
}

# Validate environment variable with default
get_env_var_or_default() {
    local var_name="$1"
    local default_value="$2"
    local var_value="${!var_name:-$default_value}"
    
    echo "$var_value"
}

# OCI CLI command wrapper for data extraction (no debug pollution)
oci_cmd_data() {
    local cmd=("$@")
    local output
    local status
    
    log_debug "Executing OCI data command: oci ${cmd[*]}"
    
    set +e
    output=$(oci --no-retry --connection-timeout $OCI_CONNECTION_TIMEOUT_SECONDS --read-timeout $OCI_READ_TIMEOUT_SECONDS "${cmd[@]}" 2>&1)
    status=$?
    set -e
    
    if [[ $status -ne 0 ]]; then
        log_error "OCI data command failed with status $status"
        log_error "Command: ${cmd[*]}"
        log_error "Output: $output"
        return $status
    fi
    
    echo "$output"
}

# Redact sensitive parameters from command arrays for secure logging
#
# This function processes OCI CLI command arguments and masks sensitive
# information before logging. Essential for debug mode security to prevent
# credential exposure in logs.
#
# Parameters:
#   cmd   Array of command arguments to process
# Returns:
#   Space-separated string with sensitive data redacted
#
# Redaction Rules:
# - OCIDs: Show first and last 4 characters (ocid1234...5678)
# - SSH keys: Replace with [SSH_KEY_REDACTED]
# - Private keys: Replace with [PRIVATE_KEY_REDACTED]
# - Auth parameters: Replace values with [REDACTED]
#
# This prevents credential leakage while maintaining debug visibility.
redact_sensitive_params() {
    local cmd=("$@")
    local redacted_cmd=()
    local i=0
    
    while [[ $i -lt ${#cmd[@]} ]]; do
        local param="${cmd[$i]}"
        
        # Check if this is a parameter that might contain sensitive data
        if [[ "$param" == "--auth" || "$param" == "--private-key" || "$param" == "--key-file" ]]; then
            redacted_cmd+=("$param")
            ((i++))
            if [[ $i -lt ${#cmd[@]} ]]; then
                redacted_cmd+=("[REDACTED]")
                ((i++))
            fi
        elif [[ "$param" =~ ^ocid1\. ]]; then
            # Redact OCIDs by showing only first and last 4 characters
            local ocid_length=${#param}
            if [[ $ocid_length -gt 8 ]]; then
                local redacted_ocid="${param:0:4}...${param: -4}"
                redacted_cmd+=("$redacted_ocid")
            else
                redacted_cmd+=("[REDACTED]")
            fi
            ((i++))
        elif [[ "$param" =~ (BEGIN|END).*PRIVATE.*KEY ]]; then
            # Redact private key content
            redacted_cmd+=("[PRIVATE_KEY_REDACTED]")
            ((i++))
        elif [[ "$param" =~ .*@.*:.* ]]; then
            # Mask proxy URLs or credentials in the format user:pass@host:port
            local masked_param
            masked_param=$(mask_credentials "$param")
            redacted_cmd+=("$masked_param")
            ((i++))
        elif [[ "$param" =~ --metadata.*ssh-authorized-keys || "$param" =~ ssh-rsa || "$param" =~ ssh-ed25519 ]]; then
            # Redact SSH keys
            redacted_cmd+=("[SSH_KEY_REDACTED]")
            ((i++))
        else
            redacted_cmd+=("$param")
            ((i++))
        fi
    done
    
    echo "${redacted_cmd[*]}"
}

# OCI CLI command wrapper with debug support (for troubleshooting)
oci_cmd_debug() {
    local cmd=("$@")
    local output
    local status
    local oci_args=()
    
    # Add debug flag if OCI CLI debug is specifically enabled
    # This controls verbose Oracle API request/response logging
    if [[ "${OCI_CLI_DEBUG:-}" == "true" ]]; then
        oci_args+=("--debug")
    fi
    
    # Add no-retry flag for performance optimization
    # Disables exponential backoff retry logic since we handle errors gracefully
    oci_args+=("--no-retry")
    
    # Add timeout flags for faster failure on network issues
    # Connection timeout: 5s (down from 10s default)
    # Read timeout: 15s (down from 60s default) 
    oci_args+=("--connection-timeout" "${OCI_CONNECTION_TIMEOUT_SECONDS:-5}")
    oci_args+=("--read-timeout" "${OCI_READ_TIMEOUT_SECONDS:-15}")
    
    # Create redacted command for secure logging
    local redacted_cmd_str
    redacted_cmd_str=$(redact_sensitive_params "${cmd[@]}")
    log_debug "Executing OCI debug command: oci ${oci_args[*]} $redacted_cmd_str"
    
    set +e
    output=$(oci "${oci_args[@]}" "${cmd[@]}" 2>&1)
    status=$?
    set -e
    
    if [[ $status -ne 0 ]]; then
        log_error "OCI 调试命令失败，状态码 $status"
        log_error "Command: ${cmd[*]}"
        log_error "Output: $output"
    fi
    
    echo "$output"
    return $status
}

# Intelligent OCI CLI command wrapper - uses appropriate mode
oci_cmd() {
    local cmd=("$@")
    
    # Check if this is a data extraction command (contains --query or --raw-output)
    local is_data_query=false
    for arg in "${cmd[@]}"; do
        if [[ "$arg" == "--query" || "$arg" == "--raw-output" ]]; then
            is_data_query=true
            break
        fi
    done
    
    # Use data mode for queries to avoid debug pollution, debug mode for actions
    if [[ "$is_data_query" == "true" ]]; then
        oci_cmd_data "${cmd[@]}"
    else
        oci_cmd_debug "${cmd[@]}"
    fi
}

# Check if OCI CLI is available
check_oci_cli() {
    if ! command -v oci >/dev/null 2>&1; then
        die "OCI CLI is not installed or not in PATH"
    fi
    
    log_debug "OCI CLI found: $(which oci)"
}

# Check if jq is available for JSON parsing
has_jq() {
    command -v jq >/dev/null 2>&1
}

# Extract and validate instance OCID from OCI CLI JSON output
#
# Uses jq for robust JSON parsing when available, falls back to regex.
# Validates the extracted OCID format before returning to prevent downstream errors.
#
# Parameters:
#   $1: output - JSON output from OCI CLI command
# Returns:
#   0: Valid OCID found and printed to stdout
#   1: No valid OCID found (prints empty string)
extract_instance_ocid() {
    local output="$1"
    local instance_id=""
    
    # Try jq first for robust JSON parsing
    if has_jq; then
        log_debug "Using jq for JSON parsing to extract instance OCID"
        instance_id=$(echo "$output" | jq -r '.data.id // empty' 2>/dev/null)
        
        # If jq didn't find the OCID, try alternative JSON paths
        if [[ -z "$instance_id" ]]; then
            instance_id=$(echo "$output" | jq -r '.id // .data."instance-id" // empty' 2>/dev/null)
        fi
    fi
    
    # Fallback to regex if jq is not available or didn't find the OCID
    if [[ -z "$instance_id" ]]; then
        log_debug "Using regex fallback to extract instance OCID"
        instance_id=$(echo "$output" | grep -o 'ocid1\.instance[^"]*' | head -1)
    fi
    
    # Validate the extracted OCID format before returning
    if [[ -n "$instance_id" ]]; then
        if is_valid_ocid "$instance_id"; then
            log_debug "Successfully extracted and validated instance OCID: ${instance_id:0:12}...${instance_id: -8}"
            echo "$instance_id"
        else
            log_warning "Extracted string '$instance_id' does not pass OCID format validation"
            echo ""
            return 1
        fi
    else
        log_debug "No instance OCID found in output"
        echo ""
    fi
}

# Classify OCI CLI error output into actionable categories
#
# ALGORITHM: Hierarchical Error Pattern Recognition and Classification
#
# This function implements a sophisticated error analysis system using pattern
# matching to categorize Oracle Cloud errors into actionable response strategies.
# The classification directly drives multi-AD retry logic and workflow outcomes.
#
# ALGORITHM DESIGN PRINCIPLES:
# 1. Specificity Priority: Most specific patterns checked first to prevent misclassification
# 2. Case-Insensitive Matching: Handles Oracle's inconsistent error formatting  
# 3. Multiple Pattern Support: Each category matches various Oracle error formats
# 4. Early Termination: Returns immediately on first match for performance
# 5. Defensive Default: Unknown errors classified as UNKNOWN rather than assumption
#
# CLASSIFICATION HIERARCHY (in order of evaluation):
# ```
# LIMIT_EXCEEDED     → Special case requiring instance verification
#   ↓
# RATE_LIMIT         → Throttling, treat as capacity constraint
#   ↓  
# CAPACITY           → Expected free tier limitation
#   ↓
# INTERNAL_ERROR     → Temporary Oracle service issues
#   ↓
# DUPLICATE          → Instance exists (success condition)
#   ↓
# AUTH               → Credential/permission failures (terminal)
#   ↓
# CONFIG             → Parameter/resource errors (terminal)
#   ↓
# NETWORK            → Connectivity issues (retriable)
#   ↓
# UNKNOWN            → Unrecognized patterns (terminal, requires investigation)
# ```
#
# PATTERN MATCHING STRATEGY:
# - Uses grep -qi for case-insensitive, efficient string matching
# - Multiple patterns per category (OR logic within categories)
# - JSON-aware patterns: Handles both text and JSON error responses
# - HTTP status codes: Recognizes 429, 502, etc. for network issues
#
# PERFORMANCE CONSIDERATIONS:
# - Early termination on first match reduces evaluation overhead
# - Simple grep-based matching faster than complex regex
# - Debug logging only in debug mode to minimize I/O
# - Single-pass evaluation through hierarchical checks
#
# Parameters:
#   error_output  Raw error text from OCI CLI
# Returns:
#   Error classification string
#
# Classifications:
# - LIMIT_EXCEEDED: Oracle limit errors (special verification needed)
# - RATE_LIMIT: Too many requests, throttling
# - CAPACITY: No host capacity, service limits (expected for free tier)
# - INTERNAL_ERROR: Gateway errors, temporary Oracle issues
# - DUPLICATE: Instance already exists (success condition)
# - AUTH: Authentication/authorization failures
# - CONFIG: Invalid parameters, missing resources
# - NETWORK: Connectivity, timeout issues  
# - UNKNOWN: Unrecognized error patterns
#
# Pattern ordering is critical - more specific patterns checked first.
get_error_type() {
    local error_output="$1"
    
    # Check for user limit reached errors first (most specific - E2/A1 instance limits)
    if echo "$error_output" | grep -qi "limitexceeded.*core.*count\|standard.*micro.*core.*count\|\"code\".*\"LimitExceeded\".*core.*count"; then
        log_debug "Detected USER_LIMIT_REACHED error pattern in: $error_output"
        echo "USER_LIMIT_REACHED"
    # Check for Oracle capacity unavailable errors (specific Oracle capacity constraints)
    elif echo "$error_output" | grep -qi "out of host capacity\|insufficient.*host.*capacity\|host.*capacity.*unavailable\|\"code\".*\"InternalError\".*host.*capacity"; then
        log_debug "Detected ORACLE_CAPACITY_UNAVAILABLE error pattern in: $error_output"
        echo "ORACLE_CAPACITY_UNAVAILABLE"
    # Check for general limit exceeded errors (fallback for other limit types)
    elif echo "$error_output" | grep -qi "limitexceeded\|\"code\".*\"LimitExceeded\""; then
        log_debug "Detected LIMIT_EXCEEDED error pattern in: $error_output"
        echo "LIMIT_EXCEEDED"
    # Check for rate limiting (treat as capacity issue)
    elif echo "$error_output" | grep -qi "too.*many.*requests\|rate.*limit\|throttle\|429\|TooManyRequests\|\"code\".*\"TooManyRequests\"\|\"status\".*429\|'status':.*429\|'code':.*'TooManyRequests'"; then
        log_debug "Detected RATE_LIMIT error pattern in: $error_output"
        echo "RATE_LIMIT"
    # Check for capacity-related errors (more general patterns)
    elif echo "$error_output" | grep -qi "capacity\|host capacity\|out of capacity\|service limit\|quota exceeded\|resource unavailable\|insufficient capacity"; then
        log_debug "Detected CAPACITY error pattern in: $error_output"
        echo "CAPACITY"
    # Check for internal/gateway errors (retry-able)
    elif echo "$error_output" | grep -qi "internal.*error\|internalerror\|\"code\".*\"InternalError\"\|bad.*gateway\|502\|\"status\".*502"; then
        log_debug "Detected INTERNAL/GATEWAY error pattern in: $error_output"
        echo "INTERNAL_ERROR"
    # Check for duplicate instances
    elif echo "$error_output" | grep -qi "display name already exists\|instance.*already exists\|duplicate.*name"; then
        log_debug "Detected DUPLICATE error pattern in: $error_output"
        echo "DUPLICATE"
    # Check for authentication/authorization errors
    elif echo "$error_output" | grep -qi "authentication\|authorization\|unauthorized\|forbidden\|401\|403"; then
        log_debug "Detected AUTH error pattern in: $error_output"
        echo "AUTH"
    # Check for network/connectivity errors
    elif echo "$error_output" | grep -qi "network\|timeout\|connection\|unreachable\|dns"; then
        log_debug "Detected NETWORK error pattern in: $error_output"
        echo "NETWORK"
    # Check for configuration errors
    elif echo "$error_output" | grep -qi "not found\|invalid.*id\|does not exist\|bad.*request\|400\|parameter"; then
        log_debug "Detected CONFIG error pattern in: $error_output"
        echo "CONFIG"
    else
        log_debug "No specific error pattern matched in: $error_output"
        echo "UNKNOWN"
    fi
}

# Calculate exponential backoff delay for retry attempts
# Used for transient error retry scenarios where we need smart delay calculation
#
# Parameters:
#   attempt     Current attempt number (1-based)
#   base_delay  Base delay in seconds (default: 5)
#   max_delay   Maximum delay cap in seconds (default: 40)
# Returns:
#   Calculated delay in seconds
calculate_exponential_backoff() {
    local attempt="$1"
    local base_delay="${2:-5}"
    local max_delay="${3:-40}"
    
    # Calculate 2^(attempt-1) * base_delay
    local delay=$((base_delay * (2 ** (attempt - 1))))
    
    # Cap at maximum delay
    if [[ $delay -gt $max_delay ]]; then
        delay=$max_delay
    fi
    
    echo "$delay"
}

# Retry function with exponential backoff
retry_with_backoff() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local cmd=("$@")
    
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt/$max_attempts: ${cmd[*]}"
        
        if "${cmd[@]}"; then
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Command failed, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        fi
        
        ((attempt++))
    done
    
    log_error "命令在 $max_attempts 次尝试后失败"
    return 1
}

# 错误处理 standards for all scripts
# 返回码约定：
# 0 = 成功/继续
# 1 = 一般错误/失败
# 2 = 容量/速率限制（预期行为，稍后重试）
# 3 = 配置错误（需要修复）
# 4 = 网络/连接错误（可能自行恢复）
# 124 = 超时（GNU timeout 标准）

# 退出码常量已集中定义在 constants.sh 中

# 常量已集中定义在 constants.sh 中 - 在 init_script() 中加载

# Wait for result file with polling and timeout
wait_for_result_file() {
    local file_path="$1"
    local timeout="${2:-$RESULT_FILE_WAIT_TIMEOUT}"
    local elapsed=0
    local poll_interval="$RESULT_FILE_POLL_INTERVAL"
    
    log_debug "Waiting for result file: $file_path (timeout: ${timeout}s)"
    
    while [[ $elapsed -lt $timeout ]]; do
        if [[ -f "$file_path" ]]; then
            # File exists, check if it has content
            local file_content
            if file_content=$(cat "$file_path" 2>/dev/null) && [[ -n "$file_content" ]]; then
                # Validate content is a valid exit code (numeric)
                if [[ "$file_content" =~ ^[0-9]+$ ]]; then
                    log_debug "Result file found with valid exit code '$file_content' after ${elapsed}s"
                    return 0
                else
                    log_debug "Result file found but content is not numeric: '$file_content'"
                fi
            fi
        fi
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done
    
    # Final check - log file state for debugging
    if [[ -f "$file_path" ]]; then
        local file_content
        file_content=$(cat "$file_path" 2>/dev/null || echo "<read failed>")
        log_warning "Result file exists but failed validation within ${timeout}s timeout: $file_path (content: '$file_content')"
    else
        log_warning "Result file not found within ${timeout}s timeout: $file_path"
    fi
    return 1
}

# Mask credentials in proxy URLs for safe logging
mask_credentials() {
    local input="$1"
    
    # Pattern matches: user:pass@host or user:pass@[host]
    # Replace credentials with [MASKED]:[MASKED]
    echo "$input" | sed -E 's|([^/@]+):([^/@]+)@|[MASKED]:[MASKED]@|g'
}

# Secure debug logging wrapper that automatically redacts sensitive information
log_debug_secure() {
    local message="$1"
    
    # Apply credential masking to the entire message
    local masked_message
    masked_message=$(mask_credentials "$message")
    
    # Additional redaction patterns for OCIDs (show only first/last 4 chars)
    masked_message=$(echo "$masked_message" | sed -E 's/ocid1\.[^.]+\.[^.]+\.[^.]+\.([^.]{4})[^.]*([^.]{4})/ocid1.***.\1...\2/g')
    
    # Redact SSH keys
    masked_message=$(echo "$masked_message" | sed -E 's/ssh-(rsa|ed25519|dss) [A-Za-z0-9+/=]+ .*/[SSH_KEY_REDACTED]/g')
    
    # Redact private key content
    masked_message=$(echo "$masked_message" | sed -E 's/-----BEGIN [A-Z ]*PRIVATE KEY-----.*/[PRIVATE_KEY_REDACTED]/g')
    
    # Redact Telegram tokens
    masked_message=$(echo "$masked_message" | sed -E 's/[0-9]{8,10}:[A-Za-z0-9_-]{35}/[TELEGRAM_TOKEN_REDACTED]/g')
    
    log_debug "$masked_message"
}

# Get appropriate exit code for error type
get_exit_code_for_error_type() {
    local error_type="$1"
    
    case "$error_type" in
        "CAPACITY"|"LIMIT_EXCEEDED")
            echo $OCI_EXIT_CAPACITY_ERROR
            ;;
        "RATE_LIMIT")
            echo $OCI_EXIT_RATE_LIMIT_ERROR
            ;;
        "AUTH"|"CONFIG"|"DUPLICATE")
            echo $OCI_EXIT_CONFIG_ERROR
            ;;
        "NETWORK"|"INTERNAL_ERROR")
            echo $OCI_EXIT_NETWORK_ERROR
            ;;
        "TIMEOUT")
            echo $OCI_EXIT_TIMEOUT
            ;;
        *)
            echo $OCI_EXIT_GENERAL_ERROR
            ;;
    esac
}

# URL encoding/decoding functions for proxy credentials
url_encode() {
    local string="$1"
    local encoded=""
    local i
    
    for ((i = 0; i < ${#string}; i++)); do
        local char="${string:$i:1}"
        case "$char" in
            [a-zA-Z0-9._~-]) encoded+="$char" ;;
            *) 
                # Convert character to hex
                printf -v encoded "%s%%%02X" "$encoded" "'$char"
                ;;
        esac
    done
    
    echo "$encoded"
}

url_decode() {
    local string="$1"
    printf '%b\n' "${string//%/\\x}"
}

# Parse and configure proxy from OCI_PROXY_URL environment variable
# Supports both IPv4 and IPv6 addresses with URL encoding
parse_and_configure_proxy() {
    local validate_only="${1:-false}"
    
    if [[ -z "${OCI_PROXY_URL:-}" ]]; then
        log_debug "No OCI_PROXY_URL provided - proxy will not be used"
        return 0
    fi
    
    # Check if proxy is already configured (avoid redundant setup)
    if [[ "${validate_only}" == "false" ]] && [[ -n "${HTTP_PROXY:-}" ]]; then
        log_debug "Proxy already configured - skipping setup"
        return 0
    fi
    
    log_info "Processing OCI_PROXY_URL configuration..."
    
    local proxy_user proxy_pass proxy_host proxy_port is_ipv6=false
    
    # Check for IPv6 format first (contains brackets)
    if [[ "$OCI_PROXY_URL" == *"@["*"]:"* ]]; then
        log_debug "Detected IPv6 proxy format"
        is_ipv6=true
        # Extract IPv6 components manually
        local user_pass="${OCI_PROXY_URL%@\[*}"
        local rest="${OCI_PROXY_URL#*@\[}"
        proxy_host="${rest%\]:*}"
        proxy_port="${rest##*\]:}"
        proxy_user="${user_pass%:*}"
        proxy_pass="${user_pass##*:}"
        
        # Validate IPv6 format
        if [[ -z "$proxy_user" || -z "$proxy_pass" || -z "$proxy_host" || ! "$proxy_port" =~ ^[0-9]+$ ]]; then
            log_error "Invalid IPv6 proxy format. Expected: USER:PASS@[HOST]:PORT"
            log_error "Example: myuser:mypass@[::1]:3128"
            die "Invalid IPv6 proxy configuration"
        fi
    else
        # Try IPv4 format
        local ipv4_pattern="^([^:]+):([^@]+)@([^:]+):([0-9]+)$"
        if [[ "$OCI_PROXY_URL" =~ $ipv4_pattern ]]; then
            proxy_user="${BASH_REMATCH[1]}"
            proxy_pass="${BASH_REMATCH[2]}"
            proxy_host="${BASH_REMATCH[3]}"
            proxy_port="${BASH_REMATCH[4]}"
            log_debug "Detected IPv4 proxy format"
        else
            log_error "Invalid OCI_PROXY_URL format. Expected formats:"
            log_error "  IPv4: USER:PASS@HOST:PORT"
            log_error "  IPv6: USER:PASS@[HOST]:PORT"
            log_error "Examples:"
            log_error "  myuser:mypass@proxy.example.com:3128"
            log_error "  myuser:mypass@192.168.1.100:3128"
            log_error "  myuser:mypass@[::1]:3128"
            die "Invalid proxy configuration - check OCI_PROXY_URL format"
        fi
    fi
    
    # Decode URL-encoded credentials
    proxy_user=$(url_decode "$proxy_user")
    proxy_pass=$(url_decode "$proxy_pass")
    
    # Validate components
    if [[ -z "$proxy_user" || -z "$proxy_pass" ]]; then
        die "Proxy user and password cannot be empty"
    fi
    
    if [[ -z "$proxy_host" ]]; then
        die "Proxy host cannot be empty"
    fi
    
    # Validate port range
    if [[ $proxy_port -lt 1 || $proxy_port -gt 65535 ]]; then
        die "Proxy port must be between 1 and 65535, got: $proxy_port"
    fi
    
    # If validation only, we're done
    if [[ "${validate_only}" == "true" ]]; then
        log_success "Proxy configuration validation passed: ${proxy_host}:${proxy_port}"
        return 0
    fi
    
    # Re-encode credentials to handle special characters in final URL
    # shellcheck disable=SC2155  # url_encode function rarely fails
    local encoded_user=$(url_encode "$proxy_user")
    # shellcheck disable=SC2155  # url_encode function rarely fails  
    local encoded_pass=$(url_encode "$proxy_pass")
    
    # Construct proxy URL with authentication and proper IPv6 bracketing
    local proxy_url
    if [[ "$is_ipv6" == "true" ]]; then
        proxy_url="http://${encoded_user}:${encoded_pass}@[${proxy_host}]:${proxy_port}/"
        log_debug "Constructed IPv6 proxy URL with brackets: [${proxy_host}]:${proxy_port}"
    else
        proxy_url="http://${encoded_user}:${encoded_pass}@${proxy_host}:${proxy_port}/"
        log_debug "Constructed IPv4 proxy URL: ${proxy_host}:${proxy_port}"
    fi
    
    # Set both uppercase and lowercase versions for maximum compatibility
    export HTTP_PROXY="${proxy_url}"
    export HTTPS_PROXY="${proxy_url}"
    export http_proxy="${proxy_url}"
    export https_proxy="${proxy_url}"
    
    log_debug "Proxy configured for ${proxy_host}:${proxy_port} with authentication (credentials not logged)"
    log_success "Proxy configuration applied successfully"
}

# Validate OCID format
is_valid_ocid() {
    local ocid="$1"
    if [[ "$ocid" =~ ^ocid1\.[a-z0-9]+\.[a-z0-9-]*\.[a-z0-9-]*\..+ ]]; then
        return 0
    else
        return 1
    fi
}

# Validate configuration values don't contain spaces
validate_no_spaces() {
    local var_name="$1"
    local var_value="$2"
    
    if [[ "$var_value" =~ [[:space:]] ]]; then
        log_error "Configuration variable $var_name contains spaces: '$var_value'"
        log_error "Spaces in configuration values can cause command parsing issues"
        return 1
    fi
    return 0
}

# Validate boot volume size constraints
validate_boot_volume_size() {
    local size="$1"
    
    # Check if it's a number
    if ! [[ "$size" =~ ^[0-9]+$ ]]; then
        log_error "引导卷大小必须是数字: $size"
        return 1
    fi
    
    # Check minimum size (Oracle requirement)
    if [[ "$size" -lt 50 ]]; then
        log_error "引导卷大小至少为 50GB: $size"
        return 1
    fi
    
    # Check reasonable maximum (10TB)
    if [[ "$size" -gt 10000 ]]; then
        log_warning "引导卷大小似乎过大: ${size}GB"
    fi
    
    return 0
}

find_boot_volume_for_instance() {
    local comp_id="$1"
    local instance_id="$2"
    
    local attachment_id
    attachment_id=$(oci_cmd compute boot-volume-attachment list \
        --compartment-id "$comp_id" \
        --instance-id "$instance_id" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null)
    
    if [[ -z "$attachment_id" || "$attachment_id" == "null" ]]; then
        log_debug "No boot volume attachment found for instance: $instance_id"
        echo ""
        return 1
    fi
    
    local boot_volume_id
    boot_volume_id=$(oci_cmd compute boot-volume-attachment get \
        --boot-volume-attachment-id "$attachment_id" \
        --query 'data."boot-volume-id"' \
        --raw-output 2>/dev/null)
    
    if [[ -z "$boot_volume_id" || "$boot_volume_id" == "null" ]]; then
        log_debug "Could not retrieve boot volume ID from attachment: $attachment_id"
        echo ""
        return 1
    fi
    
    echo "$boot_volume_id"
    return 0
}

detach_boot_volume_if_attached() {
    local comp_id="$1"
    local boot_volume_id="$2"
    
    if [[ -z "$boot_volume_id" ]]; then
        log_warning "未提供用于分离检查的引导卷 ID"
        return 1
    fi
    
    local attachment_id
    attachment_id=$(oci_cmd compute boot-volume-attachment list \
        --compartment-id "$comp_id" \
        --boot-volume-id "$boot_volume_id" \
        --lifecycle-state "ATTACHED" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null)
    
    if [[ -z "$attachment_id" || "$attachment_id" == "null" ]]; then
        log_info "引导卷 $boot_volume_id 当前未附加 - 可以使用"
        return 0
    fi
    
    local attached_instance_id
    attached_instance_id=$(oci_cmd compute boot-volume-attachment get \
        --boot-volume-attachment-id "$attachment_id" \
        --query 'data."instance-id"' \
        --raw-output 2>/dev/null)
    
    log_info "引导卷 $boot_volume_id 已附加到实例: ${attached_instance_id:-未知}"
    log_info "正在分离引导卷: $attachment_id"
    
    local detach_output
    detach_output=$(oci_cmd compute boot-volume-attachment detach \
        --boot-volume-attachment-id "$attachment_id" \
        --force 2>&1)
    local detach_status=$?
    
    if [[ $detach_status -ne 0 ]]; then
        log_error "分离引导卷失败: $detach_output"
        return 1
    fi
    
    log_info "等待引导卷分离完成..."
    local max_wait=120
    local wait_interval=10
    local elapsed=0
    
    while [[ $elapsed -lt $max_wait ]]; do
        local state
        state=$(oci_cmd compute boot-volume-attachment get \
            --boot-volume-attachment-id "$attachment_id" \
            --query 'data."lifecycle-state"' \
            --raw-output 2>/dev/null)
        
        if [[ -z "$state" || "$state" == "DETACHED" || "$state" == "null" ]]; then
            log_info "引导卷在 ${elapsed}s 后成功分离"
            return 0
        fi
        
        log_debug "Boot volume state: $state, waiting ${wait_interval}s..."
        sleep "$wait_interval"
        elapsed=$((elapsed + wait_interval))
    done
    
    log_warning "引导卷分离在 ${max_wait}s 后超时 - 继续执行"
    return 0
}

terminate_instance_and_preserve_boot_volume() {
    local comp_id="$1"
    local instance_id="$2"
    
    if [[ -z "$instance_id" ]]; then
        log_error "未提供要终止的实例 ID"
        return 1
    fi
    
    local boot_volume_id
    boot_volume_id=$(find_boot_volume_for_instance "$comp_id" "$instance_id")
    
    if [[ -n "$boot_volume_id" ]]; then
        log_info "找到实例 $instance_id 的引导卷: $boot_volume_id"
    fi
    
    log_info "正在终止实例: $instance_id（保留引导卷）"
    
    local terminate_output
    terminate_output=$(oci_cmd compute instance terminate \
        --instance-id "$instance_id" \
        --preserve-boot-volume "true" \
        --force 2>&1)
    local terminate_status=$?
    
    if [[ $terminate_status -ne 0 ]]; then
        log_error "终止实例失败: $terminate_output"
        return 1
    fi
    
    log_info "等待实例终止..."
    local max_wait=180
    local wait_interval=15
    local elapsed=0
    
    while [[ $elapsed -lt $max_wait ]]; do
        local state
        state=$(oci_cmd compute instance get \
            --instance-id "$instance_id" \
            --query 'data."lifecycle-state"' \
            --raw-output 2>/dev/null)
        
        if [[ -z "$state" || "$state" == "TERMINATED" || "$state" == "null" ]]; then
            log_info "实例在 ${elapsed}s 后成功终止"
            if [[ -n "$boot_volume_id" ]]; then
                echo "$boot_volume_id"
            fi
            return 0
        fi
        
        log_debug "Instance state: $state, waiting ${wait_interval}s..."
        sleep "$wait_interval"
        elapsed=$((elapsed + wait_interval))
    done
    
    log_warning "实例终止在 ${max_wait}s 后超时"
    if [[ -n "$boot_volume_id" ]]; then
        echo "$boot_volume_id"
    fi
    return 0
}

# Validate availability domain format
validate_availability_domain() {
    local ad_list="$1"
    
    # Check for empty input
    if [[ -z "$ad_list" ]]; then
        log_error "可用域不能为空"
        return 1
    fi
    
    # Check for leading/trailing commas or spaces
    if [[ "$ad_list" =~ ^[[:space:]]*,.* ]] || [[ "$ad_list" =~ .*,[[:space:]]*$ ]]; then
        log_error "无效的 AD 格式: 不允许前导或尾随逗号"
        log_error "Found: '$ad_list'"
        return 1
    fi
    
    # Check for consecutive commas
    if [[ "$ad_list" =~ ,, ]]; then
        log_error "Invalid AD format: consecutive commas not allowed"
        log_error "Found: '$ad_list'"
        return 1
    fi
    
    # Use a simple loop to split by comma
    local temp_list="$ad_list"
    
    # Process each AD separated by comma
    while [[ "$temp_list" == *","* ]]; do
        # Extract first AD
        local ad="${temp_list%%,*}"
        # Remove leading/trailing spaces
        ad=$(echo "$ad" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Validate this AD
        if [[ -z "$ad" ]]; then
            log_error "Empty availability domain found in comma-separated list"
            return 1
        fi
        
        if ! [[ "$ad" =~ ^[a-zA-Z0-9-]+:[A-Z0-9-]+-[A-Z]+-[0-9]+-AD-[0-9]+$ ]]; then
            log_error "Invalid availability domain format: '$ad'"
            log_error "Expected format: tenancy_prefix:REGION-AD-N (e.g., 'fgaj:AP-SINGAPORE-1-AD-1')"
            return 1
        fi
        
        # Remove processed AD from temp_list
        temp_list="${temp_list#*,}"
    done
    
    # Process the last (or only) AD
    if [[ -n "$temp_list" ]]; then
        # shellcheck disable=SC2155  # String trimming with sed rarely fails
        local ad=$(echo "$temp_list" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [[ -z "$ad" ]]; then
            log_error "Empty availability domain found at end of list"
            return 1
        fi
        
        if ! [[ "$ad" =~ ^[a-zA-Z0-9-]+:[A-Z0-9-]+-[A-Z]+-[0-9]+-AD-[0-9]+$ ]]; then
            log_error "Invalid availability domain format: '$ad'"
            log_error "Expected format: tenancy_prefix:REGION-AD-N (e.g., 'fgaj:AP-SINGAPORE-1-AD-1')"
            return 1
        fi
    fi
    
    return 0
}

# Validate timeout values are within reasonable bounds
validate_timeout_value() {
    local var_name="$1"
    local value="$2"
    local min_val="$3"
    local max_val="$4"
    
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "$var_name must be a positive integer, got: $value"
        return 1
    fi
    
    if [[ "$value" -lt "$min_val" || "$value" -gt "$max_val" ]]; then
        log_error "$var_name must be between $min_val-${max_val} seconds, got: $value"
        return 1
    fi
    
    log_debug "$var_name validation passed: ${value}s (range: $min_val-${max_val}s)"
    return 0
}

# Validate all configuration values for common issues
validate_configuration() {
    local validation_failed=false
    
    log_info "正在验证配置值..."
    
    # Validate required variables don't have spaces
    # NOTE: OPERATING_SYSTEM excluded because "Oracle Linux" is valid and properly quoted
    local vars_to_check=(
        "OCI_TENANCY_OCID:${OCI_TENANCY_OCID:-}"
        "OCI_USER_OCID:${OCI_USER_OCID:-}"
        "OCI_REGION:${OCI_REGION:-}"
        "OCI_AD:${OCI_AD:-}"
        "OCI_SHAPE:${OCI_SHAPE:-}"
        "INSTANCE_DISPLAY_NAME:${INSTANCE_DISPLAY_NAME:-}"
        "OCI_SUBNET_ID:${OCI_SUBNET_ID:-}"
        "OS_VERSION:${OS_VERSION:-}"
        "BOOT_VOLUME_SIZE:${BOOT_VOLUME_SIZE:-}"
        "RECOVERY_ACTION:${RECOVERY_ACTION:-}"
        "LEGACY_IMDS_ENDPOINTS:${LEGACY_IMDS_ENDPOINTS:-}"
        "RETRY_WAIT_TIME:${RETRY_WAIT_TIME:-}"
        "OCI_IMAGE_ID:${OCI_IMAGE_ID:-}"
        "OCI_KEY_FINGERPRINT:${OCI_KEY_FINGERPRINT:-}"
        "TELEGRAM_TOKEN:${TELEGRAM_TOKEN:-}"
        "TELEGRAM_USER_ID:${TELEGRAM_USER_ID:-}"
    )
    
    for var_def in "${vars_to_check[@]}"; do
        IFS=':' read -r var_name var_value <<< "$var_def"
        if [[ -n "$var_value" ]]; then
            if ! validate_no_spaces "$var_name" "$var_value"; then
                validation_failed=true
            fi
        fi
    done
    
    # Validate boot volume size if set
    if [[ -n "${BOOT_VOLUME_SIZE:-}" ]]; then
        if ! validate_boot_volume_size "$BOOT_VOLUME_SIZE"; then
            validation_failed=true
        fi
    fi
    
    # Validate boolean values
    local boolean_vars=(
        "LEGACY_IMDS_ENDPOINTS:${LEGACY_IMDS_ENDPOINTS:-}"
        "DEBUG:${DEBUG:-}"
        "ENABLE_NOTIFICATIONS:${ENABLE_NOTIFICATIONS:-}"
        "CHECK_EXISTING_INSTANCE:${CHECK_EXISTING_INSTANCE:-}"
    )
    
    for var_def in "${boolean_vars[@]}"; do
        IFS=':' read -r var_name var_value <<< "$var_def"
        if [[ -n "$var_value" ]]; then
            if [[ "$var_value" != "true" && "$var_value" != "false" ]]; then
                log_error "Boolean configuration variable $var_name must be 'true' or 'false': $var_value"
                validation_failed=true
            fi
        fi
    done
    
    # Validate numeric values
    if [[ -n "${RETRY_WAIT_TIME:-}" ]]; then
        if ! [[ "$RETRY_WAIT_TIME" =~ ^[0-9]+$ ]]; then
            log_error "RETRY_WAIT_TIME must be a positive integer: $RETRY_WAIT_TIME"
            validation_failed=true
        fi
    fi
    
    # Validate recovery action value
    if [[ -n "${RECOVERY_ACTION:-}" ]]; then
        if [[ "$RECOVERY_ACTION" != "RESTORE_INSTANCE" && "$RECOVERY_ACTION" != "STOP_INSTANCE" ]]; then
            log_error "RECOVERY_ACTION must be 'RESTORE_INSTANCE' or 'STOP_INSTANCE': $RECOVERY_ACTION"
            validation_failed=true
        fi
    fi
    
    # Validate availability domain format
    if [[ -n "${OCI_AD:-}" ]]; then
        if ! validate_availability_domain "$OCI_AD"; then
            validation_failed=true
        fi
    fi
    
    # Validate OCIDs if present
    local ocid_vars=(
        "OCI_TENANCY_OCID:${OCI_TENANCY_OCID:-}"
        "OCI_USER_OCID:${OCI_USER_OCID:-}"
        "OCI_COMPARTMENT_ID:${OCI_COMPARTMENT_ID:-}"
        "OCI_SUBNET_ID:${OCI_SUBNET_ID:-}"
        "OCI_IMAGE_ID:${OCI_IMAGE_ID:-}"
    )
    
    for ocid_def in "${ocid_vars[@]}"; do
        IFS=':' read -r var_name var_value <<< "$ocid_def"
        if [[ -n "$var_value" ]]; then
            if ! is_valid_ocid "$var_value"; then
                log_error "Invalid OCID format for $var_name: $var_value"
                validation_failed=true
            fi
        fi
    done
    
    if [[ "$validation_failed" == true ]]; then
        log_error "Configuration validation failed"
        return 1
    fi
    
    log_success "Configuration validation passed"
    return 0
}

# 性能指标 logging for multi-AD optimization
log_performance_metric() {
    local metric_type="$1"
    local ad_name="$2"
    local attempt_number="$3"
    local total_attempts="$4"
    local additional_info="${5:-}"
    
    # shellcheck disable=SC2155  # Date commands rarely fail
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local metric_line="[$timestamp] $metric_type: AD=$ad_name, Attempt=$attempt_number/$total_attempts"
    
    if [[ -n "$additional_info" ]]; then
        metric_line="$metric_line, Info=$additional_info"
    fi
    
    # Log to both debug output and a performance metrics comment for future analysis
    log_debug "PERF_METRIC: $metric_line"
    
    # In a production environment, these could be sent to monitoring systems
    case "$metric_type" in
        "AD_SUCCESS")
            log_info "Performance: Successful instance creation in $ad_name on attempt $attempt_number"
            ;;
        "AD_FAILURE")
            log_debug "Performance: Failed attempt in $ad_name ($attempt_number/$total_attempts) - $additional_info"
            ;;
        "AD_CYCLE_COMPLETE")
            log_info "Performance: Completed full AD cycle ($total_attempts ADs attempted)"
            ;;
    esac
}


# Set GitHub repository variable to mark successful instance creation
set_success_variable() {
    local instance_id="$1"
    local availability_domain="$2"
    
    # Only attempt to set variable if we have GITHUB_TOKEN (running in Actions)
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        log_info "Setting INSTANCE_CREATED variable to prevent future workflow runs"
        
        # Use GitHub CLI to set repository variable
        if command -v gh >/dev/null 2>&1; then
            # shellcheck disable=SC2155  # Date command embedded in JSON rarely fails
            local success_value="{\"created\": true, \"instance_id\": \"$instance_id\", \"ad\": \"$availability_domain\", \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')\"}"
            
            if gh variable set INSTANCE_CREATED --body "true" >/dev/null 2>&1; then
                log_success "Successfully set INSTANCE_CREATED variable"
                
                # Also set detailed info in a separate variable for debugging
                if gh variable set INSTANCE_CREATED_INFO --body "$success_value" >/dev/null 2>&1; then
                    log_debug "Set INSTANCE_CREATED_INFO with details: $success_value"
                fi
            else
                log_warning "Failed to set INSTANCE_CREATED variable - workflow may continue running"
            fi
        else
            log_warning "GitHub CLI not available - cannot set success variable"
        fi
    else
        log_debug "GITHUB_TOKEN not available - skipping repository variable update"
    fi
}

# Record success pattern for adaptive scheduling analysis
record_success_pattern() {
    local availability_domain="$1"
    local attempt_number="$2"
    local total_attempts="$3"
    
    # Only record if pattern tracking is enabled
    if [[ "${SUCCESS_TRACKING_ENABLED:-true}" != "true" ]]; then
        return 0
    fi
    
    # shellcheck disable=SC2155  # Date commands rarely fail
    local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')
    # shellcheck disable=SC2155  # Date commands rarely fail
    local hour_utc=$(date -u '+%H')
    # shellcheck disable=SC2155  # Date commands rarely fail
    local day_of_week=$(date -u '+%u')
    
    if [[ -n "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
        # Get existing pattern data - separate declaration for better error handling
        local existing_data
        existing_data=$(gh variable get SUCCESS_PATTERN_DATA 2>/dev/null || echo "[]")
        
        # Create success entry
        local success_entry="{\"type\":\"success\",\"timestamp\":\"$timestamp\",\"hour_utc\":$hour_utc,\"day_of_week\":$day_of_week,\"ad\":\"$availability_domain\",\"attempt\":$attempt_number,\"total_attempts\":$total_attempts}"
        
        # Update pattern data (keep last 100 entries)
        local updated_data
        if [[ -z "$existing_data" || "$existing_data" == "[]" ]]; then
            updated_data="[$success_entry]"
        else
            updated_data=$(echo "$existing_data" | jq --arg entry "$success_entry" '. + [($entry | fromjson)] | .[-50:]' 2>/dev/null || echo "[$success_entry]")
        fi
        
        # Store updated data
        if echo "$updated_data" | gh variable set SUCCESS_PATTERN_DATA --body-file - 2>/dev/null; then
            log_debug "Recorded success pattern: AD=$availability_domain, Hour=${hour_utc}UTC, Attempt=$attempt_number"
        fi
    fi
}

# Record failure pattern for adaptive scheduling analysis  
record_failure_pattern() {
    local availability_domain="$1"
    local error_type="$2"
    local attempt_number="$3"
    local total_attempts="$4"
    
    # Only record if pattern tracking is enabled
    if [[ "${SUCCESS_TRACKING_ENABLED:-true}" != "true" ]]; then
        return 0
    fi
    
    # shellcheck disable=SC2155  # Date commands rarely fail
    local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')
    # shellcheck disable=SC2155  # Date commands rarely fail
    local hour_utc=$(date -u '+%H')
    # shellcheck disable=SC2155  # Date commands rarely fail
    local day_of_week=$(date -u '+%u')
    
    if [[ -n "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
        # Get existing pattern data - separate declaration for better error handling
        local existing_data
        existing_data=$(gh variable get SUCCESS_PATTERN_DATA 2>/dev/null || echo "[]")
        
        # Create failure entry
        local failure_entry="{\"type\":\"${error_type}_failure\",\"timestamp\":\"$timestamp\",\"hour_utc\":$hour_utc,\"day_of_week\":$day_of_week,\"ad\":\"$availability_domain\",\"attempt\":$attempt_number,\"total_attempts\":$total_attempts}"
        
        # Update pattern data (keep last 100 entries)
        local updated_data
        if [[ -z "$existing_data" || "$existing_data" == "[]" ]]; then
            updated_data="[$failure_entry]"
        else
            updated_data=$(echo "$existing_data" | jq --arg entry "$failure_entry" '. + [($entry | fromjson)] | .[-50:]' 2>/dev/null || echo "[$failure_entry]")
        fi
        
        # Store updated data
        if echo "$updated_data" | gh variable set SUCCESS_PATTERN_DATA --body-file - 2>/dev/null; then
            log_debug "Recorded failure pattern: AD=$availability_domain, Error=$error_type, Hour=${hour_utc}UTC"
        fi
    fi
}

