# 12 — `observability` feature v0.1 spec

> **Status**: v0.1 contract for the observability dashboards feature.
> **Lives at**: `packages/platform-features/observability/`.
> **Consumes**: `01-studio-client-spec.md` §7.6 (`list_meetings`), §7.10 (`get_cost_report`); `02-platform-shell-spec.md` (composables + routing + permissions); `03-auth-service-spec.md` (`platform:view_observability`).
> **Forwarded to from**: `02-platform-shell-spec.md` sidebar nav.

---

## Mission

This file defines the observability feature — the read-only dashboards where users (typically operators / admins) inspect product-wide cost and activity. Three views: **Cost** (overview + breakdown by dimension), **Activity** (meeting counts over time + status mix + top projects), **Errors** (recently-failed meetings + error-type breakdown). All data comes from studio's `get_cost_report` (multi-`group_by`) + `list_meetings`; no new endpoints, no caches that outlive a session, no live updates (refresh button only).

**Hard rule** (P3 + read-only + scope discipline): observability does NOT compute cost or count meetings server-side. Studio's cost ledger is the source of truth (per `01-studio-client-spec.md` §7.10). Product-side aggregation is limited to **client-side group-by + bucketing on already-fetched rows** — no apps/api summarization, no SQLite cache. If queries become heavy at scale (10k+ meetings per query), the right fix is studio-side aggregation parameters in v0.2, not product-side denormalization.

---

## Scope

**Covers.**
- Module layout (frontend feature only; no backend).
- 2 routes: `/platform/observability` (defaults to Cost tab), `/platform/observability/:tab` (direct link to one of `cost`, `activity`, `errors`).
- Top-level `<ObservabilityView>` with 3 tab views: `<CostView>`, `<ActivityView>`, `<ErrorsView>`.
- 3 chart components (Chart.js-backed): `<LineChart>`, `<BarChart>`, `<DonutChart>`.
- Time range picker (4 presets + custom) shared across all 3 views; URL-synced.
- 3 composables: `useCostReportData`, `useMeetingActivity`, `useTimeRange`.
- CSV export of raw rows from any chart.
- Per-view loading / empty / error states with partial-failure tolerance.
- Forward-compat for new studio enum values (`MeetingStatus`, `error_class` strings, `concluded_by`).
- Test matrix per view + per chart + per composable.
- v0.2 path documented: server-side aggregation when client-side scaling hurts; switching never breaks the UI shape.

**Does not cover.**
- Live cost during an active meeting — `01b-product-derivations-spec.md` §5 `useCostState` (consumed by agora's CostPanel per `05-feature-agora-spec.md` §5.5).
- Cost ledger writes — studio-only (per `01` §7.10 read-only).
- Per-vertical breakdowns — possible via `vertical_id` in `get_cost_report` filters, but UI surfacing deferred to v0.2 once the verticalization story matures.
- Per-event-type analytics on the 24 EventType stream — out of v0.1; `total_turns` from outcome + `MessageEmitted` / `ToolCalled` counts (which agora's CostState tracks per-meeting) cover v0.1 needs.
- Email digest of weekly costs.
- Anomaly detection / alert rules.
- Custom saved dashboards / pinned filters.

**Out of scope for v0.1.**
- Real-time updates (dashboards refresh on demand; no SSE subscription).
- Multi-tenant filters (single-tenant per `01` §1.5).
- Drill-down navigation from chart click (would require a "show me meetings matching this slice" join — possible but deferred).
- Alerting (cost > $X / day → notify). Notifications are in-app only and require separate alerting infra.
- Per-agent or per-skill ROI calculations (would require value-side metrics studio doesn't provide).
- Comparison mode (this week vs last week side-by-side).
- Mobile-optimized chart layouts (charts collapse to tables on mobile; no chart re-layout).

---

## §1 Module layout

```
packages/platform-features/observability/
├── src/
│   ├── index.ts                              # exports ObservabilityView + observabilityRoutes
│   ├── ObservabilityView.vue                 # top-level
│   ├── components/
│   │   ├── ObservabilityHeader.vue           # time range picker + refresh button
│   │   ├── ObservabilityTabs.vue             # 3-tab navigation
│   │   ├── TimeRangePicker.vue               # presets + custom range
│   │   ├── ExportButton.vue                  # CSV download
│   │   ├── EmptyState.vue
│   │   ├── views/
│   │   │   ├── CostView.vue                  # tab: cost
│   │   │   ├── ActivityView.vue              # tab: activity
│   │   │   └── ErrorsView.vue                # tab: errors
│   │   ├── charts/
│   │   │   ├── LineChart.vue                 # Chart.js line; for time series
│   │   │   ├── BarChart.vue                  # Chart.js bar; for breakdowns
│   │   │   └── DonutChart.vue                # Chart.js doughnut; for share/mix
│   │   └── tables/
│   │       ├── CostBreakdownTable.vue
│   │       ├── TopProjectsTable.vue
│   │       └── FailedMeetingsTable.vue
│   ├── composables/
│   │   ├── useCostReportData.ts              # wraps studio.get_cost_report
│   │   ├── useMeetingActivity.ts             # wraps list_meetings + client-side aggregation
│   │   └── useTimeRange.ts                   # reactive time range + URL sync
│   ├── routes.ts
│   ├── permissions.ts
│   └── i18n/
│       ├── zh.json
│       └── en.json
├── tests/
└── package.json
```

**No backend in this package.** Every fetch goes through `useStudio()`.

### 1.1 Permissions declared

```typescript
// packages/platform-features/observability/src/permissions.ts
export const OBSERVABILITY_PERMISSIONS = [
  // Already declared in 03 §5.2 + referenced by 02 §4.1; reaffirmed here.
  { code: "platform:view_observability", description: "View product-wide cost and activity dashboards" },
  // list_projects + list_meetings also needed (declared elsewhere)
] as const;
```

`platform:view_observability` is admin-grade by convention. Standard users may have it; ops definitely do.

### 1.2 Routes declared

```typescript
// packages/platform-features/observability/src/routes.ts
import type { RouteRecordRaw } from "vue-router";

export const OBSERVABILITY_TABS = ["cost", "activity", "errors"] as const;
export type ObservabilityTab = typeof OBSERVABILITY_TABS[number];

export const observabilityRoutes: RouteRecordRaw[] = [
  {
    path: "/platform/observability",
    name: "observability",
    component: () => import("./ObservabilityView.vue"),
    meta: { required_permissions: ["platform:view_observability"], title_key: "feature.observability.title" },
    redirect: { name: "observability-tab", params: { tab: "cost" } },
  },
  {
    path: "/platform/observability/:tab",
    name: "observability-tab",
    component: () => import("./ObservabilityView.vue"),
    meta: { required_permissions: ["platform:view_observability"], title_key: "feature.observability.title" },
    props: true,
    beforeEnter(to) {
      if (!OBSERVABILITY_TABS.includes(to.params.tab as ObservabilityTab)) {
        return { name: "observability-tab", params: { tab: "cost" } };
      }
    },
  },
];
```

---

## §2 Top-level lifecycle

### 2.1 `<ObservabilityView>` contract

```typescript
export default defineComponent({
  props: {
    tab: { type: String as PropType<ObservabilityTab>, default: "cost" },
  },
  setup(props) {
    const router = useRouter();

    // Time range — shared across tabs; URL-synced
    const { range, setPreset, setCustom, sinceISO, untilISO } = useTimeRange();

    function setTab(t: ObservabilityTab) {
      router.push({ name: "observability-tab", params: { tab: t }, query: router.currentRoute.value.query });
    }

    return { range, setPreset, setCustom, sinceISO, untilISO, setTab };
  },
});
```

Renders header (time range + refresh) + tabs nav + active tab view. Active view is dynamically imported (Cost / Activity / Errors).

### 2.2 Status states

| State | Trigger | Visual |
|---|---|---|
| `loading_initial` | view first mounted; data fetching | skeleton with placeholder chart shapes |
| `ready` | data loaded; charts rendered | full UI |
| `partial_failure` | one of multiple parallel fetches failed; others succeeded | render available; per-panel error banner for failed |
| `total_failure` | every fetch in this view failed | full-view error banner with retry |
| `empty` | data fetched OK but no rows | empty-state per panel ("No cost data for this range.") |
| `permission_denied` | user lacks permission (route guard) | redirected to dashboard with toast (per `02` §4.1) |

---

## §3 Layout

### 3.1 Desktop (≥ 1024 px)

```
┌─────────────── ObservabilityHeader ──────────────────────────────────┐
│  [Time range: Last 7 days ▼]    [Custom...]     [Refresh ↻]         │
├─────────────── ObservabilityTabs ────────────────────────────────────┤
│  • Cost     • Activity     • Errors                                 │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  (active view's content)                                             │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 Mobile (< 640 px)

Tabs become horizontal scroll. Charts collapse to tables (chart canvases at narrow widths render unreadably; tables are the honest fallback). A note explains the collapse: "Charts unavailable on small screens; data shown as table."

---

## §4 Views

### 4.1 `<CostView>`

Three panels in a vertical stack:

#### Panel A — Cost overview

```typescript
interface CostOverviewProps {
  since: string;       // ISO
  until: string;
}
```

Renders:
- Big number: total cost USD across the time range.
- `<LineChart>` showing daily cost trend (X = day, Y = USD). Buckets cost rows by `created_at` day.
- 4-card grid below: total tokens in / total tokens out / total meetings / total agent turns. Aggregated from rows.

Data: `useCostReportData({ since, until, group_by: [] })` — single CostReport, no grouping.

#### Panel B — Breakdown by dimension

```typescript
interface CostByDimensionProps {
  since: string;
  until: string;
  dimension: CostGroupByDimension;     // "project_id" | "user_id" | "agent_id" | "skill_id" | "model_id" | "kind"
}
interface CostByDimensionEmits {
  (e: "update:dimension", v: CostGroupByDimension): void;
}
```

Renders:
- Dropdown to pick dimension (7 choices: project / meeting / user / agent / skill / model / kind).
- `<BarChart>` showing cost per dimension value (top 10 by cost; "+ N more" link to expand).
- `<CostBreakdownTable>` below the chart with full rows + ExportButton.

Data: `useCostReportData({ since, until, group_by: [dimension] })`.

#### Panel C — Cost by model (donut)

A focused view of cost share by model_id. Donut chart for share-of-spend; legend with values. This is hard-coded as a useful default view (model spend is the most actionable metric for ops).

Data: `useCostReportData({ since, until, group_by: ["model_id"] })`.

**Why a third dedicated panel for model_id when Panel B can do it.** Model spend distribution is the single most actionable metric for cost optimization (which model is eating the budget?). Surfacing it without requiring users to know to select "model_id" in the dropdown is a deliberate UX decision.

### 4.2 `<ActivityView>`

Three panels:

#### Panel A — Meeting volume over time

```typescript
interface MeetingActivityProps {
  since: string;
  until: string;
}
```

`<LineChart>` showing daily meeting count. Series: `started_at` bucket per day. Data: `useMeetingActivity({ since, until })` calling `list_meetings({ since, limit: 500 })` + paginating until exhausted, then bucketing client-side.

#### Panel B — Status breakdown

`<DonutChart>` showing share of meetings by status (`running` / `completed` / `failed`) over the range. Forward-compat: any unknown status (per `01` §5.4 forward-compat rule) shown in gray "other" segment with the literal value in legend tooltip.

#### Panel C — Top projects by activity

`<TopProjectsTable>` showing top 10 projects by meeting count + their total cost (joined client-side from useCostReportData). 2 columns + chart in same row when desktop.

### 4.3 `<ErrorsView>`

Two panels:

#### Panel A — Recent failed meetings

```typescript
interface FailedMeetingsProps {
  since: string;
  until: string;
}
```

`<FailedMeetingsTable>` listing failed meetings (status=failed) sorted by `started_at` desc. Columns: meeting_id, project, user, started_at, error_class, error_message (truncated). Each row links to `/platform/agora/<meeting_id>` (where the failure banner per `05` §3.2 explains).

Data: `useMeetingActivity({ since, until }).failed_meetings.value`.

#### Panel B — Error type breakdown

`<DonutChart>` showing share of failures by `error_class` (the studio §8.2 error type strings preserved in `MeetingStatus.error_class`). Forward-compat: unknown error class shown in "other"; logged once to console with the full literal.

---

## §5 Charts (Chart.js wrappers)

### 5.1 Library choice — Chart.js

**Why Chart.js.** Mature, batteries-included (legend, tooltip, responsive sizing), ~80 KB minified-gzipped, MIT-licensed, no native deps. Covers line / bar / doughnut without custom drawing code. Bundle hit acceptable for an internal admin-grade feature.

**Why not D3** (which agora already uses). D3 gives lower-level control but requires significant glue for axes / legends / tooltips for each chart type. Cost-vs-benefit tilts to Chart.js for plain dashboards. v0.2 may consolidate to one library if perf or bundle concerns warrant.

**Why not server-side rendering.** Need interactive tooltips + responsive resize; SSR loses both. Server-rendered images would also blow up the apps/api surface for a feature that's purely presentational.

### 5.2 Wrapper component contract

Each chart is a minimal Vue wrapper around Chart.js. All three follow the same shape:

```typescript
interface LineChartProps {
  data: { labels: string[]; series: { name: string; values: number[] }[] };
  unit: string;            // "USD" | "count" | etc.; shown in axis label + tooltip
  height: number;          // px; default 240
  on_empty?: "spinner" | "empty_state" | "hide";  // default "empty_state"
}
// no emits
```

`<BarChart>` and `<DonutChart>` mirror with their data shape.

**Render rules.**
- Empty data → render the configured `on_empty` placeholder (default empty state).
- Loading state — wrapper has its own `is_loading` slot used by parent.
- Resize observed via `ResizeObserver`; chart redraws (debounced 150 ms).
- Tooltip formats values via `Intl.NumberFormat` (locale from `useI18n().locale.value`).
- Color palette: hardcoded sequential 8-color palette in `theme/charts.ts`; theme-aware (light / dark variants per `02` §5).
- Print mode: charts honor `prefers-reduced-motion` (no animations).

### 5.3 Per-chart minimal config

| Chart | Chart.js type | Axis labels | Tooltip format |
|---|---|---|---|
| `<LineChart>` | `line` | X = date (locale), Y = unit | `{date}: {value} {unit}` |
| `<BarChart>` | `bar` | X = dimension value, Y = unit | `{label}: {value} {unit}` |
| `<DonutChart>` | `doughnut` | (no axes) | `{label}: {value} {unit} ({percent}%)` |

---

## §6 Composables

### 6.1 `useCostReportData`

```typescript
export type CostGroupByDimension = "project_id" | "meeting_id" | "user_id" | "agent_id" | "skill_id" | "model_id" | "kind";

export interface CostReportFilters {
  since:     string;          // ISO
  until:     string;
  group_by:  CostGroupByDimension[];
  // optional point filters
  project_id?: string;
  user_id?:    string;
  agent_id?:   string;
  skill_id?:   string;
  model_id?:   string;
  kind?:       string;
}

export function useCostReportData(filters: Ref<CostReportFilters>): {
  report:    ComputedRef<CostReport | null>;
  isLoading: ComputedRef<boolean>;
  error:     ComputedRef<string | null>;
  refresh:   () => Promise<void>;
};
```

**Behavior.**
1. On mount + on `filters` change (deep watch): `studio.get_cost_report(filters.value)`.
2. Cache by JSON-stringified filters in a per-session Pinia store; identical filters within 30 s → returned from cache.
3. Stale time: 30 s. Beyond → re-fetch on next access.
4. Manual `refresh()` bypasses cache.

**Fetch errors** stored in `error` ref (localized message); `report` becomes null; UI shows panel-level error.

**Cache strategy rationale.** Time-range data is immutable for the past; the small cache window makes tab-switching fast without showing stale data after the user explicitly refreshes.

### 6.2 `useMeetingActivity`

```typescript
export interface MeetingActivityFilters {
  since: string;
  until: string;
}

export interface MeetingActivityData {
  total:           number;
  by_status:       Record<"running" | "completed" | "failed" | string, number>;   // string = forward-compat
  by_day:          { date: string; count: number }[];
  failed_meetings: MeetingSummary[];               // sorted desc by started_at
  by_error_class:  Record<string, number>;          // for ErrorsView Panel B
  top_projects:    { project_id: string; count: number }[];   // top 10
}

export function useMeetingActivity(filters: Ref<MeetingActivityFilters>): {
  data:      ComputedRef<MeetingActivityData | null>;
  isLoading: ComputedRef<boolean>;
  error:     ComputedRef<string | null>;
  refresh:   () => Promise<void>;
};
```

**Behavior.**
1. On mount + filters change: paginated `studio.list_meetings({ since, limit: 500, offset: 0/500/...})` until empty page.
2. Aggregate client-side:
   - by_day buckets by `started_at`'s date (UTC).
   - by_status counts by `status`.
   - failed_meetings filters where `status === "failed"`.
   - by_error_class buckets `failed_meetings[*].error_class` (defensively reads from MeetingStatus per `01` §5.4; `MeetingSummary` doesn't include error_class — see §6.3 for the workaround).
   - top_projects counts by `project_id`, sorted desc, top 10.
3. Cache + stale-time same as `useCostReportData`.

**Hard cap.** If `list_meetings` returns > 5000 rows in the range, abort + show "too much data; narrow time range." Acceptable degradation (operations would split into smaller queries).

### 6.3 Error class enrichment workaround

`MeetingSummary` (per `01` §5.3) does NOT carry `error_class`. To populate `by_error_class`, `useMeetingActivity` does an additional `studio.get_meeting_status({meeting_id: m})` call for **only the failed meetings** (typically a small fraction). Concurrent (up to 8); cached per session.

If the failed meeting count > 100 (pathological), only the first 100 by `started_at` desc are enriched; remainder counted as `"unknown"` in the donut with a footer note.

This workaround documented as a v0.2 request: "Add `error_class` to MeetingSummary so observability doesn't need N+1 fetches."

### 6.4 `useTimeRange`

```typescript
export type TimeRangePreset = "last_24h" | "last_7d" | "last_30d" | "custom";

export interface TimeRangeState {
  preset:    TimeRangePreset;
  custom_from: string | null;   // ISO; only when preset === "custom"
  custom_to:   string | null;
}

export function useTimeRange(): {
  range:     Ref<TimeRangeState>;
  sinceISO:  ComputedRef<string>;          // resolves preset → concrete ISO
  untilISO:  ComputedRef<string>;
  setPreset: (p: TimeRangePreset) => void;
  setCustom: (from: string, to: string) => void;
};
```

**URL sync.** Time range state serialized to `route.query` as `?range=last_7d` or `?range=custom&from=...&to=...`. Default: `last_7d`.

**Reactivity.** `sinceISO` / `untilISO` recompute when `range` changes. Charts watch these via composable filters.

---

## §7 CSV export

`<ExportButton>` triggers client-side CSV generation for the current view's primary data:

```typescript
interface ExportButtonProps {
  filename: string;     // suggests download name
  data:     unknown[];  // rows; serialized via Object.keys → header row, then values
  // optional: column_order to enforce header column order
  column_order?: string[];
}
```

**Behavior.** On click:
1. Build CSV string in memory (escape `"`, wrap fields with `"` if needed, use `,` separator, `\r\n` line ending).
2. Create Blob + `URL.createObjectURL`; trigger anonymous `<a download>` click.
3. Revoke object URL after timeout (1 s).

**Why client-side CSV** (vs apps/api endpoint): no server load, no auth round trip, no extra endpoint. Data is already in the browser.

**Limits.** v0.1 exports up to the rows currently shown in the panel. For exports > 5000 rows, button shows a tooltip "Narrow your filters to enable export"; download disabled.

---

## §8 Per-view error / empty / loading

| View | Loading | Empty | Partial fail | Total fail |
|---|---|---|---|---|
| Cost | skeleton charts + skeleton number cards | "No cost recorded in this range." | one panel error banner; others render | view-level error banner with retry |
| Activity | skeleton chart + skeleton table | "No meeting activity in this range." | same | same |
| Errors | skeleton table + skeleton donut | "No failures in this range. 🎉" | same | same |

Refresh button at top: re-fetches every panel in current view; per-panel `isLoading` flips during; `lastError` clears on success.

---

## §9 i18n

```json
{
  "feature.observability.title":                        "Observability",

  "feature.observability.tab.cost":                     "Cost",
  "feature.observability.tab.activity":                 "Activity",
  "feature.observability.tab.errors":                   "Errors",

  "feature.observability.range.last_24h":               "Last 24 hours",
  "feature.observability.range.last_7d":                "Last 7 days",
  "feature.observability.range.last_30d":               "Last 30 days",
  "feature.observability.range.custom":                 "Custom range",
  "feature.observability.range.refresh":                "Refresh",
  "feature.observability.range.from_to":                "{from} – {to}",

  "feature.observability.cost.heading":                 "Cost",
  "feature.observability.cost.total":                   "Total: ${amount}",
  "feature.observability.cost.daily_trend":             "Daily cost trend",
  "feature.observability.cost.metric.tokens_in":        "Total input tokens",
  "feature.observability.cost.metric.tokens_out":       "Total output tokens",
  "feature.observability.cost.metric.meetings":         "Meetings",
  "feature.observability.cost.metric.agent_turns":      "Agent turns",
  "feature.observability.cost.breakdown.heading":       "Breakdown by",
  "feature.observability.cost.breakdown.dimension.project_id":  "Project",
  "feature.observability.cost.breakdown.dimension.meeting_id":  "Meeting",
  "feature.observability.cost.breakdown.dimension.user_id":     "User",
  "feature.observability.cost.breakdown.dimension.agent_id":    "Agent",
  "feature.observability.cost.breakdown.dimension.skill_id":    "Skill",
  "feature.observability.cost.breakdown.dimension.model_id":    "Model",
  "feature.observability.cost.breakdown.dimension.kind":        "Kind",
  "feature.observability.cost.breakdown.show_more":             "+ {count} more",
  "feature.observability.cost.by_model.heading":                "Cost by model",
  "feature.observability.cost.empty":                           "No cost recorded in this range.",

  "feature.observability.activity.heading":             "Activity",
  "feature.observability.activity.daily_meetings":      "Daily meeting count",
  "feature.observability.activity.status.heading":      "Status mix",
  "feature.observability.activity.status.running":      "Running",
  "feature.observability.activity.status.completed":    "Completed",
  "feature.observability.activity.status.failed":       "Failed",
  "feature.observability.activity.status.other":        "Other",
  "feature.observability.activity.top_projects.heading":"Top projects",
  "feature.observability.activity.top_projects.col_project": "Project",
  "feature.observability.activity.top_projects.col_count":   "Meetings",
  "feature.observability.activity.top_projects.col_cost":    "Total cost",
  "feature.observability.activity.empty":               "No meeting activity in this range.",

  "feature.observability.errors.heading":               "Errors",
  "feature.observability.errors.failed_meetings.heading":"Recent failed meetings",
  "feature.observability.errors.failed_meetings.col_meeting":  "Meeting",
  "feature.observability.errors.failed_meetings.col_project":  "Project",
  "feature.observability.errors.failed_meetings.col_user":     "User",
  "feature.observability.errors.failed_meetings.col_started":  "Started",
  "feature.observability.errors.failed_meetings.col_error":    "Error class",
  "feature.observability.errors.failed_meetings.col_message":  "Message",
  "feature.observability.errors.failed_meetings.col_open":     "Open",
  "feature.observability.errors.error_breakdown.heading":      "Error type breakdown",
  "feature.observability.errors.error_breakdown.unknown":      "(unknown)",
  "feature.observability.errors.empty":                 "No failures in this range. 🎉",
  "feature.observability.errors.enrichment_partial":    "Showing first 100 failures by error class; older failures grouped as 'unknown'.",

  "feature.observability.export.csv":                   "Export CSV",
  "feature.observability.export.too_many":              "Narrow your filters to enable export ({rows} rows; max {max}).",

  "feature.observability.error.studio_unavailable":     "Studio is unavailable. Try again shortly.",
  "feature.observability.error.too_many_meetings":      "Too many meetings in this range; narrow your time filter.",
  "feature.observability.error.fetch_failed":           "Could not load: {message}",
  "feature.observability.error.retry":                  "Retry",

  "feature.observability.mobile.charts_unavailable":    "Charts unavailable on small screens; data shown as table."
}
```

---

## §10 Test matrix

### 10.1 ObservabilityView routing

| scenario | expected | test_id |
|---|---|---|
| /observability → /observability/cost | redirect | `t_ov_default_redirect` |
| /observability/activity | ActivityView rendered | `t_ov_tab_activity` |
| /observability/errors | ErrorsView rendered | `t_ov_tab_errors` |
| /observability/unknown | redirect to /cost | `t_ov_unknown_tab_redirect` |
| tab click | router.push to clicked tab | `t_ov_tabs_nav` |
| time range URL sync | preset="last_7d" → ?range=last_7d | `t_ov_range_url_sync` |
| time range custom | ?range=custom&from=&to= roundtrips | `t_ov_range_custom_roundtrip` |

### 10.2 CostView

| scenario | preconditions | expected | test_id |
|---|---|---|---|
| panel A renders | mock CostReport with rows | total + line chart + 4 metric cards | `t_cv_panel_a_render` |
| panel A empty | mock empty | empty state | `t_cv_panel_a_empty` |
| panel B dimension change | user picks "model_id" | useCostReportData re-fetches with group_by=[model_id] | `t_cv_panel_b_dim_change` |
| panel B top-10 chart + table | rows populate | bar chart + table; "+ N more" if > 10 | `t_cv_panel_b_top10` |
| panel C donut by model | mock report | donut renders share of cost | `t_cv_panel_c_donut` |
| export CSV | click ExportButton | blob URL triggered with csv | `t_cv_export_csv` |
| export disabled too-many | rows > 5000 | button disabled with tooltip | `t_cv_export_too_many` |
| partial failure | panel B fails, A + C succeed | panel B shows error; A + C render | `t_cv_partial_failure` |
| total failure | every panel fetch fails | view-level error banner | `t_cv_total_failure` |

### 10.3 ActivityView

| scenario | expected | test_id |
|---|---|---|
| meeting volume chart | mock 7 days of meetings | line chart with 7 points | `t_av_volume_chart` |
| status mix donut | running 2, completed 5, failed 1 | donut with 3 slices | `t_av_status_donut` |
| top projects table | top 10 by count | table populated; cost joined from cost data | `t_av_top_projects` |
| forward-compat unknown status | meeting with status="archived" (hypothetical) | shown as "Other" segment with literal in tooltip | `t_av_status_forward_compat` |
| too many meetings | mock returns > 5000 rows | view error "narrow time filter" | `t_av_too_many` |
| paginated fetch | mock requires 3 pages | all 3 pages fetched + merged | `t_av_paginated` |

### 10.4 ErrorsView

| scenario | expected | test_id |
|---|---|---|
| failed meetings table | 5 failed | rows with project/user/started/error_class/message; each row links to /agora | `t_ev_table_render` |
| error breakdown donut | mix of error classes | donut + legend | `t_ev_breakdown_donut` |
| empty | no failures | "No failures 🎉" | `t_ev_empty` |
| forward-compat unknown error_class | new studio error type | "other" slice with literal in tooltip + console log once | `t_ev_unknown_error_class` |
| > 100 failures enrichment cap | 150 failed | first 100 enriched; remainder counted as "unknown" with footer note | `t_ev_enrichment_cap` |
| failed meeting click → agora | click row | router.push to /platform/agora/<meeting_id> | `t_ev_click_agora` |

### 10.5 Composables

| composable | scenario | expected | test_id |
|---|---|---|---|
| useCostReportData | filters change | re-fetch | `t_cd_filters_change_refetch` |
| useCostReportData | identical filters within 30s | cache hit (no studio call) | `t_cd_cache_hit` |
| useCostReportData | manual refresh | bypass cache | `t_cd_refresh_bypass` |
| useMeetingActivity | aggregates by_day client-side | bucket count matches | `t_ma_aggregate_by_day` |
| useMeetingActivity | enriches failed with get_meeting_status | concurrent up to 8 | `t_ma_enrich_concurrent` |
| useMeetingActivity | hard cap > 5000 | aborts with too_many error | `t_ma_hard_cap` |
| useTimeRange | preset change updates ISO | sinceISO/untilISO recompute | `t_tr_preset_change` |
| useTimeRange | URL roundtrip | set + reload + read same state | `t_tr_url_roundtrip` |

### 10.6 Charts

| scenario | expected | test_id |
|---|---|---|
| LineChart empty data | empty_state placeholder | `t_lc_empty` |
| BarChart resize | container width change → ResizeObserver fires | redraw debounced | `t_bc_resize_debounce` |
| DonutChart locale-formatted tooltip | locale=zh, value=1234.56 | tooltip shows "1,234.56 USD" with zh locale formatting | `t_dc_locale_format` |
| Theme-aware palette | theme=dark | dark variant colors used | `t_charts_theme` |

---

## §11 Why this design — load-bearing decisions

**Why product-side aggregation (not server-side).**
Studio's cost ledger is the source of truth (per `01` §7.10); product fetches rows + groups client-side. Adding apps/api summarization would create a second source of truth for cost data — wrong, and operationally invites drift. v0.2 may add server-side aggregation parameters to studio if scale demands it.
*Considered and rejected.* **apps/api summarizes** — second source of truth.

**Why Chart.js (and not D3 which agora already uses).**
Plain dashboards (line / bar / doughnut) need legends, tooltips, axes — Chart.js batteries-included. D3 would require glue per chart type. Agora's DAG is bespoke (force layout); reusing D3 there is justified. Observability charts are commodity; lighter wrapper is the right call.
*Considered and rejected.* **D3 for both** — extra glue work; same outcome. **Server-rendered charts** — loses interactivity.

**Why no caching beyond 30 s session-level.**
Cost data changes slowly but the user's mental model is "I clicked refresh; now I see fresh data." Long-lived cache invalidates that. 30 s makes tab-switching fast without going stale.
*Considered and rejected.* **Persistent cache (IndexedDB)** — over-engineering for a v0.1 dashboard.

**Why N+1 fetches for failed-meeting enrichment (and the documented v0.2 request).**
`MeetingSummary` doesn't include `error_class`; `MeetingStatus` does. Without the field on the Summary, observability needs an extra fetch per failed meeting to populate the error breakdown. Concurrency (up to 8) keeps it tolerable; 100-cap prevents pathological cases. Migration path: studio adds `error_class` to `MeetingSummary` → observability drops the workaround.
*Considered and rejected.* **Skip the error breakdown** — the most actionable observability metric. **Make it a UI button "load error classes" (lazy)** — adds friction; users want to see the breakdown immediately.

**Why hard cap at 5000 meetings.**
Beyond 5K, paginating + aggregating client-side becomes laggy + uses noticeable memory. The cap is honest about v0.1 scale; users hit it by widening time range too much. v0.2 with server-side aggregation removes the cap.
*Considered and rejected.* **No cap** — pathological queries hang the browser.

**Why Charts collapse to tables on mobile (not re-layout).**
Charts at < 640 px width are unreadable (axis labels overlap, donut legend dominates). Tables are the honest fallback. Responsive chart layouts add complexity for a low-value mobile use case (observability is operator work, mostly desktop).
*Considered and rejected.* **Mobile-optimized charts** — over-engineering for the use case.

**Why client-side CSV export.**
Data is already in the browser; server round trip adds nothing. Limits exports to currently-shown data (5000 row cap), which is honest about the scale.
*Considered and rejected.* **Server-side CSV endpoint** — extra apps/api surface; same data, second path.

**Why a third dedicated "Cost by model" panel when Panel B can dimension by model_id.**
Model spend is the single most actionable metric for cost optimization. Surfacing it without requiring users to know to select "model_id" is worth the panel slot. Design pattern: progressive disclosure — Panel B for power users, Panel C for the common ask.
*Considered and rejected.* **Panel B only** — buries the most-used metric behind a dropdown. **Default Panel B's dimension to model_id** — confuses the "this is the breakdown panel" mental model.

**Why no drill-down from chart click in v0.1.**
Drill-down would require joining chart slices to specific meetings (e.g., "click this segment → show me the 12 meetings that contributed"). Possible but requires navigating to a filtered list view that doesn't exist (knowledge browser doesn't accept "errors of type X" filters in v0.1). v0.2 can add when the navigation target is ready.
*Considered and rejected.* **Click → filtered knowledge view** — knowledge doesn't support those filters yet.

**Why no real-time / SSE / live updates.**
Dashboards reflect aggregate state that changes slowly; refresh button is enough. Live SSE would require server push for cost changes, which studio doesn't expose. Polling at 30 s is implicit through the cache stale time.
*Considered and rejected.* **Auto-refresh every 30 s** — surprising battery drain on idle tabs. **SSE** — studio doesn't push cost events.

---

## §12 Downstream impact

| Spec | Adjustment |
|---|---|
| `01-studio-client-spec.md` | The §6.3 N+1 enrichment workaround is documented as a v0.2 request: "Add `error_class` to `MeetingSummary` so observability avoids per-failed-meeting `get_meeting_status` calls." Tracked in `docs/migration-log.md` (operational; will be added by user). |
| `02-platform-shell-spec.md` | `useStudio()` consumed; no change. |
| `03-auth-service-spec.md` | `platform:view_observability` consumed; declared upstream. |
| `05-feature-agora-spec.md` | The "open meeting" link from ErrorsView's failed-meetings table navigates to `/platform/agora/<meeting_id>`. Already supported. |
| `13-vertical-template-spec.md` | No vertical extension surface; observability is platform-only. |
| `15-apps-api-spec.md` | No new endpoints. Charts library (Chart.js) declared as a frontend dep in `apps/frontend/package.json` (per spec 16). |
| `16-apps-frontend-spec.md` | Add `chart.js` to `apps/frontend/package.json`. Bundle ~80 KB minified-gzipped — under typical performance budget for an internal admin tool. |
| `17-substitution-tests-spec.md` | Observability's `useCostReportData` calls studio's `get_cost_report`; covered by existing `[SUB] t_gcr_*` tests in `01` §7.10. |

---

## §13 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (per-vertical breakdowns, per-event-type analytics, email digest, anomaly detection, custom dashboards, real-time, multi-tenant filters, chart drill-down, alerting, ROI calcs, comparison mode, mobile chart layouts)
- [ ] Module layout (§1) frontend-only; no backend; Chart.js dependency noted
- [ ] Permissions (§1.1) `platform:view_observability` + list_projects + list_meetings (already declared upstream)
- [ ] 2 routes (§1.2) with tab validation in beforeEnter
- [ ] All 6 visual states (§2.2) covered including partial / total failure variants
- [ ] All 3 view components (§4) with panels enumerated + props/emits + data sources
- [ ] CostView panel C (Cost by model) explicitly motivated as default-surfaced metric (§4.1 + §11)
- [ ] All 3 chart components (§5) with TS contract + Chart.js library rationale (§5.1)
- [ ] All 3 composables (§6) with signatures + behavior + cache strategy + hard cap
- [ ] N+1 enrichment workaround (§6.3) documented + capped + v0.2 request raised
- [ ] CSV export (§7) client-side + 5000-row cap rationale
- [ ] Per-view error / empty / loading matrix (§8) covers each view × each state
- [ ] i18n keys (§9) for every user-visible string with en values
- [ ] Test matrix (§10): routing (7), CostView (9), ActivityView (6), ErrorsView (6), composables (8), charts (4); ≥ 35 rows
- [ ] Why-this / why-not (§11) for ≥ 8 load-bearing decisions
- [ ] Downstream impact (§12) lists every spec affected; v0.2 studio request flagged
- [ ] No business / domain / product / agent-role string literals (uses neutral examples)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No `try: ... except Exception: pass` patterns
- [ ] No apps/api summarization endpoints (product-side aggregation only)
- [ ] No fabrication of studio knobs that don't exist (no apps/api cost ledger)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/12-feature-observability-spec.md`
