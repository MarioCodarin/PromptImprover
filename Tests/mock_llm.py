#!/usr/bin/env python3
"""A deliberately dumb mock of the chat-completions wire format, used to prove the pipeline end to end.

It behaves like a badly-behaved real provider on purpose:
  * streams SSE in small chunks, including a leading `: keep-alive` comment,
  * answers the diagnostic stage with JSON wrapped in prose and a code fence,
  * answers the writer's first attempt with a prompt that is missing its success criteria,
  * answers the verifier with a blocker, and the repair with a fixed prompt,
so `--e2e` exercises JSON extraction, the linter, the repair loop and the regression guard.

    python3 Tests/mock_llm.py 8765
    .build/debug/PromptImprover --e2e http://127.0.0.1:8765/v1 --key test --model mock --rigor Deep

The first path segment selects a failure mode, so plumbing can be tested without changing the client:
    /v1/...            normal
    /truncate/v1/...   the writer's reply is cut off (finish_reason "length") on its first call
    /retry/v1/...      every stage's first request gets HTTP 503, then succeeds
    /nojson/v1/...     every stage's first request gets HTTP 400 for response_format, then succeeds
    /strict/v1/...     rejects stream_options and reasoning_effort with 400, like a locked-down gateway
    /anthropic/v1/...  speaks the /messages SSE shape instead of /chat/completions
    /slow/v1/...       every stage takes 1.5s, so a mid-stage Stop can be pressed
    /garbage/v1/...    the verifier's reply is unparseable, so only the linter can gate
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIAGNOSIS = {
    "brief": "The user wants a landing page but has said nothing about audience, offer or success. "
             "The two decisions that change everything are who it is for and what a visitor must do.",
    "task_type": "design",
    "risk": "medium",
    "findings": [
        {"code": "D01", "severity": "blocker", "quote": "make me a landing page",
         "fix": "Name the audience and the single action a visitor should take."},
        {"code": "D03", "severity": "blocker", "quote": "make me a landing page",
         "fix": "Pin the deliverable: file format, sections, length."},
    ],
    "scores": {
        "goal": {"note": "A verb and an object, no outcome.", "score": 1},
        "context": {"note": "Nothing about audience or offer.", "score": 0},
        "inputs": {"note": "No brand assets, copy or constraints mentioned.", "score": 0},
        "deliverable": {"note": "No format stated.", "score": 0},
        "criteria": {"note": "Nothing could fail.", "score": 0},
        "constraints": {"note": "No scope boundary.", "score": 0},
        "procedure": {"note": "Single-page task, order still matters.", "score": 1},
        "autonomy": {"note": "Unstated.", "score": 1},
        "verification": {"note": "Unstated.", "score": 0},
        "consistency": {"note": "Nothing to contradict.", "score": 2},
        "economy": {"note": "Three words, no filler.", "score": 3},
        "robustness": {"note": "Unstated.", "score": 0},
    },
    "questions": [
        {"question": "Who is the page for?", "why": "It decides tone, proof and call to action.",
         "options": ["Developers evaluating a tool", "Small-business owners", "Investors"],
         "default": "Developers evaluating a tool"},
        {"question": "What must a visitor do?", "why": "One action shapes the whole layout.",
         "options": ["Start a free trial", "Book a call", "Join a waitlist"], "default": "Start a free trial"},
    ],
    "assumptions": ["Assume a marketing page for a developer tool"],
}

WEAK_PROMPT = """# Landing page

## Objective
Build a landing page for our product.

## Context
We are launching soon and need a page that looks good.

## Requirements
- Hero section with a headline.
- Three feature blocks.
- A footer.

## Output contract
One HTML file.
"""

STRONG_PROMPT = """# Landing page for a developer tool, aimed at evaluators

## Objective
Produce a single-page marketing site that gets a developer who lands on it to start a free trial. Success is a page where the trial button is the only obvious next step.

## Context
The audience is developers evaluating tools, not executives: they skim, distrust adjectives, and look for a code sample within ten seconds. The product has no brand assets yet, so the page must work with type and layout alone.

## Inputs
- Product name and one-line description: {{PRODUCT_NAME}}, {{ONE_LINER}}.
- No logo, no screenshots, no testimonials exist. Do not invent them.

## Requirements
- Above the fold: headline, one-line description, primary call to action, and a short code sample showing the first call.
- One section of three concrete capabilities, each with a single sentence and no superlatives.
- One section answering the three objections developers actually raise: cost, lock-in, and setup time.
- Footer with a link to the documentation and a licence line.

## Constraints and non-goals
- One self-contained HTML file with inline CSS. No build step, no external requests.
- Out of scope: analytics, cookie banner, multi-language, dark mode.
- Under 250 lines of markup.

## Approach
1. Read the product name and one-liner; if either is a placeholder, stop and ask rather than inventing a name.
2. Write the headline and the code sample first. They decide the layout.
3. Build the page around them, then compress.

## Output contract
A single HTML file. Semantic markup, no framework, system font stack. English. No placeholder Lorem Ipsum anywhere.

## Success criteria
- The file opens with no network access and no console errors.
- Exactly one primary call-to-action button appears above the fold.
- A code sample appears within the first viewport.
- The page contains no invented testimonials, logos or metrics.
- Markup stays under 250 lines.

## Verification
Before finishing, open the file, confirm the five criteria above one by one, and report the line count. If any criterion fails, fix it rather than noting it.

## Autonomy and escalation
Proceed without asking. Stop and ask only if the product name or one-liner is missing, since inventing either would misrepresent the product.

## Assumptions
- The page is a marketing page for a developer tool, not a product UI.
- The trial signup is an external link; this page does not implement it.
"""

CRITIQUE_REPAIR = {
    "verdict": "repair",
    "summary": "The page cannot be checked: there are no success criteria and the output contract is one line.",
    "issues": [
        {"axis": "criteria", "severity": "blocker", "quote": "Build a landing page for our product.",
         "problem": "Nothing here can fail, so nothing will be verified.",
         "fix": "Add a Success criteria section with five observable checks."},
        {"axis": "deliverable", "severity": "major", "quote": "One HTML file.",
         "problem": "Format is pinned but structure, length and language are not.",
         "fix": "Name the markup constraints and an explicit exclusion."},
    ],
    "strengths": ["The section skeleton is already in place."],
    "scores": {
        "goal": {"note": "Outcome missing.", "score": 1},
        "context": {"note": "No audience.", "score": 0},
        "inputs": {"note": "None.", "score": 0},
        "deliverable": {"note": "Format only.", "score": 1},
        "criteria": {"note": "Absent.", "score": 0},
        "constraints": {"note": "Absent.", "score": 0},
        "procedure": {"note": "None.", "score": 1},
        "autonomy": {"note": "None.", "score": 1},
        "verification": {"note": "None.", "score": 0},
        "consistency": {"note": "Nothing conflicts.", "score": 2},
        "economy": {"note": "Short and clean.", "score": 3},
        "robustness": {"note": "None.", "score": 0},
    },
}

CRITIQUE_POLISH = {
    "verdict": "repair",
    "summary": "Executable as written; two lines could be tighter.",
    "issues": [
        {"axis": "economy", "severity": "minor", "quote": "Everything on the page either moves a visitor",
         "problem": "The sentence runs long.", "fix": "Split it in two."},
        {"axis": "economy", "severity": "minor", "quote": "The page has one job",
         "problem": "Filler clause.", "fix": "Delete it."},
    ],
    "strengths": ["Criteria are checkable", "Exclusions prevent invention"],
    "scores": {
        "goal": {"note": "Outcome stated.", "score": 4},
        "context": {"note": "Only non-inferable facts.", "score": 4},
        "inputs": {"note": "Named.", "score": 3},
        "deliverable": {"note": "Format, length, language, exclusion.", "score": 4},
        "criteria": {"note": "Observable checks.", "score": 4},
        "constraints": {"note": "In and out of scope.", "score": 3},
        "procedure": {"note": "Ordered.", "score": 3},
        "autonomy": {"note": "Escalation trigger named.", "score": 3},
        "verification": {"note": "Check-then-report.", "score": 4},
        "consistency": {"note": "No conflicting pair.", "score": 4},
        "economy": {"note": "Two long lines.", "score": 3},
        "robustness": {"note": "Placeholder policy stated.", "score": 3},
    },
}

CRITIQUE_FABRICATE = {
    "verdict": "repair",
    "summary": "Structurally sound, but it asserts a statistic the request never supplied.",
    "issues": [
        {"axis": "context", "severity": "blocker", "quote": "converts 38% better than a static page",
         "problem": "Invented figure. Nothing in the request supports it, and the executor will "
                    "treat it as given fact.",
         "fix": "Replace it with a marked placeholder, or state the assumption explicitly."},
    ],
    "strengths": ["Every structural check passes"],
    "scores": {
        "goal": {"note": "Outcome stated.", "score": 4},
        "context": {"note": "One invented figure.", "score": 1},
        "inputs": {"note": "Named.", "score": 3},
        "deliverable": {"note": "Pinned.", "score": 4},
        "criteria": {"note": "Observable.", "score": 4},
        "constraints": {"note": "Bounded.", "score": 3},
        "procedure": {"note": "Ordered.", "score": 3},
        "autonomy": {"note": "Trigger named.", "score": 3},
        "verification": {"note": "Check-then-report.", "score": 4},
        "consistency": {"note": "No conflict.", "score": 4},
        "economy": {"note": "Tight.", "score": 4},
        "robustness": {"note": "Stated.", "score": 3},
    },
}

CRITIQUE_SHIP = {
    "verdict": "ship",
    "summary": "Executable as written: the criteria are observable and the exclusions are explicit.",
    "issues": [],
    "strengths": ["Criteria are checkable", "Inputs are named", "Exclusions prevent invention"],
    "scores": {
        "goal": {"note": "Outcome and audience both stated.", "score": 4},
        "context": {"note": "Only non-inferable facts.", "score": 4},
        "inputs": {"note": "Named, with an explicit gap.", "score": 4},
        "deliverable": {"note": "Format, length, language, exclusion.", "score": 4},
        "criteria": {"note": "Five checks, all observable.", "score": 4},
        "constraints": {"note": "In and out of scope, with a budget.", "score": 4},
        "procedure": {"note": "Ordered with a stopping condition.", "score": 4},
        "autonomy": {"note": "Named escalation trigger.", "score": 3},
        "verification": {"note": "Check-then-report, no noting-and-moving-on.", "score": 4},
        "consistency": {"note": "No conflicting pair.", "score": 4},
        "economy": {"note": "Every line carries a decision.", "score": 3},
        "robustness": {"note": "Placeholder policy stated.", "score": 3},
    },
}

TESTS = {
    "cases": [
        {"name": "Missing product name", "input": "{{PRODUCT_NAME}} is still a placeholder. Build it anyway.",
         "expects": ["Stops and asks for the product name", "Does not invent a name"],
         "trap": "A prompt without the placeholder rule produces a confident fake brand."},
        {"name": "Temptation to invent proof", "input": "Add two customer testimonials.",
         "expects": ["Declines to invent testimonials", "Explains the exclusion it is following"],
         "trap": "A prompt without the no-invention criterion fabricates quotes."},
    ],
    "judge_rubric": "1. Every criterion named in the prompt was checked and reported.\n"
                    "2. No invented names, quotes or metrics appear.\n"
                    "3. One primary CTA above the fold.\n"
                    "4. Under 250 lines of markup.\n"
                    "5. Opens with no external requests.",
}


def classify(system: str, messages: list) -> str:
    s = system.lower()
    if "diagnostic stage" in s:
        return "diagnosis"
    if "verification stage" in s:
        return "critique"
    if "repair stage" in s:
        return "repair"
    if "acceptance tests" in s:
        return "tests"
    return "write"


# A deliberately damaged repair: no output contract, a contradictory pair of limits, and a
# shouted instruction. RepairGuard must discard this rather than ship it.
BAD_REPAIR = """# Make a page

## Objective
Make the landing page good.

## Context
It is for developers.

## Requirements
- Be thorough and make it GREAT.

## Output contract
Keep it under 200 words and at least 600 words.
"""


def payload_for(kind: str, attempt: int, mode: str = "") -> str:
    if kind == "diagnosis":
        # Wrapped in prose and a fence on purpose: the parser has to cope.
        return "Here is my analysis:\n```json\n" + json.dumps(DIAGNOSIS) + "\n```"
    if kind == "critique":
        if mode == "garbage":
            # Prose with a stray brace pair before the answer: not JSON, so the parser returns
            # nothing. The verifier has said nothing, which must leave the linter's own findings
            # as the only issues — an unparseable verdict is not an exemption from the gate.
            return 'I looked at it. {draft} seems close, but I cannot score it. {"verdict": "ship"'
        if mode == "polish":
            return json.dumps(CRITIQUE_POLISH)
        if mode == "fabricate":
            return json.dumps(CRITIQUE_FABRICATE)
        return json.dumps(CRITIQUE_REPAIR if attempt == 0 else CRITIQUE_SHIP)
    if kind == "repair":
        return BAD_REPAIR if mode == "revert" else STRONG_PROMPT
    if kind == "tests":
        return json.dumps(TESTS)
    if mode in ("polish", "fabricate"):
        return STRONG_PROMPT
    return WEAK_PROMPT if attempt == 0 else STRONG_PROMPT


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    attempts = {}
    failures = {}
    rejected = {}
    last_request = 0.0

    finished_run = False

    def reset_for_run(kind: str) -> None:
        """A new client run must start from attempt 0, or the fixture silently changes shape.

        The boundary is "a diagnosis arrives after a run that reached a write", not "a diagnosis
        arrives": the retry mode retries the diagnosis request itself, and resetting there served
        the scripted 503 forever. A long idle also resets, so a manual re-run against a server
        left standing behaves like a fresh one.
        """
        now = time.time()
        idle = now - Handler.last_request
        Handler.last_request = now
        if (kind == "diagnosis" and Handler.finished_run) or idle > 30.0:
            Handler.attempts.clear()
            Handler.failures.clear()
            Handler.finished_run = False

    def log_message(self, *a):  # keep the e2e output readable
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def route(self):
        parts = self.path.lstrip("/").split("/")
        mode = "normal"
        if parts and parts[0] in ("truncate", "retry", "nojson", "anthropic", "strict", "revert",
                                  "polish", "fabricate", "slow", "garbage"):
            mode = parts[0]
            parts = parts[1:]
        return mode, "/" + "/".join(parts)

    def do_GET(self):
        mode, path = self.route()
        if path.rstrip("/").endswith("/models"):
            self._json(200, {"data": [{"id": "mock"}]})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        mode, path = self.route()
        n = int(self.headers.get("Content-Length") or 0)
        req = json.loads(self.rfile.read(n) or b"{}")
        messages = req.get("messages", [])
        # The Anthropic format carries the system prompt as a top-level field, not a message.
        system = req.get("system") or next((m["content"] for m in messages if m.get("role") == "system"), "")
        kind = classify(system, messages)
        Handler.reset_for_run(kind)
        attempt = self.attempts.get((mode, kind), 0)

        # Inject one failure per stage, once, so the client's recovery paths run exactly once.
        # A rejected request must not consume the scripted answer: real gateways do not advance
        # their response on a 400, and pretending they do hides which call actually succeeded.
        seen = self.failures.get((mode, kind), 0)
        self.failures[(mode, kind)] = seen + 1
        if mode == "retry" and seen == 0:
            self._json(503, {"error": {"message": "upstream overloaded"}})
            return
        if mode == "nojson" and seen == 0 and "response_format" in req:
            self._json(400, {"error": {"message": "response_format is not supported by this gateway"}})
            return
        # A locked-down gateway: each optional parameter is rejected once, then accepted once dropped.
        if mode == "strict":
            if "stream_options" in req and not self.rejected.get("stream_options"):
                self.rejected["stream_options"] = True
                print("MOCK-400 stream_options", flush=True)
                self._json(400, {"error": {"message": "Unrecognized request argument supplied: stream_options"}})
                return
            if "reasoning_effort" in req and not self.rejected.get("reasoning_effort"):
                self.rejected["reasoning_effort"] = True
                print("MOCK-400 reasoning_effort", flush=True)
                self._json(400, {"error": {"message": "Unrecognized request argument supplied: reasoning_effort"}})
                return

        # A gateway that takes its time. The state machine's mid-stage behaviour — Stop during
        # "Checking it against the rubric…" — is only observable if the stage lasts long enough to
        # press it, and a loopback mock answers in under a millisecond.
        if mode == "slow":
            time.sleep(1.5)

        self.attempts[(mode, kind)] = attempt + 1
        if kind == "write":
            Handler.finished_run = True
        text = payload_for(kind, attempt, mode)
        if mode == "truncate" and kind == "write" and attempt == 0:
            text = text[:60]

        anthropic = mode == "anthropic" or path.rstrip("/").endswith("/messages")
        if anthropic:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b": ping\n\n")
            self.wfile.flush()
            step = 48
            for i in range(0, len(text), step):
                ev = {"type": "content_block_delta",
                      "delta": {"type": "text_delta", "text": text[i:i + step]}}
                self.wfile.write(("event: content_block_delta\ndata: " + json.dumps(ev) + "\n\n").encode())
                self.wfile.flush()
            stop = "max_tokens" if (mode == "truncate" and kind == "write" and attempt == 0) else "end_turn"
            # Anthropic reports input tokens on message_start, nested under "message", and output
            # tokens on message_delta. The client has to read both places.
            start = {"type": "message_start",
                     "message": {"usage": {"input_tokens": 1500, "output_tokens": 1,
                                           "cache_read_input_tokens": 400,
                                           "cache_creation_input_tokens": 100}}}
            self.wfile.write(("event: message_start\ndata: " + json.dumps(start) + "\n\n").encode())
            self.wfile.flush()
            done = {"type": "message_delta", "delta": {"stop_reason": stop},
                    "usage": {"output_tokens": 800}}
            self.wfile.write(("event: message_delta\ndata: " + json.dumps(done) + "\n\n").encode())
            self.wfile.flush()
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        # A comment line first, like a real gateway sending keep-alives.
        self.wfile.write(b": keep-alive\n\n")
        self.wfile.flush()

        step = 48
        for i in range(0, len(text), step):
            chunk = {"choices": [{"delta": {"content": text[i:i + step]}, "index": 0}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.flush()
            time.sleep(0.002)
        truncated = mode == "truncate" and kind == "write" and attempt == 0
        finish = {"choices": [{"delta": {}, "finish_reason": "length" if truncated else "stop", "index": 0}]}
        self.wfile.write(("data: " + json.dumps(finish) + "\n\n").encode())
        # A usage-only chunk with empty choices, as gateways send when include_usage is set.
        usage = {"choices": [],
                 "usage": {"prompt_tokens": 2100, "completion_tokens": 360,
                           "prompt_tokens_details": {"cached_tokens": 512}}}
        self.wfile.write(("data: " + json.dumps(usage) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"mock listening on http://127.0.0.1:{port}/v1", flush=True)
    server.serve_forever()
