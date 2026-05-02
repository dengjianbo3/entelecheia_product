# 07 — `knowledge` feature v0.1 spec

> **Status**: v0.1 contract for the knowledge browser — the canonical "find a past meeting" view. **Frontend stack**: React 18 + TypeScript + Zustand + React Router v6 (using `useSearchParams` for URL-synced filter state) + react-i18next + Tailwind.
> **Lives at**: `packages/platform-features/knowledge/`.
> **Consumes**: `01-studio-client-spec.md` §7.1 (`list_projects`), §7.2 (`get_project`), §7.6 (`list_meetings`), §7.9 (`get_meeting_outcome`); `02-platform-shell-spec.md` (hooks + routing + permissions); `03-auth-service-spec.md` (`platform:list_projects`, `platform:list_meetings`).
> **Forwarded to from**: `02-platform-shell-spec.md` (sidebar nav), `05-feature-agora-spec.md` (back button), `06-feature-reports-spec.md` (`/platform/reports` bare-path redirect).
> **Supersedes**: the Vue version of this spec (committed in `f5cf94a`); React migration per session decision 2026-05-03.

---

## Mission

This file defines the knowledge feature — the read-only browser for past projects + meetings + their outcomes. Per `01-studio-client-spec.md` §11.8, studio v0.1 does not expose a "knowledge tree" API; the browser composes from existing endpoints (`list_projects`, `list_meetings`, `get_meeting_outcome`) and renders a two-column tree-and-table view client-side. Knowledge is also the platform's natural "what should I do next?" landing page when no meeting is selected — agora's back button + reports' empty-redirect both terminate here.

**Hard rule** (P3 + read-only): knowledge writes nothing. Every interaction is a read against studio (live or cached) plus client-side filter / search. Starting a new meeting is the wizard's job (`10-feature-wizard-spec.md`); revisiting a live meeting is agora's; exporting an outcome is reports'. Knowledge connects them.

---

## Scope

**Covers.**
- Module layout under `packages/platform-features/knowledge/`.
- 2 routes: `/platform/knowledge` (main view), `/platform/knowledge/projects/:project_id` (deep link with project preselected).
- Two-column layout: project list (left, ~30%) + meetings table (right, ~70%).
- 7 React components: `<KnowledgeView>`, `<KnowledgeFilters>`, `<ProjectList>`, `<ProjectRow>`, `<MeetingTable>`, `<MeetingRow>`, `<OutcomeHighlights>`, `<EmptyState>`.
- 3 React hooks: `useKnowledgeData` (joins projects + meetings; in-memory session cache via Zustand), `useKnowledgeFilters` (filter state via `useSearchParams` + URL sync), `useOutcomeLazy` (per-meeting outcome cache + fetch-on-expand via internal Zustand store).
- Filters: status (All / Completed / Running / Failed), date range (All / 24h / 7d / 30d / Custom), free-text search (across topic + project name + cached outcome highlights), debounced via custom `useDebouncedValue` hook.
- Vertical scoping: only projects in `useActiveVertical().active.default_project_filter.project_id_in` are visible (per `01-studio-client-spec.md` §11.4).
- Pagination: cursor-style "Load more" once meetings list exceeds 100 rows (avoids loading 10K meetings on first paint).
- Per-row actions: "Open in agora" (always available), "View report" (only when `status=completed`).
- Lazy-fetched outcome highlights on row expand.
- Empty states (no vertical / no projects / project with no meetings / search no results).
- Error states (list fails / outcome lazy fetch fails) — partial-failure tolerant.
- Test matrix per component + per filter.
- i18n keys.
- v0.1 forward-compat for studio adding labels to ProjectSpec or a knowledge-tree API later (UI doesn't presume; can absorb additively).

**Does not cover.**
- Starting a new meeting — `10-feature-wizard-spec.md`. Knowledge surfaces a "+ Start meeting" CTA that navigates to wizard.
- Replaying a meeting — `05-feature-agora-spec.md`. Knowledge surfaces "Open" that routes there.
- Rendering / exporting reports — `06-feature-reports-spec.md`.
- Cross-meeting analytics or comparison — `12-feature-observability-spec.md` covers cost; multi-meeting outcome diffing is out of v0.1.
- Editing meeting metadata (renaming, tagging, archiving) — meetings are immutable per studio §9.2.
- Saving searches / pinned filters — out of v0.1.

**Out of scope for v0.1.**
- Server-side filtering / search beyond what studio's `list_meetings` query params already support (`project_id`, `status`, `since`). Free-text search is client-side only.
- Real-time refresh (no live updates when a new meeting starts elsewhere; user must hit refresh).
- Bulk actions (delete N, archive N) — meetings are not deletable.
- Cross-vertical visibility ("show me everything across all my verticals") — UI is vertical-scoped per active vertical (per `02-platform-shell-spec.md` §2.4).
- Personal pins / favorites.
- Per-user view preferences (column visibility, sort order).
- Inline outcome rendering — only highlights on expand; full outcome opens via "Open in agora" or "View report".

---

## §1 Module layout

```
packages/platform-features/knowledge/
├── src/
│   ├── index.ts                          # exports KnowledgeView + knowledgeRoutes
│   ├── KnowledgeView.tsx                 # top-level
│   ├── components/
│   │   ├── KnowledgeFilters.tsx          # date / status / search bar
│   │   ├── ProjectList.tsx               # left column
│   │   ├── ProjectRow.tsx                # one project entry
│   │   ├── MeetingTable.tsx              # right column container
│   │   ├── MeetingRow.tsx                # one meeting row + expand chevron
│   │   ├── OutcomeHighlights.tsx         # inline preview when row expanded
│   │   └── EmptyState.tsx                # configurable for the 4 empty states
│   ├── hooks/
│   │   ├── useKnowledgeData.ts           # list_projects + list_meetings; session-cached via Zustand
│   │   ├── useKnowledgeFilters.ts        # reactive filter state + useSearchParams URL sync
│   │   ├── useOutcomeLazy.ts             # per-meeting outcome cache + fetch-on-expand
│   │   └── useDebouncedValue.ts          # tiny utility hook for search debouncing
│   ├── stores/
│   │   ├── useKnowledgeDataStore.ts      # tiny Zustand store backing useKnowledgeData per-vertical cache
│   │   └── useOutcomeLazyStore.ts        # Zustand store backing useOutcomeLazy cache
│   ├── routes.ts
│   ├── permissions.ts
│   └── i18n/
│       ├── zh.json
│       └── en.json
├── tests/
│   ├── components/
│   ├── hooks/
│   └── e2e-fixtures/
├── package.json                          # depends on react, react-dom, react-router-dom, zustand, react-i18next
└── tsconfig.json
```

**No backend.** Knowledge is pure frontend — every fetch goes through `useStudio()` per the philosophy.

### 1.1 Permissions declared

```typescript
// packages/platform-features/knowledge/src/permissions.ts
export const KNOWLEDGE_PERMISSIONS = [
  // Both already declared by platform-shell (per 03 §5.2); listed here so the
  // boot dance reaffirms agora and knowledge depend on the same gates.
  { code: "platform:list_projects",  description: "List projects in the knowledge browser" },
  { code: "platform:list_meetings",  description: "List past meetings in the knowledge browser" },
] as const;
```

The route loader requires BOTH (any-of insufficient — knowledge needs both lists to render).

### 1.2 Routes declared

```typescript
// packages/platform-features/knowledge/src/routes.ts
import type { RouteObject } from "react-router-dom";
import { makePermissionsLoader } from "@entelecheia/platform-shell";   // factory variant for multi-perm

export const knowledgeRoutes: RouteObject[] = [
  {
    path: "/platform/knowledge",
    lazy: async () => {
      const { KnowledgeView } = await import("./KnowledgeView");
      return { Component: KnowledgeView };
    },
    loader: makePermissionsLoader(["platform:list_projects", "platform:list_meetings"]),
    handle: { title_key: "feature.knowledge.title" },
  },
  {
    path: "/platform/knowledge/projects/:project_id",
    lazy: async () => {
      const { KnowledgeView } = await import("./KnowledgeView");
      return { Component: KnowledgeView };
    },
    loader: makePermissionsLoader(["platform:list_projects", "platform:list_meetings"]),
    handle: { title_key: "feature.knowledge.title" },
  },
];
```

`makePermissionsLoader([...])` requires ALL listed permissions (vs single-perm `makePermissionLoader` from spec 02 §4.1). Both routes mount the SAME `<KnowledgeView>` component; the deep-link variant pre-selects the project via `useParams()`.

---

## §2 Top-level lifecycle

### 2.1 `<KnowledgeView>` contract

```typescript
import { useParams } from "react-router-dom";
import { useActiveVertical } from "@entelecheia/platform-shell";
import { useKnowledgeData } from "./hooks/useKnowledgeData";
import { useKnowledgeFilters } from "./hooks/useKnowledgeFilters";
import { useOutcomeLazy } from "./hooks/useOutcomeLazy";

export function KnowledgeView() {
  const { project_id: urlProjectId } = useParams<{ project_id?: string }>();
  const { active: activeVertical } = useActiveVertical();

  // Combined fetch — keyed by activeVertical; cached in Zustand store
  const { projects, meetings, isLoading, errors, refresh, loadMoreMeetings } =
    useKnowledgeData(activeVertical);

  // Filter state (URL-synced via useSearchParams; URL params for project_id)
  const { filters, setStatus, setDateRange, setSearch, selectProject, selectedProjectId } =
    useKnowledgeFilters({ initialProjectId: urlProjectId ?? null });

  // Filtered + searched view (client-side)
  const filteredMeetings = useMemo(
    () => applyFilters(meetings, filters),
    [meetings, filters]
  );

  // Lazy outcome fetch on expand
  const outcomeLazy = useOutcomeLazy();

  // ... render based on visual state per §2.2
}
```

### 2.2 Status states

| State | Trigger | Visual |
|---|---|---|
| `loading_projects` | `isLoading.projects === true` | left column skeleton (3-row placeholder) |
| `loading_meetings` | `isLoading.meetings === true` | right column skeleton |
| `ready` | both loaded; at least one project | full UI |
| `empty_no_projects` | active vertical has zero projects in `project_id_in` | EmptyState: "Your vertical has no projects available." + "Switch vertical" CTA |
| `empty_no_meetings_for_project` | selected project has zero meetings | right column EmptyState: "No meetings yet." + "Start meeting" CTA → wizard |
| `empty_no_search_results` | search yields nothing | right column EmptyState: "No matches." + "Clear search" CTA |
| `empty_no_active_vertical` | `activeVertical === null` | EmptyState: "No active vertical." + sign-out link (matches 02 §2.4) |
| `partial_failure` | one fetch failed; the other succeeded | render available data + top banner with the failed fetch's error |

### 2.3 Permission check

Route loader (per `02` §4.1) requires both `platform:list_projects` and `platform:list_meetings`. If user lacks either, redirect to `/platform/dashboard` with a permission-denied toast (loader uses `redirect()` response).

---

## §3 Layout

### 3.1 Desktop (≥ 1024 px)

```
┌────────────────────── KnowledgeFilters ───────────────────────────────────┐
│  [search box]   [status: All ▼]   [date: All ▼]    [+ Start meeting]    │
├────────────────────────┬──────────────────────────────────────────────────┤
│                        │                                                  │
│      ProjectList       │             MeetingTable                         │
│      (left, ~30%)      │             (right, ~70%)                        │
│                        │                                                  │
│   ◯ Project A          │    ┌─ topic ─────┬─ status ─┬─ ended ─┬ act. ┐  │
│   ● Project B (sel)    │    │ Q2 review   │ done    │ 2h ago  │ ◀ ▶  │  │
│   ◯ Project C          │    │ Risk check  │ done    │ 1d ago  │ ◀ ▶  │  │
│   ◯ ... (Load more)    │    │ ...         │         │         │      │  │
│                        │    └─────────────┴──────────┴─────────┴──────┘  │
│                        │    (selected meeting expanded → highlights)     │
│                        │    [Load more meetings]                         │
└────────────────────────┴──────────────────────────────────────────────────┘
```

### 3.2 Tablet (640..1023 px)

Same two-column but narrower; project list collapsible to a dropdown ("Project: B ▼") above the meeting table.

### 3.3 Mobile (< 640 px)

Single column with project picker as a top dropdown; meetings stack vertically; outcome highlights expand inline.

---

## §4 Components

### 4.1 `<KnowledgeFilters>`

```typescript
export interface KnowledgeFiltersProps {
  filters: KnowledgeFilters;        // see §5.2
  onStatusChange:    (v: MeetingStatus | "all") => void;
  onDateRangeChange: (v: DateRangePreset | { from: string; to: string }) => void;
  onSearchChange:    (v: string) => void;
  onStartMeeting:    () => void;       // navigates to wizard
  onRefresh:         () => void;
}

export function KnowledgeFilters(props: KnowledgeFiltersProps): React.ReactElement;
```

**Renders.**
- Search input (debounced 300 ms via `useDebouncedValue` internally; raw value bound to local `useState`, debounced value passed up via `onSearchChange`).
- Status dropdown: All / Completed / Running / Failed.
- Date range dropdown: All / Last 24 hours / Last 7 days / Last 30 days / Custom (custom opens a date-picker pair).
- "+ Start meeting" primary button on the right (disabled if no active vertical or no projects).
- Refresh icon button (top-right).

**Accessibility.** All controls keyboard-accessible; date picker has `aria-label="Custom date range"`.

### 4.2 `<ProjectList>`

```typescript
export interface ProjectListProps {
  projects:           ProjectSummary[];        // sorted: most-recent-meeting first
  selected_id:        string | null;
  meeting_counts:     Record<string, number>;  // project_id → meeting count (filtered)
  has_more:           boolean;
  onProjectClicked:   (id: string) => void;
  onLoadMore:         () => void;
}

export function ProjectList(props: ProjectListProps): React.ReactElement;
```

**Renders.** Vertical list of `<ProjectRow>` (one per project). Each row shows project name + meeting count badge. Selected row has accent border. Below the list: "Load more projects" button if `has_more` (paged via studio's `limit/offset`).

**Sort order.** Projects sorted by their most-recent-meeting `started_at` descending. If a project has no meetings, sort by project's `updated_at`.

### 4.3 `<ProjectRow>`

```typescript
export interface ProjectRowProps {
  project:        ProjectSummary;
  selected:       boolean;
  meeting_count:  number;
  onClick:        () => void;
}

export function ProjectRow(props: ProjectRowProps): React.ReactElement;
```

**Renders.** `[project name]  [meeting count badge]`. Hover state distinct from selected. Truncates long names with ellipsis + tooltip (`title=...` attribute).

### 4.4 `<MeetingTable>`

```typescript
export interface MeetingTableProps {
  meetings:           MeetingSummary[];        // already filtered + searched
  expanded_ids:       Set<string>;
  is_loading_more:    boolean;
  has_more:           boolean;
  outcomeLazy:        UseOutcomeLazyReturn;   // for fetching outcomes on expand
  onRowExpand:        (meeting_id: string) => void;
  onRowCollapse:      (meeting_id: string) => void;
  onOpenClicked:      (meeting_id: string) => void;
  onReportClicked:    (meeting_id: string) => void;
  onLoadMore:         () => void;
}

export function MeetingTable(props: MeetingTableProps): React.ReactElement;
```

**Renders.** Table with columns: Topic / Status / Started / Ended / Actions. Each row is a `<MeetingRow>`. Below the table: "Load more meetings" button if `has_more` (studio paging).

**Sort order.** Most recent first by `started_at`. Sort fixed in v0.1 — no clickable column headers.

### 4.5 `<MeetingRow>`

```typescript
export interface MeetingRowProps {
  meeting:    MeetingSummary;
  expanded:   boolean;
  outcome:    OutcomeResponse | null;       // populated by useOutcomeLazy when expanded
  outcome_error: string | null;             // localized
  onExpand:   () => void;
  onCollapse: () => void;
  onOpen:     () => void;
  onReport:   () => void;
}

export function MeetingRow(props: MeetingRowProps): React.ReactElement;
```

**Renders.**
- Top row: chevron (▶ / ▼) | topic (truncated 80 chars) | status chip | started_at | ended_at (or "running") | "Open" button | "Report" button (disabled when status ≠ completed).
- Status chip color: completed=green, running=blue, failed=red, (unknown forward-compat)=gray.
- Expanded row: inline `<OutcomeHighlights>` below.
- Click anywhere on the row toggles expand (except buttons; uses `onClick` with `event.stopPropagation()` on action buttons).

**Forward-compat for unknown `MeetingStatus`** (per `01` §5.4): unknown value renders as a gray chip with the raw value in `title=...` attribute; "Open" still works (agora's not_found state will handle); "Report" disabled defensively.

### 4.6 `<OutcomeHighlights>`

```typescript
export interface OutcomeHighlightsProps {
  meeting_id:  string;
  outcome:     OutcomeResponse | null;
  is_loading:  boolean;
  error:       string | null;
  onOpenClicked:   () => void;
  onReportClicked: () => void;
}

export function OutcomeHighlights(props: OutcomeHighlightsProps): React.ReactElement;
```

**Renders.** When `outcome` is loaded:
- For `outcome.outcome` non-null (completed):
  - Top consensus item (truncated to 200 chars).
  - Counts: `{N} key facts · {M} open questions · {K} unresolved disagreements`.
  - Cost (if known via `useCostState` cache — optional in v0.1; if not cached, omit).
  - Two action buttons inline: "Full outcome →" (calls `onOpenClicked`) and "Export →" (calls `onReportClicked`).
- For `outcome.outcome === null` and `outcome.error` set (failed): error message + "Open in agora to see what happened" link.
- For `is_loading`: tiny inline spinner.
- For `error`: "Could not load preview." with retry link.

**Why a preview, not the full outcome inline.** Outcomes can be large (10s of claims, deep evidence chains); inline rendering would explode the page DOM. A preview gives enough signal to decide whether to open.

### 4.7 `<EmptyState>`

```typescript
export interface EmptyStateProps {
  variant:      "no_active_vertical" | "no_projects" | "no_meetings" | "no_search_results";
  message_key:  string;          // i18n key
  cta_label_key: string | null;  // i18n key for the action button label
  onCtaClicked?: () => void;
}

export function EmptyState(props: EmptyStateProps): React.ReactElement;
```

Reusable empty-state card with icon, headline, body, optional CTA button.

---

## §5 Hooks

### 5.1 `useKnowledgeData`

```typescript
import type { VerticalManifest } from "@entelecheia/platform-shell";
import type { ProjectSummary, MeetingSummary } from "@entelecheia/studio-client";

export interface UseKnowledgeDataReturn {
  projects:        ProjectSummary[];                              // already filtered to vertical's project_id_in
  meetings:        MeetingSummary[];                              // for the projects above
  isLoading:       { projects: boolean; meetings: boolean };
  errors:          { projects: string | null; meetings: string | null };
  refresh:         () => Promise<void>;                           // re-fetch both
  loadMoreMeetings: () => Promise<void>;                          // paginated; sets has_more
  has_more:        boolean;
}

export function useKnowledgeData(activeVertical: VerticalManifest | null): UseKnowledgeDataReturn;
```

**Behavior.**
1. Subscribes (Zustand selector) to `useKnowledgeDataStore` slice keyed by `activeVertical?.vertical_id ?? "_none"`.
2. On `useEffect` watching `activeVertical?.vertical_id`:
   a. Compute `project_id_in = activeVertical?.default_project_filter.project_id_in ?? []`.
   b. If cache hit for this vertical_id (within 30s stale window): return cached.
   c. Else: trigger fetch:
      - `studio.list_projects({status: "published", limit: 200})` → filter client-side to `spec_id in project_id_in`.
      - For each project (in parallel via `Promise.allSettled`, up to 8 concurrent — cap via small semaphore utility): `studio.list_meetings({project_id: <id>, limit: 50})`.
      - Merge all meetings into a single sorted array (by `started_at` desc).
3. `loadMoreMeetings()`: increment offset for each project's `list_meetings` call; refetch + merge; `has_more` true if any project returned a full page.
4. `refresh()`: bypass cache; re-runs fetches.
5. Errors per fetch tracked separately in store; partial success is rendered (per §2.2 partial_failure).
6. Cleanup on unmount: AbortController cancels in-flight fetches.

**Caching.** In-memory only for the session via the Zustand store. No persistence; reload re-fetches.

**Why fetch per-project meetings (not one big `list_meetings()` call).** Studio's `list_meetings` doesn't accept `project_id_in: list[str]`; only `project_id: str` (single, optional). Loading ALL meetings unscoped would include meetings from projects outside the vertical's allowlist — wasteful and a leak.

### 5.2 `useKnowledgeFilters`

```typescript
export type DateRangePreset = "all" | "last_24h" | "last_7d" | "last_30d" | "custom";

export interface KnowledgeFilters {
  status:        "all" | "running" | "completed" | "failed";
  date_range:    DateRangePreset;
  date_from:     string | null;        // ISO; only when date_range === "custom"
  date_to:       string | null;
  search:        string;               // free text; debounced via useDebouncedValue
  project_id:    string | null;        // selected project; null = all in vertical
}

export interface UseKnowledgeFiltersOptions {
  initialProjectId: string | null;
}

export interface UseKnowledgeFiltersReturn {
  filters:           KnowledgeFilters;
  selectedProjectId: string | null;
  setStatus:         (v: KnowledgeFilters["status"]) => void;
  setDateRange:      (v: DateRangePreset, custom?: { from: string; to: string }) => void;
  setSearch:         (v: string) => void;                  // raw input; internally debounced via useDebouncedValue inside <KnowledgeFilters>
  selectProject:     (id: string | null) => void;
}

export function useKnowledgeFilters(opts: UseKnowledgeFiltersOptions): UseKnowledgeFiltersReturn;
```

**URL sync (the React-specific part).**

```typescript
import { useSearchParams, useNavigate } from "react-router-dom";
import { useState, useEffect, useMemo } from "react";

export function useKnowledgeFilters({ initialProjectId }: UseKnowledgeFiltersOptions) {
  const [searchParams, setSearchParams] = useSearchParams();
  const navigate = useNavigate();

  // Read filters from URL (single source of truth)
  const filters: KnowledgeFilters = useMemo(() => ({
    status:     (searchParams.get("status") as KnowledgeFilters["status"]) ?? "all",
    date_range: (searchParams.get("range") as DateRangePreset) ?? "all",
    date_from:  searchParams.get("from"),
    date_to:    searchParams.get("to"),
    search:     searchParams.get("q") ?? "",
    project_id: initialProjectId,    // from useParams, not searchParams
  }), [searchParams, initialProjectId]);

  function setStatus(v: KnowledgeFilters["status"]) {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      if (v === "all") next.delete("status"); else next.set("status", v);
      return next;
    }, { replace: true });
  }

  function setSearch(v: string) {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      if (!v) next.delete("q"); else next.set("q", v);
      return next;
    }, { replace: true });
  }

  function selectProject(id: string | null) {
    if (id) navigate(`/platform/knowledge/projects/${id}?${searchParams.toString()}`);
    else    navigate(`/platform/knowledge?${searchParams.toString()}`);
  }

  // ... setDateRange similarly
  return { filters, selectedProjectId: filters.project_id, setStatus, setDateRange, setSearch, selectProject };
}
```

**URL sync.** Filter state serialized into `route.search` query string (e.g., `?status=completed&range=last_7d&q=q2`) via React Router's `useSearchParams`. Deep links restore filter state. `project_id` lives in `route.params` (per route definition §1.2), updated via `navigate()`.

**Persistence.** Filter state NOT persisted to user-service (per §scope: no per-user view preferences in v0.1).

**Debouncing.** Search input debouncing happens at the `<KnowledgeFilters>` component level (raw input held in local `useState`, debounced via `useDebouncedValue(rawInput, 300)`, then `useEffect` calls `setSearch(debounced)`). The hook itself is debounce-agnostic.

### 5.3 `useOutcomeLazy`

```typescript
import type { OutcomeResponse } from "@entelecheia/studio-client";

export interface UseOutcomeLazyReturn {
  expandRow:     (meeting_id: string) => Promise<void>;       // triggers fetch if not cached
  collapseRow:   (meeting_id: string) => void;
  isExpanded:    (meeting_id: string) => boolean;
  getOutcome:    (meeting_id: string) => OutcomeResponse | null;     // null = not fetched OR error
  outcomeError:  (meeting_id: string) => string | null;
  isLoading:     (meeting_id: string) => boolean;
}

export function useOutcomeLazy(): UseOutcomeLazyReturn;
```

**Behavior** (backed by `useOutcomeLazyStore` Zustand store).
1. `expandRow(id)`:
   a. Add `id` to `expanded` Set in store.
   b. If outcome NOT in cache AND meeting status is `completed` or `failed` (not `running`): call `studio.get_meeting_outcome({meeting_id: id})`.
   c. On success: cache result.
   d. On `MeetingNotReady`: cache a sentinel "not_ready" — don't retry on subsequent expands (would spam studio); user can refresh manually.
   e. On other errors: cache error string; show in `<OutcomeHighlights>`.
2. `collapseRow(id)`: remove from expanded Set; cached outcome retained for re-expand.
3. `getOutcome(id)`: return cached outcome or null.

**Concurrency.** Multiple expand requests for different meetings run in parallel (up to 4 concurrent via in-store semaphore, hard cap to avoid hammering studio). Same meeting double-expand de-duped via in-flight promise stored in the Zustand state.

### 5.4 `useDebouncedValue` (utility)

```typescript
import { useState, useEffect } from "react";

export function useDebouncedValue<T>(value: T, delay: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const handle = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(handle);
  }, [value, delay]);
  return debounced;
}
```

Tiny utility hook for search input debouncing in `<KnowledgeFilters>` and analogous use cases.

---

## §6 Filtering / search semantics

Applied client-side in `applyFilters(meetings, filters)`:

| Filter | Rule |
|---|---|
| `status === "all"` | no status filter |
| `status === "<X>"` | meetings where `meeting.status === X` |
| `date_range === "all"` | no date filter |
| `date_range === "last_24h"` | meetings where `started_at >= now - 24h` |
| `date_range === "last_7d"` | similarly |
| `date_range === "last_30d"` | similarly |
| `date_range === "custom"` | meetings where `from <= started_at <= to` |
| `search === ""` | no text filter |
| `search === "X"` (after debounce) | case-insensitive substring match against `meeting.topic` (always available) AND, if outcome cached, against `outcome.consensus[].content` + `outcome.key_facts[].statement` |
| `project_id === null` | no project filter |
| `project_id === "<X>"` | meetings where `meeting.project_id === X` |

All filters AND-combined.

**Why search includes cached outcomes only.** Fetching all outcomes upfront for search is expensive; fetching on-search is even worse (could trigger 100s of fetches). Cached-only is honest about the limitation; surface it via a small footer note "Search includes outcomes you've expanded in this session."

---

## §7 Error handling

| Error source | Surface |
|---|---|
| `list_projects` fails | top banner red: "Could not load projects: {{message}}"; left column shows skeleton; meetings still show if cached from before |
| `list_meetings` for one project fails | log; that project's count shows "?" instead of a number; project is still selectable |
| `get_meeting_outcome` lazy fails | inline error in `<OutcomeHighlights>` with retry link; row stays expanded |
| `MeetingNotReady` from outcome | message "Outcome not yet available; reload page after the meeting concludes." |
| `MeetingFailed` from outcome | message "This meeting failed; outcome unavailable." (matches OutcomeResponse.error path) |
| Auth error (401) | route loader handles; redirect to /login |
| Permission denied (403) | route loader handles; redirect to dashboard |

**Partial failure rule.** A failure in any single fetch does NOT prevent the rest of the UI from rendering with what data is available.

---

## §8 Test matrix

### 8.1 Component tests

| scenario | preconditions | expected | test_id |
|---|---|---|---|
| mount with projects + meetings | active vertical with 2 projects, 5 meetings | both columns render; right column shows all 5 | `t_kv_mount_happy` |
| project click filters meetings | click project A | right column shows only A's meetings | `t_kv_project_filter` |
| status filter | set "completed" | only completed rows visible | `t_kv_status_filter` |
| date filter "last 24h" | mix of recent + old | only recent rows visible | `t_kv_date_filter` |
| custom date range | from/to set | only rows in range | `t_kv_date_custom` |
| search by topic | type "Q2" | only matching topic rows visible after 300ms debounce | `t_kv_search_topic` |
| search includes cached outcomes | expand a row first; then search for term in its consensus | row matches | `t_kv_search_outcome_cached` |
| search no results | search for nonexistent | empty state "No matches" + clear button | `t_kv_search_empty` |
| no active vertical | activeVertical = null | empty state with sign-out link | `t_kv_no_vertical` |
| no projects available | vertical has zero projects | empty state with "Switch vertical" CTA | `t_kv_no_projects` |
| project with no meetings | select project; no meetings | right column empty state with "Start meeting" CTA → wizard | `t_kv_no_meetings` |
| start-meeting CTA | click | navigate("/platform/wizard/<project_id>" or wizard root) | `t_kv_start_meeting_cta` |
| row expand triggers outcome fetch | click chevron on completed row | useOutcomeLazy fetches; spinner; then highlights | `t_kv_expand_lazy_fetch` |
| row expand outcome cached | second expand of same row | no fetch; cached render | `t_kv_expand_cached` |
| row expand running meeting | row is running | does NOT call get_meeting_outcome (would 409); inline message "Open to view live" | `t_kv_expand_running_no_fetch` |
| row expand outcome not_ready | studio returns MeetingNotReady | "Outcome not yet available" message; sentinel cached so re-expand doesn't re-fetch | `t_kv_expand_not_ready_sentinel` |
| open clicked | click "Open" button | navigate("/platform/agora/<id>") | `t_kv_open_navigate` |
| report clicked completed | completed meeting | navigate("/platform/reports/<id>") | `t_kv_report_navigate` |
| report disabled non-completed | running meeting | report button disabled | `t_kv_report_disabled` |
| forward-compat unknown status | meeting with status="archived" (hypothetical) | gray chip with raw value tooltip; "Open" works; "Report" defensively disabled | `t_kv_forward_compat_status` |
| URL deep link to project | nav to /platform/knowledge/projects/proj-a | view mounts with proj-a preselected via useParams | `t_kv_deep_link_project` |
| filter URL sync | set status=completed | searchParams has status=completed; reload restores | `t_kv_url_sync` |
| partial failure: projects ok, meetings fail | studio.list_meetings throws | left column ok; right column shows error banner; meeting count "?" | `t_kv_partial_meetings_fail` |
| partial failure: projects fail, meetings cached | list_projects throws; meetings prev cached | top banner; cached meetings still visible | `t_kv_partial_projects_fail` |
| load more meetings | has_more = true; click | loadMoreMeetings called; appends rows | `t_kv_load_more` |
| load more projects | has_more projects = true | similarly | `t_kv_load_more_projects` |
| unmount cancels fetch | switch route mid-fetch | AbortController triggered; no setState after unmount warning | `t_kv_unmount_abort` |

### 8.2 Hook tests

| hook | scenario | expected | test_id |
|---|---|---|---|
| useKnowledgeData | active vertical change | projects + meetings re-fetched | `t_kd_vertical_change_refetch` |
| useKnowledgeData | parallel meeting fetches | up to 8 concurrent via semaphore; results merged | `t_kd_parallel_fetch` |
| useKnowledgeData | cache hit within 30s | no studio call | `t_kd_cache_hit` |
| useKnowledgeFilters | URL sync round-trip | set + reload + read | `t_kf_url_roundtrip` |
| useKnowledgeFilters | replace mode | URL replaces (not pushes); back button doesn't accumulate filters | `t_kf_replace_history` |
| useDebouncedValue | rapid changes | only last value emitted after delay | `t_dv_debounce` |
| useDebouncedValue | unmount mid-debounce | no setState after unmount; clearTimeout in cleanup | `t_dv_unmount_cleanup` |
| useOutcomeLazy | concurrent expand same row | one in-flight fetch (de-duped via promise stored in Zustand) | `t_ol_dedupe_inflight` |
| useOutcomeLazy | concurrent expand different rows | up to 4 parallel; queue beyond | `t_ol_concurrency_cap` |

---

## §9 i18n

```json
{
  "feature.knowledge.title": "Knowledge",

  "feature.knowledge.filter.search_placeholder": "Search topics or facts…",
  "feature.knowledge.filter.search_footer_note": "Search includes outcomes you've expanded in this session.",
  "feature.knowledge.filter.status.all":       "All status",
  "feature.knowledge.filter.status.running":   "Running",
  "feature.knowledge.filter.status.completed": "Completed",
  "feature.knowledge.filter.status.failed":    "Failed",
  "feature.knowledge.filter.date.all":         "All time",
  "feature.knowledge.filter.date.last_24h":    "Last 24 hours",
  "feature.knowledge.filter.date.last_7d":     "Last 7 days",
  "feature.knowledge.filter.date.last_30d":    "Last 30 days",
  "feature.knowledge.filter.date.custom":      "Custom range",
  "feature.knowledge.filter.start_meeting":    "+ Start meeting",
  "feature.knowledge.filter.refresh":          "Refresh",

  "feature.knowledge.projects.heading":        "Projects",
  "feature.knowledge.projects.load_more":      "Load more projects",
  "feature.knowledge.projects.meeting_count":  "{{count}} meetings",

  "feature.knowledge.meetings.heading":        "Meetings",
  "feature.knowledge.meetings.col_topic":      "Topic",
  "feature.knowledge.meetings.col_status":     "Status",
  "feature.knowledge.meetings.col_started":    "Started",
  "feature.knowledge.meetings.col_ended":      "Ended",
  "feature.knowledge.meetings.col_actions":    "Actions",
  "feature.knowledge.meetings.action_open":    "Open",
  "feature.knowledge.meetings.action_report":  "Report",
  "feature.knowledge.meetings.load_more":      "Load more meetings",
  "feature.knowledge.meetings.ended_running":  "running…",

  "feature.knowledge.highlights.facts_count":         "{{count}} key facts",
  "feature.knowledge.highlights.questions_count":     "{{count}} open questions",
  "feature.knowledge.highlights.disagreements_count": "{{count}} unresolved",
  "feature.knowledge.highlights.full_outcome":        "Full outcome →",
  "feature.knowledge.highlights.export":              "Export →",
  "feature.knowledge.highlights.failed":              "This meeting failed.",
  "feature.knowledge.highlights.failed_open_link":    "Open in agora to see what happened",
  "feature.knowledge.highlights.not_ready":           "Outcome not yet available; reload after the meeting concludes.",
  "feature.knowledge.highlights.preview_failed":      "Could not load preview.",
  "feature.knowledge.highlights.preview_retry":       "Retry",
  "feature.knowledge.highlights.running":             "This meeting is still running. Open to view live.",

  "feature.knowledge.empty.no_vertical":          "No active vertical.",
  "feature.knowledge.empty.no_vertical_action":   "Sign out",
  "feature.knowledge.empty.no_projects":          "Your active vertical has no projects available.",
  "feature.knowledge.empty.no_projects_action":   "Switch vertical",
  "feature.knowledge.empty.no_meetings":          "No meetings yet for this project.",
  "feature.knowledge.empty.no_meetings_action":   "Start meeting",
  "feature.knowledge.empty.no_search":            "No matches.",
  "feature.knowledge.empty.no_search_action":     "Clear search",

  "feature.knowledge.error.list_projects":        "Could not load projects: {{message}}",
  "feature.knowledge.error.list_meetings":        "Could not load meetings: {{message}}",
  "feature.knowledge.error.outcome_lazy":         "Could not load outcome preview."
}
```

i18next interpolation `{{var}}`. `zh.json` mirrors with Chinese.

---

## §10 Why this design — load-bearing decisions

**Why no separate "knowledge tree" studio API in v0.1.**
Per `01-studio-client-spec.md` §11.8: the v0.1 use case is "browse past meetings" which `list_meetings` + `get_meeting_outcome` covers. Asking studio for a tree-shaped API would couple studio to UI structure. If studio later adds explicit knowledge graphs, this view absorbs additively (a new API can replace the per-project meeting fetches; the rest of the UI is unchanged).
*Considered and rejected.* **Request `/v1/knowledge/tree` from studio** — couples studio to product UI shape; v0.1 doesn't need it.

**Why two-column (project list + meeting table), not a single tree.**
A pure tree (project → meeting → claim → ...) collapses meetings into nodes that hide the metadata users actually want at first glance (status, date, action buttons). A table at the meeting level surfaces it. Projects on the left act as a filter, not a grouping.
*Considered and rejected.* **Single tree** — hides scannable metadata. **Single flat table** — loses project context. **Tabbed by project** — bad for many-project users.

**Why client-side filtering / search.**
v0.1 typical scale: < 100 meetings per vertical for a reasonable internal team; fits comfortably in memory. Server-side filter would require new studio query params (or worse, new endpoints). Client-side is honest about the scale tradeoff.
*Considered and rejected.* **Server-side full-text search** — needs studio API support; over-engineered for v0.1 scale.

**Why search excludes outcomes the user hasn't expanded.**
Fetching all outcomes upfront for searchability is wasteful (large payloads × many meetings). On-search fetching is worse (1 search keystroke could trigger 100s of fetches). Cached-only is the honest limit; the footer note discloses it.
*Considered and rejected.* **Eager outcome prefetch** — bandwidth + memory bloat. **On-search fetch** — burst load on studio + slow UX.

**Why lazy outcome fetch on row expand (not on hover, not on render).**
Expand is the user's explicit "I want to know more" signal; matches their attention. Hover would trigger fetches the user didn't ask for. Render-time fetch defeats the lazy-loading premise.
*Considered and rejected.* **Hover prefetch** — burst load when user scrolls; **on-render** — same as eager prefetch.

**Why per-project parallel fetching (up to 8 concurrent), not one big `list_meetings` call.**
Studio's `list_meetings` accepts `project_id` (single) or no filter. Asking unscoped would return meetings outside the vertical's allowlist (wasteful + leak). Per-project parallel is the cleanest path within the existing API. Concurrency cap via a small semaphore (Promise pool) avoids browser connection-limit thrashing.
*Considered and rejected.* **Single unscoped `list_meetings()` then filter client-side** — fetches meetings the user shouldn't see, even briefly. **Sequential per-project fetches** — slow; would scale poorly past ~5 projects.

**Why URL-sync filter state via `useSearchParams` (but not persist to user-service).**
Deep links + reload preservation matter for "share me a filtered view" workflows. React Router v6's `useSearchParams` is the canonical way; uses `replace: true` so back button doesn't accumulate per-keystroke filter changes. Persistence would couple knowledge to user-service; out of scope per §scope.
*Considered and rejected.* **No URL sync** — bookmarks broken. **Persist to prefs** — over-engineering; v0.2 if asked for. **`pushState` instead of `replace`** — back button would accumulate hundreds of intermediate filter states.

**Why "+ Start meeting" CTA in the filter bar instead of in EmptyState only.**
Knowledge is also the "what should I do next?" landing page. Having the CTA always visible (when applicable) lets users start without going elsewhere. EmptyState's CTA reinforces it for new-user / empty-state cases.
*Considered and rejected.* **CTA in EmptyState only** — buried for returning users. **CTA only in nav header** — out of context.

**Why disable "Report" for non-completed meetings (vs. hide).**
Disabled with a `title=...` tooltip ("Available when meeting completes") teaches the user what happens; hiding loses that signal. Keeps the action grid stable visually.
*Considered and rejected.* **Hide entirely** — UI flicker as states change.

**Why `useSearchParams` for filter state (query) and `useParams` for project_id (path param).**
Conventionally, path params are part of the resource identifier (`/projects/:id` IS a different resource than `/projects/`); query is for view modifiers (filters, sort, paging). Following this convention keeps the URL semantically meaningful + matches `02-platform-shell-spec.md` §4 routing patterns + matches React Router v6's idiomatic split between the two.
*Considered and rejected.* **All in query** — `?project_id=...` is fine but loses the "this is a project view" semantic.

**Why `useOutcomeLazy` cache lives in a Zustand store (not component-local useState).**
Two `<MeetingRow>` components (e.g., one in main view + one in a notification preview) might want to display the same meeting's outcome highlights; component-local cache would re-fetch each time. A store keyed by meeting_id is shared and refcount-free (outcomes are immutable post-finalize; no eviction needed in v0.1 short sessions).
*Considered and rejected.* **Component-local useState** — duplicate fetches. **React Context provider** — global Provider needed; Zustand module-level store is simpler.

---

## §11 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | Sidebar nav links to `/platform/knowledge` (already in §4). Hooks `useStudio` + `useActiveVertical` consumed unchanged. Route loader uses `makePermissionsLoader([...])` — a multi-perm variant of `makePermissionLoader` from `02` §4.1 (added to shell's loaders.ts). |
| `03-auth-service-spec.md` | Permissions `platform:list_projects` + `platform:list_meetings` consumed (already declared). |
| `05-feature-agora-spec.md` | Agora's back button navigates to `/platform/knowledge` (already in 05). |
| `06-feature-reports-spec.md` | `/platform/reports/<id>` is the navigation target from "Report" action (already in 06 §13). |
| `10-feature-wizard-spec.md` | "Start meeting" CTA from knowledge navigates to wizard. Wizard accepts an optional `?project_id=` query param to preselect. |
| `13-vertical-template-spec.md` | `default_project_filter.project_id_in: list[ProjectId]` is consumed here; spec 13's manifest interface MUST keep this field name + shape. |
| `15-apps-api-spec.md` | No new endpoints needed (knowledge consumes studio-client only). |
| `17-substitution-tests-spec.md` | Knowledge's `list_projects` + `list_meetings` + `get_meeting_outcome` calls are covered by studio-client substitution suite (no new categories). |

---

## §12 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (server-side search, real-time refresh, bulk actions, cross-vertical view, pins, view prefs, inline outcome render)
- [ ] Module layout (§1) enumerates every file (.tsx files; hooks/ + stores/); no backend code
- [ ] Permissions (§1.1) re-declared (also live in 03 §5.2); both required
- [ ] Routes (§1.2) cover both `/platform/knowledge` + `/platform/knowledge/projects/:project_id`; uses `makePermissionsLoader([...])`
- [ ] All 8 visual states (§2.2) documented including 4 empty states + partial_failure
- [ ] Layout (§3) covers desktop / tablet / mobile breakpoints
- [ ] All 7 components (§4) have full TS Props interface + onXxx callback props + render rules + accessibility notes
- [ ] All 4 hooks (§5) (including useDebouncedValue) have signatures + behavior + caching rules + URL-sync mechanism (useSearchParams + useParams) + AbortController cleanup
- [ ] Filter / search semantics (§6) documents every filter rule + AND-combination + cached-outcome scope limit
- [ ] Error handling (§7) covers each fetch source + partial failure rule
- [ ] Forward-compat for unknown `MeetingStatus` enum (per `01` §5.4) called out in `<MeetingRow>` + test matrix
- [ ] Test matrix (§8): components (~26 incl. unmount-abort), hooks (9 incl. useDebouncedValue + replace-history); ≥ 35 rows
- [ ] i18n keys (§9) for every user-visible string with `{{var}}` interpolation
- [ ] Why-this / why-not (§10) for ≥ 8 load-bearing decisions including React-specific ones (useSearchParams + replace mode; Zustand for outcome cache; useParams + useSearchParams split)
- [ ] Downstream impact (§11) lists every spec affected
- [ ] No business / domain / product / agent-role string literals (uses neutral `proj-a`, `vertical-a`, `Q2`)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] All studio access via `useStudio()` — no direct studio URLs
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/07-feature-knowledge-spec.md`
