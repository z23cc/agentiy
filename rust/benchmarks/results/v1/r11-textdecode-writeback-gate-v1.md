# R11 investigation — what should the TD-5 write-back gate key on?

Design: `docs/designs/textdecode-policy-v2-2026-08-22.md` §18.1 (R11, open question 6), addendum
§18.4 (this investigation's recommendation). Raw data: `r11-textdecode-writeback-gate-v1.json`
(this directory). Harness: `rust/crates/runtime/src/textdecode/r11_gate_probe.rs` — ordinary
`cargo test`, no env gate (small, deterministic, cheap corpus; not a scale benchmark).

Reproduce: `cd rust && cargo test -p agentry-runtime --release textdecode::r11_gate_probe --
--nocapture`

## 0. Why this investigation exists

§18.1 (post-TD-2 empirical correction) found that `had_replacements` — the flag TD-3/TD-5's
write-back gate (§5.3.1) was designed around — essentially never fires for genuinely-corrupted
legacy multi-byte content (Shift-JIS, EUC-JP, Big5, GB18030, EUC-KR, etc.). `chardetng` disqualifies
a damaged multi-byte candidate outright rather than reporting it lossy, and the fallback it lands on
instead (a single-byte encoding, `encoding_rs`-verified to map all 256 byte values) can never itself
be disqualified. §18.1 named three untested candidates for what the gate should key on instead and
explicitly left them "evaluated, not resolved." This investigation measures a fourth candidate the
task names directly — round-trip re-encode as a lossiness oracle — plus makes §18.1's candidate 3
("high-bit-set byte proportion") concrete and measures it, plus proposes and measures one novel
narrow signal.

## 1. Corpus

Six genuinely-lossy legacy-multi-byte fixtures, each real encoder output (`encoding_rs`) corrupted
one of three ways, plus two hostile-clean controls chosen to stress false-positive risk rather than
make each candidate look good:

| Case | Corruption | Genuinely lossy? |
|---|---|---|
| truncated-shift-jis | EOF truncation (identical construction to TD-2's own `tests.rs:532-551`) | yes |
| mid-sequence-corrupted-shift-jis | single mid-buffer byte flip | yes |
| mixed-encoding-splice | genuine Shift-JIS half + genuine EUC-JP half, concatenated | yes |
| truncated-big5 | EOF truncation | yes |
| truncated-gb18030 | EOF truncation | yes |
| truncated-euc-kr | EOF truncation (mid-multibyte-character, not trailing ASCII — see note below) | yes |
| clean-windows-1252 | none (genuine windows-1252 content) | no |
| clean-all-cyrillic-windows-1251 | none (genuine, zero-ASCII windows-1251 content) | no |

**Corpus-construction bug caught and fixed during this investigation:** the first version of the
EUC-KR fixture's source sentence ended in an ASCII `.`, so truncating the last byte removed a
harmless trailing byte rather than corrupting a multi-byte sequence — the case silently wasn't
lossy at all despite being labeled so. Caught by inspecting this row's measured output (it round-
tripped and stayed labeled EUC-KR, unlike every other row); fixed by ending the sentence on a Korean
character instead. Recorded here because it's exactly the kind of fixture-construction mistake that
would otherwise quietly inflate a "the oracle works" conclusion.

## 2. Findings, per candidate

### Candidate 1 (BOM-pinned-only) and candidate 2 (detected-encoding-changed-vs-cached)

Not re-measured — §18.1 already establishes candidate 1 as TD-2's actual current (free) behavior
and argues candidate 2 is a first-open-blind supplementary signal only. Nothing in this
investigation contradicts either characterization.

### Candidate 3 (high-bit-byte-density heuristic) — measured, NOT separable

| Case | Density |
|---|---:|
| truncated-shift-jis | 0.779 |
| mid-sequence-corrupted-shift-jis | 0.774 |
| mixed-encoding-splice | 0.863 |
| truncated-big5 | 0.704 |
| truncated-gb18030 | 0.905 |
| truncated-euc-kr | 0.831 |
| clean-windows-1252 (control) | 0.065 |
| clean-all-cyrillic-windows-1251 (hostile control) | **0.846** |

A naive `density > 0.5` rule catches every lossy case — and also fires on the clean, genuine,
all-Cyrillic control (0.846, squarely inside the lossy range 0.704–0.905). **The two populations are
not density-separable in this corpus.** This is exactly the false-positive risk §18.1's own text
anticipated for candidate 3 ("a genuine heuristic-design question"), now confirmed empirically: a
plain density threshold used alone would incorrectly block write-back for legitimate dense
non-Latin-script files (Russian, Greek, etc. with little or no ASCII).

### Candidate 4 (round-trip re-encode oracle) — measured, FALSE NEGATIVE for R11's core population

The oracle: decode → re-encode the resulting text via the *detected* label → compare to the
original raw bytes. Byte-identical round trip is exactly §8's existing label-parity bar
(`assert_legacy_round_trip`, `tests.rs:301-330`), applied here as a query against deliberately
corrupted input.

**Result: 0/6 (0%) recall.** Every constructed lossy case — all three corruption shapes (truncation,
mid-sequence damage, cross-encoding splice), across five distinct target encodings — round-trips
"clean" under the oracle. Mechanism: five of the six cases reclassify to `windows-1252`, one (the
splice) to `GBK`; both are single-byte-or-near-total mappings whose `encoding_rs` decode/encode pair
is injective and total over (effectively) every byte value in this corpus, so decoding the
misclassified garbage and re-encoding it via the same wrong label reproduces the original bytes
exactly. **This is not a partial-coverage gap — the oracle has zero discriminating power for exactly
the population R11 exists to protect**, because the failure mode (silent single-byte reclassification)
and the oracle's blind spot (total single-byte mappings round-trip trivially) are the same fact
viewed from two sides. False-positive check passes (0/1 — the clean windows-1252 control correctly
round-trips), so the oracle isn't broken in general, it specifically cannot see this failure mode.

**Cost:** ~16–19% wall-time overhead over decode alone, measured on a 137-byte Shift-JIS buffer
(5,000 iterations, release profile): ~5.1–7.4 µs/call decode-only vs ~6.0–8.8 µs/call with the extra
re-encode pass (run-to-run variance is environmental noise at this scale, not corpus-dependent — the
overhead *ratio* is the stable number). A second full pass over the buffer; for the general
content-read path (TD-5's actual traffic) this is a real, non-trivial recurring cost to pay for a
signal that doesn't cover the case it would be added for.

### Candidate 5 (windows-1252 C1-gap-byte signal, novel) — measured, partial recall, zero false positives on strengthened testing

The five WHATWG windows-1252 "gap" bytes (`0x81/0x8D/0x8F/0x90/0x9D`) map to C1 control scalars
rather than erroring (confirmed at TD-2, §18.1) — genuine natural-language windows-1252 text
essentially never contains raw C1 control characters (no printable glyph was ever assigned to those
byte values). Presence of one in `Legacy(WINDOWS_1252)`-labeled decoded text is a narrow,
targeted, near-zero-cost discriminator (single byte-array scan, no second decode pass).

**Result:** of the 5 lossy cases that specifically reclassify to windows-1252 (the GBK-labeled
splice is out of this signal's scope by construction), 2/5 (40%) contain a gap byte.

**False-positive testing, strengthened after adversarial review of an earlier draft of this
investigation** (the first version tested exactly one clean windows-1252 sample — not enough
evidence to justify recommending a signal that, used as a hard gate, would block a user's save):
0/3 false positives across three deliberately varied clean windows-1252 controls, two of them
constructed specifically to be *dense* in the legitimately-assigned 0x80–0x9F printable range
(curly quotes, em/en dash, bullet, trademark, dagger, double dagger, per-mille, angle quotes,
ellipsis, Šcaron/Žcaron/Œ-ligature) — exactly where a false positive would most plausibly appear if
this signal had one. One useful side-finding from constructing that fixture: a first attempt built
from mostly symbol fragments with too little ordinary English prose was *not* labeled windows-1252
at all by `chardetng` (it landed on windows-1251 instead) — content unusual enough to stress this
signal may also be unusual enough that the ladder doesn't reach the windows-1252 branch in the first
place, a mild point in the signal's favor recorded here rather than discarded.

**Assessment:** a real signal, free, zero false positives found under n=3 adversarial testing — but
n=3 is still a small evidence base, and incomplete recall (40% on its own applicable subset,
inapplicable to non-windows-1252 reclassification targets like the measured GBK case) further limits
what it can be relied on for. **Not recommended as a hard/binding write-back gate at this evidence
level** — see §3's recommendation for how this is actually used.

## 3. Recommendation (feeds design §18.4)

No single cheap signal measured here closes R11 for the legacy-multi-byte single-byte-fallback-
reclassification population:

- Round-trip re-encode: **0% recall**, ~16–19% recurring cost for a signal that doesn't cover the
  case it targets. Not recommended as R11's primary mitigation — it would ship real cost for no real
  protection against the exact failure mode motivating it.
- Density-threshold-alone: 100% recall on this corpus, but also flags genuine dense non-Latin-script
  content. Not safe as a hard write-back block — would break legitimate Cyrillic/Greek/etc. files
  the moment they hit the same code path.
- C1-gap-byte signal: free, zero false positives across 3 adversarially-constructed clean controls
  (strengthened from an initial n=1 check), but only 40% recall on its own narrow applicable subset,
  and n=3 is still too small an evidence base to justify using it as a hard, save-blocking gate.

**Recommendation actually carried into §18.4: the disclosed accept-the-residual-risk path (§18.1
open question 6's third named resolver) is the primary recommendation, not any of the three
candidate signals above.** The C1-gap-byte signal may optionally be added as a non-blocking,
advisory-only supplementary check (e.g. logged or surfaced as lower confidence) precisely because it
has zero measured false positives and near-zero cost — but it is explicitly NOT recommended as a
binding TD-5 done-when criterion or as anything that blocks a write-back on its own, given its
recall and evidence-base limits. Round-trip re-encode and a bare density threshold are not
recommended in any capacity, for the reasons above.
