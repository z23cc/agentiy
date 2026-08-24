import Foundation
import RepoPromptDomainRuntime

private actor WorkspaceFileEditRawReadState {
    struct PendingWrite {
        let fingerprint: FileContentFingerprint
        let preservationEncodingRawValue: UInt
    }

    private var pendingWrite: PendingWrite?

    func record(_ snapshot: ValidatedRawFileContentSnapshot) {
        pendingWrite = PendingWrite(
            fingerprint: snapshot.fingerprint,
            preservationEncodingRawValue: snapshot.detectedEncodingRawValue ?? String.Encoding.utf8.rawValue
        )
    }

    func takePendingWrite() -> PendingWrite? {
        defer { pendingWrite = nil }
        return pendingWrite
    }
}

struct WorkspaceFileEditHost: FileEditHost, RawBytesFileEditHost {
    enum Target {
        case existing(WorkspaceFileRecord)
        case create(path: String)
    }

    let mutationService: WorkspaceFileMutationService
    let target: Target
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let lookupRootScope: WorkspaceLookupRootScope
    let createPathResolutionPolicy: WorkspaceFileCreatePathResolutionPolicy
    let selectCreatedFiles: Bool
    let mutationRootMappings: [DomainMutationPhysicalRootMapping]
    private let rawReadState = WorkspaceFileEditRawReadState()

    init(
        store: WorkspaceFileContextStore,
        target: Target,
        selectionCoordinator: WorkspaceSelectionCoordinator? = nil,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        createPathResolutionPolicy: WorkspaceFileCreatePathResolutionPolicy = .literalPreferredIfStronger,
        selectCreatedFiles: Bool = true,
        mutationRootMappings: [DomainMutationPhysicalRootMapping] = []
    ) {
        mutationService = WorkspaceFileMutationService(store: store)
        self.target = target
        self.selectionCoordinator = selectionCoordinator
        self.lookupRootScope = lookupRootScope
        self.createPathResolutionPolicy = createPathResolutionPolicy
        self.selectCreatedFiles = selectCreatedFiles
        self.mutationRootMappings = mutationRootMappings
    }

    func fileExists(path _: String) async -> Bool {
        if case .existing = target { return true }
        return false
    }

    func readText(path _: String) async throws -> String {
        guard case let .existing(file) = target else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Cannot read a missing file before creation.")
        }
        guard let content = try await mutationService.readText(file: file) else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                "The resolved file is no longer present or readable."
            )
        }
        return content
    }

    func readRawBytes(path _: String) async throws -> Data {
        guard case let .existing(file) = target else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Cannot read a missing file before creation.")
        }
        let snapshot = try await mutationService.readRawContentForTextMutation(file: file)
        await rawReadState.record(snapshot)
        return snapshot.data
    }

    func writeTextIfUnchanged(path _: String, content: String, expectedOriginalText: String) async throws {
        guard case let .existing(file) = target else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Approved writes require an existing file.")
        }
        try Task.checkCancellation()
        if let pendingWrite = await rawReadState.takePendingWrite() {
            try await mutationService.overwriteIfUnchanged(
                file: file,
                content: content,
                expectedOriginalFingerprint: pendingWrite.fingerprint,
                preservationEncodingRawValue: pendingWrite.preservationEncodingRawValue,
                mutationRootMappings: mutationRootMappings
            )
        } else {
            try await mutationService.overwriteIfUnchanged(
                file: file,
                content: content,
                expectedOriginalContent: expectedOriginalText,
                mutationRootMappings: mutationRootMappings
            )
        }
    }

    func writeText(path _: String, content: String, overwrite: Bool) async throws {
        switch target {
        case let .existing(file):
            guard overwrite else {
                throw FileManagerError.fileSystemServiceNotFoundWithContext("Existing file write requires overwrite semantics.")
            }
            try Task.checkCancellation()
            try await mutationService.overwrite(
                file: file,
                content: content,
                mutationRootMappings: mutationRootMappings
            )

        case let .create(path):
            try Task.checkCancellation()
            let writeResult = try await mutationService.createFileWithPostcondition(
                userPath: path,
                content: content,
                rootScope: lookupRootScope,
                selectedFileFullPaths: (path as NSString).expandingTildeInPath.hasPrefix("/") ? [] : selectedFileFullPaths(),
                pathResolutionPolicy: createPathResolutionPolicy,
                mutationRootMappings: mutationRootMappings
            )
            if selectCreatedFiles, let selectionCoordinator, let created = writeResult.materializedFile {
                _ = await selectionCoordinator.addPathsToActiveSelection(
                    paths: [created.standardizedFullPath],
                    mode: "full",
                    rootScope: lookupRootScope
                )
            }
        }
    }

    @MainActor
    private func selectedFileFullPaths() -> Set<String> {
        guard let selectionCoordinator else { return [] }
        let snapshot = selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true)
        return Set(StoredSelectionPathNormalization.standardizedPaths(snapshot.selection.selectedPaths))
    }
}
