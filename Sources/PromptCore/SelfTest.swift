import Foundation

/// Offline checks for everything that decides output quality but does not need a network call:
/// the rubric maths, the tolerant JSON parsers, the brief composer, and every linter rule.
///
/// Run with `PromptImprover --selftest`. Exit code 0 means the app's own gate still passes its own
/// examples — the one thing that must never silently rot when a prompt is edited.
public enum SelfTest {

    public static func run() -> Int32 {
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

        // A score says how far the prompt is from the bar; the weakest axes say where. Ordered by
        // score then axis order, so the same marks always name the same axes in the same order.
        // `rest` fills the axes the test does not care about: an axis left out of the dict scores
        // the generic 2, so a half-built fixture would test the default rather than the rule.
        func scored(_ marks: [Axis: Int], rest: Int = 4) -> Diagnosis {
            var all = Dictionary(uniqueKeysWithValues: Axis.allCases.map {
                ($0.rawValue, AxisVerdict(score: rest, note: ""))
            })
            for (axis, score) in marks { all[axis.rawValue] = AxisVerdict(score: score, note: "") }
            return Diagnosis(scores: all)
        }
        let tied = scored([.deliverable: 0, .consistency: 1, .criteria: 2, .inputs: 2])
            .weakestAxes(for: .agentTask, limit: 4)
        check("rubric: weakest axes are the marked-down ones, worst first",
              tied == [.deliverable, .consistency, .inputs, .criteria],
              "got \(tied.map(\.rawValue))")
        check("rubric: ties keep axis order",
              scored([.goal: 2, .economy: 2]).weakestAxes(for: .agentTask) == [.goal, .economy],
              "got \(scored([.goal: 2, .economy: 2]).weakestAxes(for: .agentTask).map(\.rawValue))")
        // An omitted axis is an assumption, not a measurement. It was listed under both headings:
        // "Scored without: Context, Inputs, Deliverable" then "Below the bar: Context, Inputs,
        // Deliverable" — the second presenting the generic default as a mark the critic made.
        let partial = scored([.goal: 1])
        check("rubric: an unscored axis is not also named as weak",
              !partial.weakestAxes(for: .agentTask).contains(.context),
              "got \(partial.weakestAxes(for: .agentTask).map(\.rawValue))")
        check("rubric: a scored weak axis is still named",
              partial.weakestAxes(for: .agentTask) == [.goal],
              "got \(partial.weakestAxes(for: .agentTask).map(\.rawValue))")

        check("rubric: nothing below the bar names nothing",
              scored([:]).weakestAxes(for: .agentTask).isEmpty,
              "got \(scored([:]).weakestAxes(for: .agentTask).map(\.rawValue))")
        check("rubric: an axis the critic omitted is counted as generic, not as good",
              scored([.goal: 4], rest: 2).weakestAxes(for: .chat).first == .context,
              "got \(scored([.goal: 4], rest: 2).weakestAxes(for: .chat).map(\.rawValue))")

        // The critic's spread is measured, not assumed: 90, 80, 84 and 73 on identical text. A
        // comparison inside it is the instrument moving, so it is reported as no change rather
        // than as a small win or a small regression.
        check("rubric: a 17-point gap is inside the measured spread",
              RubricNoise.delta(from: 90, to: 73) == .withinNoise)
        check("rubric: 18 points is a real change",
              RubricNoise.delta(from: 90, to: 72) == .worse(-18))
        check("rubric: a real gain is named as a gain",
              RubricNoise.delta(from: 70, to: 95) == .better(25))
        check("rubric: a one-point move is not a finding",
              RubricNoise.delta(from: 80, to: 81) == .withinNoise)

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

        // The extractor committed to the first `{` in the text. One brace pair in prose — a
        // placeholder, a shape sketch, an example object before the answer — consumed the single
        // attempt, and every consumer then degraded silently: the diagnosis came back all-default,
        // so the writer ran blind with no findings and no questions.
        let braceFirst = #"Here is the shape: {format, length}. Now: {"brief":"b","findings":[]}"#
        check("json: a brace pair in prose does not consume the attempt",
              ResponseParsing.jsonObject(from: braceFirst)?["brief"] as? String == "b",
              String(describing: ResponseParsing.jsonObject(from: braceFirst)))
        check("json: a placeholder before the answer is skipped",
              ResponseParsing.parseDiagnosis(#"Filling {{name}} and {x}. {"brief":"real","risk":"high"}"#).brief == "real")
        check("json: a trailing comma before a closing brace is tolerated",
              ResponseParsing.jsonObject(from: #"{"a":1,"b":[1,2,],}"#)?["a"] as? Int == 1)
        check("json: a trailing comma inside a string is left alone",
              ResponseParsing.jsonObject(from: #"{"a":"x,}y"}"#)?["a"] as? String == "x,}y")
        // A schema example is legal JSON, so "first parseable object" returned the example and
        // dropped the answer. The diagnosis came back empty with risk "low", and the critique came
        // back `ship` with no issues — a prompt the critic never scored was treated as passing.
        let schemaFirst = #"Your reply must be a JSON object with this shape: {"brief": "", "findings": [], "questions": []}"#
            + "\n\nNow the analysis: " + #"{"brief": "The draft names no audience.", "risk": "high", "findings": [{"code": "D01", "quote": "make me a page"}]}"#
        let dSchema = ResponseParsing.parseDiagnosis(schemaFirst)
        check("json: a schema example before the diagnosis does not win",
              dSchema.brief == "The draft names no audience." && dSchema.risk == "high"
                  && dSchema.findings.count == 1,
              "brief=[\(dSchema.brief)] risk=\(dSchema.risk) findings=\(dSchema.findings.count)")
        let emptyFirst = ResponseParsing.parseDiagnosis(#"Reply with {} when there is nothing to say. {"brief": "real", "risk": "high"}"#)
        check("json: an empty object before the answer does not win",
              emptyFirst.brief == "real", "brief=[\(emptyFirst.brief)]")
        let critiqueExample = #"Shape: {"verdict": "ship", "issues": []}"# + "\nActual: "
            + #"{"verdict": "repair", "issues": [{"axis": "criteria", "problem": "No threshold.", "severity": "major"}]}"#
        let cExample = ResponseParsing.parseCritique(critiqueExample)
        check("json: a critique schema example does not become the verdict",
              cExample?.verdict == "repair" && cExample?.issues.count == 1,
              "verdict=\(cExample?.verdict ?? "nil") issues=\(cExample?.issues.count ?? -1)")
        // The fix must not swing the other way: a genuine "ship, nothing wrong" is empty-looking
        // and still has to parse, or every clean prompt reads as an unreadable verdict.
        let genuineShip = ResponseParsing.parseCritique(#"{"verdict": "ship", "issues": [], "summary": "Tight and specific."}"#)
        check("json: a genuine ship with no issues still parses",
              genuineShip?.verdict == "ship" && genuineShip?.summary == "Tight and specific.",
              "verdict=\(genuineShip?.verdict ?? "nil")")
        check("json: a truncated object returns nil rather than a partial",
              ResponseParsing.jsonObject(from: #"{"a":1, "b": {"c":2}"#) == nil)

        // A stray brace in prose used to latch the depth counter and kill every later candidate.
        // One unmatched `}` drove it to -1, after which no opener was ever offered; one unmatched
        // `{` left it at 1, so the real object closed to 1 and never to 0. Either way the diagnosis
        // silently degraded to all-defaults and the writer ran with no findings and no questions.
        check("json: a stray closer before the answer does not latch the scanner",
              ResponseParsing.jsonObject(from: "Here } is the analysis:\n{\"a\":1}")?["a"] as? Int == 1)
        check("json: a stray closer mid-prose does not latch the scanner",
              ResponseParsing.jsonObject(from: "Clamp it to 0 } and retry.\n{\"a\":1}")?["a"] as? Int == 1)
        check("json: two stray closers do not latch the scanner",
              ResponseParsing.jsonObject(from: "}} before the object\n{\"a\":1}")?["a"] as? Int == 1)
        check("json: a stray closer in a fence does not latch the scanner",
              ResponseParsing.jsonObject(from: "```\n} oops\n```\n{\"a\":1}")?["a"] as? Int == 1)

        // The taxonomy is keyed on upper-case codes. A lower-case code was labelled minor in the
        // list while the title reported a blocker — one finding, two severities.
        let lowerCode = ResponseParsing.parseDiagnosis(#"{"findings":[{"code":"d07","quote":"x","fix":"y"}]}"#)
        check("parse: a lower-case defect code still resolves its severity",
              lowerCode.findings.first?.severity == Defect.severity(for: "D07"),
              String(describing: lowerCode.findings.first?.severity))
        check("parse: the code is normalised",
              lowerCode.findings.first?.code == "D07")

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

        // An unparseable critic reply must not switch the gate off. Both callers used to drop the
        // whole repair decision when the critique failed to parse, so one stray brace in the
        // critic's prose disabled the deterministic half of the gate — the half that exists
        // precisely because the critic cannot be trusted. An empty critique says nothing, which
        // leaves the gate's blockers and majors as the only issues.
        check("repair guard: an unparseable critique still lets the gate through",
              RepairGuard.issues(critique: Critique(), lint: majorAfter).count == 1)
        check("repair guard: an unparseable critique with a clean gate repairs nothing",
              RepairGuard.issues(critique: Critique(), lint: clean).isEmpty)
        check("repair guard: an unparseable critique does not veto a blocker",
              RepairGuard.issues(critique: Critique(), lint: blockerAfter).contains {
                  $0.severity == .blocker
              })

        // A clean prompt must not be sent to repair over polish. There is nothing to aim at, so the
        // model rewrites for the sake of rewriting: a live run took 100/100 and returned 97/100,
        // accepted because minors never veto.
        var polish = Critique()
        polish.verdict = "repair"
        polish.issues = [CritiqueIssue(axis: "economy", severity: .minor, quote: "a line",
                                       problem: "slightly wordy", fix: "cut it")]
        check("repair guard: polish does not send a clean prompt to repair",
              RepairGuard.issues(critique: polish, lint: clean).isEmpty)

        // But a clean prompt the critic finds unusable still goes: that is the fabrication the
        // linter cannot see, and skipping it would ship the one failure this tool exists to catch.
        var fabricates = Critique()
        fabricates.verdict = "repair"
        fabricates.issues = [CritiqueIssue(axis: "context", severity: .blocker, quote: "12% of users",
                                           problem: "invented statistic", fix: "mark it a placeholder")]
        check("repair guard: a critic blocker still repairs a clean prompt",
              RepairGuard.issues(critique: fabricates, lint: clean).count == 1)

        // On a prompt the gate already rejects, critic minors are kept: the call is happening
        // anyway, so they cost nothing and the model may as well fix them.
        var minorsOnDirty = Critique()
        minorsOnDirty.verdict = "repair"
        minorsOnDirty.issues = [CritiqueIssue(axis: "economy", severity: .minor, quote: "a line",
                                              problem: "slightly wordy", fix: "cut it")]
        check("repair guard: critic minors survive on a prompt the gate already rejects",
              RepairGuard.issues(critique: minorsOnDirty, lint: majorAfter).count == 2)

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
              chatWriter.contains("\(Axis.applicable(to: .chat).count) principles.")
                && agentWriter.contains("\(Axis.applicable(to: .agentTask).count) principles."))

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

        // MARK: Linter — false positives that were shipping
        //
        // Every case below is a *correct* prompt that the gate failed. This is the expensive kind
        // of bug in a gate: it spends a repair call and tells the operator a good prompt is
        // broken, which is how a gate stops being read. Each line is a real repro that fired.
        func notFlagged(_ label: String, _ id: String, _ text: String,
                        _ target: PromptTarget = .agentTask, unanswered: Int = 0) {
            let r = PromptLinter.lint(text, target: target, unansweredQuestions: unanswered)
            check("linter: \(label)", !r.issues.contains { $0.id == id },
                  r.issues.map(\.id).joined(separator: ","))
        }
        func flagged(_ label: String, _ id: String, _ text: String, _ target: PromptTarget = .agentTask) {
            let r = PromptLinter.lint(text, target: target, unansweredQuestions: 0)
            check("linter: \(label)", r.issues.contains { $0.id == id },
                  r.issues.map(\.id).joined(separator: ","))
        }

        // A pasted artefact is the subject of the request, not a handover of the answer. The
        // handover test scanned the whole message, so every chat prompt quoting an error, a diff
        // or a contract text was called "the result, not a prompt".
        let pastedError = """
        Here is the error our checkout page throws on Safari:

        TypeError: undefined is not an object (evaluating 'cart.items.map')

        Fix the cause and tell me in two sentences what was wrong. Plain prose, under 100 words, \
        no preamble and no sign-off.
        """
        notFlagged("a pasted error is the subject, not the answer", "executed", pastedError, .chat)
        notFlagged("a pasted draft to rewrite is not meta", "meta",
                   "I've written a first draft of the customer reply below. Rewrite it in a plainer "
                   + "voice, same facts, under 120 words, plain prose, no sign-off.", .chat)
        notFlagged("a pasted draft is not a handover", "executed",
                   "I've written a first draft of the customer reply below. Rewrite it in a plainer "
                   + "voice, same facts, under 120 words, plain prose, no sign-off.", .chat)
        // The positive control: a real handover still fails.
        flagged("a genuine handover is still caught", "executed",
                "Here's your rewritten reply: Dear customer, we have reviewed your case and the "
                + "refund is on its way. Hope this helps. Let me know if you have questions.", .chat)

        // A prompt that quotes a banned phrase in order to forbid it is not using it.
        let forbidding = syntheticPrompt(.systemPrompt) + """
        Never open with "As an AI language model I cannot" — you are the support assistant and you \
        can look at the account.
        """
        notFlagged("a quoted phrase the prompt forbids is not meta", "meta", forbidding, .systemPrompt)
        notFlagged("a quoted phrase the prompt forbids is not filler", "filler", forbidding, .systemPrompt)

        // A chat turn is short by nature, but not contentless. The floor is 30 words, which is
        // about one substantive sentence plus its constraints; below that the message is missing
        // something, and a lower floor let "Can you help me with this thing, under 100 words
        // please?" through the whole gate on the word "words" alone.
        notFlagged("a complete chat message is not too thin", "too-short",
                   "Summarise the attached incident report in three bullets, plain prose, under 150 "
                   + "words, no preamble and no sign-off. Quote the report for every claim you make, "
                   + "and say the cause is unstated if the report does not give one.", .chat)
        flagged("a contentless chat message is still too thin", "too-short",
                "Can you help me with this thing, under 100 words please?", .chat)

        // Bold pseudo-headings are headings. Demanding `##` reported five missing sections and a
        // score of 0 on a prompt that had all five.
        let bold = """
        **Objective**
        Stop the nightly export from timing out on tenants with more than 50k rows.

        **Context**
        The export job hits a 30 second statement timeout. Two tenants complained last week.

        **Requirements**
        - Stream rows in batches of 5,000 instead of loading the whole table.

        **Output contract**
        One pull request, English, under 200 words.

        **Success criteria**
        - The 50k-row tenant fixture finishes in under 30 seconds.
        """
        let boldReport = PromptLinter.lint(bold, target: .agentTask, unansweredQuestions: 0)
        check("linter: a bolded section title is a section", boldReport.isClean,
              boldReport.issues.map(\.id).joined(separator: ","))

        // The other direction: a document that uses `##` is using bold for emphasis, so a bolded
        // sentence inside a section must not be read as the next title. Reading it as one ended
        // the section body early and made the entries below it invisible.
        // Written out rather than patched onto the synthetic prompt: the fixture has to isolate the
        // one property under test. The bold line carries no "I chose" either, because that phrase
        // is the inline-assumption escape and would satisfy the check for the wrong reason.
        let boldInside = """
        ## Objective
        Stop the nightly export from timing out on tenants with more than 50k rows.

        ## Context
        The export job hits a 30 second statement timeout on the largest tenant.

        ## Requirements
        - Stream rows in batches instead of loading the whole table.

        ## Assumptions
        **Two week window with no customer impact**
        - Two-week window, no customer impact claimed.
        - No deadline was named in the request.

        ## Output contract
        One pull request, English, under 200 words.

        ## Success criteria
        - The 50k-row tenant fixture finishes in under 30 seconds.
        """
        let boldInsideReport = PromptLinter.lint(boldInside, target: .agentTask, unansweredQuestions: 2)
        check("linter: bold emphasis inside a markdown section is not a title",
              !boldInsideReport.issues.contains { $0.id == "silent-defaults" },
              boldInsideReport.issues.map(\.id).joined(separator: ","))

        // A labelled line has to match the way headings match. `hasPrefix` made "Definition of
        // done:" — a phrase this very table lists as a criteria keyword — unreachable.
        notFlagged("a qualified label still names its section", "missing-success criteria",
                   syntheticPrompt(.agentTask) + "\nDefinition of done: every test in the package "
                   + "passes and the diff stays under 300 lines.\n")

        // The decline escape only worked when it was not needed: it read the body of a heading
        // that had already matched. A decline has to be readable on its own line.
        notFlagged("an explicit decline on its own line counts", "missing-context",
                   "No context needed: the module list is in the repository and the task is "
                   + "self-contained.\n" + syntheticPrompt(.agentTask)
                       .replacingOccurrences(of: "## Context", with: "## Notes"))

        // Prose criteria with no command in them are still checkable by a second person.
        notFlagged("prose criteria are checkable", "vague-criteria",
                   syntheticPrompt(.agentTask) + "\nEvery screen names the next action in its heading.\n")

        // A conditional second format is the sanctioned resolution, not a conflict.
        notFlagged("a conditional second format is not a conflict", "format-conflict",
                   syntheticPrompt(.systemPrompt) + "\nIf the customer asks for the line items, "
                   + "return them as CSV so they can paste them into a spreadsheet.\n", .systemPrompt)
        // An input format named beside an output verb is not a second deliverable.
        notFlagged("an input format is not a second deliverable", "format-conflict",
                   syntheticPrompt(.agentTask) + "\nRead the schema in JSON and write the migration "
                   + "that adds the export table.\n")

        // Two artefacts, two budgets, no contradiction.
        notFlagged("a budget per artefact is not a conflict", "limit-conflict-words",
                   syntheticPrompt(.agentTask) + "\nTwo files: the user guide needs at least 800 "
                   + "words, and the release note stays under 200 words.\n")

        // The heading path accepts "defaults" and "decisions"; the prose path accepted only
        // "assumption", so a message that recorded its decisions was told it had recorded none.
        notFlagged("a recorded default answers the question", "silent-defaults",
                   syntheticPrompt(.chat) + " Defaults: two-week remediation window, no customer "
                   + "impact claimed.", .chat, unanswered: 2)
        notFlagged("a bulleted assumption list is read", "silent-defaults",
                   syntheticPrompt(.chat) + "\nAssumptions:\n\u{2022} two-week remediation window\n"
                   + "\u{2022} no customer impact claimed", .chat, unanswered: 2)

        // Domain acronyms and identifiers are not shouting. Two adjacent acronyms used to be a
        // "run", and `_` split an identifier into one.
        notFlagged("two acronyms are not shouting", "shouting",
                   syntheticPrompt(.agentTask) + "\nThe DNS TTL is 300 seconds, so plan for a slow failover.\n")
        notFlagged("an env var name is not shouting", "shouting",
                   syntheticPrompt(.agentTask) + "\nSet STRIPE_SECRET_KEY before running the suite.\n")
        notFlagged("a table header is not shouting", "shouting",
                   syntheticPrompt(.agentTask) + "\n| SOURCE | TARGET |\n| --- | --- |\n")

        // A prefix is not a word. "Surefire" is a Maven plugin and "Greater" opens a comparison.
        notFlagged("a word that starts like an opener is not one", "preamble",
                   "Surefire reports are flaky under parallel builds.\n" + syntheticPrompt(.agentTask))
        notFlagged("a comparison is not a preamble", "preamble",
                   "Greater than three retries on a 4xx is a bug.\n" + syntheticPrompt(.agentTask))

        // Every one of these fields is required by the deliverable, in a ~110-word letter.
        notFlagged("a template's required fields are not filler", "placeholders",
                   syntheticPrompt(.agentTask) + """
                   - Address it to {{CLIENT NAME}} at {{CLIENT ADDRESS}}.
                   - Name {{ACCOUNT MANAGER}} as the contact.
                   - State the term start {{START DATE}} and the term end {{END DATE}}.
                   - Quote the annual fee {{ANNUAL FEE}} and the uplift {{UPLIFT PERCENT}}.
                   """)

        // The product can be the subject matter the deliverable must carry.
        notFlagged("the product's own adjective is not filler", "filler",
                   syntheticPrompt(.agentTask) + "\nAnnounce the cutting-edge imaging sensor to the "
                   + "existing customer list.\n")
        // The positive control: persona theatre still fails.
        flagged("persona theatre is still filler", "filler",
                syntheticPrompt(.agentTask) + "\nYou are an expert world-class copywriter.\n")

        // Pasted source is not restatement.
        let pastedLong = syntheticPrompt(.chat) + "\n\n```\n"
            + Array(repeating: "the report states a cause that the evidence does not support", count: 90)
                .joined(separator: "\n")
            + "\n```"
        notFlagged("pasted source is not padding", "too-long", pastedLong, .chat)

        // "as needed" can be the bound rather than the absence of one.
        notFlagged("a bounded 'as needed' is bounded", "unbounded",
                   syntheticPrompt(.agentTask) + "\n- Scale the pool as needed between four and "
                   + "sixteen workers on queue depth.\n")

        let copy = syntheticPrompt(.agentTask)
        let r8 = PromptLinter.lint(copy, target: .agentTask, unansweredQuestions: 0, draft: copy)
        check("linter: verbatim copy flagged", r8.issues.contains { $0.id == "copy" })

        let empty = PromptLinter.lint("", target: .chat, unansweredQuestions: 0)
        check("linter: empty output is a blocker", empty.blockers.first?.id == "empty")

        // MARK: Gate integrity
        //
        // Every narrowing above exists to stop a false positive, and each one is an escape a
        // defect can walk through. These are the attacks: for each escape, the input that would
        // slip past the gate if the narrowing went one step too far. A reviewer found all of
        // them in one pass over the diff, which is the argument for keeping them here.

        let good = syntheticPrompt(.agentTask)

        // Two fixtures need real surgery rather than a patch, so they are written out. Patching the
        // synthetic prompt with `replacingOccurrences` silently matched nothing when its skeleton
        // changed, and the test then passed by asserting against the unmodified prompt.
        let qualityOnly = """
        # Add a retry budget to the webhook sender

        ## Objective
        Stop the sender from dropping events when a receiver is unavailable.

        ## Context
        Receivers time out during their own deploys and the event is lost.

        ## Requirements
        Retry three times with exponential backoff, and mark the row delivered only on 2xx.

        ## Output contract
        One pull request, English, under 200 words, with a unified diff.

        ## Success criteria
        Each section is well written and looks professional.
        Every part is clear and engaging.

        ## Verification
        Run the package tests and paste the last ten lines of output.
        """

        let negatedLabel = """
        # Add a retry budget to the webhook sender

        ## Objective
        Stop the sender from dropping events when a receiver is unavailable.

        ## Context
        Receivers time out during their own deploys and the event is lost.

        ## Requirements
        Retry three times with exponential backoff, and mark the row delivered only on 2xx.

        No output format: produce whatever reads best.

        ## Success criteria
        The timeouts fixture produces three attempts and `go test` exits 0.

        ## Verification
        Run the package tests and paste the last ten lines of output.
        """

        // `partWords` used to skip any *line* naming a part, which silenced the canonical
        // contradiction whenever both bounds mentioned the same artefact. A bound is now scoped
        // to the artefact named nearest before it, so the same artefact must still conflict.
        flagged("limits: two bounds on one artefact still conflict", "limit-conflict-words",
                good + "\nKeep the email under 250 words. The email must be at least 600 words.\n")
        flagged("limits: a substring is not the same artefact", "limit-conflict-words",
                good + "\nKeep the profile under 250 words. The report must be at least 600 words.\n")
        notFlagged("limits: two artefacts with their own budgets do not conflict",
                   "limit-conflict-words",
                   good + "\nThe user guide needs at least 800 words; the release note stays under 200.\n")
        // The canonical contradiction, written the way a person writes it: the second sentence uses
        // a pronoun for the artefact the first one named. No part token is in the window, so the
        // two bounds landed in different groups and the conflict was invisible.
        flagged("limits: a pronoun inherits the artefact it stands for", "limit-conflict-words",
                good + "\nThe email must be at least 600 words.\nKeep it under 250 words.\n")
        // A format belongs to an artefact the same way a word bound does. Two formats on two
        // deliverables is one contract each, not a contradiction.
        notFlagged("formats: two artefacts with their own formats do not conflict",
                   "format-conflict",
                   good + "\nReturn the summary as JSON, and the appendix as a Markdown file.\n")
        flagged("formats: two formats on one artefact still conflict", "format-conflict",
                good + "\nReturn the report as Markdown, and also as JSON.\n")

        // A bolded sub-title inside a section must not empty the section body. Ending a section at
        // the next heading of any kind switched off every check that reads the body.
        let subTitled = """
        # Add a retry budget to the webhook sender

        ## Objective
        Stop the sender from dropping events when a receiver is unavailable.

        ## Context
        Receivers time out during their own deploys and the event is lost.

        ## Requirements
        Retry three times with exponential backoff, and mark the row delivered only on 2xx.

        ## Output contract
        One pull request, English, under 200 words, with a unified diff.

        ## Success criteria
        **Quality bar**
        - It should be high quality and thorough.
        - The result must be excellent.

        ## Verification
        Run the package tests and paste the last ten lines of output.
        """
        flagged("sections: a bold sub-title does not empty the section", "vague-criteria", subTitled)

        // A title above a delivered reply is still a delivered reply.
        flagged("executed: a title does not disguise a handover", "executed",
                "Rewritten reply, under 100 words:\n\nHere is the reply you asked for: Dear customer, "
                + "we have reviewed your case and the refund is on its way.", .chat)
        // "write back if you need anything" is a closing pleasantry, not a request, so it must not
        // exempt the delivery it closes.
        flagged("executed: a closing 'write back' does not exempt a handover", "executed",
                "Here's your summary: the payment worker lost messages for 40 minutes because the "
                + "retry queue was drained. Write back if you need anything.", .chat)
        notFlagged("executed: a request quoting an artefact is not a handover", "executed",
                   "Here is the reply our support team sent, in full: Dear customer, we have reviewed "
                   + "your case. Rewrite it so it does not promise a date, keep it under 100 words, "
                   + "plain prose, no preamble, and do not apologise twice.", .chat)

        // `none` is a substring of `nonetheless`. The line has to carry an alternative as well —
        // that is the mechanism: the decline test needs both a section keyword and a decline word
        // on one line, and "nonetheless" satisfied the second half of that pair.
        let nonetheless = """
        # Add a retry budget to the webhook sender

        ## Objective
        Stop the sender from dropping events when a receiver is unavailable.

        Nonetheless the context here is unclear and you will have to guess at it.

        ## Requirements
        Retry three times with exponential backoff, and mark the row delivered only on 2xx.

        ## Output contract
        One pull request, English, under 200 words, with a unified diff.

        ## Success criteria
        The timeouts fixture produces three attempts and `go test` exits 0.

        ## Verification
        Run the package tests and paste the last ten lines of output.
        """
        flagged("sections: nonetheless is not a decline", "missing-context", nonetheless)
        // A label that denies the section is not evidence of one.
        let negatedReport = PromptLinter.lint(negatedLabel, target: .agentTask, unansweredQuestions: 0)
        check("linter: sections: a negated label does not satisfy the section",
              negatedReport.issues.contains { $0.id == "missing-output contract" },
              negatedReport.issues.map(\.id).joined(separator: ","))

        // Adjective theatre is padding whatever else is on the line.
        flagged("filler: a stack of product adjectives is filler", "filler",
                good + "\nThe tone is world-class, cutting-edge and best-in-class throughout.\n")
        notFlagged("filler: a product adjective naming the subject is not filler", "filler",
                   good + "\nAnnounce the cutting-edge imaging sensor in the release note.\n")

        // A quantifier is not a measurement.
        flagged("criteria: a quantified quality judgement is not checkable", "vague-criteria", qualityOnly)

        // Underscored caps and table bodies are still emphasis.
        flagged("shouting: an underscored caps sentence is shouting", "shouting",
                good + "\nDO_NOT_EVER_SHIP_THIS_WITHOUT_ASKING_ME_FIRST.\n")
        flagged("shouting: a table body is still scanned", "shouting",
                good + "\n| RULE | DETAIL |\n| --- | --- |\n| NEVER EVER SHIP THIS | unrecoverable |\n")
        // A standard's name is two adjacent caps tokens, which is exactly the run rule. A live run
        // failed a correct accessibility requirement for it.
        notFlagged("shouting: a standard's name is not emphasis", "shouting",
                   good + "\nText contrast meets WCAG AA on every surface.\n")
        flagged("shouting: real emphasis still fires", "shouting",
                good + "\nMUST READ THIS before you ship anything at all.\n")
        notFlagged("shouting: a table header is not shouting", "shouting",
                   good + "\n| SOURCE | TARGET |\n| --- | --- |\n| a | b |\n")
        notFlagged("shouting: an identifier is not shouting", "shouting",
                   good + "\nRead STRIPE_SECRET_KEY from the environment.\n")

        // "and also" is not a choice; an output verb plus "in <format>" is a declaration.
        flagged("formats: and-also is not an either-or", "format-conflict",
                good + "\nReturn the output as JSON if you can, and also as CSV.\n")
        flagged("formats: an output verb plus in-format declares", "format-conflict",
                good + "\nOutput the results in JSON. Output the log in CSV.\n")
        notFlagged("formats: a conditional choosing between them is fine", "format-conflict",
                   good + "\nReturn JSON by default, or CSV when the caller asks for it.\n")

        // Density, not just an absolute count.
        flagged("placeholders: eight fields in forty words is a skeleton", "placeholders",
                "Draft the renewal letter to {{CLIENT NAME}} at {{CLIENT ADDRESS}}, naming "
                + "{{ACCOUNT MANAGER}} as contact. State the start {{START DATE}} and end "
                + "{{END DATE}}, the fee {{ANNUAL FEE}} and uplift {{UPLIFT}}, and the notice "
                + "period {{NOTICE}}. Plain prose, under 200 words, no preamble.", .chat)

        // A label that hands the choice back records nothing.
        let deferred = good.replacingOccurrences(of: "## Context", with: "## Notes") + "\nDecisions: whatever you think is best.\n"
        check("linter: a deferred decision is not a recorded one",
              PromptLinter.lint(deferred, target: .agentTask, unansweredQuestions: 2)
                  .issues.contains { $0.id == "silent-defaults" })

        // "never assume a brand name" is the gap-handling instruction the list exists to exclude,
        // written with the verb the list keys on. A negation in front means no decision was made.
        let negatedAssume = """
        Draft the product page copy for a new coffee subscription. There are no product details,
        brand assets, testimonials or pricing in the brief. Do not invent pricing and never assume
        a brand name. Keep the copy under 200 words, plain prose, no preamble and no sign-off.
        """
        check("linter: 'never assume' is not a recorded decision",
              PromptLinter.lint(negatedAssume, target: .chat, unansweredQuestions: 3)
                  .issues.contains { $0.id == "silent-defaults" },
              "recorded nothing about the open questions")

        // A prompt is written in the imperative, so a recording phrased in the second person —
        // "Assume a developer will replace the placeholders" — was invisible to a check that only
        // knew first-person narration. A live run was failed for not recording decisions it had
        // recorded, in the correct voice.
        let imperativeRecord = """
        Draft the release note for the new dashboard, in plain prose, under 150 words, no preamble
        and no sign-off. Assume the reader saw the old dashboard and needs the delta only. Name the
        owner as a field to fill in rather than guessing one.
        """
        check("linter: an imperative assumption counts as a recorded decision",
              !PromptLinter.lint(imperativeRecord, target: .chat, unansweredQuestions: 3)
                  .issues.contains { $0.id == "silent-defaults" },
              PromptLinter.lint(imperativeRecord, target: .chat, unansweredQuestions: 3)
                  .issues.map(\.id).joined(separator: ","))
        // A gap-handling instruction is an output constraint, not a decision: it says what not to
        // do when a value is missing, not which value was chosen.
        check("linter: a gap-handling constraint is not a recorded decision",
              PromptLinter.lint(imperativeRecord.replacingOccurrences(
                                    of: "Assume the reader saw the old dashboard and needs the delta only.", with: ""),
                                target: .chat, unansweredQuestions: 3)
                  .issues.contains { $0.id == "silent-defaults" },
              "recorded nothing about the open questions")
        // The heading `## Assumptions` is the section's name, not evidence of an entry in it.
        let bareHeading = good.replacingOccurrences(of: "## Context", with: "## Notes")
            + "\nDecisions: whatever you think is best.\n"
        check("linter: an empty assumptions heading is not a recorded decision",
              PromptLinter.lint(bareHeading, target: .agentTask, unansweredQuestions: 2)
                  .issues.contains { $0.id == "silent-defaults" },
              PromptLinter.lint(bareHeading, target: .agentTask, unansweredQuestions: 2)
                  .issues.map(\.id).joined(separator: ","))

        // A bound elsewhere in the sentence does not bound the phrase.
        flagged("effort: a number in another clause does not bound it", "unbounded",
                good + "\nRead the surrounding modules as much as possible, and keep the diff under 300 lines.\n")

        // An inch mark is not a quote.
        flagged("meta: an inch mark does not hide a handover phrase", "meta",
                good + "\nThe card width is 12\" and hope this helps you pick a 6\" gutter for the grid.\n")

        // A title plus bold sections is the commonest model output shape.
        let titleAndBold = """
        # Add a retry budget to the webhook sender
        **Objective** Stop the sender from dropping events when a receiver is unavailable.
        **Context** Receivers time out during their own deploys and the event is lost.
        **Inputs** `internal/webhook/sender.go` and the timeouts fixture.
        **Requirements** Retry three times with exponential backoff; mark the row delivered on 2xx.
        **Constraints and non-goals** Do not change the outbox schema. Ordering is out of scope.
        **Approach** Wrap the POST in a loop and keep the backoff pure so it is testable.
        **Output contract** One pull request, English, under 200 words, with a unified diff.
        **Success criteria** The fixture produces three attempts and `go test` exits 0.
        **Verification** Run the package tests and paste the last ten lines of output.
        **Priorities when instructions conflict** Correctness, then diff size, then speed.
        **Autonomy and escalation** Ask before touching anything outside `internal/webhook/`.
        """
        check("linter: a title plus bold sections is a complete prompt",
              PromptLinter.lint(titleAndBold, target: .agentTask, unansweredQuestions: 0).isClean,
              PromptLinter.lint(titleAndBold, target: .agentTask, unansweredQuestions: 0)
                  .issues.map(\.id).joined(separator: ","))

        // A bulleted label list is a real way to write the sections.
        let bulletedLabels = """
        - Objective: Stop the sender from dropping events when a receiver is unavailable.
        - Context: Receivers time out during their own deploys and the event is lost.
        - Inputs: `internal/webhook/sender.go` and the timeouts fixture.
        - Requirements: Retry three times with exponential backoff; mark the row delivered on 2xx.
        - Constraints and non-goals: Do not change the outbox schema. Ordering is out of scope.
        - Approach: Wrap the POST in a loop and keep the backoff pure so it is testable.
        - Output contract: One pull request, English, under 200 words, with a unified diff.
        - Success criteria: The fixture produces three attempts and `go test` exits 0.
        - Verification: Run the package tests and paste the last ten lines of output.
        - Priorities when instructions conflict: Correctness, then diff size, then speed.
        - Autonomy and escalation: Ask before touching anything outside `internal/webhook/`.
        """
        check("linter: a bulleted label list is a complete prompt",
              PromptLinter.lint(bulletedLabels, target: .agentTask, unansweredQuestions: 0).isClean,
              PromptLinter.lint(bulletedLabels, target: .agentTask, unansweredQuestions: 0)
                  .issues.map(\.id).joined(separator: ","))

        // A quoted phrase the prompt forbids is not the prompt using it — including the
        // product-adjective family, which read the raw lines instead of the stripped text.
        notFlagged("filler: a quoted forbidden adjective is not filler", "filler",
                   good + "\nNever describe the sensor as \"cutting-edge\": the copy should be plain.\n")

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

    public static func lintFile(_ path: String, target: PromptTarget = .agentTask, unanswered: Int = 0) -> Int32 {
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
    /// Prints every system prompt in full, with a token estimate.
    ///
    /// The point of this command is `diff` — the README tells contributors to run it before and
    /// after a prompt edit and read the result as a code change. It printed only a name and a
    /// token count, so there was nothing to diff, and it covered six of the twelve builders, so
    /// half the prompts could change without appearing at all.
    public static func dumpPrompts() {
        var items: [(String, String)] = []
        for target in PromptTarget.allCases {
            let slug = target.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            items.append(("analyzer[\(slug)]", MetaPrompts.analyzer(target: target)))
            items.append(("writer[\(slug)]", MetaPrompts.writer(target: target)))
            items.append(("critic[\(slug)]", MetaPrompts.critic(target: target)))
            items.append(("tests[\(slug)]", MetaPrompts.evalSuite(target: target)))
        }
        items.append(("repair", MetaPrompts.repair))
        items.append(("refine", MetaPrompts.refineInstruction("<the user's revision instruction>")))
        var total = 0
        for (name, body) in items {
            let tokens = body.count / 4
            total += tokens
            // Fenced and delimited so the output diffs cleanly and a prompt containing its own
            // headings cannot be mistaken for the next section's header.
            print("═══ \(name) — ~\(tokens) tokens, \(body.count) chars ═══")
            print(body)
            print("")
        }
        print("total ≈ \(total) tokens of system prompt across \(items.count) prompts")
    }
}
