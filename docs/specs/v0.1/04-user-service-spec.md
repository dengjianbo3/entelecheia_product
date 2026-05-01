# 04 — `user-service` v0.1 spec

> **Status**: v0.1 contract for product's user-preferences service.
> **Lives at**: `packages/user-service/`.
> **Depends on**: `03-auth-service-spec.md` for the `require_auth` FastAPI dependency (user-service does NOT verify tokens itself).
> **Consumed by**: `02-platform-shell-spec.md` (`useUser` composable's merge step; `useTheme`, `useI18n`, `useActiveVertical`, `useNotifications` setters), `16-apps-frontend-spec.md` (boot-time fetch).

---

## Mission

This file defines the user-service — a small FastAPI sub-application that stores and serves user preferences (theme, locale, active vertical, notification settings) so that the frontend can persist user choices across sessions and devices. Auth is delegated to `auth-service`; user-service receives a verified `user_id` via the `require_auth` dependency and proceeds.

**Hard rule** (separation of concerns): user-service does NOT authenticate, does NOT store passwords, does NOT enforce permissions, does NOT know which verticals exist. It is a typed key-value store keyed by `user_id`.

---

## Scope

**Covers.**
- SQLite schema (1 table: `user_preferences`).
- Pydantic models for `UserPreferences` + `NotificationPreferences`.
- 3 endpoints: `GET /api/user/preferences`, `PUT /api/user/preferences`, `PATCH /api/user/preferences`.
- The cross-spec merge contract: how the frontend's `useUser()` composable assembles a unified `User` from `AuthUser` (this spec consumes auth-service's output) + `UserPreferences` (this spec).
- Per-vertical opacity: `active_vertical` is stored as an opaque string; no FK or validation against a vertical registry.
- Lazy row creation: first read for a never-seen user returns defaults; first write creates the row.
- Sealed error taxonomy (4 leaves) + HTTP status mapping.
- Configuration (env vars).
- Test matrix per endpoint.
- Why-this / why-not blocks.

**Does not cover.**
- Authentication / sessions / passwords — `03-auth-service-spec.md`.
- The `User` interface assembled by the frontend — that lives in `02-platform-shell-spec.md` §2.1.
- Vertical registry — `02-platform-shell-spec.md` §3 (frontend) + `13-vertical-template-spec.md` (backend manifest); user-service stores `active_vertical` opaquely.
- Notification storage. Per `02-platform-shell-spec.md` §7, notifications are per-tab in v0.1, retained client-side only (last 50). User-service stores only the `enabled` flag + the `severities` filter — preferences about HOW notifications behave, not the notifications themselves.
- Frontend setter UI (theme picker, locale picker, vertical switcher) — composables in `02-platform-shell-spec.md` consume this API.
- User-deletion / GDPR-style export — internal product; deferred until needed.

**Out of scope for v0.1.**
- Cross-device sync events (write here → push to other tabs / devices). Each tab fetches at boot; subsequent changes are local-only until the next reload.
- Versioned preferences history (audit log of who changed what when).
- Per-vertical preferences (e.g., "for vertical-a my default tab is X"). Verticals MAY add their own keyspace in v0.2 via an `extras: dict[str, dict]` field — explicitly out of v0.1 scope.
- Migration framework for adding new preference fields (v0.1 ships the v0.1 schema; new fields = Alembic migration + default values).
- Bulk operations for admin (no admin endpoints in v0.1).

---

## §1 Module layout

```
packages/user-service/
├── src/entelecheia_user/
│   ├── __init__.py
│   ├── app.py                       # FastAPI router exposed under /api/user/*
│   ├── models.py                    # UserPreferences + NotificationPreferences (pydantic)
│   ├── db/
│   │   ├── __init__.py
│   │   ├── session.py               # SQLAlchemy session factory; SQLite engine
│   │   ├── tables.py                # SQLAlchemy declarative tables
│   │   └── crud.py                  # CRUD helpers (transactional)
│   ├── deps.py                      # get_user_id (uses auth-service's require_auth)
│   ├── errors.py                    # sealed taxonomy + HTTP mapping
│   └── config.py                    # env-driven settings
├── alembic/
│   ├── env.py
│   └── versions/
│       └── 001_initial.py
├── tests/
│   ├── conftest.py                  # in-memory SQLite + test client + fake auth fixture
│   ├── test_get_preferences.py
│   ├── test_put_preferences.py
│   ├── test_patch_preferences.py
│   ├── test_defaults.py
│   ├── test_validation.py
│   └── test_lazy_creation.py
├── pyproject.toml
└── README.md
```

**Single-process FastAPI sub-app.** Mounted by `apps/api/main.py` under `/api/user` prefix (per `15-apps-api-spec.md`). Lives inside the same Python process as auth-service in v0.1 for deployment simplicity. Independent SQLite database file (`AUTH_DB_URL` and `USER_DB_URL` separate per §11).

---

## §2 Data models

### 2.1 SQLite schema

```sql
-- user_preferences (one row per user; lazily created on first write)
CREATE TABLE user_preferences (
    user_id                   TEXT PRIMARY KEY,                               -- ULID; matches auth-service users.user_id
    theme_mode                TEXT NOT NULL DEFAULT 'system',                 -- light | dark | system
    locale                    TEXT NOT NULL DEFAULT 'en',                     -- zh | en
    active_vertical           TEXT,                                            -- vertical_id; nullable
    notifications_enabled     INTEGER NOT NULL DEFAULT 1,                     -- 0/1
    notifications_severities  TEXT NOT NULL DEFAULT '["info","success","warning","error"]',  -- JSON array
    created_at                TEXT NOT NULL,                                   -- ISO-8601 UTC
    updated_at                TEXT NOT NULL
);
```

**No foreign key to auth-service users.** The two services have independent SQLite files; cross-service FK would require a shared DB. Instead, `user_id` is an opaque match. If a user is deleted in auth-service, their preferences row is orphaned (acceptable for v0.1; cleanup script is operational, not API).

**Why JSON-encoded `notifications_severities` instead of a normalized table.** It's a small fixed-cardinality set (4 values); a normalized `notification_severity_filters(user_id, severity)` table would be 4 rows of overhead per user with no query benefit (we always read the full filter together). JSON column is one read, one write.

### 2.2 Pydantic models

```python
# packages/user-service/src/entelecheia_user/models.py

from typing import Annotated, Literal
from pydantic import BaseModel, Field, StringConstraints

# Type aliases
ThemeMode  = Literal["light", "dark", "system"]
Locale     = Literal["zh", "en"]
Severity   = Literal["info", "success", "warning", "error"]
VerticalId = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_-]*$", max_length=60)]


class NotificationPreferences(BaseModel):
    enabled:    bool = True
    severities: list[Severity] = Field(default_factory=lambda: ["info", "success", "warning", "error"])

    # Note: severities is a list (not a set) because JSON has no native set type;
    # duplicates are permitted in the wire format but normalized at write time
    # (sorted + deduped via model_validator).


class UserPreferences(BaseModel):
    theme_mode:      ThemeMode = "system"
    locale:          Locale = "en"
    active_vertical: VerticalId | None = None
    notifications:   NotificationPreferences = Field(default_factory=NotificationPreferences)


class UserPreferencesPatch(BaseModel):
    """Partial update — every field optional. Validated as PATCH semantics:
    only-present fields are updated; absent fields are left as-is."""
    theme_mode:      ThemeMode | None = None
    locale:          Locale | None = None
    active_vertical: VerticalId | None = None     # nullable in storage; pass None to UNSET (see §3.3)
    notifications:   NotificationPreferences | None = None

    # Special tri-state for active_vertical:
    #   - field absent (PATCH does not include the key)        → leave existing value as-is
    #   - field present, value = some_id                       → update to some_id
    #   - field present, value = null                          → clear (set to NULL in DB)
    # Implemented via Pydantic's `model_fields_set` introspection at the route layer.
```

### 2.3 Defaults

The default `UserPreferences` is what `GET` returns for a never-seen user (no DB row yet):

```json
{
  "theme_mode": "system",
  "locale": "en",
  "active_vertical": null,
  "notifications": {
    "enabled": true,
    "severities": ["info", "success", "warning", "error"]
  }
}
```

These defaults match `02-platform-shell-spec.md` §2.10 `UserPreferences` interface. The shell on first run shows English UI, follows OS theme, and resolves the active vertical via the boot fallback chain (per `02-platform-shell-spec.md` §10 step 8: "If null OR not in registered set: pick first vertical user has permission for").

---

## §3 API endpoints

All endpoints under `/api/user/*` prefix. `Content-Type: application/json`. Error envelope matches the auth-service / studio shape (per `03-auth-service-spec.md` §6): `{"error": {"type": "...", "message": "...", "extras": {...}}}`.

### 3.1 `GET /api/user/preferences`

```
GET /api/user/preferences
  auth:   required (delegates to auth-service require_auth)
  200:    UserPreferences
  401:    AuthRequired | SessionExpired | SessionRevoked | InvalidToken (relayed from auth-service)
  500:    InternalError
```

**Behavior.**
1. Resolve `user_id` from the auth context (delegated dependency, see §5).
2. SELECT * FROM user_preferences WHERE user_id = ?
3. If no row → return the default `UserPreferences` (per §2.3); do NOT create a row (lazy creation per §6.4).
4. If row exists → deserialize fields, return.

**Caching.** No cache headers; preferences are mutable and the response is small. Frontend's `useUser()` composable caches in memory; refreshes on `useUser().refresh()` or 401.

### 3.2 `PUT /api/user/preferences`

Full replace.

```
PUT /api/user/preferences
  body:   UserPreferences   (every field present; missing fields = use default)
  auth:   required
  200:    UserPreferences   (echoes the saved values, including normalizations)
  400:    InvalidPreferences   (e.g., theme_mode not in allowed set, malformed severities)
  401:    (relayed)
  500:    InternalError
```

**Behavior.**
1. Validate body against `UserPreferences` (Pydantic enforces all field constraints).
2. Normalize: `notifications.severities` is sorted + deduped before storage.
3. UPSERT (INSERT … ON CONFLICT UPDATE) the row. `created_at` set on first write; `updated_at` set every write.
4. Return the saved values.

**Idempotent.** Same body twice → identical response, identical DB state (only `updated_at` changes).

### 3.3 `PATCH /api/user/preferences`

Partial update. Only fields present in the request body are updated; absent fields are left as-is.

```
PATCH /api/user/preferences
  body:   UserPreferencesPatch    (every field optional)
  auth:   required
  200:    UserPreferences         (full saved state, post-patch)
  400:    InvalidPreferences
  401:    (relayed)
  500:    InternalError
```

**`active_vertical` tri-state semantics** (because `null` is a valid value, distinct from "leave alone"):

| Body fragment                              | Effect                                  |
|--------------------------------------------|-----------------------------------------|
| `{"theme_mode": "dark"}`                    | only `theme_mode` updated; `active_vertical` left as-is |
| `{"active_vertical": "vertical-b"}`         | `active_vertical` set to `"vertical-b"` |
| `{"active_vertical": null}`                 | `active_vertical` cleared (set to NULL in DB) |
| `{"active_vertical": null, "locale": "zh"}` | `active_vertical` cleared AND `locale` updated |

Implementation reads Pydantic's `model_fields_set` to distinguish "field absent" from "field present-and-null."

**Lazy creation.** If no row exists yet, the patch is applied on top of the defaults (§2.3) and INSERTed.

**Behavior steps.**
1. Validate against `UserPreferencesPatch`.
2. SELECT existing row (or use defaults if none).
3. Apply present-only fields from the patch.
4. Normalize (sort + dedup `severities` if patched).
5. UPSERT.
6. Return the full post-patch state.

---

## §4 Cross-spec User merge contract

`02-platform-shell-spec.md` §2.1 declares a `User` interface with `permissions` AND `preferences`. The frontend assembles this from two services:

```typescript
// packages/platform-shell/src/composables/useUser.ts (excerpt)
async function fetchUser(): Promise<User> {
  const [authUser, prefs] = await Promise.all([
    fetch("/api/auth/me").then(r => parseOrThrow(r)),
    fetch("/api/user/preferences").then(r => parseOrThrow(r)),
  ]);
  return {
    user_id:           authUser.user_id,
    display_name:      authUser.display_name,
    email:             authUser.email,
    permissions:       authUser.permissions,
    authenticated_at:  authUser.authenticated_at,
    preferences:       prefs,
  };
}
```

**Failure semantics.**
- If `/api/auth/me` returns 401 → user is unauthenticated; navigate to `/login` (per `02` §10 boot step 6a). No preferences fetch needed.
- If `/api/auth/me` succeeds but `/api/user/preferences` fails (5xx, network) → log the error; use the default `UserPreferences` (§2.3) as a fallback so the UI is usable. A toast notifies the user "Settings unavailable; using defaults." Subsequent setter calls retry the write.
- If `/api/user/preferences` succeeds but `/api/auth/me` fails → block boot (cannot proceed without identity).

This split keeps the two services independently deployable and testable; one service being slow does not poison the other's response.

---

## §5 Dependency on auth-service

User-service does NOT verify JWTs. It depends on auth-service's `require_auth` dependency (per `03-auth-service-spec.md` §7).

```python
# packages/user-service/src/entelecheia_user/deps.py

from typing import Annotated
from fastapi import Depends
from entelecheia_auth.deps import require_auth, CurrentAuthContext


async def get_user_id(
    ctx: Annotated[CurrentAuthContext, Depends(require_auth)],
) -> UserId:
    """The only context user-service needs from auth-service: the verified user_id."""
    return ctx.user_id
```

All three endpoints (§3) declare `Depends(get_user_id)` and operate on that `user_id`. If `require_auth` raises, the auth error envelope (per `03` §6) propagates to the client; user-service's own taxonomy (§6) does NOT include auth errors.

---

## §6 Error taxonomy (sealed)

Single-file declaration. Every error inherits from `UserServiceError`.

```python
# packages/user-service/src/entelecheia_user/errors.py

class UserServiceError(Exception):
    error_type:   str        # frozen identifier
    http_status:  int
    message:      str        # human-readable; NOT contract-stable

# 400
class InvalidPreferences(UserServiceError):       ...   # 400  — validation failed (e.g., bad theme_mode value)

# 500
class InternalError(UserServiceError):            ...   # 500  — DB error or other unexpected

# (Auth-related errors are RAISED BY auth-service's require_auth dep and propagate
#  through unchanged. They are NOT in this service's taxonomy.)
```

**Total: 2 leaves.** Tiny on purpose — user-service does very little and most errors come from the auth dependency or the validation library.

**Per-error extras**:
- `InvalidPreferences`: `{ "field": "<field_name>", "value": "<sanitized>", "reason": "<short reason>" }`
- `InternalError`: `{ "trace_id": "<uuid>" }` for log correlation.

### 6.4 Lazy creation (no DB row yet) is NOT an error

`GET` returns defaults; `PUT` / `PATCH` create the row. There is no "user has no preferences row" error.

---

## §7 i18n (errors surfaced to UI)

Error codes map to UI strings via `packages/platform-shell/i18n/<lang>.json` under namespace `error.user.*`:

```json
{
  "error.user.invalid_preferences": "Invalid preference value: {reason}",
  "error.user.internal_error":      "Could not save preferences. Try again."
}
```

Auth errors propagate through and use `error.auth.*` keys (per `03` §10) — frontend handles them centrally.

---

## §8 Test matrix

Run via pytest. In-memory SQLite + a fake-auth fixture that injects a `CurrentAuthContext` with a configurable `user_id`.

### 8.1 GET /preferences

| scenario | preconditions | expected | test_id |
|---|---|---|---|
| existing row | row stored for user | 200 with stored values | `t_get_existing` |
| no row (first-ever read) | DB empty for user | 200 with defaults; NO row created | `t_get_defaults_lazy` |
| auth missing | no JWT | 401 (relayed from auth-service) | `t_get_no_auth` |
| auth expired | expired JWT | 401 `session_expired` (relayed) | `t_get_expired_auth` |
| different user | row for user A; auth as user B | 200 with B's defaults (NOT A's row) | `t_get_isolation` |

### 8.2 PUT /preferences

| scenario | input | expected | test_id |
|---|---|---|---|
| happy full | every field valid | 200; row UPSERTed; created_at + updated_at set | `t_put_happy` |
| happy minimal | every field at defaults | 200; row UPSERTed with defaults | `t_put_all_defaults` |
| invalid theme | `theme_mode: "blue"` | 400 `invalid_preferences{field: theme_mode}` | `t_put_invalid_theme` |
| invalid locale | `locale: "fr"` | 400 (zh/en only in v0.1) | `t_put_invalid_locale` |
| invalid severity | `notifications.severities: ["panic"]` | 400 | `t_put_invalid_severity` |
| invalid vertical_id format | `active_vertical: "Vertical_A!"` | 400 | `t_put_invalid_vertical_format` |
| severities normalized | input `["error","info","info","success"]` | stored as `["error","info","success"]` (sorted+deduped); response echoes normalized | `t_put_normalize_severities` |
| repeat (idempotent) | same body twice | second response identical except `updated_at`; DB has same logical state | `t_put_idempotent` |

### 8.3 PATCH /preferences

| scenario | input | preconditions | expected | test_id |
|---|---|---|---|---|
| theme only | `{theme_mode: "dark"}` | row with locale=zh, theme=light | row updated to theme=dark, locale=zh unchanged | `t_patch_one_field` |
| set active_vertical | `{active_vertical: "v-a"}` | active_vertical=null | active_vertical=v-a | `t_patch_set_vertical` |
| clear active_vertical | `{active_vertical: null}` | active_vertical=v-a | active_vertical=null | `t_patch_clear_vertical` |
| absent active_vertical | `{theme_mode: "light"}` | active_vertical=v-a | active_vertical=v-a unchanged | `t_patch_omit_vertical` |
| patch on no row (lazy create) | `{theme_mode: "dark"}` | DB empty for user | row created with theme=dark + other defaults | `t_patch_lazy_create` |
| patch notifications partial | `{notifications: {enabled: false}}` | row exists | enabled=false; severities preserved | `t_patch_nested_replace` |
| empty body | `{}` | row exists | 200; no field changes; `updated_at` still bumped | `t_patch_empty_body` |
| invalid value | `{theme_mode: "rainbow"}` | row exists | 400 `invalid_preferences`; row unchanged | `t_patch_invalid_no_partial_apply` |

### 8.4 Concurrency

| scenario | actions | expected | test_id |
|---|---|---|---|
| two parallel PATCHes | T1 PATCH theme=dark, T2 PATCH locale=zh | both succeed; final row has both changes; one updated_at wins (last writer) | `t_patch_concurrent_disjoint_fields` |
| two parallel PATCHes same field | T1 theme=dark, T2 theme=light | both succeed; final state is one of {dark, light}; no error | `t_patch_concurrent_same_field` |

(v0.1 has no optimistic locking. Concurrent edits to the same field are last-writer-wins. v0.2 may add `If-Match: <etag>` if it becomes a problem.)

---

## §9 Configuration (env vars)

```python
# packages/user-service/src/entelecheia_user/config.py

class UserSettings(BaseSettings):
    db_url:    str = "sqlite:///./.product_data/user.db"   # SQLAlchemy URL
    debounce_log_writes_ms: int = 0                         # diagnostic; 0 = log every write

    class Config:
        env_prefix = "USER_"
```

Notably **no** secrets — user-service has no JWT signing, no password hashing. Auth-service owns all crypto.

---

## §10 Why this design — load-bearing decisions

**Why split user-service from auth-service.**
Auth has cryptographic load (argon2id is intentionally slow); preferences are a typed key-value store. Separating means we can scale the slow service without scaling the fast one, and keep blast radius small (a bug in preferences DB cannot leak password hashes; a bug in auth doesn't drop preferences). Independently deployable also means we can swap the prefs storage (e.g., to PostgreSQL or Redis) without touching auth.
*Considered and rejected.* **One service for both** — couples blast radius; complicates per-domain testing.

**Why no FK from user_preferences.user_id to auth-service users.user_id.**
Cross-service FK requires shared DB, which defeats independent deployability. v0.1 trade-off: orphaned preference rows after user deletion are tolerated; an operational cleanup script can be added if it becomes a problem.
*Considered and rejected.* **Shared SQLite DB with cross-service FK** — couples deployment.

**Why JSON-encoded `notifications.severities` instead of a normalized join table.**
Small fixed-cardinality set (4 values); always read together; never queried for "users who have severity X enabled." Normalizing adds 4 rows per user for zero query benefit.
*Considered and rejected.* **Normalized `notification_severity_filters(user_id, severity)`** — premature normalization.

**Why `active_vertical` is opaque (no validation against vertical registry).**
User-service does not know which verticals exist; the registry lives in apps/api at boot per `02` §3.3. If the user has a stale `active_vertical` pointing at a removed vertical, the shell handles it (per `02` §10 step 8). Coupling user-service to the vertical registry would mean user-service has to be restarted whenever a new vertical is installed.
*Considered and rejected.* **`FOREIGN KEY active_vertical REFERENCES verticals(vertical_id)`** — verticals registry doesn't live in user-service's DB; would require cross-service validation.

**Why merge `User` in the frontend composable, not in apps/api.**
Composing on the frontend keeps the API gateway thin (no business logic). One service being slow doesn't block the other (parallel `Promise.all`). Each service can be tested independently against its own contract; the composable's merge is a tiny declarative function tested separately.
*Considered and rejected.* **`/api/user-bundle` aggregator endpoint in apps/api** — adds a third API surface to maintain; tight coupling between two service shapes; harder to test partial-failure scenarios.

**Why `PATCH` with tri-state `active_vertical` (absent vs null vs value), not separate endpoints.**
A single endpoint handles all three update cases without proliferating verb-noun routes (`POST /preferences/clear-vertical`, `POST /preferences/set-vertical`, …). Trade-off: clients must understand the tri-state convention. Mitigated by typing and the explicit table in §3.3.
*Considered and rejected.* **Separate `/preferences/active-vertical` resource with PUT/DELETE** — RESTful but verbose; adds 2 endpoints for a single field.

**Why no notification persistence.**
Per `02-platform-shell-spec.md` §7, notifications are per-tab in v0.1 (last 50 retained client-side). Persistence would require: cross-tab sync, server-push (WebSocket / SSE), retention cleanup. Out of scope. v0.1's notifications are ephemeral by design.
*Considered and rejected.* **Persist notifications server-side** — large scope; needs cross-tab sync model that v0.1 explicitly defers.

**Why no admin endpoints in v0.1.**
No use case yet. Admin needs are limited to "deactivate a user" (handled by auth-service's `is_active = 0`) and "list users" (auth-service's `/admin/users`). Preferences are personal; admin should not be reading them in v0.1.
*Considered and rejected.* **`GET /admin/users/{id}/preferences`** — privacy concern + no use case.

**Why 2-leaf taxonomy.**
User-service's surface is small enough that most failures are auth-relayed (handled by `03`'s 15 leaves) or input-validation (one leaf, one HTTP status). Adding leaves preemptively (e.g., `PreferencesConflict` for optimistic locking) would create dead error codes; we ship them when we need them.
*Considered and rejected.* **Forward-declared 5+ leaves** — YAGNI.

---

## §11 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | `useUser()` performs the merge per §4; `useTheme().setMode()` PATCHes `theme_mode`; `useI18n().setLocale()` PATCHes `locale`; `useActiveVertical().switchTo(id)` PATCHes `active_vertical`; `useNotifications` settings setter PATCHes `notifications`. All setter calls use a 500 ms client-side debounce (per `02` §2.10). |
| `03-auth-service-spec.md` | No change. `require_auth` is consumed unchanged; user-service propagates 401s. |
| `15-apps-api-spec.md` | Hosts user-service router under `/api/user/*` in the same FastAPI process. Provides `USER_DB_URL` env var. Ensures user-service migrations run after auth-service migrations at boot (cosmetic ordering — they're independent). |
| `16-apps-frontend-spec.md` | Implements `useUser()` merge + setter debouncing; handles the partial-failure case (auth ok, prefs failed → defaults + toast). |
| `11-feature-settings-spec.md` (Batch C) | Settings UI panel reads/writes via the composables defined in `02`; does NOT bypass and call `/api/user/preferences` directly. |
| `17-substitution-tests-spec.md` | No `[SUB]` tests here (no Pseudo↔Http distinction). E2E in `18` covers full boot → load prefs → toggle theme → reload → theme persists. |

---

## §12 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (cross-device sync, history, per-vertical prefs, migrations framework, admin endpoints)
- [ ] Module layout (§1) enumerates every file
- [ ] SQLite schema (§2.1) has 1 table with documented defaults; no FK to auth-service
- [ ] Pydantic models (§2.2): UserPreferences + UserPreferencesPatch + NotificationPreferences with constraints; ThemeMode / Locale / Severity / VerticalId aliases declared
- [ ] Defaults table (§2.3) matches `02-platform-shell-spec.md` §2.10
- [ ] All 3 endpoints (§3) have method + path + body + auth + status codes + error responses
- [ ] PATCH tri-state (§3.3) for `active_vertical` documented with the truth table
- [ ] Cross-spec User merge contract (§4) documents partial-failure semantics (auth fail → block; prefs fail → defaults + toast)
- [ ] Auth dependency (§5) shows it consumes auth-service's `require_auth` (no JWT logic here)
- [ ] Sealed error taxonomy (§6): 2 leaves; auth errors explicitly excluded (relayed)
- [ ] i18n keys (§7) listed for both error_types
- [ ] Test matrix (§8): GET / PUT / PATCH covered; concurrency cases included; ≥ 20 rows
- [ ] Config (§9): env vars listed; no secrets
- [ ] Why-this / Why-not blocks (§10) for ≥ 8 load-bearing decisions
- [ ] Downstream impact (§11) lists every spec affected
- [ ] No business / domain / product / agent-role string literals (uses `vertical-a`, `v-a`, `<vertical_id>`)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No `try: ... except Exception: pass` patterns
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/04-user-service-spec.md`
