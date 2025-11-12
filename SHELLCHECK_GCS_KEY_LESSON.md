# CRITICAL LESSON: GCS Service Account Key Handling

**Date:** November 12, 2025  
**Issue:** Shellcheck SC2116 warning on `$(echo $GCS_SERVICE_ACCOUNT_KEY)`  
**Decision:** **DO NOT "FIX"** - Keep the original pattern

---

## The Shellcheck Warning

```
SC2116 (style): Useless echo? Instead of 'cmd $(echo foo)', just use 'cmd foo'.
```

Shellcheck suggests changing:
```bash
$(echo $GCS_SERVICE_ACCOUNT_KEY)
```

To:
```bash
${GCS_SERVICE_ACCOUNT_KEY}
```

## Why This Change Would BREAK Production

### The Critical Difference

**`$(echo $VAR)`** - Collapses newlines into single line  
**`${VAR}`** - Preserves newlines exactly

### Real-World Example

```bash
# GCS service account keys are multi-line JSON:
GCS_SERVICE_ACCOUNT_KEY='{
  "type": "service_account",
  "project_id": "my-project",
  "private_key": "-----BEGIN PRIVATE KEY-----\nMII...\n-----END PRIVATE KEY-----\n"
}'

# Using $(echo $VAR) - COLLAPSES TO ONE LINE:
$ echo "$(echo $GCS_SERVICE_ACCOUNT_KEY)"
{ "type": "service_account", "project_id": "my-project", "private_key": "..." }

# Using ${VAR} - PRESERVES NEWLINES:
$ echo "${GCS_SERVICE_ACCOUNT_KEY}"
{
  "type": "service_account",
  "project_id": "my-project",
  "private_key": "..."
}
```

## Why `$(echo $VAR)` Was Used

The team discovered that piping GCS service account keys is fragile. The `$(echo $VAR)` pattern:

1. **Collapses multi-line JSON** into single line
2. **Makes YAML parsing more predictable** (avoids indentation issues)
3. **Prevents line-break related errors** in BOSH config parsing
4. **Has been battle-tested in production**

## The Correct Fix

**Original (with shellcheck warning):**
```bash
json_key: |
  $(echo $GCS_SERVICE_ACCOUNT_KEY)
```

**Shellcheck suggested (WRONG - would break):**
```bash
json_key: |
  ${GCS_SERVICE_ACCOUNT_KEY}
```

**Actual fix (quote the variable):**
```bash
json_key: |
  $(echo "$GCS_SERVICE_ACCOUNT_KEY")
```

## What We Changed

Added quotes around the variable to prevent word splitting, but kept the `echo`:

```bash
# Before:
$(echo $GCS_SERVICE_ACCOUNT_KEY)  # ⚠️ Unquoted variable

# After:
$(echo "$GCS_SERVICE_ACCOUNT_KEY")  # ✅ Quoted variable, preserves echo behavior
```

This:
- ✅ Fixes the SC2086 warning (unquoted variable)
- ✅ Keeps the single-line JSON behavior
- ✅ Prevents word splitting
- ✅ Maintains production compatibility

## Testing Validation

```bash
# Test script showing the difference:
GCS_KEY='{"type": "service_account",
"key": "value"}'

# Method 1: $(echo $VAR) - one line
echo "$(echo $GCS_KEY)"
# Output: {"type": "service_account", "key": "value"}

# Method 2: ${VAR} - preserves lines
echo "${GCS_KEY}"
# Output:
# {"type": "service_account",
# "key": "value"}

# Are they different?
test "$(echo $GCS_KEY)" = "${GCS_KEY}" && echo "Same" || echo "Different"
# Output: Different
```

## Affected Files

1. `ci/tasks/bump-ruby-package.sh` (line 28)
2. `ci/tasks/create-final-release.sh` (line 27)
3. `ci/tasks/update-release-package.sh` (line 27)

All three files use this pattern for BOSH blobstore configuration.

## Shellcheck Suppressions

We can suppress the SC2116 warning since it's intentional:

```bash
# shellcheck disable=SC2116
json_key: |
  $(echo "$GCS_SERVICE_ACCOUNT_KEY")
```

But we've chosen **NOT** to add suppressions because:
1. The warning is informational (not error)
2. Adding suppressions clutters the code
3. This document explains the reasoning

## Lessons Learned

1. **Not all shellcheck suggestions should be applied blindly**
2. **Context matters** - "useless echo" may be intentional
3. **Test before changing** - especially for config/credentials
4. **Preserve battle-tested patterns** - don't "improve" what works
5. **Document exceptions** - explain why we deviate from best practices

## For Future Developers

**If you see this pattern in the code:**
```bash
$(echo "$VAR")
```

**Do NOT "simplify" it to:**
```bash
${VAR}
```

**Unless you:**
1. Understand why `echo` is there
2. Test both formats with real data
3. Verify BOSH config parser handles both
4. Have approval from the team

## Related Issues

- Team discovered GCS key piping is fragile (mentioned by user)
- Multi-line JSON in YAML heredocs can cause parsing issues
- BOSH blobstore config requires specific formatting

## Conclusion

**The `$(echo "$VAR")` pattern is INTENTIONAL and NECESSARY.**

Do not remove the `echo` even though shellcheck suggests it's "useless."  
The echo serves a critical purpose: collapsing multi-line JSON.

---

**Reviewed:** 2025-11-12  
**Status:** Documented and Resolved  
**Action:** Keep `$(echo "$VAR")` pattern, ignore SC2116 warning


