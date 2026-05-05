# 全面复检修复计划

## 根因分析

`launch-instance.sh` 中仍有 3 处 `return 0` 在实例未创建时错误返回成功：

1. **第 364 行** — 熔断器过滤掉所有 AD 时 `return 0`
2. **第 480 行** — LIMIT_EXCEEDED 所有 AD 穷尽时 `return 0`
3. **第 557 行** — 重试期间容量错误所有 AD 穷尽时 `return 0`

这导致 `launch-parallel.sh` 收到退出码 0 → 误报成功 → 验证找不到实例 → 降级为容量错误。

## 修复步骤

### 1. 修复 launch-instance.sh 中的 3 处 return 0
- 第 364 行: `return 0` → `return "$OCI_EXIT_CAPACITY_ERROR"`
- 第 480 行: `return 0` → `return "$OCI_EXIT_USER_LIMIT_ERROR"` (LIMIT_EXCEEDED 应该是限额错误)
- 第 557 行: `return 0` → `return "$OCI_EXIT_CAPACITY_ERROR"`

### 2. 修复 launch-instance.sh 中残留的英文 Telegram 通知
- 第 702 行: `"OCI authentication error: Check credentials and permissions"` → 中文
- 第 710 行: `"OCI configuration error: ${error_line}"` → 中文
- 第 728 行: `"OCI instance launch failed in $current_ad: ${error_line}"` → 中文
- 第 796 行: `"OCI instance verified: ..."` → 中文

### 3. 语法检查 + 推送
