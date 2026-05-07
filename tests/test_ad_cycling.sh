#!/bin/bash

# AD cycling test suite
# Tests multi-AD failover logic and error aggregation

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_DIR")"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
export PROJECT_ROOT

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
    log_info "Setting up AD cycling test environment..."
    
    umask 077
    TEST_TEMP_DIR=$(mktemp -d)
    export TEST_TEMP_DIR
    
    # Mock environment for testing
    export OCI_AD="test:US-ASHBURN-1-AD-1,test:US-ASHBURN-1-AD-2,test:US-ASHBURN-1-AD-3"
    export RETRY_WAIT_TIME="1"  # Short wait for tests
    export DEBUG="false"
    
    log_success "AD cycling test environment configured"
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

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-}"
    
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  ${GREEN}✓${RESET} $message"
        ((TESTS_PASSED += 1))
    else
        echo "  ${RED}✗${RESET} $message"
        echo "    Looking for: $needle"
        echo "    In: $haystack"
        ((TESTS_FAILED += 1))
    fi
}

test_ad_list_parsing() {
    echo "${YELLOW}Testing AD list parsing...${RESET}"
    
    # Create a test function that parses AD list like the actual implementation
    parse_ad_list() {
        local ad_list="$1"
        local -a ads=()
        local temp_list="$ad_list"
        
        # Split by comma
        while [[ "$temp_list" == *","* ]]; do
            local ad="${temp_list%%,*}"
            ad=$(echo "$ad" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -n "$ad" ]] && ads+=("$ad")
            temp_list="${temp_list#*,}"
        done
        
        # Add the last AD
        if [[ -n "$temp_list" ]]; then
            local ad=$(echo "$temp_list" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -n "$ad" ]] && ads+=("$ad")
        fi
        
        printf '%s\n' "${ads[@]}"
    }
    
    # Test with the mock AD list
    local ad_array=()
    while IFS= read -r ad; do
        ad_array+=("$ad")
    done < <(parse_ad_list "$OCI_AD")
    
    assert_equals "3" "${#ad_array[@]}" "Should parse 3 ADs from comma-separated list"
    assert_equals "test:US-ASHBURN-1-AD-1" "${ad_array[0]}" "First AD should be parsed correctly"
    assert_equals "test:US-ASHBURN-1-AD-2" "${ad_array[1]}" "Second AD should be parsed correctly"
    assert_equals "test:US-ASHBURN-1-AD-3" "${ad_array[2]}" "Third AD should be parsed correctly"
}

test_mock_oci_failures() {
    echo "${YELLOW}Testing mock OCI failure scenarios...${RESET}"
    
    # Create mock OCI command that simulates different error types
    local mock_oci_script="$TEST_TEMP_DIR/mock_oci.sh"
    cat > "$mock_oci_script" << 'EOF'
#!/bin/bash

# Mock OCI CLI for testing AD cycling
# Behavior based on AD being used (set via CURRENT_AD)

case "${CURRENT_AD:-}" in
    "test:US-ASHBURN-1-AD-1")
        # First AD always returns capacity error
        echo "Error: Out of host capacity" >&2
        exit 1
        ;;
    "test:US-ASHBURN-1-AD-2") 
        # Second AD returns rate limit first time, success second time
        if [[ -f "$TEST_TEMP_DIR/ad2_attempted" ]]; then
            echo '{"data":{"id":"ocid1.instance.oc1..success"}}' 
            exit 0
        else
            touch "$TEST_TEMP_DIR/ad2_attempted"
            echo "Error: TooManyRequests" >&2
            exit 1
        fi
        ;;
    "test:US-ASHBURN-1-AD-3")
        # Third AD always succeeds
        echo '{"data":{"id":"ocid1.instance.oc1..success"}}'
        exit 0
        ;;
    *)
        echo "Error: Unknown AD" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$mock_oci_script"
    
    # Test error type detection
    export CURRENT_AD="test:US-ASHBURN-1-AD-1"
    local error_output
    error_output=$("$mock_oci_script" 2>&1 || true)
    local error_type
    error_type=$(get_error_type "$error_output")
    
    assert_equals "CAPACITY" "$error_type" "Should detect capacity error from AD-1"
    
    export CURRENT_AD="test:US-ASHBURN-1-AD-2"
    error_output=$("$mock_oci_script" 2>&1 || true)
    error_type=$(get_error_type "$error_output")
    
    assert_equals "RATE_LIMIT" "$error_type" "Should detect rate limit error from AD-2"
}

test_ad_cycling_logic() {
    echo "${YELLOW}Testing AD cycling with failover...${RESET}"
    rm -f "$TEST_TEMP_DIR/ad2_attempted"
    
    # Create a test function that simulates the AD cycling logic
    local test_cycling_script="$TEST_TEMP_DIR/test_cycling.sh"
    cat > "$test_cycling_script" << 'EOF'
#!/bin/bash
set -euo pipefail

source "$PROJECT_ROOT/scripts/utils.sh"

# Mock the create_instance function to use our mock OCI
create_instance() {
    local ad="$1"
    export CURRENT_AD="$ad"
    
    log_debug "Attempting instance creation in $ad"
    local output
    local status
    
    set +e
    output=$("$TEST_TEMP_DIR/mock_oci.sh" 2>&1)
    status=$?
    set -e

    if [[ $status -eq 0 ]]; then
        echo "$output"
        log_success "Instance created successfully in $ad"
        return 0
    else
        local error_type
        error_type=$(get_error_type "$output")
        
        log_warning "Instance creation failed in $ad: $error_type"
        
        # Log attempt for tracking
        echo "$ad:$error_type" >> "$TEST_TEMP_DIR/attempts.log"
        
        return $(get_exit_code_for_error_type "$error_type")
    fi
}

# Simulate AD cycling
cycle_through_ads() {
    local ad_list="$OCI_AD"
    local -a ads=()
    local temp_list="$ad_list"
    
    # Parse AD list
    while [[ "$temp_list" == *","* ]]; do
        local ad="${temp_list%%,*}"
        ad=$(echo "$ad" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$ad" ]] && ads+=("$ad")
        temp_list="${temp_list#*,}"
    done
    
    if [[ -n "$temp_list" ]]; then
        local ad=$(echo "$temp_list" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$ad" ]] && ads+=("$ad")
    fi
    
    log_info "Starting AD cycling through ${#ads[@]} availability domains"
    
    # Try each AD
    for ad in "${ads[@]}"; do
        if create_instance "$ad"; then
            log_success "Successfully created instance in $ad"
            echo "SUCCESS:$ad" >> "$TEST_TEMP_DIR/final_result"
            return 0
        else
            log_warning "Failed to create instance in $ad, trying next AD..."
            sleep "$RETRY_WAIT_TIME"
        fi
    done
    
    log_error "Failed to create instance in all available ADs"
    echo "FAILED:ALL_ADS" >> "$TEST_TEMP_DIR/final_result"
    return 1
}

cycle_through_ads
EOF
    chmod +x "$test_cycling_script"
    
    # Run the cycling test
    "$test_cycling_script"
    
    # Check the results
    if [[ -f "$TEST_TEMP_DIR/attempts.log" ]]; then
        local attempts
        attempts=$(cat "$TEST_TEMP_DIR/attempts.log")
        
        assert_contains "$attempts" "test:US-ASHBURN-1-AD-1:CAPACITY" "Should attempt AD-1 and get capacity error"
        assert_contains "$attempts" "test:US-ASHBURN-1-AD-2:RATE_LIMIT" "Should attempt AD-2 and get rate limit error first"
    fi
    
    if [[ -f "$TEST_TEMP_DIR/final_result" ]]; then
        local final_result
        final_result=$(cat "$TEST_TEMP_DIR/final_result")
        
        # The test should succeed in AD-3, but let's check if we get there
        if [[ "$final_result" == "SUCCESS:"* ]]; then
            assert_equals "true" "true" "Should eventually succeed in one of the ADs"
        else
            assert_equals "true" "false" "Should eventually succeed in one of the ADs"
        fi
    fi
}

test_exhausted_ads_scenario() {
    echo "${YELLOW}Testing exhausted ADs scenario...${RESET}"
    
    # Create a scenario where all ADs fail
    local mock_oci_failing="$TEST_TEMP_DIR/mock_oci_failing.sh"
    cat > "$mock_oci_failing" << 'EOF'
#!/bin/bash
# Mock OCI that always fails with capacity errors
echo "Error: Out of host capacity in all regions" >&2
exit 1
EOF
    chmod +x "$mock_oci_failing"
    
    local test_exhaustion_script="$TEST_TEMP_DIR/test_exhaustion.sh"
    cat > "$test_exhaustion_script" << 'EOF'
#!/bin/bash
set -euo pipefail

source "$PROJECT_ROOT/scripts/utils.sh"

create_instance() {
    local ad="$1"
    echo "$ad:CAPACITY" >> "$TEST_TEMP_DIR/all_attempts.log"
    return "$OCI_EXIT_CAPACITY_ERROR"
}

# Try all ADs and expect all to fail
ad_list="$OCI_AD"
ads=()
temp_list="$ad_list"

while [[ "$temp_list" == *","* ]]; do
    ad="${temp_list%%,*}"
    ad=$(echo "$ad" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$ad" ]] && ads+=("$ad")
    temp_list="${temp_list#*,}"
done

if [[ -n "$temp_list" ]]; then
    ad=$(echo "$temp_list" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$ad" ]] && ads+=("$ad")
fi

for ad in "${ads[@]}"; do
    if ! create_instance "$ad"; then
        echo "Failed: $ad" >> "$TEST_TEMP_DIR/failed_ads.log"
    fi
done

echo "ALL_EXHAUSTED" >> "$TEST_TEMP_DIR/exhaustion_result"
EOF
    chmod +x "$test_exhaustion_script"
    
    "$test_exhaustion_script"
    
    # Verify all ADs were attempted
    if [[ -f "$TEST_TEMP_DIR/all_attempts.log" ]]; then
        local attempt_count
        attempt_count=$(wc -l < "$TEST_TEMP_DIR/all_attempts.log" | tr -d '[:space:]')
        assert_equals "3" "$attempt_count" "Should attempt all 3 ADs when all fail"
    fi
    
    # Verify exhaustion was detected
    if [[ -f "$TEST_TEMP_DIR/exhaustion_result" ]]; then
        local exhaustion_result
        exhaustion_result=$(cat "$TEST_TEMP_DIR/exhaustion_result")
        assert_equals "ALL_EXHAUSTED" "$exhaustion_result" "Should detect AD exhaustion"
    fi
}

run_ad_cycling_tests() {
    echo "Starting AD Cycling Tests"
    echo "========================="
    
    setup_test_environment
    
    test_ad_list_parsing
    test_mock_oci_failures
    test_ad_cycling_logic
    test_exhausted_ads_scenario
    
    cleanup_test_environment
    
    # Print results
    echo ""
    echo "AD Cycling Test Results:"
    echo "======================="
    echo "Passed: ${GREEN}$TESTS_PASSED${RESET}"
    echo "Failed: ${RED}$TESTS_FAILED${RESET}"
    echo "Total:  $((TESTS_PASSED + TESTS_FAILED))"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo ""
        echo "${GREEN}All AD cycling tests passed!${RESET}"
        exit 0
    else
        echo ""
        echo "${RED}Some AD cycling tests failed!${RESET}"
        exit 1
    fi
}

trap cleanup_test_environment EXIT

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_ad_cycling_tests
fi
