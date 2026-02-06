#!/usr/bin/env bash
#
# This script updates:
#   1. src/fluentd/ -- Gemfile.lock + vendor/cache (the cached gems used by BOSH at compile time)
#   2. src/fluentd/telemetry-filter-plugin/ -- Gemfile.lock
#   3. src/acceptance_tests/ -- Gemfile.lock
#   4. src/acceptance_tests_audit_mode/ -- Gemfile.lock
#   5. src/acceptance_tests/telemetry_receiver/ -- go.mod + go.sum
#   6. src/acceptance_tests_audit_mode/telemetry_receiver/ -- go.mod + go.sum
#   7. ./Gemfile.lock (root)
#
# After updating, it runs the root-level rspec tests. If tests fail, no commit is made.
#
# Constraints:
#   - BUNDLED WITH in all Gemfile.lock files must remain 2.6.8
#   - PLATFORMS in all Gemfile.lock files must remain unchanged
#   - Ruby 3.4.x is required (reads from .ruby-version)
#
# Usage:
#   ./scripts/update-src-dependencies.sh
#
# Prerequisites:
#   - Ruby 3.4.x installed (matching .ruby-version)
#   - Bundler 2.6.8 (ships with Ruby 3.4.8)
#   - Go 1.25.x installed (via goenv or system)
#   - rspec gem installed (for running tests)

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

ERRORS=0
UPDATED=0

# ============================================================================
# Prerequisites
# ============================================================================
print_step "Checking prerequisites"

# Ruby
if ! command -v ruby &> /dev/null; then
    print_error "Ruby is not installed. Install Ruby 3.4.x first."
    exit 1
fi
RUBY_VERSION_INSTALLED=$(ruby -e 'puts RUBY_VERSION')
RUBY_VERSION_REQUIRED=$(cat "${REPO_ROOT}/.ruby-version" 2>/dev/null | tr -d '[:space:]' || echo "3.4")
print_info "Ruby installed: ${RUBY_VERSION_INSTALLED} (required: ${RUBY_VERSION_REQUIRED})"

# Bundler
if ! command -v bundle &> /dev/null; then
    print_error "Bundler is not installed."
    exit 1
fi
BUNDLER_VERSION=$(bundle --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
print_info "Bundler version: ${BUNDLER_VERSION}"
if [[ "${BUNDLER_VERSION}" != "2.6.8" ]]; then
    print_warning "Bundler is ${BUNDLER_VERSION}, but BUNDLED WITH must be 2.6.8."
    print_warning "Installing bundler 2.6.8..."
    gem install bundler -v 2.6.8
    BUNDLER_VERSION="2.6.8"
fi

# Go
if ! command -v go &> /dev/null; then
    # Try goenv
    if command -v goenv &> /dev/null; then
        eval "$(goenv init -)"
        GO_VERSION_FILE=$(cat "${REPO_ROOT}/.go-version" 2>/dev/null | tr -d '[:space:]' || echo "1.25")
        goenv shell "${GO_VERSION_FILE}" 2>/dev/null || true
    fi
fi
if command -v go &> /dev/null; then
    print_info "Go version: $(go version)"
else
    print_warning "Go is not installed. Go module updates will be skipped."
fi

print_success "Prerequisites checked."

# ============================================================================
# Helper: Update a Gemfile.lock while preserving BUNDLED WITH and PLATFORMS
# ============================================================================
update_gemfile_lock() {
    local dir="$1"
    local label="$2"

    print_info "Updating ${label}..."
    pushd "${dir}" > /dev/null

    # Save the current PLATFORMS and BUNDLED WITH sections
    local platforms_section=""
    local bundled_with_section=""

    if [[ -f Gemfile.lock ]]; then
        # Extract PLATFORMS section (everything between PLATFORMS and the next blank line + section)
        platforms_section=$(awk '/^PLATFORMS/{found=1} found{print} /^$/{if(found && seen_content) found=0; else seen_content=1}' Gemfile.lock | head -20)
        # Extract BUNDLED WITH section
        bundled_with_section=$(awk '/^BUNDLED WITH/{found=1} found{print}' Gemfile.lock)
    fi

    # Run bundle update
    if ! bundle update 2>&1; then
        print_error "  bundle update failed in ${label}"
        popd > /dev/null
        return 1
    fi

    # Verify BUNDLED WITH is still 2.6.8
    if [[ -f Gemfile.lock ]]; then
        local current_bundled_with
        current_bundled_with=$(awk '/^BUNDLED WITH/{getline; print; exit}' Gemfile.lock | tr -d '[:space:]')
        if [[ "${current_bundled_with}" != "2.6.8" ]]; then
            print_warning "  BUNDLED WITH changed to ${current_bundled_with}, restoring to 2.6.8..."
            # Use a temp file approach to fix BUNDLED WITH
            if [[ "$(uname -s)" == "Darwin" ]]; then
                sed -i '' '/^BUNDLED WITH$/,/^[[:space:]]*[0-9]/{s/^[[:space:]]*[0-9].*/   2.6.8/;}' Gemfile.lock
            else
                sed -i '/^BUNDLED WITH$/,/^[[:space:]]*[0-9]/{s/^[[:space:]]*[0-9].*/   2.6.8/;}' Gemfile.lock
            fi
        fi
        print_success "  ${label} updated (BUNDLED WITH: 2.6.8)"
    fi

    popd > /dev/null
    return 0
}

# ============================================================================
# Helper: Update a Go module
# ============================================================================
update_go_module() {
    local dir="$1"
    local label="$2"

    if ! command -v go &> /dev/null; then
        print_warning "Skipping ${label} (Go not installed)"
        return 0
    fi

    print_info "Updating ${label}..."
    pushd "${dir}" > /dev/null

    if ! go get -u ./... 2>&1; then
        print_warning "  go get -u failed in ${label} (non-fatal)"
    fi

    if ! go mod tidy 2>&1; then
        print_error "  go mod tidy failed in ${label}"
        popd > /dev/null
        return 1
    fi

    print_success "  ${label} updated"
    popd > /dev/null
    return 0
}

# ============================================================================
# Step 1: Root Gemfile
# ============================================================================
print_step "Step 1/7: Root Gemfile"
if update_gemfile_lock "${REPO_ROOT}" "root Gemfile"; then
    UPDATED=$((UPDATED + 1))
else
    ERRORS=$((ERRORS + 1))
fi

# ============================================================================
# Step 2: src/fluentd (with vendor/cache rebuild)
# ============================================================================
print_step "Step 2/7: src/fluentd (Gemfile + vendor/cache)"

print_info "Updating src/fluentd..."
pushd "${REPO_ROOT}/src/fluentd" > /dev/null

# Step 2a: Update Gemfile.lock
if ! bundle update 2>&1; then
    print_error "  bundle update failed in src/fluentd"
    ERRORS=$((ERRORS + 1))
else
    # Step 2b: Rebuild the vendor/cache
    # This is the critical step -- BOSH uses these cached gems at compile time
    # Following the instructions from packages/fluentd/spec
    print_info "  Rebuilding vendor/cache (BOSH compile-time gems)..."

    BUNDLE_WITHOUT=development:test bundle package --all --all-platforms --no-install --path ./vendor/cache 2>&1
    rm -rf ./vendor/cache/ruby 2>/dev/null || true
    rm -rf ./vendor/cache/vendor 2>/dev/null || true
    bundle config --delete NO_INSTALL 2>/dev/null || true
    rm -rf .bundle/ 2>/dev/null || true

    # Verify BUNDLED WITH
    current_bundled_with=$(awk '/^BUNDLED WITH/{getline; print; exit}' Gemfile.lock | tr -d '[:space:]')
    if [[ "${current_bundled_with}" != "2.6.8" ]]; then
        print_warning "  BUNDLED WITH changed to ${current_bundled_with}, restoring to 2.6.8..."
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i '' '/^BUNDLED WITH$/,/^[[:space:]]*[0-9]/{s/^[[:space:]]*[0-9].*/   2.6.8/;}' Gemfile.lock
        else
            sed -i '/^BUNDLED WITH$/,/^[[:space:]]*[0-9]/{s/^[[:space:]]*[0-9].*/   2.6.8/;}' Gemfile.lock
        fi
    fi

    GEM_COUNT=$(ls vendor/cache/*.gem 2>/dev/null | wc -l | tr -d '[:space:]')
    print_success "  src/fluentd updated (${GEM_COUNT} gems cached, BUNDLED WITH: 2.6.8)"
    UPDATED=$((UPDATED + 1))
fi

popd > /dev/null

# ============================================================================
# Step 3: src/fluentd/telemetry-filter-plugin
# ============================================================================
print_step "Step 3/7: src/fluentd/telemetry-filter-plugin"
if update_gemfile_lock "${REPO_ROOT}/src/fluentd/telemetry-filter-plugin" "src/fluentd/telemetry-filter-plugin"; then
    UPDATED=$((UPDATED + 1))
else
    ERRORS=$((ERRORS + 1))
fi

# ============================================================================
# Step 4: src/acceptance_tests
# ============================================================================
print_step "Step 4/7: src/acceptance_tests"
if update_gemfile_lock "${REPO_ROOT}/src/acceptance_tests" "src/acceptance_tests"; then
    UPDATED=$((UPDATED + 1))
else
    ERRORS=$((ERRORS + 1))
fi

# ============================================================================
# Step 5: src/acceptance_tests_audit_mode
# ============================================================================
print_step "Step 5/7: src/acceptance_tests_audit_mode"
if update_gemfile_lock "${REPO_ROOT}/src/acceptance_tests_audit_mode" "src/acceptance_tests_audit_mode"; then
    UPDATED=$((UPDATED + 1))
else
    ERRORS=$((ERRORS + 1))
fi

# ============================================================================
# Step 6: Go modules (both acceptance test receivers)
# ============================================================================
print_step "Step 6/7: Go modules"
if update_go_module "${REPO_ROOT}/src/acceptance_tests/telemetry_receiver" "src/acceptance_tests/telemetry_receiver"; then
    UPDATED=$((UPDATED + 1))
else
    ERRORS=$((ERRORS + 1))
fi

if update_go_module "${REPO_ROOT}/src/acceptance_tests_audit_mode/telemetry_receiver" "src/acceptance_tests_audit_mode/telemetry_receiver"; then
    UPDATED=$((UPDATED + 1))
else
    ERRORS=$((ERRORS + 1))
fi

# ============================================================================
# Step 7: Run tests
# ============================================================================
print_step "Step 7/7: Running rspec tests"

cd "${REPO_ROOT}"
if bundle exec rspec 2>&1; then
    print_success "All rspec tests passed."
else
    print_error "rspec tests FAILED."
    print_error "Dependencies were updated but NOT committed because tests failed."
    print_error "Fix the test failures, then commit manually."
    ERRORS=$((ERRORS + 1))
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================="
if [[ ${ERRORS} -eq 0 ]]; then
    echo -e "${GREEN}DEPENDENCY UPDATE COMPLETE${NC}"
    echo "=========================================="
    echo ""
    echo "  ${UPDATED} locations updated, all tests passed."
    echo ""
    echo "  Review changes:"
    echo "    git diff --stat"
    echo ""
    echo "  If everything looks good, commit:"
    echo "    git add -A"
    echo "    git commit -m \"chore: update Ruby and Go dependencies\""
    echo ""
else
    echo -e "${RED}DEPENDENCY UPDATE COMPLETED WITH ${ERRORS} ERROR(S)${NC}"
    echo "=========================================="
    echo ""
    echo "  ${UPDATED} locations updated, but ${ERRORS} error(s) occurred."
    echo "  Review the output above for details."
    echo ""
    exit 1
fi
