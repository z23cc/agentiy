import Foundation

enum StringSimilarityAlgorithms {
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsBytes = CStringByteView.effectiveBytes(of: lhs)
        let rhsBytes = CStringByteView.effectiveBytes(of: rhs)

        if lhsBytes == rhsBytes { return 1.0 }
        if lhsBytes.count > 64 || rhsBytes.count > 64 {
            return dice(lhsBytes, rhsBytes)
        }

        let maximumByteLength = Swift.max(lhsBytes.count, rhsBytes.count)
        if maximumByteLength == 0 { return 1.0 }

        let cap = Int(ceil(Double(maximumByteLength) * 0.15))
        let distance = levenshtein(lhsBytes, rhsBytes, maximumDistance: cap)
        if distance > cap {
            return dice(lhsBytes, rhsBytes)
        }
        return 1.0 - Double(distance) / Double(maximumByteLength)
    }

    static func levenshtein(_ lhs: String, _ rhs: String, maximumDistance: Int32?) -> Int {
        levenshtein(
            CStringByteView.effectiveBytes(of: lhs),
            CStringByteView.effectiveBytes(of: rhs),
            maximumDistance: maximumDistance.map(Int.init)
        )
    }

    static func longestCommonSubsequence(_ lhs: String, _ rhs: String) -> String {
        let lhsCharacters = CStringByteView.utf8CodePoints(in: CStringByteView.effectiveBytes(of: lhs))
        let rhsCharacters = CStringByteView.utf8CodePoints(in: CStringByteView.effectiveBytes(of: rhs))
        guard !lhsCharacters.isEmpty, !rhsCharacters.isEmpty else { return "" }

        let columnCount = rhsCharacters.count + 1
        var table = [Int](repeating: 0, count: (lhsCharacters.count + 1) * columnCount)
        for row in 1 ... lhsCharacters.count {
            for column in 1 ... rhsCharacters.count {
                let index = row * columnCount + column
                if lhsCharacters[row - 1] == rhsCharacters[column - 1] {
                    table[index] = table[(row - 1) * columnCount + column - 1] + 1
                } else {
                    table[index] = Swift.max(
                        table[(row - 1) * columnCount + column],
                        table[row * columnCount + column - 1]
                    )
                }
            }
        }

        var selected: [[UInt8]] = []
        selected.reserveCapacity(table[lhsCharacters.count * columnCount + rhsCharacters.count])
        var row = lhsCharacters.count
        var column = rhsCharacters.count
        while row > 0, column > 0 {
            if lhsCharacters[row - 1] == rhsCharacters[column - 1] {
                selected.append(lhsCharacters[row - 1])
                row -= 1
                column -= 1
            } else if table[(row - 1) * columnCount + column] > table[row * columnCount + column - 1] {
                row -= 1
            } else {
                column -= 1
            }
        }

        return CStringByteView.decode(selected.reversed().flatMap(\.self))
    }

    static func dice(_ lhs: String, _ rhs: String) -> Double {
        dice(CStringByteView.effectiveBytes(of: lhs), CStringByteView.effectiveBytes(of: rhs))
    }

    private static func levenshtein(
        _ originalLHS: [UInt8],
        _ originalRHS: [UInt8],
        maximumDistance: Int?
    ) -> Int {
        if originalLHS == originalRHS { return 0 }

        var lhs = CStringByteView.utf8CodePoints(in: originalLHS)
        var rhs = CStringByteView.utf8CodePoints(in: originalRHS)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        let cap = maximumDistance.flatMap { $0 >= 0 ? $0 : nil }
        if let cap, abs(lhs.count - rhs.count) > cap {
            return cap + 1
        }
        if rhs.count < lhs.count {
            swap(&lhs, &rhs)
        }

        if cap == nil {
            var previous = Array(0 ... rhs.count)
            var current = [Int](repeating: 0, count: rhs.count + 1)
            for row in 1 ... lhs.count {
                current[0] = row
                for column in 1 ... rhs.count {
                    let insertion = current[column - 1] + 1
                    let deletion = previous[column] + 1
                    let substitution = previous[column - 1] + (lhs[row - 1] == rhs[column - 1] ? 0 : 1)
                    current[column] = Swift.min(insertion, deletion, substitution)
                }
                swap(&previous, &current)
            }
            return previous[rhs.count]
        }

        let resolvedCap = cap!
        let beyondCap = resolvedCap + 1
        var previous = [Int](repeating: beyondCap, count: rhs.count + 1)
        var current = [Int](repeating: beyondCap, count: rhs.count + 1)
        previous[0] = 0
        if resolvedCap > 0 {
            for column in 1 ... Swift.min(rhs.count, resolvedCap) {
                previous[column] = column
            }
        }

        for row in 1 ... lhs.count {
            let lowerColumn = Swift.max(1, row - resolvedCap)
            let upperColumn = Swift.min(rhs.count, row + resolvedCap)
            current = [Int](repeating: beyondCap, count: rhs.count + 1)
            if lowerColumn == 1 {
                current[0] = row
            }

            var rowMinimum = beyondCap
            if lowerColumn <= upperColumn {
                for column in lowerColumn ... upperColumn {
                    let insertion = current[column - 1] + 1
                    let deletion = previous[column] + 1
                    let substitution = previous[column - 1] + (lhs[row - 1] == rhs[column - 1] ? 0 : 1)
                    let value = Swift.min(insertion, deletion, substitution)
                    current[column] = value
                    rowMinimum = Swift.min(rowMinimum, value)
                }
            }
            if rowMinimum > resolvedCap { return beyondCap }
            swap(&previous, &current)
        }

        return previous[rhs.count] > resolvedCap ? beyondCap : previous[rhs.count]
    }

    private static func dice(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0.0 }
        if lhs == rhs { return 1.0 }
        if lhs.count == 1 || rhs.count == 1 {
            return lhs[0] == rhs[0] ? 1.0 : 0.0
        }

        var lhsBigrams = [Int](repeating: 0, count: 65536)
        var rhsBigrams = [Int](repeating: 0, count: 65536)
        for index in 0 ..< lhs.count - 1 {
            let key = Int(CStringByteView.asciiLowercased(lhs[index])) << 8
                | Int(CStringByteView.asciiLowercased(lhs[index + 1]))
            lhsBigrams[key] += 1
        }
        for index in 0 ..< rhs.count - 1 {
            let key = Int(CStringByteView.asciiLowercased(rhs[index])) << 8
                | Int(CStringByteView.asciiLowercased(rhs[index + 1]))
            rhsBigrams[key] += 1
        }

        var intersection = 0
        for key in lhsBigrams.indices where lhsBigrams[key] > 0 && rhsBigrams[key] > 0 {
            intersection += Swift.min(lhsBigrams[key], rhsBigrams[key])
        }
        return 2.0 * Double(intersection) / Double(lhs.count + rhs.count - 2)
    }
}
