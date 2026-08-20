#!/usr/bin/env bash

load_release_metadata() {
    local root="$1"
    local assignments
    assignments="$(
        python3 - "$root/version.env" <<'PYTHON'
import re
import shlex
import sys
from pathlib import Path

patterns = {
    "APP_NAME": r"[A-Za-z0-9._ -]+",
    "DISPLAY_NAME": r"[A-Za-z0-9._ -]+",
    "MARKETING_VERSION": r"[0-9]+(?:\.[0-9]+){2}",
    "BUILD_NUMBER": r"[0-9]{1,4}(?:\.[0-9]{1,2}){0,2}",
    "BUNDLE_ID": r"[A-Za-z0-9.-]+",
    "SIGNING_TEAM_ID": r"[A-Z0-9]*",
    "AGENTRY_SPARKLE_STABLE_FEED_URL": r"[A-Za-z0-9._~:/?#@!$&'()*+,;=%+-]+",
    "AGENTRY_SPARKLE_BETA_FEED_URL": r"[A-Za-z0-9._~:/?#@!$&'()*+,;=%+-]+",
    "AGENTRY_SPARKLE_PUBLIC_ED_KEY": r"[A-Za-z0-9_+/=-]+",
}
required_keys = {
    "APP_NAME",
    "DISPLAY_NAME",
    "MARKETING_VERSION",
    "BUILD_NUMBER",
    "BUNDLE_ID",
    "SIGNING_TEAM_ID",
}
values = {}
for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        raise SystemExit(f"invalid release metadata line: {raw_line}")
    key, value = line.split("=", 1)
    if key not in patterns or key in values:
        raise SystemExit(f"invalid or duplicate release metadata key: {key}")
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    if not re.fullmatch(patterns[key], value):
        raise SystemExit(f"invalid release metadata value for {key}")
    values[key] = value

missing = sorted(required_keys - set(values))
if missing:
    raise SystemExit(f"missing release metadata keys: {', '.join(missing)}")
for key in patterns:
    if key in values:
        print(f"{key}={shlex.quote(values[key])}")
PYTHON
    )" || return
    eval "$assignments"
}

validate_agentry_sparkle_metadata() {
    python3 - \
        "${AGENTRY_SPARKLE_STABLE_FEED_URL:-}" \
        "${AGENTRY_SPARKLE_BETA_FEED_URL:-}" \
        "${AGENTRY_SPARKLE_PUBLIC_ED_KEY:-}" <<'PYTHON'
import base64
import binascii
import hashlib
import sys
from urllib.parse import urlsplit

stable, beta, public_key = (value.strip() for value in sys.argv[1:])
legacy_public_key_sha256 = "baffc4fc73168247f232f8f9d79d09abfdfca5c0b46651ccf78f436e17e2cdee"

def fail(message: str) -> None:
    raise SystemExit(f"invalid Agentry Sparkle configuration: {message}")

def configured(name: str, value: str) -> str:
    if not value or value.startswith("__") or value.endswith("__"):
        fail(f"{name} is empty or still contains a placeholder")
    return value

def canonical_feed(name: str, value: str) -> tuple[str, str, str]:
    value = configured(name, value)
    parsed = urlsplit(value)
    try:
        port = parsed.port
    except ValueError:
        fail(f"{name} has an invalid port")
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or port is not None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not parsed.path
    ):
        fail(f"{name} must be a canonical HTTPS URL without credentials, port, query, or fragment")
    path = parsed.path.rstrip("/") or "/"
    host = parsed.hostname.lower()
    normalized_path = path.lower()
    if host == "github.com" and (
        normalized_path.startswith("/repoprompt/repoprompt-ce-updates/")
        or normalized_path.startswith("/repoprompt/repoprompt-ce-tip-updates/")
    ):
        fail(f"{name} must not use a legacy RepoPrompt CE feed")
    return ("https", host, path)

stable_feed = canonical_feed("AGENTRY_SPARKLE_STABLE_FEED_URL", stable)
beta_feed = canonical_feed("AGENTRY_SPARKLE_BETA_FEED_URL", beta)
if stable_feed == beta_feed:
    fail("stable and beta feeds must be distinct")

public_key = configured("AGENTRY_SPARKLE_PUBLIC_ED_KEY", public_key)
if hashlib.sha256(public_key.encode("utf-8")).hexdigest() == legacy_public_key_sha256:
    fail("the public key must not reuse the legacy RepoPrompt CE signing key")
try:
    decoded_key = base64.b64decode(public_key, validate=True)
except (binascii.Error, ValueError):
    fail("the public key is not valid base64")
if len(decoded_key) != 32:
    fail("the public key must decode to exactly 32 bytes")
PYTHON
}

validate_agentry_sparkle_info_plist() {
    local info_plist="$1"
    validate_agentry_sparkle_metadata
    [[ -f "$info_plist" ]] || {
        printf 'ERROR: missing Info.plist for Agentry Sparkle validation: %s\n' "$info_plist" >&2
        return 1
    }

    local stable beta standard_feed public_key
    stable="$(plutil -extract AgentrySparkleStableFeedURL raw "$info_plist")" || return
    beta="$(plutil -extract AgentrySparkleBetaFeedURL raw "$info_plist")" || return
    standard_feed="$(plutil -extract SUFeedURL raw "$info_plist")" || return
    public_key="$(plutil -extract SUPublicEDKey raw "$info_plist")" || return

    [[ "$stable" == "$AGENTRY_SPARKLE_STABLE_FEED_URL" ]] || {
        printf 'ERROR: Agentry stable feed does not match approved release metadata.\n' >&2
        return 1
    }
    [[ "$beta" == "$AGENTRY_SPARKLE_BETA_FEED_URL" ]] || {
        printf 'ERROR: Agentry beta feed does not match approved release metadata.\n' >&2
        return 1
    }
    [[ "$standard_feed" == "$AGENTRY_SPARKLE_STABLE_FEED_URL" ]] || {
        printf 'ERROR: SUFeedURL must match the approved Agentry stable feed.\n' >&2
        return 1
    }
    [[ "$public_key" == "$AGENTRY_SPARKLE_PUBLIC_ED_KEY" ]] || {
        printf 'ERROR: SUPublicEDKey does not match the approved Agentry public key.\n' >&2
        return 1
    }
}
