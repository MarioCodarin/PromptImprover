# Prompt Improver

A minimal macOS menu bar app that turns a rough idea into a detailed, agent-ready prompt.

- **Two stages:** a diagnosis step asks up to 4 clarifying questions (or none), then a writer step streams the final prompt. The writer follows current prompting guidance: goal plus reason, done criteria, scope and autonomy, verification, and a final report.
- **Any endpoint:** OpenAI- or Anthropic-format APIs, with Refuseless set up by default. API keys are stored in the macOS Keychain.
- **Personal:** a profile (role, tone, detail level, language, usual agent, standing rules) and 👍/👎 feedback that turns into learned preferences.
- Runs in the menu bar only (no Dock icon), with an optional launch at login.

## Build

Requires macOS 14+ and the Swift toolchain (Command Line Tools are enough, Xcode not required).

```sh
./build.sh            # builds PromptImprover.app here
./build.sh --install  # also copies it to /Applications and launches it
```

Click the menu bar icon, open **Settings → Endpoints**, paste your key, and press **Save & Test**.
