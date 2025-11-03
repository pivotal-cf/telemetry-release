# macOS Development Guide for Telemetry

This guide documents macOS-specific considerations when developing and testing the telemetry release.

---

## Critical: GNU Tar Required

### Problem

macOS ships with BSD `tar`, which adds Apple metadata files to tarballs:
- `._filename` - Apple Double files (extended attributes)
- `.DS_Store` - Finder folder metadata

These files **break telemetry uploads** because the endpoint rejects unrecognized files.

### Solution

**ALWAYS use GNU tar (`gtar`) when creating tarballs on macOS.**

### Installation

```bash
brew install gnu-tar
```

Verify installation:
```bash
gtar --version
# Should output: tar (GNU tar) 1.35
```

### Usage

**Creating tarballs:**
```bash
# ✅ CORRECT: GNU tar with exclusions
gtar --exclude='._*' --exclude='.DS_Store' -cf telemetry-data.tar opsmanager/

# ❌ WRONG: BSD tar (macOS default)
tar -cf telemetry-data.tar opsmanager/
```

**Verifying tarballs:**
```bash
# Check for Apple metadata files (should be empty)
tar -tvf telemetry-data.tar | grep -E '\._|\.DS_Store'

# Should output nothing if clean
```

---

## Common Errors

### Error: `._` Files in Tarball

```json
{
  "error": {
    "code": "500",
    "message": "file . in uploaded TAR does not belong to a recognized dataset directory. Found: ._opsmanager"
  }
}
```

**Cause:** Used BSD tar instead of GNU tar  
**Solution:** Recreate tarball with `gtar --exclude='._*' --exclude='.DS_Store'`

### Error: `.DS_Store` Files

```json
{
  "error": {
    "code": "500",
    "message": "file . in uploaded TAR does not belong to a recognized dataset directory. Found: .DS_Store"
  }
}
```

**Cause:** Finder created `.DS_Store` in your data directory  
**Solution:** Use GNU tar with exclusions as shown above

---

## Testing SPNEGO on macOS

### Prerequisites

macOS has built-in Kerberos support (Heimdal):
- ✅ `kinit` - already installed
- ✅ `klist` - already installed  
- ✅ `kdestroy` - already installed
- ✅ `curl` with GSS-API support - already installed

### Verify curl has GSS-API

```bash
curl -V | grep -i gss
# Should output: GSS-API Kerberos
```

If not present, your curl installation is broken (very unusual on macOS).

### Running Tests

```bash
# Start test environment (Docker)
cd /Users/driddle/workspace/broadcom/tile/tpi-telemetry-cli/test-integration
docker-compose up -d

# Test collector path (CLI-based)
./test-spnego-staging-MAC-INTERACTIVE.sh

# Test centralizer path (curl-based)
cd /Users/driddle/workspace/tile/telemetry-release
./test-centralizer-spnego-staging.sh
```

---

## Best Practices

### 1. Always Use GNU Tar for Telemetry

Add this to your shell profile (`~/.zshrc` or `~/.bash_profile`):

```bash
# Telemetry: Always use GNU tar
alias tar-telemetry='gtar --exclude="._*" --exclude=".DS_Store"'
```

Usage:
```bash
tar-telemetry -cf telemetry-data.tar opsmanager/
```

### 2. Clean Up Apple Metadata Before Archiving

```bash
# Remove all ._* files from a directory tree
find opsmanager -name '._*' -delete

# Remove all .DS_Store files
find opsmanager -name '.DS_Store' -delete

# Then create tarball
gtar -cf telemetry-data.tar opsmanager/
```

### 3. Verify Tarballs Before Upload

Always verify your tarball doesn't contain Apple metadata:

```bash
# List all files in tarball
tar -tvf telemetry-data.tar

# Check for problematic files (should output nothing)
tar -tvf telemetry-data.tar | grep -E '\._|\.DS_Store'
```

---

## BOSH Development on macOS

### Creating BOSH Releases

When creating BOSH releases from macOS:

```bash
# Use GNU tar for packaging
export TAR=gtar

# Create release
bosh create-release --force
```

### Uploading Test Data

When manually testing with real telemetry data:

```bash
# Collect data (CLI uses correct method automatically)
telemetry-cli collect --config config.yml

# Find generated tarball
TARBALL=$(find /var/vcap/data/telemetry-collector -name "*.tar" -type f | head -n 1)

# If on macOS and need to recreate, use GNU tar
cd /var/vcap/data/telemetry-collector
gtar --exclude='._*' --exclude='.DS_Store' -czf telemetry-upload.tar.gz opsmanager/ usage_service/
```

---

## Docker Considerations

### File Permissions

Docker on macOS uses different UID/GID mappings. When mounting volumes:

```yaml
# docker-compose.yml
volumes:
  - ./test-data:/data:ro  # Read-only to prevent permission issues
```

### Line Endings

Ensure scripts use Unix line endings (LF, not CRLF):

```bash
# Check line endings
file script.sh
# Should output: script.sh: Bourne-Again shell script text executable, ASCII text

# Fix if needed
dos2unix script.sh
```

---

## Troubleshooting

### "tar: Unrecognized archive format"

**Problem:** Trying to read a tarball created with wrong tool  
**Solution:** Verify tarball was created with GNU tar

### "Permission denied" when running tests

**Problem:** Script not executable  
**Solution:** 
```bash
chmod +x test-centralizer-spnego-staging.sh
```

### Docker containers won't start

**Problem:** Port conflicts  
**Solution:**
```bash
# Check what's using port 3128 or 88
lsof -i :3128
lsof -i :88

# Kill conflicting processes or change ports in docker-compose.yml
```

---

## References

- GNU tar manual: `man gtar` (after installing)
- macOS BSD tar issues: [Apple Technical Note TN2024](https://developer.apple.com/library/archive/qa/qa1940/_index.html)
- Kerberos on macOS: `man kinit`, `man klist`

---

## Quick Reference

**Install tools:**
```bash
brew install gnu-tar
```

**Create clean tarball:**
```bash
gtar --exclude='._*' --exclude='.DS_Store' -cf archive.tar data/
```

**Verify tarball:**
```bash
tar -tvf archive.tar | grep -E '\._|\.DS_Store' || echo "Clean ✅"
```

**Run SPNEGO tests:**
```bash
# Collector test
cd tpi-telemetry-cli/test-integration && ./test-spnego-staging-MAC-INTERACTIVE.sh

# Centralizer test  
cd telemetry-release && ./test-centralizer-spnego-staging.sh
```

---

**Remember:** When in doubt, use GNU tar with exclusions! 🍎

