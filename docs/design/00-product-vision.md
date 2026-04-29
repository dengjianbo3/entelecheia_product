# Product Vision (canonical)

> **What this document is.** The complete, canonical statement of what entelecheia-product is, what it does, and how it is structured. Written 2026-04-29. This is the document a fresh implementer reads to fully understand the project.

---

## 0. One-line definition

**entelecheia-product is the user-facing application layer of the Entelecheia three-project stack.** It serves multiple verticals from one mother-ship platform, talks to studio for all backend logic, and never sees engine. Vertical packs add UI/data-feed specialization for specific business domains (investment, policy, legal) without modifying platform code.

---

## 1. Goals (what v1.0 must deliver)

1. **One platform, many verticals.** Investment users, policy users, legal users (etc.) share the same shell + features but get vertical-specific tabs / widgets / external data feeds.
2. **Verticals plug in via manifest.** Adding a vertical = drop a directory + manifest. No platform code changes. No engineer-only steps for typical configuration changes.
3. **Studio is the only backend logic.** Product never imports engine. Product talks to studio via the `StudioClient` Protocol. The contract is a single Python module + its TypeScript mirror.
4. **Pseudo first, real later.** Product develops independently against `PseudoStudioClient` returning mock data. When studio v0.1 ships, swap to `HttpStudioClient`. UI code unchanged.
5. **Internal-ops first.** Single-tenant. Customer-facing SaaS is not v1.0 scope (matches studio).
6. **First vertical proves the pattern.** `investment` vertical demonstrates tab + widget + upload handler + data-feed proxy patterns end-to-end.

---

## 2. Audience

| Audience | Primary tool (v0.1) | Primary tool (v0.2+) |
|---|---|---|
| **Engineers** | CLI + spec YAML + Vue + Python | + studio API + observability dashboards |
| **Product managers** | (proxy through engineers) | Web UI for vertical configuration |
| **End users** | (use products built on the platform; not direct platform users) | Same |

---

## 3. The mother-ship architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  entelecheia-product                                              │
│                                                                   │
│  ┌─ Platform Shell (always present) ────────────────────────┐    │
│  │ Auth · Navigation · Multi-vertical switcher · Theme ·    │    │
│  │ i18n · Routing · Layout · Notifications                  │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                   │
│  ┌─ Platform Features (always present, vertical-agnostic) ───┐    │
│  │ • agora (deliberation discussion UI)                     │    │
│  │ • reports (browser + multi-format exports)               │    │
│  │ • knowledge (knowledge tree browser)                     │    │
│  │ • chathub (generic expert chat)                          │    │
│  │ • uploads (file upload + generic PDF parsing)            │    │
│  │ • wizard (onboarding)                                    │    │
│  │ • settings (user preferences)                            │    │
│  │ • observability (cost / latency dashboards)              │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                   │
│  ┌─ Vertical Packs (pluggable; UI / data-feed customization) ┐    │
│  │ ┌─ investment ──────┐ ┌─ policy (future) ─┐ ┌─ legal ──┐│    │
│  │ │ • 行情 tab         │ │ • 舆情监控        │ │ • 判例时间线 ││    │
│  │ │ • 持仓 widget     │ │ • 法规对比表      │ │ • 卷宗导航  ││    │
│  │ │ • 财报上传 + 解析 │ │ • 政策追踪        │ │ • 案件管理  ││    │
│  │ │ • 市场数据 proxy  │ │                   │ │             ││    │
│  │ └───────────────────┘ └───────────────────┘ └────────────┘│    │
│  └──────────────────────────────────────────────────────────┘    │
│                              ↓ (only contract)                   │
│             StudioClient (v0.1: PseudoStudioClient)              │
└──────────────────────────────────────────────────────────────────┘
                              ↓ HTTP/WS (v0.2+)
                          Studio API
                              ↓
                        Engine (transitively)
```

---

## 4. The 5 conceptual layers within product

### 4.1 Platform Shell

The persistent UX scaffold. Every page renders inside this shell. Every user sees auth → vertical switcher → navigation → theme → settings access. The shell is small (~10 components) and stable.

Subsystems:
- **Auth**: login / logout / token refresh; talks to `auth_service` microservice
- **Multi-vertical switcher**: dropdown in nav showing the user's accessible verticals (filtered by permissions); switching changes the active vertical's tabs/widgets but keeps the same user session
- **Navigation**: top nav + side nav; tabs from active vertical's manifest are appended to nav
- **Theme**: light/dark; user preference from `user_service`
- **i18n**: zh + en at minimum; pulled from each feature/vertical's i18n bundle
- **Notifications**: toast + persistent notification center
- **Settings**: per-user preferences (default vertical, language, theme, default LLM dropdown for agora)

### 4.2 Platform Features

Vertical-agnostic features used by every vertical. Built against `studio-client` Protocol. Each lives in its own `packages/platform-features/<name>/` directory.

#### agora (the centerpiece)

The deliberation discussion UI. When a user starts a meeting:

1. User picks a project (filtered by current vertical's `default_project_filter`)
2. User provides topic + materials (uploads or text)
3. Frontend calls `studio_client.run_meeting(project_id, topic, materials)`
4. Frontend subscribes to `studio_client.subscribe_meeting(meeting_id)` for live events
5. UI renders: live message stream (per-agent threading), evidence sidebar (citations), DAG visualization (if user toggles), conclude state ("running" → "concluded")
6. When concluded: outcome panel showing facts/consensus/disagreements/open-questions, cost summary, "view DAG" button, "export report" button

agora is the most complex platform feature; everything else exists to support it.

#### reports

Browse meeting outcomes; click any outcome → see full report; export to PDF / Word / Excel via studio's outcome render API.

#### knowledge

Visualize knowledge trees (cross-meeting cumulative). Read-only view of studio's knowledge tree projection. Click a tree node → see source claims + meetings that contributed.

#### chathub

Generic expert chat (single-agent) — separate from agora's multi-agent. Useful for "ask one expert" flows. Talks to `studio_client.chat_with_agent(agent_id, ...)`.

#### uploads

File upload UI. Generic PDF parsing built in. Custom parsers (e.g., financial-report parser, BP parser) come from verticals.

#### wizard

First-time-user onboarding: pick vertical, set preferences, do a sample meeting.

#### settings

User preferences UI. Reads/writes via `user_service`.

#### observability

Cost dashboards (this user, this vertical, this project, this period); latency p50/p95; error rates. Reads from `studio_client.get_cost_aggregate(...)` and `studio_client.get_meeting_metrics(...)`.

### 4.3 Vertical Packs

Each vertical is a `packages/verticals/<id>/` directory with:

- `manifest.ts` (frontend) declaring tabs / widgets / upload handlers / data feeds / default project filter / i18n
- `manifest.py` (backend, registered as Python entry point) declaring the FastAPI router this vertical contributes
- Frontend Vue components for the tabs / widgets / handlers
- Backend FastAPI router for vertical-specific data-feed proxies

A vertical pack contributes only via these declarations. It cannot modify platform-shell or platform-features. See [`03-vertical-pack-model.md`](03-vertical-pack-model.md) for the full manifest schema.

### 4.4 studio-client SDK

`packages/studio-client/` defines:

- `StudioClient` Protocol (~15 methods)
- `PseudoStudioClient` (returns mock data — for v0.1 development)
- Future: `HttpStudioClient` (real HTTP/WS — v0.2+)

All of platform-features and vertical-packs depend on `StudioClient` Protocol only. They never know which implementation is active. This means swapping pseudo→real is a one-config change.

See [`02-studio-integration.md`](02-studio-integration.md) for the Protocol details.

### 4.5 Microservices

- **auth_service**: JWT issuance + verification. Survived from upstream codebase, kept as-is.
- **user_service**: User preferences (default vertical, theme, language, default LLM dropdown). Survived from upstream codebase.

These are independent FastAPI services that the main `apps/api/` calls.

---

## 5. The 5 invariants

These are non-negotiable structural properties of the product. CI enforces what it can; reviewer judgment covers the rest.

### Invariant 1 — Product never imports engine

`from entelecheia import …` does not appear anywhere in `packages/`, `apps/`, or `verticals/`. The engine package is not even a runtime dependency. (Studio is.)

### Invariant 2 — All studio access via studio-client

No package outside `packages/studio-client/` makes raw HTTP calls to studio. Everything flows through `StudioClient` Protocol.

### Invariant 3 — Verticals do not modify platform code

A vertical's directory may add to itself (`packages/verticals/<id>/`) but cannot edit `packages/platform-shell/` or `packages/platform-features/*`. CI checks that no PR touches both a vertical directory AND a platform directory in the same change without explicit reviewer override.

### Invariant 4 — Verticals do not import each other

`packages/verticals/investment/` cannot `from packages.verticals.policy import …`. Cross-vertical functionality belongs in platform features.

### Invariant 5 — No agent / paradigm / skill / model logic anywhere

Zero LLM clients, zero paradigm code, zero agent base classes, zero skill bundle loading code. All such concerns are on the studio side of the studio-client boundary. Product calls studio; product does not embed studio.

---

## 6. Pseudo studio-client

`packages/studio-client/` is the central abstraction. It hides whether the studio is real or mocked from every consumer.

### v0.1 — `PseudoStudioClient`

```python
class PseudoStudioClient(StudioClient):
    """Returns realistic mock data so the entire product UI can develop
    without studio existing. Mock data lives in fixtures; consumers see
    the same Protocol regardless."""

    async def list_available_projects(self, user_id: str, vertical_id: str | None = None):
        return _MOCK_PROJECTS_BY_VERTICAL.get(vertical_id, [])

    async def run_meeting(self, project_id: str, topic: str, materials: list[Material]):
        # Generate a fake MeetingHandle; spawn a background coroutine that
        # emits mock events on subscribe_meeting; return MeetingHandle.
        ...

    async def subscribe_meeting(self, meeting_id: str):
        # Yield mock events at realistic intervals
        ...

    # ... ~15 methods, all backed by mock fixtures
```

Mock data lives in `packages/studio-client/fixtures/` as YAML / JSON. Editing fixtures is the way to test new UI states.

### v0.2 — `HttpStudioClient`

```python
class HttpStudioClient(StudioClient):
    """Real HTTP/WebSocket client. Drop-in replacement for PseudoStudioClient."""
    def __init__(self, base_url: str, token: str, timeout: float = 30.0): ...

    # ... real HTTP/WS implementations
```

If studio's actual API doesn't match the Protocol exactly, **the translation layer goes inside `HttpStudioClient`** (or a thin adapter sandwiched in `packages/studio-client/`). UI code stays unchanged.

This swap is the single highest-leverage abstraction in the product. See [`02-studio-integration.md`](02-studio-integration.md).

---

## 7. Lifecycle: a meeting, end-to-end

To make the architecture concrete, here's what happens when a user starts a meeting in agora:

```
1. User clicks "Start meeting" in agora UI
2. Frontend (Vue):
   - Calls studio_client.list_available_projects(user_id, vertical_id)
   - Renders project picker with returned list
3. User picks "investment-equity-research-v1" + provides topic + uploads files
4. Frontend uploads files via uploads platform feature → returns Material[]
5. Frontend calls studio_client.run_meeting(project_id, topic, materials)
   - PseudoStudioClient: spawns mock event stream, returns MeetingHandle
   - HttpStudioClient (v0.2+): POSTs to studio /api/projects/run, returns MeetingHandle
6. Frontend opens WebSocket via studio_client.subscribe_meeting(meeting_id)
7. As events stream:
   - MessageEmitted → render in message panel
   - EvidenceCited → add to evidence sidebar
   - ClaimMade → add to claim graph view
   - StageAdvanced → update progress bar
   - MeetingFrozen → stop streaming, show outcome panel
8. After conclude:
   - Frontend calls studio_client.get_meeting_outcome(meeting_id)
   - Renders facts / consensus / disagreements / open questions
   - User can: view DAG (studio_client.get_dag_view), see provenance
     (studio_client.get_provenance), or export report (reports feature)
9. Cost/latency aggregate available via studio_client.get_cost_aggregate
   (rendered in observability dashboard, not blocking the meeting flow)
```

The product handles UI orchestration. Studio handles agent orchestration. Engine handles deliberation. Three layers, one user-visible flow.

---

## 8. Phasing

| Version | Adds | "Done when..." | Effort |
|---|---|---|---|
| **v0.1** | Day 0 scaffolding done; pseudo studio-client returning realistic mocks; agora + reports + knowledge + uploads + wizard + settings basic flows; first investment vertical with 行情 tab + 持仓 widget + 财报 upload | "user logs in, picks investment, starts a mock meeting, sees mock events stream in agora, reads mock outcome" | 6-8 weeks |
| **v0.2** | Switch to HttpStudioClient (after studio v0.1 ships); translation layer added if needed; real meeting end-to-end via studio + engine | "real meeting from product → studio → engine → outcome rendered in product UI" | +2 weeks |
| **v0.3** | observability dashboards (cost/latency); minimal admin UI for vertical config; production deployment | "PMs see daily cost dashboard; ops can deploy" | +2 weeks |
| **v0.4** | Second vertical (policy or legal) demonstrates plug-in pattern at scale | "two verticals coexisting; switching between them works seamlessly" | +2 weeks |
| **v1.0** | Production-stable for 7+ days; first real users on investment vertical | first vertical in production | +2 weeks |

Total to v1.0: ~14-16 weeks of focused work.

---

## 9. Migration from upstream codebase

Upstream Magellan codebase has scattered product-layer assets. These migrate to entelecheia-product as follows:

| Upstream | Target in entelecheia-product | Sanitization |
|---|---|---|
| `frontend/src/features/{shell, auth, landing}` | `packages/platform-shell/frontend/` | Remove any direct engine imports; rewire studio calls through studio-client (mock initially) |
| `frontend/src/features/roundtable` | `packages/platform-features/agora/frontend/` | **Rename roundtable → agora throughout**; rewire all backend calls through studio-client |
| `frontend/src/features/{tree, knowledge}` | `packages/platform-features/knowledge/frontend/` | Strip direct OriginChainQuery/KnowledgeTreeStore imports → studio-client calls |
| `frontend/src/features/reports` | `packages/platform-features/reports/frontend/` | Same |
| `frontend/src/features/chathub` | `packages/platform-features/chathub/frontend/` | Same |
| `frontend/src/features/wizard` | `packages/platform-features/wizard/frontend/` | Same; vertical selection (was domain selection) integrates with platform-shell's vertical switcher |
| `frontend/src/features/settings` | `packages/platform-features/settings/frontend/` | Same |
| `frontend/src/features/{agents, pheromone}` | **Dropped** — these are studio admin concerns, not product concerns |
| `app/api/routers/{auth, health, monitoring}.py` | Stays in respective microservice + main api | Direct port |
| `app/api/routers/{reports, export, knowledge, trees}.py` | Refactored into platform-features/*/api/ | Replace direct engine imports with studio-client calls |
| `app/api/routers/dd_workflow.py` | `packages/verticals/investment/api/` | This IS investment vertical's content; rename routes to `/api/verticals/investment/dd-workflow/*` |
| `app/api/routers/files_multipart.py` BP/financial endpoints | Split: generic PDF → `platform-features/uploads/api/`; BP/financial → `verticals/investment/api/` | |
| `app/api/routers/agents.py`, `pheromone.py`, `origin_chain.py` | **Dropped** — studio's responsibility |
| `app/exporters/*` | `packages/platform-features/reports/api/exporters/` | Direct port |
| `app/parsers/gemini_pdf_parser.py` | `packages/platform-features/uploads/api/parsers/` | Direct port |
| `app/parsers/bp_parser.py` | `packages/verticals/investment/api/parsers/` | Investment-specific |
| `app/middleware/*` | `apps/api/middleware/` | Direct port |
| `auth_service/`, `user_service/` | `auth_service/`, `user_service/` (top-level dirs) | Direct port |

Each migration is one PR + one entry in `docs/migration-log.md` recording: source path + line range, target path, sanitization performed, date, upstream commit SHA.

The five known cross-layer leakage points (in upstream) all need rewriting against `studio-client`:

1. `node_deliberation_handler.py` → call `studio_client.subscribe_meeting()`
2. `walking_writer/` → call `studio_client.get_dag_view()` + `studio_client.get_meeting_outcome()`
3. `report_writer/provenance_adapter.py` → call `studio_client.get_provenance()`
4. `tree_stream/adapter.py` → call `studio_client.subscribe_knowledge_tree_events()`
5. Direct studio-internal imports in routers → all replaced

---

## 10. Open questions deferred to v0.1 plan-creation

Following the engine's §12 deferred-types pattern: rather than over-specifying schemas in this canonical document, the following are intentionally deferred to v0.1 plan-creation. The implementer proposes shapes, the user approves in chat, the spec gets updated, then code is written.

| Deferred topic | Why deferred |
|---|---|
| Exact `StudioClient` Protocol signatures (~15 methods) | Need real studio API contract before finalizing |
| `vertical.manifest.ts` TypeScript schema (full validator) | Needs concrete vertical to validate the model |
| Frontend tech stack (Vue 3 + Vite + Pinia inherited from upstream) — confirmed but bundler config etc. open | Implementer's call |
| Authentication flow with studio — does product forward user JWT to studio, or use a separate service token? | Settled when real studio API exists |
| Vertical permission model — RBAC details, who can switch to which vertical | v0.2 (after first vertical proves the pattern) |
| Multi-tenant hooks — what schema fields are tenant-scoped if/when multi-tenancy ships | Designed forward but not implemented |
| Web UI for vertical configuration (admin) | v0.3 |
| Observability schema (what metrics, dashboards) | Co-designed with studio's observability when both stabilize |

---

## 11. Why this design

1. **Three projects, one user.** Engine + studio + product is a real architectural decomposition that survives daily pressure: each project has CI enforcing its boundaries; reverse imports fail to build.
2. **Vertical-as-UI-plugin keeps the platform stable.** Adding a vertical doesn't change shell or features. Verticals are independent.
3. **Pseudo studio-client decouples timelines.** Product develops without waiting for studio v0.1. When studio is ready, swap is small.
4. **agora rename clears cultural baggage.** "Roundtable" was upstream-specific and visually limiting; "agora" is universal, philosophical, and fits the entelecheia naming scheme.
5. **No code reuse from upstream is possible without sanitization.** Every migrated file gets reviewed against red lines #1-5; this is a feature, not a bug.

---

## 12. References

- [Engine ADR-0002 (three-project architecture)](https://github.com/dengjianbo3/Entelecheia_engine/blob/main/docs/adr/0002-three-project-architecture.md)
- [Engine v2 spec](https://github.com/dengjianbo3/Entelecheia_engine/blob/main/docs/design/06-engine-architecture-v2.md)
- [Studio ADR-0001](https://github.com/dengjianbo3/Entelecheia_studio/blob/main/docs/adr/0001-studio-as-internal-agent-ops-platform.md)
- [Studio vision](https://github.com/dengjianbo3/Entelecheia_studio/blob/main/docs/design/00-studio-vision.md)
- [`adr/0001-product-as-multi-vertical-platform.md`](../adr/0001-product-as-multi-vertical-platform.md)
- [`01-design-principles.md`](01-design-principles.md)
- [`02-studio-integration.md`](02-studio-integration.md) — pseudo client + future translation
- [`03-vertical-pack-model.md`](03-vertical-pack-model.md) — manifest schema, registration
- [`04-platform-features.md`](04-platform-features.md) — agora, reports, knowledge, etc.
