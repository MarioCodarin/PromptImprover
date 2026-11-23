# Prompt Improver

A small macOS menu bar app that turns a rough idea into a detailed, agent-ready prompt.

Write what you want in a few words. The app reads it, asks a few short questions if they're needed, and then writes a structured prompt for an AI agent or chat assistant. The output is a general-purpose prompt, not one tied to a codebase.

## Features

- **Menu bar only.** There is no Dock icon and no main window. Click the icon and a compact panel opens. When the result is ready, **Expand** grows the same panel so you can read, refine and copy the whole prompt.
- **Six stages, one gate.**
  1. *Diagnose* — scores the draft 0–4 on a fixed rubric (12 axes; 11 for a chat message, which drops autonomy), lists defects by code (`D02` = no success criteria), and asks up to 4 questions — only when no defensible default exists. Zero questions is normal.
  2. *Write* — compiles the brief into an executable prompt, streaming as it goes.
  3. *Lint* — 19 deterministic structural checks for an agent task, 17 for a system prompt, 15 for a chat message, offline and free: missing sections, unmeasurable criteria, two output formats at once, two different length limits, chat preamble, code fences, shouted rules, unanswered questions with no assumptions recorded.
  4. *Verify* — an independent reviewer quotes every defect it finds and scores the result against the full 0/2/4 anchor set. (The writer is given the same twelve axes as prose principles without the numbers — it should write for the task, not for the rubric.) Anything blocker or major triggers a repair pass.
  5. *Repair* — rewrites only the lines the issues implicate, then the result is judged on **what changed**, not on its score: a repair that introduces a blocker, or that leaves more majors than it fixed, is discarded and the original kept — and a repair that closes a real defect while losing a few points of a noisy aggregate is kept. The repaired prompt is re-scored once, so the number you see describes the text you copy.
  6. *Tests* (Deep) — 3–5 acceptance cases, each one something a weak prompt fails, plus a checklist for judging the output.
- **Three depths.** Fast = one call, write only. Standard = diagnose, write, lint, verify, repair, re-score. Deep = adds acceptance tests. The lint gate runs in every mode.
- **Three targets.**
  - **Agent task:** for Claude Code, Codex, OpenCode and similar tools. Adds autonomy rules, persistence, a verification step and a final report.
  - **System prompt:** a reusable system prompt.
  - **Chat message:** a compact single message.
- **Refine.** Ask for changes such as "shorter", "add a table" or "for Claude Code" without starting over.
- **Any endpoint.** Works with APIs in the OpenAI format (`/chat/completions`) or the Anthropic format (`/messages`).
  - **Refuseless** is set up by default.
  - Presets: OpenAI, Anthropic, OpenRouter, Ollama, or any custom URL.
  - The model list is fetched from `GET /models`.
  - Optional `reasoning_effort` setting.
- **Personalization (Settings → Profile).** Role, expertise, tone, detail level, prompt language, usual agent, and "always include" rules. The analyzer skips questions your profile already answers. "What the model sees" shows exactly what is sent.
- **Feedback (Settings → Feedback).** Rate each prompt 👍/👎 with quick tags. A tag that appears at least twice in your last 30 ratings becomes a *learned preference* that shapes future prompts. You can turn this off.
- **Open at login.** Uses `SMAppService`. It turns on the first time the app runs, and you can switch it off in Settings → General.

## Install

Requires macOS 14+ and a Swift toolchain. The Command Line Tools are enough; Xcode is not needed.

```sh
./build.sh            # builds ./PromptImprover.app (renders the app icon from the SwiftUI logo)
./build.sh --install  # also copies it to /Applications and launches it (recommended for open-at-login)
```

Then:

1. Click the `>_✦` icon in the menu bar → avatar menu → **Settings…** (⌘,).
2. In **Endpoints**, paste your API key. Refuseless keys start with `abl_`.
3. Press **Test & fetch models**.
4. Optional: fill in **Profile**.
5. Type an idea in the panel and press **⌘↩**.

| Shortcut | Action |
|---|---|
| ⌘↩ | Improve (or **Write prompt** while answering questions) |
| ⇧⌘C | Copy the prompt |
| — | **Save** writes the prompt to the file you pick, and the acceptance tests beside it as `prompt.tests.md` |
| Esc | Collapse the expanded view |
| ⌘, / ⌘Q | Settings / Quit (from the avatar menu) |

## Privacy & security

- **API keys** are stored only in the macOS Keychain, readable only while your Mac is unlocked and never synced to other devices. Keys are never written to preferences or logs, and they are hidden in error messages.
- A key is **sent only over HTTPS**. Plain `http` is allowed only for `localhost`, `127.0.0.1` or `::1`, for example Ollama. Changing an endpoint's host removes its stored key.
- Your **draft, answers and profile** go to the endpoint you selected. Your name is never sent; it's only used for the greeting in the panel.
- **Profile and ratings** are stored locally in UserDefaults. Ratings hold tags only, never prompt text.
- The app is ad-hoc signed, so macOS may ask once to allow Keychain access after each rebuild.

## How the prompt engineering works

The meta-prompts in `MetaPrompts.swift` are built from current published guidance, not vibes. Every principle below is traceable to one of these:

- Anthropic, *Prompting best practices* — [platform.anthropic.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices](https://platform.anthropic.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)
- Anthropic, *Metaprompt* (few-shot-by-construction: a metaprompt full of worked examples beats a metaprompt full of rules) — [github.com/anthropics/claude-cookbooks/blob/main/misc/metaprompt.ipynb](https://github.com/anthropics/claude-cookbooks/blob/main/misc/metaprompt.ipynb)
- Anthropic, *Effective context engineering for AI agents* — [anthropic.com/engineering/effective-context-engineering-for-ai-agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- OpenAI, *GPT-5 prompting guide* (contradictory instructions cost reasoning tokens; metaprompting with minimal edits) — [developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide)
- Google, *Prompt design strategies* — [ai.google.dev/gemini-api/docs/prompting-strategies](https://ai.google.dev/gemini-api/docs/prompting-strategies)

What the writer is actually told, and why. The principles are cut one-to-one onto the twelve rubric axes, so the instruction and the score are the same object:

| Axis | The rule | Source |
|---|---|---|
| Goal | State the outcome and why it matters, not just the activity | models generalise from a purpose better than from a rule list |
| Context | Only what the model cannot infer; long material in tags, before the instructions | Anthropic, *Long context prompting* |
| Inputs | Name what exists and what is missing; never assume a file or a repository | Gemini, *Prompt design strategies* |
| Deliverable | Fix format, structure, length as a number, language, and one exclusion | rubric axis `deliverable` |
| Criteria | Checkable by someone who did not do the work; each names a method the executor has | rubric axis `criteria` |
| Constraints | Say what is out of scope; prohibitions need a replacement behaviour | Anthropic, best practices |
| Procedure | Order the work, and give each phase a stopping condition | Anthropic, *Effective context engineering* |
| Autonomy | Act by default; name the action classes needing confirmation, each with a reason | Anthropic, *Balancing autonomy and safety* |
| Verification | Say how to prove each criterion and what evidence to show | Anthropic, agentic systems |
| Consistency | **Contradictions are the worst defect** — check every rule pair, resolve with an explicit priority | GPT-5 guide: contradictory prompts burn reasoning on reconciliation |
| Economy | Every line earns its place; no personas, no ALL-CAPS, no threats, no restating the request | measured to hurt on current models |
| Robustness | Name the failure policy: missing input, ambiguity, partial success, out of scope | GPT-5 guide; Anthropic, context engineering |

Three rules sit outside the axes because they apply to every prompt:

- **Separate facts from design decisions.** Never assert a fact you were not given — prices, names, URLs, dates, counts, citations. Limits you impose on the work (word counts, timeouts, line budgets) are yours to choose: state the number and record it under Assumptions. This distinction is the one the tool exists to enforce, and the first version of the rule failed because it forbade both.
- **Research when the task needs facts you cannot know.** Prefer primary sources, a source and a retrieval date per claim, confirmed separated from inferred.
- **One canonical example beats ten edge cases**, and only when a format is hard to describe in words.

Each target gets its own worked example, in its own shape. One exemplar served all three before, and its shape was the agent-task skeleton — so a system prompt and a chat message were shown sections they are told to drop.

Two structural choices matter more than any single rule:

1. **The rubric is one object, rendered per consumer.** `Axis` (12 axes, 11 for a chat message, each with a 0/2/4 anchor) is the single source, and each stage is handed only the slice it needs: the **critic** gets the full anchor set, because it has to place a score; the **analyzer** gets just the `generic (2)` boundary per axis, because all it decides is 2-or-worse versus 3; the **writer** gets the same twelve axes as prose principles with no numbers, because a writer aiming at "4 on economy" writes for the rubric instead of for the task; and the **repair brief** gets only the named axis per issue. One object, four renderings, so a change to an anchor reaches every stage that should see it and none that shouldn't.
2. **The model is never the only judge.** The linter is deterministic and catches the failures a model will happily wave through: a prompt with no success criteria, two contradictory length limits, a reply wrapped in a code fence. A prompt that fails the linter is marked as failing even when the critic says "ship".

A linter is only worth having if it is believed, so the governing rule is that **a false positive is worse than a miss**. A wrong verdict costs a repair call and teaches the operator to ignore the panel. Every check is therefore written to fire on the defect and nothing near it: a section counts whether it is a `#` heading, a bold line, a `- Label:` bullet or plain chat prose; a quoted phrase is the prompt *talking about* language rather than using it; `STRIPE_SECRET_KEY` is an identifier, not shouting.

The risk in that direction is the opposite one — a check narrowed until it never fires — so each narrowing is paired with an attack fixture in `SelfTest.swift` that it must still catch: two word budgets on the same artefact, `nonetheless` read as a decline, a bold sub-title that would empty a section, a delivered reply wearing a title.

## Project layout

```
Sources/PromptImprover/
├── PromptImproverApp.swift   MenuBarExtra + Settings scenes, menu bar icon, CLI hooks (--selftest, --lint, --e2e, --vm, --dump-prompts)
├── ContentView.swift         PanelView: composer, questions, preview/expanded result, feedback
├── QualityPanel.swift        Rubric/structure scores, critic issues, linter findings, acceptance tests
├── SettingsView.swift        General (depth) · Profile · Endpoints · Feedback tabs
├── ImproverViewModel.swift   Stage orchestration, questions, cancellation via run IDs, repair regression guard
├── PromptEngine.swift        The five stages as network calls — diagnose/write/verify/repair/tests — plus revise for Refine
├── Rubric.swift              The standard: 12 axes with 0/2/4 anchors, target weights, defect taxonomy
├── PipelineModel.swift       What flows between stages: Finding, Diagnosis, Critique, EvalSuite, Rigor
├── PromptTarget.swift        The three targets: skeleton, guidance, length aim, few-shot exemplar
├── PromptLinter.swift        Lint entry point, report, issue→axis mapping, shared text helpers
├── LinterChecks.swift        The structural checks, one function each, over one LintContext (19 / 17 / 15 per target)
├── MetaPrompts.swift         Every meta-prompt and the brief composer
├── ResponseParsing.swift     Tolerant JSON extraction, reasoning-block stripping, fence removal
├── RepairGuard.swift         Whether a repair is kept: what changed, not what it scored
├── LLMClient.swift           Both wire formats, SSE streaming, retry with backoff, parameter fallback, truncation detection
├── Endpoints.swift           Endpoint model, presets, EndpointStore, Keychain wrapper
├── Profile.swift             UserProfile, feedback tags, learned preferences
├── SelfTest.swift            191 offline checks + --lint / --dump-prompts
├── E2E.swift                 Headless pipeline run with a stage trace (--e2e)
├── VMProbe.swift             Headless driver for the view model: restore, cancel mid-verify, depth (--vm)
├── LoginItem.swift           SMAppService open-at-login
└── Logo.swift                LogoMark (SwiftUI) + .icns renderer
Tests/
├── mock_llm.py               Mock provider: SSE, both wire formats, ten failure modes, deterministic per run
└── run_tests.sh              The whole gate: self-tests + every pipeline path
build.sh                      SwiftPM build → self-test → .app bundle (LSUIElement, icon, ad-hoc codesign)
```

## Verifying it

```sh
./Tests/run_tests.sh      # 191 offline checks, then 28 pipeline runs against a mock provider
./build.sh                # runs the self-test before bundling; a regression in the prompts fails the build
```

Three commands for working on the prompts themselves:

```sh
.build/release/PromptImprover --dump-prompts > before.txt   # all 14 system prompts, in full
.build/release/PromptImprover --lint my-prompt.md --target "Chat message"
.build/release/PromptImprover --e2e https://api.example.com/v1 \
    --key "$KEY" --model glm-5.3-abliterated --rigor Deep --out prompt.md \
    --price-in 1 --price-out 2
```

Every flag, so nothing has to be found by reading `main`:

| Flag | On | Meaning |
|---|---|---|
| `--selftest` | — | run the 191 offline checks, exit non-zero on any failure |
| `--dump-prompts` | — | print all 14 system prompts in full with a token estimate, so a prompt edit can be read as a diff |
| `--lint <file>` | — | lint one file, print score and issues, exit 1 if not clean |
| `--target "…"` | lint, e2e | `Agent task` · `System prompt` · `Chat message`; sets which sections are required |
| `--unanswered N` | lint | how many questions the draft left open, so `silent-defaults` can judge it |
| `--e2e <baseURL>` | — | one real pipeline run with a stage trace |
| `--key` `--model` | e2e, vm | credentials and model for that run |
| `--format openai\|anthropic` | e2e | force the wire format instead of taking it from the endpoint; any other value is rejected |
| `--draft "…"` | e2e | the starting draft; without it a fixed sample draft is used |
| `--answer-questions` | e2e | fill each clarifying question with its recorded default |
| `--effort <value>` | e2e | reasoning effort (`low` `medium` `high` `none` `minimal` `xhigh`); a typo is rejected, since the value goes straight onto the wire |
| `--out <file>` | e2e | write the prompt, and `<name>.tests.md` beside it |
| `--price-in` `--price-out` | e2e | dollars per million tokens, to print the run's cost |
| `--json` | e2e | *also* write a JSON summary — `<out>.json`, or `e2e-result.json` in the current directory. The trace still prints |
| `--rigor Fast\|Standard\|Deep` | e2e, vm | depth; case-insensitive, and a typo is rejected rather than downgraded |
| `--vm <baseURL>` | — | drive the real view model through its state-machine invariants |
| `--render-icon <path>` | — | write the app icon `.icns` (used by `build.sh`) |

`--lint` takes `--target` because the required sections differ per target: a chat message is prose and has no headings, so it is matched against the body rather than at headings. It takes `--unanswered N` for the same reason the app passes it. A section counts as present when it appears as a heading, as a labelled line (`Purpose: …`), as a bulleted label (`- Objective: …`), or — for a chat message — anywhere in the body; and a section may be explicitly declined (`Context: none; the task is self-contained`), because the writer is told to drop sections that would be empty and the gate has to agree with that instruction.

`--e2e` takes `--answer-questions` to fill each clarifying question with its recorded default. Without it the harness can only simulate a user who skipped every question, which makes `silent-defaults` fire where the app would be clean. `--effort` sets a reasoning effort so the 400 fallback for that parameter is reachable.

`--vm` covers the half `--e2e` cannot reach. It drives the real `ImproverViewModel` — the same object the window binds to — and asserts the sixteen invariants that only exist in the state machine. The load-bearing ones: a refine that dies restores the prompt it replaced instead of destroying it; a cancel mid-write ships no fragment; a cancel mid-verify keeps the finished text, its structure score and a copyable result, and still reports the tokens it spent; a cancel inside the *re-check after a repair* drops the pre-repair verdict rather than leaving the panel claiming a score and an outcome that no longer describe what is on screen; and a depth change mid-run does not reshape a pipeline already in flight. Every one of those was broken at some point, and a fully green `--e2e` suite could not see any of them.

`--e2e` drives the same `PromptEngine` the app drives, so it is a real run, not a simulation: stage trace, call count, structure score, rubric score, tokens, and the finished prompt. `--price-in` / `--price-out` are dollars per million tokens and make it print the run's actual cost. They are the only source of that number — the provider's `/models` response carries model ids, not prices — so a run without them reports `cost_usd: null` rather than inventing a figure. With `--out`, the acceptance tests are written beside the prompt as `<name>.tests.md` — never appended to it, because a prompt with a test suite stapled on cannot be pasted into a system slot. Point it at the mock to check plumbing without spending tokens:

```sh
python3 Tests/mock_llm.py 8765 &
.build/debug/PromptImprover --e2e http://127.0.0.1:8765/v1 --key k --model mock --rigor Deep
.build/debug/PromptImprover --vm  http://127.0.0.1:8765/v1 --key k --model mock --rigor Fast
```

The mock is hostile on purpose: it wraps its JSON in prose and fences, answers the first write with a prompt that is missing its success criteria, and reports a blocker so the repair loop runs. Its path prefix selects one of ten failure modes:

| Mode | What it reproduces |
|---|---|
| `/truncate/` | the writer's reply is cut off, so the run must fail loudly rather than ship half a prompt — and must still count the tokens it spent |
| `/retry/` | a 503 on the first attempt, which must be retried rather than surfaced |
| `/nojson/` | a gateway that rejects `response_format` with 400; the client must retry without JSON mode and still parse the answer |
| `/garbage/` | a critique whose verdict cannot be parsed, so an unreadable answer never switches the gate off |
| `/anthropic/` | the Messages wire format, including a usage block whose input tokens exclude cache reads |
| `/strict/` | a gateway with a parameter allowlist that rejects `stream_options` and `reasoning_effort`; both must degrade rather than fail the run |
| `/revert/` | a repair that makes the prompt worse, which `RepairGuard` must discard while keeping the original |
| `/polish/` | minors only, on a prompt that already passes: must cost no repair call |
| `/fabricate/` | a fabricated figure on the same prompt: must repair |
| `/slow/` | a delayed answer, so a stage is long enough to be cancelled mid-flight |

The last two pairs are the interesting ones: `/polish/` and `/fabricate/` hold the two halves of the repair *trigger* apart, and `/revert/` covers the other side of the same policy — what to do once a repair has run.

### Notes for contributors

- The project builds with **Command Line Tools only**. Their SDK lacks the SwiftUI macro plugin, so `@State` doesn't compile. Local view state uses small `ObservableObject` classes with `@StateObject` instead.
- A cancelled `AsyncThrowingStream` finishes **without throwing**. Every pipeline task in the view model captures `runID` before it starts and re-checks it before writing state, so a stopped run can never overwrite a newer one. UI-only tasks are deliberately exempt — the 1.5 s "Copied" reset guards nothing a run owns, and guarding it on `runID` made the badge stick forever.
- `ImproverViewModel` owns interaction; `PromptEngine` owns model calls. Keep it that way: anything that touches the network belongs in the engine, or `--e2e` stops covering it.
- The linter only contains checks where a string test is *sound*. Semantic contradictions are left to the critic on purpose — a word-overlap heuristic flags "always run the tests" against "never commit without running tests" and calls agreement a conflict.
- `Rigor.fast` skips the diagnosis stage entirely. `askQuestions` never skips it: the toggle controls whether the run *stops* for answers, not whether stage 1 happens, because the analyzer's output is the writer's defect list, task type and risk.
- A repair is judged on **what changed**, not on the weighted score. Only blockers and majors can veto a repair; minors never do, because the critic re-scores the shipped text anyway. `RepairGuard` is the single home for that policy, and both the app and `--e2e` call it — they had drifted apart when the policy lived in two places.
- **The rubric number is not a regression signal.** Four runs on one target with one draft and one model scored the final text 90, 80, 84 and 73 — a 17-point spread from the critic's own variance. A repair that drops 18 points is one sample from that distribution, which is why the guard judges on the issue list and not on the score. Do not add a score threshold; it will fire on noise. The spread lives in `RubricNoise.measuredSpread`, and anything that compares two scores — the harness's repair trace today — goes through `RubricNoise.delta`, which reports a gap inside the spread as no change rather than as a small win or a small regression. The panel shows the number without inviting the comparison, and names the axes the critic actually marked down, because twelve per-axis marks survive that noise far better than their weighted mean.
- A prompt the gate already passes is only sent to repair when the critic found something *unusable*. Polish has nothing to aim at, so the model rewrites for the sake of rewriting: a live run took a 100/100 prompt and returned 97/100, accepted because minors never veto. A critic blocker or major still repairs a clean prompt — that is the fabrication the linter cannot see, and skipping it would ship the one failure this tool exists to prevent. Two mock modes pin the pair in opposite directions: `/polish/` must spend no call, `/fabricate/` must repair.
- The linter's issue→axis table is keyed on the ids the checks actually emit. It has been wrong twice (once on a registry label, once on single-word section names while the sections are `"output contract"` and `"success criteria"`), and both times every section blocker reported `consistency`, so a repair was sent looking for a contradiction. A self-test builds the id list from `requiredSections` so renaming a section cannot unmoor its axis.
- When you change a prompt, run `--dump-prompts` before and after and read the diff. Prompt edits are code changes; they get reviewed like code changes.
- **Never return the first parseable object.** Models open with an example of the schema before the content, and an example is legal JSON. Taking the first parse meant `parseDiagnosis` read `{"brief": "", "findings": []}` and returned an empty diagnosis with risk "low", and `parseCritique` read `{"verdict": "ship", "issues": []}` and reported a pass on a prompt the critic never scored. `jsonObject` now parses every span and takes a `rank` closure, so the caller decides which object is the answer. The related trap: don't filter spans that "look empty" — a genuine `{"verdict": "ship", "issues": []}` looks empty too.
- **A check that keys on a phrase must also read the negation.** `silent-defaults` looked for "assume" to prove a decision was recorded, and "never assume a brand name" satisfied it — the gap-handling instruction the same list exists to exclude, written with the verb the list keys on.
- **Scope a declaration to its artefact, and scope it the same way everywhere.** A word bound belongs to the artefact named nearest before it, and so does a format: "the summary at least 300 words; the appendix at most 200" is two budgets, not a conflict, and "the summary as JSON, and the appendix as Markdown" is two contracts, not two formats at once. `limits` and `formats` share one helper so they cannot drift apart about what "the same deliverable" means.
- **An exemption has to be as precise as the thing it exempts.** `executed` exempts a message that *asks* for something, because a prompt may quote the handover phrase it forbids. Adding the bare verb `write` to that list exempted every delivered reply that closed with "write back if you need anything" — so the verb is listed with its objects (`write a`, `write the`, …). A closing pleasantry is not a directive.
