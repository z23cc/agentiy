# Rust CodeMap Compact Contract v1

Status: draft for P2-2 implementation and differential validation.

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

## Step 12 batch differential: parity matrix and step-13 verdict

Evidence: `Tests/RepoPromptTests/CodeMap/CodeMapRustSwiftDifferentialTests.swift` runs the legacy Swift
`CodeMapSyntaxArtifactBuilder` and the production Rust seam `RustCodeMapArtifactBuilder` (real
`AgentryCoreBridge` runtime, no mocking) over the full 13-fixture corpus in
`Tests/RepoPromptCodeMapCoreTests/Fixtures`, and separately renders the Rust outcome the same way
`CodeMapGoldenTests` renders the Swift outcome, diffing against the committed
`Tests/RepoPromptCodeMapCoreTests/Goldens/*.codemap.txt` goldens.

**Rendered-golden check: 13/13 PASS.** `apiDescription`/imports text (`CodeMapAPIContentFormatter`)
is byte-identical between the Rust production seam and the committed goldens for every fixture.
`CodeMapAPIContentFormatter` only ever reads container/alias/enum *names*, and function/method
`definitionLine` + `lineNumber` -- it never reads `FunctionInfo.name`, `.returnType`, `.parameters`,
or `CodeMapSyntaxArtifact.referencedTypes`. So this check cannot, by itself, clear step 13: it only
proves the human-readable summary text is stable.

**Field-level differential: 72 named mismatches remain across the 13-fixture corpus** (down from 73
before this pass's fix; every fixture has at least one). Per plan §3.10 the strict-equality bar is
"artifact 所有持久化字段及数组顺序" (all persisted fields and array order), not just the rendered
summary, and:

- `CodeMapArtifactContainer.swift:581-587` persists `FunctionInfo.parameters` (count + each) and
  `.returnType` as part of the durable artifact.
- `CodeMapSelectionGraphContribution.swift:22` feeds `CodeMapSyntaxArtifact.referencedTypes`
  directly into the uses/used-by dependency graph (a live product feature, e.g. `get_code_structure
  expand=uses|used_by`).

So every mismatch below is a persisted-field parity gap in scope for the plan's 100% bar, even
though none of them currently show up in the golden-tested summary text.

### Fixed this pass

| Fixture | Field | Root cause | Disposition |
| --- | --- | --- | --- |
| `rs/smoke.rs` | `classes[0].methods[3].returnType` (the `fmt::Display` impl) contained the entire method body (`"fmt::Result {\n write!(f, ...)"`) | `rust/crates/runtime/src/codemap/extract.rs::declaration_line` has a hardcoded `raw.contains("fn fmt(")` special case that appends the next source line to reproduce a *legacy Swift* multi-line-leak quirk baked into the committed `rs_smoke.codemap.txt` golden's `definitionLine` rendering. That polluted text was then reused, unmodified, as the input to `signature_details()` for parameter/return-type parsing. | **rust-defect-fixed.** Split the helper: `definition_line` (rendering, golden-sensitive) keeps the hack; `parameters`/`return_type` parsing now uses a new `clean_declaration_line` that never includes body text. Verified: `cargo test -p agentry-runtime` (96 tests passed, 1 pre-existing ignored, across all of that crate's test binaries) still green, `testAllCodeMapFixturesRustEngineMatchesCommittedGoldens` still 13/13, this fixture's `returnType` now matches Swift (`"fmt::Result"`). No `Package.swift`/target changes. |

### Logged, not fixed this pass (need a dedicated Rust-side oracle/golden before touching queries again)

| Field class | Fixtures affected | Example | Disposition | Notes |
| --- | --- | --- | --- | --- |
| `parameters[i].localName` placeholder (`"param0"`/`"param1"`) vs real identifier | c, go, py, ts, cs, java, rs, cpp (~15 occurrences) | `c/smoke.c functions[0].parameters[0]`: swift=`localName:"param0"` rust=`localName:"lhs"` | **blocking-spec-decision** | Old Swift extractor never wired real per-parameter identifiers for these languages; Rust's real-name behavior is strictly more informative. This is a persisted-field *behavior change*, not a bug fix by allowlist -- needs explicit maintainer sign-off before being treated as the new baseline, because it changes durable artifact bytes for ~8/13 languages. |
| `parameters` count `0` (Swift extracted none) vs real params (Rust) | js, rb, php, tsx (~15 occurrences) | `js/smoke.js functions[0].parameters`: swift count=0 rust count=1 | **blocking-spec-decision** | Same root class as above, more severe (old Swift didn't even count parameters for these constructs). |
| `returnType: nil` (Swift never extracted) vs populated (Rust) | go, php (4 occurrences) | `go/smoke.go functions[0].returnType`: swift=nil rust=`Optional("Worker")` | **feature-gap-logged** | Old Swift limitation, not a Rust defect; Rust closes a real feature gap. |
| `returnType` polluted with access-modifier prefix | cs, java (4 occurrences) | `cs/smoke.cs classes[0].methods[0].returnType`: swift=`"string"` rust=`"public string"` | **rust-defect-logged** | Real Rust capture-boundary bug (C#/Java return-type extraction includes the preceding modifier token). Not fixed this pass -- unlike the `rs/smoke.rs` fix above, the root cause here has not yet been traced through `signature_details`'s text-based C#/Java parsing; each field class in this table needs its own root-cause read before a safe fix, and this pass time-boxed to the one case (`rs`) whose root cause was already fully understood from the golden-text investigation. |
| `returnType` polluted with trailing punctuation | py (`"str:"`, `"Worker:"`), php (`"?Task;"`) (3 occurrences) | `py/smoke.py functions[0].returnType`: swift=`"Worker"` rust=`"Worker:"` | **rust-defect-logged** | Same class as above (capture boundary swallows a trailing token); same reasoning for deferring. |
| Go parameter name/type swapped | go (2 occurrences) | `go/smoke.go functions[0].parameters[0]`: rust=`localName:"string", typeName:"name"` (should be reversed) | **rust-defect-logged, highest-priority follow-up** | Clear, self-evidencing bug (name and type are literally transposed for Go's `name Type` parameter syntax) independent of any Swift comparison. Not fixed this pass: the swap's exact origin within `signature_details`'s per-language parameter-splitting branch was not traced during this pass (time-boxed to the one already-understood `rs` case); recommend as the first follow-up given how clear-cut and self-evidencing it is. |
| `referencedTypes` differs in content and count, in both directions | go, java, rs, cpp, php, tsx (6 occurrences) | `rs/smoke.rs referencedTypes`: swift count=6 rust count=3; `go/smoke.go referencedTypes[0]`: swift=`"context.Context"` rust=`"Worker"` | **blocking-spec-decision** | No consistent "Rust is more/less complete" direction -- this is a definitional difference in what counts as a referenced type per language, and it feeds the uses/used-by dependency graph. Needs a spec decision, not a query tweak. |
| `TypeAliasInfo.definitionLine` truncated | ts (1 occurrence) | `ts/smoke.ts aliases[0].definitionLine`: swift=full multi-field type text rust=`"type User ="` only | **rust-defect-logged** | Real capture-boundary bug (TS type-alias RHS not fully captured). Not rendered into `apiDescription` today (only `alias.name` is), so zero current UI impact, but it is a real field defect. |
| `FunctionInfo.name` contains the entire multi-line source body instead of the identifier | rb (5 occurrences: 2 top-level functions + 3 methods) | `rb/smoke.rb functions[0].name`: swift=`"def build_task(title)\n  Task.new(title)\nend"` rust=`"build_task"` | **old-swift-defect-logged** | Proven old Swift bug (not a Ruby-specific Rust regression): the legacy extractor's `.name` field is unusable here. Rust's clean identifier is correct. `.name` is not rendered into `apiDescription`, so this has no current UI impact; flagged so a future decision to adopt Rust's behavior as the new baseline is deliberate, not silent. |
| C++ out-of-class method name lacks class qualifier | cpp (2 occurrences) | `cpp/edge_methods.cpp functions[1].name`: swift=`"TaskService::label"` rust=`"label"` | **blocking-spec-decision** | Ambiguous which is "right" -- Swift's qualified form may be intentionally useful for out-of-line C++ method definitions, or may be incidental. Not rendered into `apiDescription`. Needs a design decision, not a unilateral query change. |
| C++ parameter type loses `const` qualifier in Swift | cpp (1 occurrence) | `cpp/edge_methods.cpp functions[1].parameters[0]`: swift=`"Task&"` rust=`"const Task&"` | **old-swift-defect-logged** | Swift's type-text extraction drops the `const` qualifier; Rust's fuller text is more correct. |
| `PropertyInfo`/`VariableInfo.typeName`: Swift emits `Optional("")` sentinel, Rust emits `nil` | go, py, cs, rs (6 occurrences) | `go/smoke.go classes[0].properties[0].typeName`: swift=`Optional("")` rust=`nil` | **allowed-drift, logged (self-evidently harmless)** | `CodeMapAPIContentFormatter.formatPropertyLine` treats `nil` and `""` identically (`guard let typeName, !typeName.isEmpty`); confirmed zero rendering difference. Named here rather than silently allowlisted per the plan's "no wildcard allowlist" rule. |
| Python implicit `self` parameter typeName: Swift emits `"untyped"` sentinel string, Rust emits `nil` | py (1 occurrence) | `py/smoke.py classes[0].methods[0].parameters[0]`: swift=`typeName: Optional("untyped")` rust=`typeName: nil` | **old-swift-defect-logged** | `"untyped"` is a Swift-side placeholder string, not real type information; Rust's `nil` is more semantically correct for an annotation-free `self`. |
| TSX interface method name retains trailing `?` | tsx (1 occurrence) | `tsx/component.tsx interfaces[0].methods[0].name`: swift=`"onClick?"` rust=`"onClick"` | **rust-defect-logged** | Unclear yet whether the `?` (TS optional-property marker) belongs in `.name` at all; flagged for a follow-up look rather than a snap judgment either way. |

### Step 13 verdict: **NO-GO**

Step 13 (delete the legacy Swift codemap compute implementation) is **not** cleared by this pass.
Reasons, each independently sufficient:

1. Persisted fields `parameters` and `returnType` differ on effectively all 13/13 fixtures.
2. `referencedTypes` differs in both directions across 6/13 fixtures and feeds a live product
   feature (uses/used-by graph) -- this needs a spec decision on language-by-language "referenced
   type" semantics before either engine can be called authoritative.
3. Several classes above (`blocking-spec-decision`) are deliberate behavior changes (more complete
   or more correct than the legacy Swift extractor) that should not be adopted as the new baseline
   silently -- they need explicit maintainer sign-off, since `CodeMapArtifactContainer` persists
   these fields and downstream consumers may depend on the current shape.
4. A smaller set (`rust-defect-logged`) are genuine, narrower Rust extraction bugs that are fixable
   but were deliberately deferred this pass for lack of a Rust-side golden/oracle to verify a query
   change safely (see `rs/smoke.rs` fix above for what that harness would need to look like).

The rendered-golden check passing 13/13 is good evidence the *shipped summary text* did not
regress at `db53cf09`, but it is not sufficient evidence for step 13's stricter "all persisted
fields" bar.

**No wildcard allowlist was used or is proposed.** `CodeMapRustSwiftDifferentialTests` remains red
(72 named, individually-dispositioned mismatches) by design -- a failing test enumerating every
divergence is the correct artifact for a blocked gate; it should not be weakened to green until the
blocking classes above are resolved by explicit decision or fix.

### Version-policy check for the `rs/smoke.rs` fix

Per §3.4 "版本策略", `extractorVersion` was already raised to `2.0.0` for the whole Rust-migration
generation (confirmed at `Sources/RepoPromptCodeMapCore/CodeMapSyntaxEngine.swift:162`,
`CodeMapSemanticVersion(major: 2, minor: 0, patch: 0)`), and the identity flag `rust-core-compute`
is already set. A within-generation extraction refinement (this pass's `returnType` fix) does not by
itself warrant a further major-version bump: `artifactSchemaVersion` is unchanged (still `1`, no
persisted encoding change) and the fix only changes which bytes land in an already-`major:2` field,
the same category of change the `2.0.0` bump was already raised to cover for the initial Rust
cutover. No version-policy fields were changed in this pass.

### Local environment note (uncommitted)

Running this differential requires the real `AgentryCoreBridge` runtime (`incompatibleBindings`
otherwise). At session start, `Sources/AgentryUniFFIRaw/Generated/AgentryCoreBindingIdentity.swift`
and `rust/ffi-contract/generated-manifest.json` were stale: their `rustSourceRevision` was
`tree:3da7d68…` (generated from a dirty tree) instead of `git:db53cf09…` (the actual clean HEAD).
`make dev-cargo-codegen` was run to regenerate both files against clean HEAD (and again after the
`rs/smoke.rs` fix above, to pick up the new build fingerprint). Both are intentionally left
**uncommitted** per this task's instructions; regenerating them is a prerequisite for anyone running
this differential locally against a clean checkout.
