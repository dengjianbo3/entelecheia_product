# Architecture — entelecheia-product

> **Quick brief.** ~30 minutes for the three-project model + product's place in it + how vertical packs plug in + how the product talks to studio.
>
> **Full canonical vision**: [`docs/design/00-product-vision.md`](docs/design/00-product-vision.md).

---

## The three-project architecture (recap)

```
┌──────────────────────────────────────────────────────────────────┐
│ entelecheia-product (THIS REPO)                                   │
│  • Platform shell + features (always present)                     │
│  • Vertical packs (pluggable; UI / data-feed customization)       │
│  • studio-client SDK (the only way to talk to backend logic)      │
└──────────────────────────────────────────────────────────────────┘
                              ↓ HTTP/WS
┌──────────────────────────────────────────────────────────────────┐
│ entelecheia-studio                                                │
│  • Substrate (LLM / skills / memory / data / observability)       │
│  • Paradigms (CoT / ReWOO / ReAct / custom)                       │
│  • Spec / Registry / Runtime composer                             │
│  • API (REST/WS/GraphQL) — what product calls                     │
└──────────────────────────────────────────────────────────────────┘
                              ↓ entelecheia.AgentProtocol
┌──────────────────────────────────────────────────────────────────┐
│ entelecheia-engine                                                │
│  Pure deliberation runtime — meeting supervisor + event log       │
└──────────────────────────────────────────────────────────────────┘
```

**Each layer can use any layer below it. No layer reaches into a layer above it.** The product never sees engine. Studio sees engine via public surface. Engine knows about no one.

---

## What product owns

### Owns

- **The user-facing application** — a Vue 3 SPA + FastAPI backend that brings auth + agora discussions + reports + uploads + dashboards + vertical-specific tabs to end users
- **Platform shell**: auth, multi-vertical switcher, navigation, theming, i18n, settings
- **Platform features (vertical-agnostic)**:
  - **agora** — the deliberation discussion UI (live message flow, evidence sidebar, DAG view, conclude state)
  - **reports** — browser + multi-format exports (PDF/Word/Excel)
  - **knowledge** — knowledge tree browser + graph navigation
  - **chathub** — generic expert chat with file upload + evidence sidebar
  - **uploads** — file upload + generic PDF parsing
  - **wizard** — onboarding for first-time users
  - **settings** — user preferences + theme + language
  - **observability** — global cost / latency dashboards (read from studio)
- **Vertical packs** — pluggable UI/data customizations (the `investment` pack adds 行情 / 持仓 / market-data feed)
- **studio-client SDK** — the canonical way for any platform feature or vertical pack to call studio
- **Lightweight microservices** — `auth_service` (JWT), `user_service` (preferences)

### Does not own

- ❌ The deliberation runtime — that's engine (via studio)
- ❌ Agent paradigm logic — studio paradigm packages
- ❌ LLM / embedding / image-gen calls — studio substrate-models
- ❌ Skill / tool execution — studio substrate-skills
- ❌ Memory backends — studio substrate-memory
- ❌ AgentSpec / ProjectSpec data models — studio specs package
- ❌ Spec registry — studio registry
- ❌ Spec → AgentProtocol composition — studio runtime
- ❌ Cost ledger writes — studio observability (product only reads aggregates)

The product is allowed to **read from studio**, **request actions from studio**, and **subscribe to events from studio**. That's it.

---

## Vertical = product UI specialization (NOT agent specialization)

A common confusion this design explicitly resolves:

| Layer | What gets verticalized |
|---|---|
| **Studio** | Agent capabilities — each `ProjectSpec` is a verticalized agent bundle (e.g., "investment-equity-research-v1") |
| **Product (this repo)** | UI / external data feeds / vertical-specific tabs and widgets |

The investment vertical does **not** define agents — those live in studio as ProjectSpecs. The investment vertical defines:

- A `行情` tab (Vue components + small API proxy to a market-data service)
- A `持仓` widget on the dashboard
- A custom upload flow for `财报` (financial reports) — the parsing itself uses studio's general PDF parsing skill or a vertical-provided proxy
- The vertical's manifest declares "show users a market-data tab when they're in investment-vertical mode"

When a user starts an agora deliberation while in the investment vertical, the product asks studio "give me available investment-relevant projects" → studio returns a project list scoped by user permissions → user picks one → product invokes `studio.run_meeting(project_id, ...)`. The vertical pack does **not** decide which project; it filters/displays available projects.

---

## How the product talks to studio (v0.1 pseudo, v0.2+ real)

**Single contract**: `packages/studio-client/`. All other packages depend on this one for studio interaction.

### v0.1 — Pseudo client

```python
# packages/studio-client/src/entelecheia_studio_client/__init__.py

class StudioClient(Protocol):
    async def list_available_projects(self, user_id: str, vertical_id: str | None = None) -> list[ProjectSummary]: ...
    async def run_meeting(self, project_id: str, topic: str, materials: list[Material]) -> MeetingHandle: ...
    async def get_meeting_outcome(self, meeting_id: str) -> MeetingOutcome: ...
    async def get_dag_view(self, meeting_id: str) -> DagViewSnapshot: ...
    async def get_provenance(self, meeting_id: str, claim_id: str) -> ProvenanceTrace: ...
    async def subscribe_meeting(self, meeting_id: str) -> AsyncIterator[MeetingEvent]: ...
    async def get_cost_aggregate(self, **dimensions) -> CostReport: ...
    # ~15 methods total

class PseudoStudioClient:
    """Returns mock data. Lets the entire product UI develop without studio existing."""
    async def list_available_projects(self, user_id, vertical_id=None):
        return _MOCK_PROJECTS_BY_VERTICAL.get(vertical_id, [])
    # ... mock implementations
```

The platform features and vertical packs are written against `StudioClient`. They never know whether the implementation is pseudo or real.

### v0.2 — Real client

```python
class HttpStudioClient:
    """Real HTTP/WebSocket client. Drop-in replacement for PseudoStudioClient."""
    def __init__(self, base_url: str, token: str): ...
    # ... real implementations calling studio's API
```

If studio's actual API shape differs from what the product assumed, the **translation layer goes inside `HttpStudioClient`** — UI code is unchanged.

---

## Vertical pack registration

A vertical is a Python package + Vue feature module bundled at `packages/verticals/<id>/`. It declares its UI surface via a manifest:

```typescript
// packages/verticals/investment/manifest.ts
export default {
  vertical_id: "investment",
  display_name: "投资分析",
  description: "Equity research / DD / portfolio analytics",

  // Tabs added to top-level navigation when this vertical is active
  tabs: [
    { id: "market_watch", label: "行情", route: "/investment/market-watch", component: MarketWatchPage },
    { id: "portfolio",    label: "持仓", route: "/investment/portfolio",    component: PortfolioPage },
  ],

  // Widgets added to the dashboard
  dashboard_widgets: [
    { id: "market_summary", component: MarketSummaryWidget, position: "top-right" },
  ],

  // Specialized upload types
  upload_handlers: [
    { kind: "financial-report", label: "财报", endpoint: "/api/verticals/investment/upload/financial" },
    { kind: "business-plan",   label: "BP",   endpoint: "/api/verticals/investment/upload/bp" },
  ],

  // External data feeds proxied by this vertical's backend
  data_feeds: [
    { id: "yahoo-finance", api: "/api/verticals/investment/data/yahoo" },
    { id: "akshare",       api: "/api/verticals/investment/data/akshare" },
  ],

  // Default vertical ProjectSpec scope (filter when listing studio projects)
  default_project_filter: { labels_any_of: ["investment"] },

  // Localization
  i18n: { zh: { ... }, en: { ... } },
}
```

Frontend boot reads enabled verticals' manifests, registers routes/widgets/handlers. Backend boot does the same for routers via Python entry points.

**The vertical CANNOT modify platform shell or platform features.** It only adds tabs, widgets, handlers, data feeds. Adding a vertical changes the product's surface; it doesn't change the product's core.

---

## Substitution validation

Inspired by engine's substitution-test discipline:

| Test | What it validates |
|---|---|
| **Vertical add** | A new vertical can be added (drop a `packages/verticals/<id>/` directory + manifest) and appear in the UI without touching shell/features |
| **Vertical remove** | A vertical can be disabled (config flag) and the rest of the product still works |
| **Studio swap** | The pseudo studio-client can be replaced by the real one (or any other implementation) without changing platform/vertical code |
| **Multi-vertical** | A user with permissions for multiple verticals can switch between them and see each vertical's UI surface correctly |

If any of these requires touching shell or feature code in `packages/platform-*`, the architecture has leaked.

---

## Why this design

1. **Engine + studio + product is a clean three-layer.** Each layer has one job. CI in each repo enforces no reverse imports.
2. **Vertical-as-UI-plugin keeps the platform stable.** Adding a vertical doesn't change shell, features, or studio integration. Removing a vertical doesn't break anything.
3. **Pseudo studio-client lets product develop independently.** Don't block on studio v0.1 finalizing its API; build full UI against mocks first.
4. **studio-client SDK is the single contract.** All cross-layer concerns flow through one Python module + its TypeScript mirror.
5. **No agent / paradigm / skill / memory awareness.** Anything agent-related goes through studio. The product is purely the user-facing shell.
6. **Vertical = UI specialization, not domain logic.** Domain logic = ProjectSpec content in studio. The product's verticals are about external data feeds and tab/widget specialization.

---

## What's NOT in this repo

- LLM clients, paradigm implementations, agent specs, project specs, skill bundles → studio
- Deliberation runtime, event log, agent protocol → engine (via studio)
- Specific business domain words (`"investment_thesis"`, `"DCF"`, `"M&A"`, etc. as engine-side strings) — those are inside `verticals/<id>/` only, never in platform-shell or platform-features
- Multi-tenancy / billing — single-tenant for v0.x

---

## Open questions (deferred to v0.1 detailed specs)

These are addressed in [`docs/design/00-product-vision.md`](docs/design/00-product-vision.md) §"deferred":

1. Exact `studio-client` Protocol signatures (~15 methods) — fleshed out in v0.1 plan
2. Vertical manifest TypeScript schema (full validator) — v0.1 plan
3. Frontend tech stack confirmation (Vue 3 + Vite + Pinia inherited from upstream) — v0.1 plan
4. Authentication flow with studio (token forwarding) — v0.2 (when real studio API exists)
5. The mother-ship vs vertical UI dispatch (router guards, vertical permission checks) — v0.1 plan
