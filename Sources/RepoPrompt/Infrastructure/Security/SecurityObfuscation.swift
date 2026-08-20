//
//  SecurityObfuscation.swift
//  RepoPrompt
//
//  Centralized XOR obfuscation for security-sensitive strings.
//  Encoded values are internal for testability; decoded values stay scoped to their catalog or consumer.
//

import Foundation

enum SecurityObfuscation {
    static let key: UInt8 = 0x5A

    static func decode(_ bytes: [UInt8]) -> String {
        let decoded = bytes.map { $0 ^ key }
        return String(bytes: decoded, encoding: .utf8) ?? ""
    }
}
