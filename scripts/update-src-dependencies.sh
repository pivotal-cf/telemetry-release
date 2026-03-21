#!/usr/bin/env bash
#
# Update all src/ dependencies: Ruby gems and Go modules.
#
# This is a convenience wrapper that calls:
#   1. scripts/update-ruby-gems.sh  -- updates all 5 Gemfile.locks + runs rspec
#   2. scripts/update-go-modules.sh -- updates Go modules in acceptance test receivers
#
# If either script fails, this wrapper aborts (via set -e).
#
# Usage:
#   ./scripts/update-src-dependencies.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/update-ruby-gems.sh"
"${SCRIPT_DIR}/update-go-modules.sh"
