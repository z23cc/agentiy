import Foundation

/// Parameter and return-type extraction ported to match the production
/// Rust codemap engine's `signature_details`
/// (`rust/crates/runtime/src/codemap/extract.rs`), so the legacy Swift
/// extractor produces field-identical `ParameterInfo` / `FunctionInfo`
/// values to the shipping Rust engine. See
/// `docs/architecture/rust-codemap-compact-v1.md` (Step 12 parity matrix).
///
/// Callers must feed `declaration` as a clean, single source line (see
/// `cleanSignatureLine`), never the (possibly multi-line-polluted) `decl`
/// text used elsewhere for `FunctionInfo.definitionLine` rendering: some
/// languages' rendering-only declaration text intentionally retains a
/// legacy-quirk body leakage (e.g. Rust's `fn fmt(...)` single-statement
/// body golden quirk) that must never reach parameter/return-type parsing.
package enum RustParitySignatureParser {
    package struct Parsed {
        package let parameters: [ParameterInfo]
        package let returnType: String?
    }

    /// Languages this parser has a Rust-parity algorithm for. Swift has its
    /// own dedicated `SwiftSignatureParser`. Ruby is untyped and reuses this
    /// parser's C-style fallback branch for parameters (matching the Rust
    /// engine's own `param0`-style placeholder behavior for bare
    /// identifiers), but callers invoke it unconditionally for Ruby rather
    /// than gating on `isSupported`.
    package static func isSupported(_ language: LanguageType) -> Bool {
        switch language {
        case .c, .cpp, .c_sharp, .java, .go, .python, .rust, .ts, .tsx, .js, .php:
            true
        case .swift, .ruby:
            false
        }
    }

    /// Mirrors Rust's `clean_declaration_line`: the single trimmed source
    /// line, with a trailing `" {"` / `"{"` body opener removed, and
    /// (TS/TSX only) a trailing statement `;` removed. PHP's trailing `;`
    /// (body-less interface/abstract method signatures) is intentionally
    /// left in place here and stripped only from the parsed return-type
    /// value in `parse(declaration:language:)`, matching the Rust side's
    /// split between rendering-safe and parsing-safe declaration text.
    package static func cleanSignatureLine(_ rawLine: String, language: LanguageType) -> String {
        let raw = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = raw.range(of: " {", options: .backwards) {
            return String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var value = raw
        while value.hasSuffix("{") {
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if language == .ts || language == .tsx {
            while value.hasSuffix(";") {
                value.removeLast()
            }
        }
        return value
    }

    package static func parse(declaration: String, language: LanguageType) -> Parsed {
        guard let openIndex = declaration.firstIndex(of: "(") else {
            return Parsed(parameters: [], returnType: nil)
        }
        var open = openIndex
        if language == .go, declaration.hasPrefix("func (") {
            guard let receiverEnd = matchingParen(declaration, open) else {
                return Parsed(parameters: [], returnType: nil)
            }
            let afterReceiver = declaration[declaration.index(after: receiverEnd)...]
            guard let nextOpen = afterReceiver.firstIndex(of: "(") else {
                return Parsed(parameters: [], returnType: nil)
            }
            open = nextOpen
        }
        guard let close = matchingParen(declaration, open) else {
            return Parsed(parameters: [], returnType: nil)
        }

        let paramsText = String(declaration[declaration.index(after: open)..<close])
        let parameters: [ParameterInfo] = splitParameters(paramsText).enumerated().map { index, raw in
            let (name, type) = parameterNameAndType(raw: raw, index: index, language: language)
            return ParameterInfo(externalName: nil, localName: name, typeName: type)
        }

        let tail = String(declaration[declaration.index(after: close)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var returnType: String?
        if tail.hasPrefix("->") {
            // Python retains its statement-terminating `:` in this tail
            // (`def f() -> Worker:`); Rust never does. Trimming it here is
            // safe for every `->`-using language.
            var value = String(tail.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            while value.hasSuffix(":") {
                value.removeLast()
            }
            returnType = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if language == .ts || language == .tsx || language == .php {
            if tail.hasPrefix(":") {
                var value = String(tail.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if language == .php {
                    while value.hasSuffix(";") {
                        value.removeLast()
                    }
                    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                returnType = value
            }
        } else if language == .go {
            if !tail.isEmpty {
                returnType = tail
            }
        } else if language == .c || language == .cpp || language == .c_sharp || language == .java {
            let prefix = String(declaration[declaration.startIndex..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            let nameToken = prefix.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            var typeText = prefix
            if !nameToken.isEmpty, typeText.hasSuffix(nameToken) {
                typeText.removeLast(nameToken.count)
            }
            typeText = stripLeadingModifiers(typeText.trimmingCharacters(in: .whitespacesAndNewlines))
            returnType = typeText
        }
        if let value = returnType, value.isEmpty {
            returnType = nil
        }
        return Parsed(parameters: parameters, returnType: returnType)
    }

    // MARK: - Parameter (name, type) derivation

    private static func parameterNameAndType(
        raw: String,
        index: Int,
        language: LanguageType
    ) -> (String, String?) {
        switch language {
        case .python, .rust, .ts, .tsx:
            guard let colonIndex = raw.firstIndex(of: ":") else {
                return ("param\(index)", nil)
            }
            let namePart = String(raw[raw.startIndex..<colonIndex])
            var typePart = String(raw[raw.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if typePart.hasSuffix("?") {
                typePart.removeLast()
            }
            typePart = typePart.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastToken = namePart.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? namePart
            // Rust's fallback to `param{index}` applies only when the raw
            // parameter text has no colon at all (see the `guard` above);
            // once a colon is found, an empty cleaned name (e.g. a
            // destructuring pattern like `{ children }: Type`, whose last
            // whitespace-split token trims to nothing) is kept as-is, not
            // replaced with a placeholder.
            let cleanedName = trimNonIdentifierEdges(lastToken)
            return (cleanedName, typePart.isEmpty ? nil : typePart)
        case .go:
            let pieces = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            guard pieces.count > 1 else { return ("param\(index)", nil) }
            let name = String(pieces[0].drop(while: { $0 == "&" || $0 == "*" }))
            let type = pieces[1...].joined(separator: " ")
            return (name, type.isEmpty ? nil : type)
        default:
            // C-style catch-all (C, C++, C#, Java, JS, PHP, Ruby, and any
            // future language not explicitly listed above), matching the
            // Rust engine's `else` branch exactly: `type name` order, last
            // whitespace-separated token is the name.
            let pieces = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            guard pieces.count > 1 else { return ("param\(index)", nil) }
            let last = pieces[pieces.count - 1]
            let name = String(last.drop(while: { $0 == "&" || $0 == "*" || $0 == "$" }))
            let type = pieces[..<(pieces.count - 1)].joined(separator: " ")
            return (name, type.isEmpty ? nil : type)
        }
    }

    private static func trimNonIdentifierEdges(_ value: String) -> String {
        func isIdentifierCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }
        var characters = Array(value)
        while let first = characters.first, !isIdentifierCharacter(first) {
            characters.removeFirst()
        }
        while let last = characters.last, !isIdentifierCharacter(last) {
            characters.removeLast()
        }
        return String(characters)
    }

    // MARK: - Return-type modifier stripping (C/C++/C#/Java)

    /// Access-modifier / storage-class keywords that can precede a
    /// C-family return type (`public string Label()`, `static void
    /// Rename()`, ...). Mirrors Rust's `LEADING_TYPE_MODIFIERS`.
    private static let leadingTypeModifiers = [
        "public", "private", "protected", "internal", "static", "sealed", "override", "abstract",
        "virtual", "unsafe", "async", "final", "synchronized", "extern", "inline", "constexpr",
        "friend", "explicit", "mutable", "volatile", "const",
    ]

    private static func stripLeadingModifiers(_ value: String) -> String {
        var remaining = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            guard let matched = leadingTypeModifiers.first(where: { modifier in
                guard remaining.hasPrefix(modifier) else { return false }
                let rest = remaining.dropFirst(modifier.count)
                return rest.isEmpty || rest.first?.isWhitespace == true
            }) else {
                return remaining
            }
            remaining = String(remaining.dropFirst(matched.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Paren matching / top-level comma splitting

    private static func matchingParen(_ value: String, _ open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < value.endIndex {
            switch value[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return index
                }
            default:
                break
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func splitParameters(_ value: String) -> [String] {
        var values: [String] = []
        var start = value.startIndex
        var depth = 0
        var index = value.startIndex
        while index < value.endIndex {
            switch value[index] {
            case "(", "[", "{", "<":
                depth += 1
            case ")", "]", "}", ">":
                depth = max(0, depth - 1)
            case ",":
                if depth == 0 {
                    values.append(String(value[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                    start = value.index(after: index)
                }
            default:
                break
            }
            index = value.index(after: index)
        }
        values.append(String(value[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return values.filter { !$0.isEmpty }
    }
}
