import Foundation

enum LineIndentationAlgorithms {
    static func splitPreservingDetectedEnding(_ content: String) -> ([String], String) {
        let (lineBytes, endingBytes) = split(CStringByteView.effectiveBytes(of: content))
        return (lineBytes.map(CStringByteView.decode), CStringByteView.decode(endingBytes))
    }

    static func encodeIndentationAsSpaces(_ line: String) -> String {
        CStringByteView.decode(encodeIndentation(CStringByteView.effectiveBytes(of: line), type: 115))
    }

    static func decodeIndentation(_ encodedLine: String) -> String {
        CStringByteView.decode(decodeIndentation(CStringByteView.effectiveBytes(of: encodedLine)))
    }

    static func trimCommonLeadingWhitespacePreservingEndings(_ content: String) -> String {
        let contentBytes = CStringByteView.effectiveBytes(of: content)
        guard !contentBytes.isEmpty else { return "" }

        var (lines, ending) = split(contentBytes)
        for index in lines.indices {
            let htmlDecoded = StringNormalizationAlgorithms.decodeHTMLEntities(lines[index])
            lines[index] = encodeIndentation(htmlDecoded, type: 115)
        }

        var minimumWhitespace: Int?
        for index in lines.indices {
            lines[index] = decodeIndentation(lines[index])
            var whitespaceCount = 0
            while whitespaceCount < lines[index].count,
                  CStringByteView.isASCIIWhitespace(lines[index][whitespaceCount])
            {
                whitespaceCount += 1
            }
            if whitespaceCount < lines[index].count {
                minimumWhitespace = Swift.min(minimumWhitespace ?? whitespaceCount, whitespaceCount)
            }
        }

        let amountToTrim = minimumWhitespace ?? 0
        if amountToTrim > 0 {
            for index in lines.indices {
                if amountToTrim >= lines[index].count {
                    lines[index] = []
                } else {
                    lines[index].removeFirst(amountToTrim)
                }
            }
        }

        var result: [UInt8] = []
        for index in lines.indices {
            result.append(contentsOf: lines[index])
            if index + 1 < lines.count {
                result.append(contentsOf: ending)
            }
        }
        return CStringByteView.decode(result)
    }

    private static func split(_ bytes: [UInt8]) -> ([[UInt8]], [UInt8]) {
        var lines: [[UInt8]] = []
        var unixCount = 0
        var windowsCount = 0
        var macCount = 0
        var lastEnding = 0
        var lineStart = 0
        var index = 0

        while index < bytes.count {
            if bytes[index] == 13 {
                lines.append(Array(bytes[lineStart ..< index]))
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    windowsCount += 1
                    lastEnding = 1
                    index += 2
                } else {
                    macCount += 1
                    lastEnding = 2
                    index += 1
                }
                lineStart = index
            } else if bytes[index] == 10 {
                lines.append(Array(bytes[lineStart ..< index]))
                unixCount += 1
                lastEnding = 3
                index += 1
                lineStart = index
            } else {
                index += 1
            }
        }
        if lineStart < bytes.count {
            lines.append(Array(bytes[lineStart...]))
        }

        let ending: [UInt8] = if windowsCount > unixCount, windowsCount > macCount {
            [13, 10]
        } else if macCount > unixCount, macCount > windowsCount {
            [13]
        } else if unixCount > windowsCount, unixCount > macCount {
            [10]
        } else {
            switch lastEnding {
            case 1: [13, 10]
            case 2: [13]
            default: [10]
            }
        }
        return (lines, ending)
    }

    private static func encodeIndentation(_ bytes: [UInt8], type: UInt8) -> [UInt8] {
        var effectiveSpaces = 0
        var contentStart = 0
        while contentStart < bytes.count, bytes[contentStart] == 32 || bytes[contentStart] == 9 {
            effectiveSpaces += bytes[contentStart] == 9 ? 4 : 1
            contentStart += 1
        }

        var contentEnd = bytes.count
        while contentEnd > contentStart, CStringByteView.isASCIIWhitespace(bytes[contentEnd - 1]) {
            contentEnd -= 1
        }

        var result = Array("<".utf8)
        result.append(type)
        result.append(contentsOf: String(effectiveSpaces).utf8)
        result.append(62)
        if contentStart < contentEnd {
            result.append(contentsOf: bytes[contentStart ..< contentEnd])
        }
        return result
    }

    private static func decodeIndentation(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.first == 60,
              let close = bytes.firstIndex(of: 62),
              close >= 3
        else {
            return bytes
        }

        let type = bytes[1]
        guard type == 115 || type == 116 else { return bytes }
        let countBytes = Array(bytes[2 ..< close])
        guard !countBytes.isEmpty,
              countBytes.count < 20,
              countBytes.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let count = UInt(String(decoding: countBytes, as: UTF8.self)),
              count <= 1_000_000
        else {
            return bytes
        }

        var result = [UInt8](repeating: type == 116 ? 9 : 32, count: Int(count))
        if close + 1 < bytes.count {
            result.append(contentsOf: bytes[(close + 1)...])
        }
        return result
    }
}
