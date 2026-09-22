#!/usr/bin/env python3
# ===========================================================================
# Mock REST API as target system for the Web Services connector
# ===========================================================================
# Emulates a typical HR-management API as addressed by the
# WebServicesConnector:
#
#   GET    /api/v1/users            list with paging
#   GET    /api/v1/users/{id}       single fetch
#   POST   /api/v1/users            create
#   PATCH  /api/v1/users/{id}       update
#   DELETE /api/v1/users/{id}       delete
#   POST   /api/v1/users/{id}/roles         add one role  {"role": ...}
#   DELETE /api/v1/users/{id}/roles/{role}  remove one role
#   GET    /api/v1/groups           groups (entitlements)
#   GET    /api/v1/health           connectivity test
#
# Deliberately NOT SCIM: the SCIM connector has its own target system
# (container "scim"). This is about an arbitrary REST interface as most
# commonly seen in projects - with its own data structure, its own paging
# and its own error format.
#
# The response structure is intentionally nested (data[], meta{}) because
# that is exactly what the connector mapping hinges on: rootPath must
# point at it. A flat list would not exercise that part.
#
# Authentication via bearer token (API_TOKEN) or Basic Auth
# (BASIC_USER/BASIC_PASSWORD) - matching the two common values of
# authenticationMethod in the connector: "OAuthLogin" resp. "BasicLogin".
#
# Data comes from the same HR CSV as the other target systems - so
# employeeNumber is the same correlation key everywhere.
# ===========================================================================
import base64
import csv
import json
import os
import re
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

API_TOKEN = os.environ.get("API_TOKEN", "mocktoken")

# Basic Auth as alternative to the token. The Web Services connector
# supports both (authenticationMethod="BasicLogin" resp. "OAuthLogin");
# the mock accepts both so the integration can be switched without
# touching the server.
BASIC_USER = os.environ.get("BASIC_USER", "iiq")
BASIC_PASSWORD = os.environ.get("BASIC_PASSWORD", "iiqpassword")
PORT = int(os.environ.get("PORT", "8000"))
CSV_PATH = Path(os.environ.get("HR_CSV", "/data/hr/HR-people.csv"))

# Print every request body to the log. Off by default; the compose override
# turns it on because seeing what the Web Services connector really sends
# is the fastest way to debug a body template.
LOG_BODIES = os.environ.get("LOG_BODIES", "").lower() in ("1", "true", "yes")

# How many people from the CSV become seed accounts. As with LDAP and
# JDBC, the target system is nearly empty - IdentityIQ creates the rest.
SEED_LIMIT = int(os.environ.get("SEED_COUNT", "4"))
# The last N seed accounts start as DISABLED, so the aggregation has to
# carry the account state into IIQ, not only its existence.
SEED_DISABLED = int(os.environ.get("SEED_DISABLED", "0"))

# Default page size. Deliberately small so the connector's paging is
# exercised even with few records.
DEFAULT_PAGE_SIZE = 50

_lock = threading.Lock()
_users: dict[str, dict] = {}
_groups: dict[str, dict] = {}


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def public(user: dict) -> dict:
    """
    Output view of a user: adds the boolean "disabled" derived from the
    status. The Web Services connector maps a response field to the
    reserved IIQDisabled attribute only as a boolean; it cannot compare
    the status string itself.
    """
    return {**user, "disabled": user.get("status") != "ACTIVE"}


def load_seed_data() -> None:
    """
    Reads the seed accounts from the HR CSV.

    If the file is unavailable the service still starts - just empty.
    A mock that fails to come up for lack of test data would hinder
    debugging.
    """
    groups = [
        ("grp-portal-read",   "Portal: read access"),
        ("grp-portal-write",  "Portal: write access"),
        ("grp-portal-admin",  "Portal: administration"),
        ("grp-reports",       "Reports"),
        ("grp-api-access",    "API access"),
    ]
    for name, description in groups:
        gid = str(uuid.uuid5(uuid.NAMESPACE_DNS, name))
        _groups[gid] = {
            "id": gid,
            "name": name,
            "description": description,
            "createdAt": now(),
        }

    if not CSV_PATH.is_file():
        print(f"[mockapi] {CSV_PATH} not found - starting without seed accounts.")
        return

    try:
        with CSV_PATH.open(encoding="utf-8") as f:
            rows = list(csv.DictReader(f, delimiter=";"))
    except (OSError, UnicodeDecodeError, csv.Error) as e:
        print(f"[mockapi] {CSV_PATH} not readable ({e}) - "
              f"starting without seed accounts.")
        return

    # Only active people as seed accounts, and only the first few.
    active = [r for r in rows if r.get("status") == "active"]
    skipped = 0
    for i, r in enumerate(active[:SEED_LIMIT]):
        # Missing or empty columns must not prevent startup. The
        # docstring promises the service comes up without test data -
        # that must hold for an incomplete file, not just a missing one.
        number = (r.get("employeeNumber") or "").strip()
        mail = (r.get("email") or "").strip()
        if not number:
            skipped += 1
            continue
        uid = str(uuid.uuid5(uuid.NAMESPACE_DNS, number))
        # The first two get more permissions - so entitlement
        # aggregation has something to do.
        assigned = ["grp-portal-read"]
        if i == 0:
            assigned += ["grp-portal-admin", "grp-api-access", "grp-reports"]
        elif i == 1:
            assigned += ["grp-portal-write"]

        _users[uid] = {
            "id": uid,
            "employeeId": number,
            "login": mail.split("@")[0] if "@" in mail else f"user{number}",
            "firstName": r.get("firstName", ""),
            "lastName": r.get("lastName", ""),
            "fullName": r.get("displayName", ""),
            "email": mail,
            "jobTitle": r.get("title", ""),
            "department": r.get("department", ""),
            "office": r.get("location", ""),
            "status": "DISABLED" if i >= SEED_LIMIT - SEED_DISABLED else "ACTIVE",
            "roles": assigned,
            "createdAt": now(),
            "updatedAt": now(),
        }

    note = f", {skipped} row(s) skipped" if skipped else ""
    print(f"[mockapi] Loaded {len(_users)} seed accounts, "
          f"{len(_groups)} groups{note}.")


class Handler(BaseHTTPRequestHandler):

    # BaseHTTPRequestHandler's default logging goes to stderr and is
    # unstructured - one terse line per request instead.
    def log_message(self, format, *args):
        # BaseHTTPRequestHandler also calls log_message from log_error
        # with a different signature - args[1] does not exist then.
        status = args[1] if len(args) > 1 else "-"
        print(f"[mockapi] {self.command} {self.path} -> {status}")

    # -- Helpers ----------------------------------------------------------

    def _respond(self, code: int, payload=None) -> None:
        data = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _error(self, code: int, message: str) -> None:
        # Custom error format - web-service APIs rarely share one.
        # The connector evaluates the HTTP code; the body is for
        # troubleshooting.
        self._respond(code, {
            "error": {"code": code, "message": message,
                      "timestamp": now()}
        })

    def _authorized(self) -> bool:
        """
        Accepts bearer token AND Basic Auth.

        Lets the IdentityIQ application switch between
        authenticationMethod="OAuthLogin" and "BasicLogin" without
        reconfiguring the mock.
        """
        header = self.headers.get("Authorization", "")

        if header == f"Bearer {API_TOKEN}":
            return True

        if header.startswith("Basic "):
            try:
                raw = base64.b64decode(header[6:]).decode("utf-8")
                user, _, password = raw.partition(":")
                if user == BASIC_USER and password == BASIC_PASSWORD:
                    return True
            except (ValueError, UnicodeDecodeError):
                pass

        self._error(401, "Invalid or missing credentials")
        return False

    # Upper bound for request bodies. Anything a provisioning connector
    # sends is a few hundred bytes; the cap only stops a runaway client
    # from making the handler read gigabytes into memory.
    MAX_BODY = 1024 * 1024

    def _body(self) -> dict | None:
        # Content-Length is client input: non-numeric would raise an
        # uncaught ValueError (handler thread dies), negative would make
        # rfile.read(-1) block until the peer hangs up.
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._error(400, "Invalid Content-Length")
            return None
        if length < 0 or length > self.MAX_BODY:
            self._error(413, f"Body exceeds {self.MAX_BODY} bytes")
            return None
        if length == 0:
            # A real API rejects a create or update without a body. The Web
            # Services connector silently sends none when the body template
            # sits under the wrong key (rawBody instead of jsonBody), and a
            # tolerant 200 here hid that for the whole leaver/joiner path.
            self._error(400, "Request body required")
            return None
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        if LOG_BODIES:
            print(f"[mockapi] {self.command} {self.path} body: {raw}")
        try:
            parsed = json.loads(raw)
        except ValueError:
            self._error(400, "Body is not valid JSON")
            return None
        # Callers use .get(); a JSON array or scalar would crash them.
        if not isinstance(parsed, dict):
            self._error(400, "Body must be a JSON object")
            return None
        return parsed

    @staticmethod
    def _page(items: list, query: dict) -> dict:
        """
        Builds one page plus metadata.

        offset/limit instead of page/size: both variants occur, the
        connector has to be mapped to whichever one. offset is the more
        common here.
        """
        try:
            offset = max(0, int(query.get("offset", ["0"])[0]))
        except ValueError:
            offset = 0
        try:
            limit = int(query.get("limit", [str(DEFAULT_PAGE_SIZE)])[0])
        except ValueError:
            limit = DEFAULT_PAGE_SIZE
        limit = max(1, min(limit, 200))

        chunk = items[offset:offset + limit]
        return {
            "data": chunk,
            "meta": {
                "total": len(items),
                "offset": offset,
                "limit": limit,
                "hasMore": (offset + limit) < len(items),
            },
        }

    # -- Endpoints --------------------------------------------------------

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        query = parse_qs(parsed.query)

        # The connectivity test deliberately needs no token: this
        # distinguishes "service unreachable" from "authentication
        # failed".
        if path == "/api/v1/health":
            self._respond(200, {"status": "UP", "time": now()})
            return

        if not self._authorized():
            return

        if path == "/api/v1/users":
            with _lock:
                items = [public(u) for u in sorted(_users.values(), key=lambda u: u["employeeId"])]
            self._respond(200, self._page(items, query))
            return

        match = re.fullmatch(r"/api/v1/users/([^/]+)", path)
        if match:
            with _lock:
                user = _users.get(match.group(1))
            if user is None:
                self._error(404, "User not found")
            else:
                self._respond(200, public(user))
            return

        if path == "/api/v1/groups":
            with _lock:
                items = sorted(_groups.values(), key=lambda g: g["name"])
            self._respond(200, self._page(items, query))
            return

        self._error(404, f"Unknown path: {path}")

    def do_POST(self):
        if not self._authorized():
            return
        if self._role_delta(add=True):
            return
        path = urlparse(self.path).path.rstrip("/")
        if path != "/api/v1/users":
            self._error(404, f"Unknown path: {path}")
            return

        body = self._body()
        if body is None:
            return

        for required in ("login", "employeeId"):
            if not body.get(required):
                self._error(400, f"Missing required field: {required}")
                return

        with _lock:
            # employeeId is the business key and must stay unique -
            # otherwise IIQ correlates ambiguously later.
            for user in _users.values():
                if user["employeeId"] == body["employeeId"]:
                    self._error(409, "employeeId already taken")
                    return

            uid = str(uuid.uuid4())
            created = {
                "id": uid,
                "employeeId": body["employeeId"],
                "login": body["login"],
                "firstName": body.get("firstName", ""),
                "lastName": body.get("lastName", ""),
                "fullName": body.get("fullName", ""),
                "email": body.get("email", ""),
                "jobTitle": body.get("jobTitle", ""),
                "department": body.get("department", ""),
                "office": body.get("office", ""),
                "status": body.get("status", "ACTIVE"),
                "roles": body.get("roles", []),
                "createdAt": now(),
                "updatedAt": now(),
            }
            _users[uid] = created

        self._respond(201, public(created))

    # --- roles sub-resource: the delta path IIQ actually uses ------------
    #
    # IIQ's Modify sends Add/Remove of single values, never the full
    # list. Mapped to "Add Entitlement" / "Remove Entitlement" endpoints
    # in the Web Services application:
    #   POST   /api/v1/users/{id}/roles           {"role": "grp-..."}
    #   DELETE /api/v1/users/{id}/roles/{role}
    # PATCH with {"roles": [...]} still replaces the whole list - that is
    # the "Set" semantics and stays available for tests.
    _ROLES_RE = re.compile(r"/api/v1/users/([^/]+)/roles(?:/([^/]+))?")

    def _role_delta(self, add: bool) -> bool:
        """Handles the roles sub-resource; returns False if the path is not it."""
        match = self._ROLES_RE.fullmatch(urlparse(self.path).path.rstrip("/"))
        if not match:
            return False
        user_id, role_in_path = match.group(1), match.group(2)
        if add:
            body = self._body()
            if body is None:
                return True
            role = (body.get("role") or "").strip()
        else:
            role = role_in_path or ""
        if not role:
            self._error(400, "Missing role")
            return True
        with _lock:
            user = _users.get(user_id)
            if user is None:
                self._error(404, "User not found")
                return True
            roles = list(user.get("roles") or [])
            if add and role not in roles:
                roles.append(role)
            if not add and role in roles:
                roles.remove(role)
            user["roles"] = roles
            user["updatedAt"] = now()
            result = dict(user)
        self._respond(200 if add else 200, result)
        return True

    def do_PATCH(self):
        if not self._authorized():
            return
        match = re.fullmatch(r"/api/v1/users/([^/]+)",
                             urlparse(self.path).path.rstrip("/"))
        if not match:
            self._error(404, "Unknown path")
            return

        body = self._body()
        if body is None:
            return

        with _lock:
            user = _users.get(match.group(1))
            if user is None:
                self._error(404, "User not found")
                return
            for key, value in body.items():
                # id and employeeId are immutable: changing them would
                # break correlation in IIQ.
                if key in ("id", "employeeId", "createdAt"):
                    continue
                user[key] = value
            user["updatedAt"] = now()
            result = dict(user)

        self._respond(200, result)

    def do_DELETE(self):
        if not self._authorized():
            return
        if self._role_delta(add=False):
            return
        match = re.fullmatch(r"/api/v1/users/([^/]+)",
                             urlparse(self.path).path.rstrip("/"))
        if not match:
            self._error(404, "Unknown path")
            return

        with _lock:
            if _users.pop(match.group(1), None) is None:
                self._error(404, "User not found")
                return

        self._respond(204)


def main() -> None:
    load_seed_data()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    # Never print the secrets: this goes into `docker compose logs` and
    # from there into every log export. (The same mistake, `cat
    # iiq.properties` into the log, is what CLAUDE.md faults reference
    # project C for.) The values are in .env.
    print(f"[mockapi] Listening on port {PORT}")
    print(f"[mockapi]   Bearer token: {'set' if API_TOKEN else 'EMPTY'}")
    print(f"[mockapi]   Basic Auth:   user {BASIC_USER!r}, password "
          f"{'set' if BASIC_PASSWORD else 'EMPTY'}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
