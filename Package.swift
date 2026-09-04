// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// Telemetry (Sentry) is resolved deterministically but linked only when explicitly
// requested. The official Developer ID release pipeline sets
// AGENTRY_ENABLE_SENTRY=1; local builds use the same gate for intentional
// Sentry testing.
let environment = ProcessInfo.processInfo.environment
let sentryEnabled = environment["AGENTRY_ENABLE_SENTRY"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.3"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "2.3.0"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.6.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.8.0"),
    .package(url: "https://github.com/apple/swift-system.git", exact: "1.6.4"),
    .package(url: "https://github.com/repoprompt/swift-sdk.git", revision: "85dec2fc7a27252bc33dc7728be6af6b3bd398c0"),
    .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic", revision: "b7d030cd7453f314c780f5492385f73d704cbd5d"),
    .package(url: "https://github.com/repoprompt/SwiftOpenAI", revision: "1211782eb337e7968124448a20d9260df1952012"),
    .package(url: "https://github.com/loopwork-ai/JSONSchema.git", exact: "1.3.0"),
    .package(url: "https://github.com/loopwork-ai/ontology.git", exact: "0.6.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.17.1"),
    .package(path: "Packages/RepoPromptAgentProviders")
]

var repoPromptAppDependencies: [Target.Dependency] = [
    "AgentryCoreBridge",
    "RepoPromptDomainRuntime",
    "RepoPromptCodeMapCore",
    "RepoPromptSearchCore",
    "RepoPromptWorkspaceCore",
    "RepoPromptShared",
    "Sparkle",
    .product(name: "Logging", package: "swift-log"),
    .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
    .product(name: "MarkdownUI", package: "swift-markdown-ui"),
    .product(name: "Markdown", package: "swift-markdown"),
    .product(name: "MCP", package: "swift-sdk"),
    .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
    .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
    .product(name: "JSONSchema", package: "JSONSchema"),
    .product(name: "Ontology", package: "ontology"),
    .product(name: "RepoPromptClaudeCompatibleProvider", package: "RepoPromptAgentProviders")
]

var repoPromptAppSwiftSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug)),
    .enableUpcomingFeature("BareSlashRegexLiterals")
]

if sentryEnabled {
    let sentryDependency = Target.Dependency.product(name: "Sentry", package: "sentry-cocoa")
    repoPromptAppDependencies.append(sentryDependency)
    repoPromptAppSwiftSettings.append(.define("AGENTRY_SENTRY_ENABLED"))
}

let swift6LanguageMode: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

let rustArtifactRoot = "\(packageRoot)/.build/agentry-rust/current"
let rustFFISwiftSettings = swift6LanguageMode + [
    .define("DEBUG", .when(configuration: .debug)),
    .unsafeFlags(["-strict-concurrency=complete", "-warnings-as-errors"])
]

let package = Package(
    name: "Agentry",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Agentry", targets: ["RepoPrompt"]),
        .executable(name: "agentry-mcp", targets: ["RepoPromptMCP"])
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "CAgentryRustCore",
            path: "Sources/CAgentryRustCore",
            sources: ["shim.c"],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I", rustArtifactRoot])
            ],
            linkerSettings: [
                .unsafeFlags(["\(rustArtifactRoot)/libagentry_ffi.a"])
            ]
        ),
        .target(
            name: "AgentryUniFFIRaw",
            dependencies: ["CAgentryRustCore"],
            path: "Sources/AgentryUniFFIRaw",
            sources: ["Generated"],
            swiftSettings: rustFFISwiftSettings
        ),
        .target(
            name: "AgentryCoreBridge",
            dependencies: ["AgentryUniFFIRaw"],
            path: "Sources/AgentryCoreBridge",
            swiftSettings: rustFFISwiftSettings
        ),
        .executableTarget(
            name: "RepoPrompt",
            dependencies: ["RepoPromptApp"],
            path: "Sources/RepoPromptExecutable"
        ),
        .target(
            name: "RepoPromptDomainRuntime",
            dependencies: [
                "RepoPromptShared",
                "RepoPromptCodeMapCore",
                "AgentryCoreBridge",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/RepoPromptDomainRuntime",
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "RepoPromptWorkspaceCore",
            path: "Sources/RepoPromptWorkspaceCore"
        ),
        .target(
            name: "RepoPromptSearchCore",
            dependencies: ["AgentryCoreBridge"],
            path: "Sources/RepoPromptSearchCore",
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "RepoPromptCodeMapCore",
            path: "Sources/RepoPromptCodeMapCore",
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "RepoPromptApp",
            dependencies: repoPromptAppDependencies,
            path: "Sources/RepoPrompt",
            swiftSettings: repoPromptAppSwiftSettings
        ),
        .executableTarget(
            name: "RepoPromptMCP",
            dependencies: ["RepoPromptShared", "RepoPromptDomainRuntime", "RepoPromptCodeMapCore", .product(name: "Logging", package: "swift-log"), .product(name: "MCP", package: "swift-sdk"), .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"), .product(name: "SystemPackage", package: "swift-system")],
            path: "Sources/RepoPromptMCP",
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .target(
            name: "RepoPromptShared",
            path: "Sources/RepoPromptShared",
            swiftSettings: swift6LanguageMode + [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle/Sparkle.xcframework")
    ],
    swiftLanguageModes: [.v5]
)
