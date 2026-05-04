# CLAUDE.md

OCI free-tier automation: parallel A1.Flex (ARM) + E2.1.Micro (AMD) provisioning via GitHub Actions.

## Architecture

```text
.github/workflows/infrastructure-deployment.yml  # Single-job parallel execution
scripts/
├── launch-parallel.sh      # Orchestrates both shapes with env injection
├── launch-instance.sh      # Shape-agnostic creation + transient retry
├── utils.sh               # OCI CLI wrapper + error classification
├── circuit-breaker.sh     # AD failure tracking (3 failures = skip)
├── setup-oci.sh          # CLI + proxy setup
├── validate-config.sh    # Configuration validation
└── notify.sh             # Telegram notifications
tests/
├── test_proxy.sh         # Proxy validation (15 tests)
├── test_integration.sh   # Integration tests (9 tests)
├── test_circuit_breaker.sh # Circuit breaker (9 tests)
└── run_new_tests.sh      # Test runner
```

## Critical Patterns

### Performance Optimization (93% improvement)
```bash
# NEVER remove these flags in utils.sh:
oci_args+=("--no-retry")                    # Eliminates exponential backoff
oci_args+=("--connection-timeout" "5")      # 5s vs 10s default
oci_args+=("--read-timeout" "15")           # 15s vs 60s default
```

### Error Classification (scripts/utils.sh)
```bash
CAPACITY: "capacity|quota|limit|429"        → Schedule retry (treat as SUCCESS, exit 0)
DUPLICATE: "already exists"                 → SUCCESS (exit 0)
TRANSIENT: "internal|network|timeout"       → Retry 3x same AD, then next AD
AUTH/CONFIG: "authentication|invalid.*ocid" → Alert user immediately (FAILURE)
```

### CRITICAL: NO RETRIES ON VALID ORACLE API RESPONSES
**NEVER RETRY on 429/capacity/limit errors in scheduled workflows!** These are valid Oracle responses that indicate expected operational conditions. The whole point of this implementation is minimal Oracle API interaction through short scheduled runs. Only retry on actual API call failures (timeouts, network errors) - NOT on successful API responses indicating capacity constraints.

### Parallel Execution Pattern (launch-parallel.sh)
```bash
# Environment variable injection per shape:
(export OCI_SHAPE="VM.Standard.A1.Flex" OCI_OCPUS="4" OCI_MEMORY_IN_GBS="24"; ./launch-instance.sh) &
(export OCI_SHAPE="VM.Standard.E2.1.Micro" OCI_OCPUS="" OCI_MEMORY_IN_GBS=""; ./launch-instance.sh) &
wait  # 55s timeout protection
```

### Shape Configurations
```bash
# A1.Flex (ARM) - 4 OCPUs, 24GB, instance name: a1-flex-sg
# E2.1.Micro (AMD) - 1 OCPU, 1GB, instance name: e2-micro-sg
```

## Development Commands

```bash
# Configuration validation
./scripts/validate-config.sh

# Local testing (requires environment variables)
./scripts/setup-oci.sh           # OCI CLI + proxy setup
./scripts/launch-parallel.sh     # Both shapes in parallel
./scripts/launch-instance.sh     # Single shape (with env vars)

# Test suites
./tests/test_proxy.sh             # Proxy validation (15 tests)
./tests/test_integration.sh       # Integration tests (9 tests)
./tests/test_circuit_breaker.sh   # Circuit breaker functionality (9 tests)
./tests/run_new_tests.sh          # Test runner for enhancements

# Syntax validation
bash -n scripts/*.sh

# Debug modes
INTERNAL_DEBUG=true ./scripts/launch-instance.sh                    # Internal script logging only
OCI_CLI_DEBUG=true INTERNAL_DEBUG=true ./scripts/launch-instance.sh # Full debug with Oracle API logs
```

## Environment Variables

```bash
# Multi-AD Support (comma-separated)
OCI_AD="fgaj:AP-SINGAPORE-1-AD-1,fgaj:AP-SINGAPORE-1-AD-2,fgaj:AP-SINGAPORE-1-AD-3"

# Performance & Reliability
BOOT_VOLUME_SIZE="50"                    # GB, minimum enforced
RECOVERY_ACTION="RESTORE_INSTANCE"       # Auto-restart on failures
RETRY_WAIT_TIME="30"                     # Seconds between AD attempts
TRANSIENT_ERROR_MAX_RETRIES="3"         # Retry count per AD
TRANSIENT_ERROR_RETRY_DELAY="15"        # Seconds between retries

# Debugging - Dual Debug Flag Support
OCI_CLI_DEBUG="false"                    # Enable OCI CLI --debug flag (verbose Oracle API logs)
INTERNAL_DEBUG="true"                    # Enable internal script debug logging (execution flow)
LOG_FORMAT="text"                        # or "json" for structured logging
```

## Workflow Testing

```bash
# Manual run with internal debug only (recommended)
gh workflow run infrastructure-deployment.yml --field internal_debug=true --field send_notifications=false

# Manual run with both debug flags (verbose Oracle API logs)
gh workflow run infrastructure-deployment.yml --field oci_cli_debug=true --field internal_debug=true --field send_notifications=false

# Monitor execution
gh run watch <run-id>

# Expected timing: ~20-25 seconds total, ~14 seconds parallel phase
```

## Error Patterns

### Expected Behaviors
- **Capacity limitations are normal** - Oracle Cloud has dynamic resource availability
- **Rate limiting (HTTP 429)** - High demand, standard cloud provider behavior that resolves automatically
- **"Too many requests"** - Oracle API throttling during high usage, workflow continues normally  
- **"Out of host capacity"** - Common during peak usage periods
- **ARM (A1.Flex) typically more available** than AMD (E2.1.Micro)
- **Free tier limits reached** - Expected when E2 (2/2 instances) or A1 (4/4 OCPUs) limits are reached
  - Limit states are cached to prevent repeated failed attempts
  - Cached limits persist between workflow runs to avoid unnecessary Oracle API calls
  - Workflow returns success (exit code 0) when limits are reached - not a failure condition

### OCID Validation
```bash
# Pattern: ^ocid1\.type\.[a-z0-9-]*\.[a-z0-9-]*\..+
# All OCI resources have globally unique OCIDs
```

### Transient Error Retry Pattern
```bash
# For INTERNAL_ERROR and NETWORK errors:
# 1. Retry same AD up to 3 times (15 second delays)
# 2. If still failing, try next availability domain
# 3. If all ADs exhausted, treat as capacity issue
```

## Gotchas

- **Capacity errors are EXPECTED** (treat as success - retry on schedule)
- **Single job strategy** (avoid matrix = 2x GitHub Actions cost)
- **55-second timeout protection** prevents 2-minute billing
- **Proxy inheritance**: Environment variables auto-propagate to parallel processes
- **Shape requirements**: Flexible shapes need `--shape-config` parameter
- **Never remove** OCI CLI optimization flags - they provide 93% performance improvement

## Workflow Success/Failure Logic

### CRITICAL: Expected Oracle Responses = Workflow SUCCESS
The workflow is designed to treat expected Oracle Cloud operational responses as **successful completions**, not failures:

- **Exit Code 0**: Instance creation succeeded OR expected constraints encountered
- **Exit Code 2**: Oracle capacity constraints (SUCCESS - will retry on schedule)  
- **Exit Code 5**: User free tier limits reached (SUCCESS - expected behavior)
- **Exit Code 6**: Oracle API rate limiting (SUCCESS - expected behavior)

### Only Genuine Errors = Workflow FAILURE  
- **Exit Code 1**: Authentication/configuration errors (requires user action)
- **Exit Code 3**: System/network failures (requires investigation)
- **Exit Code 124**: Execution timeout (indicates performance issues)

### Debug Workflow Execution
Enhanced debugging with dual flag support:

**Internal Debug** (`internal_debug=true` - default enabled):
- Pre-launch environment validation
- Detailed exit code interpretation  
- Post-launch state verification
- Comprehensive execution tracing
- Script decision logic and state changes

**OCI CLI Debug** (`oci_cli_debug=true` - default disabled):
- Verbose Oracle API request/response logs
- Detailed Oracle Cloud service communication
- High verbosity Oracle API debugging
- **Performance impact**: Significantly increases log volume

**Recommended**: Use `internal_debug=true` only for normal troubleshooting. Only enable `oci_cli_debug=true` when investigating Oracle API-specific issues.

This prevents false workflow failures and unwanted notifications for normal Oracle Cloud operational conditions.

## Debug Flags Usage

The workflow supports two independent debug flags for optimal debugging experience:

**Flag Defaults:**
- **Scheduled runs**: `internal_debug=true`, `oci_cli_debug=false` (clean logs, optimal performance)
- **Manual runs**: `internal_debug=true`, `oci_cli_debug=false` (clean logs by default)

**When to Use Each Flag:**
- **`internal_debug=true`**: Default setting for script execution flow, state changes, decision logic
- **`oci_cli_debug=true`**: Only when investigating Oracle API-specific issues (high log volume)

## Telegram Notification Policy

### Instance Hunting Goal:
**NOTIFY: Any instance created OR critical failures**  
**SILENT: Zero instances created (regardless of reason)**

### SEND notifications for:
- ✅ **SUCCESS**: ANY instance created with complete details (ID, IPs, AD, connection info)
- ❌ **FAILURE**: Authentication/configuration errors requiring user action  
- 🚨 **CRITICAL**: System failures requiring immediate attention
- ❌ **ERROR**: Unexpected failures needing investigation

### DO NOT send notifications for:
- ❌ Zero instances created due to capacity constraints (expected operational condition)
- ❌ Zero instances created due to user limits (expected free tier behavior)
- ❌ Zero instances created due to rate limiting (expected Oracle API behavior)
- ❌ Instance already exists (expected when using state management cache)
- ❌ Preflight check completion (operational validation)

### Key Behaviors:
- **Mixed scenarios**: A1 success + E2 limits = **DETAILED NOTIFICATION** (hunting success with A1 details)
- **Both constrained**: A1 capacity + E2 capacity = **NO NOTIFICATION** (zero instances)
- **Pure success**: A1 success + E2 success = **DETAILED NOTIFICATION** (both instances with full details)

### Notification Content:
Success notifications include complete instance details:
- Instance OCID for API access
- Public & Private IP addresses
- Availability Domain location  
- Instance state and shape information
- Ready-to-use connection details

### Philosophy:
**Hunt for successful instance creation. Celebrate any hunting success, stay silent on zero results.**

### Configuration Variables:
- `PREFLIGHT_SEND_TEST_NOTIFICATION=true`: Forces preflight check to send test notification (default: false)
- Preflight checks use silent `/getMe` API endpoint for connectivity validation without generating notifications

## Linter Configuration Policy

### Core Principle
**Linters in this project MUST NOT enforce arbitrary style rules.** Focus on code quality, security, and functional correctness only.

### Disabled Style Rules
- **All Prettier validators**: Disabled to prevent style conflicts with intentional formatting
- **Markdown style rules**: MD026 (trailing punctuation), MD013 (line length), MD033 (HTML tags)
- **Shell formatting**: VALIDATE_SHELL_SHFMT disabled (existing)

### Philosophy
Linters should catch bugs, security issues, and functional problems - not enforce subjective style preferences that reduce documentation readability.

## Oracle Cloud Specifics

- **Flexible shapes need --shape-config parameter**: `{"ocpus": 4, "memoryInGBs": 24}`
- **Fixed shapes (*.Micro) do not need shape configuration**
- **OCID validation**: `^ocid1\.type\.[a-z0-9-]*\.[a-z0-9-]*\..+`
- **Proxy formats**: `username:password@proxy.example.com:3128` (URL encoding supported)

## Performance Indicators

- **<20 seconds**: Optimal performance ✅
- **20-30 seconds**: Acceptable with minor delays
- **30-60 seconds**: Investigate - config/network issues ⚠️
- **>1 minute**: Critical - missing optimizations ❌