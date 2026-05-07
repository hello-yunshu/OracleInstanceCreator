#!/bin/bash

# Comprehensive test suite for proxy parsing functionality
# Tests parse_and_configure_proxy function in utils.sh

set -euo pipefail

# Color codes for test output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source the utils.sh script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/utils.sh"

# Test logging functions
test_log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

test_log_success() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

test_log_error() {
    echo -e "${RED}[FAIL]${NC} $*"
}

test_log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Helper function to run a test
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    ((TESTS_RUN += 1))
    test_log_info "Running: $test_name"
    
    if $test_function; then
        ((TESTS_PASSED += 1))
        test_log_success "$test_name"
    else
        ((TESTS_FAILED += 1))
        test_log_error "$test_name"
    fi
    echo
}

# Helper function to clean up environment variables
cleanup_proxy_env() {
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy OCI_PROXY_URL
}

# Test 1: Valid IPv4 proxy with simple credentials
test_ipv4_simple() {
    cleanup_proxy_env
    export OCI_PROXY_URL="testuser:testpass@proxy.example.com:3128"
    
    if parse_and_configure_proxy false && [[ "$HTTP_PROXY" == "http://testuser:testpass@proxy.example.com:3128/" ]]; then
        return 0
    fi
    return 1
}

# Test 2: Valid IPv4 proxy with IP address
test_ipv4_ip() {
    cleanup_proxy_env
    export OCI_PROXY_URL="user:pass@192.168.1.100:8080"
    
    if parse_and_configure_proxy false && [[ "$HTTP_PROXY" == "http://user:pass@192.168.1.100:8080/" ]]; then
        return 0
    fi
    return 1
}

# Test 3: Valid IPv6 proxy with localhost
test_ipv6_localhost() {
    cleanup_proxy_env
    export OCI_PROXY_URL="user:pass@[::1]:3128"
    
    if parse_and_configure_proxy false && [[ "$HTTP_PROXY" == "http://user:pass@[::1]:3128/" ]]; then
        return 0
    fi
    return 1
}

# Test 4: Valid IPv6 proxy with full address
test_ipv6_full() {
    cleanup_proxy_env
    export OCI_PROXY_URL="user:pass@[2001:db8::1]:8080"
    
    if parse_and_configure_proxy false && [[ "$HTTP_PROXY" == "http://user:pass@[2001:db8::1]:8080/" ]]; then
        return 0
    fi
    return 1
}

# Test 5: URL-encoded credentials with special characters
test_url_encoded_credentials() {
    cleanup_proxy_env
    # Testing user "my+user" and password "my@pass:word" (URL encoded)
    export OCI_PROXY_URL="my%2Buser:my%40pass%3Aword@proxy.example.com:3128"
    
    if parse_and_configure_proxy false && [[ "$HTTP_PROXY" == "http://my%2Buser:my%40pass%3Aword@proxy.example.com:3128/" ]]; then
        return 0
    fi
    return 1
}

# Test 6: Validation-only mode (should not set environment variables)
test_validation_only() {
    cleanup_proxy_env
    export OCI_PROXY_URL="user:pass@proxy.example.com:3128"
    
    if parse_and_configure_proxy true && [[ -z "${HTTP_PROXY:-}" ]]; then
        return 0
    fi
    return 1
}

# Test 7: No proxy URL provided (should succeed and do nothing)
test_no_proxy_url() {
    cleanup_proxy_env
    
    if parse_and_configure_proxy false && [[ -z "${HTTP_PROXY:-}" ]]; then
        return 0
    fi
    return 1
}

# Test 8: Invalid format - missing password
test_invalid_missing_password() {
    cleanup_proxy_env
    export OCI_PROXY_URL="user@proxy.example.com:3128"
    
    # This should fail and call die()
    # We need to capture the exit in a subshell
    if ! (parse_and_configure_proxy false 2>/dev/null); then
        return 0
    fi
    return 1
}

# Test 9: Invalid format - missing port
test_invalid_missing_port() {
    cleanup_proxy_env
    export OCI_PROXY_URL="user:pass@proxy.example.com"
    
    if ! (parse_and_configure_proxy false 2>/dev/null); then
        return 0
    fi
    return 1
}

# Test 10: Invalid port range - too high
test_invalid_port_high() {
    cleanup_proxy_env
    export OCI_PROXY_URL="user:pass@proxy.example.com:99999"
    
    if ! (parse_and_configure_proxy false 2>/dev/null); then
        return 0
    fi
    return 1
}

# Test 11: Invalid port range - zero
test_invalid_port_zero() {
    cleanup_proxy_env
    export OCI_PROXY_URL="user:pass@proxy.example.com:0"
    
    if ! (parse_and_configure_proxy false 2>/dev/null); then
        return 0
    fi
    return 1
}

# Test 12: Already configured proxy (should skip setup)
test_already_configured() {
    cleanup_proxy_env
    export HTTP_PROXY="http://existing:proxy@server:8080/"
    export OCI_PROXY_URL="user:pass@proxy.example.com:3128"
    
    # Should skip setup and keep existing proxy
    if parse_and_configure_proxy false && [[ "$HTTP_PROXY" == "http://existing:proxy@server:8080/" ]]; then
        return 0
    fi
    return 1
}

# Test 13: IPv6 with invalid format (missing brackets)
test_ipv6_invalid_no_brackets() {
    cleanup_proxy_env
    export OCI_PROXY_URL="user:pass@::1:3128"
    
    if ! (parse_and_configure_proxy false 2>/dev/null); then
        return 0
    fi
    return 1
}

# Test 14: Environment variable consistency
test_env_var_consistency() {
    cleanup_proxy_env
    export OCI_PROXY_URL="user:pass@proxy.example.com:3128"
    
    if parse_and_configure_proxy false && 
       [[ "$HTTP_PROXY" == "$HTTPS_PROXY" ]] &&
       [[ "$HTTP_PROXY" == "$http_proxy" ]] &&
       [[ "$HTTP_PROXY" == "$https_proxy" ]]; then
        return 0
    fi
    return 1
}

# Test 15: URL encoding functions directly
test_url_encoding_functions() {
    local test_string="user@domain:password/special"
    local encoded=$(url_encode "$test_string")
    local decoded=$(url_decode "$encoded")
    
    if [[ "$decoded" == "$test_string" ]]; then
        return 0
    fi
    return 1
}

# Main test runner
main() {
    echo -e "${BLUE}=== Proxy Configuration Test Suite ===${NC}"
    echo
    
    # Run all tests
    run_test "IPv4 proxy with simple credentials" test_ipv4_simple
    run_test "IPv4 proxy with IP address" test_ipv4_ip
    run_test "IPv6 proxy with localhost" test_ipv6_localhost
    run_test "IPv6 proxy with full address" test_ipv6_full
    run_test "URL-encoded credentials with special characters" test_url_encoded_credentials
    run_test "Validation-only mode" test_validation_only
    run_test "No proxy URL provided" test_no_proxy_url
    run_test "Invalid format - missing password" test_invalid_missing_password
    run_test "Invalid format - missing port" test_invalid_missing_port
    run_test "Invalid port range - too high" test_invalid_port_high
    run_test "Invalid port range - zero" test_invalid_port_zero
    run_test "Already configured proxy" test_already_configured
    run_test "IPv6 with invalid format" test_ipv6_invalid_no_brackets
    run_test "Environment variable consistency" test_env_var_consistency
    run_test "URL encoding functions" test_url_encoding_functions
    
    # Print summary
    echo -e "${BLUE}=== Test Summary ===${NC}"
    echo -e "Total tests run: ${TESTS_RUN}"
    echo -e "${GREEN}Passed: ${TESTS_PASSED}${NC}"
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}Failed: ${TESTS_FAILED}${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

# Run main function
main "$@"