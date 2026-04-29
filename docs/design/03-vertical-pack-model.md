# Vertical Pack Model

What a vertical IS, what a manifest looks like, how registration works, what verticals can and cannot do.

---

## What a vertical IS

A **vertical pack** is a self-contained directory at `packages/verticals/<id>/` that adds **UI + data-feed customization** for a specific business domain to the product platform.

A vertical contains:

- **Frontend Vue components** (tabs, widgets, upload handlers) that get registered into the product's UI
- **Backend FastAPI router** for vertical-specific data-feed proxies (e.g., a thin proxy to a market-data API)
- **A manifest** declaring everything the vertical contributes

A vertical does **not** contain:

- Agent logic (that's in studio's `ProjectSpec`s)
- LLM clients
- Paradigm code
- Direct engine access
- Any modification of platform shell or platform features

The vertical is a *plug-in*: it adds without modifying.

---

## What "investment vertical" actually means

The first vertical, `investment`, demonstrates the full pattern. It contributes:

| Contribution | What it adds to user UX |
|---|---|
| Tab: 行情 | Top-level navigation tab showing market quotes for stocks the user follows |
| Tab: 持仓 | Top-level navigation tab showing the user's portfolio (positions + P&L) |
| Widget: market-summary | Dashboard widget showing daily market summary |
| Upload handler: financial-report | Custom upload + parse flow for 财报 (financial reports) |
| Upload handler: business-plan | Custom upload + parse flow for BPs |
| Data feed: yahoo-finance | Backend proxy `/api/verticals/investment/data/yahoo` for fetching quotes |
| Data feed: akshare | Backend proxy `/api/verticals/investment/data/akshare` for A-share data |
| Default project filter | When the user is in investment vertical, list_available_projects defaults to `labels_any_of=["investment"]` |
| i18n | zh + en translations for vertical-specific strings |

Notice what's NOT here: no LLM calls, no agent definitions, no paradigm choice, no skill loading. The user can start an agora deliberation while in the investment vertical, and the **agents themselves** come from studio (selected by the user from the project list studio returns). The vertical only customizes how the user *sees* and *interacts with* the platform — not what the agents *do*.

---

## The manifest

A vertical's `manifest.ts` (frontend) and `manifest.py` (backend) are the only ways it contributes.

### Frontend manifest

```typescript
// packages/verticals/investment/frontend/manifest.ts

import { defineVertical } from "@entelecheia/platform-shell"
import MarketWatchPage from "./pages/MarketWatch.vue"
import PortfolioPage from "./pages/Portfolio.vue"
import MarketSummaryWidget from "./widgets/MarketSummary.vue"
import FinancialReportUploadHandler from "./upload-handlers/FinancialReport.vue"
import BusinessPlanUploadHandler from "./upload-handlers/BusinessPlan.vue"
import zh from "./i18n/zh.json"
import en from "./i18n/en.json"

export default defineVertical({
  vertical_id: "investment",
  display_name: "投资分析",
  description: "Equity research, due diligence, portfolio analytics",
  icon: "TrendingUp", // lucide-vue-next icon name

  // Tabs added to top navigation when this vertical is active
  tabs: [
    {
      id: "market_watch",
      label: { zh: "行情", en: "Market Watch" },
      route: "/investment/market-watch",
      component: MarketWatchPage,
      requires_permission: "investment:market_watch",
    },
    {
      id: "portfolio",
      label: { zh: "持仓", en: "Portfolio" },
      route: "/investment/portfolio",
      component: PortfolioPage,
      requires_permission: "investment:portfolio",
    },
  ],

  // Widgets added to the platform dashboard
  dashboard_widgets: [
    {
      id: "market_summary",
      component: MarketSummaryWidget,
      preferred_position: "top-right",
      title: { zh: "市场概览", en: "Market Summary" },
    },
  ],

  // Specialized upload handlers (extend platform-features/uploads)
  upload_handlers: [
    {
      kind: "financial-report",
      label: { zh: "财报", en: "Financial Report" },
      accepts: [".pdf", ".xlsx"],
      backend_endpoint: "/api/verticals/investment/upload/financial",
      handler_component: FinancialReportUploadHandler,
    },
    {
      kind: "business-plan",
      label: { zh: "BP", en: "Business Plan" },
      accepts: [".pdf", ".pptx"],
      backend_endpoint: "/api/verticals/investment/upload/bp",
      handler_component: BusinessPlanUploadHandler,
    },
  ],

  // External data feeds (this vertical proxies them via its backend router)
  data_feeds: [
    { id: "yahoo-finance", api: "/api/verticals/investment/data/yahoo" },
    { id: "akshare",       api: "/api/verticals/investment/data/akshare" },
  ],

  // When this vertical is active, list_available_projects defaults to this filter
  default_project_filter: {
    labels_any_of: ["investment"],
  },

  // i18n (merged into platform-shell's i18n on registration)
  i18n: { zh, en },
})
```

### Backend manifest

```python
# packages/verticals/investment/api/manifest.py

from entelecheia_platform_shell import VerticalManifest
from .routers import data_feeds_router, uploads_router

vertical_manifest = VerticalManifest(
    vertical_id="investment",
    display_name="投资分析",

    # FastAPI routers contributed by this vertical
    api_routers=[
        data_feeds_router,    # /api/verticals/investment/data/*
        uploads_router,       # /api/verticals/investment/upload/*
    ],

    # Permissions this vertical declares (used by the multi-vertical switcher)
    permissions_declared=[
        "investment:market_watch",
        "investment:portfolio",
        "investment:upload_financial",
        "investment:upload_bp",
    ],

    # Studio fixture overlay for this vertical (during pseudo client phase)
    studio_fixture_overlay="investment",
)
```

Backend registration uses Python entry points:

```toml
# packages/verticals/investment/pyproject.toml
[project.entry-points."entelecheia_product.verticals"]
investment = "entelecheia_vertical_investment.manifest:vertical_manifest"
```

The product's `apps/api/` discovers all installed verticals at startup via this entry point group, includes their routers, and exposes their manifest metadata to the frontend.

---

## Registration flow (boot sequence)

### Backend

```
apps/api/main.py startup:
  1. Discover verticals: importlib.metadata.entry_points(group="entelecheia_product.verticals")
  2. For each entry point:
     a. Load the manifest module
     b. Validate the VerticalManifest object
     c. Register all api_routers into FastAPI app
     d. Register permissions_declared with auth_service
  3. Expose GET /api/platform/verticals returning the list of installed verticals
     (frontend reads this to know which manifests to load)
```

### Frontend

```
apps/frontend/main.ts startup:
  1. Fetch GET /api/platform/verticals → list of vertical_ids
  2. For each vertical_id: dynamic import its frontend manifest
  3. Validate VerticalManifest TS schema
  4. Register all tabs into Vue Router
  5. Register all dashboard_widgets into the dashboard layout
  6. Register all upload_handlers into platform-features/uploads
  7. Merge i18n bundles into the global i18n instance
  8. Mark active vertical (from user preferences or URL); display only that vertical's tabs/widgets
```

The active vertical can change at runtime via the multi-vertical switcher in platform-shell. Switching:

- Updates active route group
- Re-renders dashboard with the new vertical's widgets
- Filters available studio projects by the new vertical's `default_project_filter`
- Updates URL prefix (e.g., from `/investment/...` to `/policy/...`)

---

## What verticals CANNOT do

Per design principle P5 + CONTRIBUTING.md red lines:

- ❌ Modify `packages/platform-shell/` or `packages/platform-features/*` (CI rejects PRs that touch both a vertical dir and platform dir)
- ❌ Import another vertical (`from packages.verticals.policy import …` is rejected)
- ❌ Bypass the manifest mechanism (cannot directly mount a router or register a route outside of what the manifest declares)
- ❌ Modify global state (no global stores; use platform-shell's user preferences API)
- ❌ Use the engine package (`from entelecheia import …` is rejected — same as platform code)
- ❌ Make raw HTTP calls to studio (must go through `studio-client`)
- ❌ Inject agent / paradigm / skill / model logic (those concerns belong in studio's `ProjectSpec`)

---

## What verticals CAN do (full list)

- ✅ Add tabs to top navigation (from `manifest.tabs`)
- ✅ Add widgets to platform dashboard (from `manifest.dashboard_widgets`)
- ✅ Add upload handlers (from `manifest.upload_handlers`)
- ✅ Proxy external data feeds via vertical-specific FastAPI routers (`/api/verticals/<id>/...`)
- ✅ Declare permissions for fine-grained access control
- ✅ Provide a `default_project_filter` for the studio project picker
- ✅ Override studio fixture overlay (during pseudo client phase) to provide vertical-realistic mock data
- ✅ Provide i18n bundles
- ✅ Include vertical-specific Vue components, stores (Pinia, namespaced under vertical_id), and helpers
- ✅ Make HTTP calls to *external* services from its own backend routers (e.g., the investment vertical's data-feeds router calls Yahoo Finance API directly — this is the vertical's responsibility)

---

## Vertical lifecycle

A vertical pack goes through:

```
draft (in development) → released → deployed (in user's instance) → deprecated → removed
```

- **draft**: active development, not in main branch
- **released**: merged to main, available in product's package registry
- **deployed**: a particular product instance has this vertical enabled in its config (each instance can pick which verticals to enable)
- **deprecated**: marked for removal in a future major version
- **removed**: gone

A user instance can enable / disable verticals via configuration. Disabling a vertical removes its tabs/widgets/handlers but does NOT delete user data tied to it (user's portfolio data stays in the data feed; user can re-enable later).

---

## Multi-vertical concurrency

A user can have access to multiple verticals (different RBAC groups). At any given time, ONE vertical is "active" in the UI (selected via switcher in platform-shell). Switching:

- Active route group changes
- Dashboard re-renders with the new vertical's widgets
- Project filter updates
- URL prefix updates

User data is preserved across switches (e.g., switching from investment to policy and back to investment shows the same portfolio state).

For v0.1, the multi-vertical model is single-tenant single-user (one user, multiple verticals they can access). Multi-tenant (multiple users, each with their own vertical permissions) is v0.2+.

---

## Adding a new vertical (developer flow)

1. `cp -r packages/verticals/_template packages/verticals/<id>/`
2. Edit `manifest.ts` and `manifest.py` (set vertical_id, display_name, etc.)
3. Implement Vue components for tabs / widgets / upload handlers
4. Implement FastAPI router for data feeds
5. Add tests in `packages/verticals/<id>/tests/`
6. Add fixture overlay in `packages/studio-client/fixtures/<id>/`
7. Run substitution validation: with the new vertical installed, ensure platform features still work and the new tabs appear correctly
8. Update `docs/migration-log.md` with `<vertical_id> first registered on YYYY-MM-DD`
9. PR with screencast (2 min) showing the vertical's tabs / widgets working

A complete vertical pack should be ~500-2000 lines of code (depending on how many tabs/widgets it adds). Anything larger likely means agent logic is leaking in — refactor to put that in studio's `ProjectSpec`.

---

## What about cross-vertical features?

If two verticals would share a feature (e.g., both investment and policy users want a "track topics over time" widget), the right answer is:

- If it's general enough to apply to ALL verticals → promote to a platform feature
- If it's general for a subset → factor into a shared utility within `packages/platform-features/<utility-name>/`
- If it's vertical-specific to each (just looks similar) → each vertical implements it independently (DRY at the cost of cross-vertical pollution is the wrong tradeoff)

When in doubt, prefer duplication over pollution. Verticals should remain independent.
