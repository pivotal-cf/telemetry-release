#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fixture="${tmp}/repo"
mkdir -p "${fixture}/scripts" "${tmp}/bin"
cp "${repo_root}/scripts/update-ruby-gems.sh" "${fixture}/scripts/"

for dir in . src/fluentd src/fluentd/telemetry-filter-plugin src/acceptance_tests src/acceptance_tests_audit_mode; do
    mkdir -p "${fixture}/${dir}"
    cat > "${fixture}/${dir}/Gemfile" <<'EOF'
source 'https://rubygems.org'
EOF
    cat > "${fixture}/${dir}/Gemfile.lock" <<'EOF'
PLATFORMS
  ruby

RUBY VERSION
   ruby 4.0.23

BUNDLED WITH
   4.0.23
EOF
done
mkdir -p "${fixture}/src/fluentd/vendor/cache"
git -C "${fixture}" init -q

cat > "${tmp}/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/packaging" ]]; then
    printf 'RUBY_VERSION=4.0.23\nRUBYGEMS_VERSION=4.0.3\nBUNDLER_VERSION=4.0.23\n'
else
    printf '4.0.23\n'
fi
EOF
cat > "${tmp}/bin/ruby" <<'EOF'
#!/usr/bin/env bash
printf '4.0.23\n'
EOF
cat > "${tmp}/bin/gem" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${tmp}/bin/rbenv" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == version-name ]]; then printf '4.0.23\n'; fi
exit 0
EOF
cat > "${tmp}/bin/bundle" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == _* ]]; then shift; fi
if [[ "${1:-}" == --version ]]; then
    printf 'Bundler version 4.0.23\n'
    exit 0
fi
case "$1" in
    outdated)
        printf 'badgem (newest 2.0.0, installed 1.0.0)\ngoodgem (newest 2.0.0, installed 1.0.0)\n'
        ;;
    update)
        if [[ "${2:-}" == --all ]]; then
            printf '\nBULK\n' >> Gemfile.lock
        elif [[ "${2:-}" == badgem ]]; then
            printf '\nBADGEM\n' >> Gemfile.lock
        elif [[ "${2:-}" == goodgem ]]; then
            printf '\nGOODGEM\n' >> Gemfile.lock
        fi
        ;;
    package)
        mkdir -p vendor/cache
        : > vendor/cache/test.gem
        ;;
    exec)
        if grep -Eq 'BULK|BADGEM' Gemfile.lock; then exit 1; fi
        ;;
esac
EOF
chmod +x "${tmp}/bin/"*

if ! PATH="${tmp}/bin:${PATH}" bash "${fixture}/scripts/update-ruby-gems.sh" > "${tmp}/run.log" 2>&1; then
    cat "${tmp}/run.log" >&2
    exit 1
fi
if ! rg -q 'HELD BACK root badgem 1.0.0 \(latest 2.0.0\)' "${tmp}/run.log"; then
    echo 'missing expected held-back report' >&2
    cat "${tmp}/run.log" >&2
    exit 1
fi
if ! rg -q 'Kept root goodgem 1.0.0 -> 2.0.0' "${tmp}/run.log"; then
    echo 'missing expected kept update report' >&2
    cat "${tmp}/run.log" >&2
    exit 1
fi
rg -q GOODGEM "${fixture}/Gemfile.lock"
if rg -q BADGEM "${fixture}/Gemfile.lock"; then
    echo "badgem change was not restored" >&2
    exit 1
fi
rg -q 'Still outdated:' "${tmp}/run.log"
printf 'hold-back fixture passed: badgem was restored and goodgem stayed updated\n'
