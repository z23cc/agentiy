import Foundation

enum StringNormalizationAlgorithms {
    private static let htmlEntities: [([UInt8], [UInt8])] = [
        (Array("&lt;".utf8), Array("<".utf8)),
        (Array("&gt;".utf8), Array(">".utf8)),
        (Array("&amp;".utf8), Array("&".utf8)),
        (Array("&quot;".utf8), Array("\"".utf8)),
        (Array("&#39;".utf8), Array("'".utf8)),
        (Array("&nbsp;".utf8), Array(" ".utf8)),
        (Array("&#160;".utf8), Array(" ".utf8))
    ]

    private static let qualifiers = [
        "public ", "private ", "internal ", "fileprivate ",
        "open ", "final ", "static ", "class ", "override ",
        "mutating ", "async ", "throws ", "lazy "
    ].map { Array($0.utf8) }

    private static let delimiters = ["->", "=>", ":=", "=", ":"].map { Array($0.utf8) }

    static func decodeHTMLEntities(_ string: String) -> String {
        CStringByteView.decode(decodeHTMLEntities(CStringByteView.effectiveBytes(of: string)))
    }

    static func condenseWhitespace(_ string: String) -> String {
        CStringByteView.decode(condenseWhitespace(CStringByteView.effectiveBytes(of: string)))
    }

    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in CStringByteView.effectiveBytes(of: string) {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }

    static func escape(_ string: String) -> String {
        var result: [UInt8] = []
        let bytes = CStringByteView.effectiveBytes(of: string)
        result.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            switch byte {
            case 92:
                result.append(contentsOf: [92, 92])
            case 34:
                result.append(contentsOf: [92, 34])
            case 10:
                result.append(contentsOf: [92, 110])
            case 13:
                result.append(contentsOf: [92, 114])
            case 9:
                result.append(contentsOf: [92, 116])
            default:
                result.append(byte)
            }
        }
        return CStringByteView.decode(result)
    }

    static func unescape(_ string: String) -> String {
        let bytes = CStringByteView.effectiveBytes(of: string)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 92 else {
                result.append(bytes[index])
                index += 1
                continue
            }
            guard index + 1 < bytes.count else {
                result.append(92)
                break
            }

            let escaped = bytes[index + 1]
            switch escaped {
            case 110: result.append(10)
            case 114: result.append(13)
            case 116: result.append(9)
            case 92: result.append(92)
            case 34: result.append(34)
            default: result.append(contentsOf: [92, escaped])
            }
            index += 2
        }
        return CStringByteView.decode(result)
    }

    static func fuzzySpaceMatch(_ pattern: String, _ text: String, caseInsensitive: Bool) -> Bool {
        let patternBytes = CStringByteView.effectiveBytes(of: pattern)
        let textBytes = CStringByteView.effectiveBytes(of: text)
        if patternBytes.isEmpty {
            return textBytes.isEmpty && caseInsensitive
        }
        if onlyWhitespace(patternBytes) {
            return !textBytes.isEmpty && onlyWhitespace(textBytes)
        }

        var patternIndex = 0
        var textIndex = 0
        while patternIndex < patternBytes.count, textIndex < textBytes.count {
            if patternBytes[patternIndex] == 32 {
                guard isASCIIWhitespace(textBytes, at: textIndex) else { return false }
                while textIndex < textBytes.count, isASCIIWhitespace(textBytes, at: textIndex) {
                    textIndex += 1
                }
                while patternIndex < patternBytes.count, patternBytes[patternIndex] == 32 {
                    patternIndex += 1
                }
                continue
            }

            if isNBSP(patternBytes, at: patternIndex) || isEmSpace(patternBytes, at: patternIndex) {
                guard isAnyWhitespace(textBytes, at: textIndex) else { return false }
                while textIndex < textBytes.count, isAnyWhitespace(textBytes, at: textIndex) {
                    textIndex = advancedPastWhitespace(textBytes, at: textIndex)
                }
                while patternIndex < patternBytes.count,
                      patternBytes[patternIndex] == 32
                      || isNBSP(patternBytes, at: patternIndex)
                      || isEmSpace(patternBytes, at: patternIndex)
                {
                    patternIndex = advancedPastWhitespace(patternBytes, at: patternIndex)
                }
                continue
            }

            if CStringByteView.isASCIIWhitespace(patternBytes[patternIndex]) {
                guard patternBytes[patternIndex] == textBytes[textIndex] else { return false }
                patternIndex += 1
                textIndex += 1
                continue
            }

            let patternByte = caseInsensitive
                ? CStringByteView.asciiLowercased(patternBytes[patternIndex])
                : patternBytes[patternIndex]
            let textByte = caseInsensitive
                ? CStringByteView.asciiLowercased(textBytes[textIndex])
                : textBytes[textIndex]
            guard patternByte == textByte else { return false }
            patternIndex += 1
            textIndex += 1
        }

        while patternIndex < patternBytes.count,
              patternBytes[patternIndex] == 32
              || isNBSP(patternBytes, at: patternIndex)
              || isEmSpace(patternBytes, at: patternIndex)
        {
            patternIndex = advancedPastWhitespace(patternBytes, at: patternIndex)
        }
        while textIndex < textBytes.count, isAnyWhitespace(textBytes, at: textIndex) {
            textIndex = advancedPastWhitespace(textBytes, at: textIndex)
        }
        return patternIndex == patternBytes.count && textIndex == textBytes.count
    }

    static func canonicalKey(_ string: String) -> String? {
        var bytes = decodeHTMLEntities(CStringByteView.effectiveBytes(of: string))
        for index in bytes.indices {
            bytes[index] = CStringByteView.asciiLowercased(bytes[index])
        }
        bytes = condenseWhitespace(bytes)
        trimASCIIWhitespace(&bytes)
        guard !bytes.isEmpty else { return nil }

        var stripped = true
        while stripped {
            stripped = false
            for qualifier in qualifiers where bytes.count > qualifier.count && starts(bytes, with: qualifier) {
                bytes.removeFirst(qualifier.count)
                stripped = true
                break
            }
        }

        bytes = collapseSeparatorRuns(bytes)
        if bytes.count > 150 {
            bytes.removeSubrange(150...)
        }
        for delimiter in delimiters where ends(bytes, with: delimiter) {
            bytes.removeLast(delimiter.count)
            while let last = bytes.last, CStringByteView.isASCIIWhitespace(last) {
                bytes.removeLast()
            }
            break
        }
        return bytes.isEmpty ? nil : CStringByteView.decode(bytes)
    }

    static func decodeHTMLEntities(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            var matched = false
            for (entity, replacement) in htmlEntities where matches(bytes, at: index, value: entity) {
                result.append(contentsOf: replacement)
                index += entity.count
                matched = true
                break
            }
            if !matched {
                result.append(bytes[index])
                index += 1
            }
        }
        return result
    }

    private static func condenseWhitespace(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var wasWhitespace = false
        var index = 0
        while index < bytes.count {
            let isWhitespace: Bool
            if CStringByteView.isASCIIWhitespace(bytes[index]) {
                isWhitespace = true
                index += 1
            } else if isNBSP(bytes, at: index) {
                isWhitespace = true
                index += 2
            } else {
                isWhitespace = false
                result.append(bytes[index])
                index += 1
            }

            if isWhitespace {
                if !wasWhitespace { result.append(32) }
                wasWhitespace = true
            } else {
                wasWhitespace = false
            }
        }
        return result
    }

    private static func collapseSeparatorRuns(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var inSeparator = false
        var index = 0
        while index < bytes.count {
            let separatorLength = if bytes[index] == 45 || bytes[index] == 95 {
                1
            } else if index + 2 < bytes.count,
                      bytes[index] == 0xE2,
                      bytes[index + 1] == 0x94
                      || bytes[index + 1] == 0x95
                      || (bytes[index + 1] == 0x80 && (bytes[index + 2] == 0x93 || bytes[index + 2] == 0x94))
            {
                3
            } else {
                0
            }

            if separatorLength > 0 {
                if !inSeparator { result.append(45) }
                inSeparator = true
                index += separatorLength
            } else {
                result.append(bytes[index])
                inSeparator = false
                index += 1
            }
        }
        return result
    }

    private static func trimASCIIWhitespace(_ bytes: inout [UInt8]) {
        while let first = bytes.first, CStringByteView.isASCIIWhitespace(first) {
            bytes.removeFirst()
        }
        while let last = bytes.last, CStringByteView.isASCIIWhitespace(last) {
            bytes.removeLast()
        }
    }

    private static func onlyWhitespace(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        var index = 0
        while index < bytes.count {
            guard isAnyWhitespace(bytes, at: index) else { return false }
            index = advancedPastWhitespace(bytes, at: index)
        }
        return true
    }

    private static func isASCIIWhitespace(_ bytes: [UInt8], at index: Int) -> Bool {
        index < bytes.count && CStringByteView.isASCIIWhitespace(bytes[index])
    }

    private static func isAnyWhitespace(_ bytes: [UInt8], at index: Int) -> Bool {
        isASCIIWhitespace(bytes, at: index) || isNBSP(bytes, at: index) || isEmSpace(bytes, at: index)
    }

    private static func advancedPastWhitespace(_ bytes: [UInt8], at index: Int) -> Int {
        if isNBSP(bytes, at: index) { return index + 2 }
        if isEmSpace(bytes, at: index) { return index + 3 }
        return index + 1
    }

    private static func isNBSP(_ bytes: [UInt8], at index: Int) -> Bool {
        index + 1 < bytes.count && bytes[index] == 0xC2 && bytes[index + 1] == 0xA0
    }

    private static func isEmSpace(_ bytes: [UInt8], at index: Int) -> Bool {
        index + 2 < bytes.count
            && bytes[index] == 0xE2
            && bytes[index + 1] == 0x80
            && bytes[index + 2] == 0x83
    }

    private static func starts(_ bytes: [UInt8], with prefix: [UInt8]) -> Bool {
        bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix
    }

    private static func ends(_ bytes: [UInt8], with suffix: [UInt8]) -> Bool {
        bytes.count >= suffix.count && Array(bytes.suffix(suffix.count)) == suffix
    }

    private static func matches(_ bytes: [UInt8], at index: Int, value: [UInt8]) -> Bool {
        index + value.count <= bytes.count && Array(bytes[index ..< index + value.count]) == value
    }
}
