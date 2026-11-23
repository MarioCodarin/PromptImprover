#!/bin/bash
# The whole gate: offline self-tests, then every pipeline path against the mock provider.
# Exits non-zero on the first failure. Run after any change to a prompt, a stage or a parser.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=".build/debug/PromptImprover"
PORT="${PORT:-8765}"
FAILS=0
PASSES=0

say()  { printf '%s\n' "$*"; }
ok()   { PASSES=$((PASSES+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAILS=$((FAILS+1));  printf '  FAIL  %s\n' "$1"; }

# expect <label> <exit-code> <needle> -- <command...>
expect() {
  local label="$1" want="$2" needle="$3"; shift 4
  local out; out=$("$@" 2>&1); local code=$?
  if [[ "$code" != "$want" ]]; then
    bad "$label (exit $code, wanted $want)"; printf '%s\n' "$out" | tail -5 | sed 's/^/        /'; return
  fi
  if [[ -n "$needle" ]] && ! grep -qF -- "$needle" <<<"$out"; then
    bad "$label (missing: $needle)"; printf '%s\n' "$out" | tail -5 | sed 's/^/        /'; return
  fi
  ok "$label"
}

say "── offline ────────────────────────────────────────"
"$BIN" --selftest | sed 's/^/  /'
[[ ${PIPESTATUS[0]} -eq 0 ]] && PASSES=$((PASSES+1)) || FAILS=$((FAILS+1))

say ""
say "── pipeline (mock provider on :$PORT) ─────────────"
python3 Tests/mock_llm.py "$PORT" >/dev/null 2>&1 &
MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break
  sleep 0.1
done

BASE="http://127.0.0.1:$PORT"

expect "fast: one call, gate still fails a weak prompt" 1 "calls 1" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --rigor Fast

expect "standard: diagnose, write, verify, repair, reverify" 0 "reverify ship" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --rigor Standard

expect "deep: adds acceptance tests" 0 "tests 2 cases" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --rigor Deep

expect "anthropic wire format runs the same pipeline" 0 "repair accepted" \
  -- "$BIN" --e2e "$BASE/anthropic/v1" --format anthropic --key k --model mock --rigor Deep

expect "503 is retried, not surfaced" 0 "gate: PASS" \
  -- "$BIN" --e2e "$BASE/retry/v1" --key k --model mock --rigor Standard

expect "a gateway that rejects response_format still completes" 0 "gate: PASS" \
  -- "$BIN" --e2e "$BASE/nojson/v1" --key k --model mock --rigor Standard

expect "a gateway that rejects stream_options and reasoning_effort still completes" 0 "gate: PASS" \
  -- "$BIN" --e2e "$BASE/strict/v1" --key k --model mock --rigor Standard

expect "anthropic usage counts input tokens" 0 "tokens 0 in" \
  -- "$BIN" --e2e "$BASE/anthropic/v1" --format anthropic --key k --model mock --rigor Fast

expect "a truncated reply fails loudly instead of shipping half a prompt" 2 "cut off" \
  -- "$BIN" --e2e "$BASE/truncate/v1" --key k --model mock --rigor Standard

expect "an unreachable host reports an error" 2 "" \
  -- "$BIN" --e2e "http://127.0.0.1:1/v1" --key k --model mock --rigor Fast

say ""
if [[ $FAILS -eq 0 ]]; then
  say "all green — $PASSES checks"
  exit 0
fi
say "$FAILS failing, $PASSES passing"
exit 1
