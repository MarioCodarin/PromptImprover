# Prompt Improver

A small macOS menu bar app that turns a rough idea into a detailed, agent-ready prompt.

Write what you want in a few words. The app reads it, asks a few short questions if they're needed, and then writes a structured prompt for an AI agent or chat assistant. The output is a general-purpose prompt, not one tied to a codebase.

## Features

- **Menu bar only.** There is no Dock icon and no main window. Click the icon and a compact panel opens. When the result is ready, **Expand** grows the same panel so you can read, refine and copy the whole prompt.
- **Two stages.**
  1. *Diagnose:* the model checks your draft for goal, done criteria, context, inputs, constraints, deliverable and autonomy. It asks up to 4 questions, with tappable options, and only when the answer would change the prompt. Zero questions is normal.
  2. *Write:* the final prompt streams in, with sections such as Goal, Context, Requirements, Constraints & scope, Approach, Deliverable, Success criteria and Assumptions.
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
| Esc | Collapse the expanded view |
| ⌘, / ⌘Q | Settings / Quit (from the avatar menu) |

## Privacy & security

- **API keys** are stored only in the macOS Keychain, readable only while your Mac is unlocked and never synced to other devices. Keys are never written to preferences or logs, and they are hidden in error messages.
- A key is **sent only over HTTPS**. Plain `http` is allowed only for `localhost`, `127.0.0.1` or `::1`, for example Ollama. Changing an endpoint's host removes its stored key.
- Your **draft, answers and profile** go to the endpoint you selected. Your name is never sent; it's only used for the greeting in the panel.
- **Profile and ratings** are stored locally in UserDefaults. Ratings hold tags only, never prompt text.
- The app is ad-hoc signed, so macOS may ask once to allow Keychain access after each rebuild.

## How the prompt engineering works

The meta-prompts in `MetaPrompts.swift` follow current guidance from Anthropic, OpenAI and Google on prompting frontier models and agents:

- **State the goal and why it matters.** Models generalize better from a purpose than from bare rules.
- **Define "done"** with checkable success criteria.
- **Supply only the context the model can't infer.** Every line has to earn its place.
- **Write at the right level of detail.** Give principles with reasons instead of long, brittle rule lists.
- **Say what to do,** not only what to avoid.
- **Spell out scope and autonomy:** what the agent can decide alone, and when it must stop and ask.
- **Never invent facts.** Missing details become listed **Assumptions** or `{{PLACEHOLDERS}}`.
- **Avoid filler:** no empty personas, ALL-CAPS or threats.

## Project layout

```
Sources/PromptImprover/
├── PromptImproverApp.swift   MenuBarExtra + Settings scenes, menu bar template icon, --render-icon hook
├── ContentView.swift         PanelView: composer, questions, preview/expanded result, feedback
├── SettingsView.swift        General · Profile · Endpoints · Feedback tabs
├── ImproverViewModel.swift   Analyze → answer → write → refine flow, cancellation via run IDs
├── MetaPrompts.swift         Analyzer/writer meta-prompts, personalization, tolerant parsing
├── LLMClient.swift           OpenAI + Anthropic wire formats, SSE streaming, /models
├── Endpoints.swift           Endpoint model, presets, EndpointStore, Keychain wrapper
├── Profile.swift             UserProfile, feedback tags, learned preferences
├── LoginItem.swift           SMAppService open-at-login
└── Logo.swift                LogoMark (SwiftUI) + .icns renderer
build.sh                      SwiftPM build → .app bundle (LSUIElement, icon, ad-hoc codesign)
```

### Notes for contributors

- The project builds with **Command Line Tools only**. Their SDK lacks the SwiftUI macro plugin, so `@State` doesn't compile. Local view state uses small `ObservableObject` classes with `@StateObject` instead.
- A cancelled `AsyncThrowingStream` finishes **without throwing**. Every async task in the view model checks its `runID` before writing state, so a stopped run can never overwrite a newer one.
- There is an open design decision in `MetaPrompts.composeBrief`, marked `TODO(human)`: what the writer should do with questions the user left unanswered.
