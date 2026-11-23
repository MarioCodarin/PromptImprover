import Foundation

public enum MetaPrompts {

    /// One principle per rubric axis, keyed by axis so `principleBlock` can hand a target only the
    /// ones it is actually scored on. The previous static block claimed "the critic scores you on
    /// exactly these twelve" in a message that also told a chat turn to omit autonomy — two direct
    /// orders about the same thing, and the model had to guess which won.
    private static let principles: [(Axis, String)] = [
        (.goal, """
        State the outcome and why it matters. A model generalises from a purpose better than from a \
        rule list, and the purpose is what lets it make the thousand decisions you did not foresee. \
        Specific enough to steer, general enough to cover cases nobody listed.
        """),
        (.context, """
        Give only what the model cannot infer, and say why the task exists now. Context the model can \
        infer is noise that costs attention. Long supplied material goes in tags, before the \
        instructions that use it. If there is genuinely no background, say so in one line rather than \
        leaving the section out or filling it.
        """),
        (.inputs, """
        Name what exists, where it is, and what is missing. Never assume a file, repository, tool or \
        audience. If there is no input, say so and forbid inventing one.
        """),
        (.deliverable, """
        Fix the output contract: format, structure, length with a number, language, and at least one \
        thing it must not contain. A short task may pin fewer of these; an unfixed format is the \
        commonest cause of rework.
        """),
        (.criteria, """
        Every success criterion must be checkable by someone who did not do the work: a command, a \
        field, a number, a comparison. "High quality" is not a criterion. Each criterion names the \
        method the executor actually has.
        """),
        (.constraints, """
        Say what is out of scope and what the budget is. State what to do, not only what to avoid: a \
        prohibition without an alternative just moves the failure. When a "never" is necessary, give \
        the reason and the replacement behaviour.
        """),
        (.procedure, """
        Order the work, and give each phase a stopping condition — what tells you it is done. An \
        ordered list with no stopping condition is a wish. A one-step task needs no phases; write the \
        step and move on.
        """),
        (.autonomy, """
        Default to acting. List the action classes that need confirmation first — destructive, \
        irreversible, visible to others, costly — each with the reason. Never let an obstacle justify \
        a destructive shortcut.
        """),
        (.verification, """
        Say how to prove each criterion and what evidence to show. A result nobody checked is a guess. \
        Verification is part of the task, not an afterthought.
        """),
        (.consistency, """
        Contradictions are the worst defect. List the rules that constrain the same action and check \
        that no two disagree. When two legitimate goals conflict, resolve it with an explicit priority \
        order instead of leaving both rules in. Define any term the executor must interpret.
        """),
        (.economy, """
        Every line earns its place. No theatre: no "world-class expert" personas, no ALL-CAPS, no \
        threats or bribes, no restating the request back, no padding to reach a length. Calm, direct, \
        reasoned language performs better on current models.
        """),
        (.robustness, """
        Name the failure policy for the failure classes this task can actually have: missing input, \
        ambiguous request, and — for work that executes — partial success and out-of-scope asks. Each \
        gets a stated response, including when to stop and ask. Do not tell a reasoning model to think \
        step by step; it already reasons — say what to reason about and what to show.
        """),
    ]

    /// The principles this target is scored on, numbered from one so the list reads as a list.
    public static func principleBlock(for target: PromptTarget) -> String {
        let scored = Axis.applicable(to: target)
        let lines = principles
            .filter { scored.contains($0.0) }
            .enumerated()
            .map { index, pair in "\(index + 1). \(pair.0.title). \(pair.1)" }
        return """
        \(lines.count) principles. A prompt that satisfies them passes review; write for the task, not \
        for the list.

        \(lines.joined(separator: "\n\n        "))
        """
    }

    // MARK: - Shared blocks

    /// The rubric, rendered for injection. Same anchors the critic scores against.
    /// The rubric as the analyzer needs it: the axis, what it asks, and the boundary between
    /// "generic" and "clears the bar".
    ///
    /// The analyzer's scores have exactly one consumer — the writer's weak-axis list, thresholded
    /// at 2 — so the only discrimination it has to make is 2 versus 3. Sending it all three
    /// anchors of every axis (872 words, the largest block in the pipeline) bought a precision
    /// nothing reads. The critic keeps the full anchors, because it produces the number on screen.
    public static func diagnosticRubricBlock(for target: PromptTarget) -> String {
        let axes = Axis.applicable(to: target)
        let body = axes.map { axis in
            "- \(axis.rawValue) — \(axis.question)\n  generic (2): \(axis.anchor2)"
        }.joined(separator: "\n")
        return """
        <rubric>
        Score each axis 0-4 against the boundary below. These axes are the only standard; do not
        invent an axis.

        0 = nothing on this axis. 1-2 = something, but generic enough that two readers would build
        different things. 3-4 = the draft clears the boundary; it will survive the writer's edit.

        \(body)
        </rubric>
        """
    }

    public static func rubricBlock(for target: PromptTarget) -> String {
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
        Score each axis 0-4. These anchors are the only standard; do not invent an axis.

        \(body)
        </rubric>
        """
    }

    public static let defectBlock = """
    <defect_codes>
    Use these codes for findings. Do not invent codes. They are listed worst-first; report
    findings in this order.
    \(Defect.all.map { "\($0.code) [\($0.severity.rawValue)] \($0.title)" }.joined(separator: "\n"))
    </defect_codes>
    """

    // MARK: - Stage 1: diagnose

    /// The clarifier. It replaced a diagnostic stage that scored all twelve axes with a written
    /// justification each: a long JSON reply whose only consumer was the writer's weak-axis list.
    /// What measurably helps a strong model is the *missing information* (BPO, arXiv 2311.04155,
    /// and its scale study, arXiv 2505.08303: restyling a prompt gains ~0 on large models), so this
    /// stage asks for exactly that: what is missing, what to ask, and what to assume.
    public static func analyzer(target: PromptTarget) -> String {
        """
        You read a rough request that someone will turn into a prompt for an AI model or agent, and \
        work out what is missing before it is written. You do not carry out the request and you do \
        not write the prompt.

        <what_to_find>
        At most five gaps that would most change the result: a missing goal or audience, no output \
        format or length, no way to tell success, an unstated input, two requirements that cannot \
        both hold. Quote the draft for each. Contradictions outrank vagueness. Do not fault the draft \
        for what its medium does not need: a chat message needs no autonomy rules.
        </what_to_find>

        <how_to_ask>
        - Ask only when the answer would change the prompt AND no defensible default exists. If a \
        default exists, put it in "assumptions" instead.
        - At most 4 questions, most consequential first. Zero is the right answer for a clear draft.
        - Never ask what the draft or the user profile already answers.
        - Each question is answerable in a few words, with 2-4 options when answers are predictable, \
        and the "default" you would pick if it goes unanswered.
        - Ask for the fact that decides something ("internal demo or paying client?"), never for the \
        decision itself ("what should the success criteria be?").
        </how_to_ask>

        <task_type>
        task_type is one of: research, writing, code, analysis, design, planning, operations, other. \
        risk is high when the work could touch money, personal data, production systems, legal \
        exposure or third parties; medium when it writes files or sends anything; low otherwise.
        </task_type>

        Write every string in the language of the draft. Reply with JSON only, no prose, no fence:
        {
          "brief": "2-3 sentences: what the user wants and what would most change the result",
          "task_type": "research|writing|code|analysis|design|planning|operations|other",
          "risk": "low|medium|high",
          "findings": [{"code": "D02", "quote": "exact words from the draft", "fix": "one sentence"}],
          "questions": [{"question": "short", "why": "what the answer changes", "options": ["a", "b"], "default": "a"}],
          "assumptions": ["a default you would apply if the user says nothing"]
        }
        Use only these finding codes; each one's severity is fixed by the code: \
        \(Defect.all.filter { $0.severity != .minor }.map { "\($0.code) \($0.title)" }.joined(separator: "; ")).
        Omit polish: report only what would make the result wrong or force rework.
        """
    }

    public static func analyzerInput(_ draft: String, target: PromptTarget) -> String {
        """
        Intended use: \(target.rawValue)

        <draft>
        \(draft)
        </draft>
        """
    }

    // MARK: - Stage 2: write

    public static func writer(target: PromptTarget) -> String {
        """
        You are a prompt engineer. You compile a rough request into an executable specification: something \
        a capable model or agent can carry out correctly on the first attempt, and that a second person \
        could audit afterwards.

        You write the prompt. You never do the task. If the request is "write a blog post", you do not \
        write the post — you write the instructions that reliably produce a good one. Producing the \
        deliverable yourself is the one failure this tool exists to prevent.

        <principles>
        \(principleBlock(for: target))
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
        line. Use a placeholder, {{LIKE THIS}}, only where the prompt is unusable without the value, \
        and keep them to a handful — six at most.
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
    /// What the risk level should change in the prompt. The analyzer was told the writer used this
    /// to size its escalation detail; the writer was never told what any level meant.
    public static func riskNote(_ risk: String) -> String {
        switch risk.lowercased() {
        case "high":
            return "spell out every action class that needs confirmation, with the reason and the safer alternative"
        case "medium":
            return "state what needs confirmation before acting, in one line"
        default:
            return "proceed by default; no confirmation rules needed"
        }
    }

    public static func composeBrief(draft: String, diagnosis: Diagnosis, questions: [ClarifyingQuestion]) -> String {
        var parts = ["<draft>\n\(draft)\n</draft>"]

        var diagnosisLines: [String] = []
        if !diagnosis.brief.isEmpty { diagnosisLines.append(diagnosis.brief) }
        if !diagnosis.taskType.isEmpty {
            diagnosisLines.append("Task type: \(diagnosis.taskType). Risk: \(diagnosis.risk) — \(riskNote(diagnosis.risk)).")
        }
        if !diagnosis.findings.isEmpty {
            // The quote is the evidence; the code is a private label the writer has no table for.
            let fs = diagnosis.findings.map { f -> String in
                let quote = f.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                let evidence = quote.isEmpty ? "" : "\n  in the draft: \u{201C}\(quote)\u{201D}"
                return "- [\(f.severity.rawValue)] \(f.title)\(evidence)\n  fix: \(f.fix)"
            }.joined(separator: "\n")
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

        parts.append("Write the improved prompt now.")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Stage 3: verify

    /// The reviewer (Deep only). Issues with quotes, no per-axis scores: the score was a weighted
    /// mean of twelve judgements that moved 17 points between identical runs (see `RepairGuard`),
    /// while the quoted issues are what the repair stage actually consumes.
    public static func critic(target: PromptTarget) -> String {
        let checklist = Axis.applicable(to: target).map { "- \($0.rawValue): \($0.question)" }
            .joined(separator: "\n")
        return """
        You review a prompt someone else wrote. Find the defects that will cost the user a bad result, \
        and nothing else.

        <checklist>
        \(checklist)
        </checklist>

        <passes>
        - Contradictions: collect the rules that constrain the same action and check each pair. Two \
        rules that cannot both be followed are a blocker.
        - Fabrication: every number, name, URL, date and citation is either in the original request \
        or listed under Assumptions. Anything else asserted as fact is a blocker.
        - Criteria: each success criterion can be checked by someone else, with a method the executor \
        has. Report a failure as one issue on the criteria axis.
        - Performing: if the prompt contains the finished deliverable instead of instructions, that \
        is a blocker.
        - Medium: a chat message with autonomy sections is padded; an agent prompt with no \
        verification is under-specified.
        - Contract: the output pins format, length with a number, language, and at least one \
        exclusion. Do not reward length.
        </passes>

        Blocker = fails on a normal input. Major = forces rework. Minor = polish; report at most two. \
        Quote the exact text for every issue; no quote, no issue. Ignore taste. At most six issues.

        Reply with JSON only, no prose, no fence:
        {"verdict": "ship|repair", "summary": "one sentence", "issues": [{"axis": "criteria", "severity": "major", "quote": "exact text", "problem": "why it fails", "fix": "the replacement text"}]}
        Use "repair" when any issue is a blocker or major.
        """
    }

    public static func criticInput(prompt: String, draft: String, target: PromptTarget) -> String {
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

    public static let repair = """
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
    - Keep the language, the terminology and the user's explicit constraints. Stay inside the
    length envelope you are given; if a fix pushes past it, cut something that could be deleted
    rather than dropping the fix.
    - If an issue cannot be fixed without information you do not have, leave a clearly marked \
    {{PLACEHOLDER}} and add the line to Assumptions. Do not invent a fact.
    </rules>

    Output the full corrected prompt only: no diff, no commentary, no fence around the whole thing.
    """

    public static func repairInput(prompt: String, issues: [CritiqueIssue], target: PromptTarget,
                            draft: String = "", lengthTarget: String = "") -> String {
        let list = issues.enumerated().map { i, issue in
            """
            \(i + 1). [\(issue.severity.rawValue)] \(issue.axis)
               quote: \(issue.quote)
               problem: \(issue.problem)
               fix: \(issue.fix)
            """
        }.joined(separator: "\n")
        var parts = ["Intended use: \(target.rawValue)"]
        if !lengthTarget.isEmpty {
            parts.append("Length envelope: \(lengthTarget).")
        }
        // Without the original request, a repair cannot tell a fix from a drift: it will happily
        // delete a constraint because the issue list did not mention it.
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDraft.isEmpty {
            parts.append("<original_request>\n\(trimmedDraft)\n</original_request>")
        }
        parts.append("<issues>\n\(list)\n</issues>")
        parts.append("<prompt>\n\(prompt)\n</prompt>")
        parts.append("Return the corrected prompt.")
        return parts.joined(separator: "\n\n")
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

    public static func evalSuite(target: PromptTarget) -> String {
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

    public static func evalInput(prompt: String, target: PromptTarget) -> String {
        """
        Intended use: \(target.rawValue)

        <prompt>
        \(prompt)
        </prompt>

        Write the acceptance tests.
        """
    }

    // MARK: - Refine

    public static func refineInstruction(_ instruction: String) -> String {
        """
        Revise the prompt: \(instruction)

        Apply the change and keep everything else intact. Re-run the contradiction check afterwards: a \
        revision that introduces a rule conflicting with an existing one is worse than no revision. \
        Return the full revised prompt only.
        """
    }

    // MARK: - Personalisation

    /// Appends the user's profile so both stages tailor to the person, not just the draft.
    public static func personalize(_ system: String, profile: String?) -> String {
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
}
