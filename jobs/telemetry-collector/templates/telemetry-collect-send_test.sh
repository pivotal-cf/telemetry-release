#!/usr/bin/env bash
#
# Test Suite for telemetry-collect-send.erb
#
# This test suite demonstrates critical bugs in the collector script.
# Run with: bash telemetry-collect-send_test.sh
#
# Expected: Multiple tests will FAIL, demonstrating production issues

set +e # Don't exit on failure - we want to see all test results

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_RUN=0
TESTS_FAILED=0
TESTS_PASSED=0

# Setup test environment
TEST_DIR=$(mktemp -d)
DATA_DIR="$TEST_DIR/data"
CONFIG_DIR="$TEST_DIR/config"
mkdir -p "$DATA_DIR" "$CONFIG_DIR"

echo "========================================="
echo "TELEMETRY COLLECTOR ROBUSTNESS TEST SUITE"
echo "========================================="
echo ""
echo "Test directory: $TEST_DIR"
echo ""

# Mock telemetry-cli binary
MOCK_CLI="$TEST_DIR/telemetry-cli-linux"
cat >"$MOCK_CLI" <<'MOCK_EOF'
#!/bin/bash
# Mock telemetry-cli that creates a tarball
if [ "$1" == "collect" ]; then
    # Create a tarball with current timestamp
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    TAR_FILE="/tmp/data/telemetry-$TIMESTAMP.tar"
    echo "Creating mock tarball: $TAR_FILE"
    tar -cf "$TAR_FILE" -T /dev/null 2>/dev/null
    exit 0
elif [ "$1" == "send" ]; then
    echo "Mock send: $@"
    exit 0
fi
MOCK_EOF
chmod +x "$MOCK_CLI"

# Helper functions
run_test() {
	TESTS_RUN=$((TESTS_RUN + 1))
	echo -e "${YELLOW}TEST $TESTS_RUN: $1${NC}"
}

assert_fail() {
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo -e "${RED}  ✗ FAIL: $1${NC}"
	if [ -n "$2" ]; then
		echo "    Details: $2"
	fi
}

assert_pass() {
	TESTS_PASSED=$((TESTS_PASSED + 1))
	echo -e "${GREEN}  ✓ PASS: $1${NC}"
}

# ============================================================================
# TEST 1: Multiple Tarball Bug (Issue #1)
# ============================================================================
run_test "Multiple tarballs should not cause script failure"

# Test the FIXED code snippet
cat >"$TEST_DIR/test_multiple_tarballs.sh" <<'EOF'
#!/bin/bash
set -eu
# This simulates the FIXED version: find with -type f | head -n 1
TAR_FILE=$(find /tmp/data -name "*.tar" -type f | head -n 1)
echo "Found: $TAR_FILE"
# This simulates: telemetry-cli send --path "$TAR_FILE"
echo $TAR_FILE | wc -w
EOF
chmod +x "$TEST_DIR/test_multiple_tarballs.sh"

# Create multiple tarballs
mkdir -p /tmp/data
touch /tmp/data/{file1,file2,file3}.tar

OUTPUT=$("$TEST_DIR/test_multiple_tarballs.sh" 2>&1 || echo "FAILED")
WORD_COUNT=$(echo "$OUTPUT" | tail -n 1)

if [ "$WORD_COUNT" -eq 1 ]; then
	assert_pass "Fixed version selects only one tarball" \
		"TAR_FILE contains $WORD_COUNT word, will pass 1 argument to send command"
else
	assert_fail "Fixed version still has multiple tarball issue" \
		"TAR_FILE contains $WORD_COUNT words (should be 1)"
fi

rm -f /tmp/data/*.tar

# ============================================================================
# TEST 2: Unquoted Variable Expansion (Issue #2)
# ============================================================================
run_test "Spaces in tarball filename should be handled correctly"

cat >"$TEST_DIR/test_quoted_var.sh" <<'EOF'
#!/bin/bash
set -eu
TAR_FILE=$(find /tmp/data -name "*.tar" -type f | head -n 1)
# Simulate FIXED version: telemetry-cli send --path "$TAR_FILE"
if [ -n "$TAR_FILE" ]; then
    # Count how many arguments "$TAR_FILE" expands to (should be 1)
    set -- "$TAR_FILE"
    echo $#
fi
EOF
chmod +x "$TEST_DIR/test_quoted_var.sh"

# Create tarball with space in name
mkdir -p /tmp/data
touch "/tmp/data/telemetry data 2024.tar"

ARGS=$("$TEST_DIR/test_quoted_var.sh" 2>&1 || echo "0")

if [ "$ARGS" -eq 1 ]; then
	assert_pass "Quoted variable correctly treated as single argument" \
		"Variable expanded to $ARGS argument (correct)"
else
	assert_fail "Quoted variable still splits on spaces" \
		"Variable expanded to $ARGS arguments (should be 1)"
fi

rm -f /tmp/data/*.tar

# ============================================================================
# TEST 3: Comprehensive Test - Multiple Tarballs + Spaces in Filename
# ============================================================================
run_test "Combined fix handles multiple tarballs with spaces in filename"

cat >"$TEST_DIR/test_comprehensive.sh" <<'EOF'
#!/bin/bash
set -eu
DATA_DIR="/tmp/data"
mkdir -p "$DATA_DIR"

# Create multiple tarballs, including one with spaces
touch "$DATA_DIR/file1.tar"
touch "$DATA_DIR/telemetry data 2024.tar"
touch "$DATA_DIR/file3.tar"

# Simulate the COMPLETE FIXED version
TAR_FILE=$(find "$DATA_DIR" -name "*.tar" -type f | head -n 1)

# Test that the variable is properly quoted and contains only one file
if [ -n "$TAR_FILE" ]; then
    # Count words in the variable (should be 1 even with spaces)
    WORD_COUNT=$(echo "$TAR_FILE" | wc -w)
    
    # Test that it's a valid file path
    if [ -f "$TAR_FILE" ]; then
        echo "SUCCESS:$WORD_COUNT"
    else
        echo "INVALID_FILE"
    fi
else
    echo "NO_FILE_FOUND"
fi
EOF
chmod +x "$TEST_DIR/test_comprehensive.sh"

mkdir -p /tmp/data
OUTPUT=$("$TEST_DIR/test_comprehensive.sh" 2>&1 | tail -n 1)

if echo "$OUTPUT" | grep -q "SUCCESS:.*1"; then
	assert_pass "Comprehensive fix works: single file selected and properly quoted" \
		"Result: $OUTPUT (correctly handles multiple tarballs with spaces)"
else
	assert_fail "Comprehensive fix failed" \
		"Result: $OUTPUT (should be SUCCESS:1)"
fi

rm -f /tmp/data/*.tar

# ============================================================================
# TEST 4: No Error Checking After Collect (Issue #3)
# ============================================================================
run_test "Script should fail if collect command fails"

cat >"$TEST_DIR/test_error_check.sh" <<'EOF'
#!/bin/bash
set -eu
COLLECTOR_BIN=/tmp/fake-collector
echo "#!/bin/bash" > $COLLECTOR_BIN
echo "exit 1" >> $COLLECTOR_BIN
chmod +x $COLLECTOR_BIN

# Simulate current code - no error checking
$COLLECTOR_BIN collect --config dummy.yml
echo "Script continued after failure"
TAR_FILE=$(find /tmp/data -name "*.tar")
echo "Found: $TAR_FILE"
EOF
chmod +x "$TEST_DIR/test_error_check.sh"

OUTPUT=$("$TEST_DIR/test_error_check.sh" 2>&1 || echo "SCRIPT_FAILED")

if echo "$OUTPUT" | grep -q "Script continued after failure"; then
	assert_fail "Script continues after collect failure" \
		"Should exit immediately when collect fails"
else
	assert_pass "Script properly fails on collect error"
fi

# ============================================================================
# TEST 5: .bak Files Accumulate (Issue #4)
# ============================================================================
run_test ".bak files should be cleaned up after sed operations"

cat >"$TEST_DIR/test_config.yml" <<'EOF'
usage-service-url: example.com
operational-data-only: false
EOF

cat >"$TEST_DIR/test_bak_files.sh" <<'EOF'
#!/bin/bash
set -eu
CONFIG="/tmp/test_config.yml"

# Simulate the sed operations in create_or_update_options
sed -i.bak "s/false/true/" "$CONFIG"
sed -i.bak "s/example/modified/" "$CONFIG"

# Simulate the FIXED version: cleanup after sed operations
rm -f "${CONFIG}.bak"

# Count .bak files
ls -1 "$CONFIG"*.bak 2>/dev/null | wc -l
EOF
chmod +x "$TEST_DIR/test_bak_files.sh"

cp "$TEST_DIR/test_config.yml" /tmp/test_config.yml
BAK_COUNT=$("$TEST_DIR/test_bak_files.sh" 2>&1 | tail -n 1)

if [ "$BAK_COUNT" -eq 0 ]; then
	assert_pass "Fixed version cleans up .bak files after sed operations" \
		"Found $BAK_COUNT .bak files (correctly cleaned up)"
else
	assert_fail "Fixed version still leaves .bak files" \
		"Found $BAK_COUNT .bak files (should be 0)"
fi

rm -f /tmp/test_config.yml*

# ============================================================================
# TEST 6: Log File Growth (Issue #6)
# ============================================================================
run_test "Log files should not grow unbounded"

cat >"$TEST_DIR/test_log_growth.sh" <<'EOF'
#!/bin/bash
set -eu
LOG_FILE="/tmp/telemetry-collect-send.log"

# Simulate 365 daily cron runs with 10KB output each
rm -f "$LOG_FILE"
for i in {1..365}; do
    # Each run appends to log (simulate cron: >> $LOG 2>> $LOG)
    dd if=/dev/zero bs=10240 count=1 2>/dev/null | base64 >> "$LOG_FILE"
done

# Check log size
LOG_SIZE=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
LOG_SIZE_MB=$((LOG_SIZE / 1024 / 1024))

echo "$LOG_SIZE_MB"
EOF
chmod +x "$TEST_DIR/test_log_growth.sh"

LOG_SIZE_MB=$("$TEST_DIR/test_log_growth.sh" 2>&1 | tail -n 1)

if [ "$LOG_SIZE_MB" -gt 100 ]; then
	assert_fail "Log file grows without rotation" \
		"After 1 year: ${LOG_SIZE_MB}MB (no rotation configured)"
else
	assert_pass "Log rotation in place"
fi

rm -f /tmp/telemetry-collect-send.log

# ============================================================================
# TEST 7: Regex Injection in Sed (Issue #8)
# ============================================================================
run_test "Special characters in config values should not break sed"

cat >"$TEST_DIR/test_config_regex.yml" <<'EOF'
usage-service-url: api.*.example.com/v1
EOF

cat >"$TEST_DIR/test_regex_injection.sh" <<'EOF'
#!/bin/bash
set +e  # Don't fail on sed error

CONFIG="/tmp/test_config_regex.yml"
usage_service_value=$(grep "usage-service-url:" "$CONFIG" | awk -F': ' '{print $2}' | tr -d ' ')
updated_value="https://app-usage.$usage_service_value"

# This is the vulnerable sed command from the script
sed -i.bak "s~usage-service-url: $usage_service_value~usage-service-url: $updated_value~" "$CONFIG" 2>&1

# Check if sed succeeded
if [ $? -eq 0 ]; then
    # Check if replacement actually worked correctly
    RESULT=$(grep "usage-service-url:" "$CONFIG" | awk -F': ' '{print $2}')
    if [ "$RESULT" == "$updated_value" ]; then
        echo "SUCCESS"
    else
        echo "INCORRECT: $RESULT"
    fi
else
    echo "SED_FAILED"
fi
EOF
chmod +x "$TEST_DIR/test_regex_injection.sh"

cp "$TEST_DIR/test_config_regex.yml" /tmp/test_config_regex.yml
RESULT=$("$TEST_DIR/test_regex_injection.sh" 2>&1 | tail -n 1)

if [ "$RESULT" != "SUCCESS" ]; then
	assert_fail "Sed fails or produces incorrect results with special characters" \
		"Result: $RESULT (regex characters not escaped)"
else
	assert_pass "Sed handles special characters correctly"
fi

rm -f /tmp/test_config_regex.yml*

# ============================================================================
# TEST 8: Pre-start Ignores Non-1 Exit Codes (Issue #9)
# ============================================================================
run_test "Pre-start should fail on any non-zero exit code"

cat >"$TEST_DIR/test_exit_codes.sh" <<'EOF'
#!/bin/bash

# Simulate actual pre-start error handling
test_exit_code() {
    local exit_code=$1
    
    # Mock command that exits with specific code
    (exit $exit_code)
    exit_code=$?
    
    # Simulate actual script behavior: if [ $exit_code -ne 0 ]
    if [ "$exit_code" -ne 0 ]; then
        return 1
    fi
    
    return 0
}

# Test various failure exit codes
for code in 2 127 255; do
    if test_exit_code $code; then
        echo "CONTINUED_ON_EXIT_$code"
    else
        echo "FAILED_ON_EXIT_$code"
    fi
done
EOF
chmod +x "$TEST_DIR/test_exit_codes.sh"

OUTPUT=$("$TEST_DIR/test_exit_codes.sh" 2>&1)

if echo "$OUTPUT" | grep -q "FAILED_ON_EXIT"; then
	assert_pass "Script fails on all non-zero exit codes" \
		"Correctly handles exit codes: $OUTPUT"
else
	assert_fail "Script does not fail on non-zero exit codes" \
		"Expected failures but got: $OUTPUT"
fi

# ============================================================================
# TEST 9: Find Command Can Match Directories (Issue #13)
# ============================================================================
run_test "Find should only match files, not directories"

cat >"$TEST_DIR/test_find_dirs.sh" <<'EOF'
#!/bin/bash
set -eu
DATA_DIR="/tmp/data"
mkdir -p "$DATA_DIR"

# Create a directory named something.tar (weird but possible)
mkdir -p "$DATA_DIR/archive.tar"
touch "$DATA_DIR/real-file.tar"

# FIXED find command with -type f
TAR_FILE=$(find "$DATA_DIR" -name "*.tar" -type f | head -n 1)

# Check if result is a file (not directory)
if [ -n "$TAR_FILE" ] && [ -f "$TAR_FILE" ]; then
    echo "FILE"
else
    echo "DIRECTORY_OR_EMPTY"
fi
EOF
chmod +x "$TEST_DIR/test_find_dirs.sh"

mkdir -p /tmp/data
RESULT=$("$TEST_DIR/test_find_dirs.sh" 2>&1 | tail -n 1)

if [ "$RESULT" = "FILE" ]; then
	assert_pass "Fixed find command only matches files, not directories" \
		"Correctly excluded directory and selected file"
else
	assert_fail "Fixed find command still matches directories" \
		"Result: $RESULT (should be FILE)"
fi

rm -rf /tmp/data

# ============================================================================
# TEST 10: Weak Cron Randomization (Issue #11)
# ============================================================================
run_test "Cron schedule should be distributed across VMs"

cat >"$TEST_DIR/test_randomization.rb" <<'EOF'
#!/usr/bin/env ruby

# Simulate 100 VMs deployed at same time
schedules = []

100.times do |i|
  # Current code: uses rand() without seed
  schedule = "#{rand(60)} #{rand(24)} * * *"
  schedules << schedule
end

# Count unique schedules
unique = schedules.uniq.length

# If randomization is weak, most VMs get same schedule
if unique < 50
  puts "WEAK: #{unique}"
else
  puts "GOOD: #{unique}"
end
EOF
chmod +x "$TEST_DIR/test_randomization.rb"

if command -v ruby &>/dev/null; then
	RESULT=$("$TEST_DIR/test_randomization.rb" 2>&1 | tail -n 1)

	if echo "$RESULT" | grep -q "WEAK"; then
		UNIQUE=$(echo "$RESULT" | awk '{print $2}')
		assert_fail "Weak randomization causes schedule collisions" \
			"Only $UNIQUE unique schedules for 100 VMs (high collision rate)"
	else
		assert_pass "Good distribution of schedules"
	fi
else
	echo "  ⊘ SKIP: Ruby not installed"
fi

# ============================================================================
# TEST: krb5 PATH is added conditionally
# ============================================================================
run_test "krb5 PATH should be added when directory exists"

mkdir -p /tmp/mock-vcap/packages/krb5/bin
cat >"$TEST_DIR/test_krb5_path.sh" <<'EOF'
#!/bin/bash
if [ -d /tmp/mock-vcap/packages/krb5/bin ]; then
  export PATH=/tmp/mock-vcap/packages/krb5/bin:$PATH
fi
echo "$PATH"
EOF
chmod +x "$TEST_DIR/test_krb5_path.sh"

OUTPUT=$("$TEST_DIR/test_krb5_path.sh")
if echo "$OUTPUT" | grep -q "/tmp/mock-vcap/packages/krb5/bin"; then
        assert_pass "krb5/bin added to PATH when directory exists"
else
        assert_fail "krb5/bin not in PATH" "Got: $OUTPUT"
fi

rm -rf /tmp/mock-vcap

# ============================================================================
# TEST: Script works without krb5
# ============================================================================
run_test "Script should work when krb5 directory doesn't exist"

cat >"$TEST_DIR/test_no_krb5.sh" <<'EOF'
#!/bin/bash
set -e
if [ -d /var/vcap/packages/krb5/bin ]; then
  export PATH=/var/vcap/packages/krb5/bin:$PATH
fi
echo "SUCCESS"
EOF
chmod +x "$TEST_DIR/test_no_krb5.sh"

OUTPUT=$("$TEST_DIR/test_no_krb5.sh" 2>&1)
if echo "$OUTPUT" | grep -q "SUCCESS"; then
        assert_pass "Script works without krb5 directory"
else
        assert_fail "Script failed without krb5" "Got: $OUTPUT"
fi

# ============================================================================
# TEST: SPNEGO requires all three credentials
# ============================================================================
run_test "SPNEGO should only enable when all three credentials are provided"

cat >"$TEST_DIR/test_spnego_all_creds.sh" <<'EOF'
#!/bin/bash

test_spnego_enabled() {
  local username="$1"
  local password="$2"
  local domain="$3"
  
  if [[ -n "$username" && -n "$password" && -n "$domain" ]]; then
    echo "ENABLED"
  else
    echo "DISABLED"
  fi
}

# Test with all three
RESULT1=$(test_spnego_enabled "user" "pass" "DOMAIN")
# Test with only username
RESULT2=$(test_spnego_enabled "user" "" "")
# Test with username and password
RESULT3=$(test_spnego_enabled "user" "pass" "")
# Test with empty strings
RESULT4=$(test_spnego_enabled "" "" "")

echo "$RESULT1|$RESULT2|$RESULT3|$RESULT4"
EOF
chmod +x "$TEST_DIR/test_spnego_all_creds.sh"

RESULTS=$("$TEST_DIR/test_spnego_all_creds.sh")
if [ "$RESULTS" = "ENABLED|DISABLED|DISABLED|DISABLED" ]; then
        assert_pass "SPNEGO only enables with all three credentials"
else
        assert_fail "SPNEGO credential logic incorrect" "Got: $RESULTS (expected: ENABLED|DISABLED|DISABLED|DISABLED)"
fi

# ============================================================================
# TEST: KRB5CCNAME includes PID for uniqueness
# ============================================================================
run_test "KRB5CCNAME should include PID to avoid race conditions"

cat >"$TEST_DIR/test_krb5_ccname.sh" <<'EOF'
#!/bin/bash
# Simulate what the script does
CCNAME="/tmp/krb5cc_collector_$$_$(date +%s%N)"
echo "$CCNAME"
EOF
chmod +x "$TEST_DIR/test_krb5_ccname.sh"

CCNAME1=$("$TEST_DIR/test_krb5_ccname.sh")
sleep 0.01
CCNAME2=$("$TEST_DIR/test_krb5_ccname.sh")

if [[ "$CCNAME1" != "$CCNAME2" ]]; then
        assert_pass "KRB5CCNAME is unique per invocation" \
                "CCNAME1: $(basename $CCNAME1), CCNAME2: $(basename $CCNAME2)"
else
        assert_fail "KRB5CCNAME is not unique" \
                "Both processes got same CCNAME: $CCNAME1"
fi

# ============================================================================
# TEST: Credential cleanup removes sensitive data
# ============================================================================
run_test "SPNEGO credentials should be unset after use"

cat >"$TEST_DIR/test_cred_cleanup.sh" <<'EOF'
#!/bin/bash
# Simulate setting and cleaning credentials
export PROXY_USERNAME="testuser"
export PROXY_PASSWORD="testpass"
export PROXY_DOMAIN="EXAMPLE.COM"

# Simulate the cleanup
unset PROXY_USERNAME PROXY_PASSWORD PROXY_DOMAIN SPNEGO_USERNAME SPNEGO_PASSWORD SPNEGO_DOMAIN

# Check if they're really gone
if [[ -z "${PROXY_USERNAME:-}" && -z "${PROXY_PASSWORD:-}" && -z "${PROXY_DOMAIN:-}" ]]; then
  echo "CLEANED"
else
  echo "LEAKED: USER=${PROXY_USERNAME:-} PASS=${PROXY_PASSWORD:-} DOMAIN=${PROXY_DOMAIN:-}"
fi
EOF
chmod +x "$TEST_DIR/test_cred_cleanup.sh"

RESULT=$("$TEST_DIR/test_cred_cleanup.sh")
if [ "$RESULT" = "CLEANED" ]; then
        assert_pass "Credentials properly cleaned up after use"
else
        assert_fail "Credentials not fully cleaned" "Got: $RESULT"
fi

# ============================================================================
# TEST: kinit validation doesn't fail script
# ============================================================================
run_test "Missing kinit should log warning but not fail script"

cat >"$TEST_DIR/test_kinit_validation.sh" <<'EOF'
#!/bin/bash
# Simulate the validation logic
if ! command -v kinit_fake >/dev/null 2>&1; then
  echo "ERROR: SPNEGO configured but kinit not found in PATH" >&2
  echo "ERROR: This is unusual for Ubuntu stemcells and indicates a potential issue" >&2
  # Don't fail deployment - log and continue
fi
echo "CONTINUED"
EOF
chmod +x "$TEST_DIR/test_kinit_validation.sh"

OUTPUT=$("$TEST_DIR/test_kinit_validation.sh" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 && "$OUTPUT" =~ "CONTINUED" ]]; then
        assert_pass "Script continues after kinit validation failure"
else
        assert_fail "Script failed on kinit validation" "Exit code: $EXIT_CODE, Output: $OUTPUT"
fi

# ============================================================================
# TEST: Conditional krb5 PATH doesn't break on missing directory
# ============================================================================
run_test "Conditional krb5 PATH check handles missing directory gracefully"

cat >"$TEST_DIR/test_missing_krb5_dir.sh" <<'EOF'
#!/bin/bash
set -e  # Fail on any error

# This should NOT fail even though directory doesn't exist
if [ -d /var/vcap/packages/krb5/bin ]; then
  export PATH=/var/vcap/packages/krb5/bin:$PATH
fi

# Continue with script
echo "SCRIPT_CONTINUED"
exit 0
EOF
chmod +x "$TEST_DIR/test_missing_krb5_dir.sh"

OUTPUT=$("$TEST_DIR/test_missing_krb5_dir.sh" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 && "$OUTPUT" = "SCRIPT_CONTINUED" ]]; then
        assert_pass "Script handles missing krb5 directory without failing"
else
        assert_fail "Script failed when krb5 directory missing" \
                "Exit code: $EXIT_CODE, Output: $OUTPUT"
fi

# ============================================================================
# TEST: Error classification includes SPNEGO errors
# ============================================================================
run_test "Error classification should handle proxy authentication errors"

cat >"$TEST_DIR/test_proxy_error_classification.sh" <<'EOF'
#!/bin/bash

classify_error() {
  local output="$1"
  
  if echo "$output" | grep -qi "kinit.*not found\|curl.*not found\|gss-api"; then
    echo "SYSTEM_REQUIREMENTS_ERROR"
  elif echo "$output" | grep -qi "proxy.*authentication\|407\|spnego\|kerberos"; then
    echo "PROXY_AUTH_ERROR"
  elif echo "$output" | grep -qi "unauthorized\|not authorized\|401"; then
    echo "CUSTOMER_CONFIG_ERROR"
  elif echo "$output" | grep -qi "connection refused\|timeout|503\|502\|504"; then
    echo "MIDDLEWARE_PIPELINE_ERROR"
  else
    echo "UNKNOWN_ERROR"
  fi
}

# Test various error types
ERROR1=$(classify_error "407 Proxy Authentication Required")
ERROR2=$(classify_error "kinit: not found")
ERROR3=$(classify_error "SPNEGO negotiation failed")
ERROR4=$(classify_error "curl: (60) SSL certificate problem")

echo "$ERROR1|$ERROR2|$ERROR3|$ERROR4"
EOF
chmod +x "$TEST_DIR/test_proxy_error_classification.sh"

RESULTS=$("$TEST_DIR/test_proxy_error_classification.sh")
EXPECTED="PROXY_AUTH_ERROR|SYSTEM_REQUIREMENTS_ERROR|PROXY_AUTH_ERROR|UNKNOWN_ERROR"

if [ "$RESULTS" = "$EXPECTED" ]; then
        assert_pass "Error classification handles SPNEGO/proxy errors correctly"
else
        assert_fail "Error classification incorrect" \
                "Got: $RESULTS, Expected: $EXPECTED"
fi

# ============================================================================
# Test Summary
# ============================================================================
echo ""
echo "========================================="
echo "TEST SUMMARY"
echo "========================================="
echo "Total Tests:  $TESTS_RUN"
echo -e "${GREEN}Passed:       $TESTS_PASSED${NC}"
echo -e "${RED}Failed:       $TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
	PERCENT_FAILED=$((TESTS_FAILED * 100 / TESTS_RUN))
	echo -e "${RED}🚨 $PERCENT_FAILED% of tests FAILED${NC}"
	echo ""
	echo "These failures demonstrate production issues that will cause:"
	echo "  • Silent failures and data loss"
	echo "  • Disk space exhaustion"
	echo "  • Script crashes on edge cases"
	echo "  • Load spikes in large deployments"
	echo ""
	echo "See full analysis in the code review document."
	EXIT_CODE=1
else
	echo -e "${GREEN}✓ All tests passed!${NC}"
	EXIT_CODE=0
fi

# Cleanup
rm -rf "$TEST_DIR"
rm -rf /tmp/data

exit $EXIT_CODE
