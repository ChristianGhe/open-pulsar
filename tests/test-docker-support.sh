#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local content="$2"
    local pattern="$3"
    if echo "$content" | grep -qF -- "$pattern"; then
        echo "  PASS: $desc"
        ((pass++)) || true
    else
        echo "  FAIL: $desc (pattern '$pattern' not found)"
        ((fail++)) || true
    fi
}

assert_not_contains() {
    local desc="$1"
    local content="$2"
    local pattern="$3"
    if ! echo "$content" | grep -qF -- "$pattern"; then
        echo "  PASS: $desc"
        ((pass++)) || true
    else
        echo "  FAIL: $desc (pattern '$pattern' should not be present)"
        ((fail++)) || true
    fi
}

echo "=== Docker support tests ==="

dockerfile_content="$(cat "$ROOT_DIR/Dockerfile")"
readme_content="$(cat "$ROOT_DIR/README.md")"

assert_contains "Dockerfile installs jq"              "$dockerfile_content" "jq"
assert_contains "Dockerfile uses native installer"    "$dockerfile_content" "claude.ai/install.sh"
assert_contains "Dockerfile disables autoupdater"     "$dockerfile_content" "DISABLE_AUTOUPDATER"
assert_not_contains "Dockerfile does not use npm"     "$dockerfile_content" "@anthropic-ai/claude-code"
assert_contains "README documents docker build"       "$readme_content" "docker build -t agent-loop ."
assert_contains "README documents docker run"         "$readme_content" "docker run --rm -it"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
