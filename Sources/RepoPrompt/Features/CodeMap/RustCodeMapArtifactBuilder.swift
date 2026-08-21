import AgentryCoreBridge
import Foundation
import RepoPromptCodeMapCore

enum RustCodeMapArtifactBuilderError: Error, Equatable {
    case unexpectedSubjectCount
    case subjectIdentityMismatch
    case numericOverflow
}

struct RustCodeMapArtifactBuilder: @unchecked Sendable {
    typealias Extract = @Sendable (CoreCodeMapBatchRequestV1) async throws -> CoreCodeMapBatchResultV1

    private let extract: Extract

    init(extract: @escaping Extract = { request in
        let client = try await AgentryCoreService.shared.computeClient()
        return try await client.extractCodeMapBatchV1(request)
    }) {
        self.extract = extract
    }

    func build(input: CodeMapArtifactBuildInput) async throws -> CodeMapSyntaxArtifactOutcome {
        try await build(source: input.source.coreSnapshot, language: input.language)
    }

    func build(
        source: CodeMapCoreSourceSnapshot,
        language: LanguageType
    ) async throws -> CodeMapSyntaxArtifactOutcome {
        let subject = CoreCodeMapSubjectRequestV1(source: source, language: language)
        let result = try await extract(CoreCodeMapBatchRequestV1(subjects: [subject]))
        guard result.subjects.count == 1 else {
            throw RustCodeMapArtifactBuilderError.unexpectedSubjectCount
        }
        let returned = result.subjects[0]
        guard returned.languageID == subject.languageID,
              returned.sourceByteCount == UInt64(subject.sourceUTF8.count)
        else {
            throw RustCodeMapArtifactBuilderError.subjectIdentityMismatch
        }
        return try Self.materialize(returned.outcome)
    }

    private static func materialize(
        _ outcome: CoreCodeMapSubjectOutcome
    ) throws -> CodeMapSyntaxArtifactOutcome {
        switch outcome {
        case let .ready(artifact):
            try .ready(CodeMapSyntaxArtifact(
                imports: artifact.imports,
                exports: artifact.exports,
                classes: artifact.classes.map { classInfo in
                    try ClassInfo(
                        name: classInfo.name,
                        methods: classInfo.methods.map(Self.materialize),
                        properties: classInfo.properties.map(Self.materialize)
                    )
                },
                interfaces: artifact.interfaces.map { interfaceInfo in
                    try InterfaceInfo(
                        name: interfaceInfo.name,
                        properties: interfaceInfo.properties.map(Self.materialize),
                        methods: interfaceInfo.methods.map(Self.materialize)
                    )
                },
                aliases: artifact.aliases.map {
                    TypeAliasInfo(name: $0.name, definitionLine: $0.definitionLine)
                },
                literalUnions: artifact.literalUnions,
                functions: artifact.functions.map(Self.materialize),
                enums: artifact.enums.map { EnumInfo(name: $0.name, cases: $0.cases) },
                globalVars: artifact.globalVariables.map {
                    VariableInfo(name: $0.name, typeName: $0.typeName, definitionLine: $0.definitionLine)
                },
                macros: artifact.macros,
                referencedTypes: artifact.referencedTypes
            ))
        case .readyNoSymbols:
            .readyNoSymbols
        case let .oversizeUTF8Bytes(actual, limit):
            try .oversize(.utf8Bytes(actual: checkedInt(actual), limit: checkedInt(limit)))
        case let .oversizeUTF16Units(actual, limit):
            try .oversize(.utf16Units(actual: checkedInt(actual), limit: checkedInt(limit)))
        case let .oversizeLines(actual, limit):
            try .oversize(.lines(actual: checkedInt(actual), limit: checkedInt(limit)))
        case .decodeFailedUndecodable:
            .decodeFailed(.undecodable)
        case .parseFailedNilTree:
            .parseFailed(.parserReturnedNilTree)
        case .parseFailedNilRoot:
            .parseFailed(.parserReturnedNilRoot)
        }
    }

    private static func materialize(_ function: CoreCodeMapFunction) throws -> FunctionInfo {
        try FunctionInfo(
            name: function.name,
            parameters: function.parameters.map {
                ParameterInfo(
                    externalName: $0.externalName,
                    localName: $0.localName,
                    typeName: $0.typeName
                )
            },
            returnType: function.returnType,
            definitionLine: function.definitionLine,
            lineNumber: function.lineNumber.map { try checkedInt($0) }
        )
    }

    private static func materialize(_ property: CoreCodeMapProperty) -> PropertyInfo {
        PropertyInfo(name: property.name, typeName: property.typeName)
    }

    private static func checkedInt(_ value: UInt64) throws -> Int {
        guard let converted = Int(exactly: value) else {
            throw RustCodeMapArtifactBuilderError.numericOverflow
        }
        return converted
    }
}

private extension CoreCodeMapSubjectRequestV1 {
    init(source: CodeMapCoreSourceSnapshot, language: LanguageType) {
        switch source.decodeResult {
        case let .decoded(decoded):
            self.init(
                languageID: language.coreCodeMapLanguageID,
                sourceKind: .decoded,
                sourceUTF8: Data(decoded.text.utf8)
            )
        case .failed(.undecodable):
            self.init(
                languageID: language.coreCodeMapLanguageID,
                sourceKind: .decodeFailedUndecodable,
                sourceUTF8: Data()
            )
        }
    }
}

private extension LanguageType {
    var coreCodeMapLanguageID: UInt16 {
        switch self {
        case .swift: 1
        case .js: 2
        case .c_sharp: 3
        case .python: 4
        case .c: 5
        case .rust: 6
        case .cpp: 7
        case .go: 8
        case .java: 9
        case .ts: 10
        case .tsx: 11
        case .php: 12
        case .ruby: 13
        }
    }
}
