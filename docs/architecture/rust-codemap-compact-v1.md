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
