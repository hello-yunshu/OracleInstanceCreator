#!/bin/bash

# Parallel OCI instance launcher script
# Attempts to create both free tier shapes simultaneously:
# - VM.Standard.A1.Flex (ARM): 4 OCPUs, 24GB RAM
# - VM.Standard.E2.1.Micro (AMD): 1 OCPU, 1GB RAM
#
# TELEGRAM NOTIFICATION RULES:
# NOTIFY: Any instance created OR critical failures (auth/config/system)
# SILENT: Zero instances created (capacity/limits/rate limiting)

set -euo pipefail

# shellcheck source=scripts/utils.sh
source "$(dirname "$0")/utils.sh"
# shellcheck source=scripts/notify.sh
source "$(dirname "$0")/notify.sh"
source "$(dirname "$0")/state-manager.sh"

# Global variables for signal handling
PID_A1=""
PID_E2=""
temp_dir=""
A1_VERIFIED=true
E2_VERIFIED=true
SHOULD_LAUNCH_A1=true
SHOULD_LAUNCH_E2=true

# Performance monitoring functions
get_memory_usage() {
    if command -v free >/dev/null 2>&1; then
        # Linux - get used memory in MB
        free -m | awk 'NR==2{printf "%.1f", $3}'
    elif command -v vm_stat >/dev/null 2>&1; then
        # macOS - get used memory in MB
        vm_stat | awk '
        /Pages free/ { free = $3 + 0 }
        /Pages active/ { active = $3 + 0 }
        /Pages inactive/ { inactive = $3 + 0 }
        /Pages wired down/ { wired = $4 + 0 }
        END { printf "%.1f", (active + inactive + wired) * 4096 / 1024 / 1024 }'
    else
        echo "0"
    fi
}

# Track resource contention during parallel execution
track_resource_usage() {
    local phase="$1" # "start", "peak", "end"
    local memory_usage
    memory_usage=$(get_memory_usage)

    # Log resource usage for monitoring
    log_performance_metric "RESOURCE_USAGE" "parallel_execution" "$phase" "1" "Memory=${memory_usage}MB"

    # Store peak usage for analysis
    if [[ "$phase" == "peak" ]]; then
        echo "$memory_usage" >"${temp_dir}/peak_memory_usage" 2>/dev/null || true
    fi
}

# Terminate background processes gracefully then forcefully
terminate_processes() {
    # Graceful termination first
    if [[ -n "$PID_A1" ]] && kill -0 "$PID_A1" 2>/dev/null; then
        log_debug "正在终止 A1 进程 (PID: $PID_A1)"
        kill "$PID_A1" 2>/dev/null || true
    fi
    if [[ -n "$PID_E2" ]] && kill -0 "$PID_E2" 2>/dev/null; then
        log_debug "正在终止 E2 进程 (PID: $PID_E2)"
        kill "$PID_E2" 2>/dev/null || true
    fi
    sleep "$GRACEFUL_TERMINATION_DELAY" # 2-second grace period allows processes to cleanup before SIGKILL

    # Force kill if still running
    if [[ -n "$PID_A1" ]] && kill -0 "$PID_A1" 2>/dev/null; then
        kill -9 "$PID_A1" 2>/dev/null || true
    fi
    if [[ -n "$PID_E2" ]] && kill -0 "$PID_E2" 2>/dev/null; then
        kill -9 "$PID_E2" 2>/dev/null || true
    fi
}

# Signal handler for graceful shutdown
cleanup_handler() {
    log_warning "收到中断信号 - 正在清理后台进程"

    terminate_processes

    # Cleanup temporary files
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf "$temp_dir" 2>/dev/null || true
    fi

    log_info "清理完成"
    exit "$OCI_EXIT_GENERAL_ERROR"
}

# Set up signal handlers
trap cleanup_handler SIGTERM SIGINT

ACTIVE_LIFECYCLE_STATES=(--lifecycle-state MOVING --lifecycle-state PROVISIONING --lifecycle-state RUNNING --lifecycle-state STARTING --lifecycle-state STOPPING --lifecycle-state STOPPED --lifecycle-state CREATING_IMAGE)

get_region_suffix() {
    local region="${OCI_REGION:-}"
    case "$region" in
        ap-singapore-1)  echo "sg" ;;
        ap-tokyo-1)      echo "tk" ;;
        ap-seoul-1)      echo "se" ;;
        ap-osaka-1)      echo "os" ;;
        ap-mumbai-1)     echo "mb" ;;
        ap-hyderabad-1)  echo "hy" ;;
        ap-melbourne-1)  echo "ml" ;;
        ap-sydney-1)     echo "sy" ;;
        us-sanjose-1)    echo "sj" ;;
        us-phoenix-1)    echo "ph" ;;
        us-ashburn-1)    echo "ab" ;;
        us-chicago-1)    echo "ch" ;;
        eu-frankfurt-1)  echo "fr" ;;
        eu-amsterdam-1)  echo "am" ;;
        eu-london-1)     echo "ln" ;;
        eu-zurich-1)     echo "zh" ;;
        sa-saopaulo-1)   echo "sp" ;;
        me-dubai-1)      echo "db" ;;
        me-jeddah-1)     echo "jd" ;;
        ca-montreal-1)   echo "mt" ;;
        ca-toronto-1)    echo "to" ;;
        ap-chuncheon-1)  echo "cc" ;;
        ap-ibaraki-1)    echo "ik" ;;
        *)               echo "${region%%-[0-9]*}" ;;
    esac
}

REGION_SUFFIX=$(get_region_suffix)

# Shape configurations for Oracle Cloud free tier
# shellcheck disable=SC2034  # Used via nameref in launch_shape()
declare -A A1_FLEX_CONFIG=(
    ["SHAPE"]="$A1_FLEX_SHAPE"
    ["OCPUS"]="$A1_FLEX_OCPUS"
    ["MEMORY_IN_GBS"]="$A1_FLEX_MEMORY_GB"
    ["DISPLAY_NAME"]="a1-flex-${REGION_SUFFIX}"
    ["BOOT_VOLUME_ID"]="${A1_BOOT_VOLUME_ID:-${BOOT_VOLUME_ID:-}}"
)

# shellcheck disable=SC2034  # Used via nameref in launch_shape()
declare -A E2_MICRO_CONFIG=(
    ["SHAPE"]="$E2_MICRO_SHAPE"
    ["OCPUS"]=""
    ["MEMORY_IN_GBS"]=""
    ["DISPLAY_NAME"]="e2-micro-${REGION_SUFFIX}"
    ["BOOT_VOLUME_ID"]="${E2_BOOT_VOLUME_ID:-${BOOT_VOLUME_ID:-}}"
)

determine_compartment() {
    local comp_id

    if [[ -z "${OCI_COMPARTMENT_ID:-}" ]]; then
        comp_id="${OCI_TENANCY_OCID:-}"
        if [[ -n "$comp_id" ]]; then
            log_info "使用租户 OCID 作为区间"
        fi
    else
        comp_id="$OCI_COMPARTMENT_ID"
        log_info "使用指定区间"
    fi

    echo "$comp_id"
}

# Verify actual instance existence by querying OCI API
count_actual_instances() {
    local comp_id
    comp_id=$(determine_compartment)
    if [[ -z "$comp_id" ]]; then
        log_debug "OCI_COMPARTMENT_ID 和 OCI_TENANCY_OCID 均不可用 - 无法验证实例数量"
        return 0
    fi
    
    local actual_count=0
    
    # Check A1.Flex instance (only if not skipped)
    if [[ "$SHOULD_LAUNCH_A1" == "true" ]]; then
        local a1_instance_id
        if a1_instance_id=$(oci_cmd compute instance list \
            --compartment-id "$comp_id" \
            --display-name "${A1_FLEX_CONFIG[DISPLAY_NAME]}" \
            "${ACTIVE_LIFECYCLE_STATES[@]}" \
            --query 'data[0].id' \
            --raw-output) && [[ -n "$a1_instance_id" && "$a1_instance_id" != "null" ]]; then
            ((actual_count++))
        fi
    fi
    
    # Check E2.1.Micro instance (only if not skipped)
    if [[ "$SHOULD_LAUNCH_E2" == "true" ]]; then
        local e2_instance_id
        if e2_instance_id=$(oci_cmd compute instance list \
            --compartment-id "$comp_id" \
            --display-name "${E2_MICRO_CONFIG[DISPLAY_NAME]}" \
            "${ACTIVE_LIFECYCLE_STATES[@]}" \
            --query 'data[0].id' \
            --raw-output) && [[ -n "$e2_instance_id" && "$e2_instance_id" != "null" ]]; then
            ((actual_count++))
        fi
    fi
    
    echo "$actual_count"
}

launch_shape() {
    local shape_name="$1"
    local -n config=$2

    log_info "正在启动 $shape_name 创建尝试..."

    # Track shape-specific timing
    local shape_start_time
    shape_start_time=$(date +%s)

    # Set shape-specific environment variables
    export OCI_SHAPE="${config[SHAPE]}"
    export OCI_OCPUS="${config[OCPUS]}"
    export OCI_MEMORY_IN_GBS="${config[MEMORY_IN_GBS]}"
    export INSTANCE_DISPLAY_NAME="${config[DISPLAY_NAME]}"
    if [[ -n "${config[BOOT_VOLUME_ID]:-}" ]]; then
        export BOOT_VOLUME_ID="${config[BOOT_VOLUME_ID]}"
        log_info "使用已有引导卷 $shape_name: ${config[BOOT_VOLUME_ID]}"
    else
        unset BOOT_VOLUME_ID
    fi
    
    # Set instance ID file path for OCID communication
    local shape_key=$(echo "$shape_name" | tr '[:upper:]' '[:lower:]' | tr -d '.')
    export INSTANCE_ID_FILE="${temp_dir}/${shape_key}_instance_id"
    rm -f "$INSTANCE_ID_FILE" 2>/dev/null || true

    # Launch the instance using existing script
    local script_dir
    script_dir="$(dirname "$0")"
    "$script_dir/launch-instance.sh"
    local exit_code=$?

    # Calculate and log shape execution time
    local shape_end_time duration
    shape_end_time=$(date +%s)
    duration=$((shape_end_time - shape_start_time))

    # Log shape performance metrics
    log_performance_metric "SHAPE_DURATION" "$shape_name" "$duration" "$exit_code" "Shape=${config[SHAPE]}"

    # Store duration for analysis (write to temp file if available)
    if [[ -n "${temp_dir:-}" ]]; then
        echo "$duration" >"${temp_dir}/${shape_name,,}_duration" 2>/dev/null || true
    fi

    return $exit_code
}

# Verify instance states and update cache after parallel execution
verify_and_update_state() {
    local status_a1="$1"
    local status_e2="$2"
    local state_file="instance-state.json"
    local verification_errors=0
    
    # Initialize state manager if not already done
    if ! init_state_manager "$state_file" >/dev/null; then
        log_error "状态管理器初始化失败"
        return 1
    fi
    
    # Get the compartment ID for OCI API calls
    local comp_id
    comp_id=$(determine_compartment)
    if [[ -z "$comp_id" ]]; then
        log_error "OCI_COMPARTMENT_ID 和 OCI_TENANCY_OCID 均不可用 - 无法验证实例状态"
        return 2
    fi
    
    verify_instance_exists() {
        local display_name="$1"
        local comp_id="$2"
        local instance_id_file="${3:-}"
        local max_retries=5
        local retry_delay=5
        
        # 优先使用 OCID 直接查询（比 display-name 搜索更可靠）
        if [[ -n "$instance_id_file" && -f "$instance_id_file" ]]; then
            local ocid
            ocid=$(cat "$instance_id_file" 2>/dev/null || echo "")
            if [[ -n "$ocid" && "$ocid" != "null" ]]; then
                log_debug "使用 OCID 直接查询实例: ${ocid:0:30}..."
                for i in $(seq 1 $max_retries); do
                    local state
                    state=$(oci_cmd compute instance get \
                        --instance-id "$ocid" \
                        --query 'data."lifecycle-state"' \
                        --raw-output 2>/dev/null || echo "")
                    
                    if [[ -n "$state" && "$state" != "null" ]]; then
                        log_debug "通过 OCID 找到实例（状态: $state）"
                        echo "$ocid"
                        return 0
                    fi
                    
                    if [[ $i -lt $max_retries ]]; then
                        log_debug "OCID 查询未返回状态，${retry_delay}s 后重试 ($i/$max_retries)..."
                        sleep $retry_delay
                    fi
                done
                log_debug "OCID 直接查询失败，回退到 display-name 搜索"
            fi
        fi
        
        # 回退：使用 display-name 搜索
        local instance_id=""
        for i in $(seq 1 $max_retries); do
            instance_id=$(oci_cmd compute instance list \
                --compartment-id "$comp_id" \
                --display-name "$display_name" \
                --limit 1 \
                --query 'data[0].id' \
                --raw-output 2>/dev/null || echo "")
            
            if [[ -n "$instance_id" && "$instance_id" != "null" ]]; then
                echo "$instance_id"
                return 0
            fi
            
            if [[ $i -lt $max_retries ]]; then
                log_debug "实例 '$display_name' 未找到，${retry_delay}s 后重试 ($i/$max_retries)..."
                sleep $retry_delay
            fi
        done
        
        echo ""
        return 1
    }
    
    # Verify A1.Flex instance state if creation was attempted
    if [[ "$status_a1" -eq 0 && "$SHOULD_LAUNCH_A1" == "true" ]]; then
        local a1_instance_id
        a1_instance_id=$(verify_instance_exists "${A1_FLEX_CONFIG[DISPLAY_NAME]}" "$comp_id" "${temp_dir}/a1flex_instance_id")
        
        if [[ -n "$a1_instance_id" && "$a1_instance_id" != "null" ]]; then
            log_info "已验证 A1.Flex 实例存在: $a1_instance_id"
            A1_VERIFIED=true
            if ! record_instance_verification "${A1_FLEX_CONFIG[DISPLAY_NAME]}" "$a1_instance_id" "verified" "$state_file"; then
                log_warning "记录 A1.Flex 实例验证失败"
                ((verification_errors++))
            fi
        else
            log_warning "A1.Flex 实例创建报告成功但 API 未找到实例 - 降级为容量错误"
            A1_VERIFIED=false
            ((verification_errors++))
        fi
    fi
    
    # Verify E2.Micro instance state if creation was attempted
    if [[ "$status_e2" -eq 0 && "$SHOULD_LAUNCH_E2" == "true" ]]; then
        local e2_instance_id
        e2_instance_id=$(verify_instance_exists "${E2_MICRO_CONFIG[DISPLAY_NAME]}" "$comp_id" "${temp_dir}/e21micro_instance_id")
        
        if [[ -n "$e2_instance_id" && "$e2_instance_id" != "null" ]]; then
            log_info "已验证 E2.Micro 实例存在: $e2_instance_id"
            E2_VERIFIED=true
            if ! record_instance_verification "${E2_MICRO_CONFIG[DISPLAY_NAME]}" "$e2_instance_id" "verified" "$state_file"; then
                log_warning "记录 E2.Micro 实例验证失败"
                ((verification_errors++))
            fi
        else
            log_warning "E2.Micro 实例创建报告成功但 API 未找到实例 - 降级为容量错误"
            E2_VERIFIED=false
            ((verification_errors++))
        fi
    fi
    
    # Log current state for debugging
    if [[ "${DEBUG:-}" == "true" ]]; then
        log_debug "验证后当前实例状态:"
        print_state "$state_file"
    fi
    
    # Return appropriate exit code based on verification results
    if [[ "$verification_errors" -gt 0 ]]; then
        log_warning "实例状态验证完成，有 $verification_errors 个错误"
        return 3  # Return specific code for verification errors (non-critical)
    else
        log_debug "实例状态验证完成"
        return 0
    fi
}

# Get detailed instance information for notifications
get_instance_details() {
    local instance_id="$1"
    local shape_name="$2"
    
    if [[ -z "$instance_id" || "$instance_id" == "null" ]]; then
        return 1
    fi
    
    # Get instance details from OCI API
    local instance_data
    if ! instance_data=$(oci_cmd compute instance get --instance-id "$instance_id" \
        --query 'data.{id:id,shape:shape,ad:availabilityDomain,state:lifecycleState}' \
        --output json 2>/dev/null); then
        log_debug "获取实例 $instance_id 详情失败"
        return 1
    fi
    
    # Get VNIC attachments for IP addresses
    local vnic_data
    if ! vnic_data=$(oci_cmd compute instance list-vnics --instance-id "$instance_id" \
        --query 'data[0].{publicIp:publicIp,privateIp:privateIp}' \
        --output json 2>/dev/null); then
        log_debug "获取实例 $instance_id VNIC 详情失败"
        # Continue without IP info
        vnic_data='{"publicIp":null,"privateIp":null}'
    fi
    
    # Parse the data
    local id shape ad state public_ip private_ip
    id=$(echo "$instance_data" | jq -r '.id // "unknown"')
    shape=$(echo "$instance_data" | jq -r '.shape // "unknown"') 
    ad=$(echo "$instance_data" | jq -r '.ad // "unknown"' | sed 's/.*-AD-/AD-/')
    state=$(echo "$instance_data" | jq -r '.state // "unknown"')
    public_ip=$(echo "$vnic_data" | jq -r '.publicIp // "none"')
    private_ip=$(echo "$vnic_data" | jq -r '.privateIp // "unknown"')
    
    # Format the details
    echo "**${shape_name}** (${shape}):
• ID: ${id}
• Public IP: ${public_ip}
• Private IP: ${private_ip}
• AD: ${ad}
• State: ${state}"
}

# Main parallel execution
main() {
    start_timer "parallel_execution"
    log_info "开始并行创建两种免费层形状的 OCI 实例"

    # Set timeout to prevent exceeding 60 seconds (GitHub Actions billing boundary)
    # Using constant defined in constants.sh for consistency and maintainability
    local timeout_seconds=$GITHUB_ACTIONS_BILLING_TIMEOUT
    log_debug "设置执行超时为 ${timeout_seconds}s 以避免 2 分钟计费"

    # Create temporary files for process communication with secure permissions
    umask 077             # Ensure secure permissions (owner only)
    temp_dir=$(mktemp -d) # Using global variable for cleanup handler
    chmod 700 "$temp_dir" # Explicit directory permissions
    log_debug "已创建安全临时目录: $temp_dir"
    local a1_result="${temp_dir}/a1_result"
    local e2_result="${temp_dir}/e2_result"

    # Pre-create result files with secure permissions
    touch "$a1_result" "$e2_result"
    chmod 600 "$a1_result" "$e2_result"

    # Track resource usage at start of parallel execution
    track_resource_usage "start"

    # Smart shape filtering: Check cached limit states to prevent futile API calls
    local state_file="instance-state.json"
    SHOULD_LAUNCH_A1=true
    SHOULD_LAUNCH_E2=true
    
    # Check SKIP_SHAPES environment variable (comma-separated: "E2" or "A1" or "E2,A1")
    local skip_shapes="${SKIP_SHAPES:-E2}"
    if [[ -n "$skip_shapes" ]]; then
        IFS=',' read -ra skip_list <<< "$skip_shapes"
        for shape in "${skip_list[@]}"; do
            local shape_upper=$(echo "$shape" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
            case "$shape_upper" in
                E2|E2.*|MICRO|AMD)
                    SHOULD_LAUNCH_E2=false
                    log_info "E2.1.Micro: 已通过 SKIP_SHAPES 跳过"
                    echo "$OCI_EXIT_USER_LIMIT_ERROR" >"$e2_result"
                    ;;
                A1|A1.*|FLEX|ARM)
                    SHOULD_LAUNCH_A1=false
                    log_info "A1.Flex: 已通过 SKIP_SHAPES 跳过"
                    echo "$OCI_EXIT_USER_LIMIT_ERROR" >"$a1_result"
                    ;;
            esac
        done
    fi
    
    # Initialize state manager to ensure state file exists
    if ! init_state_manager "$state_file" >/dev/null; then
        log_warning "状态管理器初始化失败，继续尝试所有形状"
    else
        # Check A1.Flex limit state
        if get_cached_limit_state "${A1_FLEX_CONFIG[SHAPE]}" "$state_file"; then
            SHOULD_LAUNCH_A1=false
            log_info "A1.Flex: 缓存限额已达 - 跳过创建尝试"
            echo "$OCI_EXIT_USER_LIMIT_ERROR" >"$a1_result"
        else
            log_debug "A1.Flex: 无缓存限额 - 继续创建尝试"
        fi
        
        # Check E2.Micro limit state  
        if get_cached_limit_state "${E2_MICRO_CONFIG[SHAPE]}" "$state_file"; then
            SHOULD_LAUNCH_E2=false
            log_info "E2.1.Micro: 缓存限额已达 - 跳过创建尝试"
            echo "$OCI_EXIT_USER_LIMIT_ERROR" >"$e2_result"
        else
            log_debug "E2.1.Micro: 无缓存限额 - 继续创建尝试"
        fi
        
        # Early exit if both shapes are at cached limits
        if [[ "$SHOULD_LAUNCH_A1" == false && "$SHOULD_LAUNCH_E2" == false ]]; then
            log_info "两种形状均达缓存限额 - 无需创建尝试"
            log_info "请考虑管理现有实例以释放容量，或等待限额缓存过期"
            # Clean up temporary files
            rm -rf "$temp_dir" 2>/dev/null || true
            return 0  # Success - no work needed due to limits
        fi
    fi

    # Launch A1.Flex in background (if not skipped due to cached limits)
    if [[ "$SHOULD_LAUNCH_A1" == true ]]; then
        log_info "正在后台启动 A1.Flex (ARM) 实例..."
        (
            # Capture both exit code and any error output
            set -o pipefail
            local exit_code=0
            if ! launch_shape "A1.Flex" A1_FLEX_CONFIG; then
                exit_code=$?
                log_debug "A1.Flex launch_shape 返回退出码: $exit_code"
            fi
            
            # Ensure result file is written atomically
            local temp_result="${a1_result}.tmp"
            echo "$exit_code" > "$temp_result"
            mv "$temp_result" "$a1_result"
            
            log_debug "A1.Flex 后台进程写入退出码 $exit_code 到结果文件"
            # Small delay to ensure file system flush
            sleep 0.1
            exit $exit_code
        ) &
        PID_A1=$!
        log_debug "A1.Flex 后台进程已启动，PID: $PID_A1"
    else
        log_debug "跳过 A1.Flex 启动 - 缓存限额状态"
        PID_A1=""
    fi

    # Launch E2.Micro in background (if not skipped due to cached limits)
    if [[ "$SHOULD_LAUNCH_E2" == true ]]; then
        log_info "正在后台启动 E2.1.Micro (AMD) 实例..."
        (
            # Capture both exit code and any error output
            set -o pipefail
            local exit_code=0
            if ! launch_shape "E2.1.Micro" E2_MICRO_CONFIG; then
                exit_code=$?
                log_debug "E2.1.Micro launch_shape 返回退出码: $exit_code"
            fi
            
            # Ensure result file is written atomically
            local temp_result="${e2_result}.tmp"
            echo "$exit_code" > "$temp_result"
            mv "$temp_result" "$e2_result"
            
            log_debug "E2.1.Micro 后台进程写入退出码 $exit_code 到结果文件"
            # Small delay to ensure file system flush
            sleep 0.1
            exit $exit_code
        ) &
        PID_E2=$!
        log_debug "E2.1.Micro 后台进程已启动，PID: $PID_E2"
    else
        log_debug "跳过 E2.1.Micro 启动 - 缓存限额状态"
        PID_E2=""
    fi

    # Log concurrent execution start
    log_performance_metric "CONCURRENT_START" "parallel_execution" "1" "2" "A1_PID=$PID_A1,E2_PID=$PID_E2"

    # Wait for both processes to complete with timeout
    log_info "等待两种形状尝试完成（超时: ${timeout_seconds}s）..."

    # Initialize status variables
    local STATUS_A1=1
    local STATUS_E2=1

    # Wait for both processes with timeout protection
    local elapsed=0
    # Process monitoring interval - 1 second for responsive detection without excessive CPU usage
    local sleep_interval=1

    # Keep checking until timeout or both processes complete
    while [[ $elapsed -lt $timeout_seconds ]]; do
        # Check if both processes have finished (handle empty PIDs for skipped shapes)
        local a1_running=false
        local e2_running=false
        
        if [[ -n "$PID_A1" ]] && kill -0 "$PID_A1" 2>/dev/null; then
            a1_running=true
        fi
        if [[ -n "$PID_E2" ]] && kill -0 "$PID_E2" 2>/dev/null; then
            e2_running=true
        fi
        
        if [[ "$a1_running" == false && "$e2_running" == false ]]; then
            log_debug "两个进程均已完成（或已跳过），耗时 ${elapsed}s"
            break
        fi

        # Track peak resource usage during execution (every 5 seconds to avoid overhead)
        if [[ $((elapsed % 5)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            track_resource_usage "peak"
        fi

        sleep $sleep_interval
        ((elapsed += sleep_interval))
    done

    # Always wait for processes to fully complete and flush their output (handle empty PIDs)
    local a1_wait_result=0
    local e2_wait_result=0
    
    if [[ -n "$PID_A1" ]]; then
        log_debug "等待 A1.Flex 进程 (PID: $PID_A1) 完成"
        wait $PID_A1 2>/dev/null || a1_wait_result=$?
        log_debug "A1.Flex 进程等待完成，结果: $a1_wait_result"
    fi
    if [[ -n "$PID_E2" ]]; then
        log_debug "等待 E2.1.Micro 进程 (PID: $PID_E2) 完成"
        wait $PID_E2 2>/dev/null || e2_wait_result=$?
        log_debug "E2.1.Micro 进程等待完成，结果: $e2_wait_result"
    fi

    # Additional wait to ensure file system consistency after process completion
    sleep 0.2

    # Wait for result files with proper timeout (fixes race condition)
    if wait_for_result_file "$a1_result"; then
        STATUS_A1=$(cat "$a1_result" 2>/dev/null || echo "1")
        log_debug "A1 结果文件已找到，状态: $STATUS_A1"
        # Validate the status is numeric
        if [[ ! "$STATUS_A1" =~ ^[0-9]+$ ]]; then
            log_warning "A1 结果文件包含无效状态 '$STATUS_A1'，使用失败状态"
            STATUS_A1=1
        fi
    else
        log_warning "A1 结果文件未找到 - 使用等待结果或默认失败状态"
        STATUS_A1=${a1_wait_result:-1}
    fi

    if wait_for_result_file "$e2_result"; then
        STATUS_E2=$(cat "$e2_result" 2>/dev/null || echo "1")
        log_debug "E2 结果文件已找到，状态: $STATUS_E2"
        # Validate the status is numeric
        if [[ ! "$STATUS_E2" =~ ^[0-9]+$ ]]; then
            log_warning "E2 结果文件包含无效状态 '$STATUS_E2'，使用失败状态"
            STATUS_E2=1
        fi
    else
        log_warning "E2 结果文件未找到 - 使用等待结果或默认失败状态"
        STATUS_E2=${e2_wait_result:-1}
    fi
    # Handle timeout case - architecture-aware approach respecting smart shape filtering
    if [[ $elapsed -ge $timeout_seconds ]]; then
        log_warning "执行超时（${timeout_seconds}s）- 正在终止后台进程"
        terminate_processes
        
        # Only apply timeout errors to shapes that were actually launched and have generic error codes
        # This preserves capacity/limit error codes (2, 5) which indicate expected Oracle Cloud behavior
        if [[ "$SHOULD_LAUNCH_A1" == true ]]; then
            # Only override if no specific error code was already captured
            if [[ $STATUS_A1 -eq 1 ]]; then
                STATUS_A1=$OCI_EXIT_TIMEOUT
                log_debug "A1 超时已应用（已启动，无特定错误码）"
            else
                log_debug "A1 超时但保留错误码 $STATUS_A1（容量/限额检测）"
            fi
        else
            log_debug "A1 已因缓存限额跳过 - 无需超时处理"
        fi
        
        if [[ "$SHOULD_LAUNCH_E2" == true ]]; then
            # Only override if no specific error code was already captured
            if [[ $STATUS_E2 -eq 1 ]]; then
                STATUS_E2=$OCI_EXIT_TIMEOUT
                log_debug "E2 超时已应用（已启动，无特定错误码）"
            else
                log_debug "E2 超时但保留错误码 $STATUS_E2（容量/限额检测）"
            fi
        else
            log_debug "E2 已因缓存限额跳过 - 无需超时处理"
        fi
    fi
    
    # Verify and update state for both instances (if state management enabled)
    # Only verify when instances were actually attempted (not cache hits)
    if [[ "${CACHE_ENABLED:-true}" == "true" ]]; then
        local should_verify=false
        
        # Only verify if at least one instance reported success (status 0)
        # Verification is to check if successful instances actually exist in OCI
        if [[ $STATUS_A1 -eq 0 || $STATUS_E2 -eq 0 ]]; then
            should_verify=true
            log_debug "需要验证 - 至少一个实例报告成功"
        fi
        
        # Also verify if execution took a reasonable amount of time (not instant cache hit)
        # This handles edge cases where rapid failures might indicate cache issues
        if [[ $elapsed -gt 2 && ($STATUS_A1 -ne 0 || $STATUS_E2 -ne 0) ]]; then
            should_verify=true  
            log_debug "需要验证 - 非瞬时执行且有失败"
        fi
        
        if [[ "$should_verify" == "true" ]]; then
            log_info "正在验证实例状态并更新缓存..."
            # Capture but don't propagate verification errors - they're non-critical
            if ! verify_and_update_state "$STATUS_A1" "$STATUS_E2"; then
                log_warning "实例状态验证遇到问题但继续执行"
            fi
        else
            log_debug "跳过验证 - 无成功实例需要验证"
        fi
    fi
    # Collect shape-specific durations for analysis (before cleanup)
    local a1_duration=0 e2_duration=0 peak_memory=0
    if [[ -n "${temp_dir:-}" && -f "${temp_dir}/a1.flex_duration" ]]; then
        a1_duration=$(cat "${temp_dir}/a1.flex_duration" 2>/dev/null || echo "0")
    fi
    if [[ -n "${temp_dir:-}" && -f "${temp_dir}/e2.1.micro_duration" ]]; then
        e2_duration=$(cat "${temp_dir}/e2.1.micro_duration" 2>/dev/null || echo "0")
    fi
    if [[ -n "${temp_dir:-}" && -f "${temp_dir}/peak_memory_usage" ]]; then
        peak_memory=$(cat "${temp_dir}/peak_memory_usage" 2>/dev/null || echo "0")
    fi

    # Cleanup temporary files (after data collection)
    if [[ -n "${temp_dir:-}" && -d "${temp_dir:-}" ]]; then
        rm -rf "$temp_dir" 2>/dev/null || true
    fi

    # Downgrade statuses based on verification results
    # If a shape reported success but verification couldn't find the instance,
    # it means the instance was never actually created - downgrade to capacity error
    if [[ $STATUS_A1 -eq 0 && "$A1_VERIFIED" == "false" ]]; then
        log_warning "A1.Flex 验证失败 - 将状态从成功降级为容量不足"
        STATUS_A1=$OCI_EXIT_CAPACITY_ERROR
    fi
    if [[ $STATUS_E2 -eq 0 && "$E2_VERIFIED" == "false" ]]; then
        log_warning "E2.1.Micro 验证失败 - 将状态从成功降级为容量不足"
        STATUS_E2=$OCI_EXIT_CAPACITY_ERROR
    fi

    # Log results
    if [[ $STATUS_A1 -eq 0 ]]; then
        log_success "A1.Flex (ARM) 实例创建: 成功"
    elif [[ $STATUS_A1 -eq 124 ]]; then
        log_warning "A1.Flex (ARM) 实例创建: 超时"
    else
        log_warning "A1.Flex (ARM) 实例创建: 失败"
    fi

    if [[ $STATUS_E2 -eq 0 ]]; then
        log_success "E2.1.Micro (AMD) 实例创建: 成功"
    elif [[ $STATUS_E2 -eq 124 ]]; then
        log_warning "E2.1.Micro (AMD) 实例创建: 超时"
    else
        log_warning "E2.1.Micro (AMD) 实例创建: 失败"
    fi

    # Determine overall result
    local success_count=0
    [[ $STATUS_A1 -eq 0 ]] && success_count=$((success_count + 1))
    [[ $STATUS_E2 -eq 0 ]] && success_count=$((success_count + 1))

    # Check different types of failures for intelligent handling
    local capacity_failures=0
    local user_limit_failures=0
    local rate_limit_failures=0
    
    # Count capacity-related failures (exit code 2 = OCI_EXIT_CAPACITY_ERROR)
    [[ $STATUS_A1 -eq 2 ]] && capacity_failures=$((capacity_failures + 1))
    [[ $STATUS_E2 -eq 2 ]] && capacity_failures=$((capacity_failures + 1))
    
    # Count user limit failures (exit code 5 = OCI_EXIT_USER_LIMIT_ERROR)
    [[ $STATUS_A1 -eq 5 ]] && user_limit_failures=$((user_limit_failures + 1))
    [[ $STATUS_E2 -eq 5 ]] && user_limit_failures=$((user_limit_failures + 1))
    
    # Count rate limit failures (exit code 6 = OCI_EXIT_RATE_LIMIT_ERROR)
    [[ $STATUS_A1 -eq 6 ]] && rate_limit_failures=$((rate_limit_failures + 1))
    [[ $STATUS_E2 -eq 6 ]] && rate_limit_failures=$((rate_limit_failures + 1))

    log_elapsed "parallel_execution"

    # Track final resource usage and collect detailed performance summary
    track_resource_usage "end"

    # Log comprehensive execution summary
    local performance_summary="ExecutionTime=${elapsed}s,A1Duration=${a1_duration}s,E2Duration=${e2_duration}s"
    performance_summary="${performance_summary},PeakMemory=${peak_memory}MB,SuccessRate=${success_count}/2"
    log_performance_metric "CONCURRENT_END" "parallel_execution" "$success_count" "2" "$performance_summary"

    # Log structured performance data for analysis
    if [[ "${LOG_FORMAT:-}" == "json" ]]; then
        local performance_context="{\"total_duration\":${elapsed},\"a1_duration\":${a1_duration}"
        performance_context="${performance_context},\"e2_duration\":${e2_duration},\"peak_memory\":${peak_memory}"
        local parallel_efficiency=0
        local total_shape_duration=$((a1_duration + e2_duration))
        if [[ $total_shape_duration -gt 0 && $elapsed -gt 0 ]]; then
            parallel_efficiency=$((total_shape_duration * 100 / elapsed))
        fi
        performance_context="${performance_context},\"success_count\":${success_count},\"parallel_efficiency\":${parallel_efficiency}}"
        log_with_context "info" "Parallel execution performance summary" "$performance_context"
    fi

    # Verify actual instances exist before claiming success
    local actual_instances
    actual_instances=$(count_actual_instances)
    
    if [[ $actual_instances -gt 0 ]]; then
        log_success "并行执行完成: $actual_instances/2 个实例实际存在且运行中"

        # Instance hunting success: notify for ANY created instances with details
        if [[ "${ENABLE_NOTIFICATIONS:-}" == "true" ]]; then
            local comp_id
            comp_id=$(determine_compartment)
            
            local notification_details=""
            local shapes_created=""
            
            # Get details for A1.Flex if it exists
            local a1_instance_id
            if [[ -n "$comp_id" ]] && a1_instance_id=$(oci_cmd compute instance list \
                --compartment-id "$comp_id" \
                --display-name "${A1_FLEX_CONFIG[DISPLAY_NAME]}" \
                --limit 1 \
                --query 'data[0].id' \
                --raw-output) && [[ -n "$a1_instance_id" && "$a1_instance_id" != "null" ]]; then
                shapes_created="A1.Flex (ARM)"
                if a1_details=$(get_instance_details "$a1_instance_id" "A1.Flex (ARM)" 2>/dev/null); then
                    notification_details="$a1_details"
                fi
            fi
            
            # Get details for E2.Micro if it exists and was not skipped
            if [[ "$SHOULD_LAUNCH_E2" == "true" ]]; then
                local e2_instance_id
                if [[ -n "$comp_id" ]] && e2_instance_id=$(oci_cmd compute instance list \
                    --compartment-id "$comp_id" \
                    --display-name "${E2_MICRO_CONFIG[DISPLAY_NAME]}" \
                    --limit 1 \
                    --query 'data[0].id' \
                    --raw-output) && [[ -n "$e2_instance_id" && "$e2_instance_id" != "null" ]]; then
                    shapes_created="${shapes_created:+$shapes_created, }E2.1.Micro (AMD)"
                    if e2_details=$(get_instance_details "$e2_instance_id" "E2.1.Micro (AMD)" 2>/dev/null); then
                        notification_details="${notification_details:+$notification_details

}$e2_details"
                    fi
                fi
            fi
            
            # Send notification with details if available, fallback to basic info
            if [[ -n "$notification_details" ]]; then
                send_telegram_notification "success" "OCI instance hunting success!

$notification_details"
            else
                send_telegram_notification "success" "OCI instances created: $shapes_created"
            fi
        fi

        return 0
    elif [[ $user_limit_failures -gt 0 && $((user_limit_failures + success_count)) -eq 2 ]]; then
        # User limits reached - this is expected behavior when at free tier limits
        log_info "$user_limit_failures 种形状已达用户限额 - 无需继续尝试"
        log_info "请考虑管理现有实例以释放新部署的容量"
        
        # Notification Policy: NO notifications for user limits
        # User limits are EXPECTED free tier behavior - normal operation
        # Per CLAUDE.md policy: "DO NOT send notifications for User limits reached (expected)"
        
        return 0  # User limits are not failures - they're expected behavior
    elif [[ $rate_limit_failures -gt 0 && $((rate_limit_failures + success_count + capacity_failures + user_limit_failures)) -eq 2 ]]; then
        # Rate limits encountered - this is expected Oracle behavior, no notifications needed
        log_info "$rate_limit_failures 种形状遇到 Oracle API 速率限制 - 将在下次调度运行时重试"
        log_info "这是 Oracle API 在高使用期间的正常行为，会自动恢复"
        
        # Notification Policy: NO notifications for rate limits  
        # Rate limiting is EXPECTED Oracle API behavior during high usage periods
        # Per CLAUDE.md policy: "DO NOT send notifications for Rate limiting (standard behavior)"
        
        return 0  # Rate limits are not failures - they're expected behavior
    elif [[ $capacity_failures -eq 2 ]]; then
        # Both failed due to Oracle capacity constraints - this is expected behavior
        log_info "两种形状因 Oracle 容量限制不可用 - 将在下次调度时重试"
        log_info "这是 Oracle Cloud 容量暂时耗尽时的正常行为"

        # Notification Policy: NO notifications for Oracle capacity constraints
        # Capacity constraints are EXPECTED operational conditions that resolve through retry cycles
        # Per CLAUDE.md policy: "DO NOT send notifications for Oracle capacity unavailable (expected)"
        
        return 0 # Don't treat capacity exhaustion as failure
    elif [[ $((capacity_failures + user_limit_failures + rate_limit_failures)) -eq 2 ]]; then
        # Mixed capacity, limit, and rate limit issues - still expected behavior
        log_info "遇到混合 Oracle 限制 - 将在下次调度时重试"
        log_info "这是 Oracle Cloud 的正常行为 - 容量、限额或速率限制"
        
        # Notification Policy: NO notifications for mixed constraint scenarios
        # These are EXPECTED Oracle operational conditions that resolve through retry cycles
        # Per CLAUDE.md policy: \"DO NOT send notifications for\" expected operational conditions
        
        return 0  # Mixed constraint issues are still expected behavior
    else
        # Analyze and report the specific failure reasons
        local failure_summary=""
        if [[ $STATUS_A1 -ne 0 && $STATUS_A1 -ne 2 && $STATUS_A1 -ne 5 && $STATUS_A1 -ne 6 ]]; then
            failure_summary="A1.Flex failed (exit: $STATUS_A1)"
        fi
        if [[ $STATUS_E2 -ne 0 && $STATUS_E2 -ne 2 && $STATUS_E2 -ne 5 && $STATUS_E2 -ne 6 ]]; then
            if [[ -n "$failure_summary" ]]; then
                failure_summary="$failure_summary, E2.1.Micro failed (exit: $STATUS_E2)"
            else
                failure_summary="E2.1.Micro failed (exit: $STATUS_E2)"
            fi
        fi
        
        if [[ -n "$failure_summary" ]]; then
            log_error "并行执行失败: $failure_summary - 可能是配置或认证错误"
        else
            log_error "并行执行失败: 两种实例创建尝试均失败"
        fi

        # Let individual shape failures handle their own error notifications
        # This prevents duplicate error notifications

        return 1
    fi
}

# Execute main function if script is called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Capture main function exit code to prevent shell configuration from interfering
    main_exit_code=0
    main "$@" || main_exit_code=$?
    
    # Log final exit code for debugging (if DEBUG enabled)
    if [[ "${DEBUG:-}" == "true" ]]; then
        echo "launch-parallel.sh final exit code: $main_exit_code"
        case $main_exit_code in
            0) echo "SUCCESS: All operations completed successfully or expected Oracle constraints" ;;
            2) echo "SUCCESS: Capacity constraints (normal Oracle behavior)" ;;
            5) echo "SUCCESS: User limits reached (expected free tier behavior)" ;;
            6) echo "SUCCESS: Rate limits encountered (expected Oracle API behavior)" ;;
            *) echo "FAILURE: Genuine error requiring attention (exit $main_exit_code)" ;;
        esac
    fi
    
    # Exit with the captured code to preserve correct workflow behavior
    exit $main_exit_code
fi
