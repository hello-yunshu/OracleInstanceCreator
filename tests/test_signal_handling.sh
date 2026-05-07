#!/bin/bash

# Signal handling test suite
# Tests graceful shutdown and cleanup behavior

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_DIR")"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"

source "$SCRIPTS_DIR/utils.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TEMP_DIR=""

# Colors for test output
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

setup_test_environment() {
    log_info "Setting up signal handling test environment..."
    
    umask 077
    TEST_TEMP_DIR=$(mktemp -d)
    export TEST_TEMP_DIR
    
    log_success "Signal handling test environment configured"
}

cleanup_test_environment() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" == "$actual" ]]; then
        echo "  ${GREEN}✓${RESET} $message"
        ((TESTS_PASSED += 1))
    else
        echo "  ${RED}✗${RESET} $message"
        echo "    Expected: $expected"
        echo "    Actual: $actual"
        ((TESTS_FAILED += 1))
    fi
}

assert_file_exists() {
    local file_path="$1"
    local message="${2:-File should exist: $file_path}"
    
    if [[ -f "$file_path" ]]; then
        echo "  ${GREEN}✓${RESET} $message"
        ((TESTS_PASSED += 1))
    else
        echo "  ${RED}✗${RESET} $message"
        ((TESTS_FAILED += 1))
    fi
}

test_sigterm_cleanup() {
    echo "${YELLOW}Testing SIGTERM graceful cleanup...${RESET}"
    
    # Create a test script that mimics launch-parallel.sh behavior
    local test_script="$TEST_TEMP_DIR/sigterm_test.sh"
    cat > "$test_script" << 'EOF'
#!/bin/bash
set -euo pipefail

PID_A1=""
PID_E2=""
temp_dir=""
cleanup_called=false

cleanup_handler() {
    cleanup_called=true
    echo "CLEANUP_STARTED" >> "$TEST_TEMP_DIR/cleanup_trace"
    
    # Terminate child processes
    [[ -n "$PID_A1" ]] && kill $PID_A1 2>/dev/null || true
    [[ -n "$PID_E2" ]] && kill $PID_E2 2>/dev/null || true
    
    sleep 0.1  # Graceful termination delay (shortened for tests)
    
    # Force kill if still running
    [[ -n "$PID_A1" ]] && kill -9 $PID_A1 2>/dev/null || true
    [[ -n "$PID_E2" ]] && kill -9 $PID_E2 2>/dev/null || true
    
    # Cleanup temp directory
    [[ -n "$temp_dir" && -d "$temp_dir" ]] && rm -rf "$temp_dir" 2>/dev/null || true
    
    echo "CLEANUP_COMPLETED" >> "$TEST_TEMP_DIR/cleanup_trace"
    exit 1
}

trap cleanup_handler SIGTERM SIGINT

# Create temp directory
umask 077
temp_dir=$(mktemp -d)
echo "Created temp dir: $temp_dir" >> "$TEST_TEMP_DIR/test_log"

# Start background processes
sleep 30 &
PID_A1=$!
echo "Started A1 process: $PID_A1" >> "$TEST_TEMP_DIR/test_log"

sleep 30 &
PID_E2=$!
echo "Started E2 process: $PID_E2" >> "$TEST_TEMP_DIR/test_log"

# Wait for signal
(sleep 0.2; kill -TERM $$) &
wait
EOF
    chmod +x "$test_script"
    
    set +e
    "$test_script"
    set -e
    
    # Check if cleanup was called
    assert_file_exists "$TEST_TEMP_DIR/cleanup_trace" "Cleanup trace should be created"
    
    if [[ -f "$TEST_TEMP_DIR/cleanup_trace" ]]; then
        local cleanup_content
        cleanup_content=$(cat "$TEST_TEMP_DIR/cleanup_trace")
        
        if [[ "$cleanup_content" == *"CLEANUP_STARTED"* ]]; then
            assert_equals "true" "true" "Cleanup should start on SIGTERM"
        else
            assert_equals "true" "false" "Cleanup should start on SIGTERM"
        fi
        
        if [[ "$cleanup_content" == *"CLEANUP_COMPLETED"* ]]; then
            assert_equals "true" "true" "Cleanup should complete on SIGTERM"
        else
            assert_equals "true" "false" "Cleanup should complete on SIGTERM"
        fi
    fi
}

test_sigint_cleanup() {
    echo "${YELLOW}Testing SIGINT graceful cleanup...${RESET}"
    
    local test_script="$TEST_TEMP_DIR/sigint_test.sh"
    cat > "$test_script" << 'EOF'
#!/bin/bash
set -euo pipefail

PID_A1=""
PID_E2=""
temp_dir=""

cleanup_handler() {
    echo "SIGINT_CLEANUP" >> "$TEST_TEMP_DIR/sigint_trace"
    
    # Cleanup processes and files
    [[ -n "$PID_A1" ]] && kill $PID_A1 2>/dev/null || true
    [[ -n "$PID_E2" ]] && kill $PID_E2 2>/dev/null || true
    [[ -n "$temp_dir" && -d "$temp_dir" ]] && rm -rf "$temp_dir" 2>/dev/null || true
    
    exit 1
}

trap cleanup_handler SIGINT

umask 077
temp_dir=$(mktemp -d)

sleep 30 &
PID_A1=$!
sleep 30 &
PID_E2=$!

(sleep 0.2; kill -INT $$) &
wait
EOF
    chmod +x "$test_script"
    
    set +e
    "$test_script"
    set -e
    
    assert_file_exists "$TEST_TEMP_DIR/sigint_trace" "SIGINT cleanup should be called"
}

test_process_termination() {
    echo "${YELLOW}Testing background process termination...${RESET}"
    
    # Start some background processes and verify they get terminated
    local test_script="$TEST_TEMP_DIR/process_test.sh"
    cat > "$test_script" << 'EOF'
#!/bin/bash
set -euo pipefail

PID_A1=""
PID_E2=""

cleanup_handler() {
    # Kill background processes
    if [[ -n "$PID_A1" ]]; then
        if kill $PID_A1 2>/dev/null; then
            echo "A1_TERMINATED" >> "$TEST_TEMP_DIR/process_trace"
        fi
    fi
    
    if [[ -n "$PID_E2" ]]; then
        if kill $PID_E2 2>/dev/null; then
            echo "E2_TERMINATED" >> "$TEST_TEMP_DIR/process_trace"
        fi
    fi
    
    exit 1
}

trap cleanup_handler SIGTERM

# Start background processes that write to files periodically
(while true; do echo "A1_ALIVE" >> "$TEST_TEMP_DIR/a1_log"; sleep 0.1; done) &
PID_A1=$!

(while true; do echo "E2_ALIVE" >> "$TEST_TEMP_DIR/e2_log"; sleep 0.1; done) &
PID_E2=$!

(sleep 0.2; kill -TERM $$) &
wait
EOF
    chmod +x "$test_script"
    
    set +e
    "$test_script"
    set -e
    
    # Check if processes were terminated
    assert_file_exists "$TEST_TEMP_DIR/process_trace" "Process termination trace should exist"
    
    if [[ -f "$TEST_TEMP_DIR/process_trace" ]]; then
        local trace_content
        trace_content=$(cat "$TEST_TEMP_DIR/process_trace")
        
        if [[ "$trace_content" == *"A1_TERMINATED"* && "$trace_content" == *"E2_TERMINATED"* ]]; then
            assert_equals "true" "true" "Both background processes should be terminated"
        else
            assert_equals "true" "false" "Both background processes should be terminated"
        fi
    fi
}

test_temp_directory_cleanup() {
    echo "${YELLOW}Testing temporary directory cleanup...${RESET}"
    
    local test_script="$TEST_TEMP_DIR/temp_cleanup_test.sh"
    cat > "$test_script" << 'EOF'
#!/bin/bash
set -euo pipefail

temp_dir=""

cleanup_handler() {
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf "$temp_dir" 2>/dev/null || true
        echo "TEMP_CLEANED" >> "$TEST_TEMP_DIR/temp_trace"
    fi
    exit 1
}

trap cleanup_handler SIGTERM

umask 077
temp_dir=$(mktemp -d)
echo "TEMP_CREATED:$temp_dir" >> "$TEST_TEMP_DIR/temp_trace"

# Create some files in temp directory
echo "test1" > "$temp_dir/file1"
echo "test2" > "$temp_dir/file2"

(sleep 0.2; kill -TERM $$) &
wait
EOF
    chmod +x "$test_script"
    
    set +e
    "$test_script"
    set -e
    
    assert_file_exists "$TEST_TEMP_DIR/temp_trace" "Temp directory trace should exist"
    
    if [[ -f "$TEST_TEMP_DIR/temp_trace" ]]; then
        local trace_content
        trace_content=$(cat "$TEST_TEMP_DIR/temp_trace")
        
        if [[ "$trace_content" == *"TEMP_CLEANED"* ]]; then
            assert_equals "true" "true" "Temporary directory should be cleaned up"
        else
            assert_equals "true" "false" "Temporary directory should be cleaned up"
        fi
        
        # Extract temp dir path and verify it doesn't exist
        local temp_path
        temp_path=$(echo "$trace_content" | grep "TEMP_CREATED:" | cut -d':' -f2)
        
        if [[ -n "$temp_path" && ! -d "$temp_path" ]]; then
            assert_equals "true" "true" "Temp directory should not exist after cleanup"
        else
            assert_equals "true" "false" "Temp directory should not exist after cleanup"
        fi
    fi
}

run_signal_tests() {
    echo "Starting Signal Handling Tests"
    echo "=============================="
    
    setup_test_environment
    
    test_sigterm_cleanup
    test_sigint_cleanup
    test_process_termination
    test_temp_directory_cleanup
    
    cleanup_test_environment
    
    # Print results
    echo ""
    echo "Signal Handling Test Results:"
    echo "============================="
    echo "Passed: ${GREEN}$TESTS_PASSED${RESET}"
    echo "Failed: ${RED}$TESTS_FAILED${RESET}"
    echo "Total:  $((TESTS_PASSED + TESTS_FAILED))"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo ""
        echo "${GREEN}All signal handling tests passed!${RESET}"
        exit 0
    else
        echo ""
        echo "${RED}Some signal handling tests failed!${RESET}"
        exit 1
    fi
}

trap cleanup_test_environment EXIT

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_signal_tests
fi
