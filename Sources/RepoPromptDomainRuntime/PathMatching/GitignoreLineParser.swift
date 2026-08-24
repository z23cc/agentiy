package struct GitignoreParsedLine: Equatable {
    package let pattern: String
    package let isNegation: Bool
    package let directoryOnly: Bool
    package let absolute: Bool

    package init(
        pattern: String,
        isNegation: Bool,
        directoryOnly: Bool,
        absolute: Bool
    ) {
        self.pattern = pattern
        self.isNegation = isNegation
        self.directoryOnly = directoryOnly
        self.absolute = absolute
    }
}

package enum GitignoreLineParser {
    private static let capacity = 1024
    private static let space: UInt8 = 0x20
    private static let tab: UInt8 = 0x09
    private static let hash: UInt8 = 0x23
    private static let exclamation: UInt8 = 0x21
    private static let backslash: UInt8 = 0x5C
    private static let slash: UInt8 = 0x2F

    package static func parse(_ line: String) -> GitignoreParsedLine? {
        let bytes = PathMatchingCString.bytes(of: line)
        var index = 0

        while index < bytes.count, bytes[index] == space || bytes[index] == tab {
            index += 1
        }
        guard index < bytes.count, bytes[index] != hash else {
            return nil
        }

        var isNegation = false
        if bytes[index] == exclamation {
            isNegation = true
            index += 1
            if hasEscapedLeadingMarker(bytes, at: index) {
                index += 1
            }
        } else if hasEscapedLeadingMarker(bytes, at: index) {
            index += 1
        }

        var absolute = false
        if index < bytes.count, bytes[index] == slash {
            absolute = true
            index += 1
        }

        var temporary = Array(bytes.dropFirst(index).prefix(capacity - 1))
        trimTrailingWhitespacePreservingEscapes(&temporary)

        var directoryOnly = false
        if temporary.last == slash {
            directoryOnly = true
            temporary.removeLast()
        }

        var normalized: [UInt8] = []
        normalized.reserveCapacity(min(temporary.count, capacity - 1))
        var lastWasSlash = false
        for byte in temporary where normalized.count < capacity - 1 {
            if byte == slash {
                if !lastWasSlash {
                    normalized.append(byte)
                    lastWasSlash = true
                }
            } else {
                normalized.append(byte)
                lastWasSlash = false
            }
        }

        guard !normalized.isEmpty else { return nil }
        return GitignoreParsedLine(
            pattern: String(decoding: normalized, as: UTF8.self),
            isNegation: isNegation,
            directoryOnly: directoryOnly,
            absolute: absolute
        )
    }

    private static func hasEscapedLeadingMarker(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 1 < bytes.count, bytes[index] == backslash else {
            return false
        }
        return bytes[index + 1] == exclamation || bytes[index + 1] == hash
    }

    private static func trimTrailingWhitespacePreservingEscapes(_ bytes: inout [UInt8]) {
        var length = bytes.count
        var preservedSuffix = 0

        while length > preservedSuffix {
            let whitespaceIndex = length - preservedSuffix - 1
            guard bytes[whitespaceIndex] == space || bytes[whitespaceIndex] == tab else {
                break
            }

            var slashCount = 0
            var index = whitespaceIndex
            while index > 0, bytes[index - 1] == backslash {
                slashCount += 1
                index -= 1
            }

            if slashCount.isMultiple(of: 2) {
                guard preservedSuffix == 0 else { break }
                bytes.remove(at: whitespaceIndex)
                length -= 1
            } else {
                bytes.remove(at: whitespaceIndex - 1)
                length -= 1
                preservedSuffix += 1
            }
        }
    }
}
