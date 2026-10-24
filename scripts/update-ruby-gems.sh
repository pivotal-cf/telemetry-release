#!/usr/bin/env bash
#
# Update Ruby gem dependencies across all 5 Gemfile locations in telemetry-release.
#
# What it does:
#   1. Discovers the Ruby/Bundler versions from the upstream BOSH ruby-4.0 package
#   2. Runs root-level and filter-plugin rspec tests before any update
#   3. Tries all updates together, then restores and tries outdated gems one at a time
#   4. Rebuilds src/fluentd/vendor/cache (BOSH compile-time gems)
#   5. Runs a compile-time simulation (bundle install --local) for src/fluentd
#   6. Validates PLATFORMS, BUNDLED WITH (production only), and RUBY VERSION invariants
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
#   - RUBY VERSION must remain in the 4.0.x family (hard fail on major.minor change)
#
# Exit codes:
#   0 -- success (whether or not changes were made)
#   1 -- baseline tests fail, or the final state fails validation or tests
#
# Usage:
#   ./scripts/update-ruby-gems.sh
#
# Prerequisites:
#   - Ruby 4.0.x installed
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
BOSH_PACKAGING_URL="https://raw.githubusercontent.com/cloudfoundry/bosh-package-ruby-release/main/packages/ruby-4.0/packaging"
BOSH_VERSION_URL="https://raw.githubusercontent.com/cloudfoundry/bosh-package-ruby-release/main/packages/ruby-4.0/version"

print_step "Discovering BOSH ruby-4.0 versions"

bosh_packaging=""
curl_stderr=$(mktemp)
if ! bosh_packaging=$(curl -fsSL "${BOSH_PACKAGING_URL}" 2>"${curl_stderr}"); then
    print_error "Failed to fetch BOSH ruby-4.0 packaging script from GitHub."
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

# Prefer an explicit BUNDLER_VERSION line in the packaging script.
# Fall back to version derivation:
#   RubyGems 3.Y.N → Bundler 2.Y.N  (3.x era: Bundler major is one less than RubyGems major)
#   RubyGems 4.Y.N → Bundler 4.Y.N  (4.x+ era: co-released at the same version)
# The || true guards against grep's exit code 1 (no match) killing the script under set -e.
BOSH_BUNDLER_VERSION=$(echo "${bosh_packaging}" | grep -E '^BUNDLER_VERSION=' | head -1 | cut -d= -f2 || true)
if [[ -z "${BOSH_BUNDLER_VERSION}" ]]; then
    rubygems_major="${BOSH_RUBYGEMS_VERSION%%.*}"
    if [[ "${rubygems_major}" == "3" ]]; then
        BOSH_BUNDLER_VERSION="${BOSH_RUBYGEMS_VERSION/3./2.}"
    else
        BOSH_BUNDLER_VERSION="${BOSH_RUBYGEMS_VERSION}"
    fi
fi

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

print_info "BOSH ruby-4.0 upstream: Ruby ${BOSH_RUBY_VERSION}, RubyGems ${BOSH_RUBYGEMS_VERSION}, Bundler ${BOSH_BUNDLER_VERSION}"

# Safety rails: abort on major version jumps
bosh_ruby_major_minor="${BOSH_RUBY_VERSION%.*}"
if [[ "${bosh_ruby_major_minor}" != "4.0" ]]; then
    print_error "BOSH Ruby major.minor changed to ${bosh_ruby_major_minor} (expected 4.0). Manual review required."
    exit 1
fi

print_success "BOSH version discovery OK."

# ============================================================================
# BOSH version drift advisory
# ============================================================================
VERSION_FILE="${REPO_ROOT}/packages/ruby-4.0/VERSION"
if [[ -f "${VERSION_FILE}" ]]; then
    local_ruby_version=$(cat "${VERSION_FILE}" | tr -d '[:space:]')
    if [[ "${local_ruby_version}" != "${BOSH_RUBY_VERSION}" ]]; then
        print_warning "packages/ruby-4.0 is at Ruby ${local_ruby_version}; upstream is ${BOSH_RUBY_VERSION}."
        print_warning "To upgrade:"
        print_warning "  1. Download ruby-${BOSH_RUBY_VERSION}.tar.gz from ruby-lang.org and add as a blob."
        print_warning "  2. Update RUBY_VERSION in packages/ruby-4.0/packaging."
        print_warning "  3. Update packages/ruby-4.0/VERSION to ${BOSH_RUBY_VERSION}."
        print_warning "  4. Check if RUBYGEMS_VERSION needs bumping (see upstream packaging script)."
        print_warning "  5. bosh upload-blobs after adding new blobs."
    else
        print_info "packages/ruby-4.0 Ruby ${local_ruby_version} matches upstream. No drift."
    fi
else
    print_warning "packages/ruby-4.0/VERSION not found. Cannot check for Ruby version drift."
fi

# ============================================================================
# Prerequisites
# ============================================================================
print_step "Checking prerequisites"

if ! command -v ruby &> /dev/null; then
    print_error "Ruby is not installed. Install Ruby 4.0.x first."
    exit 1
fi

RUBY_VERSION_INSTALLED=$(ruby -e 'puts RUBY_VERSION')
RUBY_MAJOR_MINOR="${RUBY_VERSION_INSTALLED%.*}"
if [[ "${RUBY_MAJOR_MINOR}" != "4.0" ]]; then
    print_error "Ruby ${RUBY_VERSION_INSTALLED} is installed, but 4.0.x is required."
    exit 1
fi
print_info "Ruby: ${RUBY_VERSION_INSTALLED}"

# Pin the interpreter for the rest of the script.
# rbenv picks the Ruby version from the .ruby-version file in the current
# directory. The compile-time simulation below runs in a temp directory, which
# has no .ruby-version file, so rbenv there falls back to the global version.
# If the global version is not the version this repo pins, the simulation runs
# under the wrong Ruby, and Bundler is missing because we installed it into the
# repo's Ruby. Setting RBENV_VERSION makes every ruby and bundle call in this
# script use the same interpreter no matter what directory it runs in.
# We ask rbenv for the name it resolved, because an rbenv version name is a
# directory name and does not have to equal the Ruby patch level.
if command -v rbenv &> /dev/null; then
    rbenv_resolved=$(rbenv version-name 2>/dev/null || true)
    if [[ -n "${rbenv_resolved}" ]]; then
        export RBENV_VERSION="${rbenv_resolved}"
        print_info "Pinned RBENV_VERSION=${RBENV_VERSION} for this run."
    fi
fi

# Always install bundler explicitly -- `gem list --silent` returns 0 for
# default gems (bundled with Ruby), but default gem executables live in the
# Ruby installation tree and are not visible to rbenv shims.  A real `gem
# install` places the binary where rbenv can find it after `rbenv rehash`.
# We always run 'gem install' to ensure Bundler is installed as a formal gem
# rather than a default gem. This guarantees that Bundler calculates and adds
# its own checksum to Gemfile.lock, keeping local and CI environments in sync.
print_info "Ensuring Bundler ${BOSH_BUNDLER_VERSION} is installed as a formal gem..."
gem install bundler -v "${BOSH_BUNDLER_VERSION}" --no-document --quiet

# Regenerate rbenv shims so the newly installed `bundle` binary is on PATH.
if command -v rbenv &>/dev/null; then
    rbenv rehash
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
print_info "Bundler: ${BOSH_BUNDLER_VERSION} (matches BOSH ruby-4.0)"

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
    local gem_name="${4:-}"

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
    if [[ -n "${gem_name}" ]]; then
        if ! "${BUNDLE_CMD[@]}" update "${gem_name}" --conservative; then
            print_error "bundle update ${gem_name} --conservative failed in ${label}"
            popd > /dev/null
            return 1
        fi
    elif ! "${BUNDLE_CMD[@]}" update --all; then
        print_error "bundle update --all failed in ${label}"
        popd > /dev/null
        return 1
    fi

    # Update the locked RUBY VERSION to match the active interpreter.
    # `bundle update --all` does NOT touch this field.
    if ! "${BUNDLE_CMD[@]}" update --ruby; then
        print_error "bundle update --ruby failed in ${label}"
        popd > /dev/null
        return 1
    fi

    # --- For src/fluentd: rebuild vendor/cache ---
    if [[ "${is_fluentd}" == "fluentd" ]]; then
        print_info "  Rebuilding vendor/cache (BOSH compile-time gems)..."

        if ! "${BUNDLE_CMD[@]}" config set --local cache_all true ||
            ! "${BUNDLE_CMD[@]}" config set --local cache_path ./vendor/cache ||
            ! "${BUNDLE_CMD[@]}" config set --local no_install true; then
            print_error "Could not set vendor/cache options in ${label}"
            popd > /dev/null
            return 1
        fi
        if ! BUNDLE_WITHOUT=development:test "${BUNDLE_CMD[@]}" package --all-platforms; then
            print_error "bundle package failed in ${label}"
            "${BUNDLE_CMD[@]}" config unset --local cache_all 2>/dev/null || true
            "${BUNDLE_CMD[@]}" config unset --local cache_path 2>/dev/null || true
            "${BUNDLE_CMD[@]}" config unset --local no_install 2>/dev/null || true
            rm -rf .bundle/ 2>/dev/null || true
            popd > /dev/null
            return 1
        fi

        if ! "${BUNDLE_CMD[@]}" config unset --local cache_all ||
            ! "${BUNDLE_CMD[@]}" config unset --local cache_path ||
            ! "${BUNDLE_CMD[@]}" config unset --local no_install; then
            print_error "Could not clear vendor/cache options in ${label}"
            rm -rf .bundle/ 2>/dev/null || true
            popd > /dev/null
            return 1
        fi
        rm -rf ./vendor/cache/ruby 2>/dev/null || true
        rm -rf ./vendor/cache/vendor 2>/dev/null || true
        rm -rf .bundle/ 2>/dev/null || true

        local gem_count
        gem_count=$(find vendor/cache -name '*.gem' 2>/dev/null | wc -l | tr -d '[:space:]')
        print_info "  ${gem_count} gems cached in vendor/cache"

        # Simulate BOSH compile: mirrors bosh_bundle_local() from compile-4.0.env
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

GEM_DIRS=(
    "${REPO_ROOT}"
    "${REPO_ROOT}/src/fluentd"
    "${REPO_ROOT}/src/fluentd/telemetry-filter-plugin"
    "${REPO_ROOT}/src/acceptance_tests"
    "${REPO_ROOT}/src/acceptance_tests_audit_mode"
)
GEM_LABELS=(root src/fluentd src/fluentd/telemetry-filter-plugin src/acceptance_tests src/acceptance_tests_audit_mode)

run_tests() {
    print_step "Running tests: root rspec"
    cd "${REPO_ROOT}"
    if ! "${BUNDLE_CMD[@]}" exec rspec; then
        print_error "Root rspec tests FAILED."
        return 1
    fi
    print_success "Root rspec tests passed."

    print_step "Running tests: filter-plugin rspec"
    cd "${REPO_ROOT}/src/fluentd/telemetry-filter-plugin"
    if ! "${BUNDLE_CMD[@]}" exec rspec; then
        print_error "Filter-plugin rspec tests FAILED."
        return 1
    fi
    print_success "Filter-plugin rspec tests passed."
}

SNAPSHOT_DIR="$(mktemp -d)"
cleanup_snapshot() { rm -rf "${SNAPSHOT_DIR}"; }
trap 'cleanup; cleanup_snapshot' EXIT

snapshot_state() {
    local destination="$1" index path
    rm -rf "${destination}"
    mkdir -p "${destination}"
    for index in "${!GEM_DIRS[@]}"; do
        path="${GEM_DIRS[$index]}/Gemfile.lock"
        if [[ -e "${path}" ]]; then
            mkdir -p "${destination}/${index}"
            cp -a "${path}" "${destination}/${index}/Gemfile.lock"
            : > "${destination}/${index}/lock-present"
        fi
    done
    path="${REPO_ROOT}/src/fluentd/vendor/cache"
    if [[ -e "${path}" ]]; then
        mkdir -p "${destination}/vendor"
        cp -a "${path}" "${destination}/vendor/cache"
        : > "${destination}/vendor-present"
    fi
}

restore_state() {
    local source="$1" index path
    for index in "${!GEM_DIRS[@]}"; do
        path="${GEM_DIRS[$index]}/Gemfile.lock"
        rm -f "${path}"
        if [[ -f "${source}/${index}/lock-present" ]]; then
            cp -a "${source}/${index}/Gemfile.lock" "${path}"
        fi
    done
    path="${REPO_ROOT}/src/fluentd/vendor/cache"
    rm -rf "${path}"
    if [[ -f "${source}/vendor-present" ]]; then
        mkdir -p "$(dirname "${path}")"
        cp -a "${source}/vendor/cache" "${path}"
    fi
}

outdated_gems() {
    local index dir output line gem_name old latest
    for index in "${!GEM_DIRS[@]}"; do
        dir="${GEM_DIRS[$index]}"
        output="$(cd "${dir}" && "${BUNDLE_CMD[@]}" outdated --parseable 2>/dev/null || true)"
        while IFS= read -r line; do
            # Bundler --parseable rows use: name (newest x, installed y).
            if [[ "${line}" =~ ^([^[:space:]]+)[[:space:]]+\(newest[[:space:]]+([^,]+),[[:space:]]+installed[[:space:]]+([^,\)]+) ]]; then
                gem_name="${BASH_REMATCH[1]}"
                latest="${BASH_REMATCH[2]}"
                old="${BASH_REMATCH[3]}"
                printf '%s\t%s\t%s\t%s\n' "${index}" "${gem_name}" "${old}" "${latest}"
            fi
        done <<< "${output}"
    done
}

print_step "Checking existing tests before any update"
if ! run_tests; then
    print_error "The code already fails its baseline tests. No gems were updated."
    exit 1
fi

snapshot_state "${SNAPSHOT_DIR}/baseline"
outdated_list="${SNAPSHOT_DIR}/outdated.tsv"
outdated_gems > "${outdated_list}"

print_step "Trying all gem updates"
all_updates_passed=true
for index in "${!GEM_DIRS[@]}"; do
    is_fluentd=""
    [[ "${index}" == 1 ]] && is_fluentd="fluentd"
    if ! update_gemfile_lock "${GEM_DIRS[$index]}" "${GEM_LABELS[$index]}" "${is_fluentd}"; then
        all_updates_passed=false
        break
    fi
done

held_back=()
if [[ "${all_updates_passed}" == true ]] && run_tests; then
    print_success "All gem updates passed the checks."
else
    print_warning "All-at-once update failed. Restoring the original lockfiles and vendor/cache."
    restore_state "${SNAPSHOT_DIR}/baseline"

    while IFS=$'\t' read -r index gem_name old latest; do
        [[ -z "${gem_name}" ]] && continue
        step_snapshot="${SNAPSHOT_DIR}/step"
        snapshot_state "${step_snapshot}"
        is_fluentd=""
        [[ "${index}" == 1 ]] && is_fluentd="fluentd"
        if update_gemfile_lock "${GEM_DIRS[$index]}" "${GEM_LABELS[$index]}" "${is_fluentd}" "${gem_name}" && run_tests; then
            print_success "Kept ${GEM_LABELS[$index]} ${gem_name} ${old} -> ${latest}."
        else
            restore_state "${step_snapshot}"
            held_back+=("${GEM_LABELS[$index]} ${gem_name} ${old} (latest ${latest})")
            print_warning "HELD BACK ${GEM_LABELS[$index]} ${gem_name} ${old} (latest ${latest})"
        fi
    done < "${outdated_list}"
fi

if ((${#held_back[@]} > 0)); then
    print_info "Held back:"
    printf '  %s\n' "${held_back[@]}"
else
    print_info "Held back: none"
fi

if ! run_tests; then
    print_error "The final state fails its tests."
    exit 1
fi

if [[ -n "${RUBY_VERSION_BEFORE}" ]]; then
    post_ruby=$(extract_ruby_version "${REPO_ROOT}/Gemfile.lock")
    print_info "Ruby version in Gemfile.lock updated: ${RUBY_VERSION_BEFORE} -> ${post_ruby}"
fi

still_outdated="${SNAPSHOT_DIR}/still-outdated.txt"
outdated_gems | while IFS=$'\t' read -r index gem_name old latest; do
    [[ -z "${gem_name}" ]] && continue
    printf '%s %s %s -> %s\n' "${GEM_LABELS[$index]}" "${gem_name}" "${old}" "${latest}"
done > "${still_outdated}" || true
if [[ -s "${still_outdated}" ]]; then
    print_info "Still outdated:"
    sed 's/^/  /' "${still_outdated}"
else
    print_info "Still outdated: none"
fi

print_success "Ruby gem update process complete."
