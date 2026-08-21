import Foundation

/// Final post-processing pass applied to every `CodeMapSyntaxArtifact` built
/// by the legacy Swift extractor, closing three remaining field-parity gaps
/// against the production Rust codemap engine that don't fit naturally
/// inside `CodeMapGenerator`'s single-pass capture loop. See
/// `docs/architecture/rust-codemap-compact-v1.md` (Step 12 parity matrix).
///
/// None of these three changes affect `apiDescription`/`definedTypeNames`
/// (the golden-tested rendered summary):
/// `CodeMapAPIContentFormatter.summarize` doesn't take `referencedTypes` as
/// an input at all, treats a `nil` and an empty-string `typeName`
/// identically, and only ever reads `FunctionInfo.definitionLine` /
/// `.lineNumber` for methods (never `.name`).
package enum RustParityArtifactNormalizer {
    package static func normalize(_ artifact: CodeMapSyntaxArtifact, language: LanguageType) -> CodeMapSyntaxArtifact {
        let stripOptionalMarkerFromNames = (language == .ts || language == .tsx)

        let classes = artifact.classes.map { classInfo in
            ClassInfo(
                name: classInfo.name,
                methods: classInfo.methods.map { normalizeFunction($0, stripOptionalMarker: stripOptionalMarkerFromNames) },
                properties: classInfo.properties.map(normalizeProperty)
            )
        }
        let interfaces = artifact.interfaces.map { interfaceInfo in
            InterfaceInfo(
                name: interfaceInfo.name,
                properties: interfaceInfo.properties.map(normalizeProperty),
                methods: interfaceInfo.methods.map { normalizeFunction($0, stripOptionalMarker: stripOptionalMarkerFromNames) }
            )
        }
        let functions = artifact.functions.map { normalizeFunction($0, stripOptionalMarker: stripOptionalMarkerFromNames) }
        let globalVars = artifact.globalVars.map(normalizeVariable)

        let normalized = CodeMapSyntaxArtifact(
            imports: artifact.imports,
            exports: artifact.exports,
            classes: classes,
            interfaces: interfaces,
            aliases: artifact.aliases,
            literalUnions: artifact.literalUnions,
            functions: functions,
            enums: artifact.enums,
            globalVars: globalVars,
            macros: artifact.macros,
            referencedTypes: ReferencedTypesRustParity.recompute(
                functions: functions,
                classes: classes,
                interfaces: interfaces
            )
        )
        return normalized
    }

    private static func normalizeFunction(_ function: FunctionInfo, stripOptionalMarker: Bool) -> FunctionInfo {
        var name = function.name
        // TS/TSX optional-member syntax (`onClick?(): void;`) can leak the
        // trailing `?` into the captured identifier; it is never part of
        // the real method name. Ruby's legitimate predicate-method `?`
        // suffix (`def valid?`) must NOT be touched, so this is scoped to
        // TS/TSX only.
        if stripOptionalMarker, name.hasSuffix("?") {
            name.removeLast()
        }
        return FunctionInfo(
            name: name,
            parameters: function.parameters,
            returnType: function.returnType,
            definitionLine: function.definitionLine,
            lineNumber: function.lineNumber
        )
    }

    private static func normalizeProperty(_ property: PropertyInfo) -> PropertyInfo {
        PropertyInfo(name: property.name, typeName: nonEmpty(property.typeName))
    }

    private static func normalizeVariable(_ variable: VariableInfo) -> VariableInfo {
        VariableInfo(name: variable.name, typeName: nonEmpty(variable.typeName), definitionLine: variable.definitionLine)
    }

    /// The legacy extractor sometimes emits `Optional("")` where the Rust
    /// engine emits `nil` for an absent property/variable type.
    /// `CodeMapAPIContentFormatter.formatPropertyLine` already treats the
    /// two identically (`guard let typeName, !typeName.isEmpty`), so this is
    /// a representation-only normalization, not a rendering change.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Recomputes `CodeMapSyntaxArtifact.referencedTypes` to match the Rust
/// codemap engine's `referenced_type_names` + `BTreeSet` accumulation in
/// `rust/crates/runtime/src/codemap/extract.rs` exactly: sourced *only* from
/// function/method parameter types and return types (never from imports,
/// container names, properties, variables, or aliases), tokenized on
/// non-identifier/non-`.` boundaries, kept only when the token starts with
/// an uppercase letter and isn't in the shared skip list, deduplicated, and
/// sorted.
private enum ReferencedTypesRustParity {
    private static let skip: Set<String> = [
        "String", "string", "str", "Int", "int", "void", "Self", "self", "bool", "boolean", "error",
    ]

    static func recompute(functions: [FunctionInfo], classes: [ClassInfo], interfaces: [InterfaceInfo]) -> [String] {
        var collected = Set<String>()
        func consume(_ function: FunctionInfo) {
            for parameter in function.parameters {
                if let typeName = parameter.typeName {
                    collected.formUnion(names(in: typeName))
                }
            }
            if let returnType = function.returnType {
                collected.formUnion(names(in: returnType))
            }
        }
        functions.forEach(consume)
        for classInfo in classes {
            classInfo.methods.forEach(consume)
        }
        for interfaceInfo in interfaces {
            interfaceInfo.methods.forEach(consume)
        }
        return collected.sorted()
    }

    private static func names(in raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in raw {
            if character.isLetter || character.isNumber || character == "_" || character == "." {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens.filter { token in
            guard let first = token.first, first.isUppercase else { return false }
            return !skip.contains(token)
        }
    }
}
