# 03 — `auth-service` v0.1 spec

> **Status**: v0.1 contract for product's internal authentication + authorization service.
> **Lives at**: `packages/auth-service/`.
> **Scope reminder**: studio v0.1 has NO auth (per studio §10.1). This service secures **product's** API surface (everything under `/api/*` mounted by apps/api), NOT studio. Product is single-tenant in v0.x.
> **Consumed by**: `02-platform-shell-spec.md` (`useUser` composable), every backend feature route (auth dependency), every admin tool that needs to grant permissions.

---

## Mission

This file defines the auth-service — a small FastAPI sub-application that handles user registration, login, JWT-based session management, password storage, and the permission registry that `usePermission()` reads. Every product API endpoint that requires identity calls this service's auth dependency to verify the request.

**Hard rule** (P3): auth-service is the ONLY place product hashes / verifies passwords, issues / verifies JWTs, or stores user grants. No feature, no vertical, no other service touches credentials. Other services receive a verified `AuthUser` (or 401) via the auth dependency and proceed from there.

---

## Scope

**Covers.**
- SQLite schema (4 tables: `users`, `user_permissions`, `sessions`, `known_permissions`).
- Pydantic / TypedDict request and response models.
- 5 user-facing endpoints: register, login, logout, `/me`, change-password.
- 4 admin endpoints (gated by `platform:admin`): list users, grant permission, revoke permission, register permission code.
- JWT issuing + verifying (HS256, 7-day default expiry, jti for revocation).
- Cookie + header credential transport (httpOnly cookie default; bearer header for non-browser clients).
- Argon2id password hashing.
- Permission registry: who-declares-what (platform + per-vertical) + how admin-grants reference it.
- Boot-time permission registration dance (apps/api → auth-service for platform permissions; vertical backends → auth-service for vertical-scoped permissions).
- Sealed error taxonomy (10 leaves) + HTTP status mapping.
- The auth FastAPI dependency (`require_auth`, `require_permission(code)`, `require_admin`).
- Session lifecycle: issue → use → refresh-on-401 (frontend) → logout / revoke / expire.
- Cross-vertical-switch interaction (auth-service is unaware of active vertical; permissions are evaluated per-request).
- CSRF mitigation (Origin header allowlist + samesite=lax cookies).
- Test matrix per endpoint + per dependency.

**Does not cover.**
- User preferences (theme, locale, active_vertical) — those live in `04-user-service-spec.md`. Frontend's `useUser()` composable merges auth-service `/me` + user-service `/preferences` for UI consumption.
- Studio authentication — studio v0.1 has none (per `01-studio-client-spec.md` §9.4). When studio v0.2 ships its `Authorization: Bearer <token>` surface, integration is documented in `15-apps-api-spec.md` (apps/api proxies the token, with optional translation layer in `studio-client`'s `AuthRefreshLayer`).
- Email delivery — registration v0.1 does NOT send confirmation emails; user is active immediately (single-tenant internal product).
- OAuth / SSO / social login.
- Frontend login UI (form, validation states) — that's `16-apps-frontend-spec.md`. This spec only declares the API contract.
- Permission UI (admin grants page) — there isn't one in v0.1; admin grants happen via direct API call from a CLI tool (`scripts/grant_permission.py`, mentioned in `15-apps-api-spec.md`).
- Audit log of admin actions beyond what `user_permissions.granted_by` + `granted_at` capture.

**Out of scope for v0.1.**
- Refresh tokens / token rotation — single long-lived JWT (7 days), users re-login when it expires.
- Multi-factor authentication (2FA / TOTP).
- Email verification flow.
- Password reset by email (admin can issue reset via CLI in v0.1).
- Rate limiting on `/login` — deferred to v0.2 with `slowapi` or similar.
- Multi-tenant org scoping (single-tenant for v0.x).
- Account lockout after N failed logins.
- Per-session permission scopes (token carries `sub` + `jti` only; permissions resolved live per request from DB).

---

## §1 Module layout

```
packages/auth-service/
├── src/entelecheia_auth/
│   ├── __init__.py
│   ├── app.py                       # FastAPI router exposed under /api/auth/*
│   ├── models.py                    # pydantic request/response models
│   ├── db/
│   │   ├── __init__.py
│   │   ├── session.py               # SQLAlchemy session factory; SQLite engine
│   │   ├── tables.py                # SQLAlchemy declarative tables
│   │   └── crud.py                  # CRUD helpers (each one transactional)
│   ├── jwt.py                       # JWT issue / verify (HS256)
│   ├── passwords.py                 # argon2id hash / verify
│   ├── permissions.py               # permission registry; validation
│   ├── deps.py                      # FastAPI dependencies (require_auth etc.)
│   ├── errors.py                    # sealed taxonomy + HTTP mapping
│   └── config.py                    # env-driven settings (Pydantic BaseSettings)
├── alembic/                          # migrations
│   ├── env.py
│   └── versions/
│       └── 001_initial.py
├── tests/
│   ├── conftest.py                  # in-memory SQLite + test client fixtures
│   ├── test_register.py
│   ├── test_login.py
│   ├── test_me.py
│   ├── test_logout.py
│   ├── test_change_password.py
│   ├── test_admin.py
│   ├── test_permissions.py
│   ├── test_jwt.py
│   ├── test_csrf.py
│   └── test_deps.py
├── pyproject.toml
└── README.md
```

**Single-process FastAPI sub-app.** Mounted by `apps/api/main.py` under `/api/auth` prefix (per `15-apps-api-spec.md`). Auth-service does NOT have its own server in v0.1 — it lives inside the product's main FastAPI process for deployment simplicity.

---

## §2 Data models

### 2.1 SQLite schema

```sql
-- users
CREATE TABLE users (
    user_id        TEXT PRIMARY KEY,                              -- ULID; opaque to studio
    email          TEXT UNIQUE NOT NULL COLLATE NOCASE,           -- case-insensitive uniqueness
    display_name   TEXT NOT NULL,                                  -- 1..80 chars
    password_hash  TEXT NOT NULL,                                  -- argon2id encoded string
    created_at     TEXT NOT NULL,                                  -- ISO-8601 UTC
    updated_at     TEXT NOT NULL,
    is_active      INTEGER NOT NULL DEFAULT 1                     -- 0 = soft-deactivated
);
CREATE INDEX idx_users_email ON users(email);

-- user_permissions (many-to-many)
CREATE TABLE user_permissions (
    user_id          TEXT NOT NULL,
    permission_code  TEXT NOT NULL,                                -- references known_permissions
    granted_at       TEXT NOT NULL,
    granted_by       TEXT,                                         -- user_id of admin; NULL for system seed grants
    PRIMARY KEY (user_id, permission_code),
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE
);
CREATE INDEX idx_user_permissions_code ON user_permissions(permission_code);

-- sessions (active JWTs; supports revocation by jti)
CREATE TABLE sessions (
    session_id   TEXT PRIMARY KEY,                                 -- ULID; equals JWT 'jti' claim
    user_id      TEXT NOT NULL,
    issued_at    TEXT NOT NULL,
    expires_at   TEXT NOT NULL,
    revoked_at   TEXT,                                             -- NULL = active; set on logout
    user_agent   TEXT,                                             -- truncated to 200 chars
    ip_address   TEXT,                                             -- nullable; v6-aware
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE
);
CREATE INDEX idx_sessions_user ON sessions(user_id);
CREATE INDEX idx_sessions_expires ON sessions(expires_at);

-- known_permissions (validates that admin grants reference a real code)
CREATE TABLE known_permissions (
    permission_code  TEXT PRIMARY KEY,                             -- "<scope>:<verb>"
    description      TEXT NOT NULL,
    declared_by      TEXT NOT NULL,                                -- "platform" OR vertical_id
    declared_at      TEXT NOT NULL
);
```

**Why SQLite.** Single-tenant internal product; one process; no horizontal scaling need in v0.1. WAL mode enabled for read concurrency. v0.2 can swap to PostgreSQL (auth-service's CRUD layer is the only thing that changes; tested via the same suite).

**Why ULID over UUID.** Sortable + URL-safe + 26 chars (vs 36 for UUID). Helps SQLite index locality.

### 2.2 Pydantic models

```python
# packages/auth-service/src/entelecheia_auth/models.py

from datetime import datetime
from typing import Annotated, Literal
from pydantic import BaseModel, EmailStr, Field, StringConstraints

# Type aliases (re-exported for cross-spec use)
UserId          = Annotated[str, StringConstraints(pattern=r"^[0-9A-HJKMNP-TV-Z]{26}$")]   # ULID
SessionId       = UserId                                                                     # same shape
PermissionCode  = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_-]*:[a-z][a-z0-9_-]*$", max_length=100)]
DisplayName     = Annotated[str, StringConstraints(min_length=1, max_length=80, strip_whitespace=True)]
Password        = Annotated[str, StringConstraints(min_length=8, max_length=200)]


# ── Request bodies ─────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    email:         EmailStr
    password:      Password
    display_name:  DisplayName

class LoginRequest(BaseModel):
    email:         EmailStr
    password:      Password

class ChangePasswordRequest(BaseModel):
    current_password: Password
    new_password:     Password

class GrantPermissionRequest(BaseModel):
    permission_code: PermissionCode

class RegisterPermissionRequest(BaseModel):
    permission_code: PermissionCode
    description:     Annotated[str, StringConstraints(min_length=1, max_length=400)]
    declared_by:     Annotated[str, StringConstraints(pattern=r"^(platform|[a-z][a-z0-9_-]*)$")]   # "platform" or vertical_id


# ── Response bodies ────────────────────────────────────────────────

class AuthUser(BaseModel):
    """Returned by GET /api/auth/me. Frontend's useUser() merges with UserPreferences from user-service."""
    user_id:           UserId
    email:             EmailStr
    display_name:      DisplayName
    permissions:       list[PermissionCode]                       # full list, sorted
    authenticated_at:  datetime                                    # UTC
    session_id:        SessionId                                   # current jti

class LoginResponse(BaseModel):
    user:        AuthUser
    expires_at:  datetime                                          # JWT exp; informational
    # JWT itself is set as httpOnly cookie 'auth_token' AND echoed in response.token
    # for non-browser clients
    token:       str

class RegisterResponse(BaseModel):
    user_id:     UserId
    created_at:  datetime

class UserSummary(BaseModel):                                      # for admin list
    user_id:           UserId
    email:             EmailStr
    display_name:      DisplayName
    is_active:         bool
    created_at:        datetime
    permission_count:  int

class GenericOkResponse(BaseModel):
    ok: Literal[True] = True

class KnownPermission(BaseModel):
    permission_code:  PermissionCode
    description:      str
    declared_by:      str                                          # "platform" or vertical_id
    declared_at:      datetime
```

---

## §3 API endpoints

All endpoints under `/api/auth` prefix. `Content-Type: application/json` for all bodies. Error responses follow the studio-style envelope `{"error": {"type": str, "message": str, ...extras}}` per `01-studio-client-spec.md` §5.5 — same shape, this service's own type strings (per §6).

### 3.1 `POST /api/auth/register`

Self-registration. v0.1 has no email verification; user is active immediately.

```
POST /api/auth/register
  body:   RegisterRequest
  auth:   none
  201:    RegisterResponse
  400:    InvalidEmail | WeakPassword | InvalidDisplayName
  409:    EmailAlreadyExists
  500:    InternalError
```

**Behavior.**
1. Validate `email` matches `EmailStr` (RFC 5322 basic).
2. Validate password length (`Password` annotation: min 8 chars).
3. Validate `display_name` (1–80 chars after strip).
4. Hash password with argon2id (default params from `argon2-cffi`: `time_cost=2, memory_cost=65536, parallelism=4`).
5. Insert into `users`. UNIQUE constraint on email surfaces as `EmailAlreadyExists` (409).
6. Return `RegisterResponse{user_id, created_at}`. No auto-login (caller calls `/login` next).

### 3.2 `POST /api/auth/login`

```
POST /api/auth/login
  body:    LoginRequest
  auth:    none
  headers: optional Origin (for CSRF mitigation per §5.4)
  200:     LoginResponse
           Set-Cookie: auth_token=<jwt>; HttpOnly; SameSite=Lax; Secure (in prod); Max-Age=604800
  400:     InvalidEmail | WeakPassword
  401:     AuthenticationFailed       (returned for both unknown email AND wrong password — no enumeration)
  403:     UserDeactivated
  500:     InternalError
```

**Behavior.**
1. Lookup user by `email` (case-insensitive per COLLATE NOCASE).
2. If not found OR `is_active = 0`: respond `401 AuthenticationFailed` (uniform message; no email enumeration).
3. Verify password via argon2 `verify`.
4. On success: create `sessions` row with new ULID; issue JWT (per §4); set cookie + return body.
5. Cookie: `HttpOnly; SameSite=Lax; Path=/; Max-Age=604800`. Add `Secure` flag if `config.secure_cookies = True` (prod).

**No rate limiting in v0.1.** Operationally limited by being internal infra; v0.2 adds `slowapi` 5-per-minute per IP.

### 3.3 `POST /api/auth/logout`

```
POST /api/auth/logout
  auth:    required (current session)
  200:     GenericOkResponse
           Set-Cookie: auth_token=; Max-Age=0
  401:     AuthRequired | SessionExpired | SessionRevoked | InvalidToken
```

**Behavior.**
1. Read `jti` from current JWT.
2. Update `sessions.revoked_at = now()` for that `jti`. Idempotent — re-logout on already-revoked is 200 (revoked_at not overwritten).
3. Clear cookie via `Max-Age=0`.

### 3.4 `GET /api/auth/me`

```
GET /api/auth/me
  auth:   required
  200:    AuthUser
  401:    AuthRequired | SessionExpired | SessionRevoked | InvalidToken
```

**Behavior.**
1. Verify JWT (signature + exp).
2. Look up `sessions` by `jti`; ensure not revoked.
3. Look up `users` by `sub`; ensure `is_active = 1` (otherwise `403 UserDeactivated`).
4. Read all `user_permissions.permission_code` for this user (sorted).
5. Return `AuthUser`.

**Frontend usage (per `02-platform-shell-spec.md` §10).** Called at boot. Returns AuthUser; `useUser()` then fetches `/api/user/preferences` separately and merges for the composable's exposed `User` shape.

### 3.5 `POST /api/auth/change-password`

```
POST /api/auth/change-password
  body:   ChangePasswordRequest
  auth:   required
  200:    GenericOkResponse
  400:    WeakPassword
  401:    AuthRequired | AuthenticationFailed (current_password mismatch)
  500:    InternalError
```

**Behavior.**
1. Verify current_password against stored hash. Mismatch → `401 AuthenticationFailed`.
2. Hash new_password.
3. Update `users.password_hash`, `users.updated_at`.
4. Invalidate all OTHER sessions (revoke every `sessions` row for this user except the current `jti`). Forces other devices to re-login.
5. Return ok.

### 3.6 Admin endpoints (require `platform:admin`)

Gated by `require_permission("platform:admin")` dependency.

#### 3.6.1 `GET /api/auth/admin/users`

```
GET /api/auth/admin/users
  query:  ?include_inactive={true|false}, ?limit=50, ?offset=0
  auth:   required + permission "platform:admin"
  200:    {data: list[UserSummary], total: int}
  401:    (auth errors)
  403:    PermissionDenied
```

#### 3.6.2 `POST /api/auth/admin/users/{user_id}/permissions`

```
POST /api/auth/admin/users/{user_id}/permissions
  body:   GrantPermissionRequest { permission_code }
  auth:   required + permission "platform:admin"
  200:    GenericOkResponse
  400:    UnknownPermission        (code not in known_permissions table)
  401:    (auth errors)
  403:    PermissionDenied
  404:    UserNotFound
  409:    PermissionAlreadyGranted
```

#### 3.6.3 `DELETE /api/auth/admin/users/{user_id}/permissions/{permission_code}`

```
DELETE /api/auth/admin/users/{user_id}/permissions/{permission_code}
  auth:   required + permission "platform:admin"
  200:    GenericOkResponse
  401:    (auth errors)
  403:    PermissionDenied
  404:    UserNotFound | PermissionNotGranted
```

#### 3.6.4 `POST /api/auth/admin/permissions/register`

Used by apps/api at boot to register every platform + vertical permission (per §5.3).

```
POST /api/auth/admin/permissions/register
  body:   RegisterPermissionRequest { permission_code, description, declared_by }
  auth:   required + permission "platform:admin"
           OR internal-bootstrap header (per §5.4) for boot-time registration
  200:    GenericOkResponse | (no-op on already-registered with same description)
  400:    InvalidPermissionFormat
  409:    PermissionAlreadyDeclared (with different description or declared_by)
```

**Idempotent semantics.** Same `(permission_code, description, declared_by)` triple = no-op + 200. Same code with different description / declared_by = 409 (caller must call `DELETE` first to re-declare).

#### 3.6.5 `GET /api/auth/admin/permissions`

```
GET /api/auth/admin/permissions
  query:  ?declared_by={platform|<vertical_id>}, ?limit=200
  auth:   required + permission "platform:admin"
  200:    {data: list[KnownPermission], total: int}
```

---

## §4 JWT format

**Algorithm.** HS256 (symmetric; sufficient for single-process internal service). Secret loaded from `AUTH_JWT_SECRET` env var (≥ 32 random bytes); refusing to start if shorter. v0.2 may switch to RS256 if multi-process / external verification becomes a need.

**Claims.**

```json
{
  "iss":  "entelecheia-product/auth-service/v0.1",
  "sub":  "<user_id>",
  "iat":  1714521600,
  "exp":  1715126400,
  "jti":  "<session_id>"
}
```

- `iss` (issuer) — identifies this service version; future tokens with different iss are rejected (graceful upgrade path).
- `sub` (subject) — the `user_id`.
- `iat` (issued at) — unix seconds.
- `exp` (expires at) — unix seconds; default `iat + 7 days` (configurable via `AUTH_JWT_TTL_SECONDS`).
- `jti` (JWT ID) — the `sessions.session_id`. Used for revocation lookup.

**No additional claims in v0.1** (no roles / permissions in the token — those are looked up live from the DB on each request). Rationale: revocation works without token rotation; admin grant takes effect immediately.

**Verification flow** (`require_auth` dependency):

```
1. Read token from cookie 'auth_token' OR Authorization: Bearer <token> header
   (cookie takes precedence; header allowed for non-browser clients)
2. Parse + verify signature (HS256, secret from env)
3. Verify iss == expected
4. Verify exp > now()    → otherwise raise SessionExpired
5. SELECT * FROM sessions WHERE session_id = jti
   → if no row OR revoked_at NOT NULL: raise SessionRevoked
6. SELECT * FROM users WHERE user_id = sub
   → if no row: raise InvalidToken (synthetic; should not happen since sessions FK)
   → if is_active = 0: raise UserDeactivated
7. Return AuthUser-like internal context (used by downstream deps)
```

Token is decoded ONCE per request (cached in request state for downstream deps).

---

## §5 Permissions

### 5.1 Format

`<scope>:<verb>` strings, both segments matching `^[a-z][a-z0-9_-]*$`. Examples:

- `platform:list_projects`
- `platform:run_meeting`
- `platform:view_observability`
- `platform:list_meetings`
- `platform:admin`
- `<vertical_id>:open_meeting`        (vertical-scoped)
- `<vertical_id>:upload_data`         (vertical-scoped)

**Reserved scopes**: `platform`. All other scopes MUST match a registered `vertical_id`.

### 5.2 Built-in platform permissions

Declared by `apps/api` at boot via `POST /api/auth/admin/permissions/register` (per §5.3):

| code | description | gates |
|---|---|---|
| `platform:list_projects` | List projects via studio-client | `useStudio().list_projects()` |
| `platform:list_meetings` | List meetings | `useStudio().list_meetings()` |
| `platform:run_meeting` | Start a meeting | wizard / agora launch |
| `platform:view_observability` | Open observability dashboards | observability feature route |
| `platform:list_users` | (admin) | admin endpoints |
| `platform:admin` | Full admin (grants, registrations, user management) | all admin endpoints |

### 5.3 Boot-time registration dance

At product startup, `apps/api/main.py` (per spec 15) runs:

```
1. Auth-service starts (DB migrations applied).
2. Apps/api seeds the FIRST admin user IF database is empty (per env config:
   AUTH_BOOTSTRAP_EMAIL + AUTH_BOOTSTRAP_PASSWORD); grants platform:admin.
3. Apps/api calls POST /api/auth/admin/permissions/register for each
   platform permission (§5.2), authenticated via the bootstrap admin's
   freshly-issued token (or internal-bootstrap header per §5.4).
4. Apps/api iterates each registered vertical's backend manifest's
   permissions_declared list; calls register for each
   (declared_by=<vertical_id>).
5. Apps/api logs the final known_permissions count + breakdown.
```

If step 2's bootstrap creds are missing AND no admin exists, apps/api exits with a fatal error message ("set AUTH_BOOTSTRAP_EMAIL + AUTH_BOOTSTRAP_PASSWORD to seed the first admin").

### 5.4 Internal-bootstrap header

To avoid the chicken-and-egg of "need admin to register permissions, but registration is itself permission-gated," `POST /api/auth/admin/permissions/register` accepts an alternative auth path:

```
Header: X-Internal-Bootstrap: <secret>
```

The `<secret>` matches `AUTH_INTERNAL_BOOTSTRAP_SECRET` env var. Accepts the request without JWT verification. Refused if the secret is empty / missing in env.

This header is ONLY honored on `POST /api/auth/admin/permissions/register`; no other endpoint accepts it.

### 5.5 Cross-vertical-switch interaction

When the user switches verticals (per `02-platform-shell-spec.md` §2.4), auth-service is **uninvolved**:
- Permissions are evaluated per-request, live from DB.
- Switching vertical does not re-issue tokens.
- The `<vertical_id>:*` permissions for both verticals stay valid in the user's grant list; what changes is which UI surfaces are visible (per `02` §8).

---

## §6 Error taxonomy (sealed)

Single-file declaration (`packages/auth-service/src/entelecheia_auth/errors.py`). Every error inherits from `AuthServiceError`.

```python
class AuthServiceError(Exception):
    error_type:   str        # frozen identifier, surfaces in response body
    http_status:  int
    message:      str        # human-readable; NOT contract-stable

# 400 — validation
class InvalidEmail(AuthServiceError):           ...   # 400
class WeakPassword(AuthServiceError):           ...   # 400
class InvalidDisplayName(AuthServiceError):     ...   # 400
class InvalidPermissionFormat(AuthServiceError):...   # 400

# 401 — authentication
class AuthRequired(AuthServiceError):           ...   # 401  (no token)
class AuthenticationFailed(AuthServiceError):   ...   # 401  (login bad creds OR change-pw current mismatch)
class SessionExpired(AuthServiceError):         ...   # 401  (jwt exp passed)
class SessionRevoked(AuthServiceError):         ...   # 401  (jti not in sessions OR revoked_at set)
class InvalidToken(AuthServiceError):           ...   # 401  (signature / parse / iss fail)

# 403 — authorization / activation
class PermissionDenied(AuthServiceError):       ...   # 403  (user lacks required permission code)
class UserDeactivated(AuthServiceError):        ...   # 403

# 404
class UserNotFound(AuthServiceError):           ...   # 404
class PermissionNotGranted(AuthServiceError):   ...   # 404  (revoke on a permission user doesn't have)

# 409
class EmailAlreadyExists(AuthServiceError):     ...   # 409
class PermissionAlreadyGranted(AuthServiceError):...  # 409
class PermissionAlreadyDeclared(AuthServiceError):... # 409  (re-register with different description)
class UnknownPermission(AuthServiceError):      ...   # 400  (grant a code not in known_permissions)

# 500 (catch-all in handler; sealed type for logging)
class InternalError(AuthServiceError):          ...   # 500  (DB error, hash error, etc.)
```

**Total: 14 leaves.** Each `error_type` is the class name in snake_case (e.g., `auth_required`, `permission_denied`, `email_already_exists`) — frozen for v0.x.

**Response envelope** (matches studio § 5.5 shape so frontend can treat product errors uniformly):

```json
{ "error": { "type": "auth_required", "message": "Authentication required.", "extras": {} } }
```

Per-error extras:
- `WeakPassword`: `{ "min_length": 8 }`
- `InvalidEmail`: `{ "value": "<sanitized truncated>" }`
- `EmailAlreadyExists`: `{}` (no email echo — avoid enumeration)
- `UnknownPermission`: `{ "permission_code": "<code>" }`
- `PermissionAlreadyDeclared`: `{ "permission_code": "<code>", "existing_declared_by": "<who>", "existing_description": "<what>" }`
- Others: `{}`

---

## §7 FastAPI dependencies

Lives at `packages/auth-service/src/entelecheia_auth/deps.py`. Used by every product endpoint outside auth-service itself.

```python
from typing import Annotated
from fastapi import Depends, Header, Request

class CurrentAuthContext:
    """Populated by require_auth; passed to downstream deps."""
    user_id:        UserId
    email:          str
    display_name:   str
    permissions:    frozenset[PermissionCode]
    session_id:     SessionId
    issued_at:      datetime


async def require_auth(request: Request) -> CurrentAuthContext:
    """Resolves token from cookie OR Authorization header.
    Raises AuthRequired / SessionExpired / SessionRevoked / InvalidToken / UserDeactivated."""
    ...


def require_permission(code: PermissionCode):
    """Returns a dependency that ensures the current user has the given permission.
    Raises PermissionDenied if not."""
    async def _dep(ctx: Annotated[CurrentAuthContext, Depends(require_auth)]) -> CurrentAuthContext:
        if code not in ctx.permissions:
            raise PermissionDenied(message=f"Missing permission: {code}", extras={"required": code})
        return ctx
    return _dep


def require_any_permission(*codes: PermissionCode):
    """Returns a dependency that ensures user has ANY of the given permissions."""
    async def _dep(ctx: Annotated[CurrentAuthContext, Depends(require_auth)]) -> CurrentAuthContext:
        if not (ctx.permissions & set(codes)):
            raise PermissionDenied(message=f"Need one of: {codes}", extras={"required_any": list(codes)})
        return ctx
    return _dep


require_admin = require_permission("platform:admin")
```

**Usage in feature routes** (per spec 15):

```python
from fastapi import Depends
from entelecheia_auth.deps import require_permission, CurrentAuthContext

@router.get("/projects")
async def list_projects(
    ctx: Annotated[CurrentAuthContext, Depends(require_permission("platform:list_projects"))],
    studio: StudioClient = Depends(get_studio_client),
):
    return await studio.list_projects(...)
```

---

## §8 Cookie + CSRF

### 8.1 Cookie defaults

```
Set-Cookie: auth_token=<jwt>;
            HttpOnly;
            SameSite=Lax;
            Path=/;
            Max-Age=604800;     (7 days; matches JWT exp)
            Secure              (only when config.secure_cookies = True; default True in prod)
```

`HttpOnly` defends against XSS-stealing the token. `SameSite=Lax` defends against most CSRF (only top-level GETs are sent cross-site, and our state-changing endpoints are POST/DELETE).

### 8.2 CSRF mitigation

For state-changing requests (POST / PUT / PATCH / DELETE), `require_auth` additionally enforces **Origin / Referer allowlist**:

```
ALLOWED_ORIGINS = config.allowed_origins   # e.g. ["https://app.example.com"]

if request.method in {"POST", "PUT", "PATCH", "DELETE"}:
    origin = request.headers.get("Origin") or request.headers.get("Referer")
    if origin is None: raise CsrfRejected
    if not any(origin.startswith(allowed) for allowed in ALLOWED_ORIGINS):
        raise CsrfRejected
```

`CsrfRejected` is a 14th leaf in the taxonomy (... actually 15th — let me put it under `InvalidToken`'s sibling group as a separate one):

Adding to §6:
```python
class CsrfRejected(AuthServiceError):    ...   # 403  (origin missing or not in allowlist)
```

Updating §6 leaf count to **15**.

For non-browser clients (CLI, scripts) using `Authorization: Bearer <token>`, the Origin check is **skipped** (cookies are not used; CSRF is not applicable). Detection: `Authorization` header present AND no `auth_token` cookie.

### 8.3 Logout cookie clearing

`POST /api/auth/logout` returns:

```
Set-Cookie: auth_token=; Path=/; Max-Age=0
```

Plus revokes the session row (per §3.3).

---

## §9 Test matrix

Run via Vitest-equivalent (pytest); in-memory SQLite per test (`conftest.py` fixture).

### 9.1 Register

| scenario | input | expected | test_id |
|---|---|---|---|
| happy | valid email + 8+ char password + display name | 201 with user_id | `t_reg_happy` |
| invalid email | `"not-an-email"` | 400 `invalid_email` | `t_reg_invalid_email` |
| weak password | 7-char password | 400 `weak_password` | `t_reg_weak_password` |
| empty display name | `""` | 400 `invalid_display_name` | `t_reg_empty_name` |
| duplicate email (case insensitive) | existing email in different case | 409 `email_already_exists` | `t_reg_dup_email` |
| display_name with whitespace stripped | `"  John  "` | 201; stored as `"John"` | `t_reg_strip_name` |

### 9.2 Login

| scenario | input | expected | test_id |
|---|---|---|---|
| happy | valid creds | 200 with token + cookie + AuthUser | `t_login_happy` |
| unknown email | nonexistent email | 401 `authentication_failed` (no enumeration) | `t_login_unknown_email` |
| wrong password | valid email, bad password | 401 `authentication_failed` (same shape) | `t_login_bad_password` |
| deactivated user | `is_active=0` | 403 `user_deactivated` | `t_login_deactivated` |
| cookie attributes set | success | `Set-Cookie` includes `HttpOnly`, `SameSite=Lax`, correct `Max-Age` | `t_login_cookie_flags` |
| Secure flag (prod) | `config.secure_cookies=True` | cookie has `Secure` | `t_login_secure_in_prod` |

### 9.3 GET /me

| scenario | preconditions | expected | test_id |
|---|---|---|---|
| happy via cookie | logged in | 200 AuthUser with permissions sorted | `t_me_via_cookie` |
| happy via header | `Authorization: Bearer <token>` | 200 AuthUser | `t_me_via_header` |
| no token | no cookie / header | 401 `auth_required` | `t_me_no_token` |
| expired JWT | exp in past | 401 `session_expired` | `t_me_expired` |
| revoked session | session row `revoked_at` set | 401 `session_revoked` | `t_me_revoked` |
| invalid signature | tampered token | 401 `invalid_token` | `t_me_invalid_sig` |
| invalid issuer | jwt with wrong `iss` | 401 `invalid_token` | `t_me_invalid_iss` |
| user deactivated mid-session | `is_active` flipped to 0 | 403 `user_deactivated` | `t_me_user_deactivated_mid_session` |

### 9.4 Logout

| scenario | preconditions | expected | test_id |
|---|---|---|---|
| happy | logged in | 200 ok; cookie cleared; session revoked | `t_logout_happy` |
| double logout | already revoked | 200 ok (idempotent) | `t_logout_idempotent` |
| no token | no cookie / header | 401 `auth_required` | `t_logout_no_token` |

### 9.5 Change password

| scenario | input | expected | test_id |
|---|---|---|---|
| happy | correct current; valid new | 200; OTHER sessions revoked; current session active | `t_chpw_happy` |
| current mismatch | wrong current | 401 `authentication_failed` | `t_chpw_wrong_current` |
| weak new | new < 8 chars | 400 `weak_password` | `t_chpw_weak_new` |
| same as current | new == current | 200 ok (no validation against same; user choice) | `t_chpw_same` |

### 9.6 Admin: list users

| scenario | acting user | expected | test_id |
|---|---|---|---|
| happy as admin | has `platform:admin` | 200 with paged data | `t_admin_list_users_happy` |
| non-admin | lacks permission | 403 `permission_denied` | `t_admin_list_users_no_perm` |
| filter inactive | `?include_inactive=true` | response includes `is_active=0` rows | `t_admin_list_inactive` |
| paging | `?limit=2&offset=2` | next 2 entries | `t_admin_list_paging` |

### 9.7 Admin: grant / revoke permission

| scenario | input | expected | test_id |
|---|---|---|---|
| happy grant | valid user_id + known permission_code | 200 ok; row in user_permissions | `t_admin_grant_happy` |
| unknown permission_code | code not in known_permissions | 400 `unknown_permission` | `t_admin_grant_unknown_code` |
| user_id not found | nonexistent user | 404 `user_not_found` | `t_admin_grant_user_not_found` |
| already granted | re-grant same code | 409 `permission_already_granted` | `t_admin_grant_dup` |
| revoke happy | grant exists | 200 ok; row gone | `t_admin_revoke_happy` |
| revoke not granted | code not granted | 404 `permission_not_granted` | `t_admin_revoke_not_granted` |

### 9.8 Admin: register permission

| scenario | input | expected | test_id |
|---|---|---|---|
| happy register | new code + description | 200 ok | `t_admin_pregister_happy` |
| invalid format | `"WrongFormat"` | 400 `invalid_permission_format` | `t_admin_pregister_format` |
| same triple re-register | identical code/desc/by | 200 ok (no-op) | `t_admin_pregister_idempotent` |
| different description | same code, different description | 409 `permission_already_declared` (with extras) | `t_admin_pregister_redeclare` |
| via X-Internal-Bootstrap header | secret matches env | 200 ok without JWT | `t_admin_pregister_bootstrap` |
| bootstrap header secret mismatch | bad secret | 401 `auth_required` | `t_admin_pregister_bootstrap_bad` |

### 9.9 CSRF mitigation

| scenario | request | expected | test_id |
|---|---|---|---|
| same-origin POST with cookie | Origin matches allowlist | normal processing | `t_csrf_same_origin_ok` |
| cross-origin POST with cookie | Origin not in allowlist | 403 `csrf_rejected` | `t_csrf_cross_origin_blocked` |
| missing Origin on POST with cookie | no Origin / Referer header | 403 `csrf_rejected` | `t_csrf_missing_origin` |
| API client via Authorization header | Authorization present, no cookie | Origin check skipped | `t_csrf_api_client_skipped` |
| GET request | any Origin | Origin check skipped (read-safe) | `t_csrf_get_skipped` |

### 9.10 JWT details

| scenario | expected | test_id |
|---|---|---|
| happy issue + verify | round-trip | `t_jwt_roundtrip` |
| short secret refused at startup | secret < 32 bytes → process exits | `t_jwt_short_secret_startup` |
| verify with rotated secret | old token + new secret → invalid_token | `t_jwt_secret_rotation` |
| iss mismatch | token from different iss → invalid_token | `t_jwt_iss_mismatch` |

---

## §10 i18n (errors surfaced to UI)

Error codes are stable identifiers; UI maps them to localized strings via `packages/platform-shell/i18n/<lang>.json` under namespace `error.auth.*`. Suggested keys (frontend can override):

```json
{
  "error.auth.auth_required":            "Please sign in.",
  "error.auth.authentication_failed":    "Email or password is incorrect.",
  "error.auth.session_expired":          "Your session has expired. Please sign in again.",
  "error.auth.session_revoked":          "Your session was signed out elsewhere.",
  "error.auth.invalid_token":            "Invalid session. Please sign in again.",
  "error.auth.user_deactivated":         "Your account has been deactivated.",
  "error.auth.permission_denied":        "You don't have permission for that action.",
  "error.auth.email_already_exists":     "An account with that email already exists.",
  "error.auth.weak_password":            "Password must be at least 8 characters.",
  "error.auth.invalid_email":            "That doesn't look like a valid email.",
  "error.auth.csrf_rejected":            "Request rejected for security reasons. Reload and try again."
}
```

---

## §11 Configuration (env vars)

```python
# packages/auth-service/src/entelecheia_auth/config.py

class AuthSettings(BaseSettings):
    db_url:                       str           # SQLAlchemy URL; default sqlite:///./.product_data/auth.db
    jwt_secret:                   SecretStr     # required; ≥ 32 bytes; refused if shorter
    jwt_ttl_seconds:              int = 604800  # 7 days
    jwt_iss:                      str = "entelecheia-product/auth-service/v0.1"
    secure_cookies:               bool = True   # set False in dev; required True in prod
    allowed_origins:              list[str] = []  # CSRF allowlist; required non-empty in prod
    bootstrap_admin_email:        EmailStr | None = None
    bootstrap_admin_password:     SecretStr | None = None
    internal_bootstrap_secret:    SecretStr | None = None    # optional; enables /admin/permissions/register without JWT
    argon2_time_cost:             int = 2
    argon2_memory_cost_kib:       int = 65536
    argon2_parallelism:           int = 4

    class Config:
        env_prefix = "AUTH_"
        case_sensitive = False
```

**Startup checks** (run by `app.py` on init):
- `jwt_secret` ≥ 32 bytes → else `RuntimeError` and exit
- in prod (`secure_cookies=True`): `allowed_origins` non-empty → else `RuntimeError`
- DB migrations applied (Alembic head)

---

## §12 Why this design — load-bearing decisions

**Why JWT with `jti`-based revocation, not stateless tokens.**
Stateless JWT means logout is impossible without rotating secrets (which logs out everyone). Storing `sessions` and verifying `jti` on every request is a small DB lookup (indexed) that gives us per-session revocation, change-password-revokes-others, and admin-revoke-by-user. Single-process SQLite makes the lookup negligible.
*Considered and rejected.* **Stateless JWT with rotation** — operations nightmare; users get logged out on every secret rotation. **Opaque session cookies** (no JWT) — fine, but JWT lets non-browser clients (CLI) use the same auth without a separate flow.

**Why Argon2id over bcrypt.**
Memory-hard; resists ASIC cracking better than bcrypt; modern recommendation (OWASP). Cost: slightly heavier per-request. v0.1 traffic is low; cost is irrelevant.
*Considered and rejected.* **bcrypt** — older standard; perfectly fine, but argon2id is the explicit modern choice when starting fresh.

**Why permissions live in DB rows, not in JWT claims.**
Admin grants take effect immediately; no need to re-issue tokens. Token stays small. Costs one extra `SELECT permissions` per request — bundled into the same `require_auth` dep, executed once per request.
*Considered and rejected.* **Permissions in JWT claims** — admin grants don't take effect until next login; tokens grow large; revocation of a single permission requires token rotation.

**Why the `known_permissions` table + admin grant validation.**
Catches typos. An admin granting `platform:rune_meeting` (typo) should fail loudly, not silently grant a never-checked code. Cost: one extra row read per grant + the boot-time registration dance. Worth it.
*Considered and rejected.* **Free-form string permissions** — typos go unnoticed; documentation drifts.

**Why `X-Internal-Bootstrap` header instead of "first request bypasses auth".**
"First request bypasses" is racy + fragile (what if the apps/api process restarts mid-boot?). An explicit secret-gated bypass is auditable + idempotent. The secret is rotated at deploy time alongside `jwt_secret`.
*Considered and rejected.* **No-auth-needed if no admin exists** — leaves a window where any random caller can register permissions. **CLI-only registration** — couples spec to a tool; backend manifest registration would have to shell out.

**Why uniform `authentication_failed` for both unknown-email AND wrong-password.**
Email enumeration leak: `email_not_found` lets attackers verify which emails are registered. Uniform response is OWASP standard. Cost: helpful error message lost; users may try password reset when they should re-check email — that's the right tradeoff for an internal product.
*Considered and rejected.* **Differentiated errors** — leaks identity.

**Why cookie-first transport with header fallback.**
Browser clients (the common case): `httpOnly` cookie defends against XSS-stealing tokens. CLI / scripts: `Authorization: Bearer <token>` is the standard idiom and avoids cookie-jar complexity. Both are accepted; cookie wins when both present (browser canonical).
*Considered and rejected.* **localStorage + header only** — XSS readable. **Cookie only** — inconvenient for CLI tools.

**Why the same FastAPI process hosts auth-service (not a separate microservice).**
Single-tenant internal product; deployment simplicity. v0.2 can split if needed; the API contract here doesn't change.
*Considered and rejected.* **Separate microservice** — more processes, more secrets, no v0.1 benefit.

**Why no email verification in v0.1.**
Internal product; users come from a known set; admin can deactivate immediately if needed. v0.2 adds email + reset flow.
*Considered and rejected.* **Verification required** — blocks onboarding for an internal tool.

**Why 7-day JWT lifetime.**
Balances "users hate re-logging in" with "stolen token isn't useful for years". Refresh tokens (which would let us shorten the access token TTL to hours) are deferred to v0.2. Revocation via `jti` works any time.
*Considered and rejected.* **24-hour TTL** — daily re-login is annoying for an internal tool; without refresh tokens it's a clear UX regression.

---

## §13 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | `User` interface (§2.1) is the merged view of `AuthUser` (this spec §2.2) + `UserPreferences` (spec 04). `useUser()` composable performs the merge. The `User.permissions` field comes from this spec. |
| `04-user-service-spec.md` | Independent; user_id is the foreign-key reference into auth-service. user-service does NOT validate user_id existence (fail-soft); apps/api ensures both services are called with the same authenticated user_id. |
| `05`–`12` (every feature spec) | Each feature route uses `Depends(require_permission("..."))`; declares its required permissions in its spec; apps/api boot registers them via the boot dance (§5.3). |
| `13-vertical-template-spec.md` | Backend manifest's `permissions_declared: list[PermissionCode]` field; each declared permission is registered with auth-service at boot (per §5.3 step 4). |
| `15-apps-api-spec.md` | Hosts the auth-service router under `/api/auth/*`. Implements the boot dance. Provides `get_studio_client()` dependency separately. Implements bootstrap-admin seeding. |
| `16-apps-frontend-spec.md` | Implements the `useUser()` composable's merge (auth + prefs); handles 401 → redirect to /login; handles `csrf_rejected` → toast + reload prompt. |
| `17-substitution-tests-spec.md` | No `[SUB]` tests here (auth-service has no Pseudo↔Http distinction; one impl). E2E tests in `18` cover login → use API → logout flow. |

---

## §14 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope for v0.1 listed (refresh tokens, 2FA, email verify, password reset by email, rate limiting, multi-tenant, lockout, per-session permissions)
- [ ] Module layout (§1) enumerates every file
- [ ] SQLite schema (§2.1) has 4 tables with FKs + indexes; ULID format documented
- [ ] Pydantic models (§2.2) typed with constraints (regex, length, EmailStr); UserId / SessionId / PermissionCode / DisplayName / Password aliases declared
- [ ] All 8 user + admin endpoints (§3) have method + path + body + auth + status codes + error responses; admin endpoints declare `platform:admin` permission gate
- [ ] JWT format (§4) declares iss / sub / iat / exp / jti claims; HS256; verification flow steps numbered
- [ ] Permission model (§5): format regex, 6 platform built-ins, boot dance with apps/api, X-Internal-Bootstrap header
- [ ] Sealed error taxonomy (§6) with 15 leaves; HTTP statuses; per-error extras
- [ ] FastAPI dependencies (§7) signatures: `require_auth`, `require_permission(code)`, `require_any_permission(*codes)`, `require_admin`; CurrentAuthContext shape
- [ ] Cookie + CSRF (§8): default attributes, allowlist mechanism, header-fallback bypass
- [ ] Test matrix (§9): every endpoint + dep covered; 50+ rows total
- [ ] i18n keys (§10) for every error_type that surfaces to UI
- [ ] Config (§11): every env var declared with default + startup validation
- [ ] Why-this / why-not blocks (§12) for ≥ 8 load-bearing decisions
- [ ] Downstream impact (§13) lists every consumer spec
- [ ] No business / domain / product / agent-role string literals (uses neutral `<vertical_id>` placeholder)
- [ ] No `from entelecheia` / `import entelecheia` (engine)
- [ ] No `try: ... except Exception: pass` patterns shown anywhere
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/03-auth-service-spec.md`
