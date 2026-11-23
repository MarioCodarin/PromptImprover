import Foundation

enum PromptTarget: String, CaseIterable, Identifiable {
    case agentTask = "Agent task"
    case systemPrompt = "System prompt"
    case chat = "Chat message"
    var id: String { rawValue }

    /// What the writer must know about the medium it is writing for.
    var guidance: String {
        switch self {
        case .agentTask:
            return """
            TARGET: an autonomous agent in a harness with tools (Claude Code, Codex, OpenCode, a custom loop).
            Address it in second person. It will run unattended, so it needs:
            - Autonomy: act by default. Name the action classes that need confirmation first — destructive, \
            irreversible, visible to others, costly — and say why, instead of a blanket "ask if unsure".
            - Persistence: finish the work, not the plan. If the task is large, decompose it and confirm each \
            sub-request is complete before yielding.
            - Escalation: when a requirement conflicts with what it finds on the ground, report the conflict \
            and the reading it chose. Obstacles never justify destructive shortcuts.
            - Verification: a named check per success criterion, and the evidence to show for it.
            - Final report: what changed, how it was verified, what is still open, which assumptions it made.
            """
        case .systemPrompt:
            return """
            TARGET: a reusable system prompt that governs every future conversation, not one request.
            It needs: purpose and audience; how it works (priorities, decision rules); what it must never do \
            and why; tone and default formatting; how it handles ambiguity, out-of-scope asks and conflicts \
            between its own rules. Prefer durable principles over rules tied to one scenario. If two rules \
            could ever conflict, say which wins.
            """
        case .chat:
            return """
            TARGET: one message pasted into a chat assistant. Compact prose or light structure — headings are \
            optional, not required. It needs: the goal, only the context the model cannot infer, what the \
            output must look like, and what "good" means. No autonomy, escalation, persistence or reporting \
            sections: a chat turn is not an agent run. Aim for under 400 words.
            """
        }
    }

    /// The length envelope the structural check enforces, stated to the writer so it can aim.
    var lengthTarget: String {
        switch self {
        case .agentTask: return "400 to 900 words (hard ceiling 1400)"
        case .systemPrompt: return "350 to 800 words (hard ceiling 1100)"
        case .chat: return "60 to 300 words (hard ceiling 500)"
        }
    }

    /// A worked example in this target's own shape.
    ///
    /// One exemplar served all three targets before, and its shape was the agent-task skeleton —
    /// so a system prompt and a chat message were shown sections they are told to drop, and the
    /// agent one failed the rubric it was modelling (no stopping condition per phase, no action
    /// classes with reasons). Each example below scores 4 on the axes it demonstrates.
    var exemplar: String {
        switch self {
        case .agentTask:
            return """
            The example shows the shape, not the content. Never reuse its subject, numbers or wording.

            # Add a retry budget to the outbound webhook sender

            ## Objective
            Stop the sender retrying a dead endpoint forever. Two incidents this quarter came from a worker \
            pinned on a 404 for six hours: the queue backed up and every other tenant stalled behind it.

            ## Inputs
            - `internal/webhook/sender.go` — the retry loop.
            - `docs/webhooks.md` — the delivery contract we promised clients.

            ## Requirements
            - Cap retries at 5 attempts, backoff 2s to 60s, jittered by 20%.
            - Treat 4xx except 429 as permanent: one attempt, no retry.
            - Emit a counter per outcome so queue depth is observable.

            ## Constraints and non-goals
            - No change to the public `Send` signature. Out of scope: the consumer side.
            - Budget: one pull request, under 300 changed lines.

            ## Approach
            1. Read the sender and the contract. Stop once you can name every retry branch.
            2. Put the budget behind the existing loop. Stop when all three cases above are handled.
            3. Add table tests for permanent, transient and exhausted. Stop when all three fail against \
            the old code.

            ## Output contract
            One pull request. Description naming the files, the tests and the rollback step. English, \
            under 250 words.

            ## Success criteria
            - `go test ./internal/webhook/...` returns 0.
            - A 404 makes exactly one attempt and a 500 makes five; a test proves both.
            - The `Send` signature is unchanged in the diff.

            ## Verification
            Run the package tests and paste the summary line. Then re-read the diff against each \
            criterion above, one at a time.

            ## Priorities when instructions conflict
            The delivery contract outranks the current code. If they disagree, follow the contract and \
            say which reading you chose.

            ## Autonomy and escalation
            Proceed without asking. Confirm first before changing the public `Send` signature, deleting \
            an existing test, or touching a second package: the first is visible to every caller, the \
            others are irreversible in review. Obstacles never justify disabling a test.

            ## Assumptions
            - "Dead endpoint" means the host resolves but returns 4xx. DNS failure is out of scope.
            """
        case .systemPrompt:
            return """
            The example shows the shape, not the content. Never reuse its subject or wording.

            You are the support triage assistant for a B2B billing product.

            ## Purpose
            Classify each inbound ticket and draft the first reply, so a human reviews instead of \
            starting from nothing. The readers are finance staff, not engineers, and they are already \
            frustrated by the time they write.

            ## How you work
            Read the ticket and any linked invoice before writing. Classify into one of: billing-error, \
            access, refund-request, other. Then draft one reply covering what happened, what you did, and \
            what happens next.

            ## Priorities when instructions conflict
            Never state a refund amount you cannot see on an invoice. If the ticket asks for one and no \
            invoice is linked, classify as billing-error and ask for the invoice number instead.

            ## Output contract
            Two fields: `category`, one of the four above; `reply`, plain prose under 120 words with no \
            greeting formula and no sign-off.

            ## Boundaries
            Never state a policy that is not in the linked documentation. Never close a ticket. If a \
            ticket is abusive, answer it once, factually, and flag it for a human.

            ## Assumptions
            - Ticket text is the only signal; there is no call recording or chat history to consult.
            """
        case .chat:
            return """
            The example shows the shape, not the content. Never reuse its subject or wording.

            Summarise the incident report below in one paragraph, then list the three decisions it leaves \
            open. Plain prose, under 150 words, no preamble. Quote the report for every claim you make; \
            if it does not state a cause, write that the cause is unstated rather than inferring one.
            """
        }
    }

    /// Section skeleton the writer is told to adapt. Empty sections get dropped, not filled.
    var skeleton: String {
        switch self {
        case .agentTask:
            return """
            ## Objective
            ## Context
            ## Inputs
            ## Requirements
            ## Constraints and non-goals
            ## Approach
            ## Output contract
            ## Success criteria
            ## Verification
            ## Priorities when instructions conflict
            ## Autonomy and escalation
            ## Assumptions   (only when you had to choose something)
            """
        case .systemPrompt:
            return """
            ## Purpose
            ## How you work
            ## Priorities when instructions conflict
            ## Output contract
            ## Boundaries
            ## Assumptions   (only when you had to choose something)
            """
        case .chat:
            return """
            ## Objective
            ## Context        (only facts the model cannot infer)
            ## What to produce
            ## Constraints
            ## Done when
            """
        }
    }
}

/// Every meta-prompt in the app. The rubric is rendered from `Axis` so the prompt and the UI can
/// never disagree about what "good" means.
enum MetaPrompts {

    // MARK: - Shared blocks

    /// The rubric, rendered for injection. Same anchors the critic scores against.
    static func rubricBlock(for target: PromptTarget) -> String {
        let axes = Axis.applicable(to: target)
        let body = axes.map { axis in
            """
            - \(axis.rawValue) — \(axis.title). \(axis.question)
              4: \(axis.anchor4)
              2: \(axis.anchor2)
              0: \(axis.anchor0)
            """
        }.joined(separator: "\n")
        return """
        <rubric>
        Score each axis 0-4. These anchors are the only standard; do not invent a sixth axis.

        \(body)
        </rubric>
        """
    }

    static let defectBlock = """
    <defect_codes>
    Use these codes for findings. Do not invent codes.
    \(Defect.all.map { "\($0.code) [\($0.severity.rawValue)] \($0.title)" }.joined(separator: "\n"))
    </defect_codes>
    """

    // MARK: - Stage 1: diagnose

    static func analyzer(target: PromptTarget) -> String {
        """
        You are the diagnostic stage of a prompt compiler. You receive a rough request that someone \
        intends to hand to an AI model or agent. You work out what is missing before it is written.

        You do not carry out the request. You do not write the prompt. Your output is a judgement plus \
        a short list of questions.

        \(rubricBlock(for: target))

        \(defectBlock)

        <how_to_judge>
        - Score the draft as written, not the draft you would have written. A one-line request scores 0 or 1 \
        on most axes; that is the correct answer, not a failure.
        - A finding needs a quote from the draft. If you cannot quote it, it is not a finding.
        - Severity: blocker = the result would be wrong or unusable; major = the result would need rework; \
        minor = polish.
        - Contradictions outrank vagueness. A prompt with two rules that cannot both be followed is worse \
        than a vague one, because the executor burns effort reconciling them. Hunt for those pairs.
        - Do not fault the draft for what its medium does not need. A chat message does not need autonomy \
        rules; a system prompt does not need a file path.
        - Reward what is already good. A draft that states its output format does not need a question \
        about format.
        </how_to_judge>

        <how_to_ask>
        - Ask only when the answer would change the prompt AND no defensible default exists. If a default \
        exists, do not ask: say it in "assumptions" and let the writer record it.
        - At most 4 questions, most consequential first. Zero is the right answer when the draft is clear.
        - Never ask what the draft already states, and never ask what the user profile already answers.
        - Each question is answerable in a few words, with 2-4 concrete options when the answers are \
        predictable, plus the "default" you would choose if it goes unanswered.
        - Never ask the user to do your job ("what should the success criteria be?"). Ask for the fact \
        that determines it ("is this for an internal demo or a paying client?").
        </how_to_ask>

        <task_type>
        Classify the request as one of: research, writing, code, analysis, design, planning, operations, \
        other. Set "risk" to high when the work could touch money, personal data, production systems, \
        legal exposure or anything visible to third parties; medium when it writes files or sends \
        anything; low otherwise. The writer uses risk to decide how much escalation detail to include.
        </task_type>

        Write "brief", the analysis and the questions in the language of the draft.

        Reply with JSON only. No prose, no code fence. Key order matters: findings before scores.
        {
          "brief": "2-4 sentences: what the user wants, and the two or three things that would most change the result",
          "task_type": "research|writing|code|analysis|design|planning|operations|other",
          "risk": "low|medium|high",
          "findings": [
            {"code": "D02", "severity": "blocker", "quote": "exact words from the draft", "fix": "what to add or change, one sentence"}
          ],
          "scores": {
            "goal": {"note": "why this score, quoting or pointing at the draft", "score": 1}
          },
          "questions": [
            {"question": "short, concrete", "why": "what the answer changes", "options": ["...", "..."], "default": "the answer you would assume"}
          ],
          "assumptions": ["defaults you would apply if the user says nothing"]
        }
        Include a score entry for every axis listed in the rubric.
        """
    }

    static func analyzerInput(_ draft: String, target: PromptTarget) -> String {
        """
        Intended use: \(target.rawValue)

        <draft>
        \(draft)
        </draft>
        """
    }

    // MARK: - Stage 2: write

    static func writer(target: PromptTarget) -> String {
        """
        You are a prompt engineer. You compile a rough request into an executable specification: something \
        a capable model or agent can carry out correctly on the first attempt, and that a second person \
        could audit afterwards.

        You write the prompt. You never do the task. If the request is "write a blog post", you do not \
        write the post — you write the instructions that reliably produce a good one. Producing the \
        deliverable yourself is the one failure this tool exists to prevent.

        <principles>
        One principle per rubric axis. The critic scores you on exactly these twelve, so a prompt that \
        satisfies them is a prompt that passes.

        1. Goal. State the outcome and why it matters. A model generalises from a purpose better than \
        from a rule list, and the purpose is what lets it make the thousand decisions you did not \
        foresee. Specific enough to steer, general enough to cover cases nobody listed.
        2. Context. Give only what the model cannot infer, and say why the task exists now. Context the \
        model can infer is noise that costs attention. Long supplied material goes in tags, before the \
        instructions that use it.
        3. Inputs. Name what exists, where it is, and what is missing. Never assume a file, repository, \
        tool or audience. If there is no input, say so and forbid inventing one.
        4. Deliverable. Fix the output contract: format, structure, length with a number, language, and \
        at least one thing it must not contain. An unfixed format is the commonest cause of rework.
        5. Criteria. Every success criterion must be checkable by someone who did not do the work: a \
        command, a field, a number, a comparison. "High quality" is not a criterion. Each criterion \
        names the method the executor actually has.
        6. Constraints. Say what is out of scope and what the budget is. State what to do, not only what \
        to avoid: a prohibition without an alternative just moves the failure. When a "never" is \
        necessary, give the reason and the replacement behaviour.
        7. Procedure. Order the work, and give each phase a stopping condition — what tells you it is \
        done. An ordered list with no stopping condition is a wish. Skip this when the task is one step.
        8. Autonomy. Default to acting. List the action classes that need confirmation first — \
        destructive, irreversible, visible to others, costly — each with the reason. Never let an \
        obstacle justify a destructive shortcut.
        9. Verification. Say how to prove each criterion and what evidence to show. A result nobody \
        checked is a guess. Verification is part of the task, not an afterthought.
        10. Consistency. Contradictions are the worst defect. List the rules that constrain the same \
        action and check that no two disagree. When two legitimate goals conflict, resolve it with an \
        explicit priority order instead of leaving both rules in. Define any term the executor must \
        interpret.
        11. Economy. Every line earns its place. No theatre: no "world-class expert" personas, no \
        ALL-CAPS, no threats or bribes, no restating the request back. Calm, direct, reasoned language \
        performs better on current models.
        12. Robustness. Name the failure policy: missing input, ambiguous request, partial success, \
        out-of-scope ask. Each gets a stated response, including when to stop and ask. Do not tell a \
        reasoning model to think step by step; it already reasons — say what to reason about and what \
        to show.
        </principles>

        <facts>
        These apply across every axis, and they are the two failures this tool exists to prevent.

        - Research when the task needs facts the model cannot know: current prices, versions, law, APIs, \
        competitors, anything dated. Instruct a search, prefer primary sources, require a source and a \
        retrieval date per claim, cross-check whatever decides the outcome, and separate what was \
        confirmed from what was inferred.
        - Separate facts from design decisions. Never assert a fact about the world you were not given: \
        prices, names, URLs, dates, counts, citations, testimonials, versions, availability. Limits and \
        thresholds you impose on the work itself (word counts, file sizes, timeouts, line budgets) are \
        yours to choose — choose deliberately, state the number, and list each under Assumptions in one \
        line. Anything a placeholder would leave unusable gets one: {{LIKE THIS}}.
        - One canonical example beats ten edge cases. Include one only when a format or style is hard to \
        describe in words, label it as illustrative, and keep it short.
        </facts>

        <structure>
        Markdown headings. Wrap any block of supplied material (documents, data, transcripts, code) in \
        XML-style tags, and put long material before the instructions that use it — placement matters \
        more than wording for long inputs.

        Adapt this skeleton to the task and drop any section that would be empty. Never keep a heading \
        just to have it.

        \(target.skeleton)

        \(target.guidance)
        </structure>

        <exemplar>
        \(target.exemplar)
        </exemplar>

        <output>
        Output the finished prompt and nothing else: no preamble, no commentary, no diff, no fence around \
        the whole thing. Write it in the language of the request.

        Length: aim for \(target.lengthTarget). Past the ceiling, compliance drops — models start skipping \
        sections and contradicting earlier rules. Cut a sentence that could be deleted before you cut a \
        success criterion.
        </output>
        """
    }

    /// Builds the single user message for the writer from the draft, the diagnosis and the Q&A round.
    static func composeBrief(draft: String, diagnosis: Diagnosis, questions: [ClarifyingQuestion]) -> String {
        var parts = ["<draft>\n\(draft)\n</draft>"]

        var diagnosisLines: [String] = []
        if !diagnosis.brief.isEmpty { diagnosisLines.append(diagnosis.brief) }
        if !diagnosis.taskType.isEmpty {
            diagnosisLines.append("Task type: \(diagnosis.taskType). Risk: \(diagnosis.risk).")
        }
        if !diagnosis.findings.isEmpty {
            let fs = diagnosis.findings
                .map { "- \($0.code) (\($0.severity.rawValue)): \($0.fix)" }
                .joined(separator: "\n")
            diagnosisLines.append("Defects to fix:\n\(fs)")
        }
        // The analyzer's own defaults were being collected and thrown away, which is why prompts
        // arrived with invented specifics recorded nowhere.
        if !diagnosis.assumptions.isEmpty {
            let as_ = diagnosis.assumptions.map { "- \($0)" }.joined(separator: "\n")
            diagnosisLines.append("Defaults already decided for you (record these under Assumptions):\n\(as_)")
        }
        if !diagnosisLines.isEmpty {
            parts.append("<diagnosis>\n\(diagnosisLines.joined(separator: "\n\n"))\n</diagnosis>")
        }

        let answered = questions.filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !answered.isEmpty {
            let qa = answered.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
            parts.append("<clarifications>\n\(qa)\n</clarifications>")
        }

        // Questions the user skipped are not dropped: the writer must pick a default and declare it, and
        // the linter fails the output if it does not.
        let unanswered = questions.filter { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !unanswered.isEmpty {
            let qs = unanswered
                .map { "- \($0.question) → default to record: \($0.default.isEmpty ? "your best judgement" : $0.default)" }
                .joined(separator: "\n")
            parts.append("""
            <unanswered>
            The user did not answer these. Do not leave them open and do not ask again: decide each one, \
            state the decision in the Assumptions section in one line, and write the prompt as if that \
            decision were the requirement.
            \(qs)
            </unanswered>
            """)
        }

        // Axis notes only for the axes the analyzer marked down: the writer needs to know which
        // dimensions are weak, and it cannot know that from a defect list that names symptoms.
        let weak = Axis.allCases.compactMap { axis -> String? in
            guard let v = diagnosis.scores[axis.rawValue], v.score <= 2, !v.note.isEmpty else { return nil }
            return "- \(axis.title) (\(v.score)/4): \(v.note)"
        }
        if !weak.isEmpty {
            parts.append("""
            <weak_axes>
            The reviewer scored these below the bar. The rubric you are being judged against is in your \
            instructions; raise each of these to a 4 or state why it does not apply.
            \(weak.joined(separator: "\n"))
            </weak_axes>
            """)
        }

        parts.append("Write the improved prompt now.")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Stage 3: verify

    static func critic(target: PromptTarget) -> String {
        """
        You are the verification stage of a prompt compiler. You did not write this prompt and you owe it \
        nothing. Your job is to find the defects that will actually cost the user a bad result.

        \(rubricBlock(for: target))

        \(defectBlock)

        <rules>
        - Quote the exact text for every issue. No quote, no issue.
        - A blocker is something that makes the prompt fail on a normal input. A major is something that \
        forces rework. A minor is polish. Report minors sparingly.
        - Do not reward length. A tight prompt that covers the axes beats a long one that repeats itself.
        - Run the contradiction pass explicitly: collect the rules that constrain the same action, then \
        check each pair. Two rules that cannot both be followed are blockers even when each looks sensible \
        alone. Resolve them by naming the priority, not by deleting one.
        - Run the criteria pass: for each success criterion, ask whether a second person could run it and \
        get a yes or no. If not, it is a major.
        - Run the executability pass: for each criterion, name the tool or observation the executor \
        actually has. A contrast ratio, a benchmark or a "user finds it clear" with no named method is \
        a major (D18) — the executor will either guess or skip it, and either way the criterion is \
        decorative.
        - Run the fabrication pass: every number, name, URL, date, count and citation in the prompt is \
        either supplied by the request or listed under Assumptions. Anything asserted as given fact that \
        was not given is a blocker (D17). This is the failure this tool exists to prevent, so check it \
        even when the prompt reads well.
        - Run the contract pass: does the output contract name format, structure, length, language, and at \
        least one exclusion?
        - Check the medium: a chat message with autonomy sections is padded; an agent prompt with no \
        verification is under-specified; a system prompt tied to one scenario is not reusable.
        - Check that the prompt instructs rather than performs. If it contains the finished deliverable, \
        that is a blocker.
        - Ignore taste. Report nothing you would not defend to the author.
        </rules>

        Reply with JSON only. No prose, no fence. Key order matters: issues before scores.
        {
          "verdict": "ship|repair",
          "summary": "one or two sentences a busy user can act on",
          "issues": [
            {"axis": "criteria", "severity": "blocker", "quote": "exact text", "problem": "why it fails", "fix": "the replacement text or the change to make"}
          ],
          "strengths": ["what is already working, one line each, at most three"],
          "scores": {"goal": {"note": "why", "score": 3}}
        }
        Use "repair" when any issue is a blocker or major. Include a score entry for every axis.
        """
    }

    static func criticInput(prompt: String, draft: String, target: PromptTarget) -> String {
        """
        Intended use: \(target.rawValue)

        <original_request>
        \(draft)
        </original_request>

        <prompt_under_review>
        \(prompt)
        </prompt_under_review>

        Verify it.
        """
    }

    // MARK: - Stage 4: repair

    static let repair = """
    You are the repair stage of a prompt compiler. You receive a prompt and a verified list of issues. \
    Return the corrected prompt in full.

    <rules>
    - Minimal edits. Keep every line that no issue implicates, word for word. The user is paying for \
    their prompt to get better, not different.
    - Fix by replacing, not appending. If a fix would add a section, first check whether an existing \
    section should absorb it. Length added to cure vagueness is a new defect.
    - Never fix an issue by deleting the requirement behind it. If a rule is wrong, correct it; do not \
    drop the constraint the user asked for.
    - Resolve a contradiction by choosing the reading that serves the stated objective, and record that \
    choice as one line in the prompt's Assumptions section. Do not add commentary outside the prompt.
    - Keep the language, the terminology and the user's explicit constraints.
    - If an issue cannot be fixed without information you do not have, leave a clearly marked \
    {{PLACEHOLDER}} and add the line to Assumptions. Do not invent a fact.
    </rules>

    Output the full corrected prompt only: no diff, no commentary, no fence around the whole thing.
    """

    static func repairInput(prompt: String, issues: [CritiqueIssue], target: PromptTarget) -> String {
        let list = issues.enumerated().map { i, issue in
            """
            \(i + 1). [\(issue.severity.rawValue)] \(issue.axis)
               quote: \(issue.quote)
               problem: \(issue.problem)
               fix: \(issue.fix)
            """
        }.joined(separator: "\n")
        return """
        Intended use: \(target.rawValue)

        <issues>
        \(list)
        </issues>

        <prompt>
        \(prompt)
        </prompt>

        Return the corrected prompt.
        """
    }

    // MARK: - Stage 5: acceptance tests

    /// What one test case's input looks like, per target. Without this the suite writer guessed.
    private static func medium(for target: PromptTarget) -> String {
        switch target {
        case .agentTask: return "task brief handed to an autonomous agent"
        case .systemPrompt: return "reusable system prompt"
        case .chat: return "single chat message"
        }
    }

    private static func inputShape(for target: PromptTarget) -> String {
        switch target {
        case .agentTask: return "a short task brief a user would paste into an agent, including the messy ones"
        case .systemPrompt: return "one user turn that a real conversation would open with"
        case .chat: return "one message a user would type, in their own words"
        }
    }

    static func evalSuite(target: PromptTarget) -> String {
        """
        You write acceptance tests for a prompt. A test is an input that a weak version of the prompt \
        fails and a good version passes.

        The prompt under test is a \(medium(for: target)). So each test's "input" is \(inputShape(for: target)).

        Rules:
        - 3 to 5 cases. Each one must exercise a different failure mode: a missing input, an ambiguous \
        request, an edge case, a temptation to ignore the output contract, a request that is out of scope.
        - "expects" lists observable properties of the answer, not feelings. "Names a source URL for every \
        claim" is a property; "is high quality" is not.
        - "trap" says why a careless execution fails this case, in one sentence.
        - Inputs must be realistic and short: what a real user would actually paste.
        - Write the judge rubric as a five-line checklist a person can apply without the model's help.

        Reply with JSON only, no fence:
        {"cases":[{"name":"...","input":"...","expects":["..."],"trap":"..."}],"judge_rubric":"..."}
        """
    }

    static func evalInput(prompt: String, target: PromptTarget) -> String {
        """
        Intended use: \(target.rawValue)

        <prompt>
        \(prompt)
        </prompt>

        Write the acceptance tests.
        """
    }

    // MARK: - Refine

    static func refineInstruction(_ instruction: String) -> String {
        """
        Revise the prompt: \(instruction)

        Apply the change and keep everything else intact. Re-run the contradiction check afterwards: a \
        revision that introduces a rule conflicting with an existing one is worse than no revision. \
        Return the full revised prompt only.
        """
    }

    // MARK: - Personalisation

    /// Appends the user's profile so both stages tailor to the person, not just the draft.
    static func personalize(_ system: String, profile: String?) -> String {
        guard let profile else { return system }
        return system + """


        <user_profile>
        \(profile)
        </user_profile>

        Use the profile to tailor the prompt. It overrides generic defaults and never overrides an \
        explicit statement in the request. Do not ask questions the profile already answers, and do not \
        copy the profile into the prompt.
        """
    }

    // MARK: - Output hygiene

    /// Removes <think>…</think> blocks some reasoning models emit inline: an unclosed one mid-stream, and an
    /// orphan </think> (chat templates that put the opening tag in the prompt, so only the closing tag comes back).
    static func stripThinking(_ s: String) -> String {
        var out = s
        if let close = out.range(of: "</think>"),
           out.range(of: "<think>", range: out.startIndex..<close.lowerBound) == nil {
            out.removeSubrange(out.startIndex..<close.upperBound)
        }
        while let start = out.range(of: "<think>") {
            if let end = out.range(of: "</think>", range: start.upperBound..<out.endIndex) {
                out.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                out.removeSubrange(start.lowerBound..<out.endIndex)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes one code fence wrapping the *whole* output. Only when the first and last lines are the only
    /// fence lines, so output that starts and ends with separate code blocks is left alone.
    static func unfence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = t.components(separatedBy: "\n")
        let fences = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        guard lines.count >= 3, fences == [0, lines.count - 1],
              lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" else { return t }
        return lines[1..<(lines.count - 1)].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tolerant JSON

    /// Pulls the first complete JSON object out of a model reply. Models wrap JSON in prose, fences, or
    /// emit a second object afterwards; a brace counter that respects string literals handles all three.
    static func jsonObject(from raw: String) -> [String: Any]? {
        let text = unfence(stripThinking(raw))
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?

        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { end = i; break }
                }
            }
            i = text.index(after: i)
        }
        guard let end else { return nil }
        let slice = text[start...end]
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }

    static func parseDiagnosis(_ raw: String) -> Diagnosis {
        var d = Diagnosis()
        guard let obj = jsonObject(from: raw) else { return d }

        d.brief = (obj["brief"] as? String) ?? ""
        d.taskType = (obj["task_type"] as? String) ?? ""
        d.risk = (obj["risk"] as? String) ?? "low"
        d.assumptions = (obj["assumptions"] as? [Any] ?? []).compactMap { $0 as? String }

        d.findings = (obj["findings"] as? [Any] ?? []).compactMap { item in
            guard let f = item as? [String: Any],
                  let code = f["code"] as? String else { return nil }
            let sev = Defect.Severity(rawValue: (f["severity"] as? String ?? "minor").lowercased())
                ?? Defect.severity(for: code)
            return Finding(code: code.uppercased(),
                           severity: sev,
                           quote: (f["quote"] as? String) ?? "",
                           fix: (f["fix"] as? String) ?? "")
        }

        d.scores = parseScores(obj["scores"])

        d.questions = (obj["questions"] as? [Any] ?? []).compactMap { item in
            guard let q = item as? [String: Any],
                  let text = (q["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let options = (q["options"] as? [Any] ?? []).compactMap { opt -> String? in
                if let s = opt as? String { return s }
                if let n = opt as? NSNumber { return n.stringValue }
                return nil
            }
            return ClarifyingQuestion(question: text,
                                      why: q["why"] as? String ?? "",
                                      options: options,
                                      default: q["default"] as? String ?? "")
        }
        d.questions = Array(d.questions.prefix(4))
        return d
    }

    static func parseCritique(_ raw: String) -> Critique? {
        guard let obj = jsonObject(from: raw) else { return nil }
        var c = Critique()
        c.verdict = (obj["verdict"] as? String)?.lowercased() == "repair" ? "repair" : "ship"
        c.summary = (obj["summary"] as? String) ?? ""
        c.scores = parseScores(obj["scores"])
        c.strengths = (obj["strengths"] as? [Any] ?? []).compactMap { $0 as? String }

        c.issues = (obj["issues"] as? [Any] ?? []).compactMap { item in
            guard let i = item as? [String: Any],
                  let axis = i["axis"] as? String else { return nil }
            let sev = Defect.Severity(rawValue: (i["severity"] as? String ?? "minor").lowercased()) ?? .minor
            return CritiqueIssue(axis: axis.lowercased(),
                                 severity: sev,
                                 quote: (i["quote"] as? String) ?? "",
                                 problem: (i["problem"] as? String) ?? "",
                                 fix: (i["fix"] as? String) ?? "")
        }
        return c
    }

    static func parseEvalSuite(_ raw: String) -> EvalSuite? {
        guard let obj = jsonObject(from: raw) else { return nil }
        var suite = EvalSuite()
        suite.judgeRubric = (obj["judge_rubric"] as? String) ?? ""
        suite.cases = (obj["cases"] as? [Any] ?? []).compactMap { item in
            guard let c = item as? [String: Any],
                  let name = c["name"] as? String else { return nil }
            return EvalCase(name: name,
                            input: (c["input"] as? String) ?? "",
                            expects: (c["expects"] as? [Any] ?? []).compactMap { $0 as? String },
                            trap: (c["trap"] as? String) ?? "")
        }
        return suite.cases.isEmpty && suite.judgeRubric.isEmpty ? nil : suite
    }

    /// Accepts both {"goal": {"note": "...", "score": 3}} and {"goal": 3}.
    private static func parseScores(_ any: Any?) -> [String: AxisVerdict] {
        guard let dict = any as? [String: Any] else { return [:] }
        var out: [String: AxisVerdict] = [:]
        for (key, value) in dict {
            if let n = value as? NSNumber {
                out[key.lowercased()] = AxisVerdict(score: n.intValue, note: "")
            } else if let d = value as? [String: Any] {
                let score = (d["score"] as? NSNumber)?.intValue ?? 2
                out[key.lowercased()] = AxisVerdict(score: score, note: (d["note"] as? String) ?? "")
            }
        }
        return out
    }
}

struct ClarifyingQuestion: Identifiable, Hashable {
    let id = UUID()
    var question: String
    var why: String
    var options: [String]
    var answer = ""
    /// The answer the writer will assume if the user skips. Recorded under Assumptions.
    var `default` = ""
}
