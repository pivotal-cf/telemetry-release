#!/usr/bin/env bash
#
# Update every dependency of one Go module, and keep only the updates that pass.
#
# What it does:
#   1. Runs the check command. If it fails now, the script stops. We never
#      update on top of code that already fails.
#   2. Updates all dependencies at once, test-only ones included (go get -u -t).
#      If the check still passes, it is done.
#   3. If the check fails, it undoes step 2. In both cases it then tries each
#      module that is still outdated, alone. An update that breaks the check is undone and reported
#      as "held back". All other updates stay.
#
# Major versions are never touched. Go treats a new major version as a
# different module path, so "go list -m -u" does not offer it.
#
# The check command is $GO_VERIFY_CMD. The default is:
#   go build -o /dev/null ./... && go vet ./... && go test -count=1 ./...
#
# Exit codes:
#   0 -- success (whether or not anything changed)
#   1 -- the check failed before any update, or go mod tidy failed
#
# Usage:
#   ./scripts/update-go-module-safely.sh <module-dir>

set -euo pipefail

MODULE_DIR="${1:-}"
if [[ -z "${MODULE_DIR}" || ! -f "${MODULE_DIR}/go.mod" ]]; then
    echo "Usage: $0 <dir containing go.mod>" >&2
    exit 1
fi

VERIFY_CMD="${GO_VERIFY_CMD:-go build -o /dev/null ./... && go vet ./... && go test -count=1 ./...}"

if ! command -v go &> /dev/null && command -v goenv &> /dev/null; then
    eval "$(goenv init -)"
fi

cd "${MODULE_DIR}"

SNAP_DIR="$(mktemp -d)"
trap 'rm -rf "${SNAP_DIR}"' EXIT

snapshot() { cp go.mod "${SNAP_DIR}/go.mod"; cp go.sum "${SNAP_DIR}/go.sum" 2>/dev/null || : > "${SNAP_DIR}/go.sum"; }
restore()  { cp "${SNAP_DIR}/go.mod" go.mod; cp "${SNAP_DIR}/go.sum" go.sum; }
verify()   { bash -c "${VERIFY_CMD}" > "${SNAP_DIR}/verify.log" 2>&1; }

# Outdated modules that go.mod itself requires. Go's module graph also lists
# modules that go.mod does not need. Those are not part of this build.
outdated() {
    local required
    required="$(go mod edit -json | jq -r '.Require[].Path')"
    go list -m -u -f '{{if and .Update (not .Main)}}{{.Path}} {{.Version}} {{.Update.Version}}{{end}}' all 2>/dev/null \
        | while read -r path current latest; do
            [[ -z "${path}" ]] && continue
            if grep -qxF -- "${path}" <<< "${required}"; then echo "${path} ${current} ${latest}"; fi
        done
}

echo "[go-update] module: $(go list -m) in ${MODULE_DIR}"
echo "[go-update] go: $(go version)"

echo "[go-update] checking the code before any update"
if ! verify; then
    echo "[go-update] FAIL: the check fails before any update. Last lines:" >&2
    tail -n 20 "${SNAP_DIR}/verify.log" >&2
    exit 1
fi

snapshot

held_back=()

# Try each outdated module alone. Keep an update only if the check passes.
update_one_by_one() {
    local path current latest
    while read -r path current latest; do
        [[ -z "${path}" ]] && continue
        snapshot
        if go get "${path}@${latest}" > "${SNAP_DIR}/get.log" 2>&1 && go mod tidy >> "${SNAP_DIR}/get.log" 2>&1 && verify; then
            echo "[go-update]   ${path} ${current} -> ${latest}"
        else
            restore
            held_back+=("${path} ${current} (latest ${latest})")
            echo "[go-update]   HELD BACK ${path}: ${latest} breaks the check"
        fi
    done < <(outdated)
}

echo "[go-update] trying all updates at once"
if go get -u -t ./... > "${SNAP_DIR}/get.log" 2>&1 && go mod tidy >> "${SNAP_DIR}/get.log" 2>&1 && verify; then
    echo "[go-update] all updates passed the check"
else
    echo "[go-update] all-at-once failed. Undoing it."
    restore
fi

echo "[go-update] updating the rest one module at a time"
update_one_by_one

if ((${#held_back[@]} > 0)); then
    echo "[go-update] held back (${#held_back[@]}):"
    printf '[go-update]   %s\n' "${held_back[@]}"
fi

# Final state must be tidy and must pass the check.
go mod tidy
if ! verify; then
    echo "[go-update] FAIL: the final state does not pass the check. Last lines:" >&2
    tail -n 20 "${SNAP_DIR}/verify.log" >&2
    exit 1
fi

# A held-back module is listed here as still outdated. That is expected.
# This list is only for the report. A failure here must not fail the update.
remaining=$(outdated | while read -r path current latest; do echo "${path} ${current} -> ${latest}"; done || true)
if [[ -n "${remaining}" ]]; then
    echo "[go-update] still outdated after the update:"
    echo "${remaining}" | sed 's/^/[go-update]   /'
fi
echo "[go-update] done"
