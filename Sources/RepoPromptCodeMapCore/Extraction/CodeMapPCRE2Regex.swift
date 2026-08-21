//
//  CodeMapPCRE2Regex.swift
//  RepoPrompt
//
//  Thin regex helpers for developer-authored codemap regex constants.
//

import Foundation

struct CodeMapPCRE2Match {
    private let captures: [String?]

    init(subject: String, match: NSTextCheckingResult) {
        captures = (0 ..< match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let stringRange = Range(range, in: subject) else {
                return nil
            }
            return String(subject[stringRange])
        }
    }

    func capture(_ index: Int) -> String? {
        guard index >= 0, index < captures.count else { return nil }
        return captures[index]
    }

    func trimmedCapture(_ index: Int) -> String? {
        capture(index)?.trimmingCharacters(in: .whitespaces)
    }
}

struct CodeMapPCRE2Pattern {
    private let pattern: String
    private let regex: NSRegularExpression

    init(
        _ pattern: String,
        caseInsensitive: Bool = false,
        multilineAnchors: Bool = false,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        var options: NSRegularExpression.Options = []
        if caseInsensitive {
            options.insert(.caseInsensitive)
        }
        if multilineAnchors {
            options.insert(.anchorsMatchLines)
        }

        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
            self.pattern = pattern
        } catch {
            preconditionFailure("Invalid codemap regex pattern at \(file):\(line): \(error)")
        }
    }

    func firstMatch(in text: String) -> CodeMapPCRE2Match? {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return CodeMapPCRE2Match(subject: text, match: match)
    }

    func firstCapture(_ index: Int = 1, in text: String) -> String? {
        firstMatch(in: text)?.capture(index)
    }

    func trimmedCapture(_ index: Int = 1, in text: String) -> String? {
        firstMatch(in: text)?.trimmedCapture(index)
    }

    func matches(_ text: String) -> Bool {
        firstMatch(in: text) != nil
    }

    func wholeMatch(in text: String) -> Bool {
        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: fullRange) else { return false }
        return match.range == fullRange
    }

    func replacingMatches(in text: String, with replacement: String = "") -> String {
        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var output = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else {
                preconditionFailure("Codemap regex replacement produced an invalid range for pattern \(pattern)")
            }
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }
}
