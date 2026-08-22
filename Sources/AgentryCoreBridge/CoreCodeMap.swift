import Foundation

public enum CoreComputeError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case malformedResponse
    case runtimeInvalidated
    case runtimeStopped
    case runtimePoisoned
    case transportFailure(String)
}

extension CoreComputeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message): "The core rejected the compute request: \(message)"
        case .malformedResponse: "The core returned a malformed compact compute result."
        case .runtimeInvalidated: "The Rust runtime was invalidated."
        case .runtimeStopped: "The Rust runtime is stopped."
        case .runtimePoisoned: "The Rust runtime is poisoned."
        case let .transportFailure(message): "Rust compute transport failed: \(message)"
        }
    }
}

public enum CoreCodeMapSourceKind: UInt8, Sendable, Equatable, Hashable {
    case decoded = 0
    case decodeFailedUndecodable = 1
    /// TD-3 (`docs/designs/textdecode-policy-v2-2026-08-22.md` §6.1): `sourceUTF8` carries
    /// genuinely raw, possibly-non-UTF-8 bytes; Rust's `textdecode` (never fails) runs as
    /// codemap's first step instead of a strict UTF-8 validity check.
    case raw = 2
}

public struct CoreCodeMapSubjectRequestV1: Sendable, Equatable {
    public let languageID: UInt16
    public let sourceKind: CoreCodeMapSourceKind
    public let sourceUTF8: Data

    public init(languageID: UInt16, sourceKind: CoreCodeMapSourceKind = .decoded, sourceUTF8: Data) {
        self.languageID = languageID
        self.sourceKind = sourceKind
        self.sourceUTF8 = sourceUTF8
    }

    public init(languageID: UInt16, source: String) {
        self.init(languageID: languageID, sourceUTF8: Data(source.utf8))
    }
}

public struct CoreCodeMapBatchRequestV1: Sendable, Equatable {
    public static let contractVersion: UInt16 = 1

    public let contractVersion: UInt16
    public let subjects: [CoreCodeMapSubjectRequestV1]

    public init(contractVersion: UInt16 = Self.contractVersion, subjects: [CoreCodeMapSubjectRequestV1]) {
        self.contractVersion = contractVersion
        self.subjects = subjects
    }
}

public struct CoreCodeMapParameter: Sendable, Equatable, Hashable {
    public let externalName: String?
    public let localName: String
    public let typeName: String?

    public init(externalName: String?, localName: String, typeName: String?) {
        self.externalName = externalName
        self.localName = localName
        self.typeName = typeName
    }
}

public struct CoreCodeMapFunction: Sendable, Equatable, Hashable {
    public let name: String
    public let parameters: [CoreCodeMapParameter]
    public let returnType: String?
    public let definitionLine: String
    public let lineNumber: UInt64?

    public init(
        name: String,
        parameters: [CoreCodeMapParameter],
        returnType: String?,
        definitionLine: String,
        lineNumber: UInt64?
    ) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.definitionLine = definitionLine
        self.lineNumber = lineNumber
    }
}

public struct CoreCodeMapProperty: Sendable, Equatable, Hashable {
    public let name: String
    public let typeName: String?

    public init(name: String, typeName: String?) {
        self.name = name
        self.typeName = typeName
    }
}

public struct CoreCodeMapClass: Sendable, Equatable, Hashable {
    public let name: String
    public let methods: [CoreCodeMapFunction]
    public let properties: [CoreCodeMapProperty]

    public init(name: String, methods: [CoreCodeMapFunction], properties: [CoreCodeMapProperty]) {
        self.name = name
        self.methods = methods
        self.properties = properties
    }
}

public struct CoreCodeMapInterface: Sendable, Equatable, Hashable {
    public let name: String
    public let methods: [CoreCodeMapFunction]
    public let properties: [CoreCodeMapProperty]

    public init(name: String, methods: [CoreCodeMapFunction], properties: [CoreCodeMapProperty]) {
        self.name = name
        self.methods = methods
        self.properties = properties
    }
}

public struct CoreCodeMapTypeAlias: Sendable, Equatable, Hashable {
    public let name: String
    public let definitionLine: String

    public init(name: String, definitionLine: String) {
        self.name = name
        self.definitionLine = definitionLine
    }
}

public struct CoreCodeMapEnum: Sendable, Equatable, Hashable {
    public let name: String
    public let cases: [String]

    public init(name: String, cases: [String]) {
        self.name = name
        self.cases = cases
    }
}

public struct CoreCodeMapVariable: Sendable, Equatable, Hashable {
    public let name: String
    public let typeName: String?
    public let definitionLine: String

    public init(name: String, typeName: String?, definitionLine: String) {
        self.name = name
        self.typeName = typeName
        self.definitionLine = definitionLine
    }
}

public struct CoreCodeMapArtifact: Sendable, Equatable {
    public let imports: [String]
    public let exports: [String]
    public let classes: [CoreCodeMapClass]
    public let interfaces: [CoreCodeMapInterface]
    public let aliases: [CoreCodeMapTypeAlias]
    public let literalUnions: [String]
    public let functions: [CoreCodeMapFunction]
    public let enums: [CoreCodeMapEnum]
    public let globalVariables: [CoreCodeMapVariable]
    public let macros: [String]
    public let referencedTypes: [String]

    public init(
        imports: [String],
        exports: [String],
        classes: [CoreCodeMapClass],
        interfaces: [CoreCodeMapInterface],
        aliases: [CoreCodeMapTypeAlias],
        literalUnions: [String],
        functions: [CoreCodeMapFunction],
        enums: [CoreCodeMapEnum],
        globalVariables: [CoreCodeMapVariable],
        macros: [String],
        referencedTypes: [String]
    ) {
        self.imports = imports
        self.exports = exports
        self.classes = classes
        self.interfaces = interfaces
        self.aliases = aliases
        self.literalUnions = literalUnions
        self.functions = functions
        self.enums = enums
        self.globalVariables = globalVariables
        self.macros = macros
        self.referencedTypes = referencedTypes
    }
}

public enum CoreCodeMapSubjectOutcome: Sendable, Equatable {
    case ready(CoreCodeMapArtifact)
    case readyNoSymbols
    case oversizeUTF8Bytes(actual: UInt64, limit: UInt64)
    case oversizeUTF16Units(actual: UInt64, limit: UInt64)
    case oversizeLines(actual: UInt64, limit: UInt64)
    case decodeFailedUndecodable
    case parseFailedNilTree
    case parseFailedNilRoot
}

public struct CoreCodeMapSubjectResultV1: Sendable, Equatable {
    public let languageID: UInt16
    public let sourceByteCount: UInt64
    public let outcome: CoreCodeMapSubjectOutcome

    public init(languageID: UInt16, sourceByteCount: UInt64, outcome: CoreCodeMapSubjectOutcome) {
        self.languageID = languageID
        self.sourceByteCount = sourceByteCount
        self.outcome = outcome
    }
}

public struct CoreCodeMapBatchResultV1: Sendable, Equatable {
    public let subjects: [CoreCodeMapSubjectResultV1]

    public init(subjects: [CoreCodeMapSubjectResultV1]) {
        self.subjects = subjects
    }
}

public struct CoreComputeClient: Sendable {
    let bridge: AgentryCoreBridge

    public func extractCodeMapBatchV1(_ request: CoreCodeMapBatchRequestV1) async throws -> CoreCodeMapBatchResultV1 {
        try Self.validate(request)
        guard !request.subjects.isEmpty else { return .init(subjects: []) }
        let context = try await bridge.prepareComputeOperation()
        defer { try? context.transport.closeLeafCancellation(context.cancellation, identity: context.identity) }
        do {
            let compact = try await withTaskCancellationHandler {
                if Task.isCancelled {
                    try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
                    throw CancellationError()
                }
                return try await Task.detached(priority: nil) {
                    try context.transport.codeMapExtractBatchCompactV1(
                        identity: context.identity,
                        cancellation: context.cancellation,
                        request: request
                    )
                }.value
            } onCancel: {
                try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
            }
            if Task.isCancelled { throw CancellationError() }
            let validated = try CoreCodeMapCompactValidator.validate(compact, request: request)
            try context.transport.closeLeafCancellation(context.cancellation, identity: context.identity)
            try await bridge.validateComputeCompletion(identity: context.identity)
            return try CoreCodeMapCompactValidator.materialize(validated, compact: compact)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await bridge.mapComputeFailure(error)
        }
    }

    private static func validate(_ request: CoreCodeMapBatchRequestV1) throws {
        guard request.contractVersion == CoreCodeMapBatchRequestV1.contractVersion else {
            throw CoreComputeError.invalidRequest("unsupported codemap contract version")
        }
        for subject in request.subjects {
            guard (1 ... 13).contains(subject.languageID) else {
                throw CoreComputeError.invalidRequest("unknown codemap language ID")
            }
            switch subject.sourceKind {
            case .decoded:
                guard String(data: subject.sourceUTF8, encoding: .utf8) != nil else {
                    throw CoreComputeError.invalidRequest("decoded codemap source is not UTF-8")
                }
            case .decodeFailedUndecodable:
                guard subject.sourceUTF8.isEmpty else {
                    throw CoreComputeError.invalidRequest("decode-failed codemap source must be empty")
                }
            case .raw:
                // Any byte sequence is acceptable: Rust's textdecode() never fails (design §5.1).
                break
            }
        }
    }
}

extension CoreRuntimeTransport {
    func codeMapExtractBatchCompactV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCodeMapBatchRequestV1
    ) throws -> CoreCompactCodeMapBatchResultV1 {
        throw CoreTransportError.unexpected("codemap compact transport is unavailable")
    }
}

struct CoreComputeOperationContext {
    let transport: any CoreRuntimeTransport
    let identity: CoreRuntimeIdentity
    let cancellation: any CoreLeafCancellationHandle
}

struct CoreCompactTableRange: Equatable {
    let start: UInt64
    let count: UInt64
}

enum CoreCompactCodeMapOutcomeTag: UInt8, Equatable {
    case ready = 0
    case readyNoSymbols = 1
    case oversizeUTF8Bytes = 2
    case oversizeUTF16Units = 3
    case oversizeLines = 4
    case decodeFailedUndecodable = 5
    case parseFailedNilTree = 6
    case parseFailedNilRoot = 7
}

struct CoreCompactCodeMapSubjectSummaryV1: Equatable {
    let languageID: UInt16
    let sourceByteCount: UInt64
    let outcomeTag: CoreCompactCodeMapOutcomeTag
    let outcomeActual: UInt64
    let outcomeLimit: UInt64
    let blob: CoreCompactTableRange
    let strings: CoreCompactTableRange
    let stringIndices: CoreCompactTableRange
    let classPool: CoreCompactTableRange
    let interfacePool: CoreCompactTableRange
    let aliasPool: CoreCompactTableRange
    let functionPool: CoreCompactTableRange
    let parameterPool: CoreCompactTableRange
    let propertyPool: CoreCompactTableRange
    let enumPool: CoreCompactTableRange
    let variablePool: CoreCompactTableRange
    let imports: CoreCompactTableRange
    let exports: CoreCompactTableRange
    let classes: CoreCompactTableRange
    let interfaces: CoreCompactTableRange
    let aliases: CoreCompactTableRange
    let literalUnions: CoreCompactTableRange
    let functions: CoreCompactTableRange
    let enums: CoreCompactTableRange
    let globalVariables: CoreCompactTableRange
    let macros: CoreCompactTableRange
    let referencedTypes: CoreCompactTableRange
}

struct CoreCompactCodeMapBatchResultV1: Equatable {
    let subjectSummaries: [CoreCompactCodeMapSubjectSummaryV1]
    let utf8Blob: Data
    let stringRangeWords: [UInt64]
    let stringIndexWords: [UInt64]
    let classWords: [UInt64]
    let interfaceWords: [UInt64]
    let aliasWords: [UInt64]
    let functionWords: [UInt64]
    let parameterWords: [UInt64]
    let propertyWords: [UInt64]
    let enumWords: [UInt64]
    let variableWords: [UInt64]
}

private struct CoreCodeMapValidatedBatch {
    let subjects: [CoreCodeMapValidatedSubject]
}

private struct CoreCodeMapValidatedSubject {
    let summary: CoreCompactCodeMapSubjectSummaryV1
    let strings: [String]
}

private enum CoreCodeMapCompactValidator {
    static let optional = UInt64.max
    static let stringRangeStride = 2
    static let classStride = 5
    static let interfaceStride = 5
    static let aliasStride = 2
    static let functionStride = 6
    static let parameterStride = 3
    static let propertyStride = 2
    static let enumStride = 3
    static let variableStride = 3

    static func validate(
        _ value: CoreCompactCodeMapBatchResultV1,
        request: CoreCodeMapBatchRequestV1
    ) throws -> CoreCodeMapValidatedBatch {
        guard value.subjectSummaries.count == request.subjects.count,
              value.stringRangeWords.count.isMultiple(of: stringRangeStride),
              value.classWords.count.isMultiple(of: classStride),
              value.interfaceWords.count.isMultiple(of: interfaceStride),
              value.aliasWords.count.isMultiple(of: aliasStride),
              value.functionWords.count.isMultiple(of: functionStride),
              value.parameterWords.count.isMultiple(of: parameterStride),
              value.propertyWords.count.isMultiple(of: propertyStride),
              value.enumWords.count.isMultiple(of: enumStride),
              value.variableWords.count.isMultiple(of: variableStride)
        else { throw CoreComputeError.malformedResponse }

        let totals = TableCounts(value)
        var cursors = TableCounts()
        var subjects: [CoreCodeMapValidatedSubject] = []
        subjects.reserveCapacity(request.subjects.count)

        for (summary, requestSubject) in zip(value.subjectSummaries, request.subjects) {
            guard summary.languageID == requestSubject.languageID,
                  summary.sourceByteCount == UInt64(requestSubject.sourceUTF8.count)
            else { throw CoreComputeError.malformedResponse }

            let ranges = try SubjectRanges(summary)
            try cursors.requireStarts(of: ranges)
            try ranges.requireInBounds(totals: totals)
            let strings = try validateStrings(value, summary: summary)
            try validateOutcome(summary, ranges: ranges)
            try validateReferences(value, summary: summary, strings: strings)
            subjects.append(.init(summary: summary, strings: strings))
            cursors.advance(by: ranges)
        }
        guard cursors == totals else { throw CoreComputeError.malformedResponse }
        return CoreCodeMapValidatedBatch(subjects: subjects)
    }

    static func materialize(
        _ validated: CoreCodeMapValidatedBatch,
        compact: CoreCompactCodeMapBatchResultV1
    ) throws -> CoreCodeMapBatchResultV1 {
        var results: [CoreCodeMapSubjectResultV1] = []
        results.reserveCapacity(validated.subjects.count)
        for subject in validated.subjects {
            let summary = subject.summary
            let outcome: CoreCodeMapSubjectOutcome = switch summary.outcomeTag {
            case .ready:
                try .ready(artifact(summary, strings: subject.strings, compact: compact))
            case .readyNoSymbols: .readyNoSymbols
            case .oversizeUTF8Bytes: .oversizeUTF8Bytes(actual: summary.outcomeActual, limit: summary.outcomeLimit)
            case .oversizeUTF16Units: .oversizeUTF16Units(actual: summary.outcomeActual, limit: summary.outcomeLimit)
            case .oversizeLines: .oversizeLines(actual: summary.outcomeActual, limit: summary.outcomeLimit)
            case .decodeFailedUndecodable: .decodeFailedUndecodable
            case .parseFailedNilTree: .parseFailedNilTree
            case .parseFailedNilRoot: .parseFailedNilRoot
            }
            results.append(.init(languageID: summary.languageID, sourceByteCount: summary.sourceByteCount, outcome: outcome))
        }
        return .init(subjects: results)
    }

    private static func validateStrings(
        _ value: CoreCompactCodeMapBatchResultV1,
        summary: CoreCompactCodeMapSubjectSummaryV1
    ) throws -> [String] {
        let blob = try slice(value.utf8Blob, range: summary.blob)
        guard String(data: blob, encoding: .utf8) != nil else { throw CoreComputeError.malformedResponse }
        let rows = try wordRows(value.stringRangeWords, range: summary.strings, stride: stringRangeStride)
        guard let blobStart = Int(exactly: summary.blob.start),
              let blobCount = Int(exactly: summary.blob.count)
        else { throw CoreComputeError.malformedResponse }
        let (blobEnd, overflow) = blobStart.addingReportingOverflow(blobCount)
        guard !overflow, blobEnd <= value.utf8Blob.count else {
            throw CoreComputeError.malformedResponse
        }
        var expectedByte = blobStart
        var strings: [String] = []
        strings.reserveCapacity(rows.count)
        for row in rows {
            guard let start = Int(exactly: row[0]), let end = Int(exactly: row[1]),
                  start == expectedByte, start <= end, end <= blobEnd,
                  isUTF8Boundary(start, in: value.utf8Blob), isUTF8Boundary(end, in: value.utf8Blob),
                  String(data: value.utf8Blob[start ..< end], encoding: .utf8) != nil
            else { throw CoreComputeError.malformedResponse }
            // Non-stripping decode: keep a legitimate leading U+FEFF aligned
            // with the Rust engine's byte offsets.
            strings.append(String(decoding: value.utf8Blob[start ..< end], as: UTF8.self))
            expectedByte = end
        }
        guard expectedByte == blobEnd else { throw CoreComputeError.malformedResponse }
        return strings
    }

    private static func validateOutcome(
        _ summary: CoreCompactCodeMapSubjectSummaryV1,
        ranges: SubjectRanges
    ) throws {
        switch summary.outcomeTag {
        case .ready:
            guard summary.outcomeActual == 0, summary.outcomeLimit == 0 else { throw CoreComputeError.malformedResponse }
        case .readyNoSymbols:
            guard ranges.artifactRowsAreEmpty, summary.outcomeActual == 0, summary.outcomeLimit == 0 else {
                throw CoreComputeError.malformedResponse
            }
        case .oversizeUTF8Bytes, .oversizeUTF16Units, .oversizeLines:
            guard ranges.artifactRowsAreEmpty,
                  summary.outcomeLimit > 0,
                  summary.outcomeActual > summary.outcomeLimit
            else { throw CoreComputeError.malformedResponse }
        case .decodeFailedUndecodable, .parseFailedNilTree, .parseFailedNilRoot:
            guard ranges.artifactRowsAreEmpty, summary.outcomeActual == 0, summary.outcomeLimit == 0 else {
                throw CoreComputeError.malformedResponse
            }
        }
    }

    private static func validateReferences(
        _ value: CoreCompactCodeMapBatchResultV1,
        summary: CoreCompactCodeMapSubjectSummaryV1,
        strings: [String]
    ) throws {
        let stringBounds = try compactBounds(summary.strings)
        let indexBounds = try compactBounds(summary.stringIndices)
        let functionBounds = try compactBounds(summary.functionPool)
        let parameterBounds = try compactBounds(summary.parameterPool)
        let propertyBounds = try compactBounds(summary.propertyPool)

        for word in try words(value.stringIndexWords, range: summary.stringIndices) {
            try requireReference(word, in: stringBounds)
        }
        for row in try wordRows(value.classWords, range: summary.classPool, stride: classStride) {
            try requireReference(row[0], in: stringBounds)
            try requireRange(start: row[1], count: row[2], in: functionBounds)
            try requireRange(start: row[3], count: row[4], in: propertyBounds)
        }
        for row in try wordRows(value.interfaceWords, range: summary.interfacePool, stride: interfaceStride) {
            try requireReference(row[0], in: stringBounds)
            try requireRange(start: row[1], count: row[2], in: functionBounds)
            try requireRange(start: row[3], count: row[4], in: propertyBounds)
        }
        for row in try wordRows(value.aliasWords, range: summary.aliasPool, stride: aliasStride) {
            try requireReference(row[0], in: stringBounds)
            try requireReference(row[1], in: stringBounds)
        }
        for row in try wordRows(value.functionWords, range: summary.functionPool, stride: functionStride) {
            try requireReference(row[0], in: stringBounds)
            try requireRange(start: row[1], count: row[2], in: parameterBounds)
            try requireOptionalReference(row[3], in: stringBounds)
            try requireReference(row[4], in: stringBounds)
            guard row[5] == optional || Int(exactly: row[5]) != nil else { throw CoreComputeError.malformedResponse }
        }
        for row in try wordRows(value.parameterWords, range: summary.parameterPool, stride: parameterStride) {
            try requireOptionalReference(row[0], in: stringBounds)
            try requireReference(row[1], in: stringBounds)
            try requireOptionalReference(row[2], in: stringBounds)
        }
        for row in try wordRows(value.propertyWords, range: summary.propertyPool, stride: propertyStride) {
            try requireReference(row[0], in: stringBounds)
            try requireOptionalReference(row[1], in: stringBounds)
        }
        for row in try wordRows(value.enumWords, range: summary.enumPool, stride: enumStride) {
            try requireReference(row[0], in: stringBounds)
            try requireRange(start: row[1], count: row[2], in: indexBounds)
        }
        for row in try wordRows(value.variableWords, range: summary.variablePool, stride: variableStride) {
            try requireReference(row[0], in: stringBounds)
            try requireOptionalReference(row[1], in: stringBounds)
            try requireReference(row[2], in: stringBounds)
        }

        try requireRange(summary.imports, in: indexBounds)
        try requireRange(summary.exports, in: indexBounds)
        try requireRange(summary.classes, in: compactBounds(summary.classPool))
        try requireRange(summary.interfaces, in: compactBounds(summary.interfacePool))
        try requireRange(summary.aliases, in: compactBounds(summary.aliasPool))
        try requireRange(summary.literalUnions, in: indexBounds)
        try requireRange(summary.functions, in: functionBounds)
        try requireRange(summary.enums, in: compactBounds(summary.enumPool))
        try requireRange(summary.globalVariables, in: compactBounds(summary.variablePool))
        try requireRange(summary.macros, in: indexBounds)
        try requireRange(summary.referencedTypes, in: indexBounds)
        _ = strings
    }

    private static func artifact(
        _ summary: CoreCompactCodeMapSubjectSummaryV1,
        strings: [String],
        compact: CoreCompactCodeMapBatchResultV1
    ) throws -> CoreCodeMapArtifact {
        func string(_ absolute: UInt64) throws -> String {
            guard let absolute = Int(exactly: absolute), let start = Int(exactly: summary.strings.start),
                  absolute >= start, absolute - start < strings.count
            else { throw CoreComputeError.malformedResponse }
            return strings[absolute - start]
        }
        func optionalString(_ value: UInt64) throws -> String? {
            value == optional ? nil : try string(value)
        }
        func stringList(_ range: CoreCompactTableRange) throws -> [String] {
            try words(compact.stringIndexWords, range: range).map { try string($0) }
        }
        func parameters(_ range: CoreCompactTableRange) throws -> [CoreCodeMapParameter] {
            try wordRows(compact.parameterWords, range: range, stride: parameterStride).map {
                try .init(externalName: optionalString($0[0]), localName: string($0[1]), typeName: optionalString($0[2]))
            }
        }
        func properties(_ range: CoreCompactTableRange) throws -> [CoreCodeMapProperty] {
            try wordRows(compact.propertyWords, range: range, stride: propertyStride).map {
                try .init(name: string($0[0]), typeName: optionalString($0[1]))
            }
        }
        func functions(_ range: CoreCompactTableRange) throws -> [CoreCodeMapFunction] {
            try wordRows(compact.functionWords, range: range, stride: functionStride).map {
                try .init(
                    name: string($0[0]),
                    parameters: parameters(.init(start: $0[1], count: $0[2])),
                    returnType: optionalString($0[3]),
                    definitionLine: string($0[4]),
                    lineNumber: $0[5] == optional ? nil : $0[5]
                )
            }
        }
        let classes = try wordRows(compact.classWords, range: summary.classes, stride: classStride).map {
            try CoreCodeMapClass(
                name: string($0[0]),
                methods: functions(.init(start: $0[1], count: $0[2])),
                properties: properties(.init(start: $0[3], count: $0[4]))
            )
        }
        let interfaces = try wordRows(compact.interfaceWords, range: summary.interfaces, stride: interfaceStride).map {
            try CoreCodeMapInterface(
                name: string($0[0]),
                methods: functions(.init(start: $0[1], count: $0[2])),
                properties: properties(.init(start: $0[3], count: $0[4]))
            )
        }
        let aliases = try wordRows(compact.aliasWords, range: summary.aliases, stride: aliasStride).map {
            try CoreCodeMapTypeAlias(name: string($0[0]), definitionLine: string($0[1]))
        }
        let enums = try wordRows(compact.enumWords, range: summary.enums, stride: enumStride).map {
            try CoreCodeMapEnum(name: string($0[0]), cases: stringList(.init(start: $0[1], count: $0[2])))
        }
        let variables = try wordRows(compact.variableWords, range: summary.globalVariables, stride: variableStride).map {
            try CoreCodeMapVariable(name: string($0[0]), typeName: optionalString($0[1]), definitionLine: string($0[2]))
        }
        return try .init(
            imports: stringList(summary.imports),
            exports: stringList(summary.exports),
            classes: classes,
            interfaces: interfaces,
            aliases: aliases,
            literalUnions: stringList(summary.literalUnions),
            functions: functions(summary.functions),
            enums: enums,
            globalVariables: variables,
            macros: stringList(summary.macros),
            referencedTypes: stringList(summary.referencedTypes)
        )
    }
}

private struct TableCounts: Equatable {
    var blob = 0
    var strings = 0
    var stringIndices = 0
    var classes = 0
    var interfaces = 0
    var aliases = 0
    var functions = 0
    var parameters = 0
    var properties = 0
    var enums = 0
    var variables = 0

    init() {}

    init(_ value: CoreCompactCodeMapBatchResultV1) {
        blob = value.utf8Blob.count
        strings = value.stringRangeWords.count / 2
        stringIndices = value.stringIndexWords.count
        classes = value.classWords.count / 5
        interfaces = value.interfaceWords.count / 5
        aliases = value.aliasWords.count / 2
        functions = value.functionWords.count / 6
        parameters = value.parameterWords.count / 3
        properties = value.propertyWords.count / 2
        enums = value.enumWords.count / 3
        variables = value.variableWords.count / 3
    }

    mutating func requireStarts(of value: SubjectRanges) throws {
        guard blob == value.blob.start, strings == value.strings.start,
              stringIndices == value.stringIndices.start, classes == value.classes.start,
              interfaces == value.interfaces.start, aliases == value.aliases.start,
              functions == value.functions.start, parameters == value.parameters.start,
              properties == value.properties.start, enums == value.enums.start,
              variables == value.variables.start
        else { throw CoreComputeError.malformedResponse }
    }

    mutating func advance(by value: SubjectRanges) {
        blob += value.blob.count
        strings += value.strings.count
        stringIndices += value.stringIndices.count
        classes += value.classes.count
        interfaces += value.interfaces.count
        aliases += value.aliases.count
        functions += value.functions.count
        parameters += value.parameters.count
        properties += value.properties.count
        enums += value.enums.count
        variables += value.variables.count
    }
}

private struct SubjectRanges {
    let blob: (start: Int, count: Int)
    let strings: (start: Int, count: Int)
    let stringIndices: (start: Int, count: Int)
    let classes: (start: Int, count: Int)
    let interfaces: (start: Int, count: Int)
    let aliases: (start: Int, count: Int)
    let functions: (start: Int, count: Int)
    let parameters: (start: Int, count: Int)
    let properties: (start: Int, count: Int)
    let enums: (start: Int, count: Int)
    let variables: (start: Int, count: Int)

    init(_ value: CoreCompactCodeMapSubjectSummaryV1) throws {
        blob = try Self.pair(value.blob)
        strings = try Self.pair(value.strings)
        stringIndices = try Self.pair(value.stringIndices)
        classes = try Self.pair(value.classPool)
        interfaces = try Self.pair(value.interfacePool)
        aliases = try Self.pair(value.aliasPool)
        functions = try Self.pair(value.functionPool)
        parameters = try Self.pair(value.parameterPool)
        properties = try Self.pair(value.propertyPool)
        enums = try Self.pair(value.enumPool)
        variables = try Self.pair(value.variablePool)
    }

    var artifactRowsAreEmpty: Bool {
        [blob, strings, stringIndices, classes, interfaces, aliases, functions, parameters, properties, enums, variables]
            .allSatisfy { $0.count == 0 }
    }

    func requireInBounds(totals: TableCounts) throws {
        guard try Self.inBounds(blob, total: totals.blob), try Self.inBounds(strings, total: totals.strings),
              try Self.inBounds(stringIndices, total: totals.stringIndices), try Self.inBounds(classes, total: totals.classes),
              try Self.inBounds(interfaces, total: totals.interfaces), try Self.inBounds(aliases, total: totals.aliases),
              try Self.inBounds(functions, total: totals.functions), try Self.inBounds(parameters, total: totals.parameters),
              try Self.inBounds(properties, total: totals.properties), try Self.inBounds(enums, total: totals.enums),
              try Self.inBounds(variables, total: totals.variables)
        else { throw CoreComputeError.malformedResponse }
    }

    private static func pair(_ value: CoreCompactTableRange) throws -> (start: Int, count: Int) {
        guard let start = Int(exactly: value.start), let count = Int(exactly: value.count) else {
            throw CoreComputeError.malformedResponse
        }
        return (start, count)
    }

    private static func inBounds(_ value: (start: Int, count: Int), total: Int) throws -> Bool {
        let (end, overflow) = value.start.addingReportingOverflow(value.count)
        return !overflow && value.start >= 0 && value.count >= 0 && end <= total
    }
}

private extension CoreCompactTableRange {
    var isEmpty: Bool {
        count == 0
    }
}

private func compactBounds(_ range: CoreCompactTableRange) throws -> Range<Int> {
    guard let start = Int(exactly: range.start), let count = Int(exactly: range.count) else {
        throw CoreComputeError.malformedResponse
    }
    let (end, overflow) = start.addingReportingOverflow(count)
    guard !overflow else { throw CoreComputeError.malformedResponse }
    return start ..< end
}

private func slice(_ data: Data, range: CoreCompactTableRange) throws -> Data {
    let range = try compactBounds(range)
    guard range.lowerBound >= 0, range.upperBound <= data.count else { throw CoreComputeError.malformedResponse }
    return data.subdata(in: range)
}

private func words(_ values: [UInt64], range: CoreCompactTableRange) throws -> ArraySlice<UInt64> {
    let range = try compactBounds(range)
    guard range.lowerBound >= 0, range.upperBound <= values.count else { throw CoreComputeError.malformedResponse }
    return values[range]
}

private func wordRows(
    _ values: [UInt64],
    range: CoreCompactTableRange,
    stride: Int
) throws -> [[UInt64]] {
    let rowRange = try compactBounds(range)
    let (start, startOverflow) = rowRange.lowerBound.multipliedReportingOverflow(by: stride)
    let (end, endOverflow) = rowRange.upperBound.multipliedReportingOverflow(by: stride)
    guard !startOverflow, !endOverflow, start >= 0, end <= values.count else {
        throw CoreComputeError.malformedResponse
    }
    var rows: [[UInt64]] = []
    rows.reserveCapacity(rowRange.count)
    var cursor = start
    while cursor < end {
        rows.append(Array(values[cursor ..< cursor + stride]))
        cursor += stride
    }
    return rows
}

private func requireReference(_ value: UInt64, in bounds: Range<Int>) throws {
    guard let index = Int(exactly: value), bounds.contains(index) else { throw CoreComputeError.malformedResponse }
}

private func requireOptionalReference(_ value: UInt64, in bounds: Range<Int>) throws {
    if value != UInt64.max { try requireReference(value, in: bounds) }
}

private func requireRange(start: UInt64, count: UInt64, in bounds: Range<Int>) throws {
    try requireRange(.init(start: start, count: count), in: bounds)
}

private func requireRange(_ value: CoreCompactTableRange, in bounds: Range<Int>) throws {
    let value = try compactBounds(value)
    guard value.lowerBound >= bounds.lowerBound, value.upperBound <= bounds.upperBound else {
        throw CoreComputeError.malformedResponse
    }
}

private func isUTF8Boundary(_ offset: Int, in data: Data) -> Bool {
    offset == 0 || offset == data.count || (offset > 0 && offset < data.count && data[offset] & 0xC0 != 0x80)
}
