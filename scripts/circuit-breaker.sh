#!/bin/bash

# Circuit breaker pattern for Oracle Cloud Availability Domain failures
# Prevents wasted attempts on consistently failing ADs by tracking failure patterns

source "$(dirname "$0")/utils.sh"
source "$(dirname "$0")/constants.sh"

# Circuit breaker constants
readonly MAX_CONSECUTIVE_FAILURES=3
readonly CIRCUIT_BREAKER_RESET_HOURS=24
readonly AD_FAILURE_DATA_VAR="AD_FAILURE_DATA"

# Track AD failure counts in GitHub variables for persistence
# Data format: JSON array of objects with ad, failures, last_failure_time
# Example: [{"ad":"fgaj:AP-SINGAPORE-1-AD-1","failures":2,"last_failure":"2025-08-26T10:00:00Z"}]

get_ad_failure_data() {
    local failure_data=""
    
    # Try to get existing failure data from GitHub variables
    if command -v gh >/dev/null 2>&1; then
        failure_data=$(gh variable get "$AD_FAILURE_DATA_VAR" 2>/dev/null || echo "[]")
    else
        log_debug "GitHub CLI not available - using empty failure data"
        failure_data="[]"
    fi
    
    # Validate JSON structure
    if ! echo "$failure_data" | jq empty 2>/dev/null; then
        log_warning "Invalid failure data format - resetting to empty array"
        failure_data="[]"
    fi
    
    echo "$failure_data"
}

get_ad_failure_count() {
    local ad="$1"
    local failure_data
    local count=0
    
    failure_data=$(get_ad_failure_data)
    
    if command -v jq >/dev/null 2>&1; then
        count=$(echo "$failure_data" | jq -r ".[] | select(.ad == \"$ad\") | .failures // 0" | head -1)
        [[ -z "$count" ]] && count=0
    fi
    
    echo "$count"
}

get_ad_last_failure_time() {
    local ad="$1"
    local failure_data
    local last_failure=""
    
    failure_data=$(get_ad_failure_data)
    
    if command -v jq >/dev/null 2>&1; then
        last_failure=$(echo "$failure_data" | jq -r ".[] | select(.ad == \"$ad\") | .last_failure // \"\"" | head -1)
    fi
    
    echo "$last_failure"
}

should_skip_ad() {
    local ad="$1"
    local failure_count
    local last_failure_time
    local current_time
    
    failure_count=$(get_ad_failure_count "$ad")
    
    # If failure count is below threshold, don't skip
    if [[ $failure_count -lt $MAX_CONSECUTIVE_FAILURES ]]; then
        return 1  # Don't skip
    fi
    
    # Check if enough time has passed for circuit breaker reset
    last_failure_time=$(get_ad_last_failure_time "$ad")
    if [[ -n "$last_failure_time" ]]; then
        current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u)
        
        # Calculate hours since last failure (simplified check)
        if command -v date >/dev/null 2>&1; then
            local last_epoch current_epoch hours_diff
            if last_epoch=$(date -d "$last_failure_time" +%s 2>/dev/null); then
                current_epoch=$(date +%s 2>/dev/null)
            elif [[ "$(uname)" == "Darwin" ]]; then
                last_epoch=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('${last_failure_time}'.replace('Z','+00:00')).timestamp()))" 2>/dev/null) || \
                last_epoch=$(perl -MTime::Local -e 'print Time::Local::timegm(reverse split(/[T:-]/,substr($ARGV[0],0,19)))' "$last_failure_time" 2>/dev/null)
                current_epoch=$(date +%s 2>/dev/null)
            fi
            if [[ -n "$last_epoch" && -n "$current_epoch" ]]; then
                hours_diff=$(( (current_epoch - last_epoch) / 3600 ))
                
                if [[ $hours_diff -ge $CIRCUIT_BREAKER_RESET_HOURS ]]; then
                    log_info "Circuit breaker reset for AD $ad after ${hours_diff} hours"
                    reset_ad_failures "$ad"
                    return 1  # Don't skip - circuit breaker reset
                fi
            fi
        fi
    fi
    
    log_warning "Circuit breaker OPEN for AD $ad (${failure_count} consecutive failures)"
    return 0  # Skip this AD
}

increment_ad_failure() {
    local ad="$1"
    local failure_data
    local updated_data
    local current_time
    local retry_count=0
    local max_retries=3
    
    current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u)
    failure_data=$(get_ad_failure_data)
    
    if command -v jq >/dev/null 2>&1; then
        # Update or add AD failure record
        updated_data=$(echo "$failure_data" | jq --arg ad "$ad" --arg time "$current_time" '
            map(if .ad == $ad then .failures += 1 | .last_failure = $time else . end) |
            if any(.ad == $ad) then . else . + [{"ad": $ad, "failures": 1, "last_failure": $time}] end |
            .[-20:]  # Keep only last 20 AD records to prevent data size issues
        ' 2>/dev/null)
        
        if [[ -z "$updated_data" ]]; then
            log_warning "Failed to update failure data with jq - creating new record"
            updated_data="[{\"ad\":\"$ad\",\"failures\":1,\"last_failure\":\"$current_time\"}]"
        fi
    else
        # Fallback without jq
        updated_data="[{\"ad\":\"$ad\",\"failures\":1,\"last_failure\":\"$current_time\"}]"
    fi
    
    # Store updated data in GitHub variables with retry logic
    if command -v gh >/dev/null 2>&1; then
        while [[ $retry_count -lt $max_retries ]]; do
            if echo "$updated_data" | gh variable set "$AD_FAILURE_DATA_VAR" --body-file - 2>/dev/null; then
                log_debug "Updated AD failure data for $ad"
                return 0
            else
                retry_count=$((retry_count + 1))
                log_warning "Failed to update AD failure data (attempt $retry_count/$max_retries)"
                sleep 2
            fi
        done
        
        log_error "Failed to persist AD failure data after $max_retries attempts"
        return 1
    else
        log_debug "GitHub CLI not available - failure data not persisted"
        return 0
    fi
}

reset_ad_failures() {
    local ad="$1"
    local failure_data
    local updated_data
    
    failure_data=$(get_ad_failure_data)
    
    if command -v jq >/dev/null 2>&1; then
        # Remove AD from failure tracking
        updated_data=$(echo "$failure_data" | jq --arg ad "$ad" 'map(select(.ad != $ad))' 2>/dev/null)
        
        if [[ -n "$updated_data" ]] && command -v gh >/dev/null 2>&1; then
            if echo "$updated_data" | gh variable set "$AD_FAILURE_DATA_VAR" --body-file - 2>/dev/null; then
                log_info "Reset failure tracking for AD $ad"
            else
                log_warning "Failed to reset AD failure data"
            fi
        fi
    fi
}

reset_all_ad_failures() {
    if command -v gh >/dev/null 2>&1; then
        if echo "[]" | gh variable set "$AD_FAILURE_DATA_VAR" --body-file - 2>/dev/null; then
            log_info "Reset all AD failure tracking data"
        else
            log_warning "Failed to reset all AD failure data"
        fi
    fi
}

# Get list of available ADs with circuit breaker filtering
get_available_ads() {
    local input_ads="$1"  # Comma-separated list of ADs
    local available_ads=""
    
    # Convert comma-separated list to array
    IFS=',' read -ra ad_array <<< "$input_ads"
    
    for ad in "${ad_array[@]}"; do
        # Trim whitespace
        ad=$(echo "$ad" | xargs)
        
        if should_skip_ad "$ad"; then
            log_info "Skipping AD $ad (circuit breaker open)"
            continue
        fi
        
        if [[ -n "$available_ads" ]]; then
            available_ads="${available_ads},$ad"
        else
            available_ads="$ad"
        fi
    done
    
    echo "$available_ads"
}

# Function to be called after successful AD usage
mark_ad_success() {
    local ad="$1"
    log_debug "Marking AD $ad as successful - resetting failure tracking"
    reset_ad_failures "$ad"
}

# Show circuit breaker status for debugging
show_circuit_breaker_status() {
    local failure_data
    local ad_count
    
    failure_data=$(get_ad_failure_data)
    
    if command -v jq >/dev/null 2>&1; then
        ad_count=$(echo "$failure_data" | jq length)
        log_info "Circuit breaker status: $ad_count ADs with failure tracking"
        
        if [[ $ad_count -gt 0 ]]; then
            echo "$failure_data" | jq -r '.[] | "\(.ad): \(.failures) failures, last: \(.last_failure)"' | while read -r line; do
                log_info "  $line"
            done
        fi
    else
        log_info "Circuit breaker status: jq not available for detailed status"
    fi
}

# Export functions for use by other scripts
export -f should_skip_ad
export -f increment_ad_failure
export -f mark_ad_success
export -f get_available_ads
export -f show_circuit_breaker_status