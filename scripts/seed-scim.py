#!/usr/bin/env python3
# ===========================================================================
# Replays data/seed/scim-users.json into the SCIM server.
#
# The SCIM container keeps its data in its own writable layer, so
# `docker compose down` (with or without -v) wipes it and the SCIM
# aggregation finds nothing. Run this after a fresh start:
#
#     python scripts/seed-scim.py        # or: .\scripts\iiq.ps1 seed-scim
#
# Idempotent: a user whose externalId already exists is skipped. URL and
# token come from .env (SCIM_PORT, SCIM_API_KEY) with the compose defaults.
# Standard library only.
# ===========================================================================
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEED = ROOT / "data" / "seed" / "scim-users.json"


def dotenv(key: str, default: str) -> str:
    env = ROOT / ".env"
    if env.is_file():
        for line in env.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith(f"{key}="):
                return line.split("=", 1)[1]
    return default


def main() -> int:
    if not SEED.is_file():
        print(f"seed file missing: {SEED} - run scripts/generate-testdata.py first")
        return 1
    base = f"http://localhost:{dotenv('SCIM_PORT', '8100')}"
    headers = {
        "Authorization": f"Bearer {dotenv('SCIM_API_KEY', 'secret')}",
        "Content-Type": "application/scim+json",
        "Accept": "application/scim+json",
    }

    def call(method: str, path: str, payload=None):
        req = urllib.request.Request(
            base + path,
            data=json.dumps(payload).encode() if payload is not None else None,
            headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read() or b"{}")

    try:
        existing = {u.get("externalId") for u in call("GET", "/Users").get("Resources", [])}
    except urllib.error.URLError as e:
        print(f"SCIM server not reachable at {base}: {e}")
        return 1

    created = skipped = 0
    for user in json.loads(SEED.read_text(encoding="utf-8")):
        if user["externalId"] in existing:
            skipped += 1
            continue
        call("POST", "/Users", user)
        created += 1
        print(f"  created {user['userName']} (externalId={user['externalId']})")
    print(f"SCIM seed: {created} created, {skipped} already present.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
