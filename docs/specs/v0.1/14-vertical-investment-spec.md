# 14 — `verticals/investment` v0.1 spec

> **Status**: v0.1 contract for the first concrete vertical pack — investment (React).
> **Lives at**: `packages/verticals/investment/`.
> **Consumes**: `13-vertical-template-spec.md` (the canonical structure this spec instantiates), `02-platform-shell-spec.md` §3 (`VerticalManifest`), `06-feature-reports-spec.md` §6.3 (`report_templates`), `09-feature-uploads-spec.md` §1.4 (custom upload handlers).
> **Forwards to**: `15-apps-api-spec.md` §boot (entry-point discovery + fixture overlay merge).
> **Supersedes**: the Vue version of this spec; React migration per session decision 2026-05-03.
> **Domain vocabulary note**: this spec is INSIDE a `packages/verticals/<id>/` directory equivalent in spec form; per `entelecheia-product-philosophy` skill + `scripts/check-purity.sh`, the forbidden-vocabulary rule applies to `packages/platform-*` and `apps/*` only. This spec legitimately uses "investment" / "financial-report" / "due-diligence" / "yahoo-finance" / "akshare" — they are the vertical's domain.

---

## Mission

This file defines the investment vertical — the first concrete vertical pack, copied from `13`'s `_template/` and filled with real domain content. It contributes two tabs (Market Watch + Portfolio), one dashboard widget (Market Summary), two custom upload handlers (Financial Report + Business Plan), two backend data-feed proxies (yahoo-finance + akshare), two custom report templates (Investment Summary + Due Diligence), an investment-flavored studio fixture overlay (5 projects spanning deliberation + chat use cases), and a permission set scoped under `investment:*`. The vertical proves the manifest pluggability that `02` + `13` define is real and complete.

**Hard rule** (proves P5 isolation): the vertical does not modify ANY platform code. Every contribution flows through the manifest declared in `manifest.py` + `manifest.ts`. CI (per `13` §9 row "Vertical does NOT import another vertical" + Red Line #4) enforces. Removing this vertical (uninstall the package) leaves the rest of the product fully functional with no traces.

---

## Scope

**Covers.**
- Module layout under `packages/verticals/investment/`, derived from `13` `_template/` via the rename script.
- Backend `manifest.py` instance: 4 routers (yahoo data + akshare data + financial upload + business-plan upload), 5 declared permissions, fixture overlay = "investment", 2 report templates.
- Frontend `manifest.ts` instance: 2 tabs, 1 widget, 2 upload handlers, 2 data feeds, project_id_in allowlist of 5 projects, i18n bundles, accent_color, default_route.
- 2 tab React components: `<MarketWatchTab>`, `<PortfolioTab>`.
- 1 widget React component: `<MarketSummaryWidget>`.
- 2 upload handler React components: `<FinancialReportHandler>`, `<BusinessPlanHandler>`.
- 2 backend data-feed routers (yahoo-finance proxy + akshare proxy) with caching + rate limiting.
- 2 backend upload handler endpoints (vertical-specific validation that doesn't fit the generic `/api/uploads`).
- 2 report templates with section composition.
- Fixture overlay: 5 `ProjectSpec`s, 5 meeting_templates, 5 outcomes covering deliberation + chathub use cases.
- 5 declared permissions under `investment:*` namespace.
- i18n bundles (zh + en) for every user-visible string this vertical introduces.
- Test matrix per contribution.
- v0.2 forward-compat hooks (broker integration for portfolio, real-time market WebSocket, additional templates).

**Does not cover.**
- `_template/` itself — `13-vertical-template-spec.md` defines the canonical structure; this spec instantiates.
- `VerticalManifest` interface — `02` §3.1 defines.
- The studio agents that drive investment meetings — those are studio's `ProjectSpec`s with `AgentSpec` members; the vertical only references `project_id`s. Authoring agents is studio admin work (per `01` §11.10 spec authoring is OUT of product Protocol).
- Specific paradigm choices for investment projects — paradigm tuning lives in studio's ProjectSpec.
- Live brokerage integration / order execution — the portfolio tab is read-only (manual entry or pasted CSV); broker hookups are v0.2+.
- Tax / accounting calculations.
- Compliance / KYC workflows.

**Out of scope for v0.1.**
- Real-time market data via WebSocket. v0.1 polls every 30 s.
- Server-side persistence of user's watchlist + portfolio. v0.1 stores in vertical's Zustand store (in-memory per session). v0.2 may extend `UserPreferences.extras` (per `04` §scope hint) for cross-session persistence.
- Advanced charting (TradingView-style candles + indicators). v0.1 shows price + change only.
- Sector / industry analytics views.
- Per-user data feed credentials. v0.1 uses platform-wide API keys via env vars (`YAHOO_API_KEY` if needed; akshare is keyless).
- Multi-currency portfolio. v0.1 assumes USD for yahoo + CNY for akshare; no FX conversion.
- Holding-level news feed.
- Earnings calendar integration.

---

## §1 Module layout (delta from `_template`)

Same overall tree as `13` §1; differences:

```
packages/verticals/investment/
├── pyproject.toml                                # name = "entelecheia-vertical-investment"
├── README.md                                     # vertical-specific operator notes (env vars, fixture refresh)
├── src/entelecheia_vertical_investment/
│   ├── manifest.py
│   ├── api/
│   │   ├── routers/
│   │   │   ├── data_yahoo.py                     # /api/verticals/investment/data/yahoo/*
│   │   │   ├── data_akshare.py                   # /api/verticals/investment/data/akshare/*
│   │   │   ├── uploads_financial.py              # /api/verticals/investment/upload/financial-report
│   │   │   └── uploads_business_plan.py          # /api/verticals/investment/upload/business-plan
│   │   ├── permissions.py                        # 5 permissions under investment:*
│   │   ├── data_sources/
│   │   │   ├── yahoo_client.py                   # thin httpx wrapper + 30s cache
│   │   │   └── akshare_client.py                 # thin akshare wrapper + 60s cache
│   │   └── report_templates/
│   │       ├── investment_summary.py
│   │       └── due_diligence.py
│   └── __init__.py
├── tests_api/
│   ├── test_data_yahoo.py
│   ├── test_data_akshare.py
│   ├── test_uploads_financial.py
│   └── test_uploads_business_plan.py
├── frontend/
│   ├── src/
│   │   ├── manifest.ts
│   │   ├── components/
│   │   │   ├── tabs/
│   │   │   │   ├── MarketWatchTab.tsx
│   │   │   │   └── PortfolioTab.tsx
│   │   │   ├── widgets/
│   │   │   │   └── MarketSummaryWidget.tsx
│   │   │   ├── handlers/
│   │   │   │   ├── FinancialReportHandler.tsx
│   │   │   │   └── BusinessPlanHandler.tsx
│   │   │   └── shared/
│   │   │       ├── QuoteRow.tsx                  # used by both market-watch + dashboard widget
│   │   │       └── PnLBadge.tsx                  # green/red P&L pill
│   │   ├── stores/
│   │   │   ├── marketWatchStore.ts               # Zustand: watchlist (in-memory v0.1)
│   │   │   └── portfolioStore.ts                 # Zustand: holdings (in-memory v0.1)
│   │   ├── hooks/
│   │   │   ├── useYahooQuotes.ts                 # polls /yahoo/quotes; AbortController + 30s interval
│   │   │   └── useAkshareQuotes.ts               # polls /akshare/quotes; 30s interval
│   │   └── i18n/
│   │       ├── zh.json
│   │       └── en.json
│   └── tests/
└── fixture_overlay/
    ├── projects.yaml
    ├── meeting_templates.yaml
    └── outcomes.yaml
```

Cross-cutting deltas vs `_template`:
- `data_sources/` subdir for the upstream-API clients (yahoo + akshare have non-trivial wrappers worth isolating from routers)
- `shared/` frontend subdir for components reused across tabs + widget
- 2 Zustand stores (separate concerns — watchlist vs portfolio)
- `hooks/` subdir for fetch hooks (polling + abort discipline lives here, not in components)

---

## §2 Backend manifest instance

```python
# packages/verticals/investment/src/entelecheia_vertical_investment/manifest.py

from entelecheia_platform_shell.types import VerticalManifest

from .api.routers.data_yahoo import yahoo_router
from .api.routers.data_akshare import akshare_router
from .api.routers.uploads_financial import financial_upload_router
from .api.routers.uploads_business_plan import business_plan_upload_router
from .api.permissions import PERMISSIONS
from .api.report_templates.investment_summary import investment_summary_template
from .api.report_templates.due_diligence import due_diligence_template


vertical_manifest = VerticalManifest(
    vertical_id="investment",                       # MUST match pyproject entry-point key
    display_name="Investment Research",

    api_routers=[
        yahoo_router,
        akshare_router,
        financial_upload_router,
        business_plan_upload_router,
    ],

    permissions_declared=PERMISSIONS,

    studio_fixture_overlay="investment",             # merges packages/verticals/investment/fixture_overlay/
                                                     # into packages/studio-client/fixtures/investment/

    report_templates=[
        investment_summary_template,
        due_diligence_template,
    ],
)
```

`pyproject.toml` (deltas vs template):

```toml
[project]
name = "entelecheia-vertical-investment"
version = "0.1.0"
description = "Investment research vertical pack for entelecheia-product."
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.110",
    "pydantic>=2.7",
    "httpx>=0.27",                                   # for yahoo proxy
    "akshare>=1.13",                                 # A-share data; pure-Python, no native deps
    "entelecheia-platform-shell",
    "entelecheia-studio-client",
]

[project.entry-points."entelecheia_product.verticals"]
investment = "entelecheia_vertical_investment.manifest:vertical_manifest"
```

---

## §3 Frontend manifest instance

```typescript
// packages/verticals/investment/frontend/src/manifest.ts
import type { VerticalManifest } from "@entelecheia/platform-shell";
import type { ProjectId } from "@entelecheia/studio-client";
import { TrendingUp } from "lucide-react";

import MarketWatchTab from "./components/tabs/MarketWatchTab";
import PortfolioTab from "./components/tabs/PortfolioTab";
import MarketSummaryWidget from "./components/widgets/MarketSummaryWidget";
import FinancialReportHandler from "./components/handlers/FinancialReportHandler";
import BusinessPlanHandler from "./components/handlers/BusinessPlanHandler";
import zh from "./i18n/zh.json";
import en from "./i18n/en.json";

const manifest: VerticalManifest = {
  vertical_id: "investment",
  display_name: "Investment Research",
  description: "Equity research, due diligence, portfolio analytics for the investment use case.",
  icon: TrendingUp,                                  // React.ComponentType from lucide-react
  accent_color: "#0EA5E9",                           // sky-500; finance-flavored

  tabs: [
    {
      id: "market-watch",
      label_key: "vertical.investment.tab.market_watch",
      route_path: "/market-watch",                    // /investment/market-watch
      component: MarketWatchTab,                      // React.ComponentType
      required_permission: "investment:market_watch",
      position: 100,
    },
    {
      id: "portfolio",
      label_key: "vertical.investment.tab.portfolio",
      route_path: "/portfolio",                        // /investment/portfolio
      component: PortfolioTab,
      required_permission: "investment:portfolio",
      position: 110,
    },
  ],

  dashboard_widgets: [
    {
      id: "market-summary",
      component: MarketSummaryWidget,
      preferred_position: "top-right",
      title_key: "vertical.investment.widget.market_summary.title",
      required_permission: "investment:market_watch",
    },
  ],

  upload_handlers: [
    {
      kind: "investment:financial-report",
      label_key: "vertical.investment.upload.financial_report",
      accepts: [".pdf", ".xlsx",
                "application/pdf",
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"],
      max_size_bytes: 20 * 1024 * 1024,              // 20 MB; financial reports get big
      handler_component: FinancialReportHandler,
      studio_material_kind: "brief",                  // PDFs become brief; xlsx normalized to brief text via parse
    },
    {
      kind: "investment:business-plan",
      label_key: "vertical.investment.upload.business_plan",
      accepts: [".pdf", ".docx",
                "application/pdf",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
      max_size_bytes: 10 * 1024 * 1024,              // 10 MB
      handler_component: BusinessPlanHandler,
      studio_material_kind: "brief",
    },
  ],

  data_feeds: [
    {
      id: "yahoo-finance",
      api_path: "/api/verticals/investment/data/yahoo",
      description: "Yahoo Finance quote proxy (US + global markets). 30 s cache.",
    },
    {
      id: "akshare",
      api_path: "/api/verticals/investment/data/akshare",
      description: "A-share quote proxy via akshare (Shanghai + Shenzhen). 60 s cache.",
    },
  ],

  // 5 projects: 3 deliberation projects + 2 chathub-eligible (chat-* convention per 08 §4.1)
  default_project_filter: {
    project_id_in: [
      "investment-equity-research"   as ProjectId,
      "investment-due-diligence"     as ProjectId,
      "investment-portfolio-review"  as ProjectId,
      "chat-equity-analyst"          as ProjectId,
      "chat-financial-advisor"       as ProjectId,
    ],
  },

  i18n: { zh, en },

  default_route: "/investment/market-watch",
};

export default manifest;
```

---

## §4 Permissions

```python
# packages/verticals/investment/src/entelecheia_vertical_investment/api/permissions.py

from entelecheia_platform_shell.types import PermissionDeclaration

PERMISSIONS: list[PermissionDeclaration] = [
    PermissionDeclaration(
        code="investment:market_watch",
        description="View market quotes and the Market Watch tab.",
    ),
    PermissionDeclaration(
        code="investment:portfolio",
        description="View and edit the portfolio tab.",
    ),
    PermissionDeclaration(
        code="investment:upload_financial_report",
        description="Upload financial reports (10-K, 10-Q, annual reports).",
    ),
    PermissionDeclaration(
        code="investment:upload_business_plan",
        description="Upload business plans (BP / pitch deck PDFs).",
    ),
    PermissionDeclaration(
        code="investment:open_meeting",
        description="Required (in addition to platform:run_meeting) to start an investment-vertical meeting.",
    ),
]
```

Per the rename + boot dance (per `13` §9), apps/api registers all 5 with auth-service at boot. Standard "investment user" grant set is all 5; admin tooling can split (e.g., grant `market_watch` + `portfolio` to read-only users).

---

## §5 Tabs

### 5.1 `<MarketWatchTab>` (行情)

```tsx
// packages/verticals/investment/frontend/src/components/tabs/MarketWatchTab.tsx
import { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { useToast } from "@entelecheia/platform-shell";
import { useMarketWatchStore } from "../../stores/marketWatchStore";
import { useYahooQuotes } from "../../hooks/useYahooQuotes";
import { useAkshareQuotes } from "../../hooks/useAkshareQuotes";
import { QuoteRow } from "../shared/QuoteRow";

export interface QuoteRowData {
  symbol:     string;
  source:     "yahoo" | "akshare";
  price:      number;
  change:     number;
  change_pct: number;
  volume:     number;
  ts:         string;        // ISO; last update
  error:      string | null; // per-row fetch error
}

export default function MarketWatchTab() {
  const { t } = useTranslation();
  const { push: pushToast } = useToast();
  const watchlist = useMarketWatchStore(s => s.watchlist);
  const addSymbol = useMarketWatchStore(s => s.add);
  const removeSymbol = useMarketWatchStore(s => s.remove);
  const [autoRefresh, setAutoRefresh] = useState(true);

  const yahooSymbols = useMemo(
    () => watchlist.filter(w => w.source === "yahoo").map(w => w.symbol),
    [watchlist],
  );
  const akshareSymbols = useMemo(
    () => watchlist.filter(w => w.source === "akshare").map(w => w.symbol),
    [watchlist],
  );

  const yahoo   = useYahooQuotes(yahooSymbols,   { intervalMs: autoRefresh ? 30_000 : 0 });
  const akshare = useAkshareQuotes(akshareSymbols, { intervalMs: autoRefresh ? 30_000 : 0 });

  const rows = useMemo(() => mergeAndSort([...yahoo.quotes, ...akshare.quotes]), [yahoo.quotes, akshare.quotes]);

  // Component renders:
  //   - SymbolPicker (search + add)
  //   - watchlist <table> with QuoteRow[] (sortable by symbol / change_pct / volume)
  //   - Auto-refresh toggle (30 s default) + Refresh button (calls yahoo.refresh + akshare.refresh)
  //   - Per-row "Remove from watchlist" action
  //   - Per-row "Add to portfolio" → prefills PortfolioTab via portfolioStore.openAddDialog(...)
  //   - Empty state when watchlist is empty (CTA: "Add a symbol")
  //   - Per-source error banner ("Yahoo feed unavailable") when one side errored
  return (/* ... */);
}
```

**State.** `useMarketWatchStore()` (Zustand, in-memory v0.1) holds watchlist `{symbol, source}[]` plus `add/remove/clear` actions. Watchlist persists for the SESSION; reload starts empty (v0.2 may persist via `UserPreferences.extras`).

**Data fetch (`useYahooQuotes`).** Standalone hook so the polling + abort discipline lives outside the component:

```typescript
// hooks/useYahooQuotes.ts
import { useEffect, useRef, useState } from "react";

export function useYahooQuotes(symbols: string[], opts: { intervalMs: number }) {
  const [quotes, setQuotes] = useState<QuoteRowData[]>([]);
  const [error, setError]   = useState<string | null>(null);
  const ctrlRef = useRef<AbortController | null>(null);

  async function fetchOnce() {
    if (symbols.length === 0) { setQuotes([]); return; }
    ctrlRef.current?.abort();
    const ctrl = new AbortController();
    ctrlRef.current = ctrl;
    try {
      const res = await fetch(`/api/verticals/investment/data/yahoo/quotes?symbols=${symbols.join(",")}`, { signal: ctrl.signal });
      const body = await res.json();
      if (body.error) { setError(body.error); return; }
      setQuotes(body.quotes.map((q: any) => ({ ...q, source: "yahoo", error: null })));
      setError(null);
    } catch (e: any) {
      if (e.name === "AbortError") return;
      setError("upstream_unavailable");
    }
  }

  useEffect(() => {
    void fetchOnce();
    if (opts.intervalMs <= 0) return;
    const id = setInterval(fetchOnce, opts.intervalMs);
    return () => { clearInterval(id); ctrlRef.current?.abort(); };
  }, [symbols.join(","), opts.intervalMs]);

  return { quotes, error, refresh: fetchOnce };
}
```

`useAkshareQuotes` mirrors this shape against the akshare endpoint.

**Errors per source.** If yahoo returns 502 (upstream error), `yahoo.error === "upstream_unavailable"` and yahoo rows render with the cached values + a banner; akshare rows still render. Inverse if akshare fails.

**Test rows.**

| scenario | expected | test_id |
|---|---|---|
| empty watchlist | empty state visible | `t_mw_empty` |
| add symbol via picker | row appears with quote | `t_mw_add_symbol` |
| auto-refresh ticks | every 30 s row updates | `t_mw_auto_refresh` |
| toggle auto-refresh off | interval cleared; manual refresh still works | `t_mw_auto_refresh_off` |
| yahoo 502 | yahoo banner shown; akshare rows OK | `t_mw_yahoo_partial_fail` |
| sort by change_pct | rows reorder | `t_mw_sort` |
| add-to-portfolio | clicking opens portfolio Add dialog prefilled | `t_mw_to_portfolio` |
| remove from watchlist | row removed; persists in store | `t_mw_remove` |
| unmount aborts in-flight fetches | switching tabs mid-poll | no console "set state on unmounted" warning | `t_mw_unmount_abort` |

### 5.2 `<PortfolioTab>` (持仓)

```tsx
// PortfolioTab.tsx
import { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { usePortfolioStore } from "../../stores/portfolioStore";
import { useYahooQuotes } from "../../hooks/useYahooQuotes";
import { useAkshareQuotes } from "../../hooks/useAkshareQuotes";

export interface Holding {
  symbol:   string;
  source:   "yahoo" | "akshare";
  shares:   number;
  avg_cost: number;            // per share
  added_at: string;
}

export interface ComputedHolding extends Holding {
  current_price: number | null;
  market_value:  number | null;
  pnl:           number | null;
  pnl_pct:       number | null;
  error:         string | null;
}

export default function PortfolioTab() {
  const { t } = useTranslation();
  const holdings = usePortfolioStore(s => s.holdings);
  // ... (compute via hooks; render table; modal for Add; confirm for Remove)
  return (/* ... */);
}
```

**Renders.**
- Header: total portfolio value + day's P&L pill (green/red, via `<PnLBadge>`).
- Holdings table: symbol / shares / avg cost / current price / market value / P&L / P&L %.
- "Add holding" button → modal (native `<dialog>` + focus-trap-react per 05/08/09/10/11 standard pattern) with symbol picker + shares + avg-cost inputs.
- "Remove" per row (with confirm dialog, same modal primitive).
- "Import from CSV" — paste CSV with `symbol,shares,avg_cost` per line; client-side parse; appends to store.
- Empty state with "Add your first holding" CTA.

**Data.** `usePortfolioStore()` holds holdings in memory (per session). Quotes are fetched via the same `useYahooQuotes` / `useAkshareQuotes` hooks as MarketWatchTab; computed P&L is derived in a `useMemo`.

**v0.2 hooks documented.** `UserPreferences.extras.investment.portfolio` could persist holdings; `UserPreferences.extras.investment.broker_credentials` could enable broker integration.

**Test rows.**

| scenario | expected | test_id |
|---|---|---|
| empty portfolio | empty state visible | `t_pf_empty` |
| add holding manually | row appears; computed P&L correct | `t_pf_add_manual` |
| import CSV happy | 5 rows parsed, all added | `t_pf_csv_import` |
| import CSV malformed | toast error; no rows added | `t_pf_csv_malformed` |
| quote unavailable | row shows "—" for price/PnL with error tooltip | `t_pf_quote_missing` |
| total computes correctly | sum of market_values matches displayed total | `t_pf_total_compute` |
| remove with confirm | removed | `t_pf_remove` |

---

## §6 Widget — `<MarketSummaryWidget>`

```tsx
// MarketSummaryWidget.tsx
import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";
import { useYahooQuotes } from "../../hooks/useYahooQuotes";
import { useAkshareQuotes } from "../../hooks/useAkshareQuotes";

const indices = [
  { symbol: "^GSPC",    source: "yahoo",   label: "S&P 500" },
  { symbol: "^IXIC",    source: "yahoo",   label: "NASDAQ" },
  { symbol: "000001.SS", source: "akshare", label: "上证指数" },
] as const;

export default function MarketSummaryWidget() {
  const { t } = useTranslation();
  const navigate = useNavigate();

  const yahoo   = useYahooQuotes(["^GSPC", "^IXIC"], { intervalMs: 60_000 });
  const akshare = useAkshareQuotes(["000001.SS"],     { intervalMs: 60_000 });

  // Renders 3 compact QuoteRows (or "Data unavailable" if both feeds error).
  // Clicking an index navigates to /investment/market-watch with the symbol prefilled
  // via search params: navigate(`/investment/market-watch?prefill=${sym}&source=${src}`).
  return (/* ... */);
}
```

**Test rows.**

| scenario | expected | test_id |
|---|---|---|
| renders 3 indices | 3 QuoteRows visible | `t_ms_render` |
| auto-refresh 60 s | values update | `t_ms_refresh` |
| click index | navigate to /investment/market-watch?prefill=…&source=… | `t_ms_click` |
| degraded if all feeds down | placeholder "Data unavailable" | `t_ms_degraded` |

---

## §7 Upload handlers

### 7.1 `<FinancialReportHandler>`

Renders after a user uploads a `.pdf` or `.xlsx` matching the `investment:financial-report` kind.

```tsx
// FinancialReportHandler.tsx
import { useState, useEffect } from "react";
import { useTranslation } from "react-i18next";
import type { Upload } from "@entelecheia/uploads";

export interface FinancialReportHandlerProps {
  upload: Upload;
  onConfirm: (upload_id: string, normalized: { company?: string; period?: string }) => void;
  onCancel: () => void;
}

export default function FinancialReportHandler({ upload, onConfirm, onCancel }: FinancialReportHandlerProps) {
  const { t } = useTranslation();
  const initial = useMemo(() => extractFromFilename(upload.display_name), [upload.display_name]);
  const [company, setCompany] = useState(initial.company ?? "");
  const [period,  setPeriod]  = useState(initial.period  ?? "");

  // Heuristic extraction: filename matching e.g. "AAPL-10K-2024Q4.pdf"
  //   → company="AAPL", period="2024Q4"
  // User can edit the extracted values before confirming.
  // Server-side parsing happens at the upload endpoint (§7.2 backend).
  return (/* ... */);
}

function extractFromFilename(name: string): { company?: string; period?: string } {
  const m = /^([A-Z0-9.]+)[-_]?(10[KQ])?[-_]?(\d{4}(?:Q[1-4])?)/i.exec(name);
  if (!m) return {};
  return { company: m[1], period: m[3] };
}
```

**Test rows.**

| scenario | expected | test_id |
|---|---|---|
| filename heuristic | "AAPL-10K-2024Q4.pdf" → fields prefilled | `t_fh_filename_extract` |
| user edits | manual override works | `t_fh_manual_edit` |
| confirm | calls onConfirm with normalized | `t_fh_confirm` |
| xlsx accepted | shows parsed sheet preview (first 10 rows) | `t_fh_xlsx_preview` |
| cancel | calls onCancel | `t_fh_cancel` |

### 7.2 Backend: `uploads_financial.py`

```python
# packages/verticals/investment/src/entelecheia_vertical_investment/api/routers/uploads_financial.py
from fastapi import APIRouter, Depends, UploadFile
from entelecheia_auth.deps import require_auth, CurrentAuthContext
from entelecheia_platform_shell.permissions import require_permission

financial_upload_router = APIRouter(
    prefix="/api/verticals/investment/upload",
    tags=["investment"],
)


@financial_upload_router.post("/financial-report")
async def upload_financial_report(
    file: UploadFile,
    company: str | None = None,
    period: str | None = None,
    ctx: CurrentAuthContext = Depends(require_auth),
    _perm = Depends(require_permission("investment:upload_financial_report")),
) -> dict:
    """Custom upload endpoint for financial reports.

    Server-side validation:
      - File MIME validated as application/pdf or .xlsx
      - PDF: extract text via pdfminer; reject if encrypted (loud failure)
      - XLSX: parse with openpyxl; extract sheet names + first 10 rows of each;
        produce a structured summary the agent can read.

    Returns { material: { kind, name, content }, metadata: { company, period, ... } }
    that wizard inlines into the studio.run_meeting() Material array.
    """
    # ... (validate, parse, return)
    return {"ok": True}
```

### 7.3 `<BusinessPlanHandler>` + backend

Symmetric to financial report; accepts `.pdf` and `.docx`. Endpoint at `/api/verticals/investment/upload/business-plan`. PDF / DOCX parsed via pdfminer / python-docx. Heuristic filename extract: company name from leading word. No special parsing beyond text extraction.

---

## §8 Data feeds

### 8.1 Yahoo Finance proxy

```python
# packages/verticals/investment/src/entelecheia_vertical_investment/api/routers/data_yahoo.py
from fastapi import APIRouter, Depends, Query
from entelecheia_auth.deps import require_auth, CurrentAuthContext
from entelecheia_platform_shell.permissions import require_permission
from ..data_sources.yahoo_client import yahoo_get_quotes

yahoo_router = APIRouter(prefix="/api/verticals/investment/data/yahoo", tags=["investment"])


@yahoo_router.get("/quotes")
async def get_yahoo_quotes(
    symbols: str = Query(..., description="Comma-separated symbol list, e.g. 'AAPL,MSFT,^GSPC'"),
    ctx: CurrentAuthContext = Depends(require_auth),
    _perm = Depends(require_permission("investment:market_watch")),
) -> dict:
    """Quote proxy. 30 s in-memory cache. Returns:
        { quotes: [{ symbol, price, change, change_pct, volume, currency, ts }] }
    """
    sym_list = [s.strip() for s in symbols.split(",") if s.strip()]
    if not sym_list:
        return {"quotes": []}
    if len(sym_list) > 50:                       # cap
        return {"quotes": [], "error": "too_many_symbols", "max": 50}
    quotes = await yahoo_get_quotes(sym_list)    # cached
    return {"quotes": quotes}
```

**`yahoo_client.py`** wraps Yahoo's public quote API via httpx. 30 s cache (in-memory dict keyed by symbol; expires per entry). Rate limit: 100 requests/min per process (Yahoo's documented limit). On rate-limit hit: return cached values + `stale: true` flag. On upstream 5xx: return cached values + `stale: true` + `error: "upstream_unavailable"`.

**Why proxy (not direct browser fetch).** API key security (when keyed); CORS bypass; centralized caching; consistent error envelope.

### 8.2 Akshare proxy

```python
# data_akshare.py
from fastapi import APIRouter, Depends, Query
from entelecheia_auth.deps import require_auth, CurrentAuthContext
from entelecheia_platform_shell.permissions import require_permission
from ..data_sources.akshare_client import akshare_get_quotes

akshare_router = APIRouter(prefix="/api/verticals/investment/data/akshare", tags=["investment"])


@akshare_router.get("/quotes")
async def get_akshare_quotes(
    symbols: str = Query(..., description="Comma-separated A-share symbols, e.g. '600519,000858,300750'"),
    ctx: CurrentAuthContext = Depends(require_auth),
    _perm = Depends(require_permission("investment:market_watch")),
) -> dict:
    """A-share quote proxy. 60 s cache. Symbol format: 6-digit code (no .SH/.SZ
    suffix; akshare disambiguates). Returns same shape as yahoo with currency=CNY."""
    # ... (cap, fetch, return)
    return {"quotes": []}
```

**Why akshare.** Pure-Python A-share data library; no API key; covers Shanghai + Shenzhen + indices. Slower than yahoo (~500 ms-2 s per call); cache is more important.

**Test matrix (data feeds).**

| scenario | expected | test_id |
|---|---|---|
| yahoo happy | list of QuoteRow returned | `t_dy_happy` |
| yahoo cache hit | second call within 30 s returns cached without upstream | `t_dy_cache` |
| yahoo upstream 5xx | returns cached + stale=true + error | `t_dy_upstream_fail` |
| yahoo > 50 symbols | 200 with `error: "too_many_symbols"` | `t_dy_too_many` |
| akshare happy | A-share quotes returned with currency=CNY | `t_da_happy` |
| akshare cache hit | second call within 60 s cached | `t_da_cache` |
| permission denied | user without investment:market_watch | 403 | `t_dy_perm` |

---

## §9 Report templates

### 9.1 Investment Summary (`investment:summary`)

```python
# packages/verticals/investment/src/entelecheia_vertical_investment/api/report_templates/investment_summary.py
from entelecheia_studio_client.dto.reports import ReportTemplate, ReportSection

investment_summary_template = ReportTemplate(
    template_id="investment:summary",
    name="Investment Summary",
    description="Concise investment thesis + key facts + recommendation. Suitable for partner review.",
    formats=["pdf", "word", "markdown"],
    declared_by="investment",
    sections=[
        ReportSection(section_id="meta",            heading_key="vertical.investment.report.section.meta",
                      source_field="meta",          visualization="paragraph", filter=None),
        ReportSection(section_id="key_facts",       heading_key="vertical.investment.report.section.key_facts",
                      source_field="key_facts",     visualization="list",      filter=None),
        ReportSection(section_id="consensus",       heading_key="vertical.investment.report.section.thesis",
                      source_field="consensus",     visualization="list",      filter=None),
        ReportSection(section_id="open_questions",  heading_key="vertical.investment.report.section.open_questions",
                      source_field="open_questions", visualization="list",     filter=None),
    ],
)
```

### 9.2 Due Diligence (`investment:due_diligence`)

```python
due_diligence_template = ReportTemplate(
    template_id="investment:due_diligence",
    name="Due Diligence Report",
    description="Long-form DD report with executive summary, business overview, financial analysis, risks, and recommendation. PDF + Word only.",
    formats=["pdf", "word"],
    declared_by="investment",
    sections=[
        ReportSection(section_id="meta",            heading_key="vertical.investment.report.section.meta",
                      source_field="meta",          visualization="paragraph", filter=None),
        ReportSection(section_id="executive_summary", heading_key="vertical.investment.report.section.exec_summary",
                      source_field="consensus",     visualization="paragraph", filter=None),
        ReportSection(section_id="key_facts",       heading_key="vertical.investment.report.section.key_facts",
                      source_field="key_facts",     visualization="table",     filter=None),
        ReportSection(section_id="risks",           heading_key="vertical.investment.report.section.risks",
                      source_field="unresolved_disagreements",
                      visualization="list",         filter=None),
        ReportSection(section_id="open_questions",  heading_key="vertical.investment.report.section.open_questions",
                      source_field="open_questions", visualization="list",     filter=None),
        ReportSection(section_id="constraints",     heading_key="vertical.investment.report.section.constraints",
                      source_field="final_constraints_status",
                      visualization="table",        filter=None),
    ],
)
```

Both templates registered with apps/api at boot (per `06` §6.3); appear in `<TemplatePicker>` when investment vertical is active alongside platform defaults.

---

## §10 Fixture overlay

### 10.1 `fixture_overlay/projects.yaml`

5 ProjectSpecs covering deliberation + chat use cases. All `published`.

```yaml
- spec_kind: project
  schema_version: v0.1
  spec_id: investment-equity-research
  version: 1
  status: published
  created_at: "2026-01-10T00:00:00Z"
  updated_at: "2026-04-20T00:00:00Z"
  created_by: investment-pm
  description: "Multi-agent equity research deliberation. Reviews company fundamentals + competitive position + thesis pros and cons."
  agents:
    - {agent_id: "agent-fundamentals", version: 1, enabled: true}
    - {agent_id: "agent-thesis-pro",   version: 1, enabled: true}
    - {agent_id: "agent-thesis-con",   version: 1, enabled: true}
  engine_extensions:
    conclude_predicates:
      - {type: "builtin.max_turns", params: {max_turns: 30}}
    constraints: []
    speaker_selector: {type: "builtin.round_robin", params: {}}
    phase_machine:    {type: "builtin.linear", params: {phases: ["fundamentals", "competitive", "thesis", "synthesize"]}}
  meeting_defaults: {max_turns: 30, language: en}
  skill_overrides: {}

- spec_kind: project
  spec_id: investment-due-diligence
  version: 1
  status: published
  description: "Formal due diligence deliberation. Examines company, market, financials, risks, and produces structured DD report."
  agents:
    - {agent_id: "agent-business-analyst", version: 1, enabled: true}
    - {agent_id: "agent-financial-analyst", version: 1, enabled: true}
    - {agent_id: "agent-risk-reviewer", version: 1, enabled: true}
  # ... (similar engine_extensions, max_turns: 50, phases reflect DD structure)

- spec_kind: project
  spec_id: investment-portfolio-review
  version: 1
  status: published
  description: "Portfolio-level review. Discusses sector concentration, position sizing, rebalancing recommendations."
  # ... (3 agents: macro, allocation, risk)

- spec_kind: project
  spec_id: chat-equity-analyst                        # chathub-eligible (chat-* convention per 08 §4)
  version: 1
  status: published
  description: "1:1 chat with an equity analyst persona. Single-agent react paradigm."
  agents:
    - {agent_id: "agent-equity-analyst", version: 1, enabled: true}
  engine_extensions:
    conclude_predicates:
      - {type: "builtin.max_turns", params: {max_turns: 5}}        # short, since each chat turn = 1 meeting per 08 §3
    constraints: []
    speaker_selector: {type: "builtin.round_robin", params: {}}
    phase_machine:    {type: "builtin.linear", params: {phases: ["respond"]}}
  meeting_defaults: {max_turns: 5, language: en}

- spec_kind: project
  spec_id: chat-financial-advisor                     # chathub-eligible
  version: 1
  status: published
  description: "1:1 chat with a financial advisor persona. Single-agent react."
  # ... (similar shape)
```

### 10.2 `fixture_overlay/meeting_templates.yaml`

5 meeting_templates (one per project), with realistic event scripts. Each script demonstrates events that exercise agora's reducers (per `01b`):

```yaml
- template_id: tmpl_investment_equity_research
  match_rule:
    project_id_in: ["investment-equity-research"]
    topic_keywords_any_of: ["*"]
  initial_status: running
  events:
    - {at_offset_ms: 0,    event_type: MeetingStarted,    data: {paradigm: "round_robin"}}
    - {at_offset_ms: 200,  event_type: RootQuestionPosed, data: {question: "<topic>"}}
    - {at_offset_ms: 1500, event_type: ClaimMade,         data: {claim_id: "f1", asserted_by: "agent-fundamentals", content: "Revenue grew 18% YoY in the most recent quarter, beating consensus by 4%."}}
    - {at_offset_ms: 3000, event_type: EvidenceCited,     data: {claim_id: "f1", source_kind: "material", excerpt: "Q4 2024 10-K", relation: "supports"}}
    - {at_offset_ms: 4500, event_type: ClaimMade,         data: {claim_id: "t1", asserted_by: "agent-thesis-pro", content: "Strong demand signals support a continued growth thesis."}}
    - {at_offset_ms: 6000, event_type: ChallengeRaised,   data: {claim_id: "t1", by: "agent-thesis-con", content: "Demand may be pulled forward; risk of mean reversion."}}
    - {at_offset_ms: 9000, event_type: ConsensusReached,  data: {claim_ids: ["f1"], confidence: 0.85}}
    - {at_offset_ms: 12000, event_type: MeetingFrozen,    data: {}}
    - {at_offset_ms: 12100, event_type: meeting_finalized, data: {outcome_ref: "tmpl_investment_equity_research"}}

- template_id: tmpl_investment_due_diligence
  # ... (longer script: ~60 s with more claims + challenges across 50 turns)

- template_id: tmpl_investment_portfolio_review
  # ... (~40 s, 30 turns)

- template_id: tmpl_chat_equity_analyst
  match_rule:
    project_id_in: ["chat-equity-analyst"]
    topic_keywords_any_of: ["*"]
  initial_status: running
  events:
    # Single-agent chat; each chat turn = a new short meeting per 08 §3.
    # Script is ONE turn: agent reads the topic-prepended history + responds.
    - {at_offset_ms: 0,    event_type: MeetingStarted,    data: {paradigm: "react"}}
    - {at_offset_ms: 500,  event_type: MessageEmitted,    data: {agent_id: "agent-equity-analyst", content: "Based on the question, here's my analysis…"}}
    - {at_offset_ms: 2000, event_type: MeetingFrozen,     data: {}}
    - {at_offset_ms: 2100, event_type: meeting_finalized, data: {outcome_ref: "tmpl_chat_equity_analyst"}}

- template_id: tmpl_chat_financial_advisor
  # ... (similar single-turn script)
```

### 10.3 `fixture_overlay/outcomes.yaml`

5 outcomes corresponding to the 5 meeting_templates. Each provides realistic `consensus`, `key_facts`, `unresolved_disagreements`, etc., consistent with the meeting script. (Sample shown for one; remaining follow same structure.)

```yaml
- outcome_ref: tmpl_investment_equity_research
  outcome:
    meeting_id: "<runtime>"
    concluded_by: consensus_reached
    consensus:
      - claim_id: f1
        content: "Revenue grew 18% YoY in the most recent quarter, beating consensus by 4%."
        confidence: 0.85
    unresolved_disagreements:
      - claim_id_a: t1
        position_a: "Strong demand signals support a continued growth thesis."
        position_b: "Demand may be pulled forward; risk of mean reversion."
        agents_for_a: ["agent-thesis-pro"]
        agents_for_b: ["agent-thesis-con"]
    key_facts:
      - statement: "Q4 2024 revenue beat consensus by 4%."
        evidence: [{kind: "material", excerpt: "Q4 2024 10-K"}]
    open_questions:
      - "What is the sustainability of demand into Q1 2025?"
    started_at: "<runtime>"
    concluded_at: "<runtime>"
    total_turns: 8
    final_constraints_status: []
    merkle_root: "0000000000000000000000000000000000000000000000000000000000000000"
```

---

## §11 i18n bundle

```json
// packages/verticals/investment/frontend/src/i18n/en.json
{
  "tab.market_watch":                                   "Market Watch",
  "tab.portfolio":                                      "Portfolio",

  "widget.market_summary.title":                        "Market Summary",
  "widget.market_summary.unavailable":                  "Market data unavailable.",

  "upload.financial_report":                            "Financial Report (.pdf, .xlsx)",
  "upload.business_plan":                               "Business Plan (.pdf, .docx)",

  "page.market_watch.heading":                          "Market Watch",
  "page.market_watch.empty":                            "Your watchlist is empty.",
  "page.market_watch.add_symbol":                       "Add a symbol",
  "page.market_watch.refresh":                          "Refresh",
  "page.market_watch.auto_refresh":                     "Auto-refresh every 30 s",
  "page.market_watch.col.symbol":                       "Symbol",
  "page.market_watch.col.price":                        "Price",
  "page.market_watch.col.change":                       "Change",
  "page.market_watch.col.change_pct":                   "%",
  "page.market_watch.col.volume":                       "Volume",
  "page.market_watch.row.add_to_portfolio":             "Add to portfolio",
  "page.market_watch.row.remove":                       "Remove",
  "page.market_watch.row.error":                        "Quote unavailable",
  "page.market_watch.fetch_error":                      "{{source}} feed unavailable.",

  "page.portfolio.heading":                             "Portfolio",
  "page.portfolio.empty":                               "No holdings yet.",
  "page.portfolio.add_holding":                         "Add holding",
  "page.portfolio.import_csv":                          "Import from CSV",
  "page.portfolio.import_csv.placeholder":              "symbol,shares,avg_cost (one per line)",
  "page.portfolio.import_csv.parse_error":              "Could not parse CSV at line {{line}}.",
  "page.portfolio.col.symbol":                          "Symbol",
  "page.portfolio.col.shares":                          "Shares",
  "page.portfolio.col.avg_cost":                        "Avg cost",
  "page.portfolio.col.current":                         "Current",
  "page.portfolio.col.value":                           "Market value",
  "page.portfolio.col.pnl":                             "P&L",
  "page.portfolio.col.pnl_pct":                         "P&L %",
  "page.portfolio.summary.total":                       "Total: {{amount}}",
  "page.portfolio.summary.day_pnl":                     "Day P&L: {{amount}} ({{pct}})",

  "report.section.meta":                                "Meeting Information",
  "report.section.thesis":                              "Investment Thesis",
  "report.section.exec_summary":                        "Executive Summary",
  "report.section.key_facts":                           "Key Facts",
  "report.section.risks":                               "Risks & Disagreements",
  "report.section.open_questions":                      "Open Questions",
  "report.section.constraints":                         "Constraints"
}
```

`zh.json` mirrors with Chinese (e.g., `tab.market_watch: "行情"`, `tab.portfolio: "持仓"`, etc.). Interpolation uses `{{var}}` per react-i18next.

---

## §12 Test matrix (vertical-level)

In addition to per-component / per-router test rows above, the vertical has these integration tests:

| scenario | expected | test_id |
|---|---|---|
| Vertical loads at apps/api boot | importlib.metadata finds entry point; manifest validates | `[SUB] t_inv_boot_load` |
| Permissions registered with auth-service | all 5 visible in auth registry | `t_inv_perm_register` |
| Tabs appear in sidebar when active | both visible (gated by their permissions) | `t_inv_tabs_visible` |
| Switching to investment vertical | router lands at /investment/market-watch (default_route) | `t_inv_switch_default_route` |
| Wizard project picker | shows 3 deliberation projects (chat-* hidden from wizard since wizard is for deliberation) | `t_inv_wizard_projects` |
| Chathub agent picker | shows chat-equity-analyst + chat-financial-advisor | `t_inv_chathub_agents` |
| Knowledge browser | lists past meetings filtered to investment projects | `t_inv_knowledge_filter` |
| Reports view | shows investment:summary + investment:due_diligence templates | `t_inv_reports_templates_listed` |
| MaterialsPanel preview for investment-handler upload | UploadPreviewOverlay opens with PDF / xlsx renderer | `t_inv_materials_preview` |
| Coexistence with another vertical | both verticals' tabs / fixtures don't collide | `[SUB] t_inv_coexist_with_other` |
| Vertical removed (uninstall package) | apps/api boots without it; rest of platform unaffected | `[SUB] t_inv_remove_isolated` |
| CI purity | scripts/check-purity.sh exits 0 with this vertical present (it lives under packages/verticals/, allowed for business words) | `t_inv_purity_pass` |

---

## §13 Why this design — load-bearing decisions

**Why two tabs (Market Watch + Portfolio), not one combined view.**
Different user mental models. Market Watch is "what's happening RIGHT NOW in the broader market"; Portfolio is "what do I own + how's it doing". Combined view confuses both. Separate tabs let users navigate to each without scrolling past the other.
*Considered and rejected.* **Combined "Markets" tab** — UX confusion.

**Why backend proxies for data feeds (not browser direct fetch).**
1) API key security: even when keyless today, a future yahoo key would need to live server-side.
2) CORS bypass: yahoo + akshare don't issue CORS headers for browser calls.
3) Centralized caching: 30 s/60 s in-memory cache shared across all users in the process.
4) Consistent error envelope: studio-style ErrorBody for upload + agora consistency.
5) Rate-limit handling: server-side hits the limit once and degrades gracefully for everyone.
*Considered and rejected.* **Browser direct fetch via JSONP** — security + caching nightmare.

**Why akshare (vs alternative A-share libraries).**
Pure-Python (no native deps; cleaner install in apps/api). MIT-licensed. Wide A-share coverage. Active maintenance. Slower than commercial APIs but free + sufficient for v0.1 portfolio review use case.
*Considered and rejected.* **Wind / Bloomberg APIs** — paid + complex integration. **Tushare** — requires registration token; v0.2 may add as alternative.

**Why portfolio is in-memory v0.1 (not persisted).**
Persisting holdings introduces account-data ownership concerns (what if user wants to delete? export? share?). v0.1 ships read-only manual entry; v0.2 may persist via `UserPreferences.extras.investment.portfolio` once the persistence model is clear. Documented hook ensures the v0.2 transition is additive.
*Considered and rejected.* **Persist to user-service from v0.1** — introduces data-ownership complexity prematurely.

**Why filename heuristic for financial-report metadata extraction (not pure server-side parsing).**
Filename is what the user sees + edits naturally; an "AAPL-10K-2024Q4.pdf" naming pattern is widespread in finance. Heuristic prefills the form; user can override before confirming. Server-side parsing of arbitrary financial PDFs is hard (variable layouts) and out of v0.1 scope.
*Considered and rejected.* **No metadata extraction** — extra typing for users with naming-convention PDFs.

**Why chat-equity-analyst + chat-financial-advisor are listed in default_project_filter (not auto-discovered by chat-* convention).**
Chathub's `useChatAgents()` filters by BOTH (a) `spec_id.startsWith("chat-")` convention AND (b) project is in active vertical's `project_id_in` allowlist (per `08` §4.1). The vertical must explicitly list chat projects in its allowlist; this is a deliberate "verticals own their chathub agent set" decision. Otherwise any vertical's chat would surface in any other vertical, breaking the per-vertical chathub experience.
*Considered and rejected.* **Auto-discover all chat-* projects regardless of vertical** — cross-vertical leak.

**Why investment vertical demonstrates BOTH deliberation projects + chathub projects.**
Real users want both: 1:1 chat with an equity analyst for quick questions; full multi-agent deliberation for serious thesis review. The vertical is incomplete without both. This also exercises the platform-wide chathub feature (per 08) end-to-end with a concrete vertical.
*Considered and rejected.* **Deliberation-only or chat-only** — incomplete demonstration of the platform.

**Why DD template is "PDF + Word" (not "Markdown" too).**
Due diligence reports are typically reviewed in PDF and edited in Word. Markdown is a developer-flavored format that DD reviewers don't use. Trimming Markdown from the formats list is a deliberate UX choice; users picking the DD template see only PDF + Word in the FormatPicker (per `06` §4.3 the picker filters by template's formats).
*Considered and rejected.* **Markdown for DD too** — bloats the format options for a use case nobody asks for.

**Why two report templates (investment:summary + investment:due_diligence) for v0.1.**
Different review contexts — the summary is for quick partner sign-off (1-page); the DD is for formal investment committee. Two templates cover the 80% use cases without proliferation. Custom templates v0.2.
*Considered and rejected.* **Single mega-template** — UX confusion for users picking. **Many templates** — analysis paralysis.

**Why hooks (`useYahooQuotes` / `useAkshareQuotes`) own polling + AbortController, not components.**
React function components re-render every state change; lifting the polling timer + abort discipline into a hook keeps the component body declarative and ensures cleanup happens once per hook instance. The hook's `useEffect` returns a teardown that clears the interval and aborts any in-flight request — covered by `t_mw_unmount_abort`.
*Considered and rejected.* **Inline `useEffect` in each tab** — duplicate cleanup logic per tab; bug-prone. **Global polling singleton** — can't easily express "stop polling when tab unmounts."

---

## §14 Downstream impact

| Spec | Adjustment |
|---|---|
| `01-studio-client-spec.md` | The 5 ProjectSpecs in fixture_overlay/projects.yaml become available to PseudoStudioClient; substitution tests t_inv_boot_load + t_inv_coexist_with_other + t_inv_remove_isolated cover the studio-client integration. |
| `06-feature-reports-spec.md` | The 2 report templates land in the registry; `<TemplatePicker>` shows them when investment vertical is active. Per 06's mechanism — no spec change needed. |
| `08-feature-chathub-spec.md` | Chat-equity-analyst + chat-financial-advisor are 2 chat-eligible projects; chathub agent picker surfaces them when investment vertical is active. |
| `09-feature-uploads-spec.md` | The 2 vertical handlers register via the standard mechanism; HandlerPicker shows them above platform built-ins. No spec change. |
| `13-vertical-template-spec.md` | This spec is the proof that the template structure works for a real vertical. If 13 evolves (e.g., adds a contribution type in v0.2), 14 is the canary that shows the addition is real. |
| `15-apps-api-spec.md` | Boot dance discovers entelecheia-vertical-investment via entry point; merges fixture overlay; registers permissions; mounts 4 routers under /api/verticals/investment/*. |
| `17-substitution-tests-spec.md` | The 3 `[SUB]` test_ids in §12 join 17's category 4 (vertical isolation) suite. |
| `18-end-to-end-scenarios-spec.md` | Several e2e scenarios (login → switch to investment → run equity-research meeting → view report → ...) use this vertical end-to-end. |

---

## §15 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (real-time WebSocket, persisted portfolio, advanced charting, broker integration, sectors, multi-currency, news, earnings calendar)
- [ ] Module layout (§1) shows deltas vs `_template` (data_sources subdir, shared frontend subdir, 2 stores, hooks subdir)
- [ ] Backend manifest (§2) declares 4 routers + 5 permissions + fixture_overlay="investment" + 2 report_templates
- [ ] pyproject.toml entry point key matches manifest.vertical_id
- [ ] Frontend manifest (§3) declares 2 tabs + 1 widget + 2 upload handlers + 2 data feeds + 5-element project_id_in (3 deliberation + 2 chat) + i18n + accent_color + default_route; `icon` is `lucide-react` component reference; every `component` field is `React.ComponentType`
- [ ] 5 permissions (§4) all under `investment:*` namespace; descriptions clear
- [ ] 2 tabs (§5): MarketWatchTab + PortfolioTab — `.tsx`, props/callbacks, Zustand state, polling via dedicated hooks with AbortController cleanup
- [ ] 1 widget (§6): MarketSummaryWidget renders 3 indices with auto-refresh; uses `useNavigate()` not router.push
- [ ] 2 upload handlers (§7) frontend (`.tsx`, props shape: `{upload, onConfirm, onCancel}`) + backend with filename heuristic + structured parse
- [ ] 2 data feeds (§8) with caching (30 s yahoo / 60 s akshare) + rate limit + permission gate
- [ ] 2 report templates (§9) with proper template_id prefix + declared_by
- [ ] Fixture overlay (§10): 5 projects (3 deliberation + 2 chat-*), 5 meeting_templates with realistic event scripts (covering ClaimMade / EvidenceCited / ChallengeRaised / ConsensusReached / MessageEmitted / meeting_finalized — exercising agora's reducers per 01b), 5 outcomes
- [ ] i18n bundles (§11) cover every user-visible string (tab labels / widget / upload / both pages' content / report sections); zh + en mirrored; uses `{{var}}` interpolation
- [ ] Test matrix (§12) covers vertical-level integration tests (boot, perms, tabs visible, switcher, wizard, chathub, knowledge, reports, materials preview, coexistence, removal, purity); 3 marked `[SUB]`
- [ ] Why-this / why-not (§13) for ≥ 9 load-bearing decisions
- [ ] Downstream impact (§14) lists every spec affected
- [ ] No engine import (Red Line #1) — vertical only imports from platform-shell + studio-client + standard libs
- [ ] No cross-vertical import (Red Line #4)
- [ ] No platform code modification (Red Line #3)
- [ ] No direct studio HTTP call (Red Line #2) — only via studio-client
- [ ] No agent / paradigm / skill logic in vertical (Red Line #5) — only references `agent_id`s + `project_id`s as opaque strings
- [ ] No Vue-only artifacts (`<template>`, `defineProps`, `defineEmits`, `useI18n` from vue-i18n, `Pinia`, `lucide-vue-next`)
- [ ] Domain vocabulary (investment, financial-report, due-diligence, yahoo-finance, akshare) used freely INSIDE this vertical's package per the philosophy skill's allowlist (`packages/verticals/<id>/`)
- [ ] `bash scripts/check-purity.sh` exits 0 (vertical's domain words land outside the scanned platform-* / apps/* paths)
- [ ] File path matches `docs/specs/v0.1/14-vertical-investment-spec.md`
