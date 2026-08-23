# claude-ndjson-v1 corpus

Fixture corpus for the Claude vertical (`docs/architecture/rust-agent-claude-v1.md`,
`docs/designs/p6-claude-vertical-2026-08-23.md`). Frozen at P6-1 per the design's
step list (P6-1: "capture and redact the fixture corpus per §9"). See
`MANIFEST.json` for the authoritative, machine-readable file-by-file record —
this file is a short human-facing map.

## Status: PARTIAL

Only `synthetic/` is committed. It covers the corpus shapes a well-behaved real
`claude` CLI conversation cannot produce on its own: all four malformed-line
recovery classes (design D-1, positive and negative), a line over 1 MiB,
non-UTF-8 bytes, and CRLF line endings.

**Not yet captured**: the real-traffic half — ≥20 real multi-turn Claude Code
conversations spanning plain text, thinking/reasoning deltas, tool use + tool
results, `system/init`, `result` with and without `errors[]`,
`session_state_changed` sequences including `idle`, and approval
`can_use_tool` round-trips. This requires launching the visible Agentry debug
app and running live conversations against the real Anthropic API (real
spend); both require explicit end-user approval, which was asked for and
explicitly deferred during P6-1 (see the P6-1 commit history for the
`ask_user` exchange). **This is a named, blocking gap for P6-2's E-P6-1
gate — do not treat this corpus as complete.**

When approved, captured-and-redacted turns land under a new `captured/`
subdirectory alongside this one, following `MANIFEST.json`'s
`captured-redacted` provenance value and the redaction contract documented
there (design §9). The `synthetic/` half does not need to move or be
restructured when that lands.

## Layout

```
v1/
  README.md          -- this file
  MANIFEST.json       -- authoritative file-by-file record: provenance, targeted
                          coverage, expected behavior, source-traced reasoning
  synthetic/           -- hand-authored adversarial fixtures (committed at P6-1)
  captured/            -- reserved for real-traffic captures (not yet present)
```

Every `*.ndjson` file is a raw byte stream, fed to the framer/codec exactly as
a real stdout reader would see it — not pre-parsed, not reformatted. Some
files are deliberately not valid UTF-8 or not newline-delimited in the usual
sense (see `MANIFEST.json` for which, and why).
