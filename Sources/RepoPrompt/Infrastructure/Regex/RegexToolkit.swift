import Foundation

/// Umbrella protocol for all regex pattern failures.
public protocol RegexPatternFailure: LocalizedError {}

enum SearchPatternErrorFormatter {
    static func parts(for pattern: String, isRegex: Bool, error: SearchPatternError) -> (issue: String, suggestion: String?) {
        let base = error.localizedDescription
        switch error {
        case .unmatchedParentheses:
            if isRegex {
                return (base, "Unmatched parentheses. Balance each '(' with a ')' or escape literal parentheses as '\\\\(' and '\\\\)'.")
            }
            return (base, "You're in literal mode. Parentheses match as regular characters; if you meant regex operators, set regex=true.")
        case .unmatchedBrackets:
            if isRegex {
                return (base, "Missing closing bracket ']' in the character class. Close it or escape literal '[' as '\\\\['.")
            }
            return (base, "Literal search interprets '[' as plain text. To build character classes, enable regex=true.")
        case .invalidEscape:
            if isRegex {
                return (base, "Invalid escape sequence. Use '\\\\\\\\' for a literal backslash, or double-escape special characters like '\\\\('.")
            }
            return (base, "Backslashes are literal in regex=false mode. Remove extra escapes or enable regex=true for regex syntax.")
        case .invalidQuantifier:
            if isRegex {
                return (base, "Quantifiers like '*', '+', and '{n}' need a token before them. Add a leading '.' or escape the character with '\\\\*'.")
            }
            return (base, "Literal search treats '*' as a normal character. If you intended a wildcard, enable regex=true or escape with '\\\\*'.")
        case let .invalidRegex(_, details):
            let issue = "Invalid regex pattern. \(details)"
            if isVariableLengthLookbehindError(pattern: pattern, details: details) {
                return (
                    issue,
                    "Use a fixed-width lookbehind, or rewrite the search as a line-level lookahead. For example, to find GetComponent only on lines that do not contain //, use `(?m)^(?!.*\\/\\/).*GetComponent`."
                )
            }
            if isRegex {
                return (issue, "Review the pattern for typos or unmatched groups. Escape literal characters with '\\\\'.")
            }
            return (issue, "If you intended to use regex features, set regex=true. Otherwise remove regex-only syntax.")
        case .emptyAlternative:
            return (base, "Remove extra '|' characters or provide content on both sides of the alternation.")
        }
    }

    private static func isVariableLengthLookbehindError(pattern: String, details: String) -> Bool {
        guard pattern.contains("(?<=") || pattern.contains("(?<!") else { return false }
        let normalized = details.lowercased()
        return normalized.contains("lookbehind") && (
            normalized.contains("fixed length")
                || normalized.contains("not fixed")
                || normalized.contains("variable")
                || normalized.contains("bounded")
                || normalized.contains("not limited")
                || normalized.contains("maximum length")
        )
    }
}

/// Errors specific to search patterns.
public enum SearchPatternError: Error, LocalizedError, RegexPatternFailure {
    case unmatchedParentheses(String)
    case unmatchedBrackets(String)
    case invalidEscape(String)
    case invalidQuantifier(String)
    case invalidRegex(String, String)
    case emptyAlternative(String)

    public var errorDescription: String? {
        switch self {
        case let .unmatchedParentheses(pattern):
            "Unmatched parentheses in pattern: '\(pattern)'. Check that all '(' have matching ')'."
        case let .unmatchedBrackets(pattern):
            "Unmatched brackets in pattern: '\(pattern)'. Check that all '[' have matching ']'."
        case let .invalidEscape(pattern):
            "Invalid escape sequence in pattern: '\(pattern)'. Use '\\\\' for literal backslash."
        case let .invalidQuantifier(pattern):
            "Invalid quantifier in pattern: '\(pattern)'. Check syntax like {n,m} or *+?."
        case let .invalidRegex(pattern, details):
            "Invalid regex pattern: '\(pattern)'. \(details)"
        case let .emptyAlternative(pattern):
            "Empty alternative in pattern: '\(pattern)'. Remove extra '|' characters."
        }
    }
}

/// Hard guards to avoid catastrophic regex compilation/back-tracking.
public struct SearchPatternTooComplexError: Error, LocalizedError, RegexPatternFailure {
    public var errorDescription: String? {
        """
        Search pattern was rejected because it is either excessively large \
        or shaped in a way that is known to cause catastrophic back-tracking \
        in the regex engine. Please simplify the pattern or rewrite it \
        using non-nested quantifiers.
        """
    }
}
