#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
  echo -e "${BLUE}ℹ ${1}${NC}"
}

print_success() {
  echo -e "${GREEN}✓ ${1}${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠ ${1}${NC}"
}

print_error() {
  echo -e "${RED}✗ ${1}${NC}"
}

# Usage message
usage() {
  cat <<EOF
Usage: $0 <version>

Updates the krb5 (MIT Kerberos) BOSH blob to the specified version.

Arguments:
  version    The krb5 version to update to (e.g., 1.21.3, 1.22.1)

Example:
  $0 1.21.4

What this script does:
  1. Downloads the specified krb5 version from kerberos.org or MIT mirrors
  2. Validates tarball integrity
  3. Calculates SHA256 checksum
  4. Adds the blob to BOSH blobstore (GCS)
  5. Uploads the blob using service account credentials
  6. Updates config/blobs.yml
  7. Removes the old blob
  8. Optionally creates a test BOSH release

IMPORTANT: krb5 is used for SPNEGO authentication. After updating:
  - Deploy to staging first
  - Test SPNEGO proxy authentication thoroughly
  - Verify kinit/klist functionality in deployed jobs

Requirements:
  - bosh CLI installed
  - curl for downloading
  - service_account.json in repo root (GCS credentials)
  - Write access to GCS bucket: tpi-telemetry-release-blobs

Find available versions:
  - https://kerberos.org/dist/krb5/
  - https://github.com/krb5/krb5/releases

EOF
  exit 1
}

# Check for version argument
if [ $# -ne 1 ]; then
  print_error "Error: Version argument required"
  echo
  usage
fi

VERSION="$1"

# Validate version format (e.g., 1.21.3 or 1.21)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  print_error "Invalid version format: $VERSION"
  print_info "Expected format: X.Y.Z or X.Y (e.g., 1.21.3 or 1.21)"
  exit 1
fi

# Get repository root
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

print_info "Repository root: $REPO_ROOT"

# Check for required tools
if ! command -v bosh &>/dev/null; then
  print_error "bosh CLI is not installed"
  print_info "Install from: https://bosh.io/docs/cli-v2-install/"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  print_error "curl is not installed"
  exit 1
fi

# Check for service account credentials
SERVICE_ACCOUNT_JSON="$REPO_ROOT/service_account.json"
if [ ! -f "$SERVICE_ACCOUNT_JSON" ]; then
  print_error "service_account.json not found in repo root"
  print_info "This file is required for GCS blob upload"
  exit 1
fi

print_success "All prerequisites met"

# Set up GCS credentials for BOSH
export BOSH_GCS_CREDENTIALS_SOURCE="service_account_json_file"
export BOSH_GCS_SERVICE_ACCOUNT_JSON="$SERVICE_ACCOUNT_JSON"

print_info "GCS credentials configured"

# Create temporary directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

print_info "Created temporary directory: $TEMP_DIR"

# Determine major.minor version for URL path
MAJOR_MINOR=$(echo "$VERSION" | grep -oE '^[0-9]+\.[0-9]+')

# Download krb5 - try multiple mirrors
KRB5_TARBALL="krb5-$VERSION.tar.gz"
DOWNLOAD_URLS=(
  "https://kerberos.org/dist/krb5/${MAJOR_MINOR}/krb5-${VERSION}.tar.gz"
  "https://web.mit.edu/kerberos/dist/krb5/${MAJOR_MINOR}/krb5-${VERSION}.tar.gz"
)

print_info "Downloading krb5 $VERSION..."

DOWNLOAD_SUCCESS=false
for url in "${DOWNLOAD_URLS[@]}"; do
  print_info "Trying: $url"

  if curl -f -L -o "$TEMP_DIR/$KRB5_TARBALL" "$url"; then
    DOWNLOAD_SUCCESS=true
    print_success "Downloaded from: $url"
    break
  else
    print_warning "Failed to download from: $url"
  fi
done

if [ "$DOWNLOAD_SUCCESS" = false ]; then
  print_error "Failed to download krb5 $VERSION from any mirror"
  print_info "Verify the version exists at: https://kerberos.org/dist/krb5/${MAJOR_MINOR}/"
  exit 1
fi

# Calculate checksum
CHECKSUM=$(shasum -a 256 "$TEMP_DIR/$KRB5_TARBALL" | awk '{print $1}')
FILE_SIZE=$(stat -f%z "$TEMP_DIR/$KRB5_TARBALL" 2>/dev/null || stat -c%s "$TEMP_DIR/$KRB5_TARBALL")

print_info "SHA256: $CHECKSUM"
print_info "Size: $FILE_SIZE bytes"

# Verify tarball can be extracted (basic integrity check)
print_info "Verifying tarball integrity..."
if tar -tzf "$TEMP_DIR/$KRB5_TARBALL" >/dev/null 2>&1; then
  print_success "Tarball integrity verified"
else
  print_error "Tarball appears to be corrupted"
  exit 1
fi

# Find old krb5 blob
OLD_BLOB=$(grep "^krb5/krb5-" config/blobs.yml | head -1 | cut -d: -f1 || echo "")

if [ -n "$OLD_BLOB" ]; then
  print_info "Current blob: $OLD_BLOB"
else
  print_warning "No existing krb5 blob found in config/blobs.yml"
fi

# Add new blob
print_info "Adding new blob to blobstore..."
if ! bosh add-blob "$TEMP_DIR/$KRB5_TARBALL" "krb5/$KRB5_TARBALL"; then
  print_error "Failed to add blob"
  exit 1
fi

print_success "Blob added to blobstore"

# Upload blobs
print_info "Uploading blob to GCS..."
if ! bosh upload-blobs; then
  print_error "Failed to upload blobs to GCS"
  exit 1
fi

print_success "Blob uploaded to GCS bucket: tpi-telemetry-release-blobs"

# Remove old blob if it exists
if [ -n "$OLD_BLOB" ]; then
  print_info "Removing old blob: $OLD_BLOB"

  echo
  print_warning "About to remove old blob: $OLD_BLOB"
  read -p "Continue? (y/n) " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    if bosh remove-blob "$OLD_BLOB"; then
      print_success "Old blob removed"
    else
      print_warning "Failed to remove old blob (may need manual cleanup)"
    fi
  else
    print_info "Skipping old blob removal"
  fi
fi

# Show git status
echo
print_info "Git status:"
git status --short config/blobs.yml

# Summary
echo
echo "════════════════════════════════════════════════════════════"
print_success "krb5 blob update completed!"
echo "════════════════════════════════════════════════════════════"
echo
print_info "Summary:"
echo "  • Version: $VERSION"
echo "  • File: krb5/$KRB5_TARBALL"
echo "  • SHA256: $CHECKSUM"
echo "  • Size: $FILE_SIZE bytes"
echo

# Offer to create test release
read -p "Create a test BOSH release? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  print_info "Creating test release..."

  TEST_TARBALL="/tmp/telemetry-test-krb5-$VERSION.tgz"

  if bosh create-release --force --tarball="$TEST_TARBALL"; then
    print_success "Test release created: $TEST_TARBALL"
  else
    print_error "Failed to create test release"
    print_info "You may need to run: bosh sync-blobs"
    exit 1
  fi
fi

echo
print_warning "IMPORTANT: krb5 update requires thorough testing!"
echo
print_info "Next steps:"
echo "  1. Review changes: git diff config/blobs.yml"
echo "  2. Create test release: bosh create-release --force"
echo "  3. Deploy to staging environment"
echo "  4. Test SPNEGO authentication:"
echo "     - Test SPNEGO proxy with kinit/klist"
echo "     - Verify telemetry data flows through proxy"
echo "     - Check logs for Kerberos-related errors"
echo "  5. Commit if tests pass:"
echo "     git add config/blobs.yml"
echo "     git commit -m \"chore: Update krb5 to $VERSION\""
