import Foundation

/// Offline checks for everything that decides output quality but does not need a network call:
/// the rubric maths, the tolerant JSON parsers, the brief composer, and every linter rule.
///
/// Run with `PromptImprover --selftest`. Exit code 0 means the app's own gate still passes its own
/// examples — the one thing that must never silently rot when a prompt is edited.
enum SelfTest {

    static func run() -> Int32 {
        var failures: [(String, String)] = []
        var passes = 0

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition { passes += 1 } else { failures.append((name, detail())) }
        }

        // MARK: Rubric

        let perfect = Diagnosis(scores: Dictionary(uniqueKeysWithValues: Axis.allCases.map {
            ($0.rawValue, AxisVerdict(score: 4, note: ""))
        }))
        check("rubric: all 4s is 100", perfect.total(for: .agentTask) == 100, "got \(perfect.total(for: .agentTask))")

        let zero = Diagnosis(scores: Dictionary(uniqueKeysWithValues: Axis.allCases.map {
            ($0.rawValue, AxisVerdict(score: 0, note: ""))
        }))
        check("rubric: all 0s is 0", zero.total(for: .agentTask) == 0, "got \(zero.total(for: .agentTask))")

        let mixed = Diagnosis(scores: ["goal": AxisVerdict(score: 4, note: "")])
        let mixedScore = mixed.total(for: .agentTask)
        check("rubric: missing axes default to 2, not 0", mixedScore > 0 && mixedScore < 100, "got \(mixedScore)")

        check("rubric: chat excludes autonomy", !Axis.applicable(to: .chat).contains(.autonomy))
        check("rubric: agent includes verification", Axis.applicable(to: .agentTask).contains(.verification))
        check("rubric: every axis has all three anchors",
              Axis.allCases.allSatisfy { !$0.anchor4.isEmpty && !$0.anchor2.isEmpty && !$0.anchor0.isEmpty })

        // MARK: Tolerant JSON

        let fenced = """
        ```json
        {"verdict": "ship", "summary": "fine"}
        ```
        """
        check("json: fenced object", ResponseParsing.jsonObject(from: fenced)?["summary"] as? String == "fine")

        let chatty = """
        Sure! Here is my analysis:
        {"a": 1, "b": {"c": "}"}}
        and some trailing prose {"x": 9}
        """
        let chattyObj = ResponseParsing.jsonObject(from: chatty)
        check("json: brace inside a string does not end the object", chattyObj?["a"] as? Int == 1)
        check("json: trailing object ignored", chattyObj?["x"] == nil)

        check("json: no object returns nil", ResponseParsing.jsonObject(from: "no json here") == nil)

        // MARK: Parsers

        let diagnosisJSON = """
        {"brief": "Wants a landing page.",
         "task_type": "design", "risk": "medium",
         "findings": [{"code": "D02", "severity": "blocker", "quote": "make it nice", "fix": "state what a visitor must do"}],
         "scores": {"goal": {"note": "vague", "score": 1}, "deliverable": 2},
         "questions": [{"question": "Who is the page for?", "why": "changes tone", "options": ["devs", "clients"], "default": "clients"}],
         "assumptions": ["Assume a marketing page"]}
        """
        let d = ResponseParsing.parseDiagnosis(diagnosisJSON)
        check("parse: brief", d.brief == "Wants a landing page.")
        check("parse: risk", d.risk == "medium")
        check("parse: finding severity", d.findings.first?.severity == .blocker)
        check("parse: object score form", d.scores["goal"]?.score == 1)
        check("parse: number score form", d.scores["deliverable"]?.score == 2)
        check("parse: question default", d.questions.first?.default == "clients")
        check("parse: assumption", d.assumptions.first == "Assume a marketing page")

        let badCode = ResponseParsing.parseDiagnosis(#"{"findings":[{"code":"D99","severity":"wat","quote":"x","fix":"y"}]}"#)
        check("parse: unknown code falls back to taxonomy severity", badCode.findings.first?.severity == .minor)

        let critiqueJSON = """
        {"verdict": "repair", "summary": "Criteria are unmeasurable.",
         "issues": [{"axis": "criteria", "severity": "blocker", "quote": "high quality", "problem": "unfalsifiable", "fix": "name a threshold"}],
         "strengths": ["clear objective"],
         "scores": {"criteria": {"note": "adjective", "score": 1}}}
        """
        let c = ResponseParsing.parseCritique(critiqueJSON)
        check("parse: critique verdict", c?.verdict == "repair")
        check("parse: critique needs repair", c?.needsRepair == true)
        check("parse: critique issue axis", c?.issues.first?.axis == "criteria")
        check("parse: critique score", c?.scores["criteria"]?.score == 1)

        let suiteJSON = """
        {"cases":[{"name":"Empty input","input":"","expects":["asks for the missing field"],"trap":"invents data"}],
         "judge_rubric":"1. Every claim has a source."}
        """
        let suite = ResponseParsing.parseEvalSuite(suiteJSON)
        check("parse: eval case", suite?.cases.first?.name == "Empty input")
        check("parse: eval markdown renders", suite?.markdown.contains("Acceptance tests") == true)

        // MARK: Output hygiene

        check("unfence: strips one wrapper",
              ResponseParsing.unfence("```markdown\n# A\nbody\n```") == "# A\nbody")
        check("unfence: leaves two blocks alone",
              ResponseParsing.unfence("```\na\n```\n```\nb\n```").contains("```"))
        check("thinking: orphan closing tag stripped",
              ResponseParsing.stripThinking("</think>\n# Prompt") == "# Prompt")
        check("thinking: unclosed block stripped to empty",
              ResponseParsing.stripThinking("<think>musing forever") == "")

        // MARK: Brief composer

        let unanswered = [
            ClarifyingQuestion(question: "Audience?", why: "", options: [], default: "developers"),
            ClarifyingQuestion(question: "Length?", why: "", options: [], answer: "short", default: "long"),
        ]
        let brief = MetaPrompts.composeBrief(draft: "make a page", diagnosis: Diagnosis(), questions: unanswered)
        check("brief: unanswered block present", brief.contains("<unanswered>"))
        check("brief: unanswered default carried", brief.contains("developers"))
        check("brief: answered question in clarifications", brief.contains("A: short"))
        check("brief: answered question not repeated as unanswered",
              !brief.contains("→ default to record: long"))

        // MARK: Linter

        for target in PromptTarget.allCases {
            let prompt = syntheticPrompt(target)
            let report = PromptLinter.lint(prompt, target: target, unansweredQuestions: 0, draft: "make a page")
            check("linter: own skeleton passes for \(target.rawValue)",
                  report.blockers.isEmpty,
                  report.blockers.map(\.title).joined(separator: "; "))
        }

        let noCriteria = """
        # Task
        ## Objective
        Do the thing well.
        ## Context
        Some background that the model could not know about the client.
        ## Deliverable
        A report.
        """
        let r1 = PromptLinter.lint(noCriteria, target: .agentTask, unansweredQuestions: 0)
        check("linter: missing success criteria is a blocker", r1.blockers.contains { $0.id.hasPrefix("missing-success") },
              r1.blockers.map(\.id).joined(separator: ","))

        let fencedPrompt = "```markdown\n" + syntheticPrompt(.agentTask) + "\n```"
        let r2 = PromptLinter.lint(fencedPrompt, target: .agentTask, unansweredQuestions: 0)
        check("linter: fenced output is a major", r2.majors.contains { $0.id == "fence" })

        let preamble = "Sure! Here is your prompt.\n" + syntheticPrompt(.agentTask)
        let r3 = PromptLinter.lint(preamble, target: .agentTask, unansweredQuestions: 0)
        check("linter: chat preamble is a major", r3.majors.contains { $0.id == "preamble" })

        // Same prompt with the Assumptions section renamed away: the writer skipped the defaults.
        let silent = syntheticPrompt(.agentTask).replacingOccurrences(of: "## Assumptions", with: "## Notes")
        let r4 = PromptLinter.lint(silent, target: .agentTask, unansweredQuestions: 2)
        check("linter: unanswered questions need assumptions", r4.majors.contains { $0.id == "silent-defaults" })

        let formats = syntheticPrompt(.agentTask) + "\nOutput JSON only.\nReturn it as Markdown.\n"
        let r5 = PromptLinter.lint(formats, target: .agentTask, unansweredQuestions: 0)
        check("linter: two output formats is a major", r5.majors.contains { $0.id == "format-conflict" })

        let conflict = syntheticPrompt(.agentTask) + "\nKeep it under 250 words.\nThe report must be at least 600 words.\n"
        let r5b = PromptLinter.lint(conflict, target: .agentTask, unansweredQuestions: 0)
        check("linter: two word budgets conflict", r5b.majors.contains { $0.id == "limit-conflict-words" },
              r5b.majors.map(\.id).joined(separator: ","))

        // Per-section counts are normal and must not be reported as a conflict.
        let perSection = syntheticPrompt(.agentTask) + "\nUse 3 bullets for the summary.\nUse 5 bullets for the risks.\n"
        let r5c = PromptLinter.lint(perSection, target: .agentTask, unansweredQuestions: 0)
        check("linter: per-section counts are not a conflict",
              !r5c.issues.contains { $0.id.hasPrefix("limit-conflict") })

        // Live regression: a {{PLACEHOLDER}} in caps is a fill-in field, not emphasis.
        let placeholder = syntheticPrompt(.agentTask) + "\nFill in {{LAST DAY}} and {{MANAGER NAME}} before sending.\n"
        let r5d = PromptLinter.lint(placeholder, target: .agentTask, unansweredQuestions: 0)
        check("linter: caps placeholders are not shouting", !r5d.issues.contains { $0.id == "shouting" },
              r5d.issues.map(\.id).joined(separator: ","))

        // Live regression: a chat message is prose and must not be failed for lacking headings.
        let chat = syntheticPrompt(.chat)
        let r5e = PromptLinter.lint(chat, target: .chat, unansweredQuestions: 0)
        check("linter: a prose chat message passes the section checks",
              !r5e.issues.contains { $0.id.hasPrefix("missing-") },
              r5e.issues.map(\.id).joined(separator: ","))

        // Live regression: ordered-list markers are not measurements.
        let vague = """
        # Thing

        ## Objective
        Do it well.

        ## Context
        Something.

        ## Requirements
        Be good.

        ## Output contract
        A file.

        ## Success criteria
        1. It should be high quality and thorough.
        2. The result must be excellent.
        """
        let r5g = PromptLinter.lint(vague, target: .agentTask, unansweredQuestions: 0)
        check("linter: list markers do not satisfy the criteria check",
              r5g.issues.contains { $0.id == "vague-criteria" }, r5g.issues.map(\.id).joined(separator: ","))

        // Live regression: a legal range is not a conflicting pair of limits.
        let range = syntheticPrompt(.agentTask) + "\nKeep it between 400 and 700 words.\n"
        let r5h = PromptLinter.lint(range, target: .agentTask, unansweredQuestions: 0)
        check("linter: a stated range is not a conflict",
              !r5h.issues.contains { $0.id.hasPrefix("limit-conflict") }, r5h.issues.map(\.id).joined(separator: ","))

        let thousands = syntheticPrompt(.agentTask) + "\nUnder 1,000 words total, and at most 1,400 words.\n"
        let r5i = PromptLinter.lint(thousands, target: .agentTask, unansweredQuestions: 0)
        check("linter: thousands separators parse as numbers",
              !r5i.issues.contains { $0.id.hasPrefix("limit-conflict") }, r5i.issues.map(\.id).joined(separator: ","))

        // A format declared per sentence is judged per sentence, not per document.
        let twoFormats = syntheticPrompt(.agentTask) + "\nReturn the output as JSON.\nAlso emit a table.\n"
        let r5j = PromptLinter.lint(twoFormats, target: .agentTask, unansweredQuestions: 0)
        check("linter: a second format in its own sentence is caught",
              r5j.majors.contains { $0.id == "format-conflict" }, r5j.issues.map(\.id).joined(separator: ","))

        // "or" inside an unrelated sentence must not silence the format check.
        let smuggled = syntheticPrompt(.agentTask) + "\nReturn the output as JSON.\nAlso return the log as CSV.\n"
        let r5k = PromptLinter.lint(smuggled, target: .agentTask, unansweredQuestions: 0)
        check("linter: an unrelated 'or' does not excuse two formats",
              r5k.majors.contains { $0.id == "format-conflict" }, r5k.issues.map(\.id).joined(separator: ","))

        let eitherOr = syntheticPrompt(.agentTask) + "\nReturn the output as JSON, or as CSV if the caller asks for a spreadsheet.\n"
        let r5l = PromptLinter.lint(eitherOr, target: .agentTask, unansweredQuestions: 0)
        check("linter: an either/or in the same sentence is allowed",
              !r5l.issues.contains { $0.id == "format-conflict" })

        // An instruction to the executor is not the model talking about the prompt.
        let tellMe = syntheticPrompt(.agentTask) + "\nRun the migration, then let me know if the row count changed.\n"
        let r5m = PromptLinter.lint(tellMe, target: .agentTask, unansweredQuestions: 0)
        check("linter: 'let me know if' is an instruction, not meta", !r5m.issues.contains { $0.id == "meta" },
              r5m.issues.map(\.id).joined(separator: ","))

        // Two illustrative examples are what the writer is told to produce.
        let examples = syntheticPrompt(.agentTask)
            + "\nInput: `add two numbers`. Output: `{\"sum\": 3}`.\n\n```\n{\"sum\": 3}\n```\n\n"
            + "Input: `greet`. Output: `{\"greeting\": \"hi\"}`.\n\n```\n{\"greeting\": \"hi\"}\n```\n"
        let r5n = PromptLinter.lint(examples, target: .agentTask, unansweredQuestions: 0)
        check("linter: two small examples are not an executed task", !r5n.issues.contains { $0.id == "executed" },
              r5n.issues.map(\.id).joined(separator: ","))

        // Live regression: a field used twice is one slot, not two.
        let reused = syntheticPrompt(.agentTask) + "\nAddress it to {{NAME}}; sign it {{NAME}}.\n"
        let r5o = PromptLinter.lint(reused, target: .agentTask, unansweredQuestions: 0)
        check("linter: a repeated placeholder counts once", !r5o.issues.contains { $0.id == "placeholders" },
              r5o.issues.map(\.id).joined(separator: ","))

        // Live regression: a chat message records its decisions inline.
        let inline = syntheticPrompt(.chat) + "\nAssumptions: a neutral relationship; two weeks' notice."
        let r5p = PromptLinter.lint(inline, target: .chat, unansweredQuestions: 2)
        check("linter: inline assumptions satisfy the chat target",
              !r5p.issues.contains { $0.id == "silent-defaults" }, r5p.issues.map(\.id).joined(separator: ","))

        // Live regression: a system prompt that opens with its role has stated its purpose.
        let roleOpener = """
        You draft resignation emails that leave the relationship intact.

        ## How you work
        Ask for the last day, then draft.

        ## Output contract
        Prose under 200 words.
        """
        let r5q = PromptLinter.lint(roleOpener, target: .systemPrompt, unansweredQuestions: 0)
        check("linter: a role opening satisfies the purpose section",
              !r5q.issues.contains { $0.id == "missing-purpose" }, r5q.issues.map(\.id).joined(separator: ","))

        let noRole = "Here are some rules.\n\n## How you work\nBe nice.\n\n## Output contract\nProse.\n"
        let r5r = PromptLinter.lint(noRole, target: .systemPrompt, unansweredQuestions: 0)
        check("linter: a system prompt with no role still fails",
              r5r.issues.contains { $0.id == "missing-purpose" })

        // Live regression: a chat message labelled its decisions in prose, with no heading.
        let proseAssumptions = syntheticPrompt(.chat) + """

        Assumptions (already decided, do not ask):
        - Recipient is the direct manager only.
        - Standard notice, stated once.
        """
        let r5s = PromptLinter.lint(proseAssumptions, target: .chat, unansweredQuestions: 2)
        check("linter: a prose assumption clause is read", !r5s.issues.contains { $0.id == "silent-defaults" },
              r5s.issues.map(\.id).joined(separator: ","))

        // A label is usually bolded. Requiring a bare word failed the natural way of writing it.
        let boldAssumptions = syntheticPrompt(.chat)
            + "\n**Assumptions:** internal draft, not a launch; signup is non-functional by design.\n"
        let r5bold = PromptLinter.lint(boldAssumptions, target: .chat, unansweredQuestions: 4)
        check("linter: a bolded Assumptions label counts",
              !r5bold.issues.contains { $0.id == "silent-defaults" },
              r5bold.issues.map(\.id).joined(separator: ","))

        // One decision can answer two questions; a string test cannot map questions to decisions,
        // so presence is the sound property. Absence still fails.
        let noAssumptions = syntheticPrompt(.chat)
        let r5t = PromptLinter.lint(noAssumptions, target: .chat, unansweredQuestions: 4)
        check("linter: unanswered questions with no recorded decision still fail",
              r5t.issues.contains { $0.id == "silent-defaults" },
              r5t.issues.map(\.id).joined(separator: ","))

        // The model names axes in its own words; a near-miss must still score, not silently
        // fall back to the generic 2.
        let aliased = ResponseParsing.parseDiagnosis(#"{"scores":{"output contract":{"note":"vague","score":1},"success criteria":{"score":3},"goal":2}}"#)
        check("parse: axis names are aliased to canonical",
              aliased.scores["deliverable"]?.score == 1 && aliased.scores["criteria"]?.score == 3
                && aliased.scores["goal"]?.score == 2,
              aliased.scores.keys.sorted().joined(separator: ","))
        check("parse: an unmatchable axis is not invented",
              aliased.scores["output_contract"] == nil)

        // The repair guard decides whether the user keeps the repaired prompt. It used to
        // compare weighted scores, which discarded repairs that fixed what they were asked to
        // fix. Pure function, so every branch is testable here.
        func report(_ spec: [(PromptLinter.Issue.Severity, String)]) -> PromptLinter.Report {
            var r = PromptLinter.Report()
            r.checksRun = 19
            r.issues = spec.map { PromptLinter.Issue(id: $0.1, severity: $0.0,
                                                     title: $0.1, detail: "", fix: "") }
            return r
        }
        let clean = report([])
        let minorAfter = report([(.minor, "shouting")])
        let majorAfter = report([(.major, "vague-criteria")])
        let blockerAfter = report([(.blocker, "section:output")])
        let oneBlocker = report([(.blocker, "section:output")])
        let twoMajors = report([(.major, "vague-criteria"), (.major, "section:context")])
        let oneMajorTwoMinors = report([(.major, "vague-criteria"), (.minor, "shouting"),
                                        (.minor, "too-thin")])
        let threeMajors = report([(.major, "a"), (.major, "b"), (.major, "c")])

        // The bug this replaced: a repair that fixed something invisible to the linter and added
        // two words past a ceiling scored 97 < 100 and was thrown away.
        check("repair guard: a minor does not veto a repair",
              RepairGuard.judge(before: clean, after: minorAfter, revised: "text") == .accept)
        check("repair guard: a clean prompt made unclean is kept",
              RepairGuard.judge(before: clean, after: majorAfter, revised: "text")
                == .revert(.brokeClean))
        check("repair guard: a new blocker is discarded",
              RepairGuard.judge(before: clean, after: blockerAfter, revised: "text")
                == .revert(.gainedBlocker))
        check("repair guard: closing a blocker survives new minors",
              RepairGuard.judge(before: oneBlocker, after: minorAfter, revised: "text") == .accept)
        check("repair guard: fixing one major and adding two minors is progress",
              RepairGuard.judge(before: twoMajors, after: oneMajorTwoMinors, revised: "text") == .accept)
        check("repair guard: more majors than before is not progress",
              RepairGuard.judge(before: twoMajors, after: threeMajors, revised: "text")
                == .revert(.gainedMajor))
        check("repair guard: an empty repair is discarded",
              RepairGuard.judge(before: clean, after: clean, revised: "   ") == .revert(.empty))
        check("repair guard: a clean prompt stays clean",
              RepairGuard.judge(before: clean, after: clean, revised: "text") == .accept)

        // The gate's findings must reach the repair stage, or a prompt the linter rejects ships
        // because the critic said "ship".
        var ship = Critique()
        ship.verdict = "ship"
        let fromGate = RepairGuard.issues(critique: ship, lint: majorAfter)
        check("repair guard: gate majors reach repair when the critic says ship",
              fromGate.count == 1 && fromGate[0].axis == "criteria", "\(fromGate.count)")
        check("repair guard: gate minors alone do not trigger repair",
              RepairGuard.issues(critique: ship, lint: minorAfter).isEmpty)
        check("repair guard: a clean gate and a shipping critic trigger nothing",
              RepairGuard.issues(critique: ship, lint: clean).isEmpty)

        // The critic and the gate both name the same missing section. The repair prompt must show
        // it once. An id-based dedup never matched, because the gate has no quote.
        var both = Critique()
        both.verdict = "repair"
        both.issues = [CritiqueIssue(axis: "deliverable", severity: .blocker, quote: "the text",
                                     problem: "Missing output contract section: no heading",
                                     fix: "Add one.")]
        let deduped = RepairGuard.issues(critique: both, lint: report([(.blocker, "missing-output contract")]))
        check("repair guard: a defect both reviewers name appears once",
              deduped.count == 1, "\(deduped.count)")

        // The writer was handed all twelve principles regardless of target, so a chat message was
        // told to write autonomy sections by principle 8 and told to omit them by its own target
        // guidance. Two orders, one message, and the model had to guess.
        let chatWriter = MetaPrompts.writer(target: .chat)
        let agentWriter = MetaPrompts.writer(target: .agentTask)
        check("prompts: a chat writer is not told to write autonomy",
              !chatWriter.contains("Default to acting"))
        check("prompts: an agent writer is told to write autonomy",
              agentWriter.contains("Default to acting"))
        check("prompts: the principle count matches the axes the target is scored on",
              chatWriter.contains("exactly these \(Axis.applicable(to: .chat).count),")
                && agentWriter.contains("exactly these \(Axis.applicable(to: .agentTask).count),"))

        // Every emitted lint id must resolve to an axis. The table once keyed on `section:` and on
        // ids no check constructed, so seven issue types all reported `consistency`.
        // Built from the real section table, so renaming a section cannot silently unmoor its axis.
        var emitted = ["fence", "preamble", "filler", "shouting", "placeholders", "silent-defaults",
                       "format-conflict", "limit-conflict-words", "meta", "too-short", "too-long",
                       "copy", "unbounded", "executed", "vague-criteria"]
        for target in PromptTarget.allCases {
            emitted += PromptLinter.requiredSections(for: target).map { "missing-\($0.0)" }
        }
        let unmapped = emitted.filter { id in
            let issue = PromptLinter.Issue(id: id, severity: .major, title: "", detail: "", fix: "")
            // `consistency` is the fallback, so a mapping that lands there proves nothing unless
            // the id genuinely defends consistency.
            // These defend consistency genuinely: a system prompt's behaviour section is where
            // rule pairs live, so "missing behaviour" really is a consistency finding.
            let honestConsistency = ["format-conflict", "limit-conflict-words", "missing-behaviour"]
            return issue.axis == "consistency" && !honestConsistency.contains(id)
        }
        check("linter: every emitted issue id maps to its own axis", unmapped.isEmpty,
              unmapped.joined(separator: ","))

        // The exemplars are few-shot training data for the writer. If one fails the gate the
        // writer is taught a shape the tool then rejects — that happened, and nothing caught it.
        for target in PromptTarget.allCases {
            let r = PromptLinter.lint(target.exemplar, target: target, unansweredQuestions: 0)
            check("exemplar passes the gate: \(target.rawValue)", r.isClean,
                  r.issues.map { $0.id }.joined(separator: ","))
        }

        // Two deliverables with two formats is one contract, not a contradiction.
        let twoArtefacts = syntheticPrompt(.agentTask)
            + "\nProduce the record in Markdown, and emit a JSON summary alongside it.\n"
        let r6a = PromptLinter.lint(twoArtefacts, target: .agentTask, unansweredQuestions: 0)
        check("linter: two artefacts with two formats are allowed",
              !r6a.issues.contains { $0.id == "format-conflict" },
              r6a.issues.map(\.id).joined(separator: ","))

        // Two parts of one deliverable may each carry a budget.
        let perPart = syntheticPrompt(.agentTask)
            + "\nThe summary must be at least 300 words; the appendix at most 200 words.\n"
        let r6b = PromptLinter.lint(perPart, target: .agentTask, unansweredQuestions: 0)
        check("linter: per-part budgets are not a conflict",
              !r6b.issues.contains { $0.id == "limit-conflict" },
              r6b.issues.map(\.id).joined(separator: ","))

        // A named human reviewer is a legitimate instrument.
        let human = syntheticPrompt(.agentTask)
            + "\nA colleague who has not seen the page can name which plan suits a two-person team.\n"
        let r6c = PromptLinter.lint(human, target: .agentTask, unansweredQuestions: 0)
        check("linter: a human-checkable criterion passes",
              !r6c.issues.contains { $0.id == "vague-criteria" },
              r6c.issues.map(\.id).joined(separator: ","))

        // A verb is not an output contract: "can you write something that fixes it" constrains nothing.
        let noContract = "Can you write something that fixes the flaky test? It fails one run in ten and I am out of ideas."
        let r6d = PromptLinter.lint(noContract, target: .chat, unansweredQuestions: 0)
        check("linter: a chat message needs a bound, not a verb",
              r6d.issues.contains { $0.id == "missing-output contract" },
              r6d.issues.map(\.id).joined(separator: ","))

        // A complete one-step task is short by nature; the floor must not call it a failure.
        let oneStep = """
        # Fix the flaky retry test

        ## Objective
        Make `TestRetry` stop failing intermittently.

        ## Context
        It fails roughly one run in ten and always at the same assertion.

        ## Requirements
        - Find the shared state between subtests and remove it.

        ## Output contract
        One commit, English, under 100 words. No changelog entry.

        ## Success criteria
        `go test -run TestRetry -count=20 ./...` returns 0.

        ## Verification
        Run that command and paste the final line.
        """
        let r6e = PromptLinter.lint(oneStep, target: .agentTask, unansweredQuestions: 0)
        check("linter: a tight one-step task is not too thin", r6e.isClean,
              r6e.issues.map { $0.id }.joined(separator: ","))

        let mush = "hello there, just wondering if you could maybe help me out a bit with something"
        let r5f = PromptLinter.lint(mush, target: .chat, unansweredQuestions: 0)
        check("linter: a contentless chat message still fails", !r5f.isClean)

        let shouting = syntheticPrompt(.agentTask) + "\nTHIS IS CRITICAL AND YOU MUST COMPLY ALWAYS.\n"
        let r6 = PromptLinter.lint(shouting, target: .agentTask, unansweredQuestions: 0)
        check("linter: shouting is a minor", r6.minors.contains { $0.id == "shouting" })

        let thin = "# Task\nDo it."
        let r7 = PromptLinter.lint(thin, target: .agentTask, unansweredQuestions: 0)
        check("linter: thin prompt is too short", r7.issues.contains { $0.id == "too-short" })

        let copy = syntheticPrompt(.agentTask)
        let r8 = PromptLinter.lint(copy, target: .agentTask, unansweredQuestions: 0, draft: copy)
        check("linter: verbatim copy flagged", r8.issues.contains { $0.id == "copy" })

        let empty = PromptLinter.lint("", target: .chat, unansweredQuestions: 0)
        check("linter: empty output is a blocker", empty.blockers.first?.id == "empty")

        // MARK: Pipeline shape

        check("rigor: fast skips verification", !Rigor.fast.verifies && !Rigor.fast.repairs)
        check("rigor: standard verifies", Rigor.standard.verifies && Rigor.standard.repairs)
        check("rigor: deep writes tests", Rigor.deep.writesTests)
        check("prompts: writer names the rubric axes", MetaPrompts.writer(target: .agentTask).contains("Success criteria"))
        check("prompts: analyzer carries the defect taxonomy", MetaPrompts.analyzer(target: .agentTask).contains("D02"))
        check("prompts: critic carries the contradiction rule",
              MetaPrompts.critic(target: .agentTask).contains("contradiction"))
        check("prompts: repair forbids appending",
              MetaPrompts.repair.contains("Fix by replacing, not appending"))

        // MARK: Report

        let total = passes + failures.count
        for (name, detail) in failures {
            print("  FAIL  \(name)" + (detail.isEmpty ? "" : "  [\(detail)]"))
        }
        print("\(passes)/\(total) checks passed" + (failures.isEmpty ? " — all green" : " — \(failures.count) failing"))
        return failures.isEmpty ? 0 : 1
    }

    /// A prompt built from the target's own advertised skeleton. If the linter rejects this, the
    /// writer is being told to produce something the app then marks as broken.
    static func syntheticPrompt(_ target: PromptTarget) -> String {
        // A chat message has no headings. Building the fixture with headings hid a real defect:
        // the section checks demanded markdown of a prose target and passed only the fixture.
        if target == .chat {
            return """
            Draft a one-paragraph summary of the attached incident report, then list the three decisions \
            it leaves open. Reply in plain prose, under 150 words, and quote the report for every claim \
            you make. If the report does not state a cause, write that the cause is unstated rather than \
            inferring one. Return the summary first and the list after it, with no preamble and no sign-off.
            """
        }
        var lines = ["# Synthetic prompt for \(target.rawValue)", ""]
        for line in target.skeleton.components(separatedBy: "\n") {
            let heading = line.trimmingCharacters(in: .whitespaces)
            guard heading.hasPrefix("#") else { continue }
            lines.append(heading)
            let title = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
            if title.contains("success") || title.contains("done") {
                lines.append("- Every claim carries a source URL and the check returns 200 on a second run.")
            } else {
                lines.append("The executor reads the supplied material first and then acts on it with the tools available to it.")
                lines.append("When a fact is missing it records the gap rather than inventing a plausible value for it.")
                lines.append("Each requirement below exists because a real decision depends on it being satisfied.")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - CLI helpers

    static func lintFile(_ path: String, target: PromptTarget = .agentTask, unanswered: Int = 0) -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
            return 2
        }
        // The target changes which sections are required, so it has to be selectable: a chat
        // message linted as an agent task fails on headings it was never meant to have.
        let report = PromptLinter.lint(text, target: target, unansweredQuestions: unanswered)
        print("structure \(report.score)/100 — \(report.summary)")
        for i in report.issues {
            print("  [\(i.severity.rawValue)] \(i.title): \(i.detail)")
            if !i.fix.isEmpty { print("      fix: \(i.fix)") }
        }
        return report.isClean ? 0 : 1
    }

    /// Prints every system prompt with a rough token estimate, so prompt edits can be reviewed as
    /// diffs instead of guessed at.
    static func dumpPrompts() {
        let items: [(String, String)] = [
            ("analyzer[agent]", MetaPrompts.analyzer(target: .agentTask)),
            ("writer[agent]", MetaPrompts.writer(target: .agentTask)),
            ("writer[chat]", MetaPrompts.writer(target: .chat)),
            ("critic[agent]", MetaPrompts.critic(target: .agentTask)),
            ("repair", MetaPrompts.repair),
            ("tests", MetaPrompts.evalSuite(target: .agentTask)),
        ]
        var total = 0
        for (name, body) in items {
            let tokens = body.count / 4
            total += tokens
            print("── \(name) — ~\(tokens) tokens, \(body.count) chars")
        }
        print("total ≈ \(total) tokens of system prompt")
    }
}
