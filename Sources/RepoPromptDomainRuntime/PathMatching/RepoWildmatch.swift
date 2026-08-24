/*
 * Copyright (c), 2016 David Aguilar
 * Based on the fnmatch implementation from OpenBSD.
 *
 * Copyright (c) 1989, 1993, 1994
 *  The Regents of the University of California.  All rights reserved.
 *
 * This code is derived from software contributed to Berkeley by
 * Guido van Rossum.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the University nor the names of its contributors
 *    may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

package struct RepoWildmatchOptions: OptionSet {
    package let rawValue: UInt32

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package static let noEscape = RepoWildmatchOptions(rawValue: 0x01)
    package static let pathname = RepoWildmatchOptions(rawValue: 0x02)
    package static let period = RepoWildmatchOptions(rawValue: 0x04)
    package static let leadingDir = RepoWildmatchOptions(rawValue: 0x08)
    package static let caseFold = RepoWildmatchOptions(rawValue: 0x10)
    package static let prefixDirs = RepoWildmatchOptions(rawValue: 0x20)
    package static let wildstar = RepoWildmatchOptions(rawValue: 0x40)
}

package enum RepoWildmatch {
    package static func matches(
        pattern: String,
        text: String,
        options: RepoWildmatchOptions = []
    ) -> Bool {
        matches(
            pattern: PathMatchingCString.bytes(of: pattern),
            text: PathMatchingCString.bytes(of: text),
            options: options
        )
    }

    package static func gitignoreMatchesAnchored(pattern: String, path: String) -> Bool {
        let patternBytes = PathMatchingCString.bytes(of: pattern)
        let pathBytes = PathMatchingCString.bytes(of: path)

        if pathBytes.isEmpty {
            return patternBytes == PathMatchingCString.doubleStar
        }

        return matches(
            pattern: patternBytes,
            text: pathBytes,
            options: gitignoreOptions(for: patternBytes)
        )
    }

    package static func gitignoreMatchesAnywhere(pattern: String, path: String) -> Bool {
        let patternBytes = PathMatchingCString.bytes(of: pattern)
        let pathBytes = PathMatchingCString.bytes(of: path)

        if pathBytes.isEmpty {
            return patternBytes == PathMatchingCString.doubleStar
        }
        if patternBytes == PathMatchingCString.doubleStar {
            return true
        }

        let options = gitignoreOptions(for: patternBytes)
        if !patternBytes.contains(PathMatchingCString.slash) {
            return matchEachBasename(pattern: patternBytes, path: pathBytes, options: options)
        }

        if patternBytes.suffix(3).elementsEqual(PathMatchingCString.slashDoubleStar) {
            let basePattern = Array(patternBytes.dropLast(3))
            if !basePattern.isEmpty,
               basePattern.count < 1024,
               matchEachSubpath(pattern: basePattern, path: pathBytes, options: options)
            {
                return true
            }
        }

        return matchEachSubpath(pattern: patternBytes, path: pathBytes, options: options)
    }

    private static func matches(
        pattern: [UInt8],
        text: [UInt8],
        options: RepoWildmatchOptions
    ) -> Bool {
        RepoWildmatchMatcher(pattern: pattern, text: text).matches(options: options)
    }

    private static func gitignoreOptions(for pattern: [UInt8]) -> RepoWildmatchOptions {
        var options: RepoWildmatchOptions = [.pathname, .noEscape]
        if hasGlobstar(pattern) {
            options.insert(.wildstar)
        }
        return options
    }

    private static func hasGlobstar(_ pattern: [UInt8]) -> Bool {
        if pattern == PathMatchingCString.doubleStar || pattern.starts(with: PathMatchingCString.doubleStarSlash) {
            return true
        }

        guard pattern.count >= 3 else { return false }
        for index in 0 ... pattern.count - 3 where
            pattern[index] == PathMatchingCString.slash &&
            pattern[index + 1] == PathMatchingCString.star &&
            pattern[index + 2] == PathMatchingCString.star
        {
            let following = index + 3
            if following == pattern.count || pattern[following] == PathMatchingCString.slash {
                return true
            }
        }
        return false
    }

    private static func matchEachBasename(
        pattern: [UInt8],
        path: [UInt8],
        options: RepoWildmatchOptions
    ) -> Bool {
        var componentStart = 0
        while componentStart < path.count {
            let slash = path[componentStart...].firstIndex(of: PathMatchingCString.slash)
            let componentEnd = slash ?? path.endIndex
            let componentLength = componentEnd - componentStart
            guard componentLength < 1024 else { return false }

            if matches(
                pattern: pattern,
                text: Array(path[componentStart ..< componentEnd]),
                options: options
            ) {
                return true
            }

            guard let slash else { break }
            componentStart = slash + 1
        }
        return false
    }

    private static func matchEachSubpath(
        pattern: [UInt8],
        path: [UInt8],
        options: RepoWildmatchOptions
    ) -> Bool {
        var subpathStart = 0
        while subpathStart < path.count {
            if matches(
                pattern: pattern,
                text: Array(path[subpathStart...]),
                options: options
            ) {
                return true
            }

            guard let slash = path[subpathStart...].firstIndex(of: PathMatchingCString.slash) else {
                break
            }
            subpathStart = slash + 1
        }
        return false
    }
}

enum PathMatchingCString {
    static let slash: UInt8 = 0x2F
    static let star: UInt8 = 0x2A
    static let doubleStar: [UInt8] = [star, star]
    static let doubleStarSlash: [UInt8] = [star, star, slash]
    static let slashDoubleStar: [UInt8] = [slash, star, star]

    static func bytes(of string: String) -> [UInt8] {
        Array(string.utf8.prefix { $0 != 0 })
    }
}

private final class RepoWildmatchMatcher {
    private struct MemoKey: Hashable {
        let patternIndex: Int
        let textIndex: Int
        let options: UInt32
    }

    private enum RangeResult {
        case matched(nextPatternIndex: Int)
        case noMatch
        case malformed
    }

    private let pattern: [UInt8]
    private let text: [UInt8]
    private var memo: [MemoKey: Bool] = [:]

    init(pattern: [UInt8], text: [UInt8]) {
        self.pattern = pattern
        self.text = text
    }

    func matches(options: RepoWildmatchOptions) -> Bool {
        match(patternIndex: 0, textIndex: 0, options: options)
    }

    private func match(
        patternIndex: Int,
        textIndex: Int,
        options originalOptions: RepoWildmatchOptions
    ) -> Bool {
        var options = originalOptions
        if options.contains(.wildstar) {
            options.insert(.pathname)
        }

        let key = MemoKey(
            patternIndex: patternIndex,
            textIndex: textIndex,
            options: options.rawValue
        )
        if let cached = memo[key] {
            return cached
        }

        let result = matchUncached(
            patternIndex: patternIndex,
            textIndex: textIndex,
            options: options
        )
        memo[key] = result
        return result
    }

    private func matchUncached(
        patternIndex startPatternIndex: Int,
        textIndex startTextIndex: Int,
        options: RepoWildmatchOptions
    ) -> Bool {
        var patternIndex = startPatternIndex
        var textIndex = startTextIndex
        let textStart = startTextIndex

        while true {
            var character = patternByte(at: patternIndex)
            patternIndex += 1

            switch character {
            case 0:
                if options.contains(.leadingDir), textByte(at: textIndex) == PathMatchingCString.slash {
                    return true
                }
                return textByte(at: textIndex) == 0

            case asciiQuestionMark:
                let current = textByte(at: textIndex)
                if current == 0 || current == PathMatchingCString.slash && options.contains(.pathname) {
                    return false
                }
                if isProtectedPeriod(at: textIndex, textStart: textStart, options: options) {
                    return false
                }
                textIndex += 1

            case PathMatchingCString.star:
                character = patternByte(at: patternIndex)
                let isWildstar = options.contains(.wildstar) && character == PathMatchingCString.star
                var previous: UInt8 = patternIndex >= 2 ? patternByte(at: patternIndex - 2) : 0

                if isWildstar {
                    while character == PathMatchingCString.star {
                        patternIndex += 1
                        character = patternByte(at: patternIndex)
                    }

                    while character == PathMatchingCString.slash,
                          patternByte(at: patternIndex + 1) == PathMatchingCString.star,
                          patternByte(at: patternIndex + 2) == PathMatchingCString.star
                    {
                        previous = character
                        patternIndex += 1
                        character = patternByte(at: patternIndex)
                        while character == PathMatchingCString.star {
                            patternIndex += 1
                            character = patternByte(at: patternIndex)
                        }
                    }

                    if character == PathMatchingCString.slash,
                       match(
                           patternIndex: patternIndex + 1,
                           textIndex: textIndex,
                           options: options
                       )
                    {
                        return true
                    }
                } else {
                    while character == PathMatchingCString.star {
                        patternIndex += 1
                        character = patternByte(at: patternIndex)
                    }
                }

                if !isWildstar,
                   isProtectedPeriod(at: textIndex, textStart: textStart, options: options)
                {
                    return false
                }

                if character == 0 {
                    if isWildstar, previous == PathMatchingCString.slash {
                        return true
                    }
                    if options.contains(.pathname) {
                        return options.contains(.leadingDir) || firstSlash(inTextFrom: textIndex) == nil
                    }
                    return true
                } else if character == PathMatchingCString.slash {
                    if isWildstar {
                        var slash = firstSlash(inTextFrom: textStart)
                        while let currentSlash = slash {
                            if match(
                                patternIndex: patternIndex + 1,
                                textIndex: currentSlash + 1,
                                options: options
                            ) {
                                return true
                            }
                            slash = firstSlash(inTextFrom: currentSlash + 1)
                        }
                    } else if options.contains(.pathname) {
                        guard let slash = firstSlash(inTextFrom: textIndex) else {
                            return false
                        }
                        textIndex = slash
                    }
                } else if isWildstar {
                    return false
                }

                let recursiveOptions = RepoWildmatchOptions(
                    rawValue: options.rawValue & ~RepoWildmatchOptions.period.rawValue
                )
                while textByte(at: textIndex) != 0 {
                    let current = textByte(at: textIndex)
                    if match(
                        patternIndex: patternIndex,
                        textIndex: textIndex,
                        options: recursiveOptions
                    ) {
                        return true
                    }
                    if current == PathMatchingCString.slash, options.contains(.pathname) {
                        break
                    }
                    textIndex += 1
                }
                return false

            case asciiLeftBracket:
                let current = textByte(at: textIndex)
                if current == 0 || current == PathMatchingCString.slash && options.contains(.pathname) {
                    return false
                }
                if isProtectedPeriod(at: textIndex, textStart: textStart, options: options) {
                    return false
                }

                switch rangeMatch(patternIndex: patternIndex, test: current, options: options) {
                case let .matched(nextPatternIndex):
                    patternIndex = nextPatternIndex
                    textIndex += 1
                case .noMatch:
                    return false
                case .malformed:
                    // Preserve the bundled C implementation's observable malformed-range behavior:
                    // it advances the text once before treating `[` as a literal.
                    textIndex += 1
                    guard bytesEqual(character, textByte(at: textIndex), options: options) else {
                        return false
                    }
                    textIndex += 1
                }

            case asciiBackslash:
                if !options.contains(.noEscape) {
                    character = patternByte(at: patternIndex)
                    patternIndex += 1
                    if character == 0 {
                        character = asciiBackslash
                        patternIndex -= 1
                        if textByte(at: textIndex + 1) == 0 {
                            return false
                        }
                    }
                }
                fallthrough

            default:
                guard bytesEqual(character, textByte(at: textIndex), options: options) else {
                    return false
                }
                textIndex += 1
            }
        }
    }

    private func rangeMatch(
        patternIndex startPatternIndex: Int,
        test originalTest: UInt8,
        options: RepoWildmatchOptions
    ) -> RangeResult {
        var patternIndex = startPatternIndex
        var test = originalTest
        let negate = patternByte(at: patternIndex) == asciiExclamation || patternByte(at: patternIndex) == asciiCaret
        if negate {
            patternIndex += 1
        }
        if options.contains(.caseFold) {
            test = asciiLowercased(test)
        }

        var matched = false
        var character = patternByte(at: patternIndex)
        patternIndex += 1

        while true {
            if character == asciiBackslash, !options.contains(.noEscape) {
                character = patternByte(at: patternIndex)
                patternIndex += 1
            }
            if character == 0 {
                return .malformed
            }
            if character == PathMatchingCString.slash, options.contains(.pathname) {
                return .noMatch
            }

            if patternByte(at: patternIndex) == asciiHyphen {
                var rangeEnd = patternByte(at: patternIndex + 1)
                if rangeEnd != 0, rangeEnd != asciiRightBracket {
                    patternIndex += 2
                    if rangeEnd == asciiBackslash, !options.contains(.noEscape) {
                        rangeEnd = patternByte(at: patternIndex)
                        patternIndex += 1
                    }
                    if rangeEnd == 0 {
                        return .malformed
                    }

                    var rangeStart = character
                    if options.contains(.caseFold) {
                        rangeStart = asciiLowercased(rangeStart)
                        rangeEnd = asciiLowercased(rangeEnd)
                    }
                    var signedRangeStart = Int8(bitPattern: rangeStart)
                    var signedRangeEnd = Int8(bitPattern: rangeEnd)
                    let signedTest = Int8(bitPattern: test)
                    if signedRangeStart > signedRangeEnd {
                        swap(&signedRangeStart, &signedRangeEnd)
                    }
                    if signedRangeStart <= signedTest, signedTest <= signedRangeEnd {
                        matched = true
                    }
                }
            }

            if character == asciiLeftBracket,
               patternByte(at: patternIndex) == asciiColon,
               patternByte(at: patternIndex + 1) != 0
            {
                if bytesMatch(Array(":]".utf8), at: patternIndex + 1) {
                    character = patternByte(at: patternIndex)
                    patternIndex += 1
                    if character == asciiRightBracket { break }
                    continue
                }

                if let name = matchingCharacterClassName(at: patternIndex + 1) {
                    if characterClass(name, matches: test, caseFold: options.contains(.caseFold)) {
                        matched = true
                    }
                    patternIndex += name.utf8.count + 3
                    character = patternByte(at: patternIndex)
                    patternIndex += 1
                    if character == asciiRightBracket { break }
                    continue
                }
            }

            if character == test {
                matched = true
            }

            character = patternByte(at: patternIndex)
            patternIndex += 1
            if character == asciiRightBracket {
                break
            }
        }

        return matched == negate ? .noMatch : .matched(nextPatternIndex: patternIndex)
    }

    private func matchingCharacterClassName(at index: Int) -> String? {
        for name in characterClassNames where bytesMatch(Array("\(name):]".utf8), at: index) {
            return name
        }
        return nil
    }

    private func characterClass(_ name: String, matches byte: UInt8, caseFold: Bool) -> Bool {
        switch name {
        case "alnum":
            return isASCIIAlpha(byte) || isASCIIDigit(byte)
        case "alpha":
            return isASCIIAlpha(byte)
        case "blank":
            return byte == asciiSpace || byte == asciiTab
        case "cntrl":
            return byte < asciiSpace || byte == 0x7F
        case "digit":
            return isASCIIDigit(byte)
        case "graph":
            return byte >= 0x21 && byte <= 0x7E
        case "lower":
            return byte >= asciiLowerA && byte <= asciiLowerZ
        case "print":
            return byte >= asciiSpace && byte <= 0x7E
        case "punct":
            return byte >= 0x21 && byte <= 0x7E && !isASCIIAlpha(byte) && !isASCIIDigit(byte)
        case "space":
            return byte == asciiSpace || (0x09 ... 0x0D).contains(byte)
        case "xdigit":
            return isASCIIDigit(byte) || (asciiLowerA ... asciiLowerF).contains(asciiLowercased(byte))
        case "upper":
            let candidate = caseFold ? asciiUppercased(byte) : byte
            return candidate >= asciiUpperA && candidate <= asciiUpperZ
        default:
            return false
        }
    }

    private func isProtectedPeriod(
        at textIndex: Int,
        textStart: Int,
        options: RepoWildmatchOptions
    ) -> Bool {
        guard textByte(at: textIndex) == asciiPeriod, options.contains(.period) else {
            return false
        }
        return textIndex == textStart ||
            options.contains(.pathname) && textByte(at: textIndex - 1) == PathMatchingCString.slash
    }

    private func bytesEqual(_ lhs: UInt8, _ rhs: UInt8, options: RepoWildmatchOptions) -> Bool {
        lhs == rhs || options.contains(.caseFold) && asciiLowercased(lhs) == asciiLowercased(rhs)
    }

    private func bytesMatch(_ expected: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + expected.count <= pattern.count else { return false }
        return pattern[index ..< index + expected.count].elementsEqual(expected)
    }

    private func firstSlash(inTextFrom index: Int) -> Int? {
        guard index >= 0, index < text.count else { return nil }
        return text[index...].firstIndex(of: PathMatchingCString.slash)
    }

    private func patternByte(at index: Int) -> UInt8 {
        guard index >= 0, index < pattern.count else { return 0 }
        return pattern[index]
    }

    private func textByte(at index: Int) -> UInt8 {
        guard index >= 0, index < text.count else { return 0 }
        return text[index]
    }
}

private let asciiQuestionMark: UInt8 = 0x3F
private let asciiLeftBracket: UInt8 = 0x5B
private let asciiRightBracket: UInt8 = 0x5D
private let asciiBackslash: UInt8 = 0x5C
private let asciiExclamation: UInt8 = 0x21
private let asciiCaret: UInt8 = 0x5E
private let asciiHyphen: UInt8 = 0x2D
private let asciiColon: UInt8 = 0x3A
private let asciiPeriod: UInt8 = 0x2E
private let asciiSpace: UInt8 = 0x20
private let asciiTab: UInt8 = 0x09
private let asciiUpperA: UInt8 = 0x41
private let asciiUpperZ: UInt8 = 0x5A
private let asciiLowerA: UInt8 = 0x61
private let asciiLowerF: UInt8 = 0x66
private let asciiLowerZ: UInt8 = 0x7A

private let characterClassNames = [
    "alnum", "alpha", "blank", "cntrl", "digit", "graph",
    "lower", "print", "punct", "space", "xdigit", "upper"
]

private func asciiLowercased(_ byte: UInt8) -> UInt8 {
    (asciiUpperA ... asciiUpperZ).contains(byte) ? byte + 0x20 : byte
}

private func asciiUppercased(_ byte: UInt8) -> UInt8 {
    (asciiLowerA ... asciiLowerZ).contains(byte) ? byte - 0x20 : byte
}

private func isASCIIAlpha(_ byte: UInt8) -> Bool {
    (asciiUpperA ... asciiUpperZ).contains(byte) || (asciiLowerA ... asciiLowerZ).contains(byte)
}

private func isASCIIDigit(_ byte: UInt8) -> Bool {
    (0x30 ... 0x39).contains(byte)
}
