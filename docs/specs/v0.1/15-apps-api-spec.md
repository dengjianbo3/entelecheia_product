# 15 — `apps/api` v0.1 spec

> **Status**: v0.1 contract for the integrating FastAPI process.
> **Lives at**: `apps/api/`.
> **Consumes**: every Batch A–D spec (`01`/`01b`/`02`/`03`/`04`/`05`/`06`/`07`/`08`/`09`/`10`/`11`/`12`/`13`/`14`).
> **Forwarded to from**: `16-apps-frontend-spec.md` (the frontend talks here for everything except SSE which is also here as a proxy).

---

## Mission

This file defines `apps/api` — the single FastAPI process that mounts every router introduced by the platform features and verticals, runs the boot dance (vertical entry-point discovery + fixture overlay merge + permission registration), exposes the platform meta-endpoints (`/api/platform/verticals`, `/api/platform/feature-flags`), owns the small `meeting_metadata` table introduced by `05` §7 + `10` §6, configures the `StudioClient` (pseudo for v0.1, http for v0.2+), proxies the agora SSE stream, and applies cross-cutting middleware (CORS, rate limit, observability, auth, error envelope). It is the integration point where every spec from 03 through 14 becomes one runnable process.

**Hard rule** (P3 boundary at the integration layer): apps/api is **wiring**, not **logic**. Routers come from feature / vertical packages. Business logic comes from those packages or from studio (via studio-client). apps/api owns one small table (`meeting_metadata` — product-side input record), the boot dance, the middleware stack, and the meta-endpoints. Everything else is mounted, not authored.

---

## Scope

**Covers.**
- Module layout under `apps/api/`.
- The 11-step boot sequence (per `02` §10's frontend boot, mirrored on the backend with apps/api-specific steps).
- `StudioClient` instantiation (env-driven `STUDIO_MODE = pseudo | http`).
- Vertical entry-point discovery via `importlib.metadata.entry_points("entelecheia_product.verticals")`.
- Per-vertical fixture overlay merge dance (copies `packages/verticals/<id>/fixture_overlay/` into `packages/studio-client/fixtures/<overlay_name>/` at boot).
- Permission registry boot (auth-service + each vertical's `PERMISSIONS`).
- Report template registry boot (platform defaults + each vertical's `report_templates`).
- Router mount order: auth → user → meetings → reports → uploads → chathub → platform-meta → vertical routers.
- Owned endpoints: `/api/platform/verticals`, `/api/platform/feature-flags`, `/api/meetings/{id}/metadata` (POST + GET), `/api/meetings/{id}/materials` (GET), `/api/meetings/{id}/events` (SSE proxy), `/healthz`, `/readyz`, `/api/version`.
- The `meeting_metadata` SQLite table + its 1 model.
- Middleware stack: CORS, rate limit, request-id observability, auth dependency wiring, error envelope.
- agora_proxy: SSE passthrough from studio-client's `subscribe_meeting` AsyncIterator to a `text/event-stream` response.
- Health forwarding: `/healthz` reports both this process AND studio reachability; `/readyz` reports DB + studio.
- Configuration: every env var declared with default, secret, or required marker.
- Test matrix per boot step + per owned endpoint + per middleware.
- v0.2 forward-compat: studio_mode swap to `http`, additional middleware (auth-refresh, retry per `01` §9.5), feature flag SIGHUP reload.

**Does not cover.**
- Routers themselves — defined in `03` (auth) / `04` (user) / `06` (reports) / `08` (chathub) / `09` (uploads) / each vertical (data feeds + custom uploads).
- StudioClient Protocol / DTOs — `01`.
- Pseudo / Http studio client implementations — `01` §10 / §9.
- The frontend (Vite, Vue, Pinia) — `16-apps-frontend-spec.md`.
- Production deployment infrastructure (Docker, k8s, secrets management, TLS termination, reverse proxy).
- Database backups / disaster recovery.
- Multi-process / multi-host deployment. v0.1 is single-process.

**Out of scope for v0.1.**
- HTTP/2 + push.
- WebSocket endpoints (only SSE for streaming).
- Server-side rendering of any UI.
- Distributed tracing (OpenTelemetry export). v0.1 has structured logs + request_id only; v0.2 may add OTLP export.
- API versioning (no `/v2/` prefix). All routes under `/api/*` are v0.1 surface.
- Per-tenant config (single-tenant per `01` §1.5).
- Graceful shutdown coordination beyond FastAPI's standard.
- Auto-scaling / horizontal-scaling readiness. v0.1 ships one process.
- Encrypted-at-rest SQLite. v0.1 plaintext per `08` + `09` decisions.

---

## §1 Module layout

```
apps/api/
├── main.py                                # FastAPI app + lifespan startup/shutdown
├── config.py                              # AppApiSettings (every env var declared)
├── boot/
│   ├── __init__.py
│   ├── studio_client.py                   # build StudioClient based on STUDIO_MODE
│   ├── verticals.py                       # entry-point discovery + load + register
│   ├── fixture_overlay.py                 # merge per-vertical fixture_overlay/ into studio-client/fixtures/
│   ├── permissions.py                     # register platform + vertical permissions with auth-service
│   ├── report_templates.py                # register platform + vertical report templates
│   ├── migrations.py                      # run Alembic for all 5 SQLite DBs
│   └── observability.py                   # structured-log setup + Prometheus registry
├── platform/                              # platform meta-endpoints owned by this app
│   ├── __init__.py
│   ├── verticals.py                       # GET /api/platform/verticals
│   ├── feature_flags.py                   # GET /api/platform/feature-flags
│   └── version.py                         # GET /api/version
├── meetings/                              # the meeting_metadata table + agora SSE proxy
│   ├── __init__.py
│   ├── api.py                             # /api/meetings/* router
│   ├── agora_proxy.py                     # SSE passthrough
│   ├── models.py                          # MeetingMetadata pydantic
│   ├── db/
│   │   ├── tables.py                      # SQLAlchemy
│   │   └── crud.py
│   └── errors.py
├── health/
│   └── api.py                             # /healthz + /readyz
├── middleware/
│   ├── __init__.py                        # ordered middleware stack assembly
│   ├── cors.py
│   ├── rate_limit.py                      # in-memory token bucket
│   ├── request_id.py                      # observability: per-request UUID; goes into logs + response header
│   ├── error_envelope.py                  # uniform error JSON per 03 §6
│   └── auth.py                            # extract bearer; set request.state.user_id
├── alembic/                               # one shared env.py with multi-DB targets
│   ├── env.py
│   └── versions/
└── tests/
    ├── conftest.py
    ├── boot/
    ├── platform/
    ├── meetings/
    ├── middleware/
    └── e2e/                               # smoke-level boot-and-call tests
```

---

## §2 Configuration

```python
# apps/api/config.py
from typing import Literal
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class AppApiSettings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    # ── Studio ──────────────────────────────────────────────────────────
    studio_mode:        Literal["pseudo", "http"] = "pseudo"
    studio_base_url:    str | None = None                          # required when studio_mode == "http"
    studio_fixture_set: str = "default"                            # used when studio_mode == "pseudo"
    studio_token:       str | None = None                          # for v0.2; ignored in v0.1

    # ── Database URLs (per-service SQLite files) ─────────────────────────
    auth_db_url:        str = "sqlite:///./.product_data/auth.db"
    user_db_url:        str = "sqlite:///./.product_data/user.db"
    chathub_db_url:     str = "sqlite:///./.product_data/chathub.db"
    uploads_db_url:     str = "sqlite:///./.product_data/uploads.db"
    apps_api_db_url:    str = "sqlite:///./.product_data/apps_api.db"   # meeting_metadata table

    # ── Auth ────────────────────────────────────────────────────────────
    auth_jwt_secret:    str = Field(..., description="JWT signing secret; MUST be set in production")
    auth_jwt_algorithm: str = "HS256"

    # ── CORS ────────────────────────────────────────────────────────────
    cors_allowed_origins: list[str] = ["http://localhost:5173"]    # Vite dev server default
    cors_allow_credentials: bool = True

    # ── Rate limit ──────────────────────────────────────────────────────
    rate_limit_per_minute_anon:   int = 30                          # unauthenticated requests
    rate_limit_per_minute_user:   int = 600                         # per authenticated user

    # ── Observability ──────────────────────────────────────────────────
    log_level:               Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    log_format:              Literal["json", "text"] = "json"        # json for prod; text for local
    metrics_enabled:         bool = True

    # ── Feature flags ──────────────────────────────────────────────────
    feature_flags_path:      str | None = None                      # JSON file path; None = no flags

    # ── Uploads ────────────────────────────────────────────────────────
    uploads_base_dir:        str = "./.product_data/uploads"
    uploads_max_file_bytes:  int = 10 * 1024 * 1024
    uploads_user_quota_bytes: int = 1024 * 1024 * 1024

    # ── Chathub ────────────────────────────────────────────────────────
    chathub_messages_per_session_cap: int = 100
    chathub_turn_timeout_s:           int = 60

    class Config:
        env_prefix = ""    # no prefix; full envvar names match field names uppercased
```

**Required vs default**: only `auth_jwt_secret` is `Field(...)` — the only env var that has no safe default. Boot fails fast if not set.

---

## §3 Boot sequence (the 11 steps)

Mirrors `02` §10's frontend boot but is the backend's responsibility. Implemented via FastAPI's `lifespan` async context manager.

```python
# apps/api/main.py (sketch)
from contextlib import asynccontextmanager
from fastapi import FastAPI
from .config import AppApiSettings
from .boot import (
    studio_client as boot_studio,
    verticals as boot_verticals,
    fixture_overlay as boot_fixtures,
    permissions as boot_perms,
    report_templates as boot_templates,
    migrations as boot_migrations,
    observability as boot_obs,
)

@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = AppApiSettings()

    # 1. Observability + logging setup (so all subsequent steps log uniformly)
    boot_obs.setup_logging(settings)
    boot_obs.setup_metrics(settings)

    # 2. Run all 5 SQLite migrations (sequential; each db is independent)
    await boot_migrations.run_all(settings)

    # 3. Discover verticals via importlib.metadata.entry_points
    discovered = boot_verticals.discover()                          # returns list[VerticalEntryPoint]

    # 4. Validate each vertical's manifest (vertical_id format, key-mismatch, dups, etc.)
    valid_verticals = boot_verticals.validate(discovered)            # raises VerticalRegistrationError on hard failures

    # 5. Merge per-vertical fixture overlay into studio-client/fixtures/
    #    (so PseudoStudioClient sees them when instantiated next step)
    for v in valid_verticals:
        boot_fixtures.merge(v)

    # 6. Instantiate StudioClient per STUDIO_MODE
    studio = await boot_studio.build(settings)
    app.state.studio = studio

    # 7. Register platform-default permissions with auth-service
    await boot_perms.register_platform_defaults()

    # 8. Register each vertical's PERMISSIONS list
    for v in valid_verticals:
        await boot_perms.register_vertical(v)

    # 9. Register report templates: 2 platform defaults + each vertical's
    boot_templates.register_platform_defaults()
    for v in valid_verticals:
        boot_templates.register_vertical(v)

    # 10. Mount routers in order
    boot_verticals.mount_routers(app, valid_verticals)               # /api/verticals/<id>/*

    # 11. Final health check: studio is reachable
    health = await studio.get_studio_health()
    if not health.live:
        # Log warn but DON'T fail boot — studio may come up after us in development.
        # /readyz will report not_ready until it does.
        boot_obs.log.warning("studio not reachable at boot; /readyz will report not_ready")

    app.state.verticals = valid_verticals
    app.state.settings = settings

    yield

    # ── shutdown ──
    if hasattr(studio, "aclose"):
        await studio.aclose()
```

### 3.1 Step ordering invariants

| Step | Why this position |
|---|---|
| 1 logging | every later step's logs need format / level configured |
| 2 migrations | DB tables must exist before any router instantiates a CRUD helper |
| 3 vertical discovery | manifests needed for steps 5, 7, 8, 9, 10 |
| 4 manifest validation | catch malformed verticals before they pollute studio fixtures |
| 5 fixture overlay merge | MUST be before StudioClient instantiation (step 6) — pseudo loads fixtures at construction |
| 6 StudioClient build | needed for step 11; can't move earlier (depends on step 5 for pseudo mode) |
| 7-8 permission registration | platform defaults first so verticals can't accidentally clobber; vertical-prefixed permissions can't collide with platform per `13` §9 validation |
| 9 report template registration | order doesn't matter (templates keyed by template_id); placed here because verticals are now validated |
| 10 router mount | last so all dependencies are wired |
| 11 health probe | informational; doesn't gate boot |

### 3.2 Failure modes per step

| Step | Failure → boot behavior |
|---|---|
| 1 | logging misconfig → boot fails (FastAPI doesn't start; operator sees stderr) |
| 2 | migration fails → boot fails (don't start with stale schema) |
| 3 | discovery fails → boot fails (importlib error means workspace broken) |
| 4 | validation fails for vertical X → log error + skip X; continue with others (P5 isolation: a broken vertical doesn't kill the platform) |
| 5 | fixture merge fails for X → log warn + skip X's fixtures; vertical loads without overlay |
| 6 | studio_mode=pseudo + fixture parse error → boot fails (pseudo MUST be valid); studio_mode=http + base_url unreachable → boot WARN + start anyway, /readyz reports not_ready |
| 7 | platform permissions registration fails → boot fails (auth would be broken) |
| 8 | vertical permissions registration fails for X → log error + skip X's permissions (X loads but its perms are missing; UI gates → 403 → forced reauth hint) |
| 9 | template registration fails for X → log warn + skip X's templates |
| 10 | router mount conflict (route collision) → boot fails |
| 11 | health probe failure → log warn only |

---

## §4 `StudioClient` instantiation (per `01` §9 + §10)

```python
# apps/api/boot/studio_client.py
from entelecheia_studio_client import StudioClient
from entelecheia_studio_client.pseudo import PseudoStudioClient
from entelecheia_studio_client.http import HttpStudioClient, HttpStudioClientConfig

async def build(settings: AppApiSettings) -> StudioClient:
    if settings.studio_mode == "pseudo":
        return PseudoStudioClient(
            fixture_set=settings.studio_fixture_set,
            time_acceleration=1.0,
            random_seed=None,
        )
    elif settings.studio_mode == "http":
        if not settings.studio_base_url:
            raise ValueError("STUDIO_BASE_URL required when STUDIO_MODE=http")
        return HttpStudioClient(
            config=HttpStudioClientConfig(
                base_url=settings.studio_base_url,
                auth_token_provider=None,        # v0.2 wires auth-refresh layer
                request_timeout_s=30.0,
                stream_timeout_s=0.0,
                max_inflight_requests=32,
                sandwich_layers=[],              # v0.2 adds AuthRefreshLayer / RetryLayer / ObservabilityLayer
            )
        )
    else:
        raise ValueError(f"Unknown STUDIO_MODE: {settings.studio_mode}")
```

The instance is exposed app-wide via `app.state.studio` and consumed by every router's dependency:

```python
# Used by every backend router that touches studio
def get_studio(request: Request) -> StudioClient:
    return request.app.state.studio
```

---

## §5 Vertical discovery + registration

### 5.1 Discovery

```python
# apps/api/boot/verticals.py
from dataclasses import dataclass
from importlib.metadata import entry_points

@dataclass
class VerticalEntryPoint:
    entry_point_key: str        # the LHS of pyproject's [project.entry-points."..."]; MUST equal vertical_id
    module_path:     str        # the RHS, e.g. "entelecheia_vertical_investment.manifest:vertical_manifest"
    manifest:        VerticalManifest | None = None

def discover() -> list[VerticalEntryPoint]:
    eps = entry_points(group="entelecheia_product.verticals")
    return [VerticalEntryPoint(entry_point_key=ep.name, module_path=str(ep.value)) for ep in eps]
```

### 5.2 Validation

```python
def validate(eps: list[VerticalEntryPoint]) -> list[VerticalEntryPoint]:
    valid = []
    seen_ids: set[str] = set()
    for ep in eps:
        try:
            ep.manifest = ep.load_manifest()                                # importlib.import_module + getattr
            _check_id_format(ep.manifest.vertical_id)                        # ^[a-z][a-z0-9_-]*$
            _check_key_matches_id(ep.entry_point_key, ep.manifest.vertical_id)
            _check_unique(ep.manifest.vertical_id, seen_ids)
            _check_permissions_namespace(ep.manifest.permissions_declared, ep.manifest.vertical_id)
            _check_report_templates_namespace(ep.manifest.report_templates, ep.manifest.vertical_id)
            seen_ids.add(ep.manifest.vertical_id)
            valid.append(ep)
        except VerticalRegistrationError as e:
            log.error(f"Vertical '{ep.entry_point_key}' rejected: {e}")
            continue                                                          # P5: don't kill platform
    return valid
```

Validation failures raise `VerticalRegistrationError` (per `02` §3.2 — same type used by frontend `registerVertical`). Reasons: `entry_point_id_mismatch`, `invalid_format`, `duplicate_id`, `permission_namespace_violation`, `template_namespace_violation`.

### 5.3 Router mounting

```python
def mount_routers(app: FastAPI, verticals: list[VerticalEntryPoint]) -> None:
    for v in verticals:
        for router in v.manifest.api_routers:
            # Each vertical's routers MUST be prefixed with /api/verticals/<id>/
            # — verified at validation time. Log at INFO for ops visibility.
            app.include_router(router)
            log.info(f"Mounted {router.prefix} from vertical '{v.manifest.vertical_id}'")
```

**Route collision**: if two verticals contribute routers under the same prefix, FastAPI raises at mount time → boot fails. This is intentional — collisions are bugs.

---

## §6 Fixture overlay merge dance

Per `13` §8 + `14` §10, each vertical ships its own `fixture_overlay/` dir. At boot, apps/api copies these into `packages/studio-client/fixtures/<overlay_name>/` so PseudoStudioClient sees them when constructed in step 6.

```python
# apps/api/boot/fixture_overlay.py
from pathlib import Path
from shutil import copytree

STUDIO_FIXTURES_BASE = Path("packages/studio-client/fixtures")

def merge(v: VerticalEntryPoint) -> None:
    """Merge a vertical's fixture_overlay/ into studio-client/fixtures/<overlay>/.

    Strategy: per-file overwrite. Vertical's projects.yaml replaces (does
    NOT append to) the same-named file in studio-client/fixtures/<overlay>/.
    The OVERLAY directory itself is a SIBLING of fixtures/default/, so the
    vertical's projects/meeting_templates/outcomes only override the named
    overlay set, not the default set. PseudoStudioClient(fixture_set="<id>")
    loads default + this overlay merged, per 01 §10.2.
    """
    if not v.manifest.studio_fixture_overlay:
        return                                                                # vertical opted out
    overlay_name = v.manifest.studio_fixture_overlay
    src = Path(f"packages/verticals/{v.manifest.vertical_id}/fixture_overlay")
    if not src.exists():
        log.warning(f"Vertical '{v.manifest.vertical_id}' declares fixture_overlay='{overlay_name}' but src dir absent; skipping")
        return
    dst = STUDIO_FIXTURES_BASE / overlay_name
    dst.mkdir(parents=True, exist_ok=True)
    copytree(src, dst, dirs_exist_ok=True)
    log.info(f"Merged fixture overlay from vertical '{v.manifest.vertical_id}' into {dst}")
```

**Why copy (not symlink).** Symlinks break under some Windows + container deployments. Copy is dumb but reliable. `dirs_exist_ok=True` lets multiple boots be idempotent.

**Why post-boot writes don't matter.** Pseudo loads fixtures at construction (step 6); after step 6, fixture files are read-only as far as Pseudo is concerned. Any operator-side `cp` post-boot has no effect until process restart.

**Production note.** When `studio_mode="http"`, the merge dance is a no-op (HttpStudioClient doesn't load fixtures). The verticals' `fixture_overlay/` becomes dev/test-only data.

---

## §7 Permission registry boot

```python
# apps/api/boot/permissions.py
from entelecheia_auth.permissions import PERMISSION_REGISTRY

PLATFORM_DEFAULTS = [
    PermissionDeclaration(code="platform:list_projects",       description="List projects"),
    PermissionDeclaration(code="platform:list_meetings",       description="List meetings"),
    PermissionDeclaration(code="platform:run_meeting",         description="Start a meeting via wizard"),
    PermissionDeclaration(code="platform:render_report",       description="Render and download a report"),
    PermissionDeclaration(code="platform:upload",              description="Upload files"),
    PermissionDeclaration(code="platform:upload_list",         description="List own uploads"),
    PermissionDeclaration(code="platform:upload_delete",       description="Delete own uploads"),
    PermissionDeclaration(code="platform:chathub",             description="Use the chat feature"),
    PermissionDeclaration(code="platform:view_observability",  description="View dashboards"),
    # extends per features as defined in their respective specs
]

async def register_platform_defaults() -> None:
    for p in PLATFORM_DEFAULTS:
        await PERMISSION_REGISTRY.upsert(p)
    log.info(f"Registered {len(PLATFORM_DEFAULTS)} platform permissions")

async def register_vertical(v: VerticalEntryPoint) -> None:
    for p in v.manifest.permissions_declared:
        # Validation already ensured the prefix matches v.vertical_id (step 4);
        # registry upsert is idempotent so re-boot is safe.
        await PERMISSION_REGISTRY.upsert(p)
    log.info(f"Registered {len(v.manifest.permissions_declared)} permissions from vertical '{v.manifest.vertical_id}'")
```

The registry (provided by auth-service per `03` §5.3) is a process-local in-memory dict for v0.1; v0.2 may persist to auth-service's SQLite for cross-process consistency. Idempotent upsert means rebooting doesn't fail.

---

## §8 Owned endpoints

### 8.1 `GET /api/platform/verticals`

Returns the list of installed + valid verticals so the frontend can dynamic-import each.

```
GET /api/platform/verticals
  auth:   required (any authenticated user)
  200:    {
            available: list[{
              vertical_id:           str,
              display_name:          str,
              description:           str,
              icon:                  str,
              accent_color:          str | null,
              frontend_module_path:  str,            # for dynamic import in apps/frontend
              permissions:           list[str],       # the vertical's declared permission codes
              user_has_any_permission: bool,          # whether the current user has at least one perm in this vertical
            }]
          }
```

The `user_has_any_permission` field tells the frontend whether to surface the vertical in the switcher (per `02` §2.4 "verticals user has any permission for"). If false, the frontend hides the vertical UI but the vertical's routers still serve ASGI traffic for callers with explicit permission grants.

### 8.2 `GET /api/platform/feature-flags`

```
GET /api/platform/feature-flags
  auth:   required
  200:    { flags: { "<flag_name>": bool, ... } }
```

Loaded from `FEATURE_FLAGS_PATH` (a JSON file) at boot. v0.1 has no SIGHUP reload — flag changes require process restart. Used by `02` §2.8 `useFeatureFlag`.

### 8.3 `POST /api/meetings/{meeting_id}/metadata`

Called by wizard after `studio.run_meeting` succeeds; persists user-submitted material descriptors so agora's MaterialsPanel can render them later.

```
POST /api/meetings/{meeting_id}/metadata
  auth:    required + permission "platform:run_meeting"
  body:
    {
      project_id:       str,
      project_version:  int,
      user_id:          str,
      topic:            str,                       # 1..2000 chars (matches studio §3.6)
      materials: list[{
        upload_id:    str,                          # ULID; references uploads service
        name:         str,                          # display name
        kind:         "brief" | "data",             # studio_material_kind
        size_bytes:   int,
        preview_url:  str | None,                   # /api/uploads/<upload_id>/preview if previewable
      }]
    }
  201:    201 Created (no body)
  400:    InvalidArgument (validation failure)
  401/403: relayed
  409:    MeetingMetadataAlreadyExists (idempotent re-POST: same body → 201; different body → 409 with diff in extras)
  500:    InternalError
```

**Idempotency**: if a row exists for this `meeting_id` AND the new body is byte-equivalent (after pydantic-canonicalization), respond 201 unchanged. If the body differs, respond 409 with `extras: { conflict_field: "...", existing: ..., submitted: ... }`. v0.1 wizard does NOT retry on failure (per `10` §5.3 best-effort).

### 8.4 `GET /api/meetings/{meeting_id}/materials`

Consumed by agora's MaterialsPanel (per `05` §7).

```
GET /api/meetings/{meeting_id}/materials
  auth:   required + permission "platform:run_meeting"
  200:    list[MaterialDescriptor] (the same shape as the materials field in the metadata POST body, minus upload_id which is internal)
  401/403: relayed
  404:    MeetingMetadataNotFound (apps/api has no row; agora UI shows empty state)
```

### 8.5 `GET /api/meetings/{meeting_id}/events` (SSE proxy)

The agora live-event stream (per `05` §3 + `01` §7.8). apps/api proxies studio's SSE through to the browser.

```
GET /api/meetings/{meeting_id}/events
  Accept: text/event-stream
  Last-Event-Id: <int>            # optional; reconnect cursor
  auth:   required + permission "platform:run_meeting"
  200:    text/event-stream; per-event format:
            id: <event_id>
            event: <event_type>
            data: <json>

            (blank line)
          plus heartbeat lines `: keepalive` every 15s
          terminates with event_type=meeting_finalized OR meeting_failed
  401/403: relayed
  404:    MeetingNotFound (relayed from studio)
  502:    StudioUnavailable (couldn't establish stream)
```

See §9 for proxy implementation.

### 8.6 `GET /healthz`

```
GET /healthz
  auth:   not required
  200:    { status: "ok", studio_version: str | null, engine_version: str | null, api_contract: str | null }
  always returns 200 (the ASGI app is up); inner fields populated from
    last-known studio health (cached; refreshed every 30s in background).
```

### 8.7 `GET /readyz`

```
GET /readyz
  auth:   not required
  200:    { ready: true, components: { db: ok, studio_live: ok, studio_ready: ok } }
  503:    { ready: false, components: { ... } }   # any of {db, studio_live, studio_ready} false
```

Used by deployment infra; returns 200 only if everything is reachable.

### 8.8 `GET /api/version`

```
GET /api/version
  auth:   not required
  200:    {
            apps_api: str,        # this process's version
            studio_client: str,
            studio: str | null,    # from studio.get_studio_health (may be null if studio unreachable)
            engine: str | null,
            api_contract: str | null,   # e.g. "v0.1"; from studio
          }
```

---

## §9 agora SSE proxy

```python
# apps/api/meetings/agora_proxy.py
from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse
from entelecheia_studio_client import StudioClient
from entelecheia_studio_client.errors import StudioUnavailable, NotFound, StreamUnavailable

router = APIRouter()

@router.get("/api/meetings/{meeting_id}/events")
async def stream_meeting_events(
    meeting_id: str,
    request: Request,
    studio: StudioClient = Depends(get_studio),
    ctx: CurrentAuthContext = Depends(require_auth),
    _perm = Depends(require_permission("platform:run_meeting")),
):
    last_event_id = request.headers.get("Last-Event-Id")
    last_event_id_int = int(last_event_id) if last_event_id else None

    async def event_generator():
        try:
            async for event in studio.subscribe_meeting(
                meeting_id=meeting_id,
                last_event_id=last_event_id_int,
            ):
                # SSE wire format per 01 §6.1
                payload = json.dumps(event.data, separators=(",", ":"))
                yield f"id: {event.event_id}\nevent: {event.event_type}\ndata: {payload}\n\n"
                # The async iterator ends after meeting_finalized / meeting_failed
                # per 01 §7.8 termination rule; loop exits naturally.
        except NotFound:
            # Surface as a single error event then close
            yield f"event: meeting_failed\ndata: {{\"error\": {{\"type\": \"meeting_not_found\"}}}}\n\n"
        except StudioUnavailable:
            yield f"event: meeting_failed\ndata: {{\"error\": {{\"type\": \"studio_unavailable\"}}}}\n\n"
        except StreamUnavailable:
            yield f"event: meeting_failed\ndata: {{\"error\": {{\"type\": \"stream_unavailable\"}}}}\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",       # disable nginx buffering if behind one
        },
    )
```

**Heartbeats.** A separate background task (or interleaved in `event_generator`) yields `: keepalive\n\n` every 15 seconds to defeat idle-connection timeouts on intermediate proxies. The frontend's EventSource ignores keepalive lines per W3C SSE spec.

**Why proxy (not direct browser → studio).** (1) Single auth surface — the browser's session cookie / JWT goes to apps/api; apps/api uses its own studio token. (2) CORS — studio doesn't issue CORS headers for browsers. (3) Rate limiting can be applied uniformly. (4) The proxy can fall back gracefully when studio is unavailable, sending a shaped `meeting_failed` event rather than a bare connection error.

---

## §10 `meeting_metadata` table

The one SQLite table this app owns. Forward-declared by `05` §7 + extended by `09` §8 + `10` §6.

```sql
CREATE TABLE meeting_metadata (
    meeting_id        TEXT PRIMARY KEY,                               -- studio's 12-char hex
    project_id        TEXT NOT NULL,                                   -- studio spec_id
    project_version   INTEGER NOT NULL,
    user_id           TEXT NOT NULL,                                   -- product's user_id (no FK across services per 04 §10)
    topic             TEXT NOT NULL,
    materials         TEXT NOT NULL,                                   -- JSON list of MaterialDescriptor with upload_id
    created_at        TEXT NOT NULL                                    -- ISO-8601 UTC
);
CREATE INDEX idx_meeting_metadata_user ON meeting_metadata(user_id, created_at DESC);
CREATE INDEX idx_meeting_metadata_project ON meeting_metadata(project_id, created_at DESC);
```

**Why JSON-encoded materials**: small fixed-cardinality (≤ 20 materials per meeting in practice); always read together; normalizing into a join table costs more than it saves.

**Why no FK to studio meetings**: independent — apps/api has no shared DB with studio. Orphans (rows for meetings that never started or failed at studio side) tolerated; v0.1 has no GC.

---

## §11 Middleware stack

Order matters (FastAPI applies middleware in reverse order — last-added runs first on requests, first on responses):

```python
# apps/api/middleware/__init__.py (sketch)
def install_middleware(app: FastAPI, settings: AppApiSettings) -> None:
    # Outermost (request order): error envelope, then CORS, then request_id, then rate_limit, then auth.
    # FastAPI add_middleware runs in REVERSE; so add in inner-to-outer order:
    app.add_middleware(AuthMiddleware, settings=settings)            # innermost; sets request.state.user_id from Bearer
    app.add_middleware(RateLimitMiddleware, settings=settings)       # uses request.state.user_id when available
    app.add_middleware(RequestIdMiddleware, settings=settings)       # adds X-Request-Id header + log binding
    app.add_middleware(CORSMiddleware, allow_origins=settings.cors_allowed_origins,
                       allow_credentials=settings.cors_allow_credentials,
                       allow_methods=["*"], allow_headers=["*"])
    app.add_middleware(ErrorEnvelopeMiddleware)                      # outermost; wraps any exception → uniform JSON
```

### 11.1 ErrorEnvelopeMiddleware

Catches any unhandled exception + any subclass of the studio-client / auth-service / vertical taxonomies; emits the uniform error JSON per `03` §6:

```json
{ "error": { "type": "<error_type>", "message": "...", "extras": {...} } }
```

If the exception is unrecognized: log full traceback at ERROR level, return 500 `InternalError` with `extras.trace_id` for support correlation.

### 11.2 CORS

`fastapi.middleware.cors.CORSMiddleware` with `allow_origins` from config. Defaults to `["http://localhost:5173"]` for dev. Production overrides via env var.

### 11.3 RequestIdMiddleware

Generates UUID4 per request; attaches to `request.state.request_id`; adds `X-Request-Id` to response; binds to logger context so all logs from this request thread carry the ID. Critical for support — every error envelope's `extras.trace_id` matches a log search.

### 11.4 RateLimitMiddleware

In-memory token-bucket; two buckets per identity:
- Anonymous (by IP): 30 requests/min default
- Authenticated (by user_id): 600 requests/min default

Exhausted → 429 `RateLimited` with `Retry-After` header. Bucket state is process-local; v0.2 may move to Redis for multi-process consistency.

Exempt paths: `/healthz`, `/readyz`, `/api/version` (operator probes; rate-limiting them defeats their purpose).

### 11.5 AuthMiddleware

Extracts `Authorization: Bearer <token>` header; calls `auth-service.verify_jwt(token)`; on success sets `request.state.user_id` + `request.state.permissions`. On failure: sets nothing (the per-endpoint `Depends(require_auth)` will raise 401 for protected routes; unprotected routes like `/healthz` still work).

---

## §12 Test matrix

### 12.1 Boot sequence

| scenario | expected | test_id |
|---|---|---|
| happy boot | all 11 steps complete; app starts | `t_boot_happy` |
| missing JWT secret | step 0 (settings) fails fast | `t_boot_missing_jwt_secret` |
| migration fails | step 2 fails; app does not start | `t_boot_migration_fail` |
| no verticals discovered | steps 4-9 skip vertical work; platform-only routes mounted | `t_boot_no_verticals` |
| 1 vertical loads | mounted at /api/verticals/<id>/*; perms registered; templates registered | `t_boot_one_vertical` |
| 2 verticals load | both mounted; no collision | `t_boot_two_verticals` |
| Vertical with malformed manifest | logged + skipped; other verticals + platform unaffected (P5 isolation) | `t_boot_one_malformed` |
| Vertical with missing fixture overlay dir | warned + skipped; vertical loads anyway | `t_boot_missing_fixtures` |
| Studio unreachable at boot (mode=http) | warned + boot completes; /readyz returns 503 until studio comes up | `t_boot_studio_unreachable_http` |
| Studio fixtures invalid (mode=pseudo) | step 6 fails; boot fails (pseudo MUST be valid per 01 §10.5 invariants) | `t_boot_pseudo_fixture_invalid` |
| Route prefix collision between two verticals | step 10 fails; boot fails | `t_boot_route_collision` |

### 12.2 Endpoints

| endpoint | scenario | expected | test_id |
|---|---|---|---|
| GET /api/platform/verticals | happy | list with available verticals + per-vertical user_has_any_permission flag | `t_ep_verticals_list` |
| GET /api/platform/verticals | 0 verticals installed | `available: []` | `t_ep_verticals_empty` |
| GET /api/platform/feature-flags | path set | flags returned | `t_ep_flags_loaded` |
| GET /api/platform/feature-flags | path unset | `flags: {}` | `t_ep_flags_empty` |
| POST /api/meetings/:id/metadata | happy | 201 | `t_ep_meta_post_happy` |
| POST /api/meetings/:id/metadata | invalid topic length | 400 | `t_ep_meta_post_invalid` |
| POST /api/meetings/:id/metadata | duplicate identical body | 201 (idempotent) | `t_ep_meta_post_idempotent` |
| POST /api/meetings/:id/metadata | duplicate different body | 409 with diff in extras | `t_ep_meta_post_conflict` |
| GET /api/meetings/:id/materials | row exists | list returned | `t_ep_materials_get_happy` |
| GET /api/meetings/:id/materials | no row | 404 | `t_ep_materials_get_404` |
| GET /api/meetings/:id/events | live meeting | SSE stream with events; ends on meeting_finalized | `[SUB] t_ep_sse_live` |
| GET /api/meetings/:id/events | with Last-Event-Id | resumes from cursor | `[SUB] t_ep_sse_reconnect` |
| GET /api/meetings/:id/events | meeting not found | yields meeting_failed event then closes | `t_ep_sse_not_found` |
| GET /api/meetings/:id/events | studio unavailable | yields meeting_failed event then closes | `t_ep_sse_studio_down` |
| GET /healthz | always | 200 with last-known studio info | `t_ep_healthz` |
| GET /readyz | all components ok | 200 | `t_ep_readyz_ok` |
| GET /readyz | studio unreachable | 503 | `t_ep_readyz_studio_down` |
| GET /readyz | DB unreachable | 503 | `t_ep_readyz_db_down` |
| GET /api/version | happy | full version dict | `t_ep_version` |

### 12.3 Middleware

| middleware | scenario | expected | test_id |
|---|---|---|---|
| ErrorEnvelope | unrecognized exception | 500 with InternalError + trace_id | `t_mw_error_unknown` |
| ErrorEnvelope | StudioUnavailable raised | 502 with proper envelope | `t_mw_error_studio_unavailable` |
| ErrorEnvelope | trace_id matches log | request log has same trace_id | `t_mw_error_trace_id` |
| CORS | allowed origin | preflight passes | `t_mw_cors_allowed` |
| CORS | disallowed origin | preflight fails | `t_mw_cors_blocked` |
| RequestId | response header set | X-Request-Id matches log | `t_mw_request_id_in_header` |
| RateLimit anon | 31st req in a minute | 429 with Retry-After | `t_mw_rate_anon_exceeded` |
| RateLimit user | 601st req for user | 429 | `t_mw_rate_user_exceeded` |
| RateLimit exempt | /healthz called 100 times | always 200 | `t_mw_rate_healthz_exempt` |
| Auth | missing bearer on protected | 401 | `t_mw_auth_missing` |
| Auth | invalid bearer on protected | 401 | `t_mw_auth_invalid` |
| Auth | valid bearer | request.state.user_id set; route runs | `t_mw_auth_valid` |
| Auth | unprotected route + missing bearer | route runs (no 401) | `t_mw_auth_optional_passes` |

### 12.4 StudioClient swap

| scenario | expected | test_id |
|---|---|---|
| STUDIO_MODE=pseudo at boot | PseudoStudioClient instantiated | `[SUB] t_studio_swap_pseudo` |
| STUDIO_MODE=http at boot, base_url set | HttpStudioClient constructed (or raises NotImplementedError per 01 §9 v0.1 stub) | `[SUB] t_studio_swap_http_v01_stub` |
| STUDIO_MODE=http, base_url missing | boot fails with clear error | `t_studio_swap_http_no_url` |
| STUDIO_MODE=invalid | boot fails | `t_studio_swap_unknown` |

---

## §13 Why this design — load-bearing decisions

**Why a single `apps/api` process (not microservices).**
v0.1 is single-tenant + internal product; deployment simplicity outweighs scale flexibility. Every "service" (auth, user, chathub, uploads) is a Python sub-package mounted under one ASGI app with its own SQLite file. v0.2 may extract heavy ones (auth's password hashing) into separate processes if needed — the per-package modular design makes this a refactor, not a rewrite.
*Considered and rejected.* **Microservices from day 1** — infrastructure burden + cross-process auth coordination too high for v0.1 scale.

**Why per-service SQLite (not one shared DB).**
Independent migrations: auth-service's schema can evolve without coordinating with chathub. Independent blast radius: a bug in uploads can't corrupt auth tokens. Independent file → easy operator backup of just one service. Cost: no cross-service FK (acknowledged in `04` §10 + `08` + `09`).
*Considered and rejected.* **One DB with separate schemas** — couples migrations; harder operator story.

**Why fixture overlay merge happens at boot (not runtime / not lazy).**
Pseudo loads fixtures at construction. Boot-time merge lets pseudo see all verticals' fixtures from the moment it's instantiated. Lazy / runtime merging would require pseudo to re-parse fixtures on every project list call — wasteful + introduces ordering bugs.
*Considered and rejected.* **Lazy merge on first use** — re-parsing cost; unpredictable ordering. **Symlink instead of copy** — Windows / container compat issues.

**Why entry-point discovery (not config file).**
Standard Python plugin mechanism. Installing `entelecheia-vertical-X` via pip auto-registers the entry point; no config file edit needed. Same as how pytest plugins work.
*Considered and rejected.* **YAML config listing verticals** — duplicate source of truth (also in pyproject); has to be manually edited per install.

**Why agora_proxy lives in apps/api (not platform-features/agora/backend).**
Per `05` §1 "agora has zero backend code in this package." The proxy is product-API infrastructure — translating SSE between studio and the browser. Putting it in agora's package would violate the "agora is a frontend feature" framing.
*Considered and rejected.* **proxy in agora package** — violates 05's hard rule.

**Why all middleware (CORS / rate / observability / auth / error envelope) at apps/api level.**
Cross-cutting concerns. Per-router would mean every router defines them, and they'd drift. Centralized middleware applies uniformly + is configured once.
*Considered and rejected.* **Per-router middleware** — drift; inconsistent.

**Why ErrorEnvelopeMiddleware is the OUTERMOST.**
Catches everything including failures in inner middleware (e.g., rate-limit logic crashes). Without it, a rare middleware bug would surface as bare 500 with no envelope, breaking frontend's error parsing.
*Considered and rejected.* **Inner error envelope** — leaks stack traces on middleware failures.

**Why /healthz returns 200 even when studio is down.**
The ASGI app is up — healthz reflects "the process is running." /readyz reflects "the process can serve traffic" (which requires studio + DB). This separation matches Kubernetes' liveness vs readiness convention; our deployment story will use it.
*Considered and rejected.* **healthz includes studio** — load balancer might restart the process when studio (an external dependency) hiccups.

**Why feature flags via JSON file (not env vars / not DB).**
JSON file is editable + version-controllable + diffable. Env vars don't structure well for nested flags. DB-backed flags require a UI + migration story, premature for v0.1's scale (≤ 10 flags expected).
*Considered and rejected.* **DB-backed flags** — over-engineering. **Env vars** — flat, ugly for nested flags.

**Why no SIGHUP reload of feature flags in v0.1.**
Process restart is cheap (tens of seconds) and v0.1 is single-process; flag changes are infrequent and operator-driven. SIGHUP wiring + reload-during-active-requests safety is non-trivial for marginal benefit.
*Considered and rejected.* **SIGHUP-reload** — complexity vs benefit at v0.1 scale.

---

## §14 Downstream impact

| Spec | Adjustment |
|---|---|
| `01-studio-client-spec.md` | StudioClient consumed unchanged. agora_proxy translates per `01` §6.4 SSE format. v0.2 HttpStudioClient stub honored. |
| `02-platform-shell-spec.md` | `GET /api/platform/verticals` + `GET /api/platform/feature-flags` shapes match `02` §10 boot sequence consumption. |
| `03-auth-service-spec.md` | Auth router mounted under `/api/auth/*`; permission registry consumed. |
| `04-user-service-spec.md` | User router mounted under `/api/user/*`. |
| `05-feature-agora-spec.md` | Materials endpoint + agora_proxy SSE both honored. `meeting_metadata` table populated by wizard. |
| `06-feature-reports-spec.md` | Reports router mounted under `/api/reports/*`; report templates registry boot per §9 of this spec. |
| `08-feature-chathub-spec.md` | Chathub router mounted under `/api/chathub/*`. |
| `09-feature-uploads-spec.md` | Uploads router mounted under `/api/uploads/*`. |
| `10-feature-wizard-spec.md` | `POST /api/meetings/:id/metadata` is wizard's phase-3 target. |
| `13-vertical-template-spec.md` | The validation rules in `13` §9 are enforced here in the boot validation step. |
| Spec 14 (first concrete vertical) | The vertical's routers + permissions + report templates + fixture overlay all wired through this spec's boot dance. Adding additional verticals later requires no apps/api change — the boot dance enumerates entry points. |
| `16-apps-frontend-spec.md` | The frontend's boot sequence (per `02` §10) calls the meta-endpoints defined here. CORS allowed origins must include the dev + prod frontend hosts. |
| `17-substitution-tests-spec.md` | The 5 `[SUB]` test_ids in §12 join 17's substitution suite (StudioClient swap + SSE proxy parity). |

---

## §15 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (HTTP/2, WebSocket, SSR, distributed tracing, API versioning, multi-tenant, multi-process)
- [ ] Module layout (§1) covers main + config + boot + platform meta + meetings + health + middleware + alembic
- [ ] Configuration (§2): every env var declared with default or `Field(...)` for required; jwt_secret is the only required one
- [ ] 11-step boot sequence (§3) with order rationale (§3.1) + per-step failure mode (§3.2)
- [ ] StudioClient instantiation (§4) handles pseudo + http modes + error cases
- [ ] Vertical discovery (§5.1) + validation (§5.2) + router mount (§5.3) — per-vertical isolation on validation failure (P5)
- [ ] Fixture overlay merge (§6) per-file overwrite + idempotent + copy-not-symlink
- [ ] Permission registry boot (§7) — platform defaults first, vertical perms second; idempotent upsert
- [ ] All 8 owned endpoints (§8) with full method + path + body + auth + status + error mapping
- [ ] agora_proxy (§9) yields SSE per `01` §6.1 wire format; heartbeats every 15s; graceful failure events
- [ ] meeting_metadata table (§10) with FK-free design + indexes
- [ ] Middleware stack (§11) with order rationale; ErrorEnvelope outermost; healthz/readyz exempt from rate limit
- [ ] Test matrix (§12): boot (~11 rows), endpoints (~17 rows), middleware (~13 rows), studio swap (~4 rows); ≥ 40 rows total
- [ ] Why-this / why-not (§13) for ≥ 8 load-bearing decisions
- [ ] Downstream impact (§14) lists every spec affected
- [ ] No business / domain / product / agent-role string literals (uses neutral examples)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No agent / paradigm / skill / model logic in apps/api (Red Line #5)
- [ ] No direct studio HTTP calls outside of HttpStudioClient (Red Line #2)
- [ ] No vertical's logic in apps/api beyond mounting + boot dance
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/15-apps-api-spec.md`
