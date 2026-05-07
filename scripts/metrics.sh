#!/bin/bash

# AD Success Rate Metrics Tracking
# Tracks availability domain success/failure rates for optimization

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]:-$0}")/utils.sh"

# Metrics file location (temporary, cleared on each run)
METRICS_FILE="${TMPDIR:-/tmp}/oci_ad_metrics_$$"

# Initialize metrics tracking
init_metrics() {
    # Create temporary metrics file
    echo "# OCI AD Metrics - $(date '+%Y-%m-%d %H:%M:%S')" > "$METRICS_FILE"
    log_debug "已初始化 AD 指标追踪: $METRICS_FILE"
}

# Record AD attempt result
# Parameters:
#   $1: ad_name - Availability domain name
#   $2: result - success|failure
#   $3: error_type - CAPACITY|AUTH|CONFIG|NETWORK|etc (for failures)
record_ad_result() {
    local ad_name="$1"
    local result="$2"
    local error_type="${3:-}"
    local timestamp
    
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Format: timestamp|ad_name|result|error_type
    local entry="${timestamp}|${ad_name}|${result}|${error_type}"
    echo "$entry" >> "$METRICS_FILE"
    
    log_debug "已记录 AD 结果: $ad_name -> $result${error_type:+ ($error_type)}"
}

# Get AD success rate summary
show_ad_metrics() {
    if [[ ! -f "$METRICS_FILE" ]]; then
        log_info "本次运行无 AD 指标数据"
        return
    fi
    
    log_info "=== AD 性能摘要 ==="
    
    # Count results by AD
    local ad_stats
    ad_stats=$(awk -F'|' '
        /^#/ { next }  # Skip comment lines
        {
            ad = $2
            result = $3
            error_type = $4
            
            total[ad]++
            if (result == "success") {
                success[ad]++
            } else {
                failure[ad]++
                error_count[ad "_" error_type]++
            }
        }
        END {
            for (ad in total) {
                succ = success[ad] + 0
                fail = failure[ad] + 0
                rate = (total[ad] > 0) ? int((succ / total[ad]) * 100) : 0
                printf "%s: %d%% success (%d/%d attempts)\n", ad, rate, succ, total[ad]
                
                # Show failure breakdown
                if (fail > 0) {
                    printf "  Failures: "
                    first = 1
                    for (key in error_count) {
                        if (index(key, ad "_") == 1) {
                            error_type = substr(key, length(ad) + 2)
                            if (error_type != "") {
                                if (!first) printf ", "
                                printf "%s(%d)", error_type, error_count[key]
                                first = 0
                            }
                        }
                    }
                    printf "\n"
                }
            }
        }
    ' "$METRICS_FILE")
    
    if [[ -n "$ad_stats" ]]; then
        echo "$ad_stats" | while read -r line; do
            log_info "$line"
        done
    else
        log_info "无 AD 尝试记录"
    fi
}

# Get best performing AD based on historical data
get_optimal_ad() {
    if [[ ! -f "$METRICS_FILE" ]]; then
        echo ""
        return
    fi
    
    # Return AD with highest success rate
    awk -F'|' '
        /^#/ { next }
        {
            ad = $2
            result = $3
            total[ad]++
            if (result == "success") success[ad]++
        }
        END {
            best_ad = ""
            best_rate = -1
            
            for (ad in total) {
                succ = success[ad] + 0
                rate = (total[ad] > 0) ? (succ / total[ad]) : 0
                
                if (rate > best_rate) {
                    best_rate = rate
                    best_ad = ad
                }
            }
            
            print best_ad
        }
    ' "$METRICS_FILE"
}

# Clean up metrics file
cleanup_metrics() {
    if [[ -f "$METRICS_FILE" ]]; then
        rm -f "$METRICS_FILE"
        log_debug "已清理指标文件"
    fi
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    trap cleanup_metrics EXIT
fi

# Record structured performance metrics
record_performance_metric() {
    local metric_type="$1"
    local metric_value="$2"
    local additional_info="${3:-}"
    local timestamp
    
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Structured format for monitoring systems
    local metric_line="PERF_METRIC|${timestamp}|${metric_type}|${metric_value}|${additional_info}"
    
    # Log to both debug and metrics file
    log_debug "$metric_line"
    echo "$metric_line" >> "${METRICS_FILE}_perf"
    
    # Output structured logs for monitoring systems
    if [[ "${LOG_FORMAT:-}" == "json" ]]; then
        local json_context="{\"metric_type\":\"$metric_type\",\"value\":\"$metric_value\""
        [[ -n "$additional_info" ]] && json_context+=",\"info\":\"$additional_info\""
        json_context+="}"
        log_json "performance" "$metric_line" "$json_context"
    fi
}

# Record API response time
record_api_response_time() {
    local operation="$1"
    local response_time_ms="$2"
    local status="${3:-success}"
    
    record_performance_metric "API_RESPONSE_TIME" "$response_time_ms" "$operation:$status"
    
    # Alert on slow responses (>5000ms)
    if [[ "$response_time_ms" -gt 5000 ]]; then
        log_warning "API 响应缓慢: $operation 耗时 ${response_time_ms}ms"
    fi
}

# Record execution phase timing
record_execution_phase() {
    local phase_name="$1"
    local duration_seconds="$2"
    local status="${3:-completed}"
    
    record_performance_metric "EXECUTION_PHASE" "$duration_seconds" "$phase_name:$status"
    
    case "$phase_name" in
        "parallel_execution")
            if [[ "$duration_seconds" -gt 30 ]]; then
                log_warning "并行执行耗时 ${duration_seconds}s（>30s 可能存在问题）"
            fi
            ;;
        "setup")
            if [[ "$duration_seconds" -gt 10 ]]; then
                log_warning "初始化阶段耗时 ${duration_seconds}s（>10s 可能存在网络问题）"
            fi
            ;;
    esac
}

# Generate performance dashboard template
generate_dashboard_template() {
    local output_file="${1:-dashboard_template.yml}"
    
    cat > "$output_file" << 'EOF'
# GitHub Actions Performance Dashboard Template
# Use with monitoring systems like Grafana, DataDog, etc.

metrics:
  parallel_execution_time:
    query: "PERF_METRIC.*parallel_execution"
    alert_threshold: 30  # seconds
    description: "Time taken for parallel instance creation"
    
  api_response_times:
    query: "PERF_METRIC.*API_RESPONSE_TIME"
    alert_threshold: 5000  # milliseconds
    description: "OCI API response times"
    
  ad_success_rates:
    query: "success.*AD-[0-9]+"
    description: "Success rates by availability domain"
    group_by: "availability_domain"
    
  capacity_errors:
    query: "CAPACITY.*error"
    description: "Frequency of capacity errors by time of day"
    group_by: "hour_of_day"

alerts:
  - name: "Slow Execution"
    condition: "parallel_execution_time > 30"
    message: "Parallel execution taking >30s may indicate performance issues"
    
  - name: "High API Latency"
    condition: "api_response_times > 5000"
    message: "OCI API responding slowly (>5s)"
    
  - name: "Low Success Rate"
    condition: "ad_success_rate < 10"
    message: "Very low success rate in availability domain"

dashboard_queries:
  execution_timing:
    title: "Execution Time Trends"
    query: "PERF_METRIC.*EXECUTION_PHASE"
    visualization: "time_series"
    
  error_distribution:
    title: "Error Types Distribution"
    query: "error_type"
    visualization: "pie_chart"
    
  success_rate_by_ad:
    title: "Success Rate by Availability Domain"
    query: "success.*|failure.*"
    group_by: "availability_domain"
    visualization: "bar_chart"
EOF

    log_info "性能仪表板模板已生成: $output_file"
}

# Export all functions for use by other scripts
export -f init_metrics record_ad_result show_ad_metrics get_optimal_ad cleanup_metrics
export -f record_performance_metric record_api_response_time record_execution_phase generate_dashboard_template