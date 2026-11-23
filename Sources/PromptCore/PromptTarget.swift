import Foundation

public enum PromptTarget: String, CaseIterable, Identifiable {
    case agentTask = "Agent task"
    case systemPrompt = "System prompt"
    case chat = "Chat message"
    public var id: String { rawValue }

    /// What the writer must know about the medium it is writing for.
    public var guidance: String {
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
            sections: a chat turn is not an agent run.
            """
        }
    }

    /// The length envelope the structural check enforces, stated to the writer so it can aim.
    public var lengthTarget: String {
        switch self {
        case .agentTask: return "under 900 words; a one-step task may be 150. Never pad to reach a floor"
        case .systemPrompt: return "under 800 words; a durable-principles prompt may be 250. Never pad to reach a floor"
        case .chat: return "under 300 words, usually 80 to 200"
        }
    }

    /// A worked example in this target's own shape.
    ///
    /// One exemplar served all three targets before, and its shape was the agent-task skeleton —
    /// so a system prompt and a chat message were shown sections they are told to drop, and the
    /// agent one failed the rubric it was modelling (no stopping condition per phase, no action
    /// classes with reasons). Each example below scores 4 on the axes it demonstrates.
    public var exemplar: String {
        switch self {
        case .agentTask:
            return """
            The example shows the shape, not the content. Never reuse its subject, numbers or wording.

            # Add a retry budget to the outbound webhook sender

            ## Objective
            Stop the sender retrying a dead endpoint forever. Two incidents this quarter came from a worker \
            pinned on a 404 for six hours: the queue backed up and every other tenant stalled behind it.

            ## Context
            Tenants configure their own endpoints and about 2% are abandoned each quarter. The sender \
            currently retries every failure until the job times out, which is what pinned the worker.

            ## Inputs
            - `internal/webhook/sender.go` — the retry loop.
            - `docs/webhooks.md` — the delivery contract we promised clients.

            ## Requirements
            - Cap retries at 5 attempts, backoff 2s to 60s, jittered by 20%.
            - Treat 4xx except 429 as permanent: one attempt, no retry.
            - Emit a counter per outcome so queue depth is observable.

            ## Constraints and non-goals
            - The public `Send` signature stays as it is unless you confirm first. It is visible to \
            every caller, so changing it is not reversible in review.
            - Out of scope: the consumer side, and any change to the retry policy of other senders.
            - Budget: one pull request, under 300 changed lines.

            ## Approach
            1. Read the sender and the contract. Stop once you can name every retry branch.
            2. Put the budget behind the existing loop. Stop when all three cases above are handled.
            3. Add table tests for permanent, transient and exhausted. Stop when all three fail against \
            the old code.
            Skip step 3 if the package already has a table-driven retry test; extend it instead.

            ## Output contract
            One pull request. Description naming the files, the tests and the rollback step, English, \
            under 250 words. Do not include a changelog entry or a migration note; neither applies.

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

            You are a triage assistant for a support queue. You classify inbound tickets and draft the \
            first reply, so a human reviews instead of starting from nothing.

            ## Purpose
            A reviewer should be able to accept or reject your draft in one read. The reader is \
            already frustrated by the time they write, so your reply assumes good faith and answers \
            the question that was asked, not the one that is easiest to answer.

            ## How you work
            Read everything the ticket links before writing. Classify first, then draft: a draft \
            written before the classification tends to answer the wrong question.
            When a ticket names an amount, a date or an identifier, use the one on the linked record \
            and nothing else.

            ## Priorities when instructions conflict
            In order, highest first: never state a fact you cannot see on a linked record > never \
            promise an outcome you cannot authorise > answer the question asked > be brief. When two \
            of these conflict, the higher one wins and you say in one line what you could not do.

            ## Output contract
            Two fields: `category`, a single lowercase word from the queue's own taxonomy; `reply`, \
            plain prose under 120 words with no greeting formula and no sign-off. Do not include an \
            apology for the delay.

            ## Boundaries
            Never state a policy that is not in the linked documentation. Never close, merge or \
            reassign a ticket. If a ticket is abusive, answer it once, factually, and flag it for a \
            human rather than disengaging.

            ## Assumptions
            - Ticket text and linked records are the only signal; no call recording or chat history exists.
            - The queue's taxonomy is supplied at runtime; if it is missing, ask for it rather than
              inventing a category.
            """
        case .chat:
            return """
            The example shows the shape, not the content. Never reuse its subject or wording.

            Summarise the incident report below in one paragraph, then list the three decisions it leaves \
            open. Plain prose, under 150 words, no preamble and no closing offer to help further. Quote \
            the report for every claim you make, and keep quotes under fifteen words. If it does not \
            state a cause, write that the cause is unstated rather than inferring one. If the report is \
            missing a timeline, say so in the list of open decisions instead of reconstructing one.
            """
        }
    }

    /// Section skeleton the writer is told to adapt. Empty sections get dropped, not filled.
    public var skeleton: String {
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
