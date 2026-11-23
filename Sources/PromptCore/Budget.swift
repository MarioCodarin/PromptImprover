import Foundation

/// How much time and output one run may spend. Every model call carries it.
///
/// The pipeline used to have no ceiling at all: a 600 s idle timeout per attempt, three retries,
/// five or six sequential stages, no `max_tokens` on the chat-completions wire. A gateway that held
/// the socket open without sending a byte was indistinguishable from a slow model, and the panel
/// said "Checking it against the rubric…" for as long as the user was willing to watch.
///
/// Two limits, because they catch different failures:
/// - `stallTimeout` catches a dead stream: no byte for this long and the attempt is abandoned
///   (and retried, if the deadline still allows it).
/// - `deadline` catches a slow run: past it, no new call starts and the call in flight is cut,
///   and the pipeline returns the best prompt it already has.
public struct Budget: Sendable {
    public var deadline: Date
    /// Silence allowed *between* chunks, once the reply has started.
    public var stallTimeout: TimeInterval
    /// Silence allowed before the first line. Much longer, because chat-completions gateways send
    /// nothing while a reasoning model thinks; 45 s here cut (and re-billed) legitimate thinking.
    public var firstByteTimeout: TimeInterval

    public init(deadline: Date, stallTimeout: TimeInterval = 45, firstByteTimeout: TimeInterval = 180) {
        self.deadline = deadline
        self.stallTimeout = stallTimeout
        self.firstByteTimeout = firstByteTimeout
    }

    /// Seconds left, never negative.
    public var remaining: TimeInterval { max(0, deadline.timeIntervalSinceNow) }
    public var isExpired: Bool { remaining <= 0 }

    /// Defaults per depth. Sized for a reasoning model on a busy gateway, not for a best case:
    /// a deadline that fires on ordinary runs teaches the user to ignore it.
    public static func `for`(_ rigor: Rigor, from start: Date = Date()) -> Budget {
        let seconds: TimeInterval
        switch rigor {
        case .fast: seconds = 60
        case .standard: seconds = 150
        case .deep: seconds = 300
        }
        return Budget(deadline: start.addingTimeInterval(seconds))
    }

    /// No deadline; the stall limits still apply. Used by refine, one call the user is watching.
    public static func unbounded() -> Budget {
        Budget(deadline: .distantFuture)
    }
}

/// The model calls the pipeline can make. Each one has its own output ceiling and effort, because
/// a small JSON verdict and a 900-word prompt are not the same job.
public enum CallKind: String, Sendable, CaseIterable {
    case clarify, write, repair, critique, tests, refine

    /// Output ceiling, sent on the Anthropic wire only (where `max_tokens` is required anyway).
    /// Roughly twice the largest reply each stage should produce. Not sent on chat-completions:
    /// many gateways count reasoning tokens inside `max_tokens`, so a 1200-token clarify came back
    /// empty and truncated. There the deadline bounds a runaway reply instead.
    public var maxTokens: Int {
        switch self {
        case .clarify: return 1200
        case .write, .repair, .refine: return 4000
        case .critique: return 1500
        case .tests: return 2000
        }
    }

    /// Classification and review do not need deep reasoning; writing does. Lowering effort on the
    /// three JSON stages is where most of the wall-clock saving comes from on a reasoning model.
    public var prefersLowEffort: Bool {
        switch self {
        case .clarify, .critique, .tests: return true
        case .write, .repair, .refine: return false
        }
    }

    public var isJSON: Bool { self == .clarify || self == .critique || self == .tests }

    /// The effort to send: the user's, lowered to "low" for JSON stages — never raised. "off",
    /// "low", "none", "minimal" and unknown values pass through as the user set them.
    public func effort(from user: String?) -> String? {
        guard let user, prefersLowEffort else { return user }
        return ["medium", "high", "xhigh", "max"].contains(user.lowercased()) ? "low" : user
    }
}
