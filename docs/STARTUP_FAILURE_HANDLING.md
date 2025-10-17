# Startup Failure Handling

## Problem

When deploying the telemetry tile, the pre-start script would fail if the telemetry send operation failed, blocking the entire installation. This could happen due to:

- **Network issues**: Telemetry endpoint temporarily unavailable
- **API key problems**: Invalid or expired API keys
- **Infrastructure issues**: Middleware pipeline failures (503, 502, 504 errors)
- **Configuration errors**: Incorrect endpoint URLs or proxy settings

## Solution

The telemetry system now implements graceful degradation during startup:

1. **Data collection MUST succeed** - This is critical for functionality
2. **Send failures are handled gracefully** - Installation continues successfully
3. **Structured error logging** - Enables monitoring and debugging
4. **Cron job retry mechanism** - Collected data is retried later

## Implementation Details

### Error Classification

The system classifies send failures into three categories:

- **CUSTOMER_CONFIG_ERROR**: API key issues (401, unauthorized)
- **MIDDLEWARE_PIPELINE_ERROR**: Infrastructure issues (503, 502, 504, timeouts, connection refused)
- **UNKNOWN_ERROR**: All other failures

### Logging Strategy

#### Structured Logging (JSON)

**Success Logs**: `/var/vcap/sys/log/telemetry-collector/send-success.log`
```json
{
  "timestamp": "2024-01-15T10:30:00Z",
  "status": "success",
  "message": "Telemetry sent successfully during startup"
}
```

**Failure Logs**: `/var/vcap/sys/log/telemetry-collector/send-failures.log`
```json
{
  "timestamp": "2024-01-15T10:30:00Z",
  "error_type": "CUSTOMER_CONFIG_ERROR",
  "message": "API key is invalid or expired",
  "exit_code": 1,
  "output": "Error: user is not authorized to perform this action"
}
```

#### Human-Readable Logging (stderr)

```
WARNING: Telemetry send failed during startup - data collected successfully and will be retried by cron job
  Error type: CUSTOMER_CONFIG_ERROR
  Details: API key is invalid or expired
```

### Script Behavior

#### Pre-Start Script (`pre-start.erb`)

- Removes the `set +e` logic that was masking failures
- Ensures proper error propagation for collection failures
- Always calls the collect-send script

#### Collect-Send Script (`telemetry-collect-send.erb`)

- **Collection phase**: Must succeed or script exits with error
- **Send phase**: Attempts send but doesn't fail installation if it errors
- **Exit behavior**: Always exits 0 after successful collection (even if send fails)

## Operational Impact

### Before (Problematic Behavior)

```
Installation → Pre-start → Collect → Send → FAIL → Installation blocked
```

### After (Fixed Behavior)

```
Installation → Pre-start → Collect → Send attempt → Log error → Installation continues
                                                      ↓
                                              Cron job retries later
```

### Benefits

1. **Installations no longer blocked** by temporary network issues
2. **Bad API keys don't prevent installation** - logged for investigation
3. **Collected data preserved** and retried by cron job
4. **Structured logs enable monitoring** and alerting
5. **Operators get clear error messages** for troubleshooting

## Monitoring and Alerting

### Recommended Alerts

1. **High failure rate**: Alert if >10% of send attempts fail
2. **Customer config errors**: Alert on CUSTOMER_CONFIG_ERROR (requires operator action)
3. **Infrastructure issues**: Alert on MIDDLEWARE_PIPELINE_ERROR (may be temporary)
4. **No success logs**: Alert if no successful sends in 24 hours

### Log Analysis

```bash
# Count error types
grep "error_type" /var/vcap/sys/log/telemetry-collector/send-failures.log | \
  jq -r '.error_type' | sort | uniq -c

# Check recent failures
tail -100 /var/vcap/sys/log/telemetry-collector/send-failures.log | \
  jq -r '.timestamp + " " + .error_type + ": " + .message'

# Monitor success rate
echo "Success: $(wc -l < /var/vcap/sys/log/telemetry-collector/send-success.log)"
echo "Failures: $(wc -l < /var/vcap/sys/log/telemetry-collector/send-failures.log)"
```

## Testing

The implementation includes comprehensive tests:

- **Error classification tests**: Verify correct categorization of different error types
- **Pre-start behavior tests**: Ensure installation continues on send failures
- **Logging tests**: Verify structured and human-readable logs are created
- **Integration tests**: End-to-end scenarios with various failure modes

## Backward Compatibility

This change is fully backward compatible:

- **No configuration changes** required
- **No API changes** to telemetry endpoints
- **No changes to data format** or collection behavior
- **Only affects startup behavior** - normal operation unchanged

## Troubleshooting

### Common Issues

1. **"Installation succeeded but no telemetry data"**
   - Check `/var/vcap/sys/log/telemetry-collector/send-failures.log`
   - Verify API key is valid and endpoint is reachable
   - Check cron job is running: `crontab -l | grep telemetry`

2. **"High failure rate in monitoring"**
   - Check network connectivity to telemetry endpoint
   - Verify proxy settings if using corporate network
   - Check for rate limiting on telemetry endpoint

3. **"Customer config errors"**
   - Verify API key is correct and not expired
   - Check endpoint URL configuration
   - Ensure proper permissions for the API key

### Debug Commands

```bash
# Check recent telemetry activity
sudo tail -50 /var/vcap/sys/log/telemetry-collector/telemetry-collect-send.log

# Test telemetry endpoint connectivity
curl -v -H "Authorization: Bearer $API_KEY" $TELEMETRY_ENDPOINT

# Check cron job status
sudo systemctl status cron
crontab -l | grep telemetry

# Verify collected data exists
ls -la /var/vcap/data/telemetry-collector/*.tar
```

## Related Documentation

- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) - General troubleshooting guide
- [ARCHITECTURE.md](../ARCHITECTURE.md) - System architecture overview
- [ROBUSTNESS_TEST_RESULTS.md](../ROBUSTNESS_TEST_RESULTS.md) - Test results and validation
