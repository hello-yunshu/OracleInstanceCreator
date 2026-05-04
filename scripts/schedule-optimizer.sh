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
        *) echo "SGT|UTC+8|10am-3pm 工作日低使用率" ;;
    esac
}

# Get optimal schedule for current region
get_regional_schedule() {
    local region="${OCI_REGION:-ap-singapore-1}"
    local pattern=$(get_regional_pattern "$region")
    
    echo "$pattern"
}

# Generate optimized cron patterns based on region
generate_cron_patterns() {
    local region="${OCI_REGION:-ap-singapore-1}"
    
    log_info "Generating optimized cron patterns for region: $region"
    
    case "$region" in
        # Singapore: Business hours 9am-6pm SGT = 1am-10am UTC
        "ap-singapore-1")
            echo "# Singapore-optimized schedule"
            echo "# Off-peak aggressive: 2-7am UTC (10am-3pm SGT - lunch/low activity)"
            echo 'schedule_aggressive: "*/15 2-7 * * *"'
            echo "# Peak conservative: 8am-1am UTC (4pm-9am SGT - avoid peak business)" 
            echo 'schedule_conservative: "0 8-23,0-1 * * *"'
            echo "# Weekend boost: 1-6am UTC weekends (9am-2pm SGT - lower demand)"
            echo 'schedule_weekend: "*/20 1-6 * * 6,0"'
            ;;
        
        # Mumbai: Business hours 9am-6pm IST = 3:30am-12:30pm UTC
        "ap-mumbai-1")
            echo "# Mumbai-optimized schedule"
            echo "# Off-peak aggressive: 13-18 UTC (6:30pm-11:30pm IST - evening low)"
            echo 'schedule_aggressive: "*/15 13-18 * * *"'
            echo "# Peak conservative: Other hours"
            echo 'schedule_conservative: "0 19-23,0-12 * * *"'
            echo 'schedule_weekend: "*/20 1-6 * * 6,0"'
            ;;
            
        # US East: Business hours 9am-6pm EST = 2pm-11pm UTC  
        "us-east-1"|"ca-central-1")
            echo "# US East-optimized schedule"
            echo "# Off-peak aggressive: 6-12 UTC (1am-7am EST - night hours)"
            echo 'schedule_aggressive: "*/15 6-12 * * *"'
            echo "# Peak conservative: 13-5 UTC (8am-12am EST - avoid business/evening)"
            echo 'schedule_conservative: "0 13-23,0-5 * * *"'
            echo 'schedule_weekend: "*/20 6-11 * * 6,0"'
            ;;
            
        # Europe: Business hours 9am-6pm CET = 8am-5pm UTC
        "eu-frankfurt-1"|"eu-amsterdam-1")
            echo "# Europe CET-optimized schedule" 
            echo "# Off-peak aggressive: 18-23 UTC (7pm-12am CET - evening low)"
            echo 'schedule_aggressive: "*/15 18-23 * * *"'
            echo "# Peak conservative: 0-17 UTC (1am-6pm CET - avoid business)"
            echo 'schedule_conservative: "0 0-7,9-17 * * *"'
            echo 'schedule_weekend: "*/20 18-23 * * 6,0"'
            ;;
            
        *)
            log_warning "Unknown region $region, using Singapore default"
            echo "# Default Singapore-optimized schedule"
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
    
    echo "Expected monthly usage: $monthly_runs runs = $monthly_minutes minutes"
    
    if [[ $monthly_minutes -lt 2000 ]]; then
        echo "✅ Within free tier limit (2000 minutes)"
        echo "Buffer remaining: $((2000 - monthly_minutes)) minutes"
    else
        echo "❌ Exceeds free tier limit by $((monthly_minutes - 2000)) minutes"
    fi
}

# Recommend schedule adjustments based on success patterns
recommend_adjustments() {
    log_info "=== SCHEDULE OPTIMIZATION RECOMMENDATIONS ==="
    
    # Get current regional pattern
    local regional_info=$(get_regional_schedule)
    IFS='|' read -r timezone utc_offset optimal_window <<< "$regional_info"
    
    log_info "Region: ${OCI_REGION:-ap-singapore-1}"
    log_info "Timezone: $timezone ($utc_offset)"
    log_info "Optimal window: $optimal_window"
    
    # Generate optimized cron patterns
    log_info ""
    log_info "=== OPTIMIZED CRON PATTERNS ==="
    generate_cron_patterns
    
    # Calculate usage estimates
    log_info ""
    log_info "=== MONTHLY USAGE ESTIMATE ==="
    calculate_monthly_usage "*/15 2-7 * * *" "0 8-23,0-1 * * *" "*/20 1-6 * * 6,0"
    
    # Pattern-based recommendations
    log_info ""
    log_info "=== ADAPTIVE RECOMMENDATIONS ==="
    
    if [[ -n "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
        local pattern_data=$(gh variable get SUCCESS_PATTERN_DATA 2>/dev/null || echo "[]")
        
        if command -v jq >/dev/null 2>&1 && [[ "$pattern_data" != "[]" ]]; then
            # Analyze patterns by hour
            local success_hours=$(echo "$pattern_data" | jq -r '[.[] | select(.type == "success")] | group_by(.hour_utc) | .[] | "\(.[0].hour_utc):\(length)"' 2>/dev/null || echo "")
            
            if [[ -n "$success_hours" ]]; then
                log_info "Historical success by hour (UTC): $success_hours"
                log_info "💡 Consider concentrating attempts during successful hours"
            else
                log_info "No historical success data available yet"
            fi
        else
            log_info "Pattern analysis unavailable (jq not installed or no data)"
        fi
    else
        log_info "Pattern data unavailable (GitHub CLI not available)"
    fi
    
    log_info "================================================"
}

# Main function
main() {
    log_info "=== SCHEDULE OPTIMIZER ==="
    
    # Show current configuration
    log_info "Current region: ${OCI_REGION:-ap-singapore-1}"
    log_info "Adaptive scheduling: ${ENABLE_ADAPTIVE_SCHEDULING:-true}"
    log_info "Region optimization: ${ENABLE_REGION_OPTIMIZATION:-true}"
    
    # Generate recommendations
    recommend_adjustments
    
    log_info "Schedule optimization analysis complete"
}

# Run main function if called directly
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    main "$@"
fi