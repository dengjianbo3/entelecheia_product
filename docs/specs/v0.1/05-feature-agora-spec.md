# 05 — `agora` feature v0.1 spec

> **Status**: v0.1 contract for the agora deliberation feature — the centerpiece of every meeting view.
> **Lives at**: `packages/platform-features/agora/`.
> **Consumes**: `01-studio-client-spec.md` (subscribe_meeting + 26 EventTypes + MeetingOutcome), `01b-product-derivations-spec.md` (the 4 reducers + meeting-stream store), `02-platform-shell-spec.md` (composables + permission gates + routing), `03-auth-service-spec.md` (`platform:run_meeting` etc.), `04-user-service-spec.md` (UI prefs).
> **Forwards to**: `06-feature-reports-spec.md` (export from finalized agora), `07-feature-knowledge-spec.md` (browse-back), `09-feature-uploads-spec.md` (materials), `10-feature-wizard-spec.md` (entry flow), `15-apps-api-spec.md` (`/api/meetings/{id}/materials` endpoint), `16-apps-frontend-spec.md` (route mounting).

---

## Mission

This file defines the agora feature — the live meeting view. 7 Vue components arranged in a responsive grid render a deliberation in flight: agent utterances stream into the discussion column, claims and challenges build a graph in the DAG column, working consensus crystallizes in the outcome panel, materials remain visible at all times, cost ticks live, and evidence is one click away from any cited claim. When the meeting finalizes, the same view transparently switches from working state to studio's authoritative `MeetingOutcome`. When studio is unreachable, every disconnect / reconnect / cursor-loss state has a user-facing recovery path.

**Hard rule** (P3 + P5): agora has **zero backend code in this repo** beyond the apps/api-hosted `GET /api/meetings/{id}/materials` metadata endpoint (per `15-apps-api-spec.md`). All deliberation logic — agent runtime, event log, paradigms, outcome distillation — lives in studio. Agora's role is purely to render the stream + reductions and to surface meeting-level metadata that product stored at run_meeting time (the materials descriptor list).

---

## Scope

**Covers.**
- Module layout under `packages/platform-features/agora/`.
- Route registration: `/platform/agora/:meeting_id` mounted by the shell per `02-platform-shell-spec.md` §4.
- 3 entry flows: from wizard, from knowledge browser, from a direct bookmark URL.
- Top-level `<AgoraView>` lifecycle: mount → resolve meeting → subscribe → render → finalize / fail / disconnect / lost / unmount.
- Responsive 2x3 grid layout (desktop) collapsing to tabbed view (mobile).
- 7 Vue components with full TS prop / emit / slot signatures, per-event-type render rules, accessibility notes, and per-component test matrix:
  1. `<DiscussionStream>` — left/main column; renders the live stream.
  2. `<DagViewer>` — right column; force-directed graph from `useDagState`.
  3. `<OutcomePanel>` — bottom-center; working consensus → authoritative on finalization.
  4. `<MaterialsPanel>` — bottom-left; the meeting's input materials (collapsible).
  5. `<CostPanel>` — bottom-right; `useCostState` two-track display.
  6. `<EvidencePopover>` — overlay anchored to a clicked evidence chip.
  7. `<ProvenanceModal>` — full-screen modal showing the full chain.
- 7 status states (loading / live / completed / failed / disconnected / lost / not_found) and the UX for each.
- Finalization behavior (working state → authoritative; toggle to compare).
- v0.2 UX gaps with explicit user messaging: no Stop button, no human input injection, no DAG/provenance pre-derived (per `01-studio-client-spec.md` §11.1, §11.2, §11.5–§11.6).
- Materials handling: source (apps/api endpoint), descriptor model, upload-service preview link.
- i18n keys for every user-visible string (zh + en).
- Permission gating (`platform:run_meeting` to access; finer per-meeting gating handled by studio's authorization, surfaced as 403 / `PermissionDenied`).
- Test matrix per component + per state transition.

**Does not cover.**
- The 4 reducers themselves — `01b-product-derivations-spec.md` §3–§6 has the state machines, idempotency rules, reconnect rules, and per-reducer test matrices. This spec ONLY covers component-side wiring.
- The meeting-stream store — `01b` §2. Agora's components consume `useMeetingStreamStore(meeting_id)` per `02` re-exports.
- The studio Protocol — `01-studio-client-spec.md` is the contract; this spec uses the surface unchanged.
- Wizard's run_meeting flow — `10-feature-wizard-spec.md`. Wizard hands off via `router.push('/platform/agora/' + meeting_id)`.
- Report rendering — `06-feature-reports-spec.md` consumes `OutcomeResponse` from `get_meeting_outcome`; agora links to the report view but does not render reports.
- Knowledge browser — `07-feature-knowledge-spec.md`; agora is reachable from knowledge by clicking a meeting, but the browser logic is in 07.
- Materials upload buffering — `09-feature-uploads-spec.md`. Agora consumes a metadata endpoint that apps/api populates at run_meeting time.

**Out of scope for v0.1.**
- Stop / pause / resume / inject-human-input UI (no studio endpoints — per `01` §11.1–§11.2).
- DAG editing / annotation by user (read-only visualization).
- Side-by-side DAG comparison across meetings (single-meeting view only).
- Real-time collaboration (multiple users seeing each other's cursors / selections).
- Voice / video input.
- Configurable layout (the 2x3 grid is fixed; users can collapse panels but not rearrange).
- Per-event-type filters (e.g., "hide InternalStep") — `InternalStep` is hidden by default in v0.1 with no toggle; deferred.
- Replay scrubbing (timeline slider). Reconnect uses live `Last-Event-Id` per `01b`; intentional time-travel is v0.2+.

---

## §1 Module layout

```
packages/platform-features/agora/
├── src/
│   ├── index.ts                                 # public exports: AgoraView + route record
│   ├── AgoraView.vue                            # top-level
│   ├── components/
│   │   ├── DiscussionStream.vue
│   │   ├── DagViewer.vue
│   │   ├── OutcomePanel.vue
│   │   ├── MaterialsPanel.vue
│   │   ├── CostPanel.vue
│   │   ├── EvidencePopover.vue
│   │   ├── ProvenanceModal.vue
│   │   ├── AgoraHeader.vue                       # back button, title, status badge, round counter
│   │   ├── StatusBadge.vue                       # one of: live / completed / failed / disconnected / lost
│   │   ├── EventCard.vue                         # generic card used by DiscussionStream
│   │   ├── EventCardRegistry.ts                  # event_type -> render component
│   │   ├── cards/                                # one tiny component per event_type (24 + 2 = 26 files)
│   │   │   ├── MessageEmittedCard.vue
│   │   │   ├── ClaimMadeCard.vue
│   │   │   ├── ChallengeRaisedCard.vue
│   │   │   ├── ConsensusReachedBanner.vue
│   │   │   ├── ContradictionFoundBanner.vue
│   │   │   ├── EvidenceCitedChip.vue
│   │   │   ├── ToolCalledInline.vue
│   │   │   ├── StageAdvancedDivider.vue
│   │   │   ├── UserInjectedCard.vue
│   │   │   ├── MeetingFinalizedFooter.vue
│   │   │   ├── MeetingFailedBanner.vue
│   │   │   └── ... (rest of the 26)
│   │   ├── DagNode.vue                           # one node renderer (kind-aware via prop)
│   │   ├── DagEdge.vue
│   │   └── EmptyState.vue
│   ├── composables/
│   │   ├── useAgoraEntryFlow.ts                  # meeting_id resolution + permission check
│   │   ├── useAgoraLayout.ts                     # responsive breakpoint state, panel collapse
│   │   ├── useEvidenceTrigger.ts                 # global event bus for "open evidence for claim X"
│   │   └── useFinalizationToggle.ts              # working-vs-authoritative outcome view
│   ├── permissions.ts                            # permission codes this feature declares
│   ├── routes.ts                                 # route record (consumed by shell + apps/frontend)
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

**No backend.** Per the hard rule, agora has zero Python / FastAPI code in this package. The materials endpoint (`GET /api/meetings/{id}/materials`) lives in apps/api.

### 1.1 Permissions declared

```typescript
// packages/platform-features/agora/src/permissions.ts
export const AGORA_PERMISSIONS = [
  { code: "platform:run_meeting",      description: "Open the agora deliberation view" },
  { code: "platform:list_meetings",    description: "Required for the back-to-knowledge link to work" },
] as const;
```

Registered with auth-service at boot via `apps/api/main.py` (per `03` §5.3).

### 1.2 Routes declared

```typescript
// packages/platform-features/agora/src/routes.ts
import type { RouteRecordRaw } from "vue-router";

export const agoraRoutes: RouteRecordRaw[] = [
  {
    path: "/platform/agora/:meeting_id",
    name: "agora",
    component: () => import("./AgoraView.vue"),
    meta: {
      required_permissions: ["platform:run_meeting"],
      title_key: "agora.title",
    },
  },
  {
    path: "/platform/agora",
    redirect: "/platform/knowledge",     // no meeting_id → land in browser
  },
];
```

Apps/frontend (per spec 16) imports + spreads `agoraRoutes` into the router table.

---

## §2 Entry flows

Three ways the user lands in `<AgoraView>`. All flow into the same lifecycle (§3).

### 2.1 From wizard

```
wizard finishes:
  → wizard calls StudioClient.run_meeting(...) → MeetingHandle{meeting_id, ...}
  → wizard (per spec 10) writes meeting metadata to apps/api
    (POST /api/meetings/{id}/metadata with materials descriptors + topic + project_id)
  → wizard calls router.push(`/platform/agora/${meeting_id}`)
  → AgoraView mounts; useMeetingStreamStore(meeting_id).subscribe() begins
  → first events arrive within ~200ms (studio §9.1: meeting starts immediately)
```

### 2.2 From knowledge browser

```
user clicks a row in /platform/knowledge:
  → knowledge view (per spec 07) calls router.push(`/platform/agora/${meeting_id}`)
  → AgoraView mounts; subscribe; if meeting is COMPLETED, the SSE stream replays
    the entire archive ending with meeting_finalized; AgoraView renders the
    final state (per `01b` §2.4 "first subscribe, completed meeting")
```

### 2.3 Direct URL / bookmark

Same as §2.2 — AgoraView resolves `meeting_id` from `route.params`, subscribes; whether meeting is live or completed is determined by the events that arrive.

### 2.4 No `meeting_id` (route variant)

`/platform/agora` (no id) redirects to `/platform/knowledge` (per §1.2). Rationale: agora is meeting-bound; opening it without a meeting is a navigation error; the most useful place to send the user is the meeting picker.

---

## §3 Top-level `<AgoraView>` lifecycle

### 3.1 Component contract

```typescript
// AgoraView consumes from route; no props from parent
export default defineComponent({
  setup() {
    const route = useRoute();
    const meeting_id = computed(() => route.params.meeting_id as string);
    const stream = useMeetingStreamStore(meeting_id.value);

    // Reducers
    const outcome = useOutcomeReducer(meeting_id.value);
    const dag     = useDagState(meeting_id.value);
    const cost    = useCostState(meeting_id.value);

    // Materials (separate fetch from product API; not from studio)
    const materials = useMaterialsList(meeting_id.value);

    onMounted(() => stream.subscribe());
    onUnmounted(() => stream.unsubscribe());

    // React to meeting_id change (route param change)
    watch(meeting_id, async (new_id, old_id) => {
      // useMeetingStreamStore is keyed by id; the watch on route.params triggers
      // a new store binding via Pinia's keyed singleton.
    });

    return { stream, outcome, dag, cost, materials };
  },
});
```

### 3.2 Status state machine

`<AgoraView>` renders one of 7 visual states based on `stream.state.status` (per `01b` §2.2):

| Status | Visual               | User action available                  |
|--------|----------------------|----------------------------------------|
| `subscribing` | full-page spinner + skeleton grid; no events yet | wait |
| `live`        | full grid; events stream into DiscussionStream     | scroll, click, navigate |
| `completed`   | full grid; "Meeting concluded" footer; OutcomePanel switches to authoritative; CostPanel marked finalized | export to report (link), share, navigate |
| `failed`      | full grid (last good state); red `<MeetingFailedBanner>` at top with `failure_reason.message` | navigate back |
| `disconnected`| full grid (last good state); subtle yellow top bar "Reconnecting…" with auto-retry counter | wait or refresh |
| `lost`        | modal overlay "Stream lost. Refresh to recover." with a primary button calling `stream.forceFullReload()` | refresh, navigate back |
| `not_found`   | 404 page (when meeting_id doesn't exist; surfaces from `MeetingNotFound` per `01` §8) | navigate back |

State transitions are driven by the store; agora is a pure renderer.

### 3.3 Permission check

Route guard (per `02` §4.1) ensures `platform:run_meeting`. Per-meeting authorization is enforced by studio (it returns 404 / `MeetingNotFound` if the user shouldn't see the meeting); agora surfaces this as `not_found`.

---

## §4 Layout

### 4.1 Desktop grid (≥ 1024px wide)

```
┌─────────────────────────── AgoraHeader ──────────────────────────────────┐
│ [back] [project name] · [topic preview]    [StatusBadge]  [round N]     │
├──────────────────────────────────────┬──────────────────────────────────┤
│                                      │                                  │
│        DiscussionStream              │         DagViewer                │
│        (left, ~50%, scrolling)       │         (right, ~50%, force-directed) │
│                                      │                                  │
├──────────────────────┬───────────────┴─────────┬────────────────────────┤
│  MaterialsPanel       │  OutcomePanel             │  CostPanel             │
│  (collapsible)        │  (working / authoritative)│  (live + authoritative)│
└──────────────────────┴───────────────────────────┴────────────────────────┘
```

Implemented via CSS grid:

```css
.agora-grid {
  display: grid;
  grid-template-rows: auto 1fr auto;          /* header / main / bottom */
  grid-template-columns: 1fr 1fr;             /* discussion | dag */
  height: 100vh;
}
.agora-bottom {
  grid-column: 1 / 3;
  display: grid;
  grid-template-columns: 1fr 1fr 1fr;         /* materials | outcome | cost */
}
```

### 4.2 Tablet (640..1023px)

DAG moves below DiscussionStream (single-column main); bottom row stays 3 columns.

### 4.3 Mobile (< 640px)

Bottom panels collapse to tabs (`<TabBar>` — Discussion / DAG / Outcome / Materials / Cost). EvidencePopover renders as a bottom sheet.

### 4.4 Panel collapse

`MaterialsPanel`, `CostPanel` are independently collapsible (chevron toggle). State persisted to user prefs via `useUserPrefs().agora_panels` (a v0.2 pref key; for v0.1 stored in `sessionStorage` only — won't survive across browser restarts).

---

## §5 Components (7 of them)

For each: mission, props, emits, slots, state derivation, accessibility, key UX rules. Per-event-type render rules consolidated in §5.1's table.

### 5.0 Per-event-type render rules (consumed by DiscussionStream)

`<EventCardRegistry>` maps `event_type` → render component. Per-event rules:

| `event_type`                | Renderer                       | Visual rule                                                           |
|-----------------------------|--------------------------------|-----------------------------------------------------------------------|
| `MeetingStarted`            | `MeetingStartedDivider`        | Top-of-stream divider with timestamp + paradigm name                  |
| `RootQuestionPosed`         | `RootQuestionHeader`           | Pinned at top of stream; topic content shown verbatim                 |
| `MessageEmitted`            | `MessageEmittedCard`           | Utterance card: avatar, agent_id, content (markdown), timestamp       |
| `UserInjected`              | `UserInjectedCard`             | Same as above but with "human" avatar style + accent border           |
| `ClaimMade`                 | `ClaimMadeCard`                | Card with `[claim]` badge; clickable → focuses node in DagViewer       |
| `ChallengeRaised`           | `ChallengeRaisedInline`        | Inline annotation under the related ClaimMade card                    |
| `ChallengeResolved`         | `ChallengeResolvedInline`      | Inline `✓ resolved` annotation                                        |
| `EvidenceCited`             | `EvidenceCitedChip`            | Inline chip with source kind icon; click → `<EvidencePopover>`        |
| `ToolCalled`                | `ToolCalledInline`             | Inline pill `🔧 <tool_name>`                                          |
| `ConsensusReached`          | `ConsensusReachedBanner`       | Full-width green banner: "Consensus on N claims"; click → OutcomePanel highlight |
| `ContradictionFound`        | `ContradictionFoundBanner`     | Full-width amber banner with content                                  |
| `StageAdvanced`             | `StageAdvancedDivider`         | Horizontal divider with new stage name                                |
| `TriggerDefined`            | `TriggerDefinedInline`         | Small icon + condition preview                                        |
| `UnknownRaised`             | `UnknownRaisedTag`             | `[unknown]` tag                                                       |
| `PathProposed`              | `PathProposedTag`              | `[proposal]` tag                                                      |
| `PivotIdentified`           | `PivotIdentifiedDivider`       | Visual divider                                                        |
| `EmergenceObserved`         | `EmergenceObservedTag`         | `[emergent]` tag                                                      |
| `DeadEndDeclared`           | `DeadEndDeclaredTag`           | `[dead end]` tag                                                      |
| `ArgumentDimensionDeclared` | `ArgumentDimensionDivider`     | Divider naming the dimension                                          |
| `FragilityRaised`           | `FragilityRaisedTag`           | `[fragility]` tag                                                     |
| `MeetingPaused`             | `LifecycleBanner` (yellow)     | Banner "Meeting paused" with reason                                   |
| `MeetingResumed`            | `LifecycleBanner` (green)      | Banner "Meeting resumed"                                              |
| `MeetingFrozen`             | `LifecycleBanner` (gray)       | Banner "Meeting frozen — finalizing…"                                 |
| `InternalStep`              | (hidden by default)            | Not rendered in v0.1; v0.2 may add a debug toggle                     |
| `meeting_finalized`         | `MeetingFinalizedFooter`       | Footer card "Meeting concluded at <ts>"; primary button "View report" |
| `meeting_failed`            | `MeetingFailedBanner`          | Top sticky banner with `error.message`; secondary button "Back"       |

**Forward-compat for unknown `event_type`** (per `01` §6 + `01b` §3.5 / §4.5): renderer registry returns a generic `<UnknownEventCard>` that shows `event_type` + `data` as collapsed JSON. Logged at WARN level.

### 5.1 `<DiscussionStream>`

**Mission.** Render the time-ordered event log as a scrollable feed; auto-follow live updates with user-overridable pause.

```typescript
interface DiscussionStreamProps {
  meeting_id: string;
}

interface DiscussionStreamEmits {
  (e: "claim-clicked", claim_id: string): void;
  (e: "evidence-clicked", payload: { event_id: number; claim_id: string }): void;
  (e: "scroll-state-changed", state: "following" | "manual"): void;
}
```

**State derivation.**
- Source: `useMeetingStreamStore(meeting_id).state.value.events` (full log).
- Filter: hide `InternalStep` (v0.1 default).
- Render: each remaining event through `<EventCardRegistry>`.

**Auto-follow rule.**
- Default: scrolled to bottom; new events push view down ("following").
- If user scrolls up by > 1 event-card-height: switch to "manual"; new events stop pushing; show a sticky pill at bottom: `↓ N new events` (N updates live).
- Click pill → scroll to bottom + return to "following".
- Scrolling to bottom manually also returns to "following".

**Accessibility.**
- ARIA live region: `aria-live="polite"` on the stream container; new events announced in user's locale.
- Keyboard: `↑/↓` to step through cards; `Enter` to expand; `Esc` to close any popover.
- Each card has `role="article"` with `aria-labelledby` pointing at the agent_id heading.

**Test rows (selected)**:

| scenario | input | expected | test_id |
|---|---|---|---|
| empty stream | no events | empty-state placeholder visible | `t_ds_empty` |
| events render in order | 3 events with event_id 1, 2, 3 | DOM order matches | `t_ds_order` |
| InternalStep hidden | mix with InternalStep | not rendered; gap-free visually | `t_ds_internal_hidden` |
| auto-follow on new events | user at bottom; new event arrives | view scrolls; "following" state | `t_ds_auto_follow` |
| pause-on-scroll-up | user scrolls up; new event arrives | view stays; pill shows `↓ 1 new` | `t_ds_pause_on_scroll` |
| pill click returns to follow | click pill | scrolls to bottom; pill hidden | `t_ds_pill_click` |
| evidence chip click emits | user clicks `EvidenceCitedChip` | emits `evidence-clicked` with payload | `t_ds_evidence_emit` |
| unknown event_type | new type from studio | `<UnknownEventCard>` rendered; warned | `t_ds_unknown_forward_compat` |

### 5.2 `<DagViewer>`

**Mission.** Render `useDagState`'s reactive snapshot as a force-directed graph; clicking a node focuses it in the discussion (scroll to first event mentioning it).

```typescript
interface DagViewerProps {
  meeting_id: string;
}

interface DagViewerEmits {
  (e: "node-clicked", node_id: string): void;
  (e: "node-double-clicked", node_id: string): void;   // opens detail panel
}
```

**State derivation.** `useDagState(meeting_id).dag.value` (Map<node_id, DagNode> + Map<edge_id, DagEdge>).

**Rendering.**
- Library: D3 force simulation (in `apps/frontend`'s deps).
- Node visual by `kind`:
  - `claim`: rounded rectangle, label = `truncate(content, 80)`; color by `state` (active=blue, contested=amber, resolved=gray, agreed=green).
  - `agent`: circle with initials.
  - `evidence`: small diamond.
  - `trigger`: small triangle.
- Edge visual by `kind`: solid (asserts), dashed (challenges), dotted (cites), thick red (contradicts), dotted-arrow (triggers).
- Labels truncated; full label in title tooltip.
- Force params tunable via `useUserPrefs().agora_dag_force` (v0.2 — v0.1 fixed).

**Performance.**
- Re-layout debounced 200 ms after each event.
- Above 200 nodes: switch to grid layout (force becomes O(N²)).
- Above 1000 nodes: render placeholder "Graph too large; open in dedicated viewer (v0.2)".

**Accessibility.**
- Graph is a SVG with `<title>` per node; `role="img"` on the SVG with `aria-label` summarizing node + edge counts.
- Keyboard: tab through nodes; `Enter` triggers click event.
- v0.1 does NOT provide a screen-reader walkthrough of the graph; an `<aside>` shows a textual summary ("Graph has N nodes (X claims agreed, Y contested) and M edges").

**Test rows (selected)**:

| scenario | dag state | expected | test_id |
|---|---|---|---|
| empty | 0 nodes | empty-state inside the panel | `t_dv_empty` |
| 5-node render | 2 claims + 2 agents + 1 evidence | 5 nodes + 3 edges visible | `t_dv_render_basic` |
| state colors | 1 active, 1 agreed | colors match the spec (`t_dv_color_legend`) | `t_dv_state_colors` |
| node click emits | click a claim node | emits `node-clicked` with node_id | `t_dv_click_emit` |
| 250-node fallback | dag growing past 200 | switches to grid layout | `t_dv_grid_fallback` |
| 1500-node fallback | growing past 1000 | placeholder rendered | `t_dv_too_large_placeholder` |

### 5.3 `<OutcomePanel>`

**Mission.** Render the working consensus while a meeting is live; switch to studio's authoritative `MeetingOutcome` on finalization, with a toggle to compare.

```typescript
interface OutcomePanelProps {
  meeting_id: string;
}

interface OutcomePanelEmits {
  (e: "claim-clicked", claim_id: string): void;
  (e: "view-report-clicked"): void;       // user wants to open the report view (spec 06)
}
```

**State derivation.**
- `useOutcomeReducer(meeting_id).consensus.value` — working state.
- `useOutcomeReducer(meeting_id).is_finalized.value` + `.finalized.value` — authoritative `MeetingOutcome` when present.
- `useFinalizationToggle()` composable — local UI state for which view is shown when finalized.

**Behavior.**
- Live (not finalized): render `consensus` only — list of `WorkingClaim`s grouped by `state` (Agreed / Resolved / Contested / Active sections); contradictions in a sub-panel.
- Finalized + default view: render `finalized.consensus` (authoritative items) + show toggle "View working consensus" (default off).
- Toggle on: render working state grayed out side-by-side for comparison; toggle persists in sessionStorage per meeting_id.
- "View report" button visible only when `is_finalized = true`; clicking emits `view-report-clicked` (parent navigates to spec 06 report view).

**Accessibility.**
- Each claim is a `<section role="region" aria-labelledby="claim-{id}-heading">`.
- Toggle is `<button aria-pressed="true|false">`.
- Status changes (claim moves from contested → agreed) announced via `aria-live="polite"` on the section.

**Test rows (selected)**:

| scenario | reducer state | expected | test_id |
|---|---|---|---|
| empty | no claims | empty-state "Awaiting claims…" | `t_op_empty` |
| 3 active claims | claims with state="active" | rendered in "Active" group | `t_op_active_group` |
| mixed states | 2 agreed, 1 contested, 1 resolved | 3 groups visible | `t_op_state_groups` |
| finalization | `is_finalized` flips true | view switches to authoritative; toggle visible | `t_op_finalization_switch` |
| toggle to compare | user clicks toggle | working state shown grayed alongside | `t_op_toggle` |
| view report click | finalized; user clicks button | emits `view-report-clicked` | `t_op_view_report_emit` |

### 5.4 `<MaterialsPanel>`

**Mission.** Show the materials the user submitted at run_meeting time. Read-only.

```typescript
interface MaterialsPanelProps {
  meeting_id: string;
}

interface MaterialsPanelEmits {
  (e: "material-preview-clicked", material_name: string): void;
}
```

**State derivation.** `useMaterialsList(meeting_id)` — a composable that calls `GET /api/meetings/{meeting_id}/materials` (apps/api endpoint defined in spec 15) and returns:

```typescript
interface MaterialDescriptor {
  name:         string;            // filename or note title; <= 200 chars
  kind:         "brief" | "data";  // matches studio §3.6 / 01 §4.6
  size_bytes:   number;
  preview_url:  string | null;     // relative URL into uploads service (spec 09); null when not previewable
}

useMaterialsList(meeting_id): {
  materials:   ComputedRef<MaterialDescriptor[]>;
  is_loading:  ComputedRef<boolean>;
  error:       ComputedRef<string | null>;   // localized "Materials unavailable"; non-blocking
}
```

**Rendering.**
- List of rows: icon (by kind) + name + size (humanized) + optional preview link.
- Click preview → emit `material-preview-clicked`; parent opens uploads-feature preview overlay (spec 09).
- Empty state: "No materials attached."
- Error state: "Materials unavailable." (Materials are not critical to the live meeting; agora continues without them.)

**Test rows**:

| scenario | input | expected | test_id |
|---|---|---|---|
| 3 materials | 1 brief + 2 data | 3 rows; correct icons | `t_mp_render` |
| empty | `materials: []` | empty-state visible | `t_mp_empty` |
| fetch error | endpoint 500 | error state visible; rest of agora unaffected | `t_mp_error_isolated` |
| preview click | brief with preview_url | emits `material-preview-clicked` | `t_mp_preview_emit` |
| collapsible | user clicks header chevron | panel collapses; sessionStorage updated | `t_mp_collapse` |

### 5.5 `<CostPanel>`

**Mission.** Render `useCostState`'s two-track view: live counters (zero-latency) + authoritative cost (periodic poll).

```typescript
interface CostPanelProps {
  meeting_id: string;
}
// no emits
```

**State derivation.** `useCostState(meeting_id).cost.value` (per `01b` §5.4).

**Rendering.**
- Top row: `{events_message_count} turns · {events_tool_count} tools so far`
- Bottom row: `${authoritative_cost_usd}` (formatted) `(as of {authoritative_as_of})`
- If no authoritative yet: bottom row shows `Calculating cost…` with spinner.
- If `is_finalized`: prefix "Final cost: $X.XX".
- If error in last poll (`cost.error.value` non-null): show small warning `⚠ Cost stale` next to the timestamp; tooltip with the error.

**Accessibility.**
- Numeric values have `aria-label` reading the full description (e.g., `aria-label="Authoritative cost as of 2:23 PM: $0.18"`).

**Test rows**:

| scenario | cost state | expected | test_id |
|---|---|---|---|
| live counts only | no authoritative yet | top row shown; bottom shows "Calculating…" | `t_cp_live_only` |
| authoritative arrives | poll succeeds | bottom row shows "$0.18 (as of …)" | `t_cp_authoritative_render` |
| poll error | last poll failed | "Cost stale" warning + tooltip | `t_cp_stale_warning` |
| finalization | `is_finalized=true` | "Final cost: …" prefix | `t_cp_final` |

### 5.6 `<EvidencePopover>`

**Mission.** Anchored overlay that opens when user clicks an evidence chip; lazily computes the provenance via `useProvenance(meeting_id, claim_id)`.

```typescript
interface EvidencePopoverProps {
  meeting_id: string;
  claim_id:   string;
  anchor_el:  HTMLElement | null;       // for positioning; null = centered modal fallback
}

interface EvidencePopoverEmits {
  (e: "close"): void;
  (e: "view-full-clicked"): void;       // opens ProvenanceModal
}
```

**State derivation.** `useProvenance(meeting_id, claim_id).trace.value` (per `01b` §6).

**Rendering.**
- Header: "Evidence for: <truncated claim content>"
- Body: list of evidence links (max 8 visible; "Show all (N)" link → emits `view-full-clicked`).
- Each link: source kind icon + excerpt + relation badge.
- Footer: "Loaded from: stream / outcome / both" diagnostic (small gray text).
- Loading: spinner.
- Empty: "No evidence cited for this claim."

**Positioning.**
- Anchored to `anchor_el` (the chip); placed below by default.
- If insufficient space below: placed above; if neither fits: centered modal fallback.
- Closes on: ESC, outside click, scroll, route change.

**Test rows**:

| scenario | trace state | expected | test_id |
|---|---|---|---|
| 3 evidence links | trace populated | 3 rows + footer | `t_ep_render` |
| empty | no evidence | empty-state | `t_ep_empty` |
| > 8 links | trace has 12 | first 8 + "Show all (12)" link | `t_ep_truncate_show_more` |
| loading | trace null + is_loading | spinner | `t_ep_loading` |
| close on ESC | popover open | closes; emits `close` | `t_ep_close_esc` |
| close on outside click | click outside | closes | `t_ep_close_outside` |
| anchor flip | insufficient space below | renders above | `t_ep_anchor_flip` |
| view full emit | click "Show all" | emits `view-full-clicked` | `t_ep_view_full` |

### 5.7 `<ProvenanceModal>`

**Mission.** Full-screen modal showing the complete evidence chain as a tree visualization.

```typescript
interface ProvenanceModalProps {
  meeting_id: string;
  claim_id:   string;
  open:       boolean;
}

interface ProvenanceModalEmits {
  (e: "update:open", value: boolean): void;
}
```

**Rendering.**
- Tree visualization (depth-first, indented list; each node = one claim or material/url with relation arrow).
- Header: full claim content + sticky close button.
- Truncation banner if `trace.truncated`: "Showing first 200 links; some chains may be incomplete."
- Footer: "Loaded from: stream / outcome / both"; "Recompute" button (forces fresh derivation by bumping `claim_id` watcher).

**Accessibility.**
- Modal: `role="dialog" aria-modal="true" aria-labelledby="provenance-modal-title"`.
- Focus trap; ESC closes.
- Tree items keyboard-navigable.

**Test rows**:

| scenario | trace state | expected | test_id |
|---|---|---|---|
| simple chain | 3 linear links | tree with 3 levels | `t_pm_render_chain` |
| truncated | `trace.truncated=true` | banner visible | `t_pm_truncated_banner` |
| recompute | user clicks button | trace re-derives | `t_pm_recompute` |
| ESC closes | open + ESC | emits `update:open false` | `t_pm_esc` |
| focus trap | tab past last element | wraps to first | `t_pm_focus_trap` |

---

## §6 v0.2-deferred UX gaps (from `01-studio-client-spec.md` §11)

Agora documents these as visible-to-user limitations:

### 6.1 No Stop button (per `01` §11.1)

- Header does NOT show a Stop / Pause / Resume control in v0.1.
- When the user navigates away from a `live` meeting, a small ephemeral toast notes: "Meeting will continue running on studio. You can come back via Knowledge."
- No `beforeunload` block — the toast on navigate is enough; intercepting tab close is too aggressive for an internal product.
- A documented v0.2 task: surface the buttons once studio adds endpoints.

### 6.2 No human-input injection (per `01` §11.2)

- DiscussionStream renders existing `UserInjected` events (from prior CLI / API injection) but provides no UI to create new ones.
- `<UserInjectedCard>` exists for reading; no submit form.
- v0.2 task documented.

### 6.3 No replay scrubbing

- The view always shows live-up-to-now state; users cannot "rewind" to an earlier `event_id` in v0.1.
- Reconnect uses live `Last-Event-Id` (per `01b` §2.4); not user-controllable.
- v0.2 may add a timeline scrubber.

---

## §7 Materials descriptor source

`<MaterialsPanel>` consumes `useMaterialsList(meeting_id)` which calls:

```
GET /api/meetings/{meeting_id}/materials
  auth: required (platform:run_meeting)
  200:  list[MaterialDescriptor]
  401:  AuthRequired
  403:  PermissionDenied
  404:  MeetingNotFound  (apps/api has no row for this meeting)
```

Endpoint is hosted by apps/api (spec 15). Storage:

- At wizard-driven `run_meeting` time (spec 10), wizard POSTs material descriptors to apps/api alongside the studio call. Apps/api persists them in a small `meeting_metadata` SQLite table (key: `meeting_id`).
- For meetings started outside the wizard (CLI scripts, future admin paths), the table will be empty — `<MaterialsPanel>` shows the empty state. This is acceptable degradation; agora's main view is the stream + reductions.

Schema in apps/api (forward-declared here, fully specced in 15):

```sql
CREATE TABLE meeting_metadata (
    meeting_id  TEXT PRIMARY KEY,
    project_id  TEXT NOT NULL,
    user_id     TEXT NOT NULL,
    topic       TEXT NOT NULL,
    materials   TEXT NOT NULL,        -- JSON list of MaterialDescriptor
    created_at  TEXT NOT NULL
);
```

---

## §8 i18n keys

Every user-visible string introduced by agora. Lives at `packages/platform-features/agora/src/i18n/{zh,en}.json`. Merged into vue-i18n at feature load under namespace `feature.agora.*`.

```json
{
  "feature.agora.title": "Agora",
  "feature.agora.status.subscribing": "Connecting…",
  "feature.agora.status.live":        "Live",
  "feature.agora.status.completed":   "Completed",
  "feature.agora.status.failed":      "Failed",
  "feature.agora.status.disconnected":"Reconnecting…",
  "feature.agora.status.lost":        "Stream lost",
  "feature.agora.status.not_found":   "Meeting not found",

  "feature.agora.lost_modal.title":       "Stream lost",
  "feature.agora.lost_modal.body":        "The connection to studio was lost. Refresh to reload from the start.",
  "feature.agora.lost_modal.refresh":     "Refresh",

  "feature.agora.failed_banner.title":    "Meeting failed",
  "feature.agora.failed_banner.go_back":  "Back",

  "feature.agora.discussion.empty":       "Awaiting events…",
  "feature.agora.discussion.new_pill":    "{count} new events",
  "feature.agora.discussion.unknown_event": "(unknown event type)",

  "feature.agora.dag.empty":              "Graph will appear as claims arrive.",
  "feature.agora.dag.summary_label":      "Graph: {nodes} nodes ({agreed} agreed, {contested} contested), {edges} edges.",
  "feature.agora.dag.too_large":          "Graph too large to render in v0.1.",

  "feature.agora.outcome.empty":          "Awaiting claims…",
  "feature.agora.outcome.section.agreed":     "Agreed",
  "feature.agora.outcome.section.resolved":   "Resolved",
  "feature.agora.outcome.section.contested":  "Contested",
  "feature.agora.outcome.section.active":     "In discussion",
  "feature.agora.outcome.toggle_compare":     "View working consensus alongside",
  "feature.agora.outcome.view_report":        "View report",

  "feature.agora.materials.empty":            "No materials attached.",
  "feature.agora.materials.error":            "Materials unavailable.",
  "feature.agora.materials.collapse":         "Collapse materials",

  "feature.agora.cost.live":              "{turns} turns · {tools} tools so far",
  "feature.agora.cost.authoritative":     "${cost} (as of {time})",
  "feature.agora.cost.calculating":       "Calculating cost…",
  "feature.agora.cost.final":             "Final cost: ${cost}",
  "feature.agora.cost.stale_warning":     "Cost figure is stale; last poll failed.",

  "feature.agora.evidence.popover.title": "Evidence for: {claim}",
  "feature.agora.evidence.popover.empty": "No evidence cited for this claim.",
  "feature.agora.evidence.popover.show_all": "Show all ({count})",
  "feature.agora.evidence.popover.loaded_from.stream":  "Loaded from event stream",
  "feature.agora.evidence.popover.loaded_from.outcome": "Loaded from outcome",
  "feature.agora.evidence.popover.loaded_from.both":    "Loaded from event stream + outcome",

  "feature.agora.provenance.modal.title":    "Provenance: {claim}",
  "feature.agora.provenance.modal.truncated":"Showing first {limit} links; deeper chains may be incomplete.",
  "feature.agora.provenance.modal.recompute":"Recompute",

  "feature.agora.gap.no_stop_button":     "Meeting will continue running on studio. You can come back via Knowledge.",
  "feature.agora.gap.no_human_input":     "Mid-meeting input is not available in this version."
}
```

`zh.json` mirrors with Chinese.

---

## §9 Test matrix — top-level

In addition to per-component test rows above, AgoraView has integration tests:

| scenario | preconditions | expected | test_id |
|---|---|---|---|
| boot from wizard | run_meeting just returned; navigate | spinner → live → events flow | `t_av_boot_from_wizard` |
| boot from knowledge | completed meeting URL | spinner → events replay → `completed` state | `t_av_boot_from_knowledge` |
| direct URL on running meeting | live meeting | spinner → live | `t_av_direct_live` |
| meeting_id missing | `/platform/agora` (no id) | redirected to `/platform/knowledge` | `t_av_no_id_redirect` |
| meeting_id not found | studio returns MeetingNotFound | `not_found` state; 404 page | `t_av_not_found` |
| permission denied at route | user lacks `platform:run_meeting` | redirected to dashboard with toast (per `02` §4.1) | `t_av_permission_denied` |
| transient disconnect | stream drops, then reconnects | yellow bar → resumes; events keep flowing | `t_av_disconnect_resume` |
| lost cursor | `StreamUnavailable` on reconnect | modal appears; `Refresh` button calls `forceFullReload` | `t_av_lost_modal` |
| meeting fails mid-stream | `meeting_failed` event | red banner; last good UI state preserved | `t_av_meeting_failed` |
| meeting finalizes | `meeting_finalized` event | `completed` state; OutcomePanel switches to authoritative; "View report" visible | `t_av_finalization` |
| route param change | nav from one meeting_id to another | old store ref-counted down; new store + reducers spin up | `t_av_meeting_id_change` |
| navigate away while live | user clicks back | toast: "meeting will continue…"; subscription torn down via ref-count | `t_av_navigate_away_live` |
| evidence chip → popover → modal | click chip → click "Show all" | popover opens; modal opens; both close cleanly | `t_av_evidence_flow` |
| mobile layout | viewport 375px wide | tab bar visible; default tab = Discussion | `t_av_mobile_layout` |
| forward-compat unknown event | studio adds new EventType | DiscussionStream renders generic card; DAG/outcome/cost ignore (per `01b` rules); no crash | `[SUB] t_av_forward_compat_event` |

`[SUB]` markers apply where the test exercises StudioClient indirectly (forward-compat is one such; the rest are handled by 01 / 01b's substitution suites).

---

## §10 Why this design — load-bearing decisions

**Why agora has zero backend code (beyond the materials metadata endpoint).**
Per **P3**, all deliberation logic is studio's. The materials endpoint is product-side metadata (what the user submitted at run_meeting) — studio doesn't store this for replay. Putting any other logic in agora's backend would re-introduce the engine-coupling we explicitly avoided in 01.
*Considered and rejected.* **Backend-side outcome reducer** (e.g., compute working consensus on the server, push to the client) — duplicates `01b`'s logic; couples to studio's event shape; defeats the streaming-UI purpose.

**Why the 7-component layout is fixed.**
Configurable layouts add complexity (drag/drop, persistence, conflict resolution across users) for a v0.1 product whose deliberation UX is still being learned. Fixed layout = uniform user experience = easier to reason about + easier to evolve. Mobile collapse is the only deviation.
*Considered and rejected.* **User-configurable panel positions** — premature; v0.2 if user feedback demands.

**Why InternalStep is hidden by default with no toggle in v0.1.**
`InternalStep` is engine-level diagnostic noise; surfacing it confuses end users. A toggle would be a feature flag that 99% of users never use. v0.2 may add a debug toggle in settings if engineering needs it.
*Considered and rejected.* **Toggle in v0.1** — clutter. **Always show** — noisy.

**Why DAG renders client-side (D3 force layout), not pre-rendered server-side.**
Reactive updates (one event = node added) demand client-side recomputation; server-side would require pushing fresh SVG every event. D3 in-browser is the standard tool. Performance fallback above 200/1000 nodes documented.
*Considered and rejected.* **Server-rendered SVG per event** — bandwidth + latency. **Static screenshots on demand** — loses interactivity.

**Why finalization shows authoritative by default with toggle to compare.**
Authoritative `MeetingOutcome` is studio's source of truth (per `01` §5.1); showing it primarily prevents users from acting on stale working state. The toggle lets curious users compare for trust-building / debugging.
*Considered and rejected.* **Always show working** — stale post-finalization. **Always show authoritative, no toggle** — loses transparency.

**Why MaterialsPanel fetches from product API, not studio.**
Studio doesn't store inputs for retrieval (per `01` §11). Materials are product-side metadata; product knows what the user uploaded. Fetching from product is the only honest path.
*Considered and rejected.* **Show nothing** — UX regression. **Re-derive from event log** — events don't carry the inputs.

**Why no Stop button in v0.1 (gap surfaced as a toast, not a modal).**
Per `01` §11.1, no studio endpoint exists. A modal warning every navigate would train users to dismiss modals. A toast is informational + non-blocking.
*Considered and rejected.* **Modal "Are you sure?" on navigate** — over-blocking. **`beforeunload` block** — aggressive; broken on reload.

**Why per-event-type render component registry, not one giant switch in DiscussionStream.**
26 event types (and growing); a switch becomes 200+ lines. Registry pattern: one tiny file per type; each is independently testable; new types are additive (new file + entry in registry).
*Considered and rejected.* **Single render switch** — bloated, fragile. **Generic pre-styled card with markdown** — loses visual differentiation that helps users parse the stream.

**Why auto-follow with pause-on-scroll-up.**
The default is "always show me new", which matches the live UX. But when users scroll up to read context, they don't want to be dragged back down. The pill ("↓ N new") gives explicit re-engagement. Standard pattern from chat UIs.
*Considered and rejected.* **Always auto-follow** — disruptive. **Never auto-follow** — defeats live UX.

**Why useFinalizationToggle is a separate composable, not inline in OutcomePanel.**
The toggle's state (which view to show post-finalization) might be consumed elsewhere in v0.2 (e.g., reports may want to show "based on working state at clock N" if a user demands). Composable extraction prevents a future refactor.
*Considered and rejected.* **Inline ref in OutcomePanel** — fine for now, but scoped too narrowly.

---

## §11 Downstream impact

| Spec | Adjustment |
|---|---|
| `06-feature-reports-spec.md` | "View report" in `<OutcomePanel>` navigates to `/platform/reports?meeting_id=<id>`. Reports view consumes the same `OutcomeResponse` from `get_meeting_outcome`. |
| `07-feature-knowledge-spec.md` | Knowledge browser links each meeting row to `/platform/agora/<id>`. Same view; AgoraView handles completed meetings via the existing replay path. |
| `09-feature-uploads-spec.md` | Defines the preview overlay opened by `<MaterialsPanel>` `material-preview-clicked`. Defines `preview_url` shape. |
| `10-feature-wizard-spec.md` | Wizard's run_meeting handoff: posts `MaterialDescriptor[]` to `POST /api/meetings/{id}/metadata`, then `router.push` to agora. |
| `12-feature-observability-spec.md` | No direct dependency; observability dashboards query `get_cost_report` separately. |
| `15-apps-api-spec.md` | Hosts `GET /api/meetings/{id}/materials` + `POST /api/meetings/{id}/metadata` + the `meeting_metadata` SQLite table. |
| `16-apps-frontend-spec.md` | Imports `agoraRoutes` from this package; wires D3 dependency in `package.json`. |
| `17-substitution-tests-spec.md` | The `[SUB]` row in §9 (forward-compat for unknown event types) joins the substitution suite. |
| `18-end-to-end-scenarios-spec.md` | E2E scenarios "user runs a meeting" + "user revisits a finalized meeting" both land in agora; lifecycle covered. |

---

## §12 Pre-merge checklist

- [ ] Mission + Scope present; v0.1 out-of-scope listed (no Stop button, no human input UI, no replay scrubber, no DAG editing, no real-time collab, no per-event filters, fixed layout)
- [ ] Module layout (§1) enumerates every file (cards/, composables, permissions, routes, i18n)
- [ ] Permissions declared (§1.1) + Routes declared (§1.2) match `02` §4 + `03` §5.3
- [ ] 3 entry flows (§2) documented
- [ ] AgoraView lifecycle (§3) declares the 7 status visual states + transitions
- [ ] Layout (§4) covers desktop / tablet / mobile breakpoints + collapse semantics
- [ ] All 7 components (§5) have full TS prop / emit / slot signatures + state derivation + per-event render rules + accessibility + test rows
- [ ] Per-event-type render rules (§5.0) cover all 26 event types (24 EventType + 2 studio-injected) + forward-compat for unknowns
- [ ] v0.2 UX gaps (§6) documented with user-facing language (toast strings; not "TODO" comments)
- [ ] Materials descriptor source (§7) cross-references apps/api spec 15
- [ ] i18n keys (§8) cover every user-visible string with en values; namespaced under `feature.agora.*`
- [ ] AgoraView integration tests (§9) cover boot from wizard / knowledge / direct, all 7 status transitions, route changes, navigation, mobile layout, forward-compat
- [ ] Why-this / why-not blocks (§10) for ≥ 8 load-bearing decisions
- [ ] Downstream impact (§11) lists every spec that integrates
- [ ] No business / domain / product / agent-role string literals (uses neutral `agent-architect`, `vertical-a`, `c1`, etc.)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No backend Python in this package (confirmed by §1 module layout)
- [ ] Forward-compat for unknown event types verified (no hard-coded 26-only handler)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/05-feature-agora-spec.md`
