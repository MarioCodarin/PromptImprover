# Prompt Improver

A small macOS menu bar app that turns a rough idea into a detailed, agent-ready prompt.

Write what you want in a few words. The app reads it, asks a few short questions if they're needed, and then writes a structured prompt for an AI agent or chat assistant. The output is a general-purpose prompt, not one tied to a codebase.

## Features

- **Menu bar only.** There is no Dock icon and no main window. Click the icon and a compact panel opens. When the result is ready, **Expand** grows the same panel so you can read, refine and copy the whole prompt.
- **Five stages, one gate.**
  1. *Diagnose* — scores the draft 0–4 on a fixed 12-axis rubric, lists defects by code (`D02` = no success criteria), and asks up to 4 questions — only when no defensible default exists. Zero questions is normal.
  2. *Write* — compiles the brief into an executable prompt, streaming as it goes.
  3. *Lint* — 19 deterministic structural checks for an agent task, 17 for a system prompt, 15 for a chat message, offline and free: missing sections, unmeasurable criteria, two output formats at once, two different length limits, chat preamble, code fences, shouted rules, unanswered questions with no assumptions recorded.
  4. *Verify* — an independent reviewer, given the same rubric the writer was given, quotes every defect it finds and scores the result. Anything blocker or major triggers a repair pass; a repair that scores worse structurally than the original is discarded. The repaired prompt is re-scored once, so the number you see describes the text you copy.
  5. *Tests* (Deep) — 3–5 acceptance cases, each one something a weak prompt fails, plus a checklist for judging the output.
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
| — | **Save** writes the prompt, plus the acceptance tests when there are any, to a `.md` file |
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

1. **The rubric is one object, rendered into every stage.** `Axis` (12 axes, each with a 0/2/4 anchor) is injected into the analyzer, the critic and the repair brief. The score in the UI and the instruction in the prompt cannot drift apart, because they are the same value.
2. **The model is never the only judge.** The linter is deterministic and catches the failures a model will happily wave through: a prompt with no success criteria, two contradictory length limits, a reply wrapped in a code fence. A prompt that fails the linter is marked as failing even when the critic says "ship".

## Project layout

```
Sources/PromptImprover/
├── PromptImproverApp.swift   MenuBarExtra + Settings scenes, menu bar icon, CLI hooks (--selftest, --lint, --e2e, --vm, --dump-prompts)
├── ContentView.swift         PanelView: composer, questions, preview/expanded result, feedback
├── QualityPanel.swift        Rubric/structure scores, critic issues, linter findings, acceptance tests
├── SettingsView.swift        General (depth) · Profile · Endpoints · Feedback tabs
├── ImproverViewModel.swift   Stage orchestration, questions, cancellation via run IDs, repair regression guard
├── PromptEngine.swift        The five stages as network calls: diagnose/write/verify/repair/tests/revise
├── Rubric.swift              The standard: 12 axes with 0/2/4 anchors, target weights, defect taxonomy
├── PipelineModel.swift       What flows between stages: Finding, Diagnosis, Critique, EvalSuite, Rigor
├── PromptTarget.swift        The three targets: skeleton, guidance, length aim, few-shot exemplar
├── PromptLinter.swift        Lint entry point, report, issue→axis mapping, shared text helpers
├── LinterChecks.swift        The 15 structural checks, one function each, over one LintContext
├── MetaPrompts.swift         Every meta-prompt and the brief composer
├── ResponseParsing.swift     Tolerant JSON extraction, reasoning-block stripping, fence removal
├── RepairGuard.swift         Whether a repair is kept: what changed, not what it scored
├── LLMClient.swift           Both wire formats, SSE streaming, retry with backoff, parameter fallback, truncation detection
├── Endpoints.swift           Endpoint model, presets, EndpointStore, Keychain wrapper
├── Profile.swift             UserProfile, feedback tags, learned preferences
├── SelfTest.swift            100 offline checks + --lint / --dump-prompts
├── E2E.swift                 Headless pipeline run with a stage trace (--e2e)
├── VMProbe.swift             Headless driver for the view model: restore, cancel, depth (--vm)
├── LoginItem.swift           SMAppService open-at-login
└── Logo.swift                LogoMark (SwiftUI) + .icns renderer
Tests/
├── mock_llm.py               Mock provider: SSE, both wire formats, five failure modes, deterministic per run
└── run_tests.sh              The whole gate: self-tests + every pipeline path
build.sh                      SwiftPM build → self-test → .app bundle (LSUIElement, icon, ad-hoc codesign)
```

## Verifying it

```sh
./Tests/run_tests.sh      # 100 offline checks + 16 end-to-end runs against a mock provider
./build.sh                # runs the self-test before bundling; a regression in the prompts fails the build
```

Three commands for working on the prompts themselves:

```sh
.build/release/PromptImprover --dump-prompts            # every system prompt, with token estimates
.build/release/PromptImprover --lint my-prompt.md --target "Chat message"
.build/release/PromptImprover --e2e https://api.example.com/v1 \
    --key "$KEY" --model glm-5.3-abliterated --rigor Deep --out prompt.md \
    --price-in 1 --price-out 2
```

`--lint` takes `--target` because the required sections differ per target: a chat message is prose and has no headings, so it is matched against the body rather than at headings. It takes `--unanswered N` for the same reason the app passes it. A section counts as present when it appears as a heading, as a labelled line (`Purpose: …`), or — for a chat message — anywhere in the body; and a section may be explicitly declined (`Context: none; the task is self-contained`), because the writer is told to drop sections that would be empty and the gate has to agree with that instruction.

`--e2e` takes `--answer-questions` to fill each clarifying question with its recorded default. Without it the harness can only simulate a user who skipped every question, which makes `silent-defaults` fire where the app would be clean. `--effort` sets a reasoning effort so the 400 fallback for that parameter is reachable.

`--vm` covers the half `--e2e` cannot reach. It drives the real `ImproverViewModel` — the same object the window binds to — and asserts the invariants that only exist in the state machine: a refine that dies restores the prompt it replaced instead of destroying it, a cancel mid-write ships no fragment, and a depth change mid-run does not reshape a pipeline already in flight. Those three were all broken at once, and a fully green `--e2e` suite could not see any of them.

`--e2e` drives the same `PromptEngine` the app drives, so it is a real run, not a simulation: stage trace, call count, structure score, rubric score, tokens, and the finished prompt. `--price-in` / `--price-out` are dollars per million tokens, taken from the provider's `/models` response, and make it print the run's actual cost. With `--out`, the acceptance tests are written beside the prompt as `prompt.tests.md` — never appended to it, because a prompt with a test suite stapled on cannot be pasted into a system slot. Point it at the mock to check plumbing without spending tokens:

```sh
python3 Tests/mock_llm.py 8765 &
.build/debug/PromptImprover --e2e http://127.0.0.1:8765/v1 --key k --model mock --rigor Deep
.build/debug/PromptImprover --vm  http://127.0.0.1:8765/v1 --key k --model mock --rigor Fast
```

The mock is hostile on purpose: it wraps its JSON in prose and fences, answers the first write with a prompt that is missing its success criteria, and reports a blocker so the repair loop runs. Its path prefix selects a failure mode — `/truncate/`, `/retry/`, `/nojson/`, `/anthropic/`, `/strict/` — which is how the truncation, backoff, parameter-fallback, Messages-SSE and locked-down-gateway paths are covered. `/strict/` rejects `stream_options` and `reasoning_effort` the way a proxy with a parameter allowlist does; both must degrade rather than fail the run. `/polish/` and `/fabricate/` hold the two halves of the repair trigger apart: the first objects only to minors on a prompt that passes and must cost no call, the second objects to a fabricated figure on the same prompt and must repair.

### Notes for contributors

- The project builds with **Command Line Tools only**. Their SDK lacks the SwiftUI macro plugin, so `@State` doesn't compile. Local view state uses small `ObservableObject` classes with `@StateObject` instead.
- A cancelled `AsyncThrowingStream` finishes **without throwing**. Every async task in the view model checks its `runID` before writing state, so a stopped run can never overwrite a newer one.
- `ImproverViewModel` owns interaction; `PromptEngine` owns model calls. Keep it that way: anything that touches the network belongs in the engine, or `--e2e` stops covering it.
- The linter only contains checks where a string test is *sound*. Semantic contradictions are left to the critic on purpose — a word-overlap heuristic flags "always run the tests" against "never commit without running tests" and calls agreement a conflict.
- `Rigor.fast` skips the diagnosis stage entirely. `askQuestions` never skips it: the toggle controls whether the run *stops* for answers, not whether stage 1 happens, because the analyzer's output is the writer's defect list, task type and risk.
- A repair is judged on **what changed**, not on the weighted score. Only blockers and majors can veto a repair; minors never do, because the critic re-scores the shipped text anyway. `RepairGuard` is the single home for that policy, and both the app and `--e2e` call it — they had drifted apart when the policy lived in two places.
- **The rubric number is not a regression signal.** Four runs on one target with one draft and one model scored the final text 90, 80, 84 and 73 — a 17-point spread from the critic's own variance. A repair that drops 18 points is one sample from that distribution, which is why the guard judges on the issue list and not on the score. Do not add a score threshold; it will fire on noise.
- A prompt the gate already passes is only sent to repair when the critic found something *unusable*. Polish has nothing to aim at, so the model rewrites for the sake of rewriting: a live run took a 100/100 prompt and returned 97/100, accepted because minors never veto. A critic blocker or major still repairs a clean prompt — that is the fabrication the linter cannot see, and skipping it would ship the one failure this tool exists to prevent. Two mock modes pin the pair in opposite directions: `/polish/` must spend no call, `/fabricate/` must repair.
- The linter's issue→axis table is keyed on the ids the checks actually emit. It has been wrong twice (once on a registry label, once on single-word section names while the sections are `"output contract"` and `"success criteria"`), and both times every section blocker reported `consistency`, so a repair was sent looking for a contradiction. A self-test builds the id list from `requiredSections` so renaming a section cannot unmoor its axis.
- When you change a prompt, run `--dump-prompts` before and after and read the diff. Prompt edits are code changes; they get reviewed like code changes.
