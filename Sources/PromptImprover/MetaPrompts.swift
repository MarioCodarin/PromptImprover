import Foundation

enum MetaPrompts {

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
    static func principleBlock(for target: PromptTarget) -> String {
        let scored = Axis.applicable(to: target)
        let lines = principles
            .filter { scored.contains($0.0) }
            .enumerated()
            .map { index, pair in "\(index + 1). \(pair.0.title). \(pair.1)" }
        return """
        One principle per rubric axis. The critic scores you on exactly these \(lines.count), so a \
        prompt that satisfies them is a prompt that passes.

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
    static func diagnosticRubricBlock(for target: PromptTarget) -> String {
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
        Score each axis 0-4. These anchors are the only standard; do not invent an axis.

        \(body)
        </rubric>
        """
    }

    static let defectBlock = """
    <defect_codes>
    Use these codes for findings. Do not invent codes. They are listed worst-first; report
    findings in this order.
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

        \(diagnosticRubricBlock(for: target))

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
    static func riskNote(_ risk: String) -> String {
        switch risk.lowercased() {
        case "high":
            return "spell out every action class that needs confirmation, with the reason and the safer alternative"
        case "medium":
            return "state what needs confirmation before acting, in one line"
        default:
            return "proceed by default; no confirmation rules needed"
        }
    }

    static func composeBrief(draft: String, diagnosis: Diagnosis, questions: [ClarifyingQuestion]) -> String {
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
        - Run the criteria pass: for each success criterion, ask two things at once — could a second \
        person run it and get a yes or no, and does the executor have the tool or observation to check \
        it? A contrast ratio, a benchmark or a "user finds it clear" with no named method fails both. \
        Report that as ONE issue on the criteria axis (D18), not two: one flaw, one repair.
        - Run the fabrication pass: every number, name, URL, date, count and citation in the prompt is \
        either supplied by the request or listed under Assumptions. Anything asserted as given fact that \
        was not given is a blocker (D17). This is the failure this tool exists to prevent, so check it \
        even when the prompt reads well.
        - Run the contract pass: does the output contract pin format, structure, length with a number, \
        language, and at least one exclusion? A short task may pin fewer; what it pins is not left to \
        chance.
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
            {"axis": "criteria", "code": "D02", "severity": "blocker", "quote": "exact text", "problem": "why it fails", "fix": "the replacement text or the change to make"}
          ],
          "strengths": ["what is already working, one line each, at most three"],
          "scores": {"goal": {"note": "why", "score": 3}}
        }
        Use "repair" when any issue is a blocker or major. Include a score entry for every axis.
        Every issue carries the defect code from the list above, so the repair stage knows which
        rule it is answering.
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
    - Keep the language, the terminology and the user's explicit constraints. Stay inside the
    length envelope you are given; if a fix pushes past it, cut something that could be deleted
    rather than dropping the fix.
    - If an issue cannot be fixed without information you do not have, leave a clearly marked \
    {{PLACEHOLDER}} and add the line to Assumptions. Do not invent a fact.
    </rules>

    Output the full corrected prompt only: no diff, no commentary, no fence around the whole thing.
    """

    static func repairInput(prompt: String, issues: [CritiqueIssue], target: PromptTarget,
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
}
