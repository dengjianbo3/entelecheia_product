# 07 — `knowledge` feature v0.1 spec

> **Status**: v0.1 contract for the knowledge browser — the canonical "find a past meeting" view.
> **Lives at**: `packages/platform-features/knowledge/`.
> **Consumes**: `01-studio-client-spec.md` §7.1 (`list_projects`), §7.2 (`get_project`), §7.6 (`list_meetings`), §7.9 (`get_meeting_outcome`); `02-platform-shell-spec.md` (composables + routing + permissions); `03-auth-service-spec.md` (`platform:list_projects`, `platform:list_meetings`).
> **Forwarded to from**: `02-platform-shell-spec.md` (sidebar nav), `05-feature-agora-spec.md` (back button), `06-feature-reports-spec.md` (`/platform/reports` bare-path redirect).

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
- 7 Vue components: `<KnowledgeView>`, `<KnowledgeFilters>`, `<ProjectList>`, `<ProjectRow>`, `<MeetingTable>`, `<MeetingRow>`, `<OutcomeHighlights>`, `<EmptyState>`.
- 3 composables: `useKnowledgeData` (joins projects + meetings), `useKnowledgeFilters` (filter state + URL sync), `useOutcomeLazy` (per-meeting outcome fetch on row expand).
- Filters: status (All / Completed / Running / Failed), date range (All / 24h / 7d / 30d / Custom), free-text search (across topic + project name + cached outcome highlights).
- Vertical scoping: only projects in `useActiveVertical().active.value.default_project_filter.project_id_in` are visible (per `01-studio-client-spec.md` §11.4).
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
│   ├── KnowledgeView.vue                 # top-level
│   ├── components/
│   │   ├── KnowledgeFilters.vue          # date / status / search bar
│   │   ├── ProjectList.vue               # left column
│   │   ├── ProjectRow.vue                # one project entry
│   │   ├── MeetingTable.vue              # right column container
│   │   ├── MeetingRow.vue                # one meeting row + expand chevron
│   │   ├── OutcomeHighlights.vue         # inline preview when row expanded
│   │   └── EmptyState.vue                # configurable for the 4 empty states
│   ├── composables/
│   │   ├── useKnowledgeData.ts           # list_projects + list_meetings; cached
│   │   ├── useKnowledgeFilters.ts        # reactive filter state + URL sync
│   │   └── useOutcomeLazy.ts             # per-meeting outcome cache + fetch-on-expand
│   ├── routes.ts
│   ├── permissions.ts
│   └── i18n/
│       ├── zh.json
│       └── en.json
├── tests/
│   ├── components/
│   ├── composables/
│   └── e2e-fixtures/
├── package.json
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

The route guard requires BOTH (any-of insufficient — knowledge needs both lists to render).

### 1.2 Routes declared

```typescript
// packages/platform-features/knowledge/src/routes.ts
import type { RouteRecordRaw } from "vue-router";

export const knowledgeRoutes: RouteRecordRaw[] = [
  {
    path: "/platform/knowledge",
    name: "knowledge",
    component: () => import("./KnowledgeView.vue"),
    meta: {
      required_permissions: ["platform:list_projects", "platform:list_meetings"],
      title_key: "feature.knowledge.title",
    },
  },
  {
    path: "/platform/knowledge/projects/:project_id",
    name: "knowledge-project",
    component: () => import("./KnowledgeView.vue"),
    meta: {
      required_permissions: ["platform:list_projects", "platform:list_meetings"],
      title_key: "feature.knowledge.title",
    },
    props: true,                        // pass project_id as prop
  },
];
```

Both routes mount the SAME `<KnowledgeView>` component; the deep-link variant pre-selects the project.

---

## §2 Top-level lifecycle

### 2.1 `<KnowledgeView>` contract

```typescript
export default defineComponent({
  props: {
    project_id: { type: String, default: null },     // from /projects/:project_id route
  },
  setup(props) {
    const { active: activeVertical } = useActiveVertical();
    const studio = useStudio();

    // Combined fetch
    const { projects, meetings, isLoading, errors, refresh, loadMoreMeetings } =
      useKnowledgeData(computed(() => activeVertical.value));

    // Filter state (URL-synced)
    const { filters, setStatus, setDateRange, setSearch, selectProject, selectedProjectId } =
      useKnowledgeFilters({ initialProjectId: props.project_id });

    // Filtered + searched view (client-side)
    const filteredMeetings = computed(() => applyFilters(meetings.value, filters.value));

    // Lazy outcome fetch on expand
    const { getOutcome, expandRow, collapseRow, isExpanded, outcomeError } = useOutcomeLazy();

    return {
      projects, filteredMeetings, isLoading, errors, refresh, loadMoreMeetings,
      filters, setStatus, setDateRange, setSearch, selectProject, selectedProjectId,
      getOutcome, expandRow, collapseRow, isExpanded, outcomeError,
    };
  },
});
```

### 2.2 Status states

| State | Trigger | Visual |
|---|---|---|
| `loading_projects` | `isLoading.projects = true` | left column skeleton (3-row placeholder) |
| `loading_meetings` | `isLoading.meetings = true` | right column skeleton |
| `ready` | both loaded; at least one project | full UI |
| `empty_no_projects` | active vertical has zero projects in `project_id_in` | EmptyState: "Your vertical has no projects available." + "Switch vertical" CTA |
| `empty_no_meetings_for_project` | selected project has zero meetings | right column EmptyState: "No meetings yet." + "Start meeting" CTA → wizard |
| `empty_no_search_results` | search yields nothing | right column EmptyState: "No matches." + "Clear search" CTA |
| `empty_no_active_vertical` | `activeVertical.value === null` | EmptyState: "No active vertical." + sign-out link (matches 02 §2.4) |
| `partial_failure` | one fetch failed; the other succeeded | render available data + top banner with the failed fetch's error |

### 2.3 Permission check

Route guard (per `02` §4.1) requires both `platform:list_projects` and `platform:list_meetings`. If user lacks either, redirect to `/platform/dashboard` with a permission-denied toast.

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
interface KnowledgeFiltersProps {
  filters: KnowledgeFilters;        // see §5.2
}
interface KnowledgeFiltersEmits {
  (e: "update:status", v: MeetingStatus | "all"): void;
  (e: "update:date_range", v: DateRangePreset | { from: string; to: string }): void;
  (e: "update:search", v: string): void;
  (e: "start-meeting"): void;       // navigates to wizard
  (e: "refresh"): void;
}
```

**Renders.**
- Search input (debounced 300 ms internally).
- Status dropdown: All / Completed / Running / Failed.
- Date range dropdown: All / Last 24 hours / Last 7 days / Last 30 days / Custom (custom opens a date-picker pair).
- "+ Start meeting" primary button on the right (disabled if no active vertical or no projects).
- Refresh icon button (top-right).

**Accessibility.** All controls keyboard-accessible; date picker has aria-label "Custom date range".

### 4.2 `<ProjectList>`

```typescript
interface ProjectListProps {
  projects:           ProjectSummary[];        // sorted: most-recent-meeting first
  selected_id:        string | null;
  meeting_counts:     Record<string, number>;  // project_id → meeting count (filtered)
  has_more:           boolean;
}
interface ProjectListEmits {
  (e: "project-clicked", id: string): void;
  (e: "load-more"): void;
}
```

**Renders.** Vertical list of `<ProjectRow>`s (one per project). Each row shows project name + meeting count badge. Selected row has accent border. Below the list: "Load more projects" button if `has_more` (paged via studio's `limit/offset`).

**Sort order.** Projects sorted by their most-recent-meeting `started_at` descending. If a project has no meetings, sort by project's `updated_at`.

### 4.3 `<ProjectRow>`

```typescript
interface ProjectRowProps {
  project:        ProjectSummary;
  selected:       boolean;
  meeting_count:  number;
}
interface ProjectRowEmits {
  (e: "click"): void;
}
```

**Renders.** `[project name]  [meeting count badge]`. Hover state distinct from selected. Truncates long names with ellipsis + tooltip.

### 4.4 `<MeetingTable>`

```typescript
interface MeetingTableProps {
  meetings:           MeetingSummary[];        // already filtered + searched
  expanded_ids:       Set<string>;
  is_loading_more:    boolean;
  has_more:           boolean;
}
interface MeetingTableEmits {
  (e: "row-expand", meeting_id: string): void;
  (e: "row-collapse", meeting_id: string): void;
  (e: "open-clicked", meeting_id: string): void;
  (e: "report-clicked", meeting_id: string): void;
  (e: "load-more"): void;
}
```

**Renders.** Table with columns: Topic / Status / Started / Ended / Actions. Each row is a `<MeetingRow>`. Below the table: "Load more meetings" button if `has_more` (studio paging).

**Sort order.** Most recent first by `started_at`. Sort fixed in v0.1 — no clickable column headers.

### 4.5 `<MeetingRow>`

```typescript
interface MeetingRowProps {
  meeting:    MeetingSummary;
  expanded:   boolean;
  outcome:    OutcomeResponse | null;       // populated by useOutcomeLazy when expanded
  outcome_error: string | null;             // localized
}
interface MeetingRowEmits {
  (e: "expand"): void;
  (e: "collapse"): void;
  (e: "open"): void;
  (e: "report"): void;
}
```

**Renders.**
- Top row: chevron (▶ / ▼) | topic (truncated 80 chars) | status chip | started_at | ended_at (or "running") | "Open" button | "Report" button (disabled when status ≠ completed).
- Status chip color: completed=green, running=blue, failed=red, (unknown forward-compat)=gray.
- Expanded row: inline `<OutcomeHighlights>` below.
- Click anywhere on the row toggles expand (except buttons).

**Forward-compat for unknown `MeetingStatus`** (per `01` §5.4): unknown value renders as a gray chip with the raw value tooltipped; "Open" still works (agora's not_found state will handle); "Report" disabled defensively.

### 4.6 `<OutcomeHighlights>`

```typescript
interface OutcomeHighlightsProps {
  meeting_id:  string;
  outcome:     OutcomeResponse | null;
  is_loading:  boolean;
  error:       string | null;
}
```

**Renders.** When `outcome` is loaded:
- For `outcome.outcome` non-null (completed):
  - Top consensus item (truncated to 200 chars).
  - Counts: `{N} key facts · {M} open questions · {K} unresolved disagreements`.
  - Cost (if known via `useCostState` cache — optional in v0.1; if not cached, omit).
  - Two action buttons inline: "Full outcome →" (= Open) and "Export →" (= Report).
- For `outcome.outcome === null` and `outcome.error` set (failed): error message + "Open in agora to see what happened" link.
- For `is_loading`: tiny inline spinner.
- For `error`: "Could not load preview." with retry link.

**Why a preview, not the full outcome inline.** Outcomes can be large (10s of claims, deep evidence chains); inline rendering would explode the page DOM. A preview gives enough signal to decide whether to open.

### 4.7 `<EmptyState>`

```typescript
interface EmptyStateProps {
  variant:  "no_active_vertical" | "no_projects" | "no_meetings" | "no_search_results";
  message_key:  string;          // i18n key
  cta_label_key: string | null;  // i18n key for the action button label
}
interface EmptyStateEmits {
  (e: "cta-clicked"): void;
}
```

Reusable empty-state card with icon, headline, body, optional CTA button.

---

## §5 Composables

### 5.1 `useKnowledgeData`

```typescript
export function useKnowledgeData(
  activeVertical: Ref<VerticalManifest | null>,
): {
  projects:        ComputedRef<ProjectSummary[]>;        // already filtered to vertical's project_id_in
  meetings:        ComputedRef<MeetingSummary[]>;        // for the projects above
  isLoading:       ComputedRef<{ projects: boolean; meetings: boolean }>;
  errors:          ComputedRef<{ projects: string | null; meetings: string | null }>;
  refresh:         () => Promise<void>;                  // re-fetch both
  loadMoreMeetings: () => Promise<void>;                 // paginated; sets has_more
  has_more:        ComputedRef<boolean>;
};
```

**Behavior.**
1. On `activeVertical` change OR mount:
   a. Compute `project_id_in = activeVertical.value?.default_project_filter.project_id_in ?? []`.
   b. Fetch `studio.list_projects({status: "published", limit: 200})`.
   c. Filter client-side to those whose `spec_id` is in `project_id_in`.
   d. For each project (in parallel, up to 8 concurrent): fetch `studio.list_meetings({project_id: <id>, limit: 50})`.
   e. Merge all meetings into a single sorted array (by `started_at` desc).
2. `loadMoreMeetings()`: increment offset for each project's `list_meetings` call; refetch + merge; `has_more` true if any project returned a full page (heuristic — studio doesn't give an explicit "more available" signal).
3. `refresh()`: re-runs steps 1-2 from scratch; respects in-flight cancellation.
4. Errors per fetch tracked separately; partial success is rendered (per §2.2 partial_failure).

**Caching.** In-memory only for the session. No persistence; reload re-fetches.

**Why fetch per-project meetings (not one big `list_meetings()` call).** Studio's `list_meetings` doesn't accept `project_id_in: list[str]`; only `project_id: str` (single, optional). Loading ALL meetings unscoped would include meetings from projects outside the vertical's allowlist — wasteful and a leak.

### 5.2 `useKnowledgeFilters`

```typescript
export type DateRangePreset = "all" | "last_24h" | "last_7d" | "last_30d" | "custom";

export interface KnowledgeFilters {
  status:        "all" | "running" | "completed" | "failed";
  date_range:    DateRangePreset;
  date_from:     string | null;        // ISO; only when date_range === "custom"
  date_to:       string | null;
  search:        string;               // free text; debounced
  project_id:    string | null;        // selected project; null = all in vertical
}

export function useKnowledgeFilters(opts: { initialProjectId: string | null }): {
  filters:           Ref<KnowledgeFilters>;
  selectedProjectId: ComputedRef<string | null>;
  setStatus:         (v: KnowledgeFilters["status"]) => void;
  setDateRange:      (v: DateRangePreset, custom?: { from: string; to: string }) => void;
  setSearch:         (v: string) => void;                  // internally debounced 300ms
  selectProject:     (id: string | null) => void;
};
```

**URL sync.** Filter state serialized into `route.query` (e.g., `?status=completed&date_range=last_7d&search=q2`). Deep links restore filter state. `project_id` lives in URL `params` (per route definition §1.2), not query.

**Persistence.** Filter state NOT persisted to user-service (per §scope: no per-user view preferences in v0.1).

### 5.3 `useOutcomeLazy`

```typescript
export function useOutcomeLazy(): {
  expandRow:     (meeting_id: string) => Promise<void>;       // triggers fetch if not cached
  collapseRow:   (meeting_id: string) => void;
  isExpanded:    (meeting_id: string) => boolean;
  getOutcome:    (meeting_id: string) => OutcomeResponse | null;     // null = not fetched OR error
  outcomeError:  (meeting_id: string) => string | null;
  isLoading:     (meeting_id: string) => boolean;
};
```

**Behavior.**
1. `expandRow(id)`:
   a. Add `id` to expanded set.
   b. If outcome NOT in cache AND meeting status is `completed` or `failed` (not `running`): call `studio.get_meeting_outcome({meeting_id: id})`.
   c. On success: cache result (in-memory; per-session).
   d. On `MeetingNotReady`: cache a sentinel "not_ready" — don't retry on subsequent expands (would spam studio); user can refresh manually.
   e. On other errors: cache error string; show in `<OutcomeHighlights>`.
2. `collapseRow(id)`: remove from expanded set; cached outcome retained for re-expand.
3. `getOutcome(id)`: return cached outcome or null.

**Concurrency.** Multiple expand requests for different meetings run in parallel (up to 4 concurrent, hard cap to avoid hammering studio). Same meeting double-expand de-duped via in-flight promise.

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
| `list_projects` fails | top banner red: "Could not load projects: {message}"; left column shows skeleton; meetings still show if cached from before |
| `list_meetings` for one project fails | log; that project's count shows "?" instead of a number; project is still selectable |
| `get_meeting_outcome` lazy fails | inline error in `<OutcomeHighlights>` with retry link; row stays expanded |
| `MeetingNotReady` from outcome | message "Outcome not yet available; reload page after the meeting concludes." |
| `MeetingFailed` from outcome | message "This meeting failed; outcome unavailable." (matches OutcomeResponse.error path) |
| Auth error (401) | route guard handles; redirect to /login |
| Permission denied (403) | route guard handles; redirect to dashboard |

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
| search by topic | type "Q2" | only matching topic rows visible; debounced | `t_kv_search_topic` |
| search includes cached outcomes | expand a row first; then search for term in its consensus | row matches | `t_kv_search_outcome_cached` |
| search no results | search for nonexistent | empty state "No matches" + clear button | `t_kv_search_empty` |
| no active vertical | activeVertical = null | empty state with sign-out link | `t_kv_no_vertical` |
| no projects available | vertical has zero projects | empty state with "Switch vertical" CTA | `t_kv_no_projects` |
| project with no meetings | select project; no meetings | right column empty state with "Start meeting" CTA → wizard | `t_kv_no_meetings` |
| start-meeting CTA | click | router.push to /platform/wizard/<project_id> (or wizard root if none selected) | `t_kv_start_meeting_cta` |
| row expand triggers outcome fetch | click chevron on completed row | useOutcomeLazy fetches; spinner; then highlights | `t_kv_expand_lazy_fetch` |
| row expand outcome cached | second expand of same row | no fetch; cached render | `t_kv_expand_cached` |
| row expand running meeting | row is running | does NOT call get_meeting_outcome (would 409); inline message "Open to view live" | `t_kv_expand_running_no_fetch` |
| row expand outcome not_ready | studio returns MeetingNotReady | "Outcome not yet available" message; sentinel cached so re-expand doesn't re-fetch | `t_kv_expand_not_ready_sentinel` |
| open clicked | click "Open" button | router.push to /platform/agora/<id> | `t_kv_open_navigate` |
| report clicked completed | completed meeting | router.push to /platform/reports/<id> | `t_kv_report_navigate` |
| report disabled non-completed | running meeting | report button disabled | `t_kv_report_disabled` |
| forward-compat unknown status | meeting with status="archived" (hypothetical) | gray chip with raw value tooltip; "Open" works; "Report" defensively disabled | `t_kv_forward_compat_status` |
| URL deep link to project | nav to /platform/knowledge/projects/proj-a | view mounts with proj-a preselected | `t_kv_deep_link_project` |
| filter URL sync | set status=completed | route.query has status=completed; reload restores | `t_kv_url_sync` |
| partial failure: projects ok, meetings fail | studio.list_meetings throws | left column ok; right column shows error banner; meeting count "?" | `t_kv_partial_meetings_fail` |
| partial failure: projects fail, meetings cached | list_projects throws; meetings prev cached | top banner; cached meetings still visible | `t_kv_partial_projects_fail` |
| load more meetings | has_more = true; click | loadMoreMeetings called; appends rows | `t_kv_load_more` |
| load more projects | has_more projects = true | similarly | `t_kv_load_more_projects` |

### 8.2 Composable tests

| composable | scenario | expected | test_id |
|---|---|---|---|
| useKnowledgeData | active vertical change | projects + meetings re-fetched | `t_kd_vertical_change_refetch` |
| useKnowledgeData | parallel meeting fetches | up to 8 concurrent; results merged | `t_kd_parallel_fetch` |
| useKnowledgeFilters | search debounced | < 300ms multiple updates → one filter pass | `t_kf_debounce` |
| useKnowledgeFilters | URL sync round-trip | set + reload + read | `t_kf_url_roundtrip` |
| useOutcomeLazy | concurrent expand same row | one in-flight fetch (de-duped) | `t_ol_dedupe_inflight` |
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
  "feature.knowledge.projects.meeting_count":  "{count} meetings",

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

  "feature.knowledge.highlights.facts_count":         "{count} key facts",
  "feature.knowledge.highlights.questions_count":     "{count} open questions",
  "feature.knowledge.highlights.disagreements_count": "{count} unresolved",
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

  "feature.knowledge.error.list_projects":        "Could not load projects: {message}",
  "feature.knowledge.error.list_meetings":        "Could not load meetings: {message}",
  "feature.knowledge.error.outcome_lazy":         "Could not load outcome preview."
}
```

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
Studio's `list_meetings` accepts `project_id` (single) or no filter. Asking unscoped would return meetings outside the vertical's allowlist (wasteful + leak). Per-project parallel is the cleanest path within the existing API.
*Considered and rejected.* **Single unscoped `list_meetings()` then filter client-side** — fetches meetings the user shouldn't see, even briefly. **Sequential per-project fetches** — slow; would scale poorly past ~5 projects.

**Why URL-sync filter state (but not persist to user-service).**
Deep links + reload preservation matter for "share me a filtered view" workflows. Persistence would couple knowledge to user-service; out of scope per §scope. URL is the right scope for view state.
*Considered and rejected.* **No URL sync** — bookmarks broken. **Persist to prefs** — over-engineering; v0.2 if asked for.

**Why "+ Start meeting" CTA in the filter bar instead of in EmptyState only.**
Knowledge is also the "what should I do next?" landing page. Having the CTA always visible (when applicable) lets users start without going elsewhere. EmptyState's CTA reinforces it for new-user / empty-state cases.
*Considered and rejected.* **CTA in EmptyState only** — buried for returning users. **CTA only in nav header** — out of context.

**Why disable "Report" for non-completed meetings (vs. hide).**
Disabled with a tooltip ("Available when meeting completes") teaches the user what happens; hiding loses that signal. Keeps the action grid stable visually.
*Considered and rejected.* **Hide entirely** — UI flicker as states change.

**Why URL-sync via `route.query` for filter state and `route.params` for project_id.**
Conventionally, `params` are part of the resource identifier (`/projects/:id` IS a different resource than `/projects/`); `query` is for view modifiers (filters, sort, paging). Following this convention keeps the URL semantically meaningful + matches `02-platform-shell-spec.md` §4 routing patterns.
*Considered and rejected.* **All in query** — `?project_id=...` is fine but loses the "this is a project view" semantic.

---

## §11 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | Sidebar nav links to `/platform/knowledge` (already in §4). Composables `useStudio` + `useActiveVertical` consumed unchanged. |
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
- [ ] Module layout (§1) enumerates every file (no backend code)
- [ ] Permissions (§1.1) re-declared (also live in 03 §5.2); both required
- [ ] Routes (§1.2) cover both `/platform/knowledge` + `/platform/knowledge/projects/:project_id`
- [ ] All 8 visual states (§2.2) documented including 4 empty states + partial_failure
- [ ] Layout (§3) covers desktop / tablet / mobile breakpoints
- [ ] All 7 components (§4) have full TS prop / emit signatures + render rules + accessibility notes
- [ ] All 3 composables (§5) have signatures + behavior + caching rules
- [ ] Filter / search semantics (§6) documents every filter rule + AND-combination + cached-outcome scope limit
- [ ] Error handling (§7) covers each fetch source + partial failure rule
- [ ] Forward-compat for unknown `MeetingStatus` enum (per `01` §5.4) called out in `<MeetingRow>` + test matrix
- [ ] Test matrix (§8): components (~25), composables (6); ≥ 30 rows
- [ ] i18n keys (§9) for every user-visible string
- [ ] Why-this / why-not (§10) for ≥ 8 load-bearing decisions
- [ ] Downstream impact (§11) lists every spec affected
- [ ] No business / domain / product / agent-role string literals (uses neutral `proj-a`, `vertical-a`, `Q2`)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] All studio access via `useStudio()` — no direct studio URLs
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/07-feature-knowledge-spec.md`
