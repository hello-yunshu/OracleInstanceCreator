#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="$PROJECT_ROOT/tests"

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

run_test_suite() {
    local test_file="$1"
    local suite_name="$(basename "$test_file" .sh)"
    
    echo -e "${BLUE}运行测试套件: $suite_name${NC}"
    echo "=" "$(printf '=%.0s' {1..50})"
    
    ((TOTAL_SUITES++))
    
    if bash "$test_file"; then
        echo -e "${GREEN}✓ 测试套件 '$suite_name' 通过${NC}\n"
        ((PASSED_SUITES++))
        return 0
    else
        echo -e "${RED}✗ 测试套件 '$suite_name' 失败${NC}\n"
        ((FAILED_SUITES++))
        return 1
    fi
}

main() {
    echo -e "${YELLOW}Oracle 实例创建器 - 测试运行器${NC}"
    echo -e "${YELLOW}=====================================${NC}\n"
    
    if [[ ! -d "$TESTS_DIR" ]]; then
        echo -e "${RED}错误: 测试目录不存在: $TESTS_DIR${NC}"
        exit 1
    fi
    
    local test_files=()
    while IFS= read -r -d '' file; do
        test_files+=("$file")
    done < <(find "$TESTS_DIR" -name "test_*.sh" -type f -print0)
    
    if [[ ${#test_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未找到测试文件: $TESTS_DIR${NC}"
        exit 0
    fi
    
    echo -e "${BLUE}找到 ${#test_files[@]} 个测试套件${NC}\n"
    
    local overall_success=true
    for test_file in "${test_files[@]}"; do
        if ! run_test_suite "$test_file"; then
            overall_success=false
        fi
    done
    
    echo -e "${YELLOW}测试结果汇总${NC}"
    echo -e "${YELLOW}=================${NC}"
    echo -e "测试套件总数: $TOTAL_SUITES"
    echo -e "${GREEN}通过: $PASSED_SUITES${NC}"
    echo -e "${RED}失败: $FAILED_SUITES${NC}"
    
    if [[ "$overall_success" == true ]]; then
        echo -e "\n${GREEN}🎉 所有测试套件通过！${NC}"
        exit 0
    else
        echo -e "\n${RED}💥 部分测试套件失败！${NC}"
        exit 1
    fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -h, --help     显示帮助信息"
    echo
    echo "说明:"
    echo "  运行 tests/ 目录下的所有测试套件。"
    echo "  测试文件应命名为 test_*.sh 且具有可执行权限。"
    echo
    exit 0
fi

main "$@"
