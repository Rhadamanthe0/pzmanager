#!/usr/bin/env bash
# Compile and run policy fixtures in an isolated disposable Linux directory.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
TEST_JAR="${PZ_WRITING_TEST_JAR:-${REPO_DIR}/data/pzserver/java/projectzomboid.jar}"
TEST_GUARD="${PZ_WRITING_TEST_GUARD:-${REPO_DIR}/data/scripts/internal/PZManagerWritingTextOnly.lua}"
TEST_STDLIB="${PZ_WRITING_TEST_STDLIB:-}"
TEST_JDK_BIN="${PZ_WRITING_TEST_JDK_BIN:-}"

usage() {
    cat <<'HELP'
Usage: tests/writing_text_only/run.sh [options]
  --jar PATH       PZ projectzomboid.jar (copied; never executed in game folder)
  --guard PATH     Policy Lua to test
  --stdlib PATH    PZ stdlib.lua (default: alongside JAR)
  --jdk-bin PATH   Directory containing java and javac (default: PATH)

Equivalent environment variables: PZ_WRITING_TEST_JAR, PZ_WRITING_TEST_GUARD,
PZ_WRITING_TEST_STDLIB, PZ_WRITING_TEST_JDK_BIN.
A JDK compatible with the selected PZ JAR is required. All execution happens
in a fresh mktemp directory. No server launch, .env access or savefile access.
HELP
}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jar|--guard|--stdlib|--jdk-bin)
            [[ $# -ge 2 ]] || fail "${1} requires a path"
            case "$1" in
                --jar) TEST_JAR="$2" ;;
                --guard) TEST_GUARD="$2" ;;
                --stdlib) TEST_STDLIB="$2" ;;
                --jdk-bin) TEST_JDK_BIN="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: ${1}" ;;
    esac
done

[[ -f "$TEST_JAR" ]] || fail "PZ JAR not found: ${TEST_JAR}; supply --jar"
[[ -f "$TEST_GUARD" ]] || fail "Policy not found: ${TEST_GUARD}; supply --guard"
[[ -n "$TEST_STDLIB" ]] || TEST_STDLIB="$(dirname -- "$TEST_JAR")/stdlib.lua"
[[ -f "$TEST_STDLIB" ]] || fail "PZ stdlib.lua not found: ${TEST_STDLIB}; supply --stdlib"
if [[ -n "$TEST_JDK_BIN" ]]; then
    TEST_JAVA="${TEST_JDK_BIN}/java"
    TEST_JAVAC="${TEST_JDK_BIN}/javac"
    [[ -x "$TEST_JAVA" && -x "$TEST_JAVAC" ]] || fail "--jdk-bin must contain executable java and javac"
else
    TEST_JAVA="$(command -v java || true)"
    TEST_JAVAC="$(command -v javac || true)"
    [[ -n "$TEST_JAVA" && -n "$TEST_JAVAC" ]] || fail "A JDK is required; supply --jdk-bin"
fi

TEST_JAVA="$(realpath -- "$TEST_JAVA")"
TEST_JAVAC="$(realpath -- "$TEST_JAVAC")"

umask 077
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pz-writing-policy-test.XXXXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
cp -- "$TEST_JAR" "${TEST_DIR}/projectzomboid.jar"
cp -- "$TEST_STDLIB" "${TEST_DIR}/stdlib.lua"
cp -- "$TEST_GUARD" "${TEST_DIR}/PZManagerWritingTextOnly.lua"
cp -- "${SCRIPT_DIR}/test_guard.lua" "${TEST_DIR}/test_guard.lua"
cp -- "${SCRIPT_DIR}/GuardLuaTest.java" "${TEST_DIR}/GuardLuaTest.java"
cp -- "${SCRIPT_DIR}/SandboxProbe.java" "${TEST_DIR}/SandboxProbe.java"
(
    cd -- "$TEST_DIR"
    "$TEST_JAVAC" -cp projectzomboid.jar GuardLuaTest.java SandboxProbe.java
    "$TEST_JAVA" -Duser.home="$TEST_DIR" -cp .:projectzomboid.jar GuardLuaTest PZManagerWritingTextOnly.lua test_guard.lua
    "$TEST_JAVA" -Duser.home="$TEST_DIR" -cp .:projectzomboid.jar SandboxProbe PZManagerWritingTextOnly.lua
)
printf 'PASS: writing policy fixtures on PZ Kahlua, isolated Linux copy\n'
