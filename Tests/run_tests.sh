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
# A stale listener on the port answers the readiness poll below, so the suite silently talked to
# someone else's mock — two simultaneous runs produced 16 bogus "Could not connect to the server"
# failures, and `set -uo pipefail` without -e carried on past them. Refuse instead of guessing.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  say "  FAIL  port $PORT is already in use — re-run with PORT=<free port>"
  exit 1
fi
python3 Tests/mock_llm.py "$PORT" >/dev/null 2>&1 &
MOCK=$!
# EXIT does not run when the shell is killed, which left the port held and the next run talking
# to a corpse. Trap the signals too, and wait for the child so the port is actually free.
cleanup() { kill "$MOCK" 2>/dev/null; wait "$MOCK" 2>/dev/null; }
trap cleanup EXIT INT TERM
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break
  sleep 0.1
done

BASE="http://127.0.0.1:$PORT"

expect "fast: one call, gate still fails a weak prompt" 1 "calls 1" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --rigor Fast

expect "standard: clarify, write, lint, one repair from the lint findings" 0 "calls 3" \
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

# The needle is the assertion. It read "tokens 0 in", which is the bug, not the fix.
# Three calls at 1500 + 400 cached + 100 written each.
expect "anthropic usage counts cached input too" 0 "tokens 6000 in (1200 cached)" \
  -- "$BIN" --e2e "$BASE/anthropic/v1" --format anthropic --key k --model mock --rigor Standard

# Three calls at 2100 each.
expect "chat-completions usage counts input tokens" 0 "tokens 6300 in" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --rigor Standard

# A clean first draft costs two calls on Standard: clarify and write. No reviewer, no repair.
expect "standard: a clean prompt costs two calls" 0 "calls 2" \
  -- "$BIN" --e2e "$BASE/polish/v1" --key k --model mock --rigor Standard

# The two halves of the repair trigger, which have to stay in opposite directions. The reviewer
# runs on Deep only. Polish: the gate passes, the reviewer objects to minors, and no repair call
# is spent — clarify, write, review, tests.
expect "polish does not spend a repair call on a clean prompt" 0 "calls 4" \
  -- "$BIN" --e2e "$BASE/polish/v1" --key k --model mock --rigor Deep

# A fabrication the linter cannot see still repairs, even though the gate is clean. Skipping this
# would ship the one failure the tool exists to prevent.
expect "a fabrication the linter cannot see still repairs" 0 "repair accepted" \
  -- "$BIN" --e2e "$BASE/fabricate/v1" --key k --model mock --rigor Deep

# The other half of the gate. An unparseable critic reply used to drop the whole repair decision,
# so a stray brace in the critic's prose switched off the deterministic half — the half that exists
# because the critic cannot be trusted. The writer's first attempt is missing its success criteria,
# so the linter has a blocker and repair must run anyway.
expect "an unparseable verdict does not switch the gate off" 0 "repair accepted" \
  -- "$BIN" --e2e "$BASE/garbage/v1" --key k --model mock --rigor Deep

expect "a truncated reply fails loudly instead of shipping half a prompt" 2 "cut off" \
  -- "$BIN" --e2e "$BASE/truncate/v1" --key k --model mock --rigor Standard

# The tokens a cut-off call spent were still spent. On the chat-completions wire the usage chunk
# arrives *after* the finish_reason chunk, so throwing at the finish_reason abandoned the stream
# before the count was read and the call contributed zero. The mock sends 2100/360 per call, so a
# run whose write is truncated must report both calls, not one.
expect "a truncated reply still counts the tokens it spent" 2 "spent: 4200 in" \
  -- "$BIN" --e2e "$BASE/truncate/v1" --key k --model mock --rigor Standard

expect "an unreachable host reports an error" 2 "" \
  -- "$BIN" --e2e "http://127.0.0.1:1/v1" --key k --model mock --rigor Fast

# The two time limits. A server that goes silent mid-write is cut by the stall watchdog (and its
# one retry), not held for ten minutes; the mock sleeps 30 s, so a pass here is a pass in ~6 s.
T0=$(date +%s)
expect "a silent gateway is cut off by the stall watchdog" 2 "stopped sending" \
  -- "$BIN" --e2e "$BASE/stall/v1" --key k --model mock --rigor Fast --stall 2 --deadline 12
T1=$(date +%s)
if (( T1 - T0 < 20 )); then ok "the stall cut-off took $((T1 - T0))s, not the mock's 30"; else bad "stall took $((T1 - T0))s"; fi

# A write slower than the whole budget ends on the deadline, with an error: there is no finished
# prompt to fall back on, and a fragment is never shipped.
expect "a write past the deadline fails instead of hanging" 2 "time limit" \
  -- "$BIN" --e2e "$BASE/drip/v1" --key k --model mock --rigor Fast --deadline 3

# Too little budget left for a repair: the written prompt is kept and the run says why.
expect "a short budget keeps the written prompt and skips repair" 1 "ended: time limit" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --rigor Standard --deadline 10

# --e2e drives PromptEngine, so it covers the pipeline and none of the state machine. The probe
# drives the real view model: a fail() that destroyed the prompt it had just restored passed a
# fully green suite, because nothing here ever touched it.
LABELED=$(mktemp -t pi-label)
cat > "$LABELED" <<'FIXTURE'
Purpose: You review Go changes for correctness before they merge.

## How you work
Read the diff, then the tests that cover it. If a test would still pass after the change is
reverted, say so — that test is not covering the change.

## Output contract
One comment per finding, Markdown, under 200 words. No praise, no summary of the diff.
Do not comment on formatting.
FIXTURE
expect "a labelled section counts as a section" 0 "All 17 structural checks passed" \
  -- "$BIN" --lint "$LABELED" --target "System prompt"

expect "the view model keeps the prompt when a refine dies" 0 "vm probe: all green" \
  -- "$BIN" --vm "$BASE/v1" --key k --model mock --rigor Fast

# `--rigor` is parsed case-insensitively. The `?? .fast` fallback lived in the `--vm` path, so the
# case that actually regressed is a lower-case depth there; `--e2e` fell back to Standard, which is
# why the needle has to be the Deep-only stage. `verify` would match on the broken binary too.
expect "a lower-case rigor is honoured, not silently downgraded" 0 "tests 2 cases" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --rigor deep
expect "the view model honours a lower-case rigor" 0 "vm probe: all green" \
  -- "$BIN" --vm "$BASE/v1" --key k --model mock --rigor standard

# A typo must not buy the cheap pipeline. `deepish` used to fall back and report PASS.
expect "an unknown rigor is rejected instead of downgraded" 64 "unknown rigor" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --rigor deepish
# The same class of defect on the other two enums: an unknown format ran the wrong wire format,
# an unknown effort went onto the wire verbatim and failed at the provider, and an unknown target
# linted against the wrong section set — all three silently.
expect "an unknown format is rejected" 64 "unknown format" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --format anthropc
expect "an unknown effort is rejected" 64 "unknown effort" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --effort loww
expect "an unknown lint target is rejected" 64 "unknown target" \
  -- "$BIN" --lint "$BIN" --target "Agent"
expect "an unknown e2e target is rejected" 64 "unknown target" \
  -- "$BIN" --e2e "$BASE/v1" --key k --model mock --target "Agent"
# `--lint` with no path used to fall through to the GUI and look like a hang.
expect "lint without a file prints usage" 64 "usage: PromptImprover --lint" \
  -- "$BIN" --lint
# Every prompt has to be reachable, or the documented before/after diff misses half of them.
expect "dump-prompts covers every stage and target" 0 "14 prompts" \
  -- "$BIN" --dump-prompts

# The revert branch of RepairGuard is the policy both callers share, and the reason strings the
# panel renders come from it. It was covered only by offline unit cases, never end to end. The run
# exits 1 because the *original* was weak and no repair was accepted — that is the correct verdict,
# and the assertion is on the decision, not on the exit code.
expect "a repair that makes the prompt worse is discarded" 1 "kept original" \
  -- "$BIN" --e2e "$BASE/revert/v1" --key k --model mock --rigor Standard

say ""
if [[ $FAILS -eq 0 ]]; then
  say "all green — $PASSES checks"
  exit 0
fi
say "$FAILS failing, $PASSES passing"
exit 1
