#!/usr/bin/env bash
#
# This script:
#   1. Reads the version from ci/VERSION
#   2. Verifies prerequisites (bosh CLI, gh CLI, GCS credentials, clean git state)
#   3. Runs `bosh create-release --final --version X.Y.Z --tarball ...`
#      - This updates .final_builds/ index files with new package/job fingerprints
#      - Creates releases/telemetry/telemetry-X.Y.Z.yml
#      - Updates releases/telemetry/index.yml
#      - Uploads new artifacts to the GCS blobstore
#   4. Commits all changes
#   5. Pushes to origin
#   6. Creates a GitHub Release tagged X.Y.Z with the tarball attached
#
# Usage:
#   ./scripts/create-final-release.sh
#
# Prerequisites:
#   - bosh CLI installed
#   - gh CLI installed and authenticated
#   - config/private.yml exists with valid GCS credentials
#     (create via: ./scripts/update-telemetry-cli.sh, or manually from service_account.json)
#   - Clean git working directory (all changes committed)
#   - ci/VERSION set to the target release version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# ============================================================================
# Colors and helpers
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[FAIL]${NC} $1"; }
print_step()    { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# ============================================================================
# Read version
# ============================================================================
VERSION=$(cat ci/VERSION | tr -d '[:space:]')
if [[ -z "${VERSION}" ]]; then
    print_error "ci/VERSION is empty."
    exit 1
fi

TARBALL_PATH="/tmp/telemetry-${VERSION}.tgz"
RELEASE_NAME="Telemetry Release ${VERSION}"

echo ""
echo "=========================================="
echo "  BOSH Final Release: ${VERSION}"
echo "=========================================="
echo ""

# ============================================================================
# Prerequisites
# ============================================================================
print_step "Checking prerequisites"

# bosh CLI
if ! command -v bosh &> /dev/null; then
    print_error "bosh CLI is not installed."
    exit 1
fi
print_info "bosh CLI: $(bosh --version 2>&1 | head -1)"

# gh CLI
if ! command -v gh &> /dev/null; then
    print_error "gh CLI is not installed."
    exit 1
fi
print_info "gh CLI: $(gh --version | head -1)"

# GCS credentials
if [[ ! -f config/private.yml ]]; then
    # Try to create from service_account.json
    if [[ -f service_account.json ]]; then
        print_warning "config/private.yml not found. Creating from service_account.json..."
        SERVICE_ACCOUNT_CONTENT=$(cat service_account.json)
        cat > config/private.yml <<EOM
---
blobstore:
  options:
    credentials_source: static
    json_key: |
$(echo "${SERVICE_ACCOUNT_CONTENT}" | sed 's/^/      /')
EOM
        print_success "Created config/private.yml from service_account.json"
    else
        print_error "config/private.yml not found and no service_account.json available."
        print_info "Run ./scripts/update-telemetry-cli.sh first, or create config/private.yml manually."
        exit 1
    fi
fi
print_success "GCS credentials: config/private.yml exists"

# Clean git state
if [[ -n "$(git status --porcelain)" ]]; then
    print_error "Git working directory is not clean. Commit or stash changes first."
    echo ""
    git status --short
    exit 1
fi
print_success "Git working directory is clean"

# Check that this version doesn't already have a release manifest
if [[ -f "releases/telemetry/telemetry-${VERSION}.yml" ]]; then
    print_error "releases/telemetry/telemetry-${VERSION}.yml already exists!"
    print_error "Version ${VERSION} has already been finalized. Bump ci/VERSION first."
    exit 1
fi
print_success "Version ${VERSION} is new (no existing release manifest)"

# Check for existing GitHub Release
if gh release view "${VERSION}" &> /dev/null; then
    print_warning "GitHub Release ${VERSION} already exists. It will be replaced."
    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Aborted."
        exit 0
    fi
fi

print_success "All prerequisites met."

# ============================================================================
# Create final release
# ============================================================================
print_step "Creating BOSH final release ${VERSION}"

print_info "Running: bosh create-release --final --version ${VERSION} --tarball ${TARBALL_PATH}"
echo ""

bosh create-release --final --version "${VERSION}" --tarball "${TARBALL_PATH}"

echo ""
print_success "Final release created."
print_info "Tarball: ${TARBALL_PATH} ($(du -h "${TARBALL_PATH}" | awk '{print $1}'))"

# ============================================================================
# Verify outputs
# ============================================================================
print_step "Verifying release artifacts"

if [[ ! -f "releases/telemetry/telemetry-${VERSION}.yml" ]]; then
    print_error "Expected releases/telemetry/telemetry-${VERSION}.yml was not created!"
    exit 1
fi
print_success "releases/telemetry/telemetry-${VERSION}.yml created"

if [[ ! -f "${TARBALL_PATH}" ]]; then
    print_error "Expected tarball ${TARBALL_PATH} was not created!"
    exit 1
fi
print_success "Tarball exists at ${TARBALL_PATH}"

# Show what changed
echo ""
print_info "Files modified by bosh create-release --final:"
git status --short
echo ""

# ============================================================================
# Commit
# ============================================================================
print_step "Committing changes"

git add .
git config --local user.email "action@github.com"
git config --local user.name "GitHub Action"
git commit -m "Create final release ${VERSION}"

print_success "Committed: Create final release ${VERSION}"

# ============================================================================
# Push
# ============================================================================
print_step "Pushing to origin"

read -p "Push to origin? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warning "Skipping push. You can push manually with: git push"
else
    git push
    print_success "Pushed to origin."
fi

# ============================================================================
# Determine release notes
# ============================================================================
# Extract component versions from blobs.yml for the release notes
CLI_VERSION=$(grep "^telemetry-cli/" config/blobs.yml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
FLUENT_BIT_VERSION=$(grep "^fluent-bit/" config/blobs.yml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
KRB5_VERSION=$(grep "^krb5/" config/blobs.yml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

RELEASE_NOTES=$(cat <<EOF
## Telemetry BOSH Release ${VERSION}

### What's New
- Updated telemetry-cli to ${CLI_VERSION} (CVE patches in Go runtime and dependencies)
- Updated krb5 to ${KRB5_VERSION} (security patches)
- Updated Ruby gems across fluentd and test dependencies (CVE mitigation)
- Updated Go modules in acceptance tests

### Dependencies
| Component | Version |
|-----------|---------|
| telemetry-cli | ${CLI_VERSION} |
| fluent-bit | ${FLUENT_BIT_VERSION} |
| krb5 | ${KRB5_VERSION} |
| ruby | 3.4 |

### Artifacts
- **telemetry-${VERSION}.tgz** - BOSH release tarball
EOF
)

# ============================================================================
# Create GitHub Release
# ============================================================================
print_step "Creating GitHub Release"

print_info "Release notes:"
echo "${RELEASE_NOTES}"
echo ""

read -p "Create GitHub Release '${RELEASE_NAME}' with these notes? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warning "Skipping GitHub Release creation."
    print_info "You can create it manually with:"
    echo "  gh release create ${VERSION} ${TARBALL_PATH} --title '${RELEASE_NAME}' --notes '...'"
else
    gh release create "${VERSION}" \
        "${TARBALL_PATH}" \
        --title "${RELEASE_NAME}" \
        --notes "${RELEASE_NOTES}"

    print_success "GitHub Release '${RELEASE_NAME}' created."
    print_info "View at: $(gh release view "${VERSION}" --json url --jq '.url')"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================="
echo -e "${GREEN}FINAL RELEASE ${VERSION} COMPLETE${NC}"
echo "=========================================="
echo ""
echo "  Release manifest: releases/telemetry/telemetry-${VERSION}.yml"
echo "  Tarball:          ${TARBALL_PATH}"
echo "  Components:"
echo "    telemetry-cli:  ${CLI_VERSION}"
echo "    fluent-bit:     ${FLUENT_BIT_VERSION}"
echo "    krb5:           ${KRB5_VERSION}"
echo "    ruby:           3.4"
echo ""
echo "  Next steps:"
echo "    - GPP will detect .final_builds/ changes and update Kilnfile.lock in tpi-p-telemetry"
echo "    - Complete compliance steps (Black Duck, TVS, RMT) as needed"
echo ""
