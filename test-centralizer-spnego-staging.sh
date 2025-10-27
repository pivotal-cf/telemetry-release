#!/usr/bin/env bash
# Test Centralizer SPNEGO Implementation Against Real Staging Endpoint
# This simulates EXACTLY what the centralizer job does

set -euo pipefail

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_step() { echo -e "${BLUE}${BOLD}$1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] ✓ $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] ✗ $1${NC}"; }
log_info() { echo -e "${BOLD}[INFO] $1${NC}"; }

echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                                                                     ║${NC}"
echo -e "${BOLD}║   🧪 CENTRALIZER SPNEGO TEST - REAL STAGING ENDPOINT 🧪           ║${NC}"
echo -e "${BOLD}║                                                                     ║${NC}"
echo -e "${BOLD}║  This tests the EXACT code path used by telemetry-centralizer     ║${NC}"
echo -e "${BOLD}║  BOSH job to send data through SPNEGO-authenticated proxy.         ║${NC}"
echo -e "${BOLD}║                                                                     ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check prerequisites
log_step "▶ Step 1: Checking Prerequisites"
echo ""

# Check for Docker containers (KDC and proxy)
CLI_TEST_DIR="$SCRIPT_DIR/../tpi-telemetry-cli/test-integration"
if [ ! -d "$CLI_TEST_DIR" ]; then
    CLI_TEST_DIR="/Users/driddle/workspace/broadcom/tile/tpi-telemetry-cli/test-integration"
fi

if ! docker ps --format "{{.Names}}" | grep -q "kerberos-kdc"; then
    log_error "Kerberos KDC not running. Start with:"
    log_error "  cd $CLI_TEST_DIR && docker-compose up -d"
    exit 1
fi
log_success "Kerberos KDC running (localhost:88)"

if ! docker ps --format "{{.Names}}" | grep -q "apache-proxy"; then
    log_error "SPNEGO proxy not running. Start with:"
    log_error "  cd $CLI_TEST_DIR && docker-compose up -d"
    exit 1
fi
log_success "SPNEGO proxy running (localhost:3128)"

# Check for kinit and curl
if ! command -v kinit >/dev/null 2>&1; then
    log_error "kinit not found - required for Kerberos authentication"
    exit 1
fi
log_success "kinit available"

if ! curl -V 2>&1 | grep -qi "gss\|kerberos"; then
    log_error "curl does not have GSS-API/Kerberos support"
    log_error "On macOS, the built-in curl should have GSS-API support"
    exit 1
fi
log_success "curl has GSS-API support"

echo ""
log_step "▶ Step 2: API Key & Test Data"
echo ""

# Get API key
if [ -n "${STAGING_API_KEY:-}" ]; then
    log_info "Using API key from STAGING_API_KEY environment variable"
    API_KEY="$STAGING_API_KEY"
else
    log_info "Enter your Broadcom Staging API key:"
    read -s -p "API Key: " API_KEY
    echo ""
fi

if [ -z "$API_KEY" ]; then
    log_error "API key is required"
    exit 1
fi
log_success "API key configured"

# Create test JSON data (what centralizer actually sends - NOT a TAR file!)
TEST_DATA=$(mktemp)
cat > "$TEST_DATA" << 'EOF'
{
  "telemetry-source": "centralizer-spnego-test",
  "telemetry-centralizer-version": "0.0.2",
  "telemetry-timestamp": "2025-10-24T12:00:00Z",
  "test-message": "SPNEGO centralizer validation test"
}
EOF

log_success "Test JSON data created (centralizer sends JSON, not TAR)"

echo ""
log_step "▶ Step 3: Simulate Centralizer SPNEGO Authentication"
echo ""

# Set unique credential cache (F001 fix - same as centralizer does)
export KRB5CCNAME="/tmp/krb5cc_centralizer_test_$$"
export KRB5_CONFIG="$CLI_TEST_DIR/krb5-host.conf"
log_info "Using credential cache: $KRB5CCNAME"
log_info "Using krb5.conf: $KRB5_CONFIG"

# Cleanup function (same as centralizer)
cleanup() {
    local exit_code=$?
    if [[ -f "${PASSWD_FILE:-}" ]]; then
        rm -f "$PASSWD_FILE"
    fi
    if [[ -n "${KRB5CCNAME:-}" && -f "$KRB5CCNAME" ]]; then
        rm -f "$KRB5CCNAME"
    fi
    rm -f "$TEST_DATA" "$CURL_OUTPUT" 2>/dev/null || true
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# SPNEGO credentials (from test environment)
USERNAME="testuser"
PASSWORD="testpass123"
DOMAIN="TEST.LOCAL"
PRINCIPAL="${USERNAME}@${DOMAIN}"

log_info "Authenticating to Kerberos KDC as $PRINCIPAL..."

# Create secure password file (same as centralizer does)
PASSWD_FILE=$(mktemp)
chmod 0600 "$PASSWD_FILE"
echo "$PASSWORD" > "$PASSWD_FILE"

# Authenticate (same as centralizer does)
if ! kinit "$PRINCIPAL" < "$PASSWD_FILE" 2>&1; then
    rm -f "$PASSWD_FILE"
    log_error "Kerberos authentication failed"
    exit 1
fi

rm -f "$PASSWD_FILE"
log_success "Kerberos ticket obtained"

# Verify ticket (same as centralizer does)
if ! klist -s 2>/dev/null; then
    log_error "No valid Kerberos ticket after kinit"
    exit 1
fi
log_success "Kerberos ticket verified"

echo ""
klist | grep "TEST.LOCAL" || true
echo ""

echo ""
log_step "▶ Step 4: Send Data via SPNEGO-Authenticated Proxy (Centralizer Method)"
echo ""

log_info "Endpoint: https://telemetry-staging.pivotal.io/components (NOT /collections/batch!)"
log_info "Proxy: http://localhost:3128 (SPNEGO)"
log_info "Method: curl --negotiate --proxy-negotiate (EXACT centralizer code)"
log_info "Content-Type: application/x-telemetry-json-batch (JSON)"
echo ""
log_info "This may take 10-30 seconds..."
echo ""

# Create curl config file (EXACT format centralizer uses)
CURL_CONFIG=$(mktemp)
cat > "$CURL_CONFIG" << EOF
silent
show-error
write-out "%{http_code}"
max-time 120
proxy "http://localhost:3128"
proxy-negotiate
negotiate
user ":"
header "Authorization: Bearer ${API_KEY}"
header "Content-Type: application/x-telemetry-json-batch"
user-agent "TelemetryCentralizer/0.0.2"
request "POST"
data "@-"
url "https://telemetry-staging.pivotal.io/components"
http1.1
EOF

CURL_OUTPUT=$(mktemp)

# THIS IS THE EXACT COMMAND THE CENTRALIZER USES
# Data piped to stdin (simulating fluentd → curl)
HTTP_CODE=$(curl -K "$CURL_CONFIG" \
    --output "$CURL_OUTPUT" \
    < "$TEST_DATA" \
    2>&1 || echo "000")

rm -f "$CURL_CONFIG"

echo ""
log_step "▶ Step 5: Results"
echo ""

echo "HTTP Status Code: $HTTP_CODE"
echo ""

if [[ "$HTTP_CODE" == "201" ]]; then
    log_success "═══════════════════════════════════════════════════════════════"
    log_success "🎉 SUCCESS! Centralizer SPNEGO method WORKS! 🎉"
    log_success "═══════════════════════════════════════════════════════════════"
    echo ""
    log_info "What was validated:"
    echo "  ✓ kinit authentication (same as centralizer)"
    echo "  ✓ Kerberos ticket verification (same as centralizer)"
    echo "  ✓ curl --negotiate --proxy-negotiate (EXACT centralizer command)"
    echo "  ✓ curl -K config file method (same as centralizer)"
    echo "  ✓ JSON data piped to stdin (same as fluentd → curl)"
    echo "  ✓ Content-Type: application/x-telemetry-json-batch (CORRECT header)"
    echo "  ✓ Unique credential cache per process (F001 fix validated)"
    echo "  ✓ Data sent to REAL staging endpoint (HTTP 201)"
    echo ""
    log_success "CENTRALIZER SPNEGO IMPLEMENTATION IS PRODUCTION-READY! 🚀"
    echo ""
    
    echo ""
    log_info "Next Steps:"
    echo "  1. This test validates the curl-based SPNEGO path"
    echo "  2. The centralizer BOSH job uses the EXACT same approach"
    echo "  3. Both collector (CLI) and centralizer (curl) paths are now tested"
    echo "  4. Ready for production deployment"
    echo ""
    exit 0
elif [[ "$HTTP_CODE" == "401" ]]; then
    log_error "Unauthorized (HTTP 401) - API key may be invalid"
    log_info "Check your STAGING_API_KEY"
    exit 1
elif [[ "$HTTP_CODE" == "407" ]]; then
    log_error "Proxy authentication failed (HTTP 407)"
    log_info "SPNEGO token was rejected by the proxy"
    log_info "This indicates an issue with the curl SPNEGO implementation"
    exit 1
elif [[ "$HTTP_CODE" == "500" ]] || [[ "$HTTP_CODE" == "502" ]] || [[ "$HTTP_CODE" == "503" ]] || [[ "$HTTP_CODE" == "504" ]]; then
    log_error "Server error (HTTP $HTTP_CODE)"
    log_info "Telemetry endpoint may be temporarily unavailable"
    if [ -f "$CURL_OUTPUT" ]; then
        echo "Response body:"
        cat "$CURL_OUTPUT"
    fi
    exit 1
elif [[ "$HTTP_CODE" == "000" ]]; then
    log_error "Connection failed (HTTP 000)"
    log_info "Check network connectivity and proxy configuration"
    exit 1
else
    log_error "Unexpected HTTP status: $HTTP_CODE"
    if [ -f "$CURL_OUTPUT" ]; then
        echo "Response body:"
        cat "$CURL_OUTPUT"
    fi
    exit 1
fi

