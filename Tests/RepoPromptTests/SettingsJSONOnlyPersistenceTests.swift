import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Focused JSON-only settings contracts: Agentry storage identity, lineage/ceiling
/// fail-closed preservation, and unlineaged v4 foreign files. Broader Context Builder
/// migration coverage was retired with the low-value suite cleanup.
@MainActor
final class SettingsJSONOnlyPersistenceTests: XCTestCase {
    func testDefaultGlobalSettingsFileStorePathUsesAgentrySupportRoot() {
        let path = GlobalSettingsFileStore.defaultFileURL().path
        XCTAssertTrue(path.contains("/Application Support/Agentry/Settings/globalSettings.json"), path)
        XCTAssertFalse(path.contains("/Application Support/RepoPrompt CE/"), path)
        XCTAssertFalse(path.contains("/Application Support/RepoPrompt/"), path)
    }

    /// GUARD RAIL — do not "fix" this by raising the ceiling. Classic/internal RepoPrompt
    /// wrote unlineaged schemaVersion 3/4 globalSettings.json files into live Application
    /// Support folders before CE introduced schemaLineage. The ceiling is frozen at 2 so those
    /// foreign files stay in the incompatible/import lane even after CE reaches v3/v4.
    func testLegacyUnlineagedCeilingIsFrozenAtTwo() {
        XCTAssertEqual(GlobalSettingsDocument.legacyUnlineagedSchemaVersionCeiling, 2)
    }

    func testUnlineagedHigherSchemaStaysBlockedAfterFutureNumericSchemaCatchup() {
        XCTAssertEqual(
            GlobalSettingsFileStore.preservationBlockReason(
                schemaVersion: 4,
                schemaLineage: nil,
                supportedVersion: 4
            ),
            .incompatibleSchema
        )
        XCTAssertNil(
            GlobalSettingsFileStore.preservationBlockReason(
                schemaVersion: 4,
                schemaLineage: GlobalSettingsDocument.schemaLineage,
                supportedVersion: 4
            )
        )
        XCTAssertEqual(
            GlobalSettingsFileStore.preservationBlockReason(
                schemaVersion: 5,
                schemaLineage: GlobalSettingsDocument.schemaLineage,
                supportedVersion: 4
            ),
            .unsupportedFutureSchema(onDiskVersion: 5, supportedVersion: 4)
        )
        XCTAssertNil(
            GlobalSettingsFileStore.preservationBlockReason(
                schemaVersion: 2,
                schemaLineage: nil,
                supportedVersion: 4
            )
        )
    }

    func testCorruptGlobalSettingsIsBackedUpAndReplacedWithDefaults() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL, now: { Date(timeIntervalSince1970: 0) })
        let document = fileStore.loadOrCreateDefault()

        XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let backupDirectory = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("globalSettings.corrupt-") })
    }

    func testFutureGlobalSettingsSchemaIsPreservedAndSaveIsBlocked() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z"}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let document = fileStore.loadOrCreateDefault()

        XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
        let preserved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(preserved, futureJSON)
        XCTAssertThrowsError(try fileStore.save(GlobalSettingsDocument())) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .unsupportedFutureSchemaPreserved)
        }
    }

    /// A realistic unlineaged v4 settings file from another build must be treated as a foreign
    /// schema: surfaced, preserved byte-for-byte, and never overwritten by CE saves.
    func testVersionFourSettingsFileWithAgentModelsKeyIsPreserved() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let versionFourJSON = #"{"schemaVersion":4,"updatedAt":"2026-06-27T13:11:41Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"agentModelsSettingsByWorkspaceID":{"workspace-1":{"selectedAgentRaw":"claudeCode"}},"globalDefaults":{"discoverAgentRaw":"claudeCode"},"scalarPreferences":{"ui":{"appearanceMode":"dark"}}}"#
        try Data(versionFourJSON.utf8).write(to: fileURL)

        let store = try makeStore(at: fileURL)
        XCTAssertEqual(
            store.persistenceBlockReason,
            .incompatibleSchema
        )

        store.setGlobalContextBuilderAgentSelection(agentRaw: "codexExec", modelRaw: "default", markUserDefined: true)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), versionFourJSON)
    }

    private func makeStore(at fileURL: URL) throws -> GlobalSettingsStore {
        let suiteName = "SettingsJSONOnlyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsJSONOnlyPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
