#!/bin/bash
# State Management for Oracle Instance Creator
# Manages instance state caching via GitHub Actions cache to reduce Oracle API calls
# Provides functions for storing, retrieving, and validating instance creation state

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]:-$0}")/utils.sh"

format_timestamp() {
    local timestamp="$1"
    local format="${2:-'+%Y-%m-%d %H:%M:%S UTC'}"
    if [[ "$(uname)" == "Darwin" ]]; then
        date -r "$timestamp" "$format" 2>/dev/null || echo "$timestamp"
    else
        date -d "@$timestamp" "$format" 2>/dev/null || echo "$timestamp"
    fi
}

# =============================================================================
# CACHE CONFIGURATION (constants defined in constants.sh)
# =============================================================================

# Get cache configuration from environment with validation
get_cache_enabled() {
    local enabled="${CACHE_ENABLED:-$CACHE_ENABLED_DEFAULT}"
    if [[ "$enabled" =~ ^(true|false)$ ]]; then
        echo "$enabled"
    else
        echo "$CACHE_ENABLED_DEFAULT"
    fi
}

get_cache_ttl_hours() {
    local ttl="${CACHE_TTL_HOURS:-$CACHE_TTL_HOURS_DEFAULT}"
    if [[ "$ttl" =~ ^[0-9]+$ ]] && [[ "$ttl" -ge 1 ]] && [[ "$ttl" -le 168 ]]; then  # 1-168 hours (1 week max)
        echo "$ttl"
    else
        echo "$CACHE_TTL_HOURS_DEFAULT"
    fi
}

# Get dynamic TTL based on region contention
get_dynamic_ttl_hours() {
    local base_ttl
    base_ttl=$(get_cache_ttl_hours)
    local region="${OCI_REGION:-}"
    
    # Check if current region is in high contention list
    if [[ ",$HIGH_CONTENTION_REGIONS," == *",$region,"* ]]; then
        # Use reduced TTL for high-contention regions
        local reduced_ttl
        reduced_ttl=$(echo "$base_ttl * $HIGH_CONTENTION_TTL_MULTIPLIER" | bc 2>/dev/null || echo "$base_ttl")
        # Ensure minimum TTL of 1 hour
        if (( $(echo "$reduced_ttl < 1" | bc -l 2>/dev/null || echo "0") )); then
            echo "1"
        else
            printf "%.0f" "$reduced_ttl"
        fi
    else
        echo "$base_ttl"
    fi
}

# Get absolute cache directory path
get_cache_dir() {
    local cache_dir="${CACHE_PATH:-$CACHE_PATH_DEFAULT}"
    # Convert to absolute path if relative
    if [[ "$cache_dir" != /* ]]; then
        cache_dir="$(pwd)/$cache_dir"
    fi
    echo "$cache_dir"
}

# Get absolute state file path
get_state_file_path() {
    local state_file
    state_file="${1:-$STATE_FILE_NAME}"
    local cache_dir
    cache_dir=$(get_cache_dir)
    
    # If state_file is just a filename, put it in cache directory
    if [[ "$state_file" == "$(basename "$state_file")" ]]; then
        echo "$cache_dir/$state_file"
    else
        # If it's already a path, use it as-is but make it absolute
        if [[ "$state_file" != /* ]]; then
            echo "$(pwd)/$state_file"
        else
            echo "$state_file"
        fi
    fi
}

# =============================================================================
# STATE FILE MANAGEMENT
# =============================================================================

# File locking utilities for safe concurrent access
acquire_state_lock() {
    local state_file="$1"
    local lock_file="${state_file}.lock"
    local timeout="${2:-30}"
    local wait_count=0
    
    while (( wait_count < timeout )); do
        if (set -C; echo $$ > "$lock_file") 2>/dev/null; then
            log_debug "已获取状态锁: $lock_file"
            return 0
        fi
        
        if [[ -f "$lock_file" ]] && [[ $(( $(date +%s) - $(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null || echo 0) )) -gt 300 ]]; then
            log_warning "正在移除过期锁文件: $lock_file"
            rm -f "$lock_file"
            sleep 0.1
            continue
        fi
        
        log_debug "等待状态锁... ($((wait_count + 1))/$timeout)"
        sleep 1
        ((wait_count++))
    done
    
    log_error "在 ${timeout}s 后获取状态锁失败: $lock_file"
    return 1
}

release_state_lock() {
    local state_file="$1"
    local lock_file="${state_file}.lock"
    
    if [[ -f "$lock_file" ]]; then
        rm -f "$lock_file"
        log_debug "已释放状态锁: $lock_file"
    fi
}

# Wrapper for safe state file operations with automatic locking
with_state_lock() {
    local state_file="$1"
    shift
    local func_name="$1"
    shift
    
    if acquire_state_lock "$state_file"; then
        local old_exit_trap old_err_trap
        old_exit_trap=$(trap -p EXIT)
        old_err_trap=$(trap -p ERR)
        trap "release_state_lock '$state_file'" EXIT ERR
        "$func_name" "$state_file" "$@"
        local result=$?
        release_state_lock "$state_file"
        eval "$old_exit_trap" 2>/dev/null || true
        eval "$old_err_trap" 2>/dev/null || true
        return "$result"
    else
        log_error "状态操作获取锁失败: $func_name"
        return 1
    fi
}

# Generate cache key for GitHub Actions cache
# Format: oci-instances-{region_hash}-{version}-{date}
generate_cache_key() {
    local region="${OCI_REGION:-unknown}"
    local date_key
    
    # Use provided cache date key if available (prevents race conditions)
    if [[ -n "${CACHE_DATE_KEY:-}" ]]; then
        date_key="$CACHE_DATE_KEY"
    else
        date_key=$(date '+%Y-%m-%d')
    fi
    
    # Generate secure hash of region to avoid information leakage
    local region_hash
    if command -v sha256sum >/dev/null 2>&1; then
        region_hash=$(echo -n "$region" | sha256sum | cut -d' ' -f1 | head -c 8)
    elif command -v shasum >/dev/null 2>&1; then
        region_hash=$(echo -n "$region" | shasum -a 256 | cut -d' ' -f1 | head -c 8)
    else
        # Fallback to simple sanitization if no hash tools available
        region_hash=$(echo "$region" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
    fi
    
    echo "oci-instances-${region_hash}-${CACHE_VERSION}-${date_key}"
}

# Generate fallback cache key pattern for restore
generate_cache_restore_keys() {
    local region="${OCI_REGION:-unknown}"
    
    # Generate secure hash of region to match generate_cache_key behavior
    local region_hash
    if command -v sha256sum >/dev/null 2>&1; then
        region_hash=$(echo -n "$region" | sha256sum | cut -d' ' -f1 | head -c 8)
    elif command -v shasum >/dev/null 2>&1; then
        region_hash=$(echo -n "$region" | shasum -a 256 | cut -d' ' -f1 | head -c 8)
    else
        # Fallback to simple sanitization if no hash tools available
        region_hash=$(echo "$region" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
    fi
    
    # Generate keys for today and yesterday (in case of timezone differences)
    local today yesterday
    today=$(date '+%Y-%m-%d')
    yesterday=$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || date -v-1d '+%Y-%m-%d' 2>/dev/null || echo "$today")
    
    echo "oci-instances-${region_hash}-${CACHE_VERSION}-${today}"
    echo "oci-instances-${region_hash}-${CACHE_VERSION}-${yesterday}"
    echo "oci-instances-${region_hash}-${CACHE_VERSION}-"
}

# Initialize empty state file
init_state_file() {
    local state_file="$1"
    
    # Ensure the directory exists
    local state_dir
    state_dir=$(dirname "$state_file")
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir"
        log_debug "已创建状态目录: $state_dir"
    fi
    
    local timestamp
    timestamp=$(date +%s)
    
    cat > "$state_file" << EOF
{
  "version": "$CACHE_VERSION",
  "region": "${OCI_REGION:-}",
  "created": "$timestamp",
  "updated": "$timestamp",
  "instances": {},
  "limits": {
    "e2_limit_reached": false,
    "a1_limit_reached": false,
    "last_limit_check": $timestamp,
    "ttl_hours": 24
  }
}
EOF
    
    log_debug "已初始化空状态文件: $state_file"
}

# Load state from file with validation
load_state() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    
    if [[ ! -f "$state_file" ]]; then
        log_debug "状态文件未找到，正在初始化: $state_file"
        init_state_file "$state_file"
    fi
    
    # Validate JSON structure
    if ! jq empty "$state_file" 2>/dev/null; then
        log_warning "状态文件中 JSON 无效，正在重新初始化: $state_file"
        init_state_file "$state_file"
    fi
    
    # Ensure required fields exist
    if ! jq -e '.instances' "$state_file" >/dev/null 2>&1; then
        log_warning "状态文件缺少 instances 字段，正在重新初始化: $state_file"
        init_state_file "$state_file"
    fi
    
    # Ensure limits field exists (for backward compatibility with existing state files)
    if ! jq -e '.limits' "$state_file" >/dev/null 2>&1; then
        log_info "状态文件缺少 limits 字段，添加默认限额结构"
        local timestamp
        timestamp=$(date +%s)
        local temp_file
        temp_file=$(mktemp)
        
        jq --arg timestamp "$timestamp" \
           '.limits = {
             "e2_limit_reached": false,
             "a1_limit_reached": false,
             "last_limit_check": ($timestamp | tonumber),
             "ttl_hours": 24
           }' "$state_file" > "$temp_file"
        mv "$temp_file" "$state_file"
    fi
    
    echo "$state_file"
}

# =============================================================================
# INSTANCE STATE OPERATIONS
# =============================================================================

# Check if instance exists in state
instance_exists_in_state() {
    local instance_name="$1"
    local state_file
    state_file=$(get_state_file_path "${2:-}")
    
    if [[ ! -f "$state_file" ]]; then
        return 1
    fi
    
    jq -e --arg name "$instance_name" '.instances[$name] != null' "$state_file" >/dev/null 2>&1
}

# Get instance state information
get_instance_state() {
    local instance_name="$1" 
    local state_file
    state_file=$(get_state_file_path "${2:-}")
    local field="${3:-}"  # Optional: specific field to retrieve
    
    if [[ ! -f "$state_file" ]]; then
        return 1
    fi
    
    if [[ -n "$field" ]]; then
        jq -r --arg name "$instance_name" --arg field "$field" \
           '.instances[$name][$field] // empty' "$state_file" 2>/dev/null || echo ""
    else
        jq -r --arg name "$instance_name" \
           '.instances[$name] // empty' "$state_file" 2>/dev/null || echo "{}"
    fi
}

# Internal function - performs actual state update (assumes lock is held)
_update_instance_state_locked() {
    local state_file="$1"
    local instance_name="$2"
    local ocid="$3"
    local status="${4:-created}"
    
    local timestamp
    timestamp=$(date +%s)
    
    # Ensure state file exists
    load_state "$state_file" >/dev/null
    
    # Update instance state
    local temp_file
    temp_file=$(mktemp)
    
    jq --arg name "$instance_name" \
       --arg ocid "$ocid" \
       --arg status "$status" \
       --arg timestamp "$timestamp" \
       '.updated = $timestamp | .instances[$name] = {
         "ocid": $ocid,
         "status": $status, 
         "created": ($timestamp),
         "last_verified": $timestamp,
         "shape": (env.OCI_SHAPE // ""),
         "region": (env.OCI_REGION // "")
       }' "$state_file" > "$temp_file"
    
    mv "$temp_file" "$state_file"
    
    log_info "已更新实例状态: $instance_name (OCID: $ocid, 状态: $status)"
}

# Add or update instance in state with file locking
update_instance_state() {
    local instance_name="$1"
    local ocid="$2"
    local status="${3:-created}"
    local state_file
    state_file=$(get_state_file_path "${4:-}")
    
    with_state_lock "$state_file" _update_instance_state_locked "$instance_name" "$ocid" "$status"
}

# Internal function - performs actual state removal (assumes lock is held)
_remove_instance_state_locked() {
    local state_file="$1"
    local instance_name="$2"
    
    if [[ ! -f "$state_file" ]]; then
        log_debug "状态文件未找到，无内容可移除: $state_file"
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    
    local timestamp
    timestamp=$(date +%s)
    
    jq --arg name "$instance_name" \
       --arg timestamp "$timestamp" \
       '.updated = $timestamp | del(.instances[$name])' "$state_file" > "$temp_file"
    
    mv "$temp_file" "$state_file"
    
    log_info "已从状态中移除实例: $instance_name"
}

# Remove instance from state with file locking
remove_instance_state() {
    local instance_name="$1"
    local state_file
    state_file=$(get_state_file_path "${2:-}")
    
    with_state_lock "$state_file" _remove_instance_state_locked "$instance_name"
}

# =============================================================================
# CACHE VALIDATION
# =============================================================================

# Check if state is expired based on TTL
is_state_expired() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    local ttl_hours
    ttl_hours=$(get_cache_ttl_hours)
    
    if [[ ! -f "$state_file" ]]; then
        return 0  # No state file = expired
    fi
    
    local updated_timestamp
    updated_timestamp=$(jq -r '.updated // empty' "$state_file" 2>/dev/null)
    
    if [[ -z "$updated_timestamp" ]]; then
        return 0  # No timestamp = expired
    fi
    
    # Calculate expiry time using Unix timestamps (simpler and more reliable)
    local updated_epoch current_epoch ttl_seconds expiry_epoch
    current_epoch=$(date +%s)
    
    # Timestamp is already in Unix epoch format
    if [[ "$updated_timestamp" =~ ^[0-9]+$ ]]; then
        updated_epoch="$updated_timestamp"
    else
        # Fallback: assume expired if not a valid Unix timestamp
        log_debug "无效的 Unix 时间戳格式: $updated_timestamp"
        return 0  # Treat as expired
    fi
    
    ttl_seconds=$((ttl_hours * 3600))
    expiry_epoch=$((updated_epoch + ttl_seconds))
    
    if [[ "$current_epoch" -gt "$expiry_epoch" ]]; then
        log_debug "状态缓存已过期 (TTL: ${ttl_hours}h, 更新时间: $updated_timestamp)"
        return 0  # Expired
    else
        log_debug "状态缓存有效 (TTL: ${ttl_hours}h, 更新时间: $updated_timestamp)"
        return 1  # Not expired
    fi
}

# Validate state file integrity and consistency
validate_state_file() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    
    if [[ ! -f "$state_file" ]]; then
        log_debug "状态文件未找到: $state_file"
        return 1
    fi
    
    # Check JSON validity
    if ! jq empty "$state_file" 2>/dev/null; then
        log_warning "状态文件中 JSON 无效: $state_file"
        return 1
    fi
    
    # Check required structure
    local required_fields=("version" "instances")
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" "$state_file" >/dev/null 2>&1; then
            log_warning "状态文件中缺少必需字段 '$field': $state_file"
            return 1
        fi
    done
    
    # Check version compatibility
    local state_version
    state_version=$(jq -r '.version // ""' "$state_file")
    if [[ "$state_version" != "$CACHE_VERSION" ]]; then
        log_warning "状态文件版本不匹配（期望: $CACHE_VERSION，实际: $state_version）"
        return 1
    fi
    
    log_debug "状态文件验证通过: $state_file"
    return 0
}

# =============================================================================
# GITHUB ACTIONS INTEGRATION
# =============================================================================

# Check if running in GitHub Actions environment
is_github_actions() {
    [[ -n "${GITHUB_ACTIONS:-}" ]] && [[ "${GITHUB_ACTIONS}" == "true" ]]
}

# Save state to GitHub Actions cache (if available)
save_state_to_cache() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    
    if [[ "$(get_cache_enabled)" != "true" ]]; then
        log_debug "缓存已禁用，跳过保存"
        return 0
    fi
    
    if ! is_github_actions; then
        log_debug "不在 GitHub Actions 中，跳过缓存保存"
        return 0
    fi
    
    if [[ ! -f "$state_file" ]]; then
        log_warning "状态文件未找到，无法保存到缓存: $state_file"
        return 1
    fi
    
    local cache_key
    cache_key=$(generate_cache_key)
    
    log_info "正在保存状态到 GitHub Actions 缓存: $cache_key"
    
    # Ensure the cache directory exists and copy state file
    local cache_dir
    cache_dir=$(get_cache_dir)
    mkdir -p "$cache_dir"
    
    # If state file is already in cache directory, no need to copy
    local cached_state="$cache_dir/$STATE_FILE_NAME"
    if [[ "$state_file" != "$cached_state" ]]; then
        cp "$state_file" "$cached_state"
        log_debug "已复制状态文件到缓存目录: $cached_state"
    fi
    
    # Note: Actual cache save would be handled by GitHub Actions workflow
    # This function prepares the file for caching
    echo "CACHE_KEY=$cache_key" >> "${GITHUB_ENV:-/dev/null}"
    echo "CACHE_PATH=$cache_dir" >> "${GITHUB_ENV:-/dev/null}"
    
    log_debug "状态已准备好缓存到: $cache_dir"
}

# Load state from GitHub Actions cache (if available)
load_state_from_cache() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    
    if [[ "$(get_cache_enabled)" != "true" ]]; then
        log_debug "缓存已禁用，跳过加载"
        return 1
    fi
    
    if ! is_github_actions; then
        log_debug "不在 GitHub Actions 中，跳过缓存加载"
        return 1
    fi
    
    local cache_dir
    cache_dir=$(get_cache_dir)
    local cached_state="$cache_dir/$STATE_FILE_NAME"
    
    if [[ -f "$cached_state" ]]; then
        if validate_state_file "$cached_state"; then
            # Ensure target directory exists
            local target_dir
            target_dir=$(dirname "$state_file")
            if [[ ! -d "$target_dir" ]]; then
                mkdir -p "$target_dir"
            fi
            
            # If state file is the same as cached state, no need to copy
            if [[ "$state_file" != "$cached_state" ]]; then
                cp "$cached_state" "$state_file"
                log_debug "已复制缓存状态到: $state_file"
            fi
            
            log_info "已从 GitHub Actions 缓存加载状态"
            return 0
        else
            log_warning "缓存状态文件无效，忽略缓存"
            return 1
        fi
    else
        log_debug "在 $cache_dir 中未找到缓存状态"
        return 1
    fi
}

# =============================================================================
# HIGH-LEVEL INTERFACE FUNCTIONS
# =============================================================================

# Initialize state management system
init_state_manager() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    
    log_debug "正在初始化状态管理器（缓存启用: $(get_cache_enabled), TTL: $(get_dynamic_ttl_hours)h）"
    
    # Try to load from cache first
    if ! load_state_from_cache "$state_file"; then
        # Fallback to initializing empty state
        load_state "$state_file" >/dev/null
    fi
    
    echo "$state_file"
}

# Check if instance should be created (not in cache or cache expired)
should_create_instance() {
    local instance_name="$1"
    local state_file
    state_file=$(get_state_file_path "${2:-}")
    
    log_debug "=== SHOULD_CREATE_INSTANCE 调试开始 ==="
    log_debug "实例名称: $instance_name"
    log_debug "状态文件: $state_file"
    log_debug "缓存启用: $(get_cache_enabled)"
    
    # If cache disabled, always create
    if [[ "$(get_cache_enabled)" != "true" ]]; then
        log_debug "缓存已禁用，允许创建实例: $instance_name"
        log_debug "=== SHOULD_CREATE_INSTANCE 调试结束: 允许（缓存已禁用）==="
        return 0
    fi
    
    # Check if state file exists
    if [[ ! -f "$state_file" ]]; then
        log_debug "状态文件不存在: $state_file"
        log_debug "=== SHOULD_CREATE_INSTANCE 调试结束: 允许（无状态文件）==="
        return 0
    fi
    
    # If state expired, allow creation
    if is_state_expired "$state_file"; then
        log_debug "状态已过期，允许创建实例: $instance_name"
        log_debug "=== SHOULD_CREATE_INSTANCE 调试结束: 允许（状态已过期）==="
        return 0
    fi
    
    # Check for cached limit state based on instance name to shape mapping
    local shape=""
    
    # Method 1: Direct instance name mapping (highest priority)
    case "$instance_name" in
        "a1-flex-sg")
            shape="VM.Standard.A1.Flex"
            log_debug "已将实例 '$instance_name' 映射到形状 '$shape'（直接映射）"
            ;;
        "e2-micro-sg")
            shape="VM.Standard.E2.1.Micro"
            log_debug "已将实例 '$instance_name' 映射到形状 '$shape'（直接映射）"
            ;;
        *)
            log_debug "实例名称 '$instance_name' 无直接映射"
            ;;
    esac
    
    # Method 2: Pattern-based mapping if direct mapping failed
    if [[ -z "$shape" ]]; then
        case "$instance_name" in
            *"a1"*|*"A1"*|*"flex"*|*"Flex"*|*"arm"*|*"ARM"*)
                shape="VM.Standard.A1.Flex"
                log_debug "已将实例 '$instance_name' 映射到形状 '$shape'（模式: ARM/A1/Flex）"
                ;;
            *"e2"*|*"E2"*|*"micro"*|*"Micro"*|*"amd"*|*"AMD"*)
                shape="VM.Standard.E2.1.Micro"
                log_debug "已将实例 '$instance_name' 映射到形状 '$shape'（模式: AMD/E2/Micro）"
                ;;
        esac
    fi
    
    # Method 3: Environment variable fallback (medium priority)
    if [[ -z "$shape" && -n "${OCI_SHAPE:-}" ]]; then
        shape="$OCI_SHAPE"
        log_debug "使用环境变量中的形状 $instance_name: $shape（环境回退）"
    fi
    
    # Method 4: Check instance state for existing shape information
    if [[ -z "$shape" ]] && instance_exists_in_state "$instance_name" "$state_file"; then
        local cached_shape
        cached_shape=$(jq -r ".instances[\"$instance_name\"].shape // \"\"" "$state_file" 2>/dev/null || echo "")
        if [[ -n "$cached_shape" && "$cached_shape" != "null" ]]; then
            shape="$cached_shape"
            log_debug "从缓存实例状态获取形状 $instance_name: $shape（缓存形状）"
        fi
    fi
    
    # Log final result
    if [[ -n "$shape" ]]; then
        log_debug "实例 '$instance_name' 的最终形状映射: '$shape'"
    else
        log_debug "无法确定实例 '$instance_name' 的形状 - 将跳过限额检查"
    fi
    
    # If we have a shape, check if its limit is reached
    if [[ -n "$shape" ]]; then
        log_debug "正在检查形状限额状态: $shape"
        if get_cached_limit_state "$shape" "$state_file"; then
            log_info "形状 $shape 免费层限额已达（实例: $instance_name），跳过创建"
            log_debug "=== SHOULD_CREATE_INSTANCE 调试结束: 跳过（限额已达）==="
            return 1  # Don't create - limit reached
        else
            log_debug "形状 $shape 未达限额"
        fi
    else
        log_debug "未确定形状，无法检查限额"
    fi
    
    # If instance not in state, allow creation
    if ! instance_exists_in_state "$instance_name" "$state_file"; then
        log_debug "实例不在状态中，允许创建: $instance_name"
        log_debug "=== SHOULD_CREATE_INSTANCE 调试结束: 允许（不在状态中）==="
        return 0
    fi
    
    # Check instance status
    local status
    status=$(get_instance_state "$instance_name" "$state_file" "status")
    log_debug "在状态中找到实例 '$instance_name'，状态: '$status'"
    
    case "$status" in
        "created"|"verified"|"running")
            log_info "实例在状态中存在，状态 '$status'，跳过创建: $instance_name"
            log_debug "=== SHOULD_CREATE_INSTANCE 调试结束: 跳过（存在，状态 $status）==="
            return 1  # Don't create
            ;;
        "failed"|"terminated")
            log_info "实例在状态中存在，状态 '$status'，允许重新创建: $instance_name"
            log_debug "=== SHOULD_CREATE_INSTANCE 调试结束: 允许（重新创建，状态 $status）==="
            return 0  # Allow creation
            ;;
        *)
            log_debug "实例在状态中存在，未知状态 '$status'，允许创建: $instance_name"
            log_debug "=== SHOULD_CREATE_INSTANCE 调试结束: 允许（未知状态 $status）==="
            return 0  # Allow creation for safety
            ;;
    esac
}

# Record successful instance creation
record_instance_creation() {
    local instance_name="$1"
    local ocid="$2"
    local state_file
    state_file=$(get_state_file_path "${3:-}")
    
    update_instance_state "$instance_name" "$ocid" "created" "$state_file"
    save_state_to_cache "$state_file"
}

# Record instance verification 
record_instance_verification() {
    local instance_name="$1"
    local ocid="$2"
    local status="${3:-verified}"
    local state_file
    state_file=$(get_state_file_path "${4:-}")
    
    update_instance_state "$instance_name" "$ocid" "$status" "$state_file"
    save_state_to_cache "$state_file"
}

# Clean up state management
cleanup_state_manager() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    
    # Cleanup temporary files
    rm -f "${state_file}.tmp" "${state_file}.bak"
    
    log_debug "状态管理器清理完成"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Get state summary for logging
get_state_summary() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    
    if [[ ! -f "$state_file" ]]; then
        echo "No state file"
        return
    fi
    
    local instance_count created_count updated
    instance_count=$(jq -r '.instances | length' "$state_file" 2>/dev/null || echo "0")
    created_count=$(jq -r '.instances | to_entries | map(select(.value.status == "created")) | length' "$state_file" 2>/dev/null || echo "0")
    local updated updated_readable
    updated=$(jq -r '.updated // "unknown"' "$state_file" 2>/dev/null)
    
    # Convert Unix timestamp to readable format for display
    if [[ "$updated" =~ ^[0-9]+$ ]] && [[ "$updated" != "unknown" ]]; then
        updated_readable=$(format_timestamp "$updated")
    else
        updated_readable="$updated"
    fi
    
    echo "Instances: $instance_count (created: $created_count), Updated: $updated_readable"
}

# Print state in human-readable format
print_state() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    
    if [[ ! -f "$state_file" ]]; then
        echo "No state file found: $state_file"
        return 1
    fi
    
    echo "=== Instance State Summary ==="
    echo "缓存启用: $(get_cache_enabled)"
    echo "Cache TTL: $(get_cache_ttl_hours) hours" 
    echo "状态文件: $state_file"
    echo "Summary: $(get_state_summary "$state_file")"
    echo
    
    if jq -e '.instances | length > 0' "$state_file" >/dev/null 2>&1; then
        echo "=== Instance Details ==="
        # Process each instance and format timestamps
        while IFS= read -r line; do
            local name status ocid created
            name=$(echo "$line" | jq -r '.key')
            status=$(echo "$line" | jq -r '.value.status')
            ocid=$(echo "$line" | jq -r '.value.ocid')
            created=$(echo "$line" | jq -r '.value.created')
            
            # Convert Unix timestamp to readable format
            local created_readable
            if [[ "$created" =~ ^[0-9]+$ ]]; then
                created_readable=$(format_timestamp "$created")
            else
                created_readable="$created"
            fi
            
            echo "$name: $status (OCID: $ocid, Created: $created_readable)"
        done < <(jq -c '.instances | to_entries[]' "$state_file")
    else
        echo "No instances in state"
    fi
}

# =============================================================================
# ENHANCED VERIFICATION FUNCTIONS
# =============================================================================

# Verify instance configuration matches cached expectations
verify_instance_configuration() {
    local instance_id="$1"
    local expected_shape="$2"
    local expected_ocpus="${3:-}"
    local expected_memory="${4:-}"
    
    if [[ -z "$instance_id" || -z "$expected_shape" ]]; then
        log_error "verify_instance_configuration: instance_id 和 expected_shape 为必填项"
        return 1
    fi
    
    # Get actual instance configuration from OCI API
    local actual_config
    if ! actual_config=$(oci_cmd compute instance get --instance-id "$instance_id" \
        --query 'data.{shape:shape,ocpus:shapeConfig.ocpus,memory:shapeConfig.memoryInGBs}' \
        --output json 2>/dev/null); then
        log_error "获取实例 $instance_id 配置失败"
        return 1
    fi
    
    # Parse the configuration
    local actual_shape actual_ocpus actual_memory
    actual_shape=$(echo "$actual_config" | jq -r '.shape // "unknown"')
    actual_ocpus=$(echo "$actual_config" | jq -r '.ocpus // "null"')
    actual_memory=$(echo "$actual_config" | jq -r '.memory // "null"')
    
    # Verify shape matches
    if [[ "$actual_shape" != "$expected_shape" ]]; then
        log_warning "实例形状不匹配: 期望 '$expected_shape'，实际 '$actual_shape'"
        return 2
    fi
    
    # Verify OCPUs if specified and shape is flexible
    if [[ -n "$expected_ocpus" && "$actual_ocpus" != "null" ]]; then
        if ! awk -v actual="$actual_ocpus" -v expected="$expected_ocpus" \
            'BEGIN { exit (actual != expected) }' 2>/dev/null; then
            log_warning "实例 OCPU 不匹配: 期望 '$expected_ocpus'，实际 '$actual_ocpus'"
            return 2
        fi
    fi
    
    # Verify memory if specified and shape is flexible
    if [[ -n "$expected_memory" && "$actual_memory" != "null" ]]; then
        if ! awk -v actual="$actual_memory" -v expected="$expected_memory" \
            'BEGIN { exit (actual != expected) }' 2>/dev/null; then
            log_warning "实例内存不匹配: 期望 '${expected_memory}GB'，实际 '${actual_memory}GB'"
            return 2
        fi
    fi
    
    log_debug "实例配置已验证: 形状=$actual_shape, OCPU=$actual_ocpus, 内存=${actual_memory}GB"
    return 0
}

# Update instance state with configuration details
update_instance_state_with_config() {
    local instance_name="$1"
    local ocid="$2"
    local status="$3"
    local shape="$4"
    local ocpus="${5:-}"
    local memory="${6:-}"
    local state_file
    state_file=$(get_state_file_path "${7:-}")
    
    # Create configuration object
    local config_json="{\"shape\": \"$shape\""
    if [[ -n "$ocpus" ]]; then
        config_json="$config_json, \"ocpus\": $ocpus"
    fi
    if [[ -n "$memory" ]]; then
        config_json="$config_json, \"memory\": $memory"
    fi
    config_json="$config_json}"
    
    # Update instance state with configuration
    local timestamp
    timestamp=$(date +%s)
    
    local temp_file="${state_file}.tmp"
    if jq --arg name "$instance_name" \
          --arg ocid "$ocid" \
          --arg status "$status" \
          --arg timestamp "$timestamp" \
          --argjson config "$config_json" \
          '.instances[$name] = {
              "id": $ocid,
              "status": $status,
              "updated": ($timestamp | tonumber),
              "config": $config
          } | .updated = ($timestamp | tonumber)' \
          "$state_file" > "$temp_file"; then
        mv "$temp_file" "$state_file"
        log_debug "已更新实例状态及配置: $instance_name"
    else
        rm -f "$temp_file"
        log_error "更新实例状态及配置失败: $instance_name"
        return 1
    fi
}

# =============================================================================
# CACHE STATISTICS AND MANAGEMENT
# =============================================================================

# Get cache statistics summary
get_cache_stats() {
    local cache_dir
    cache_dir=$(get_cache_dir)
    local stats_file="$cache_dir/$CACHE_STATS_FILE"
    
    if [[ ! -f "$stats_file" ]]; then
        echo "No cache statistics available"
        return 1
    fi
    
    echo "=== Cache Statistics ==="
    jq -r '.stats | to_entries | map("\(.key): \(.value)") | join("\n")' "$stats_file" 2>/dev/null || echo "Failed to read statistics"
    
    local updated
    updated=$(jq -r '.updated' "$stats_file" 2>/dev/null)
    if [[ "$updated" =~ ^[0-9]+$ ]]; then
        local updated_readable
        updated_readable=$(format_timestamp "$updated")
        echo "Last updated: $updated_readable"
    fi
}

# Purge cache and reset statistics
purge_cache() {
    local cache_dir
    cache_dir=$(get_cache_dir)
    
    if [[ -d "$cache_dir" ]]; then
        rm -rf "$cache_dir"
        log_info "缓存已清除: $cache_dir"
    else
        log_debug "缓存目录不存在: $cache_dir"
    fi
    
    # Reinitialize empty state
    init_state_manager >/dev/null
    log_info "缓存和状态管理已重置"
}

# Check cache health
check_cache_health() {
    local cache_dir
    cache_dir=$(get_cache_dir)
    local state_file
    state_file=$(get_state_file_path)
    
    echo "=== Cache Health Check ==="
    
    # Check cache directory
    if [[ -d "$cache_dir" ]]; then
        echo "✓ Cache directory exists: $cache_dir"
        echo "  Permissions: $(stat -c %A "$cache_dir" 2>/dev/null || stat -f %Sp "$cache_dir" 2>/dev/null || echo "unknown")"
    else
        echo "✗ Cache directory missing: $cache_dir"
        return 1
    fi
    
    # Check state file
    if [[ -f "$state_file" ]]; then
        echo "✓ State file exists: $state_file"
        if validate_state_file "$state_file"; then
            echo "✓ State file is valid JSON"
            local ttl_hours
            ttl_hours=$(get_dynamic_ttl_hours)
            echo "  TTL: ${ttl_hours}h (dynamic based on region)"
            
            # Check if expired
            if is_state_expired "$state_file"; then
                echo "⚠ State file is expired"
            else
                echo "✓ State file is current"
            fi
        else
            echo "✗ State file is corrupted"
            return 1
        fi
    else
        echo "⚠ State file not found: $state_file"
    fi
    
    # Cache configuration
    echo "✓ Cache enabled: $(get_cache_enabled)"
    echo "✓ GitHub Actions mode: $(is_github_actions && echo "true" || echo "false")"
    
    return 0
}

# =============================================================================
# LIMIT STATE MANAGEMENT
# =============================================================================

# Check if a shape limit is reached based on cached state
get_cached_limit_state() {
    local shape="$1"
    local state_file
    state_file=$(get_state_file_path "${2:-}")
    
    log_debug "=== GET_CACHED_LIMIT_STATE 调试开始 ==="
    log_debug "形状: $shape"
    log_debug "状态文件: $state_file"
    
    if [[ ! -f "$state_file" ]]; then
        log_debug "状态文件不存在: $state_file"
        log_debug "=== GET_CACHED_LIMIT_STATE 调试结束: 无限额（无文件）==="
        return 1  # No cache = no limit cached
    fi
    
    # Check if limits section exists
    if ! jq -e '.limits' "$state_file" >/dev/null 2>&1; then
        log_debug "状态文件中无 limits 部分"
        log_debug "=== GET_CACHED_LIMIT_STATE 调试结束: 无限额（无 limits 部分）==="
        return 1  # No limits section = no limit cached
    fi
    
    # Determine limit field based on shape
    local limit_field
    case "$shape" in
        "VM.Standard.E2.1.Micro")
            limit_field="e2_limit_reached"
            log_debug "已将形状 '$shape' 映射到限额字段 '$limit_field'"
            ;;
        "VM.Standard.A1.Flex")
            limit_field="a1_limit_reached"
            log_debug "已将形状 '$shape' 映射到限额字段 '$limit_field'"
            ;;
        *)
            log_warning "限额检查的未知形状: $shape"
            log_debug "=== GET_CACHED_LIMIT_STATE 调试结束: 无限额（未知形状）==="
            return 1
            ;;
    esac
    
    # Check if limit TTL has expired
    local last_check ttl_hours current_time
    last_check=$(jq -r ".limits.last_limit_check // 0" "$state_file")
    ttl_hours=$(jq -r ".limits.ttl_hours // 24" "$state_file")
    current_time=$(date +%s)
    
    log_debug "限额缓存 TTL 检查:"
    log_debug "  上次检查: $last_check ($(format_timestamp "$last_check" '+%Y-%m-%d %H:%M:%S'))"
    log_debug "  当前时间: $current_time ($(format_timestamp "$current_time" '+%Y-%m-%d %H:%M:%S'))"
    log_debug "  TTL hours: $ttl_hours"
    log_debug "  Age in seconds: $((current_time - last_check))"
    log_debug "  Max age in seconds: $((ttl_hours * 3600))"
    
    if [[ $((current_time - last_check)) -gt $((ttl_hours * 3600)) ]]; then
        log_debug "形状 $shape 的限额缓存已过期 (TTL: ${ttl_hours}h)"
        log_debug "=== GET_CACHED_LIMIT_STATE 调试结束: 无限额（缓存过期）==="
        return 1  # Cache expired
    fi
    
    # Check the specific limit flag
    local limit_reached
    limit_reached=$(jq -r ".limits.$limit_field // false" "$state_file")
    log_debug "限额字段 '$limit_field' 值: '$limit_reached'"
    
    if [[ "$limit_reached" == "true" ]]; then
        log_debug "形状 $shape 的缓存限额已达"
        log_debug "=== GET_CACHED_LIMIT_STATE 调试结束: 限额已达 ==="
        return 0  # Limit is cached as reached
    else
        log_debug "形状 $shape 无缓存限额（值: $limit_reached）"
        log_debug "=== GET_CACHED_LIMIT_STATE 调试结束: 无限额（未达限额）==="
        return 1  # No limit cached
    fi
}

# Set a shape limit state in the cache
set_cached_limit_state() {
    local shape="$1" 
    local limit_reached="$2"  # "true" or "false"
    local state_file
    state_file=$(get_state_file_path "${3:-}")
    
    # Determine limit field based on shape
    local limit_field
    case "$shape" in
        "VM.Standard.E2.1.Micro")
            limit_field="e2_limit_reached"
            ;;
        "VM.Standard.A1.Flex")
            limit_field="a1_limit_reached"
            ;;
        *)
            log_warning "限额设置的未知形状: $shape"
            return 1
            ;;
    esac
    
    # Ensure state file exists
    load_state "$state_file" >/dev/null
    
    # Update the limit state
    local timestamp temp_file
    timestamp=$(date +%s)
    temp_file=$(mktemp)
    
    if jq --arg field "$limit_field" \
          --arg value "$limit_reached" \
          --arg timestamp "$timestamp" \
          '.limits[$field] = ($value == "true") | 
           .limits.last_limit_check = ($timestamp | tonumber) |
           .updated = ($timestamp | tonumber)' \
          "$state_file" > "$temp_file"; then
        mv "$temp_file" "$state_file"
        log_debug "已更新缓存限额状态: $shape -> $limit_reached"
    else
        rm -f "$temp_file"
        log_error "更新缓存限额状态失败: $shape"
        return 1
    fi
    
    # Save to cache if in GitHub Actions
    save_state_to_cache "$state_file"
}

# Clear all cached limit states (useful for testing or manual reset)
clear_cached_limit_states() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    
    # Ensure state file exists
    load_state "$state_file" >/dev/null
    
    local timestamp temp_file
    timestamp=$(date +%s)
    temp_file=$(mktemp)
    
    if jq --arg timestamp "$timestamp" \
          '.limits.e2_limit_reached = false |
           .limits.a1_limit_reached = false |
           .limits.last_limit_check = ($timestamp | tonumber) |
           .updated = ($timestamp | tonumber)' \
          "$state_file" > "$temp_file"; then
        mv "$temp_file" "$state_file"
        log_info "已清除所有缓存限额状态"
    else
        rm -f "$temp_file"
        log_error "清除缓存限额状态失败"
        return 1
    fi
    
    # Save to cache if in GitHub Actions
    save_state_to_cache "$state_file"
}

# Get comprehensive limit status summary
get_limit_status() {
    local state_file
    state_file=$(get_state_file_path "${1:-}")
    
    if [[ ! -f "$state_file" ]]; then
        echo "No limit state available"
        return 1
    fi
    
    # Check if limits section exists
    if ! jq -e '.limits' "$state_file" >/dev/null 2>&1; then
        echo "No limit data in state file"
        return 1
    fi
    
    echo "=== Free Tier Limit Status ==="
    
    local e2_limit a1_limit last_check ttl_hours
    e2_limit=$(jq -r '.limits.e2_limit_reached // false' "$state_file")
    a1_limit=$(jq -r '.limits.a1_limit_reached // false' "$state_file")
    last_check=$(jq -r '.limits.last_limit_check // 0' "$state_file")
    ttl_hours=$(jq -r '.limits.ttl_hours // 24' "$state_file")
    
    # Convert timestamp for display
    local last_check_readable
    if [[ "$last_check" =~ ^[0-9]+$ ]] && [[ "$last_check" != "0" ]]; then
        last_check_readable=$(format_timestamp "$last_check")
    else
        last_check_readable="Never"
    fi
    
    echo "E2.1.Micro limit: $([[ "$e2_limit" == "true" ]] && echo "REACHED (2/2)" || echo "Available")"
    echo "A1.Flex limit: $([[ "$a1_limit" == "true" ]] && echo "REACHED (4/4 OCPUs)" || echo "Available")"
    echo "Last check: $last_check_readable"
    echo "Cache TTL: ${ttl_hours} hours"
    
    # Check if cache is expired
    local current_time
    current_time=$(date +%s)
    if [[ $((current_time - last_check)) -gt $((ttl_hours * 3600)) ]]; then
        echo "⚠ Limit cache is expired - will be rechecked on next creation attempt"
    else
        echo "✓ Limit cache is current"
    fi
}

# =============================================================================
# COMMAND LINE INTERFACE
# =============================================================================

# Main function for command-line usage
main() {
    case "${1:-}" in
        "init")
            init_state_manager "${2:-}"
            ;;
        "check")
            local instance_name="${2:-}"
            if [[ -z "$instance_name" ]]; then
                echo "Usage: $0 check <instance_name> [state_file]" >&2
                exit 1
            fi
            if should_create_instance "$instance_name" "${3:-}"; then
                echo "CREATE"
                exit 0
            else
                echo "SKIP"
                exit 1
            fi
            ;;
        "record")
            local instance_name="${2:-}"
            local ocid="${3:-}"
            if [[ -z "$instance_name" || -z "$ocid" ]]; then
                echo "Usage: $0 record <instance_name> <ocid> [state_file]" >&2
                exit 1
            fi
            record_instance_creation "$instance_name" "$ocid" "${4:-}"
            ;;
        "verify")
            local instance_name="${2:-}"
            local ocid="${3:-}"
            local status="${4:-verified}"
            if [[ -z "$instance_name" || -z "$ocid" ]]; then
                echo "Usage: $0 verify <instance_name> <ocid> [status] [state_file]" >&2
                exit 1
            fi
            record_instance_verification "$instance_name" "$ocid" "$status" "${5:-}"
            ;;
        "print")
            print_state "${2:-}"
            ;;
        "cleanup")
            cleanup_state_manager "${2:-}"
            ;;
        "stats")
            get_cache_stats
            ;;
        "health")
            check_cache_health
            ;;
        "purge")
            echo "WARNING: This will delete all cached data and reset statistics."
            if [[ "${2:-}" == "--confirm" ]]; then
                purge_cache
            else
                echo "To confirm, run: $0 purge --confirm"
                exit 1
            fi
            ;;
        "verify-config")
            local instance_id="${2:-}"
            local expected_shape="${3:-}"
            local expected_ocpus="${4:-}"
            local expected_memory="${5:-}"
            if [[ -z "$instance_id" || -z "$expected_shape" ]]; then
                echo "Usage: $0 verify-config <instance_id> <expected_shape> [expected_ocpus] [expected_memory]" >&2
                exit 1
            fi
            verify_instance_configuration "$instance_id" "$expected_shape" "$expected_ocpus" "$expected_memory"
            ;;
        "check-limit")
            local shape="${2:-}"
            if [[ -z "$shape" ]]; then
                echo "Usage: $0 check-limit <shape> [state_file]" >&2
                exit 1
            fi
            if get_cached_limit_state "$shape" "${3:-}"; then
                echo "LIMIT_REACHED"
                exit 0
            else
                echo "AVAILABLE"
                exit 1
            fi
            ;;
        "set-limit")
            local shape="${2:-}"
            local limit_reached="${3:-}"
            if [[ -z "$shape" || -z "$limit_reached" ]]; then
                echo "Usage: $0 set-limit <shape> <true|false> [state_file]" >&2
                exit 1
            fi
            if [[ "$limit_reached" != "true" && "$limit_reached" != "false" ]]; then
                echo "Error: limit_reached must be 'true' or 'false'" >&2
                exit 1
            fi
            set_cached_limit_state "$shape" "$limit_reached" "${4:-}"
            ;;
        "clear-limits")
            clear_cached_limit_states "${2:-}"
            ;;
        "limit-status")
            get_limit_status "${2:-}"
            ;;
        *)
            echo "Usage: $0 {init|check|record|verify|print|cleanup|stats|health|purge|verify-config|check-limit|set-limit|clear-limits|limit-status} [args...]" >&2
            echo ""
            echo "State Management:"
            echo "  init [state_file]                           - Initialize state manager"
            echo "  check <instance_name> [state_file]          - Check if instance should be created"
            echo "  record <instance_name> <ocid> [state_file]  - Record successful creation"
            echo "  verify <name> <ocid> [status] [state_file]  - Record verification"
            echo "  print [state_file]                          - Print current state"
            echo "  cleanup [state_file]                        - Cleanup temporary files"
            echo ""
            echo "Cache Management:"
            echo "  stats                                       - Show cache statistics"
            echo "  health                                      - Check cache health"
            echo "  purge --confirm                             - Purge cache and reset statistics"
            echo ""
            echo "Limit Management:"
            echo "  check-limit <shape> [state_file]            - Check if shape limit is cached as reached"
            echo "  set-limit <shape> <true|false> [state_file] - Set shape limit state in cache"
            echo "  clear-limits [state_file]                   - Clear all cached limit states"
            echo "  limit-status [state_file]                   - Show comprehensive limit status"
            echo ""
            echo "Configuration Verification:"
            echo "  verify-config <id> <shape> [ocpus] [memory] - Verify instance configuration"
            exit 1
            ;;
    esac
}

# Run main if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
