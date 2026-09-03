# Rust CodeMap Compact Contract v1

Status: Accepted (ADR-0013, Charter Phase 2; User ruling 2026-09-03).

> **Evidence update:** P2 step 13 deleted the legacy Swift extractor and `CodeMapRustSwiftDifferentialTests`. The current golden gate is `Tests/RepoPromptTests/CodeMap/CodeMapRustGoldenTests.swift` against `Tests/RepoPromptCodeMapCoreTests/Goldens`. `RepoPromptTests.CodeMapGoldenTests` covers fixture file-tree snapshot rendering only.

## Purpose and authority boundary

This contract carries path-free CodeMap computation results from `agentry-runtime` through the existing Agentry core bridge. Rust owns decoded-source guards, tree-sitter parse/query execution, capture extraction, normalization, and compact encoding. Swift remains authoritative for workspace and path resolution, source decoding policy and raw digest, scheduling/permits, cancellation orchestration, artifact identity/CAS/locator persistence, selection, MCP, and UI projection.

The production cut seam is `CodeMapArtifactBuilderClient.execute`. A core error must not silently fall back to the Swift engine and must not publish a partial artifact.

## Version and stable language IDs

Every request carries `contractVersion = 1`. Unknown versions or language IDs are invalid requests.

| ID | Language |
|---:|---|
| 1 | Swift |
| 2 | JavaScript |
| 3 | C# |
| 4 | Python |
| 5 | C |
| 6 | Rust |
| 7 | C++ |
| 8 | Go |
| 9 | Java |
| 10 | TypeScript |
| 11 | TSX |
| 12 | PHP |
| 13 | Ruby |

These IDs are wire values, not Swift enum raw strings.

## Request

```text
CoreCodeMapBatchRequestV1
  contractVersion: u16 (= 1)
  subjects: [CoreCodeMapSubjectRequestV1]

CoreCodeMapSubjectRequestV1
  languageID: u16
  sourceKind: decoded | decodeFailedUndecodable
  sourceUTF8: bytes
```

- `decoded` requires valid UTF-8.
- `decodeFailedUndecodable` requires an empty byte field and returns the deterministic decode-failed outcome without invoking a parser.
- Subject order is preserved.
- Raw SHA-256, raw byte count, decoder identity, workspace path, and artifact key remain Swift-owned and are not wire fields.
- Guards run in this order: 5,000,000 UTF-8 bytes, 1,500,000 UTF-16 code units, then 25,000 CR/LF/CRLF-aware lines. Exact counting parity is a P2-2 validation requirement; any unresolved difference is TBD rather than a contract relaxation.

## Batch-wide compact result

```text
CoreCompactCodeMapBatchResultV1
  subjectSummaries
  utf8Blob
  stringRangeWords       // stride 2
  stringIndexWords       // stride 1
  classWords             // stride 5
  interfaceWords         // stride 5
  aliasWords             // stride 2
  functionWords          // stride 6
  parameterWords         // stride 3
  propertyWords          // stride 2
  enumWords              // stride 3
  variableWords          // stride 3
```

All words are unsigned 64-bit integers. `u64::MAX` is the only optional-value sentinel and can never be a valid offset, count, or index.

### Row layouts

| Table | Words in row |
|---|---|
| `stringRangeWords` | `startByte, endByte` |
| `stringIndexWords` | `stringIndex` |
| `classWords` | `name, methodStart, methodCount, propertyStart, propertyCount` |
| `interfaceWords` | `name, methodStart, methodCount, propertyStart, propertyCount` |
| `aliasWords` | `name, definitionLine` |
| `functionWords` | `name, parameterStart, parameterCount, returnType?, definitionLine, lineNumber?` |
| `parameterWords` | `externalName?, localName, typeName?` |
| `propertyWords` | `name, typeName?` |
| `enumWords` | `name, caseIndexStart, caseIndexCount` |
| `variableWords` | `name, typeName?, definitionLine` |

`stringRangeWords` addresses the batch `utf8Blob`; all other textual fields reference string rows. The exact treatment of an absent local parameter name is TBD pending mapping against the current Swift DTO initializer.

### Subject summary

Each summary contains input language ID and source byte count, an outcome tag and values, this subject's contiguous blob/string/entity pool ranges, and top-level ranges for imports, exports, classes, interfaces, aliases, literal unions, functions, enums, global variables, macros, and referenced types.

A subject never references another subject's strings or entity pools. Cross-subject string interning is forbidden in v1 so failure isolation and monotonic validation remain simple.

## Closed outcome set

- `ready`
- `readyNoSymbols`
- `oversizeUtf8Bytes`
- `oversizeUtf16Units`
- `oversizeLines`
- `decodeFailedUndecodable`
- `parseFailedNilTree`
- `parseFailedNilRoot`

Grammar absence, ABI incompatibility, query compilation failure, cancellation, or an internal extraction invariant is a service error, not a persistable outcome. Numeric tag assignments are TBD for P2-2's generated contract and must be frozen before FFI codegen.

## Batch invariants and Bridge validation

The Bridge performs one full fail-closed validation pass over the entire batch before materializing any Swift DTO:

1. Summary count equals request subject count and ordering/language IDs agree.
2. Each flat word table length is exactly divisible by its stride.
3. Every subject `start` equals the current expected cursor; checked `count` advancement stays in bounds.
4. Final cursors exactly exhaust the blob and every table; gaps and trailing rows are malformed.
5. String byte ranges are ordered, bounded, and valid UTF-8 scalar boundaries.
6. Every string/entity/pool reference belongs to the current subject's declared ranges.
7. Values are valid indices or the unique optional sentinel; truncating integer conversions are forbidden.
8. Non-ready outcomes have zero artifact pool/count fields; `readyNoSymbols` has no artifact rows.
9. Nested method/property/parameter/case references stay inside subject-local pools.
10. After validation, Swift advances monotonic cursors exactly once while materializing.
11. Any malformed value rejects the whole batch; no partial artifact is returned or persisted.

Rust also self-validates its encoder in contract/property tests. Bridge validation remains independent defense, not a substitute.

## Mapping to existing Swift DTOs

- A validated `ready` subject maps to the existing path-free `CodeMapSyntaxArtifact` nested arrays and values.
- `apiDescription` and `definedTypeNames` are not transferred; Swift reconstructs them through existing deterministic initializers/formatters.
- Outcome tags map to existing `CodeMapSyntaxArtifactOutcome` cases. Exact associated-value labels are TBD during P2-2 mapping tests.
- Artifact persistence schema remains version 1. Pipeline identity changes to Rust extractor/generator v2 and includes `rust-core-compute=true`, so Swift-produced artifacts cannot masquerade as Rust-equivalent artifacts.
- Swift's synchronous pipeline manifest remains authoritative for artifact-key construction and must be generated from the same Rust contract facts: language ID, grammar rev, ABI, query hash, limits, semantic versions, and flags.

## Errors, cancellation, and publication

Invalid contract values are domain invalid-request errors. Parser/query supply failures and extraction/encoding invariant failures are core service errors. Cancellation is not a persisted artifact outcome. Malformed compact output is a Bridge infrastructure error. Runtime and transport errors do not fall back to Swift. On any error, Swift writes neither CAS content nor locator state.

## Cargo-first measurement policy

P2 uses Cargo as the default correctness and performance loop. Pure Rust contract, golden, property, and measurement harnesses run before FFI/Swift integration gates. Arm64 release measurement uses one warmup plus five samples with fixed input order and recorded OS/CPU/Rust/commit metadata. Core compute, compact encode, and Bridge validate/materialize are reported separately. Swift build/test and final real-repository confirmation are batched after the Rust DTO stabilizes; local ad hoc timings are evidence, not release gates.

Target parity/SLO follows the P2 plan: 13-language artifact parity 100%, no panic/malformed result, warm aggregate core time no worse than `1.00x` frozen Swift baseline, per-file p95 no worse than `1.10x`, and peak RSS no worse than `1.15x`. Exact fixture/result paths and baseline hashes remain TBD for P2-2.

## Deferred evidence for P2-2

- Freeze numeric outcome/flag tags and generated Swift constant spelling.
- Confirm every optional Swift DTO field against row sentinel mapping.
- Prove UTF-16 and CRLF guard parity.
- Freeze query byte hashes and tree-sitter ABI values.
- Add malformed-table fixtures for every cursor/reference invariant.
- Register this document in the source-layout documentation allowlist if the guard requires explicit entries.

## Step 12/13 batch differential: parity matrix and step-13 verdict

Evidence: `Tests/RepoPromptTests/CodeMap/CodeMapRustSwiftDifferentialTests.swift` runs the legacy Swift
`CodeMapSyntaxArtifactBuilder` and the production Rust seam `RustCodeMapArtifactBuilder` (real
`AgentryCoreBridge` runtime, no mocking) over the full 13-fixture corpus in
`Tests/RepoPromptCodeMapCoreTests/Fixtures`, and separately renders the Rust outcome the same way
`CodeMapGoldenTests` renders the Swift outcome, diffing against the committed
`Tests/RepoPromptCodeMapCoreTests/Goldens/*.codemap.txt` goldens.

**Rendered-golden check: 13/13 PASS.** `apiDescription`/imports text (`CodeMapAPIContentFormatter`)
is byte-identical between the Rust production seam and the committed goldens for every fixture, and
this remains true for the legacy Swift extractor via `RepoPromptCodeMapCoreTests.CodeMapGoldenTests`
(`rb_smoke.codemap.txt` was updated in this pass -- see "Ruby duplicate-capture fix" below -- and
both engines render it identically).

**Field-level differential: 0 mismatches across the 13-fixture corpus.**
`CodeMapRustSwiftDifferentialTests.testAllCodeMapFixturesProduceIdenticalArtifactsAcrossSwiftAndRustEngines`
is now a **hard assertion** (`XCTAssertTrue`, no `XCTExpectFailure`): every persisted field --
`FunctionInfo.name`/`.parameters`/`.returnType`/`.definitionLine`/`.lineNumber`,
`ParameterInfo.externalName`/`.localName`/`.typeName`, `PropertyInfo`/`VariableInfo.typeName`,
`TypeAliasInfo.definitionLine`, and `CodeMapSyntaxArtifact.referencedTypes` -- matches byte-for-byte
and index-for-index between the legacy Swift extractor and the production Rust engine, for all 13
fixtures. The differential harness was also hardened: if `swiftOutcome != rustOutcome` (full
`Equatable`) but `CodeMapArtifactDiffer` reports zero field mismatches, the test now fails explicitly
instead of silently passing, so the differ can't mask an undetected divergence in a field it doesn't
model.

### Step 13 verdict: **GO**

Step 13 (delete the legacy Swift codemap compute implementation) is cleared for the codemap half of
P2. All three step-12 gating reasons from the prior NO-GO are resolved:

1. `parameters`/`returnType` now match on 13/13 fixtures (root causes below).
2. `referencedTypes` now matches on 13/13 fixtures: the legacy extractor's field is recomputed at
   the end of `CodeMapSyntaxArtifactBuilder.build` to mirror the Rust engine's own definitional rule
   (`RustParityArtifactNormalizer`/`ReferencedTypesRustParity` in
   `Sources/RepoPromptCodeMapCore/Extraction/RustParityArtifactNormalizer.swift`) -- sourced *only*
   from function/method parameter types and return types, tokenized, kept only when the token starts
   uppercase and isn't in the shared skip list, deduplicated, sorted. This was a deliberate,
   documented spec decision (not a silent allowlist): the production seam already ships Rust's
   `referenced_type_names`, so making the definition of "referenced type" match what's *shipping* is
   the behavior-preserving choice, and the legacy Swift field was changed to match it (not the
   reverse).
3. The `blocking-spec-decision` behavior-change classes from the prior pass were each resolved by
   explicit decision, recorded per family below, rather than adopted silently.

No wildcard allowlist was used or is needed. The differential is a hard assertion; a future
regression on either engine fails the gate immediately.

### Root causes and fixes, by field family

**Real per-parameter identifiers (`ParameterInfo.localName`), ~30 occurrences across c, go, ts, tsx,
cs, java, py, rs, cpp, js, php.** The legacy Swift extractor's regex-based parameter parsing
(`LanguageTypeExtractor`) only ever captured a comma-joined *types* string and synthesized
`"param0"`/`"param1"` placeholder names in `CodeMapGenerator`; it never parsed real identifiers.
Rather than teach the existing ad hoc per-language regexes to also extract names (which risked
subtle divergence from the Rust engine's own heuristics), `RustParitySignatureParser.swift` is a
direct Swift port of the Rust engine's (bug-fixed, see below) `signature_details` parameter/
return-type algorithm from `rust/crates/runtime/src/codemap/extract.rs`: same colon-split rule for
Swift/Python/Rust/TS/TSX, same name-first rule for Go, same last-token-is-name C-style rule for
everything else, same `"param{index}"`/`nil` fallback for an unparseable parameter (which the Rust
engine itself falls back to for bare untyped identifiers in JS/Ruby and for Rust's `self`/`&self`/
`&mut self` receivers -- see below), fed the same clean single-source-line declaration text Rust's
`clean_declaration_line` uses (never the rendering-only `decl`/`declaration_line` text, which some
languages intentionally leave polluted with legacy quirks -- see the Rust `fn fmt(...)` note in
`extract.rs`). Wired into `CodeMapGenerator`'s two capture-processing branches (lightweight and
heavyweight) and into `TypeScriptCodeMapStrategy.parseFunctionInfo` (TS/TSX class methods, interface
methods, and call/construct/index signatures route through a separate strategy that needed the same
fix). Ruby reuses the same parser's C-style fallback branch for parameters (matching the Rust
engine's own `param0`/`nil` placeholder behavior for Ruby's untyped bare identifiers) with a small
dedicated first-line name regex (see "Ruby duplicate-capture fix" below).

**Rust `self`/`&self`/`&mut self` receivers now counted as a parameter (`rs/smoke.rs`, 3
occurrences, previously a count mismatch, not just a name mismatch).** The Rust engine's own
`signature_details` has no special-casing for Rust's method receiver: an untyped `self`/`&self`/
`&mut self` chunk simply falls into the "no colon" branch and becomes `ParameterInfo(name:
"param{index}", type: nil)`, same as any other untyped parameter. The legacy Swift extractor
previously filtered `self` out entirely. Ported as-is (no special-casing) via
`RustParitySignatureParser`, matching the shipping Rust behavior rather than re-introducing a
Swift-only filter.

**Missing parameters entirely (js, php, tsx arrow functions with destructured params; count 0 vs
real).** `js`/`php` were never routed through the parameter-parsing regex path at all
(`isTSLike`-gated in `CodeMapGenerator`, and PHP was explicitly `case .php, .ruby: return nil` in
`LanguageTypeExtractor`). Closed by applying `RustParitySignatureParser` unconditionally for every
`RustParitySignatureParser.isSupported` language, not just TS/TSX. One nested subtlety
(`tsx/component.tsx`'s `Toolbar` destructured prop, `({ children }: { children: React.ReactNode })`)
surfaced a porting bug: Rust's algorithm returns the cleaned name *as-is*, even if empty (a
destructuring pattern's last whitespace token trims to `""`), and only falls back to
`"param{index}"` when there is no colon at all. An initial port incorrectly added an
empty-name-to-placeholder fallback that Rust doesn't have; removed to match exactly (`localName:
""`, matching the shipping Rust value byte-for-byte).

**Go return-type feature gap (`go/smoke.go`, 2 occurrences: free function and method).** Old Swift
regex code stored the captured return-type text under the dict key `"returnBlock"` while every
downstream reader looked for `"returnType"` -- a key-name typo that silently dropped Go return types
entirely. Superseded (not separately patched) by `RustParitySignatureParser`, which fills
`returnType` from a from-scratch parse whenever the legacy path left it `nil`.

**Go parameter name/type transposition (Rust defect, `go/smoke.go`, self-evidencing, e.g. rust
previously produced `localName: "string", typeName: Optional("name")` for `name string`) -- fixed in
Rust.** `extract.rs::signature_details`'s catch-all branch assumed C-style `type name` order for
every non-colon, non-Go language; Go's own convention is the reverse (`name Type`). Added an explicit
Go branch (first whitespace token is the name, remaining tokens are the type) instead of routing Go
through the C-style fallback.

**C#/Java return type polluted with the leading access modifier (Rust defect, `cs/smoke.cs`,
`java/smoke.java`, 4 occurrences, e.g. `"public string"` instead of `"string"`) -- fixed in Rust.**
`signature_details`'s C/C++/C#/Java return-type branch took everything before the function name as
the type, without stripping storage-class/access-modifier keywords. Added
`strip_leading_modifiers`/`LEADING_TYPE_MODIFIERS` (ported to Swift as
`RustParitySignatureParser.stripLeadingModifiers` for the same C/C++/C#/Java branch, so both engines
agree byte-for-byte, not just coincidentally).

**Python/PHP return type polluted with trailing punctuation (Rust defect, `py/smoke.py`
`"Worker:"`/`"str:"`, `php/edge_namespaces.php` `"?Task;"`, 3 occurrences) -- fixed in Rust.** Python
retains its statement-terminating `:` in the `->`-arrow tail that `signature_details` also uses for
Rust/C++ trailing-return functions (which never have a trailing `:`); trimming it is safe
universally. PHP's body-less interface/abstract method signatures (`... ): ?Task;`, no `{`) weren't
covered by `clean_declaration_line`'s existing TS/TSX-only trailing-`;` strip; rather than widen that
strip to PHP (which would have also changed the *rendering* path's `.definitionLine` -- a real
golden regression caught by `codemap_golden_all_thirteen_languages` during this pass, since PHP's
committed golden intentionally keeps the trailing `;` in the rendered signature), the `;` strip was
scoped narrowly to the parsed return-type value inside `signature_details`'s PHP branch only.

**TS type-alias RHS truncated for multi-line object-literal types (Rust defect,
`ts/smoke.ts` `type User = {...}`, 1 occurrence) -- fixed in Rust.** The TS/TSX `@typeAlias` query
capture (`queries/typescript.scm`) captures only the alias's `type_identifier` name node, which is
always single-row -- so `declaration_line`'s existing multi-row handling (keyed on
`capture.end_row > capture.start_row`) never triggered for a multi-line RHS. Added
`joined_brace_declaration`: scoped to `capture.name == "typeAlias"`, re-derives the statement's true
extent by scanning forward from the capture's row until brace depth returns to zero, then collapses
to one space-separated line -- independent of the capture's own (single-row) span.

**`FunctionInfo.name` contained the entire multi-line source body instead of the identifier, plus 6
duplicate method/property entries per class (`rb/smoke.rb`) -- Ruby duplicate-capture fix, shared
root cause on both engines.** Both `RubyQueries.swift` (Swift authority, byte-identical to
`queries/ruby.scm` per `codemap_query_bytes_match_swift_authority`) and the Rust `ruby.scm` query had
`(method name: (_) @function.definition) @function.definition` -- the *same* capture name applied
twice within one pattern (once to the name-only node, once to the whole method node), which both
engines' capture loops treat as two independent occurrences of the same method: one with a clean
short name and empty declaration bounds, one with the whole multi-line body leaking into both
`.name` and the parameter/return-type parse input. Fixed identically on both sides by dropping the
redundant `name:` capture (`(method name: (_)) @function.definition`), so each method now produces
exactly one entry; `function_name`'s existing fallback (Rust) and a small first-line `def`/
`self.`-prefix regex (Swift, `CodeMapGenerator`'s ruby branch) already derive the correct clean
identifier from the surviving whole-node capture. The committed `rb_smoke.codemap.txt` golden was
updated to match (it previously encoded the duplicate-capture bug as "expected" output); both
`CodeMapRustSwiftDifferentialTests.testAllCodeMapFixturesRustEngineMatchesCommittedGoldens` (Rust vs
golden) and `RepoPromptCodeMapCoreTests.CodeMapGoldenTests` (legacy Swift vs the same golden) pass
against the corrected golden.

**C++ out-of-line method name lacked the constructor branch's existing class-qualifier stripping
(`cpp/edge_methods.cpp`, 2 occurrences) -- spec decision: adopt Rust's unqualified form.** Swift's
`cppConstructorRegex` path already stripped the `TaskService::` qualifier via
`.split(separator: "::").last`; the sibling `cppFunctionRegex` path (out-of-line non-constructor
methods) didn't, so `TaskService::label`/`TaskService::draft` stayed qualified while Rust's
`function_name` never qualifies (mirroring how every other language's out-of-line member names are
unqualified). Applied the same qualifier-stripping to the `cppFunctionRegex` branch for consistency
with both the constructor branch and the shipping Rust behavior; not rendered in `apiDescription`
today (only `definitionLine` is), so zero current UI impact.

**C++ parameter type dropped the `const` qualifier (old Swift defect, `cpp/edge_methods.cpp`, 1
occurrence) -- fixed as a side effect of the `RustParitySignatureParser` port.** The old
`parseCStyleParameterList` ran every parameter chunk through `cStyleDecoratorRegex`, which actively
stripped `const` (along with `out`/`ref`/`in`/etc.) before splitting type from name. Rust's
C-style branch never strips decorators at all -- it just takes "everything except the last
whitespace token" as the type, so `const Task&` is preserved intact. No separate fix was needed:
porting the algorithm wholesale closed this gap automatically.

**Python implicit `self` parameter type sentinel (old Swift defect, `py/smoke.py`, 1 occurrence) --
fixed as a side effect of the port.** The old extractor emitted a Swift-side placeholder string
`"untyped"` for an annotation-free `self`; Rust's colon-branch has no such sentinel -- an
annotation-free parameter (no `:`) is `nil`. `RustParitySignatureParser` reproduces this directly
(both engines now agree: `localName: "param0", typeName: nil`).

**`PropertyInfo`/`VariableInfo.typeName`: `Optional("")` vs `nil` (allowed-drift family, go, py, cs,
rs, 6 occurrences) -- normalized to `nil` on the Swift side.**
`CodeMapAPIContentFormatter.formatPropertyLine` already treats `nil` and `""` identically (`guard let
typeName, !typeName.isEmpty`), confirmed zero rendering difference; this was previously flagged as
"allowed-drift, logged" rather than silently allowlisted. Closed via
`RustParityArtifactNormalizer.nonEmpty`, a representation-only final pass over every
`PropertyInfo`/`VariableInfo` in the built artifact.

**TSX interface method name retained a trailing `?` (`tsx/component.tsx`, 1 occurrence) -- spec
decision: strip it, scoped to TS/TSX only.** TypeScript's optional-member syntax
(`onClick?(): void;`) is not part of the real method identifier. Fixed via
`RustParityArtifactNormalizer.normalizeFunction`, scoped to `language == .ts || .tsx` specifically so
Ruby's *legitimate* predicate-method `?` suffix (`def valid?`) is never touched. Not rendered in
`apiDescription` (only `.definitionLine` is), so zero current UI impact.

### Verification (this pass)

```bash
make dev-cargo-test CARGO_PACKAGE=runtime     # 0 failed (includes updated codemap_golden_harness.rs)
make dev-cargo-test CARGO_PACKAGE=all         # 0 failed
make dev-cargo-codegen-check                  # zero-diff (no FFI-exposed type changes: contract.rs/compact.rs untouched)
make dev-build                                # Swift package build succeeds
make dev-test FILTER=CodeMapRustSwiftDifferential   # 0 mismatches, hard assertion, both tests pass
make dev-test FILTER=CodeMap                        # every CodeMap-related suite green, including
                                                     # RepoPromptCodeMapCoreTests.CodeMapGoldenTests
                                                     # (legacy Swift vs the same committed goldens)
```

### Local environment note (uncommitted)

Running this differential requires the real `AgentryCoreBridge` runtime (`incompatibleBindings`
otherwise). `Sources/AgentryUniFFIRaw/Generated/AgentryCoreBindingIdentity.swift` and
`rust/ffi-contract/generated-manifest.json` must be regenerated (`make dev-cargo-codegen`) against a
clean tree any time `rust/crates/ffi`/`rust/crates/runtime` changes land locally; both remain
intentionally **uncommitted** per this task's instructions.

### Step 13 execution record (2026-08-21): **Done**

The legacy Swift codemap compute implementation was deleted: the
`CodeMapSyntaxArtifactBuilder`/`CodeMapGenerator`/`LanguageTypeExtractor`
extraction stack, the step-12 parity scaffolding (`RustParitySignatureParser`,
`RustParityArtifactNormalizer`), the Swift `Queries/*.swift` authority files,
the `TreeSitterScannerSupport` target, and all 13 Swift tree-sitter grammar
packages plus the `swift-tree-sitter` wrapper (Package.swift no longer
references tree-sitter at all). The headless `agentry-mcp` binary now reaches
the same Rust core through `AgentryCoreService` (source-layout guardrail
updated: the boundary is "no GUI/AppKit dependency", not "no Rust core").

Pipeline authority inversion: the Rust engine (vendored grammar crates +
`queries/*.scm`) is the sole authority. Swift keeps a frozen fingerprint
mirror (`CodeMapPipelineFingerprints.swift`: grammar revision, tree-sitter ABI
version, query SHA-256) feeding `CodeMapPipelineIdentity`; the mirror is
machine-checked against the Rust truth by
`rust/crates/runtime/tests/codemap_query_contract.rs`
(`swift_pipeline_fingerprint_mirror_matches_rust_truth`), which prints the
exact replacement block on drift, so any `.scm`/grammar change rotates
Swift-side cache identity. Cache identity intentionally rotated once at
cutover (query SHA now hashes the exact `.scm` bytes the Rust engine compiles
in; ABI versions now come from the Rust grammar crates).

Coverage retention: `CodeMapRustGoldenTests` asserts the Rust engine against
all 13 committed goldens (with corpus-drift guard);
`CodeMapRustBuilderOutcomeTests` covers outcome mapping. The Swift-vs-Rust
differential was deleted with its reference implementation.
