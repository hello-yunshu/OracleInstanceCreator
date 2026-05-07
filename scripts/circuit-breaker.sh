#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]:-$0}")/utils.sh"

readonly MAX_CONSECUTIVE_FAILURES=3
readonly CIRCUIT_BREAKER_RESET_HOURS=24
readonly AD_FAILURE_DATA_FILE="${AD_FAILURE_DATA_FILE:-ad-failure-data.json}"

_get_failure_data_file() {
    local state_dir="${STATE_DIR:-${GITHUB_WORKSPACE:-$HOME}/.cache/oci-state}"
    echo "${state_dir}/${AD_FAILURE_DATA_FILE}"
}

get_ad_failure_data() {
    local data_file
    data_file=$(_get_failure_data_file)
    
    if [[ -f "$data_file" ]]; then
        local data
        data=$(cat "$data_file" 2>/dev/null || echo "[]")
        if echo "$data" | jq empty 2>/dev/null; then
            echo "$data"
            return 0
        fi
        log_debug "AD 失败数据文件格式无效 - 重置"
    fi
    
    echo "[]"
}

_save_failure_data() {
    local data="$1"
    local data_file
    data_file=$(_get_failure_data_file)
    
    local dir
    dir=$(dirname "$data_file")
    mkdir -p "$dir" 2>/dev/null || true
    
    local temp_file="${data_file}.tmp"
    if echo "$data" > "$temp_file" 2>/dev/null && mv "$temp_file" "$data_file" 2>/dev/null; then
        return 0
    fi
    
    rm -f "$temp_file" 2>/dev/null
    return 1
}

count_configured_ads() {
    local input_ads="$1"
    local count=0

    IFS=',' read -ra ad_array <<< "$input_ads"
    for ad in "${ad_array[@]}"; do
        ad=$(echo "$ad" | xargs)
        [[ -n "$ad" ]] && count=$((count + 1))
    done

    echo "$count"
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
    
    failure_count=$(get_ad_failure_count "$ad")
    
    if [[ $failure_count -lt $MAX_CONSECUTIVE_FAILURES ]]; then
        return 1
    fi
    
    last_failure_time=$(get_ad_last_failure_time "$ad")
    if [[ -n "$last_failure_time" ]]; then
        local current_epoch last_epoch hours_diff
        current_epoch=$(date +%s 2>/dev/null || echo "0")
        
        if [[ "$(uname)" == "Darwin" ]]; then
            last_epoch=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('${last_failure_time}'.replace('Z','+00:00')).timestamp()))" 2>/dev/null) || \
            last_epoch=$(perl -MTime::Local -e 'print Time::Local::timegm(reverse split(/[T:-]/,substr($ARGV[0],0,19)))' "$last_failure_time" 2>/dev/null) || \
            last_epoch=""
        else
            last_epoch=$(date -d "$last_failure_time" +%s 2>/dev/null) || last_epoch=""
        fi
        
        if [[ -n "$last_epoch" && "$last_epoch" =~ ^[0-9]+$ && -n "$current_epoch" && "$current_epoch" -gt 0 ]]; then
            hours_diff=$(( (current_epoch - last_epoch) / 3600 ))
            
            if [[ $hours_diff -ge $CIRCUIT_BREAKER_RESET_HOURS ]]; then
                log_info "AD $ad 熔断器已重置（${hours_diff} 小时后）"
                reset_ad_failures "$ad"
                return 1
            fi
        fi
    fi
    
    log_warning "AD $ad 熔断器开启（连续 ${failure_count} 次失败）"
    return 0
}

increment_ad_failure() {
    local ad="$1"
    local failure_data
    local updated_data
    local current_time

    if [[ -n "${OCI_AD:-}" && "$(count_configured_ads "$OCI_AD")" -le 1 ]]; then
        log_debug "单 AD 配置 - 不记录熔断失败: $ad"
        return 0
    fi
    
    current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u)
    failure_data=$(get_ad_failure_data)
    
    if command -v jq >/dev/null 2>&1; then
        updated_data=$(echo "$failure_data" | jq --arg ad "$ad" --arg time "$current_time" '
            map(if .ad == $ad then .failures += 1 | .last_failure = $time else . end) |
            if any(.ad == $ad) then . else . + [{"ad": $ad, "failures": 1, "last_failure": $time}] end |
            .[-20:]
        ' 2>/dev/null)
        
        if [[ -z "$updated_data" ]]; then
            log_debug "jq 更新失败数据失败 - 创建新记录"
            updated_data="[{\"ad\":\"$ad\",\"failures\":1,\"last_failure\":\"$current_time\"}]"
        fi
    else
        updated_data="[{\"ad\":\"$ad\",\"failures\":1,\"last_failure\":\"$current_time\"}]"
    fi
    
    if _save_failure_data "$updated_data"; then
        log_debug "已更新 AD $ad 的失败数据"
        return 0
    else
        log_debug "AD 失败数据保存失败 - 不影响实例创建"
        return 0
    fi
}

reset_ad_failures() {
    local ad="$1"
    local failure_data
    local updated_data
    
    failure_data=$(get_ad_failure_data)
    
    if command -v jq >/dev/null 2>&1; then
        updated_data=$(echo "$failure_data" | jq --arg ad "$ad" 'map(select(.ad != $ad))' 2>/dev/null)
        
        if [[ -n "$updated_data" ]]; then
            _save_failure_data "$updated_data"
        fi
    fi
}

reset_all_ad_failures() {
    _save_failure_data "[]"
}

get_available_ads() {
    local input_ads="$1"
    local available_ads=""
    local ad_count

    ad_count=$(count_configured_ads "$input_ads")
    if [[ "$ad_count" -le 1 ]]; then
        log_debug "单 AD 配置 - 跳过熔断器过滤"
        echo "$input_ads"
        return 0
    fi
    
    IFS=',' read -ra ad_array <<< "$input_ads"
    
    for ad in "${ad_array[@]}"; do
        ad=$(echo "$ad" | xargs)
        
        if should_skip_ad "$ad"; then
            log_info "跳过 AD ${ad}（熔断器开启）"
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

mark_ad_success() {
    local ad="$1"
    log_debug "标记 AD $ad 为成功 - 重置失败追踪"
    reset_ad_failures "$ad"
}

show_circuit_breaker_status() {
    local failure_data
    local ad_count
    
    failure_data=$(get_ad_failure_data)
    
    if command -v jq >/dev/null 2>&1; then
        ad_count=$(echo "$failure_data" | jq length)
        log_info "熔断器状态: $ad_count 个 AD 有失败追踪记录"
        
        if [[ $ad_count -gt 0 ]]; then
            echo "$failure_data" | jq -r '.[] | "\(.ad): \(.failures) failures, last: \(.last_failure)"' | while read -r line; do
                log_info "  $line"
            done
        fi
    else
        log_info "熔断器状态: jq 不可用，无法显示详细信息"
    fi
}

export -f count_configured_ads
export -f should_skip_ad
export -f increment_ad_failure
export -f mark_ad_success
export -f get_available_ads
export -f show_circuit_breaker_status
