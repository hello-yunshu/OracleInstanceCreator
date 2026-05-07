#!/bin/bash

# Stress testing suite for concurrent execution
# Tests system behavior under load with multiple parallel executions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source test utilities and scripts
source "$PROJECT_ROOT/scripts/utils.sh"
source "$PROJECT_ROOT/scripts/constants.sh"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Performance metrics
EXECUTION_TIMES=()
MEMORY_USAGE=()
CPU_USAGE=()

# Get current memory usage in MB
get_memory_usage() {
    if command -v free >/dev/null 2>&1; then
        # Linux
        free -m | awk 'NR==2{printf "%.1f", $3}'
    elif command -v vm_stat >/dev/null 2>&1; then
        # macOS
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

# Get current CPU usage percentage
get_cpu_usage() {
    if command -v top >/dev/null 2>&1; then
        # Get CPU usage using top (works on both Linux and macOS)
        local cpu_usage
        cpu_usage=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ { print $3 }' | sed 's/%//' 2>/dev/null || true)
        echo "${cpu_usage:-0}"
    else
        echo "0"
    fi
}

# Create mock parallel execution script
create_mock_parallel_script() {
    local temp_dir="$1"
    local execution_time="${2:-2}"  # Default 2 second execution
    local failure_rate="${3:-0}"   # Default 0% failure rate
    
    cat > "$temp_dir/mock_parallel.sh" << EOF
#!/bin/bash
set -euo pipefail

# Simulate parallel execution time
sleep_time=\$((RANDOM % $execution_time + 1))

# Simulate memory usage
temp_files=()
for i in {1..10}; do
    temp_file=\$(mktemp)
    # Write some data to simulate memory usage
    dd if=/dev/zero of="\$temp_file" bs=1024 count=100 2>/dev/null
    temp_files+=("\$temp_file")
done

# Cleanup function
cleanup() {
    for file in "\${temp_files[@]}"; do
        rm -f "\$file" 2>/dev/null || true
    done
}

trap cleanup EXIT

# Simulate work
sleep "\$sleep_time"

# Simulate occasional failures based on failure rate
if [[ $failure_rate -gt 0 ]]; then
    if [[ \$((RANDOM % 100)) -lt $failure_rate ]]; then
        echo "Simulated failure" >&2
        exit 1
    fi
fi

# Write result
result_file="\$1/result_\$\$"
echo "SUCCESS:\$(date +%s.%N)" > "\$result_file"
exit 0
EOF
    
    chmod +x "$temp_dir/mock_parallel.sh"
}

# Test multiple concurrent executions
test_concurrent_executions() {
    local test_name="Stress Test: Multiple Concurrent Executions"
    local concurrent_count="${1:-5}"
    echo "Running: $test_name ($concurrent_count concurrent processes)"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    create_mock_parallel_script "$temp_dir" 3 0
    
    # Record initial system state
    local initial_memory
    local initial_cpu
    initial_memory=$(get_memory_usage)
    initial_cpu=$(get_cpu_usage)
    
    local start_time
    start_time=$(date +%s.%N)
    
    # Launch multiple parallel executions
    local pids=()
    for i in $(seq 1 "$concurrent_count"); do
        ("$temp_dir/mock_parallel.sh" "$temp_dir") &
        pids+=($!)
    done
    
    # Monitor resource usage during execution
    local max_memory=$initial_memory
    local max_cpu=$initial_cpu
    local monitoring=true
    
    # Background monitoring
    (
        while $monitoring; do
            local current_memory
            local current_cpu
            current_memory=$(get_memory_usage)
            current_cpu=$(get_cpu_usage)
            
            if (( $(echo "$current_memory > $max_memory" | bc -l 2>/dev/null || echo "0") )); then
                max_memory=$current_memory
            fi
            
            if (( $(echo "$current_cpu > $max_cpu" | bc -l 2>/dev/null || echo "0") )); then
                max_cpu=$current_cpu
            fi
            
            sleep 0.5
        done
    ) &
    local monitor_pid=$!
    
    # Wait for all processes to complete
    local completed=0
    local failed=0
    
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            ((completed += 1))
        else
            ((failed += 1))
        fi
    done
    
    # Stop monitoring
    monitoring=false
    kill $monitor_pid 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    
    local end_time
    end_time=$(date +%s.%N)
    local execution_time
    execution_time=$(echo "$end_time - $start_time" | bc -l)
    
    # Record metrics
    EXECUTION_TIMES+=("$execution_time")
    MEMORY_USAGE+=("$max_memory")
    CPU_USAGE+=("$max_cpu")
    
    # Verify results
    local result_files
    result_files=$(find "$temp_dir" -name "result_*" | wc -l)
    
    printf "  Execution time: %.2fs\n" "$execution_time"
    printf "  Memory usage: %.1f MB (%.1f MB increase)\n" "$max_memory" "$(echo "$max_memory - $initial_memory" | bc -l)"
    printf "  CPU usage: %.1f%%\n" "$max_cpu"
    echo "  Completed: $completed, Failed: $failed, Result files: $result_files"
    
    # Pass criteria: All processes complete successfully and reasonable resource usage
    if [[ $completed -eq $concurrent_count ]] && [[ $failed -eq 0 ]] && [[ $result_files -eq $concurrent_count ]]; then
        echo "✅ PASS: $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "❌ FAIL: $test_name - Incomplete execution or failures"
        ((TESTS_FAILED += 1))
    fi
    
    rm -rf "$temp_dir"
    trap - EXIT
    kill $monitor_pid 2>/dev/null || true
}

# Test resource contention under heavy load
test_resource_contention() {
    local test_name="Stress Test: Resource Contention"
    echo "Running: $test_name"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    # Create script that generates high I/O and CPU load
    cat > "$temp_dir/mock_heavy_load.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

result_dir="$1"
process_id="$$"

# Heavy I/O operations
for i in {1..20}; do
    temp_file=$(mktemp)
    dd if=/dev/urandom of="$temp_file" bs=1024 count=500 2>/dev/null &
done

# Heavy CPU operations
for i in {1..5}; do
    (
        # CPU intensive calculation
        counter=0
        while [[ $counter -lt 100000 ]]; do
            ((counter += 1))
        done
    ) &
done

# Wait for background jobs
wait

# Write result
echo "HEAVY_LOAD_SUCCESS:$process_id" > "$result_dir/heavy_result_$process_id"
exit 0
EOF
    
    chmod +x "$temp_dir/mock_heavy_load.sh"
    
    local start_time
    start_time=$(date +%s.%N)
    
    # Launch multiple heavy load processes
    local pids=()
    for i in {1..3}; do
        ("$temp_dir/mock_heavy_load.sh" "$temp_dir") &
        pids+=($!)
    done
    
    # Monitor system responsiveness
    local system_responsive=true
    (
        # Simple responsiveness test - create/delete files
        for i in {1..10}; do
            local test_file
            test_file=$(mktemp)
            if ! echo "test" > "$test_file" 2>/dev/null; then
                system_responsive=false
                break
            fi
            rm -f "$test_file"
            sleep 1
        done
    ) &
    local monitor_pid=$!
    
    # Wait for completion
    local completed=0
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            ((completed += 1))
        else
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    
    wait $monitor_pid 2>/dev/null || true
    
    local end_time
    end_time=$(date +%s.%N)
    local execution_time
    execution_time=$(echo "$end_time - $start_time" | bc -l)
    
    # Check results
    local result_files
    result_files=$(find "$temp_dir" -name "heavy_result_*" | wc -l | tr -d '[:space:]')
    
    printf "  Heavy load execution time: %.2fs\n" "$execution_time"
    echo "  Completed heavy processes: $completed/3"
    echo "  System remained responsive: $system_responsive"
    echo "  Result files created: $result_files"
    
    # Pass if most processes completed and system stayed responsive
    if [[ $completed -ge 2 ]] && [[ "$system_responsive" == "true" ]]; then
        echo "✅ PASS: $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "❌ FAIL: $test_name - System overload or unresponsiveness"
        ((TESTS_FAILED += 1))
    fi
    
    rm -rf "$temp_dir"
    trap - EXIT
}

# Test memory leak detection
test_memory_leak_detection() {
    local test_name="Stress Test: Memory Leak Detection"
    echo "Running: $test_name"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    # Create script that potentially leaks memory
    create_mock_parallel_script "$temp_dir" 1 0
    
    local initial_memory
    initial_memory=$(get_memory_usage)
    
    local memory_samples=()
    
    # Run multiple iterations
    # shellcheck disable=SC2034  # iteration is used as loop context
    for iteration in {1..10}; do
        # Launch parallel processes
        local pids=()
        for i in {1..3}; do
            ("$temp_dir/mock_parallel.sh" "$temp_dir") &
            pids+=($!)
        done
        
        # Wait for completion
        for pid in "${pids[@]}"; do
            wait "$pid" || true
        done
        
        # Sample memory usage
        local current_memory
        current_memory=$(get_memory_usage)
        memory_samples+=("$current_memory")
        
        # Clean up temporary files
        find "$temp_dir" -name "result_*" -delete 2>/dev/null || true
        
        sleep 1
    done
    
    # Analyze memory trend
    local memory_increase
    local final_memory="${memory_samples[$((${#memory_samples[@]} - 1))]}"
    memory_increase=$(echo "$final_memory - $initial_memory" | bc -l)
    
    printf "  Initial memory: %.1f MB\n" "$initial_memory"
    printf "  Final memory: %.1f MB\n" "$final_memory"
    printf "  Memory increase: %.1f MB\n" "$memory_increase"
    
    # Memory leak detection: increase should be minimal (< 50MB)
    if (( $(echo "$memory_increase < 50" | bc -l) )); then
        echo "✅ PASS: $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "❌ FAIL: $test_name - Potential memory leak detected"
        ((TESTS_FAILED += 1))
    fi
    
    rm -rf "$temp_dir"
    trap - EXIT
}

# Test network partition simulation
test_network_partition_simulation() {
    local test_name="Stress Test: Network Partition Simulation"
    echo "Running: $test_name"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    # Create script that simulates network calls
    cat > "$temp_dir/mock_network_script.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

result_dir="$1"
network_available="${2:-true}"

# Simulate network call
if [[ "$network_available" == "true" ]]; then
    # Simulate successful network call
    sleep 1
    echo "NETWORK_SUCCESS" > "$result_dir/network_result_$$"
    exit 0
else
    # Simulate network failure
    echo "Network unavailable" >&2
    exit 1
fi
EOF
    
    chmod +x "$temp_dir/mock_network_script.sh"
    
    # Test with network available
    echo "  Testing with network available..."
    local available_pids=()
    for i in {1..3}; do
        ("$temp_dir/mock_network_script.sh" "$temp_dir" "true") &
        available_pids+=($!)
    done
    
    local available_success=0
    for pid in "${available_pids[@]}"; do
        if wait "$pid"; then
            ((available_success += 1))
        fi
    done
    
    # Test with network unavailable
    echo "  Testing with network unavailable..."
    local unavailable_pids=()
    for i in {1..3}; do
        ("$temp_dir/mock_network_script.sh" "$temp_dir" "false") &
        unavailable_pids+=($!)
    done
    
    local unavailable_failures=0
    for pid in "${unavailable_pids[@]}"; do
        if ! wait "$pid"; then
            ((unavailable_failures += 1))
        fi
    done
    
    echo "  Network available - successes: $available_success/3"
    echo "  Network unavailable - failures: $unavailable_failures/3"
    
    # Pass if network available cases succeed and network unavailable cases fail appropriately
    if [[ $available_success -eq 3 ]] && [[ $unavailable_failures -eq 3 ]]; then
        echo "✅ PASS: $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "❌ FAIL: $test_name - Network simulation not working correctly"
        ((TESTS_FAILED += 1))
    fi
    
    rm -rf "$temp_dir"
    trap - EXIT
}

# Test rate limiting behavior
test_rate_limiting_simulation() {
    local test_name="Stress Test: Rate Limiting Simulation"
    echo "Running: $test_name"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    # Create script that simulates rate limiting
    cat > "$temp_dir/mock_rate_limited.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

result_dir="$1"
request_id="$$"

# Simulate rate limiting logic - allow only 2 concurrent requests
lock_file="$result_dir/rate_limit_lock"

# Try to acquire lock (simulate rate limit)
lock_acquired=false
for attempt in {1..5}; do
    if (
        set -C
        echo "$request_id" > "$lock_file"
    ) 2>/dev/null; then
        lock_acquired=true
        break
    else
        # Simulate rate limit delay
        sleep $((RANDOM % 3 + 1))
    fi
done

if [[ "$lock_acquired" == "false" ]]; then
    echo "Rate limited" >&2
    echo "RATE_LIMITED:$request_id" > "$result_dir/rate_limited_$request_id"
    exit 1
fi

# Simulate work
sleep 2

# Release lock
rm -f "$lock_file"

echo "SUCCESS:$request_id" > "$result_dir/success_$request_id"
exit 0
EOF
    
    chmod +x "$temp_dir/mock_rate_limited.sh"
    
    local start_time
    start_time=$(date +%s.%N)
    
    # Launch many concurrent requests to trigger rate limiting
    local pids=()
    for i in {1..8}; do
        ("$temp_dir/mock_rate_limited.sh" "$temp_dir") &
        pids+=($!)
    done
    
    # Wait for all to complete
    local successes=0
    local rate_limited=0
    
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            ((successes += 1))
        else
            ((rate_limited += 1))
        fi
    done
    
    local end_time
    end_time=$(date +%s.%N)
    local execution_time
    execution_time=$(echo "$end_time - $start_time" | bc -l)
    
    local success_files
    local rate_limited_files
    success_files=$(find "$temp_dir" -name "success_*" | wc -l)
    rate_limited_files=$(find "$temp_dir" -name "rate_limited_*" | wc -l)
    
    printf "  Rate limiting test execution time: %.2fs\n" "$execution_time"
    echo "  Successful requests: $successes (files: $success_files)"
    echo "  Rate limited requests: $rate_limited (files: $rate_limited_files)"
    
    # Pass if some requests succeeded and some were rate limited
    if [[ $successes -gt 0 ]] && [[ $rate_limited -gt 0 ]]; then
        echo "✅ PASS: $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "❌ FAIL: $test_name - Rate limiting not working as expected"
        ((TESTS_FAILED += 1))
    fi
    
    rm -rf "$temp_dir"
    trap - EXIT
}

# Performance analysis
analyze_performance_metrics() {
    echo
    echo "=== Performance Analysis ==="
    
    if [[ ${#EXECUTION_TIMES[@]} -gt 0 ]]; then
        echo "Execution Times:"
        for i in "${!EXECUTION_TIMES[@]}"; do
            printf "  Test %d: %.2fs\n" "$((i+1))" "${EXECUTION_TIMES[$i]}"
        done
        
        # Calculate average execution time
        local total_time=0
        for time in "${EXECUTION_TIMES[@]}"; do
            total_time=$(echo "$total_time + $time" | bc -l)
        done
        local avg_time
        avg_time=$(echo "scale=2; $total_time / ${#EXECUTION_TIMES[@]}" | bc -l)
        printf "  Average: %.2fs\n" "$avg_time"
    fi
    
    if [[ ${#MEMORY_USAGE[@]} -gt 0 ]]; then
        echo "Memory Usage:"
        for i in "${!MEMORY_USAGE[@]}"; do
            printf "  Test %d: %.1f MB\n" "$((i+1))" "${MEMORY_USAGE[$i]}"
        done
    fi
    
    if [[ ${#CPU_USAGE[@]} -gt 0 ]]; then
        echo "CPU Usage:"
        for i in "${!CPU_USAGE[@]}"; do
            printf "  Test %d: %.1f%%\n" "$((i+1))" "${CPU_USAGE[$i]}"
        done
    fi
}

# Main test runner
run_stress_tests() {
    echo "=== Stress Testing Suite ==="
    echo "Testing system behavior under load and various stress conditions"
    echo
    
    # Run stress test cases
    test_concurrent_executions 3
    test_concurrent_executions 5
    test_resource_contention
    test_memory_leak_detection
    test_network_partition_simulation
    test_rate_limiting_simulation
    
    analyze_performance_metrics
    
    echo
    echo "=== Stress Test Results ==="
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo "Total:  $((TESTS_PASSED + TESTS_FAILED))"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "✅ All stress tests passed!"
        return 0
    else
        echo "❌ Some stress tests failed!"
        return 1
    fi
}

# Run tests if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_stress_tests
fi
