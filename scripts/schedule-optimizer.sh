#!/bin/bash

# Schedule Optimizer - Enhanced scheduling logic with region-aware patterns
# This script provides recommendations for optimal scheduling based on regional patterns

set -euo pipefail

source "$(dirname "$0")/utils.sh"

# Regional scheduling patterns based on Oracle Cloud regions
get_regional_pattern() {
    local region="$1"
    case "$region" in
        "ap-singapore-1") echo "SGT|UTC+8|10am-3pm 工作日低使用率" ;;
        "ap-mumbai-1") echo "IST|UTC+5:30|2pm-5pm 工作日低使用率" ;;
        "ap-sydney-1") echo "AEDT|UTC+11|7am-12pm 工作日低使用率" ;;
        "ap-tokyo-1") echo "JST|UTC+9|11am-4pm 工作日低使用率" ;;
        "ap-seoul-1") echo "KST|UTC+9|11am-4pm 工作日低使用率" ;;
        "us-ashburn-1") echo "EST|UTC-5|2am-7am ET 低使用率" ;;
        "us-phoenix-1") echo "PST|UTC-8|5am-10am PT 低使用率" ;;
        "us-sanjose-1") echo "PST|UTC-8|5am-10am PT 低使用率" ;;
        "eu-frankfurt-1") echo "CET|UTC+1|8am-1pm CET 低使用率" ;;
        "uk-london-1") echo "GMT|UTC+0|7am-12pm GMT 低使用率" ;;
        "eu-amsterdam-1") echo "CET|UTC+1|8am-1pm CET 低使用率" ;;
        "ca-toronto-1") echo "EST|UTC-5|2am-7am ET 低使用率" ;;
        "sa-saopaulo-1") echo "BRT|UTC-3|4am-9am BRT 低使用率" ;;
        *) echo "PST|UTC-8|5am-10am PT 低使用率" ;;
    esac
}

# Get optimal schedule for current region
get_regional_schedule() {
    local region="${OCI_REGION:-us-sanjose-1}"
    local pattern=$(get_regional_pattern "$region")
    
    echo "$pattern"
}

# Generate optimized cron patterns based on region
generate_cron_patterns() {
    local region="${OCI_REGION:-us-sanjose-1}"
    
    log_info "正在为区域生成优化的 cron 模式: $region"
    
    case "$region" in
        # Singapore: Business hours 9am-6pm SGT = 1am-10am UTC
        "ap-singapore-1")
            echo "# 新加坡优化调度"
            echo "# 离峰激进: 2-7am UTC (新加坡时间 10am-3pm - 午餐/低活跃)"
            echo 'schedule_aggressive: "*/15 2-7 * * *"'
            echo "# 高峰保守: 8am-1am UTC (新加坡时间 4pm-9am - 避开高峰)"
            echo 'schedule_conservative: "0 8-23,0-1 * * *"'
            echo "# 周末增强: 1-6am UTC 周末 (新加坡时间 9am-2pm - 低需求)"
            echo 'schedule_weekend: "*/20 1-6 * * 6,0"'
            ;;
        
        # Mumbai: Business hours 9am-6pm IST = 3:30am-12:30pm UTC
        "ap-mumbai-1")
            echo "# 孟买优化调度"
            echo "# 离峰激进: 13-18 UTC (IST 6:30pm-11:30pm - 晚间低谷)"
            echo 'schedule_aggressive: "*/15 13-18 * * *"'
            echo "# 高峰保守: 其他时段"
            echo 'schedule_conservative: "0 19-23,0-12 * * *"'
            echo 'schedule_weekend: "*/20 1-6 * * 6,0"'
            ;;
            
        # US East: Business hours 9am-6pm EST = 2pm-11pm UTC  
        "us-east-1"|"ca-central-1")
            echo "# 美东优化调度"
            echo "# 离峰激进: 6-12 UTC (EST 1am-7am - 夜间时段)"
            echo 'schedule_aggressive: "*/15 6-12 * * *"'
            echo "# 高峰保守: 13-5 UTC (EST 8am-12am - 避开工作/晚间)"
            echo 'schedule_conservative: "0 13-23,0-5 * * *"'
            echo 'schedule_weekend: "*/20 6-11 * * 6,0"'
            ;;
            
        # US West (San Jose/Phoenix): Business hours 9am-6pm PST = 5pm-2am UTC
        "us-sanjose-1"|"us-phoenix-1")
            echo "# 美西优化调度"
            echo "# 离峰激进: 13-20 UTC (PST 5am-12pm - 早晨低谷)"
            echo 'schedule_aggressive: "*/15 13-20 * * *"'
            echo "# 高峰保守: 21-12 UTC (PST 1pm-4am - 避开工作/晚间)"
            echo 'schedule_conservative: "0 21-23,0-12 * * *"'
            echo 'schedule_weekend: "*/20 13-19 * * 6,0"'
            ;;
            
        # Europe: Business hours 9am-6pm CET = 8am-5pm UTC
        "eu-frankfurt-1"|"eu-amsterdam-1")
            echo "# 欧洲 CET 优化调度"
            echo "# 离峰激进: 18-23 UTC (CET 7pm-12am - 晚间低谷)"
            echo 'schedule_aggressive: "*/15 18-23 * * *"'
            echo "# 高峰保守: 0-17 UTC (CET 1am-6pm - 避开工作时间)"
            echo 'schedule_conservative: "0 0-7,9-17 * * *"'
            echo 'schedule_weekend: "*/20 18-23 * * 6,0"'
            ;;
            
        *)
            log_warning "未知区域 $region，使用美西默认值"
            echo "# 默认美西优化调度"
            echo 'schedule_aggressive: "*/15 2-7 * * *"'
            echo 'schedule_conservative: "0 8-23,0-1 * * *"'
            echo 'schedule_weekend: "*/20 1-6 * * 6,0"'
            ;;
    esac
}

# Calculate expected monthly usage with current patterns
calculate_monthly_usage() {
    local aggressive_pattern="$1"
    local conservative_pattern="$2" 
    local weekend_pattern="$3"
    
    # Parse cron patterns to estimate runs per day
    # Aggressive: */15 for 6 hours = 24 runs
    # Conservative: hourly for 18 hours = 18 runs  
    # Weekend: */20 for 6 hours on 2 days = 36 runs per weekend
    
    local weekday_runs=$((24 + 18))  # 42 runs per weekday
    local weekend_runs=36            # 36 runs per weekend (both days)
    
    # Monthly calculation: 
    # ~22 weekdays * 42 runs = 924
    # ~8 weekend days * (36/2) runs = 144
    # Total: ~1068 runs/month = ~1068 minutes (assuming 1 min per run)
    
    local monthly_runs=$((22 * weekday_runs + 4 * weekend_runs))
    local monthly_minutes=$monthly_runs  # Each run bills as 1 minute minimum
    
    echo "预计月度用量: $monthly_runs 次运行 = $monthly_minutes 分钟"
    
    if [[ $monthly_minutes -lt 2000 ]]; then
        echo "✅ 在免费额度内（2000 分钟）"
        echo "剩余缓冲: $((2000 - monthly_minutes)) 分钟"
    else
        echo "❌ 超出免费额度 $((monthly_minutes - 2000)) 分钟"
    fi
}

# Recommend schedule adjustments based on success patterns
recommend_adjustments() {
    log_info "=== 调度优化建议 ==="
    
    # Get current regional pattern
    local regional_info=$(get_regional_schedule)
    IFS='|' read -r timezone utc_offset optimal_window <<< "$regional_info"
    
    log_info "区域: ${OCI_REGION:-ap-singapore-1}"
    log_info "时区: $timezone ($utc_offset)"
    log_info "最优窗口: $optimal_window"
    
    # Generate optimized cron patterns
    log_info ""
    log_info "=== 优化的 CRON 模式 ==="
    generate_cron_patterns
    
    # Calculate usage estimates
    log_info ""
    log_info "=== 月度使用估算 ==="
    calculate_monthly_usage "*/15 2-7 * * *" "0 8-23,0-1 * * *" "*/20 1-6 * * 6,0"
    
    # Pattern-based recommendations
    log_info ""
    log_info "=== 自适应建议 ==="
    
    if [[ -n "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
        local pattern_data=$(gh variable get SUCCESS_PATTERN_DATA 2>/dev/null || echo "[]")
        
        if command -v jq >/dev/null 2>&1 && [[ "$pattern_data" != "[]" ]]; then
            # Analyze patterns by hour
            local success_hours=$(echo "$pattern_data" | jq -r '[.[] | select(.type == "success")] | group_by(.hour_utc) | .[] | "\(.[0].hour_utc):\(length)"' 2>/dev/null || echo "")
            
            if [[ -n "$success_hours" ]]; then
                log_info "按小时统计的历史成功 (UTC): $success_hours"
                log_info "💡 考虑在成功时段集中尝试"
            else
                log_info "尚无历史成功数据"
            fi
        else
            log_info "模式分析不可用（jq 未安装或无数据）"
        fi
    else
        log_info "模式数据不可用（GitHub CLI 不可用）"
    fi
    
    log_info "================================================"
}

# Main function
main() {
    log_info "=== 调度优化器 ==="
    
    # Show current configuration
    log_info "当前区域: ${OCI_REGION:-ap-singapore-1}"
    log_info "自适应调度: ${ENABLE_ADAPTIVE_SCHEDULING:-true}"
    log_info "区域优化: ${ENABLE_REGION_OPTIMIZATION:-true}"
    
    # Generate recommendations
    recommend_adjustments
    
    log_info "调度优化分析完成"
}

# Run main function if called directly
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    main "$@"
fi