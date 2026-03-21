#!/usr/bin/env bash
#
# Update Go module dependencies for acceptance test receivers.
#
# What it does:
#   1. Runs `go get -u ./...` + `go mod tidy` in each Go module directory
#
# Go module locations:
#   src/acceptance_tests/telemetry_receiver/
#   src/acceptance_tests_audit_mode/telemetry_receiver/
#
# Exit codes:
#   0 -- success (whether or not changes were made)
#   1 -- error
#
# Usage:
#   ./scripts/update-go-modules.sh
#
# Prerequisites:
#   - Go installed (via goenv or system)

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

print_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
print_success() { echo -e "${GREEN}[OK]${NC}   $*"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error()   { echo -e "${RED}[FAIL]${NC} $*"; }
print_step()    { echo -e "\n${BLUE}=== $* ===${NC}"; }

# ============================================================================
# Prerequisites
# ============================================================================
print_step "Checking prerequisites"

if ! command -v go &> /dev/null; then
    if command -v goenv &> /dev/null; then
        eval "$(goenv init -)"
        export GOTOOLCHAIN=auto
    fi
fi

if ! command -v go &> /dev/null; then
    print_error "Go is not installed and goenv is not available."
    exit 1
fi

print_info "Go: $(go version)"
print_success "Prerequisites OK."

# ============================================================================
# Helper: Update a Go module
# ============================================================================
update_go_module() {
    local dir="$1"
    local label="$2"

    print_info "Updating ${label}..."
    pushd "${dir}" > /dev/null

    if ! go get -u ./...; then
        print_warning "  go get -u had warnings in ${label} (continuing)"
    fi

    if ! go mod tidy; then
        print_error "go mod tidy failed in ${label}"
        popd > /dev/null
        return 1
    fi

    print_success "${label} updated."
    popd > /dev/null
    return 0
}

# ============================================================================
# Update Go modules
# ============================================================================
print_step "Step 1/2: src/acceptance_tests/telemetry_receiver"
update_go_module "${REPO_ROOT}/src/acceptance_tests/telemetry_receiver" "src/acceptance_tests/telemetry_receiver"

print_step "Step 2/2: src/acceptance_tests_audit_mode/telemetry_receiver"
update_go_module "${REPO_ROOT}/src/acceptance_tests_audit_mode/telemetry_receiver" "src/acceptance_tests_audit_mode/telemetry_receiver"

# ============================================================================
# Summary
# ============================================================================
cd "${REPO_ROOT}"
if [[ -z "$(git status --porcelain -- 'src/acceptance_tests/telemetry_receiver/' 'src/acceptance_tests_audit_mode/telemetry_receiver/' 2>/dev/null)" ]]; then
    echo ""
    echo "NO_UPDATE=true"
    print_info "All Go modules are already up to date. Nothing to commit."
else
    echo ""
    echo -e "${GREEN}GO MODULE UPDATE COMPLETE${NC}"
    echo ""
    echo "  Both Go modules updated."
    echo ""
    echo "  Review changes:"
    echo "    git diff --stat -- src/acceptance_tests/telemetry_receiver/ src/acceptance_tests_audit_mode/telemetry_receiver/"
fi
