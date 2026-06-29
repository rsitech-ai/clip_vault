import Foundation

public struct SensitiveClassification: Hashable, Sendable {
    public var isExcluded: Bool
    public var reason: String?

    public init(isExcluded: Bool, reason: String? = nil) {
        self.isExcluded = isExcluded
        self.reason = reason
    }
}

public struct SensitiveRule: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var pattern: String

    public init(id: String, label: String, pattern: String) {
        self.id = id
        self.label = label
        self.pattern = pattern
    }
}

public struct SensitiveRuleEngine: Sendable {
    public var rules: [SensitiveRule]

    public init(rules: [SensitiveRule] = SensitiveRuleEngine.defaultRules) {
        self.rules = rules
    }

    public static let `default` = SensitiveRuleEngine()

    public func classify(_ text: String) -> SensitiveClassification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SensitiveClassification(isExcluded: false)
        }

        for rule in rules {
            if trimmed.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return SensitiveClassification(isExcluded: true, reason: rule.label)
            }
        }

        return SensitiveClassification(isExcluded: false)
    }

    public static let defaultRules: [SensitiveRule] = [
        SensitiveRule(
            id: "private-key",
            label: "Private key",
            pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#
        ),
        SensitiveRule(
            id: "openai-key",
            label: "OpenAI-style API key",
            pattern: #"\bsk-(proj-)?[A-Za-z0-9_-]{20,}\b"#
        ),
        SensitiveRule(
            id: "github-token",
            label: "GitHub token",
            pattern: #"\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b"#
        ),
        SensitiveRule(
            id: "aws-access-key",
            label: "AWS access key",
            pattern: #"\b(A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}\b"#
        ),
        SensitiveRule(
            id: "jwt",
            label: "JWT token",
            pattern: #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#
        ),
        SensitiveRule(
            id: "password-assignment",
            label: "Password-like assignment",
            pattern: #"\b(password|passwd|pwd|secret|token|api[_-]?key)\s*[:=]\s*['\"]?[^'\"\s]{10,}"#
        )
    ]
}
