import Foundation

enum CStringByteView {
    static func effectiveBytes(of string: String) -> [UInt8] {
        let bytes = Array(string.utf8)
        guard let nul = bytes.firstIndex(of: 0) else { return bytes }
        return Array(bytes[..<nul])
    }

    static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func utf8CodePoints(in bytes: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        result.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            let length = if first & 0x80 == 0 {
                1
            } else if first & 0xE0 == 0xC0 {
                2
            } else if first & 0xF0 == 0xE0 {
                3
            } else if first & 0xF8 == 0xF0 {
                4
            } else {
                1
            }
            let end = Swift.min(index + length, bytes.count)
            result.append(Array(bytes[index ..< end]))
            index = end
        }
        return result
    }

    @inline(__always)
    static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    @inline(__always)
    static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || (byte >= 9 && byte <= 13)
    }
}
