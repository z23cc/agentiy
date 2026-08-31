# M8 — Live certification and release-candidate gate

Status: implemented as a fail-closed certification surface (2026-08-31).

## Purpose

M8 is the operational certification phase after the Rust provider transport and
semantic cutovers (P6, P7-1, P7-2, P7-3) and the conservative MCP backend gate
(M7). It does not introduce another provider implementation or alter the MCP
wire contract. It records whether the current commit has sufficient live,
power, and release evidence for a future `app` → `auto` promotion.

The canonical contract is
`Scripts/Fixtures/headless_mcp_domain_runtime_m8_contract.json`. The runner is
`Scripts/m8_live_certification.sh`, and the machine-readable validator is
`Scripts/validate_m8_live_evidence.py`.

## Receipt invariants

Every receipt has the current full commit SHA, UTC start/finish timestamps, a
small environment summary, and exactly four check rows:

* `live_provider_smoke` covers the Codex App Server, ACP, and Claude headless
  matrix. A version check or a single configured provider is not matrix proof.
* `live_auto_matrix` requires both app-available and app-unavailable runtime
  probes. The deterministic selection suite is a prerequisite, not a
  substitute for the two live states.
* `sleep_wake_soak` requires an externally verified wake and collection channel.
  The checked-in runner never puts the host to sleep because doing so would
  interrupt receipt collection.
* `signed_release_artifact` requires provisioned signing, Sparkle, notarization,
  and publication inputs. The local `release.sh artifact` command is explicitly
  ad-hoc and non-distributable, so it is never counted as signed evidence; an
  official signing/notarization run must provide the passing receipt.

Each row is `passed`, `blocked`, or `deferred`. A passed row must carry an M8
evidence identifier; blocked/deferred rows carry no identifier. The validator
rejects duplicate JSON keys, schema/type drift, commit mismatch, secret/path
markers, and noncanonical check/provider ordering.

The receipt is deliberately redacted: credential values, authorization headers,
raw provider output, filesystem paths, and command logs never enter it. The
runner may retain detailed logs in the normal build/job log outside the receipt.

## Promotion policy

`app` remains the immutable default. Even a receipt with four passed checks
cannot authorize promotion unless the validator is invoked with
`--authorize-auto`; the runner also requires that flag. No automatic promotion
or post-initialize backend switch is allowed. Incomplete operational evidence
is a release blocker, not an inferred pass.

## Execution

Credential-free contract/self-tests:

```bash
python3 Scripts/test_validate_m8_live_evidence.py
Scripts/m8_live_certification.sh
```

An authorized operational attempt is explicit:

```bash
Scripts/m8_live_certification.sh --live --provider-matrix --auto-matrix
```

The command always writes a receipt. Missing credentials, an unstable live
workspace, unavailable power scheduling, or unprovisioned release services are
recorded as `blocked`; they are not converted to `passed` by offline fixtures.
