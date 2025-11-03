# SPNEGO Testing Guide for Telemetry Release

This guide explains how to test the SPNEGO proxy authentication feature for both the **collector** and **centralizer** BOSH jobs.

---

## Overview

The telemetry tile has two components that send data through SPNEGO-authenticated proxies:

1. **Collector** (`telemetry-collector` job): Uses `telemetry-cli` (Go binary)
2. **Centralizer** (`telemetry-centralizer` job): Uses `curl` with `--negotiate` flag

Both paths need to be tested to ensure production readiness.

---

## Prerequisites

### 1. Start Test Environment

```bash
cd /Users/driddle/workspace/broadcom/tile/tpi-telemetry-cli/test-integration
docker-compose up -d
```

This starts:
- Kerberos KDC (localhost:88)
- SPNEGO-authenticated proxy (localhost:3128)

### 2. Get Staging API Key

You'll need a valid Broadcom staging API key. Set it as an environment variable:

```bash
export STAGING_API_KEY="your-api-key-here"
```

Or the test scripts will prompt you for it interactively.

### 3. Prepare Test Data

For the **collector test**, you'll need a real telemetry tarball from a foundation.

For the **centralizer test**, the script generates synthetic JSON data automatically.

---

## Test 1: Collector Path (CLI-based)

**What it tests:** The `telemetry-collector` BOSH job uses `telemetry-cli send` command, which implements SPNEGO via Go code that shells out to `kinit` and `curl`.

**Test script:** `tpi-telemetry-cli/test-integration/test-spnego-staging-MAC-INTERACTIVE.sh`

### Run the test:

```bash
cd /Users/driddle/workspace/broadcom/tile/tpi-telemetry-cli/test-integration
./test-spnego-staging-MAC-INTERACTIVE.sh
```

### What it validates:

- ✅ Go code generates correct bash script
- ✅ CLI validates SPNEGO credentials (username, password, domain)
- ✅ CLI sets unique Kerberos credential cache (F001 fix)
- ✅ kinit authentication against KDC
- ✅ curl --negotiate --proxy-negotiate sends data through proxy
- ✅ Data reaches real staging endpoint (HTTP 201)

### Expected output:

```
🎉 SUCCESS! Data sent to staging via SPNEGO proxy! 🎉
═══════════════════════════════════════════════════════════════

What was demonstrated:
  ✓ Native macOS Kerberos (Heimdal) authentication
  ✓ SPNEGO token generation (GSS-API)
  ✓ Proxy authentication (HTTP 407 → 201)
  ✓ Data sent to REAL staging endpoint

SPNEGO AUTHENTICATION IS WORKING END-TO-END! 🚀
```

---

## Test 2: Centralizer Path (curl-based)

**What it tests:** The `telemetry-centralizer` BOSH job uses a bash script (`spnego-curl.sh.erb`) that directly calls `kinit` and `curl --negotiate`.

**Test script:** `telemetry-release/test-centralizer-spnego-staging.sh`

### Run the test:

```bash
cd /Users/driddle/workspace/tile/telemetry-release
./test-centralizer-spnego-staging.sh
```

### What it validates:

- ✅ Bash script kinit authentication (exact centralizer code)
- ✅ Kerberos ticket verification (`klist -s`)
- ✅ Unique credential cache per process (F001 fix)
- ✅ curl -K config file method (same as centralizer)
- ✅ curl --negotiate --proxy-negotiate flags
- ✅ Data piped to stdin (simulates fluentd → curl)
- ✅ Data reaches real staging endpoint (HTTP 201)

### Expected output:

```
🎉 SUCCESS! Centralizer SPNEGO method WORKS! 🎉
═══════════════════════════════════════════════════════════════

What was validated:
  ✓ kinit authentication (same as centralizer)
  ✓ Kerberos ticket verification (same as centralizer)
  ✓ curl --negotiate --proxy-negotiate (EXACT centralizer command)
  ✓ curl -K config file method (same as centralizer)
  ✓ Data piped to stdin (same as fluentd → centralizer)
  ✓ Unique credential cache per process (F001 fix validated)
  ✓ Data sent to REAL staging endpoint

CENTRALIZER SPNEGO IMPLEMENTATION IS PRODUCTION-READY! 🚀
```

---

## Key Differences Between Tests

| Aspect | Collector Test (CLI) | Centralizer Test (curl) |
|--------|---------------------|------------------------|
| **Code Path** | Go → bash script → kinit/curl | bash script → kinit/curl |
| **Data Format** | .tar.gz file | JSON (from fluentd) |
| **Script Generation** | Dynamic (Go code) | Static (ERB template) |
| **Input Method** | `--data-binary @file.tar.gz` | stdin pipe |
| **Credential Cache** | `/tmp/krb5cc_telemetry_<pid>_<nanos>` | `/tmp/krb5cc_centralizer_$$` |
| **Frequency** | Once per collection cycle (hourly/daily) | High frequency (flush_interval, default 3600s) |

---

## What Makes These Tests Comprehensive

### 1. Real Network Environment
- ✅ Real Kerberos KDC (not mocked)
- ✅ Real SPNEGO-authenticated proxy (Apache with mod_auth_gssapi)
- ✅ Real staging endpoint (telemetry-staging.pivotal.io)
- ✅ Real API key validation

### 2. Exact Code Path
Both tests use the **EXACT** code that will run in production:

**Collector:**
```bash
# Same command the BOSH job runs
$COLLECTOR_BIN send --path "$TAR_FILE" --api-key "$API_KEY" \
  --proxy-username "$USERNAME" --proxy-password "$PASSWORD" --proxy-domain "$DOMAIN"
```

**Centralizer:**
```bash
# Same curl command from spnego-curl.sh.erb
curl -s --negotiate --proxy-negotiate -K /var/vcap/jobs/telemetry-centralizer/config/curl_config
```

### 3. F001 Fix Validation
Both tests verify the critical race condition fix:
- Unique credential cache per process
- No collision between concurrent operations
- Proper cleanup on exit

### 4. Error Scenarios
The tests validate proper error handling for:
- HTTP 401 (invalid API key)
- HTTP 407 (proxy auth failure)
- HTTP 500-504 (server errors)
- HTTP 000 (connection failure)
- Network timeouts
- Missing system requirements

---

## Troubleshooting

### Test fails with "KDC not running"

```bash
cd /Users/driddle/workspace/broadcom/tile/tpi-telemetry-cli/test-integration
docker-compose up -d
docker ps  # Verify containers are running
```

### Test fails with "HTTP 401"

Check your API key:
```bash
echo $STAGING_API_KEY
# Should output your valid staging API key
```

### Test fails with "HTTP 407"

This means proxy authentication failed. Check:
1. Is the SPNEGO proxy running? (`docker ps | grep apache-proxy`)
2. Was the Kerberos ticket obtained? (test script shows `klist` output)
3. Does curl have GSS-API support? (`curl -V | grep -i gss`)

### Test fails with "kinit not found"

On macOS, kinit should be built-in. Check:
```bash
which kinit
# Should output: /usr/bin/kinit
```

### Test fails with "curl does not have GSS-API support"

On macOS, the built-in curl should have GSS-API. Check:
```bash
curl -V | grep -i gss
# Should output: GSS-API Kerberos
```

---

## Production Validation Checklist

Before deploying to production, ensure both tests pass:

- [ ] Collector test passes (CLI-based SPNEGO)
- [ ] Centralizer test passes (curl-based SPNEGO)
- [ ] Both tests send data to staging endpoint (HTTP 201)
- [ ] Both tests validate F001 fix (unique credential cache)
- [ ] Both tests clean up properly (no leaked files/tickets)

Once both tests pass, you have **high confidence** that:
1. The collector will successfully send telemetry through SPNEGO proxy
2. The centralizer will successfully forward telemetry through SPNEGO proxy
3. The F001 race condition is fixed in both components
4. Error handling works correctly in both paths

---

## Next Steps After Testing

1. **Staging Deployment**: Deploy tile to staging environment with real Active Directory
2. **Soak Test**: Run for 24+ hours to validate ticket renewal and long-term stability
3. **Load Test**: Multiple collectors + high-frequency centralizer on same VM
4. **Production Deployment**: Deploy to production with confidence

---

## Files Modified for SPNEGO

### Collector (`telemetry-collector` job):
- `jobs/telemetry-collector/spec` - Added proxy_username/password/domain properties
- `jobs/telemetry-collector/templates/telemetry-collect-send.erb` - Sets SPNEGO env vars

### Centralizer (`telemetry-centralizer` job):
- `jobs/telemetry-centralizer/spec` - Added proxy_username/password/domain properties
- `jobs/telemetry-centralizer/templates/config.erb` - Conditional SPNEGO wrapper
- `jobs/telemetry-centralizer/templates/spnego-curl.sh.erb` - SPNEGO authentication script (NEW)

### CLI (`tpi-telemetry-cli`):
- `network/spnego_transport.go` - Credential validation
- `network/spnego_shell.go` - SPNEGO shell-out implementation
- `network/http_client.go` - Fail-fast when SPNEGO credentials provided
- `cmd/send.go` - SPNEGO command-line flags and execution path

---

## References

- **SPNEGO Security Considerations**: `tpi-telemetry-cli/SPNEGO_SECURITY_CONSIDERATIONS.md`
- **Code Review Summary**: `tpi-aqueduct-loader/SPNEGO_CODE_REVIEW_SUMMARY.md`
- **Comprehensive Review**: `tpi-aqueduct-loader/COMPREHENSIVE_CODE_REVIEW_SPNEGO.md`
- **CLI Integration Tests**: `tpi-telemetry-cli/test-integration/README.md`

---

**Last Updated**: October 24, 2025  
**Status**: Both test paths validated and passing ✅

