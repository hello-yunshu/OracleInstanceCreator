#!/bin/bash

# Test runner for Oracle Instance Creator scripts
# Runs all test suites and provides summary

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="$PROJECT_ROOT/tests"

# Test statistics
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

run_test_suite() {
    local test_file="$1"
    # shellcheck disable=SC2155  # basename rarely fails
    local suite_name="$(basename "$test_file" .sh)"
    
    echo -e "${BLUE}Running test suite: $suite_name${NC}"
    echo "=" "$(printf '=%.0s' {1..50})"
    
    ((TOTAL_SUITES++))
    
    if bash "$test_file"; then
        echo -e "${GREEN}✓ Test suite '$suite_name' passed${NC}\n"
        ((PASSED_SUITES++))
        return 0
    else
        echo -e "${RED}✗ Test suite '$suite_name' failed${NC}\n"
        ((FAILED_SUITES++))
        return 1
    fi
}

main() {
    echo -e "${YELLOW}Oracle Instance Creator - Test Runner${NC}"
    echo -e "${YELLOW}=====================================${NC}\n"
    
    # Check if tests directory exists
    if [[ ! -d "$TESTS_DIR" ]]; then
        echo -e "${RED}Error: Tests directory not found: $TESTS_DIR${NC}"
        exit 1
    fi
    
    # Find all test files
    local test_files=()
    while IFS= read -r -d '' file; do
        test_files+=("$file")
    done < <(find "$TESTS_DIR" -name "test_*.sh" -type f -print0)
    
    if [[ ${#test_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No test files found in $TESTS_DIR${NC}"
        exit 0
    fi
    
    echo -e "${BLUE}Found ${#test_files[@]} test suite(s)${NC}\n"
    
    # Run each test suite
    local overall_success=true
    for test_file in "${test_files[@]}"; do
        if ! run_test_suite "$test_file"; then
            overall_success=false
        fi
    done
    
    # Print final summary
    echo -e "${YELLOW}Final Test Summary${NC}"
    echo -e "${YELLOW}=================${NC}"
    echo -e "Total test suites: $TOTAL_SUITES"
    echo -e "${GREEN}Passed: $PASSED_SUITES${NC}"
    echo -e "${RED}Failed: $FAILED_SUITES${NC}"
    
    if [[ "$overall_success" == true ]]; then
        echo -e "\n${GREEN}🎉 All test suites passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}💥 Some test suites failed!${NC}"
        exit 1
    fi
}

# Show usage if help requested
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo
    echo "Description:"
    echo "  Runs all test suites found in the tests/ directory."
    echo "  Test files should be named test_*.sh and be executable."
    echo
    exit 0
fi

# Run main function
main "$@"
