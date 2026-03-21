#!/usr/bin/env bash
#
# Update Ruby gem dependencies across all 5 Gemfile locations in telemetry-release.
#
# What it does:
#   1. Discovers the Ruby/Bundler versions from the upstream BOSH ruby-3.4 package
#   2. Runs `bundle update` + `bundle update --ruby` in each of the 5 Gemfile directories
#   3. Rebuilds src/fluentd/vendor/cache (BOSH compile-time gems)
#   4. Runs a compile-time simulation (bundle install --local) for src/fluentd
#   5. Validates PLATFORMS, BUNDLED WITH (production only), and RUBY VERSION invariants
#   6. Runs root-level and filter-plugin rspec tests
#   7. Reports BOSH Ruby version drift if the vendored package is behind upstream
#
# Gemfile locations:
#   .                                    (root -- BOSH job template tests)
#   src/fluentd/                         (fluentd + vendor/cache for BOSH)
#   src/fluentd/telemetry-filter-plugin/ (fluentd filter plugin + tests)
#   src/acceptance_tests/                (acceptance test helpers)
#   src/acceptance_tests_audit_mode/     (audit-mode acceptance test helpers)
#
# Invariants enforced:
#   - PLATFORMS section must not change (hard fail)
#   - BUNDLED WITH must match BOSH bundler for src/fluentd (hard fail; test-only lockfiles are unchecked)
#   - RUBY VERSION must remain in the 3.4.x family (hard fail on major.minor change)
#
# Exit codes:
#   0 -- success (whether or not changes were made)
#   1 -- error (update failure, validation failure, test failure)
#
# Usage:
#   ./scripts/update-ruby-gems.sh
#
# Prerequisites:
#   - Ruby 3.4.x installed
#   - Network access to github.com (for BOSH version discovery)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

CLEANUP_TMPDIR=""
cleanup() { [[ -n "${CLEANUP_TMPDIR}" ]] && rm -rf "${CLEANUP_TMPDIR}" 2>/dev/null || true; }
trap cleanup EXIT

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

RUBY_VERSION_BEFORE=""

# ============================================================================
# BOSH version discovery
# ============================================================================
BOSH_PACKAGING_URL="https://raw.githubusercontent.com/cloudfoundry/bosh-package-ruby-release/main/packages/ruby-3.4/packaging"
BOSH_VERSION_URL="https://raw.githubusercontent.com/cloudfoundry/bosh-package-ruby-release/main/packages/ruby-3.4/version"

print_step "Discovering BOSH ruby-3.4 versions"

bosh_packaging=""
curl_stderr=$(mktemp)
if ! bosh_packaging=$(curl -fsSL "${BOSH_PACKAGING_URL}" 2>"${curl_stderr}"); then
    print_error "Failed to fetch BOSH ruby-3.4 packaging script from GitHub."
    print_error "Network error or GitHub is down. Cannot determine correct bundler version."
    print_error "URL: ${BOSH_PACKAGING_URL}"
    print_error "curl error: $(cat "${curl_stderr}")"
    rm -f "${curl_stderr}"
    exit 1
fi
rm -f "${curl_stderr}"

BOSH_RUBY_VERSION=$(echo "${bosh_packaging}" | grep -E '^RUBY_VERSION=' | head -1 | cut -d= -f2)
BOSH_RUBYGEMS_VERSION=$(echo "${bosh_packaging}" | grep -E '^RUBYGEMS_VERSION=' | head -1 | cut -d= -f2)

if [[ -z "${BOSH_RUBY_VERSION}" || -z "${BOSH_RUBYGEMS_VERSION}" ]]; then
    print_error "Could not parse RUBY_VERSION or RUBYGEMS_VERSION from BOSH packaging script."
    exit 1
fi

# RubyGems 3.6.N ships Bundler 2.6.N (co-released from the same monorepo).
# This derivation is a convention, not a contract -- validate below.
BOSH_BUNDLER_VERSION="${BOSH_RUBYGEMS_VERSION/3./2.}"

if ! [[ "${BOSH_BUNDLER_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print_error "Derived Bundler version '${BOSH_BUNDLER_VERSION}' from RubyGems ${BOSH_RUBYGEMS_VERSION} is not a valid semver."
    print_error "The RubyGems-to-Bundler version derivation may have broken. Manual review required."
    exit 1
fi

# Cross-check with the version file
bosh_version_file=""
curl_stderr_v=$(mktemp)
if bosh_version_file=$(curl -fsSL "${BOSH_VERSION_URL}" 2>"${curl_stderr_v}"); then
    bosh_version_file=$(echo "${bosh_version_file}" | tr -d '[:space:]')
    if [[ "${bosh_version_file}" != "${BOSH_RUBY_VERSION}" ]]; then
        print_warning "BOSH version file says ${bosh_version_file} but packaging script says ${BOSH_RUBY_VERSION}"
    fi
else
    print_warning "Could not fetch BOSH version file (non-fatal): $(cat "${curl_stderr_v}")"
fi
rm -f "${curl_stderr_v}"

print_info "BOSH ruby-3.4 upstream: Ruby ${BOSH_RUBY_VERSION}, RubyGems ${BOSH_RUBYGEMS_VERSION}, Bundler ${BOSH_BUNDLER_VERSION}"

# Safety rails: abort on major version jumps
bosh_ruby_major_minor="${BOSH_RUBY_VERSION%.*}"
if [[ "${bosh_ruby_major_minor}" != "3.4" ]]; then
    print_error "BOSH Ruby major.minor changed to ${bosh_ruby_major_minor} (expected 3.4). Manual review required."
    exit 1
fi

bosh_bundler_major="${BOSH_BUNDLER_VERSION%%.*}"
if [[ "${bosh_bundler_major}" != "2" ]]; then
    print_error "BOSH Bundler major version changed to ${bosh_bundler_major} (expected 2). Manual review required."
    exit 1
fi

print_success "BOSH version discovery OK."

# ============================================================================
# BOSH version drift advisory
# ============================================================================
VERSION_FILE="${REPO_ROOT}/packages/ruby-3.4/VERSION"
if [[ -f "${VERSION_FILE}" ]]; then
    vendored_ruby_version=$(cat "${VERSION_FILE}" | tr -d '[:space:]')
    if [[ "${vendored_ruby_version}" != "${BOSH_RUBY_VERSION}" ]]; then
        print_warning "Our vendored BOSH package is Ruby ${vendored_ruby_version} (per packages/ruby-3.4/VERSION)."
        print_warning "Upstream BOSH ruby-3.4 is Ruby ${BOSH_RUBY_VERSION}."
        print_warning "Consider running: bosh vendor-package ruby-3.4 <path-to-bosh-package-ruby-release>"
    else
        print_info "Vendored BOSH Ruby ${vendored_ruby_version} matches upstream. No drift."
    fi
else
    print_warning "packages/ruby-3.4/VERSION not found. Cannot check for BOSH Ruby version drift."
fi

# ============================================================================
# Prerequisites
# ============================================================================
print_step "Checking prerequisites"

if ! command -v ruby &> /dev/null; then
    print_error "Ruby is not installed. Install Ruby 3.4.x first."
    exit 1
fi

RUBY_VERSION_INSTALLED=$(ruby -e 'puts RUBY_VERSION')
RUBY_MAJOR_MINOR="${RUBY_VERSION_INSTALLED%.*}"
if [[ "${RUBY_MAJOR_MINOR}" != "3.4" ]]; then
    print_error "Ruby ${RUBY_VERSION_INSTALLED} is installed, but 3.4.x is required."
    exit 1
fi
print_info "Ruby: ${RUBY_VERSION_INSTALLED}"

if ! gem list bundler --exact --silent -v "${BOSH_BUNDLER_VERSION}" 2>/dev/null; then
    print_info "Bundler ${BOSH_BUNDLER_VERSION} not found, installing..."
    gem install bundler -v "${BOSH_BUNDLER_VERSION}"
fi

# Verify the version is actually available (bundle --version may report a
# different version due to BUNDLED WITH in the current Gemfile.lock, but
# bundle _X_ --version confirms the gem is installed and activatable)
BUNDLER_VERSION_CHECK=$(bundle "_${BOSH_BUNDLER_VERSION}_" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
if [[ "${BUNDLER_VERSION_CHECK}" != "${BOSH_BUNDLER_VERSION}" ]]; then
    print_error "Bundler ${BOSH_BUNDLER_VERSION} was installed but cannot be activated."
    print_error "'bundle _${BOSH_BUNDLER_VERSION}_ --version' reports: ${BUNDLER_VERSION_CHECK:-nothing}"
    exit 1
fi
print_info "Bundler: ${BOSH_BUNDLER_VERSION} (matches BOSH ruby-3.4)"

# Use versioned bundle invocation to ensure we use the correct bundler,
# even when the current Gemfile.lock has a different BUNDLED WITH.
BUNDLE_CMD=(bundle "_${BOSH_BUNDLER_VERSION}_")
print_info "Using: ${BUNDLE_CMD[*]}"

print_success "Prerequisites OK."

# ============================================================================
# Lockfile section extraction helpers
# ============================================================================
extract_platforms() {
    awk '/^PLATFORMS$/{found=1; next} found && /^$/{exit} found{print}' "$1"
}

extract_bundled_with() {
    awk '/^BUNDLED WITH$/{getline; print; exit}' "$1" | tr -d '[:space:]'
}

extract_ruby_version() {
    awk '/^RUBY VERSION$/{getline; print; exit}' "$1" | tr -d '[:space:]'
}

# ============================================================================
# Core helper: Update a single Gemfile.lock with full validation
#
# Args:
#   $1 -- directory containing Gemfile/Gemfile.lock
#   $2 -- human-readable label
#   $3 -- "fluentd" if this is the src/fluentd directory (triggers vendor/cache rebuild)
# ============================================================================
update_gemfile_lock() {
    local dir="$1"
    local label="$2"
    local is_fluentd="${3:-}"

    print_info "Updating ${label}..."
    pushd "${dir}" > /dev/null

    # --- Snapshot invariants before update ---
    local pre_platforms=""
    local pre_ruby_version=""

    if [[ -f Gemfile.lock ]]; then
        pre_platforms=$(extract_platforms Gemfile.lock)
        pre_ruby_version=$(extract_ruby_version Gemfile.lock)
    fi

    # --- Run bundle update ---
    if ! "${BUNDLE_CMD[@]}" update; then
        print_error "bundle update failed in ${label}"
        popd > /dev/null
        return 1
    fi

    # Update the locked RUBY VERSION to match the active interpreter.
    # `bundle update` alone does NOT touch this field.
    if ! "${BUNDLE_CMD[@]}" update --ruby; then
        print_error "bundle update --ruby failed in ${label}"
        popd > /dev/null
        return 1
    fi

    # --- For src/fluentd: rebuild vendor/cache ---
    if [[ "${is_fluentd}" == "fluentd" ]]; then
        print_info "  Rebuilding vendor/cache (BOSH compile-time gems)..."

        "${BUNDLE_CMD[@]}" config set --local cache_all true
        "${BUNDLE_CMD[@]}" config set --local cache_path ./vendor/cache
        "${BUNDLE_CMD[@]}" config set --local no_install true
        if ! BUNDLE_WITHOUT=development:test "${BUNDLE_CMD[@]}" package --all-platforms; then
            print_error "bundle package failed in ${label}"
            "${BUNDLE_CMD[@]}" config unset --local cache_all 2>/dev/null || true
            "${BUNDLE_CMD[@]}" config unset --local cache_path 2>/dev/null || true
            "${BUNDLE_CMD[@]}" config unset --local no_install 2>/dev/null || true
            rm -rf .bundle/ 2>/dev/null || true
            popd > /dev/null
            return 1
        fi

        "${BUNDLE_CMD[@]}" config unset --local cache_all
        "${BUNDLE_CMD[@]}" config unset --local cache_path
        "${BUNDLE_CMD[@]}" config unset --local no_install
        rm -rf ./vendor/cache/ruby 2>/dev/null || true
        rm -rf ./vendor/cache/vendor 2>/dev/null || true
        rm -rf .bundle/ 2>/dev/null || true

        local gem_count
        gem_count=$(find vendor/cache -name '*.gem' 2>/dev/null | wc -l | tr -d '[:space:]')
        print_info "  ${gem_count} gems cached in vendor/cache"

        # Simulate BOSH compile: mirrors bosh_bundle_local() from compile-3.4.env
        print_info "  Running compile-time simulation (bundle install --local)..."
        local tmpdir
        tmpdir=$(mktemp -d)
        CLEANUP_TMPDIR="${tmpdir}"
        cp Gemfile Gemfile.lock "${tmpdir}/"
        cp -r vendor "${tmpdir}/"
        (
            cd "${tmpdir}"
            "${BUNDLE_CMD[@]}" config set --local no_prune 'true'
            "${BUNDLE_CMD[@]}" config set --local without 'development test'
            "${BUNDLE_CMD[@]}" config set --local path './gem_home'
            "${BUNDLE_CMD[@]}" config set --local bin './bin'
            "${BUNDLE_CMD[@]}" install --local
            "${BUNDLE_CMD[@]}" binstubs --all
        ) || { rm -rf "${tmpdir}"; CLEANUP_TMPDIR=""; print_error "Compile simulation failed in ${label}"; popd > /dev/null; return 1; }
        rm -rf "${tmpdir}"
        CLEANUP_TMPDIR=""
        print_success "  Compile simulation passed."
    fi

    # --- Validate PLATFORMS ---
    if [[ -f Gemfile.lock ]]; then
        local post_platforms
        post_platforms=$(extract_platforms Gemfile.lock)

        if [[ "${pre_platforms}" != "${post_platforms}" ]]; then
            print_error "PLATFORMS changed in ${label}!"
            print_error "  Before: ${pre_platforms}"
            print_error "  After:  ${post_platforms}"
            popd > /dev/null
            return 1
        fi
    fi

    # --- Validate BUNDLED WITH (production lockfile only) ---
    if [[ "${is_fluentd}" == "fluentd" && -f Gemfile.lock ]]; then
        local post_bundled_with
        post_bundled_with=$(extract_bundled_with Gemfile.lock)

        if [[ "${post_bundled_with}" != "${BOSH_BUNDLER_VERSION}" ]]; then
            print_error "BUNDLED WITH is ${post_bundled_with} but BOSH bundler is ${BOSH_BUNDLER_VERSION} in ${label}!"
            print_error "The lockfile was generated with a different bundler than what BOSH will use."
            popd > /dev/null
            return 1
        fi
    fi

    # --- Validate RUBY VERSION ---
    if [[ -f Gemfile.lock ]]; then
        local post_ruby_version
        post_ruby_version=$(extract_ruby_version Gemfile.lock)

        if [[ -n "${post_ruby_version}" && -n "${pre_ruby_version}" ]]; then
            local pre_major_minor post_major_minor
            pre_major_minor=$(echo "${pre_ruby_version}" | grep -oE '^ruby[0-9]+\.[0-9]+')
            post_major_minor=$(echo "${post_ruby_version}" | grep -oE '^ruby[0-9]+\.[0-9]+')

            if [[ "${pre_major_minor}" != "${post_major_minor}" ]]; then
                print_error "RUBY VERSION major.minor changed in ${label}!"
                print_error "  Before: ${pre_ruby_version}"
                print_error "  After:  ${post_ruby_version}"
                popd > /dev/null
                return 1
            fi

            if [[ "${pre_ruby_version}" != "${post_ruby_version}" ]]; then
                if [[ -z "${RUBY_VERSION_BEFORE}" ]]; then
                    RUBY_VERSION_BEFORE="${pre_ruby_version}"
                fi
            fi
        fi
    fi

    print_success "${label} updated."
    popd > /dev/null
    return 0
}

# ============================================================================
# Update all 5 Gemfile locations (abort on first failure)
# ============================================================================
print_step "Step 1/5: Root Gemfile"
update_gemfile_lock "${REPO_ROOT}" "root"

print_step "Step 2/5: src/fluentd (Gemfile + vendor/cache)"
update_gemfile_lock "${REPO_ROOT}/src/fluentd" "src/fluentd" "fluentd"

print_step "Step 3/5: src/fluentd/telemetry-filter-plugin"
update_gemfile_lock "${REPO_ROOT}/src/fluentd/telemetry-filter-plugin" "src/fluentd/telemetry-filter-plugin"

print_step "Step 4/5: src/acceptance_tests"
update_gemfile_lock "${REPO_ROOT}/src/acceptance_tests" "src/acceptance_tests"

print_step "Step 5/5: src/acceptance_tests_audit_mode"
update_gemfile_lock "${REPO_ROOT}/src/acceptance_tests_audit_mode" "src/acceptance_tests_audit_mode"

# ============================================================================
# Log RUBY VERSION change if it happened
# ============================================================================
if [[ -n "${RUBY_VERSION_BEFORE}" ]]; then
    post_ruby=$(extract_ruby_version "${REPO_ROOT}/Gemfile.lock")
    print_info "Ruby version in Gemfile.lock updated: ${RUBY_VERSION_BEFORE} -> ${post_ruby}"
fi

# ============================================================================
# Run tests
# ============================================================================
print_step "Running tests: root rspec"
cd "${REPO_ROOT}"
if ! "${BUNDLE_CMD[@]}" exec rspec; then
    print_error "Root rspec tests FAILED."
    print_error "Dependencies were updated but tests failed. No commit should be made."
    exit 1
fi
print_success "Root rspec tests passed."

print_step "Running tests: filter-plugin rspec"
cd "${REPO_ROOT}/src/fluentd/telemetry-filter-plugin"
if ! "${BUNDLE_CMD[@]}" exec rspec; then
    print_error "Filter-plugin rspec tests FAILED."
    print_error "Dependencies were updated but tests failed. No commit should be made."
    exit 1
fi
print_success "Filter-plugin rspec tests passed."

# ============================================================================
# Summary
# ============================================================================
cd "${REPO_ROOT}"
if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
    echo ""
    echo "NO_UPDATE=true"
    print_info "All gems are already up to date. Nothing to commit."
else
    echo ""
    echo -e "${GREEN}RUBY GEM UPDATE COMPLETE${NC}"
    echo ""
    echo "  All 5 Gemfile.lock files updated, all tests passed."
    echo ""
    echo "  Review changes:"
    echo "    git diff --stat"
    echo ""
    echo "  If everything looks good, commit:"
    echo "    git add -A"
    echo "    git commit -m \"chore: update Ruby gem dependencies\""
fi
