# 01b — Product-side derivations spec

> **Status**: v0.1 contract for the four product-side reducers that consume studio's `MeetingEvent` stream and produce UI state.
> **Lives at**: `packages/platform-shell/` (shared meeting-stream store) + `packages/platform-features/agora/` (the four reducers).
> **Upstream contract**: [`01-studio-client-spec.md`](./01-studio-client-spec.md) §6 (MeetingEvent), §7.8 (subscribe_meeting), §5.1 (MeetingOutcome).
> **Referenced from**: `01-studio-client-spec.md` §11.5 / §11.6 / §11.7 / §15 Batch C.

---

## Mission

This file defines the four product-side reducers — `useOutcomeReducer`, `useDagState`, `useCostState`, `useProvenance` — and the shared `useMeetingStreamStore` they sit on top of, so that agora (and any other feature that consumes a meeting's live state) can render working consensus, the live deliberation DAG, live cost, and on-demand provenance from studio's raw 24-EventType stream **without re-implementing the reduction logic anywhere else**.

**Hard rule**: these reducers are PRODUCT-SIDE derivations. Studio does not provide pre-derived working outcome / DAG / provenance / live cost. Every transformation here happens in product code, fed by `StudioClient.subscribe_meeting`'s yielded events.

---

## Scope

**Covers.**
- The shared `useMeetingStreamStore(meeting_id)` Pinia store: SSE subscription lifecycle, event log retention, reconnect with `Last-Event-Id`, status surfacing.
- Four composables that read from the store and produce reactive UI state:
  - `useOutcomeReducer(meeting_id)` → `WorkingConsensus`
  - `useDagState(meeting_id)` → `DagSnapshot`
  - `useCostState(meeting_id)` → `LiveCost`
  - `useProvenance(meeting_id, claim_id)` → `ProvenanceTrace` (on-demand)
- For each: input event subset (which `event_type`s it consumes), state-machine transitions, output state shape (TS interface), idempotency guarantee, reconnect / late-join / replay semantics, lifecycle (subscribe / dispose / reset), test matrix.
- Cross-cutting: subscription sharing across reducers, error handling, in-memory log retention, finalization handling.

**Does not cover.**
- Component-tree wiring (which Vue component reads which reducer) — that's `05-feature-agora-spec.md`.
- The `StudioClient.subscribe_meeting` Protocol method itself (signature, raises, `Last-Event-Id` semantics) — that's `01-studio-client-spec.md` §7.8.
- The 24+2 `EventType` literal list, `MeetingEvent` shape, or `MeetingOutcome` shape — those mirror studio §6 / §5.1 and live in `01-studio-client-spec.md` §6 / §5.
- Backend (`apps/api`) SSE proxying — that's `15-apps-api-spec.md`.
- Cost dashboards (historical `get_cost_report` queries) — that's `12-feature-observability-spec.md`. This spec covers only **live** cost during an active meeting.
- Error mapping (studio→product) — done by `HttpStudioClient` per `01-studio-client-spec.md` §8.2.

**Out of scope for v0.1.**
- Streaming the reducer state to other tabs / browsers (no cross-tab broadcast yet).
- Persisting reducer state to local storage for offline browsing (always re-subscribe and replay on mount in v0.1).
- Differential snapshots between reducer ticks (UI re-renders the whole reactive state).

---

## §1 Upstream contract anchor

| What this spec depends on | Where it lives |
|---|---|
| `MeetingEvent { event_id, event_type, data }` | `01-studio-client-spec.md` §6.2 |
| The 26 frozen `event_type` literals (24 EventType + `meeting_finalized` + `meeting_failed`) | `01-studio-client-spec.md` §6.1 (mirrors studio §6.2 + §6.4) |
| `subscribe_meeting(meeting_id, last_event_id=None) -> AsyncIterator[MeetingEvent]` | `01-studio-client-spec.md` §7.8 |
| Per-event payload TypedDicts (`ClaimMadeData`, `ConsensusReachedData`, `MessageEmittedData`, `MeetingFinalizedData`, `MeetingFailedData`) | `01-studio-client-spec.md` §6.3 |
| `OutcomeResponse` + `MeetingOutcome` (consensus / unresolved_disagreements / key_facts / open_questions) | `01-studio-client-spec.md` §5.1 |
| `get_cost_report(meeting_id=m)` (used by `useCostState` for authoritative numbers) | `01-studio-client-spec.md` §7.10 |
| Sealed product-side error taxonomy (`StudioUnavailable`, `StreamUnavailable`, `MeetingNotReady`, `MeetingFailed`, `NotFound`, …) | `01-studio-client-spec.md` §8.1 |

If any payload field referenced below ever changes, the change must originate in studio's contract → `01-studio-client-spec.md` updates → this spec updates. Drift in either direction is a bug.

---

## §2 Common pattern: `useMeetingStreamStore`

The four reducers do not each open their own SSE subscription. **One subscription per meeting**, shared. The store is a Pinia instance keyed by `meeting_id`.

### 2.1 Module location

`packages/platform-shell/src/composables/useMeetingStreamStore.ts`

(Lives in **shell** because chathub also consumes meeting streams; the store is not agora-specific. Reducers themselves are in agora.)

### 2.2 Store state

```typescript
import type { MeetingEvent, MeetingOutcome, ErrorBody } from "@entelecheia/studio-client";

export type StreamStatus =
  | "idle"             // before subscribe
  | "subscribing"      // SSE handshake in progress
  | "live"             // receiving events
  | "completed"        // meeting_finalized seen, iterator ended
  | "failed"           // meeting_failed seen, iterator ended
  | "disconnected"     // SSE connection dropped, awaiting reconnect
  | "lost";            // reconnect failed (StreamUnavailable); operator action required

export interface MeetingStreamState {
  meeting_id:           string;
  status:               StreamStatus;
  events:               MeetingEvent[];        // append-only log; full retention for the meeting's lifetime
  last_event_id:        number;                // highest event_id seen; used for reconnect cursor
  last_error:           string | null;         // human-readable; populated on failure modes
  finalized_outcome:    MeetingOutcome | null; // set when status === "completed"
  failure_reason:       ErrorBody | null;      // set when status === "failed"
  subscriber_count:     number;                // ref count; auto-unsubscribe at 0
  subscribed_at:        string | null;         // ISO-8601 of last subscribe
}
```

### 2.3 Store actions

```typescript
export interface MeetingStreamStore {
  // State (reactive refs)
  state:                Ref<MeetingStreamState>;

  // Lifecycle — all idempotent
  subscribe():          Promise<void>;        // increments subscriber_count; ensures live subscription
  unsubscribe():        Promise<void>;        // decrements subscriber_count; closes subscription if 0
  reconnect():          Promise<void>;        // re-subscribes from last_event_id; called on transient drops
  reset():              void;                 // wipes events log + state; used when meeting_id changes
  forceFullReload():    Promise<void>;        // re-subscribes from event_id=0; used on "lost" → recovery
}
```

### 2.4 Behavior contract

- **Single subscription per `meeting_id`.** Pinia store is keyed by `meeting_id`; multiple components calling `useMeetingStreamStore("mtg_abc")` get the same instance.
- **Reference counting.** First `subscribe()` opens the SSE; last `unsubscribe()` closes it. Reducers always pair `subscribe()` with `unsubscribe()` in their lifecycle hooks.
- **Append-only event log.** Every received event is pushed to `state.events` in `event_id` order. Reducers watch this array reactively.
- **Reconnect on transient drop.** When the underlying `subscribe_meeting` AsyncIterator throws `StudioUnavailable` (network blip), the store transitions to `"disconnected"`, waits with exponential backoff (1s / 2s / 4s / 8s, max 30s), then calls `reconnect()` with `last_event_id = state.last_event_id`. Studio's `Last-Event-Id` semantics (per `01-studio-client-spec.md` §7.8 + studio §6.3) ensure no duplicates and no gaps.
- **Termination.** On `meeting_finalized`, transition to `"completed"`; populate `finalized_outcome` from the event payload. On `meeting_failed`, transition to `"failed"`; populate `failure_reason`. In both cases, close the subscription.
- **Lost cursor.** If `reconnect()` raises `StreamUnavailable` (studio's archive evicted our cursor — should be very rare), transition to `"lost"`; UI surfaces "Stream lost — refresh to recover", and `forceFullReload()` is the recovery action (subscribes from event_id=0, then drops every reducer's state via `reset()` + replay).
- **Late join is identical to subscribe.** A reducer mounted mid-meeting calls `subscribe()`; the store is already live; the reducer reads `state.events` (already populated with all past events) and folds them. No special "catch-up" code path.

### 2.5 Test matrix (substitution-eligible — runs against PseudoStudioClient + future HttpStudioClient)

| scenario | input | expected | test_id |
|---|---|---|---|
| first subscribe, live meeting | `subscribe()` on running meeting | status: `live`, events fill incrementally | `[SUB] t_mss_first_subscribe_live` |
| first subscribe, completed meeting | `subscribe()` on completed meeting | events fill from id=0, ends with `meeting_finalized`, status: `completed` | `[SUB] t_mss_first_subscribe_completed` |
| late join | second component calls `subscribe()` after first has been live for N events | second sees the same `state.events` (no double-subscribe to studio) | `[SUB] t_mss_late_join` |
| transient drop | studio drops connection mid-stream | status: `disconnected` → backoff → `live`; no duplicate events | `[SUB] t_mss_transient_drop` |
| meeting finalizes | `meeting_finalized` arrives | status: `completed`, `finalized_outcome` populated, no further events accepted | `[SUB] t_mss_finalized` |
| meeting fails | `meeting_failed` arrives | status: `failed`, `failure_reason` populated | `[SUB] t_mss_failed` |
| cursor lost | reconnect raises `StreamUnavailable` | status: `lost`; `forceFullReload()` recovers | `[SUB] t_mss_cursor_lost` |
| ref-count auto-unsubscribe | last subscriber unsubscribes | underlying subscription closed; store keeps state for re-subscribe | `[SUB] t_mss_refcount_close` |
| meeting_id change | component remounts with different `meeting_id` | old store ref-counted down; new store created | `[SUB] t_mss_meeting_id_change` |

---

## §3 Reducer 1 — `useOutcomeReducer`

Folds the deliberation event stream into a "working consensus" view: which claims are on the table, which are contested, which are agreed, plus contradictions raised. When `meeting_finalized` arrives, also exposes the authoritative `MeetingOutcome` from studio.

### 3.1 Module location

`packages/platform-features/agora/src/composables/useOutcomeReducer.ts`

### 3.2 Composable signature

```typescript
import type { Ref, ComputedRef } from "vue";

export function useOutcomeReducer(meeting_id: string): {
  consensus:        ComputedRef<WorkingConsensus>;
  is_finalized:     ComputedRef<boolean>;
  finalized:        ComputedRef<MeetingOutcome | null>;
  is_loading:       ComputedRef<boolean>;        // true while initial replay is in progress
  error:            ComputedRef<string | null>;  // surfaces underlying stream errors
};
```

### 3.3 Input event subset (6 of 26)

Consumes ONLY these `event_type`s. All others are no-ops at this reducer.

| `event_type` | Effect |
|---|---|
| `ClaimMade` | Insert or merge a `WorkingClaim` keyed by `claim_id` |
| `ChallengeRaised` | Mark target claim `state = "contested"`, append challenge, add challenger to `contestants` |
| `ChallengeResolved` | Mark target claim `state = "resolved"` (was "contested") |
| `ConsensusReached` | Mark each `claim_id` in payload `state = "agreed"` |
| `ContradictionFound` | Append to `contradictions` list |
| `meeting_finalized` | Set `is_finalized = true`; store `finalized` from `data.outcome` |

### 3.4 Output state

```typescript
export type ClaimState = "active" | "contested" | "resolved" | "agreed";

export interface ChallengeRecord {
  event_id:    number;
  by:          string;          // agent_id of the challenger
  content:     string | null;   // challenge text if present in payload
}

export interface WorkingClaim {
  claim_id:                 string;
  content:                  string;          // first ClaimMade.content; immutable thereafter
  asserted_by:              string;          // first ClaimMade.asserted_by; immutable
  state:                    ClaimState;
  contestants:              string[];        // unique agent_ids
  challenges:               ChallengeRecord[];
  first_seen_event_id:      number;
  last_modified_event_id:   number;
}

export interface ContradictionRecord {
  event_id:           number;
  content:            string;                // ContradictionFound.data.content
  related_claim_ids:  string[];              // from payload, may be empty
}

export interface WorkingConsensus {
  meeting_id:        string;
  claims:            WorkingClaim[];         // ordered by first_seen_event_id ascending
  contradictions:    ContradictionRecord[];  // ordered by event_id ascending
  last_event_id:     number;                 // highest event_id this reducer has folded
}
```

### 3.5 State machine

For each `event` arriving from `useMeetingStreamStore.state.events`, in `event_id` order:

```
match event.event_type:
  case "ClaimMade":
    cm = event.data as ClaimMadeData
    if cm.claim_id not in claims:
      claims.append(WorkingClaim{
        claim_id: cm.claim_id,
        content: cm.content,
        asserted_by: cm.asserted_by,
        state: "active",
        contestants: [],
        challenges: [],
        first_seen_event_id: event.event_id,
        last_modified_event_id: event.event_id,
      })
    else:
      no-op  # claims are immutable on content/asserted_by; idempotent re-receive

  case "ChallengeRaised":
    target_id = event.data.claim_id
    by = event.data.by
    if target_id in claims:
      c = claims[target_id]
      c.state = "contested"  # only if not already "agreed"; "agreed" wins (see 3.7)
      if by not in c.contestants:
        c.contestants.append(by)
      c.challenges.append(ChallengeRecord{event_id, by, content: event.data.content ?? null})
      c.last_modified_event_id = event.event_id

  case "ChallengeResolved":
    target_id = event.data.claim_id
    if target_id in claims and claims[target_id].state == "contested":
      claims[target_id].state = "resolved"
      claims[target_id].last_modified_event_id = event.event_id

  case "ConsensusReached":
    for cid in event.data.claim_ids:
      if cid in claims:
        claims[cid].state = "agreed"  # terminal; not overridden by later challenges
        claims[cid].last_modified_event_id = event.event_id

  case "ContradictionFound":
    contradictions.append(ContradictionRecord{
      event_id: event.event_id,
      content: event.data.content,
      related_claim_ids: event.data.related_claim_ids ?? [],
    })

  case "meeting_finalized":
    is_finalized = true
    finalized = event.data.outcome  # OutcomeResponse → .outcome → MeetingOutcome

  case _:
    no-op

last_event_id = max(last_event_id, event.event_id)
```

### 3.6 Idempotency rule

Re-applying the same event N times produces the same final state as applying it once. Achieved by:
- `ClaimMade` is upsert-by-`claim_id`; second arrival is no-op.
- `ChallengeRaised`'s contestant addition checks `if by not in c.contestants`.
- `ChallengeRaised`'s challenges-list append is keyed by `event_id`; the reducer rejects an append whose `event_id <= last_event_id` (defensive — studio guarantees monotonic ordering, but the reducer doesn't trust it).
- `ContradictionFound` similarly keyed by `event_id`.
- Terminal states (`"agreed"`) are sticky: once a claim is `"agreed"`, later `ChallengeRaised` does not move it back to `"contested"` (see 3.7).

### 3.7 Conflict-resolution rules

When event ordering surfaces ambiguity:
- **`ConsensusReached` wins over later `ChallengeRaised`** for the same claim. Once a claim is `"agreed"`, challenges are recorded in `challenges[]` for the audit trail but `state` does not regress. Rationale: studio emits `ConsensusReached` only after agents reach explicit agreement; treating later challenges as "un-agreement" would whipsaw the UI.
- **First `ClaimMade` wins** for `content` and `asserted_by`. Subsequent `ClaimMade`s with the same `claim_id` are no-ops on content (they shouldn't happen per studio's semantics; defensive only).

### 3.8 Reconnect / replay rule

The reducer reads from `useMeetingStreamStore.state.events` (a reactive append-only array). When the store reconnects:
- New events arrive in the array (with `event_id > state.last_event_id`).
- The reducer's `watch` re-runs; folds new events.
- No state reset.

When the store transitions to `"lost"` and `forceFullReload()` is called:
- `reset()` is called on every reducer.
- `state.events` becomes empty, then refills from `event_id=0`.
- Reducer's `watch` re-runs from scratch.

### 3.9 Lifecycle

```typescript
// Inside useOutcomeReducer:
const stream = useMeetingStreamStore(meeting_id);
onMounted(async () => { await stream.subscribe(); });
onUnmounted(async () => { await stream.unsubscribe(); });
watch(() => stream.state.value.events, (newEvents) => {
  // fold from last_event_id + 1
}, { deep: false, flush: "post" });
```

### 3.10 Test matrix

| scenario | input event sequence | expected `consensus` | test_id |
|---|---|---|---|
| empty stream | no events yet | `claims: [], contradictions: [], last_event_id: 0` | `t_or_empty` |
| single claim | one `ClaimMade` | one `WorkingClaim` with `state: "active"` | `t_or_single_claim` |
| claim then challenge | `ClaimMade(c1)` → `ChallengeRaised(c1, by=a2)` | `c1.state = "contested"`, `contestants = [a2]`, `challenges` len 1 | `t_or_claim_challenge` |
| challenge resolved | + `ChallengeResolved(c1)` | `c1.state = "resolved"` | `t_or_challenge_resolved` |
| consensus reached | + `ConsensusReached([c1])` | `c1.state = "agreed"` | `t_or_consensus` |
| consensus then late challenge | `ConsensusReached([c1])` → `ChallengeRaised(c1)` | `c1.state` stays `"agreed"`; challenge appended to audit trail (3.7) | `t_or_consensus_wins_over_late_challenge` |
| contradiction | `ContradictionFound{content:"X"}` | `contradictions` len 1 | `t_or_contradiction` |
| meeting finalized | … → `meeting_finalized{outcome: …}` | `is_finalized = true`, `finalized` populated | `t_or_finalized` |
| idempotent replay | apply same event sequence twice | identical final state | `t_or_idempotent` |
| late mount | mount reducer after 50 events have streamed | reducer folds all 50 from `state.events` on first watch | `t_or_late_mount` |
| reconnect | drop stream after event 30, reconnect, more events arrive | reducer folds events 31+ without resetting | `t_or_reconnect` |
| lost cursor recovery | `forceFullReload()` called | reducer state resets, refolds from event_id=0 | `t_or_lost_recovery` |
| unrelated events ignored | `MessageEmitted`, `ToolCalled`, etc. interleaved | no effect on `consensus` | `t_or_ignores_unrelated` |

---

## §4 Reducer 2 — `useDagState`

Folds the same event stream into a directed graph for the DAG visualizer. Nodes represent claims, agents, evidence references, and triggers; edges represent assertions, challenges, citations, contradictions, and supports.

### 4.1 Module location

`packages/platform-features/agora/src/composables/useDagState.ts`

### 4.2 Composable signature

```typescript
export function useDagState(meeting_id: string): {
  dag:           ComputedRef<DagSnapshot>;
  is_loading:    ComputedRef<boolean>;
  error:         ComputedRef<string | null>;
};
```

### 4.3 Input event subset (6 of 26)

| `event_type` | Effect on graph |
|---|---|
| `ClaimMade` | Add `claim` node + `agent` node (if new) + `asserts` edge |
| `ChallengeRaised` | Add `challenges` edge from challenger agent → claim |
| `EvidenceCited` | Add `evidence` node (if new) + `cites` edge claim → evidence |
| `TriggerDefined` | Add `trigger` node + `triggers` edge (target: most-recent claim if payload doesn't specify) |
| `ContradictionFound` | Add `contradicts` edge between two claims (from payload) |
| `ConsensusReached` | Annotate claim nodes with `state = "agreed"` |

### 4.4 Output state

```typescript
export type DagNodeKind = "claim" | "agent" | "evidence" | "trigger";
export type DagEdgeKind =
  | "asserts"      // agent → claim
  | "challenges"   // agent → claim
  | "cites"        // claim → evidence
  | "contradicts"  // claim → claim
  | "triggers";    // trigger → claim

export interface DagNode {
  id:                  string;          // deterministic; see 4.6
  kind:                DagNodeKind;
  label:               string;          // user-visible; <= 80 chars; truncated with "…"
  state:               "active" | "contested" | "resolved" | "agreed" | null; // for claim nodes only
  source_event_id:     number;          // first event that introduced this node
  payload:             Record<string, string>;  // UI rendering hints (color group, icon, etc.)
}

export interface DagEdge {
  id:                  string;          // deterministic; see 4.6
  source_node_id:      string;
  target_node_id:      string;
  kind:                DagEdgeKind;
  weight:              number;          // 0.0..1.0; UI strength hint; default 1.0
  source_event_id:     number;
}

export interface DagSnapshot {
  meeting_id:        string;
  nodes:             Map<string, DagNode>;
  edges:             Map<string, DagEdge>;
  last_event_id:     number;
}
```

### 4.5 State machine

```
match event.event_type:
  case "ClaimMade":
    upsert_node(id="claim:{cm.claim_id}", kind="claim",
                label=truncate(cm.content, 80), state="active",
                source_event_id=event.event_id)
    upsert_node(id="agent:{cm.asserted_by}", kind="agent",
                label=cm.asserted_by, state=null,
                source_event_id=event.event_id)  # no-op if exists
    upsert_edge(id="agent:{cm.asserted_by}|asserts|claim:{cm.claim_id}",
                source="agent:{cm.asserted_by}", target="claim:{cm.claim_id}",
                kind="asserts", source_event_id=event.event_id)

  case "ChallengeRaised":
    challenger = event.data.by
    target = event.data.claim_id
    upsert_node(id="agent:{challenger}", kind="agent", label=challenger, state=null, ...)
    upsert_edge(id="agent:{challenger}|challenges|claim:{target}",
                source="agent:{challenger}", target="claim:{target}",
                kind="challenges", source_event_id=event.event_id)
    if "claim:{target}" in nodes and nodes["claim:{target}"].state == "active":
      nodes["claim:{target}"].state = "contested"

  case "EvidenceCited":
    ev_id = event.data.evidence_id ?? "ev:" + sha8(event.event_id + event.data.content)
    upsert_node(id="evidence:{ev_id}", kind="evidence",
                label=truncate(event.data.excerpt ?? event.data.url ?? "evidence", 80),
                state=null, source_event_id=event.event_id)
    upsert_edge(id="claim:{event.data.claim_id}|cites|evidence:{ev_id}",
                source="claim:{event.data.claim_id}", target="evidence:{ev_id}",
                kind="cites", source_event_id=event.event_id)

  case "TriggerDefined":
    tr_id = event.data.trigger_id ?? "tr:" + str(event.event_id)
    upsert_node(id="trigger:{tr_id}", kind="trigger",
                label=truncate(event.data.condition ?? "trigger", 80), state=null, ...)
    if event.data.target_claim_id:
      upsert_edge(id="trigger:{tr_id}|triggers|claim:{target}", ...)

  case "ContradictionFound":
    a, b = event.data.claim_a, event.data.claim_b
    if a and b:
      upsert_edge(id="claim:{a}|contradicts|claim:{b}",
                  source="claim:{a}", target="claim:{b}",
                  kind="contradicts", source_event_id=event.event_id)

  case "ConsensusReached":
    for cid in event.data.claim_ids:
      if "claim:{cid}" in nodes:
        nodes["claim:{cid}"].state = "agreed"

  case _:
    no-op

last_event_id = max(last_event_id, event.event_id)
```

`upsert_node` and `upsert_edge` are insert-if-absent; existing nodes/edges are not overwritten on metadata fields except `state` (which is updated by the rules above).

### 4.6 Deterministic ID rules

Critical for idempotency (same event re-applied = no duplicate node/edge). IDs are constructed from event payload, never random:

| Entity | ID format |
|---|---|
| claim node | `"claim:" + claim_id` |
| agent node | `"agent:" + agent_id` |
| evidence node (with ID) | `"evidence:" + evidence_id` |
| evidence node (without ID) | `"evidence:" + sha8(event_id + content)` |
| trigger node (with ID) | `"trigger:" + trigger_id` |
| trigger node (without ID) | `"trigger:" + str(event_id)` |
| any edge | `<source_id> + "|" + kind + "|" + <target_id>` |

`sha8(s)` = first 8 hex chars of `sha256(s)` — short, deterministic, collision-tolerable for v0.1 scale (<10K events per meeting).

### 4.7 Idempotency rule

Same event applied twice = same snapshot. Achieved by deterministic IDs (4.6) + insert-if-absent semantics + `state` transitions that are sticky in the order described in 4.5 (consensus wins, contradiction edges add not toggle).

### 4.8 Reconnect / replay / lifecycle

Identical to §3.8–§3.9. The reducer watches `useMeetingStreamStore.state.events`; reconnect / lost-cursor flows do the same things.

### 4.9 Test matrix

| scenario | events | expected | test_id |
|---|---|---|---|
| empty | none | `nodes: {}, edges: {}, last_event_id: 0` | `t_dag_empty` |
| one claim | `ClaimMade(c1, by=a1)` | 2 nodes (claim + agent), 1 asserts edge | `t_dag_one_claim` |
| same claim twice | `ClaimMade(c1)` × 2 | unchanged from one-claim case | `t_dag_idempotent_claim` |
| challenge | + `ChallengeRaised(c1, by=a2)` | 3 nodes, 2 edges (asserts + challenges); claim state `"contested"` | `t_dag_challenge` |
| evidence cite | + `EvidenceCited(c1, content="…")` | +1 evidence node, +1 cites edge | `t_dag_evidence` |
| same evidence twice | repeat `EvidenceCited` with same content | no duplicate node/edge (sha8 deterministic) | `t_dag_idempotent_evidence` |
| trigger | + `TriggerDefined(target_claim_id=c1)` | +1 trigger node, +1 triggers edge | `t_dag_trigger` |
| contradiction | + `ContradictionFound(c1, c3)` | +1 contradicts edge | `t_dag_contradiction` |
| consensus | + `ConsensusReached([c1])` | claim state `"agreed"` | `t_dag_consensus` |
| late mount | reducer mounted mid-meeting | snapshot reflects entire prior history | `t_dag_late_mount` |
| reconnect | drop + reconnect | snapshot identical to never-dropped run | `t_dag_reconnect_identical` |
| ignored events | `MessageEmitted`, `ToolCalled` arrive | no graph mutation | `t_dag_ignores_unrelated` |

---

## §5 Reducer 3 — `useCostState`

Two-track cost view:

- **Live counter**: increments per `MessageEmitted` / `ToolCalled` event. Zero-latency. **Not authoritative** — does not include token counts or model rates.
- **Authoritative cost**: from `StudioClient.get_cost_report(meeting_id=m)`, polled periodically (default 30 s) and on `meeting_finalized`. Includes USD cost, tokens in/out, duration.

UI shows both: "12 turns / 4 tools so far · $0.18 (as of 14:23:01)".

### 5.1 Module location

`packages/platform-features/agora/src/composables/useCostState.ts`

### 5.2 Composable signature

```typescript
export function useCostState(meeting_id: string, opts?: {
  poll_interval_ms?:   number;           // default 30_000
  client?:             StudioClient;      // injected; default = useStudio()
}): {
  cost:           ComputedRef<LiveCost>;
  is_loading:     ComputedRef<boolean>;   // true during initial fetch
  error:          ComputedRef<string | null>;
};
```

### 5.3 Input event subset (2 of 26 for live count)

| `event_type` | Effect |
|---|---|
| `MessageEmitted` | `events_message_count++` |
| `ToolCalled` | `events_tool_count++`; record tool name in `tools_called` |

Other events are no-ops at this reducer.

### 5.4 Output state

```typescript
export interface LiveCost {
  meeting_id:                string;
  events_message_count:      number;       // count of MessageEmitted seen
  events_tool_count:         number;       // count of ToolCalled seen
  tools_called:              Map<string, number>;  // tool_name → count
  authoritative_cost_usd:    number | null;        // last successful get_cost_report total
  authoritative_tokens_in:   number | null;
  authoritative_tokens_out:  number | null;
  authoritative_as_of:       string | null;        // ISO-8601 of last successful poll
  is_finalized:              boolean;
  last_event_id:             number;
}
```

### 5.5 Polling rules

- On `subscribe()` (mount): initial `get_cost_report(meeting_id=m)` fetch. Store result.
- Every `poll_interval_ms` thereafter: re-fetch. Update `authoritative_*` fields.
- On `meeting_finalized` event: one final `get_cost_report` fetch (typically `total_cost_usd` is now stable). Cancel further polling.
- On `unsubscribe()` (unmount): cancel polling.
- On poll error (`StudioUnavailable` / `NotFound` / `RateLimited`): set `error`, keep last successful values, retry on next interval. Do NOT raise to caller; the live counter still works.

### 5.6 Idempotency

Live counters: sum is a function of (set of events seen). Reducer rejects events with `event_id <= last_event_id` (defensive); the reactive watcher only feeds new events.
Authoritative: each poll overwrites the previous `authoritative_*` snapshot atomically.

### 5.7 Reconnect / replay

After a stream reconnect, late events flow in normally; counters increment. Polling continues independent of stream state (it's HTTP, not SSE).

After `forceFullReload`: counter resets to 0; refolds from `event_id=0`. Authoritative fetched anew.

### 5.8 Test matrix

| scenario | events / actions | expected | test_id |
|---|---|---|---|
| empty | mount, no events, mock cost report = 0 | counters 0; `authoritative_cost_usd: 0` | `t_cs_empty` |
| message events | 5× `MessageEmitted` | `events_message_count: 5` | `t_cs_message_count` |
| tool events | 3× `ToolCalled(name="search")`, 2× `ToolCalled(name="calc")` | `events_tool_count: 5`, `tools_called: {search:3, calc:2}` | `t_cs_tool_count` |
| poll fetches authoritative | wait 30 s; mock returns $0.42 | `authoritative_cost_usd: 0.42`, `authoritative_as_of` set | `t_cs_poll_authoritative` |
| poll error tolerated | poll raises `StudioUnavailable` | `error` set; `authoritative_*` retained from last good poll; counter still increments | `t_cs_poll_error_tolerated` |
| meeting finalized | `meeting_finalized` arrives | one final poll, `is_finalized: true`, polling stops | `t_cs_finalized` |
| ignored events | `ClaimMade`, `ChallengeRaised`, etc. | no effect | `t_cs_ignores_unrelated` |
| concurrent reducers | useOutcomeReducer + useCostState on same meeting | both work; one underlying subscription | `t_cs_concurrent_with_outcome` |

---

## §6 Reducer 4 — `useProvenance`

On-demand. User clicks an evidence chip in agora → composable assembles a provenance trace for the cited claim from `EvidenceCited` events plus `MeetingOutcome.key_facts` (when meeting is finalized).

### 6.1 Module location

`packages/platform-features/agora/src/composables/useProvenance.ts`

### 6.2 Composable signature

```typescript
export function useProvenance(meeting_id: string, claim_id: string): {
  trace:         ComputedRef<ProvenanceTrace | null>;  // null until first computation
  is_loading:    ComputedRef<boolean>;
  error:         ComputedRef<string | null>;
};
```

Unlike the other three reducers, `useProvenance` is **lazy and bounded by `claim_id`**. Mounting it triggers a one-time computation; changes to `claim_id` re-trigger.

### 6.3 Input

| Source | Use |
|---|---|
| `useMeetingStreamStore.state.events` | scan for `EvidenceCited` events with `claim_id` matching (or transitively reachable from) the requested claim |
| `useOutcomeReducer.consensus.value.claims` | (optional) walk claim → claim citations through `evidence_refs` payload field, when `EvidenceCited` references another claim |
| `useMeetingStreamStore.state.finalized_outcome.key_facts` | when meeting is finalized, supplement with outcome-level evidence (studio-distilled facts) |

### 6.4 Output state

```typescript
export type EvidenceSourceKind = "claim" | "material" | "external_url";

export interface EvidenceLink {
  event_id:           number;             // source event in the meeting stream; or -1 for outcome-derived links
  source_kind:        EvidenceSourceKind;
  source_claim_id:    string | null;      // when source_kind === "claim"
  source_material_id: string | null;      // when source_kind === "material"
  source_url:         string | null;      // when source_kind === "external_url"
  excerpt:            string | null;      // short quoted snippet, when studio surfaced one
  relation:           "supports" | "rebuts" | "qualifies";
  weight:             number;             // 0.0..1.0; default 1.0
}

export interface ProvenanceTrace {
  meeting_id:         string;
  root_claim_id:      string;
  links:              EvidenceLink[];     // depth-first traversal order
  truncated:          bool;               // true if traversal exceeded depth_cap (default 8)
  loaded_from:        "stream" | "outcome" | "both";
  computed_at_event_id: number;           // last event_id known to the stream when trace was computed
}
```

### 6.5 Computation rules

```
trace_links = []
visited_claims = {root_claim_id}
queue = [(root_claim_id, depth=0)]
loaded_from_stream = false
loaded_from_outcome = false

while queue not empty and len(trace_links) < max_links (default 200):
  (cid, depth) = queue.popleft()
  if depth > depth_cap (default 8):
    truncated = true
    break

  # Stream-side EvidenceCited events for this claim
  for event in stream.events where event.event_type == "EvidenceCited" and event.data.claim_id == cid:
    loaded_from_stream = true
    link = EvidenceLink{
      event_id: event.event_id,
      source_kind: derive_kind(event.data),
      source_claim_id: event.data.source_claim_id ?? null,
      source_material_id: event.data.material_id ?? null,
      source_url: event.data.url ?? null,
      excerpt: event.data.excerpt ?? null,
      relation: event.data.relation ?? "supports",
      weight: event.data.weight ?? 1.0,
    }
    trace_links.append(link)
    if link.source_claim_id and link.source_claim_id not in visited_claims:
      visited_claims.add(link.source_claim_id)
      queue.append((link.source_claim_id, depth+1))

  # Outcome-side key_facts (when meeting is finalized)
  if stream.state.status == "completed" and stream.state.finalized_outcome:
    for fact in stream.state.finalized_outcome.key_facts:
      if fact.claim_id == cid and fact.evidence not already in trace_links:
        loaded_from_outcome = true
        for ev in fact.evidence:
          trace_links.append(EvidenceLink{
            event_id: -1,                # outcome-derived; no event id
            source_kind: derive_kind(ev),
            ...
          })
```

### 6.6 Idempotency rule

Computing the trace for the same `claim_id` against the same `state.events` and `finalized_outcome` produces an identical `ProvenanceTrace` (same `links` in same order). Achieved by deterministic traversal (depth-first from `root_claim_id`, events scanned in `event_id` order).

### 6.7 Recompute rule

Trace is recomputed when:
- `claim_id` arg changes (different chip clicked).
- `meeting_id` arg changes.
- `state.events.length` increases AND the meeting is still live (catch new evidence) — debounced 500 ms.
- `state.finalized_outcome` transitions from `null` to non-null (meeting just finalized; pull in outcome-level evidence).

NOT recomputed on every reducer-state tick — provenance is cheap to compute but not free; debounce + key-changes are the triggers.

### 6.8 Lifecycle

```typescript
const stream = useMeetingStreamStore(meeting_id);
onMounted(async () => { await stream.subscribe(); /* may be already subscribed */ });
onUnmounted(async () => { await stream.unsubscribe(); });
watch(
  [() => claim_id, () => stream.state.value.events.length, () => stream.state.value.finalized_outcome],
  () => recompute(),
  { flush: "post" }
);
```

### 6.9 Test matrix

| scenario | input | expected | test_id |
|---|---|---|---|
| no evidence | claim has no `EvidenceCited` events | `trace.links: []`, `truncated: false`, `loaded_from: "stream"` | `t_pv_no_evidence` |
| one external URL | one `EvidenceCited{url}` for claim | one link, `source_kind: "external_url"` | `t_pv_one_external` |
| material reference | `EvidenceCited{material_id}` | `source_kind: "material"` | `t_pv_material` |
| claim-to-claim | `EvidenceCited{source_claim_id}` chains 3 deep | 3 links DFS-ordered | `t_pv_claim_chain` |
| cycle protection | claim → A → B → A | A traversed once; no infinite loop | `t_pv_cycle_protected` |
| depth cap | chain length 10 with depth_cap 8 | `truncated: true`, `links.len = 8 worth` | `t_pv_truncated` |
| outcome supplements | meeting finalized, key_facts add evidence | `loaded_from: "both"`, extra links with `event_id: -1` | `t_pv_outcome_merge` |
| recompute on new evidence | new `EvidenceCited` arrives mid-trace | trace re-derives after debounce | `t_pv_recompute_on_new_evidence` |
| claim_id change | composable arg changes | trace re-derives for new claim | `t_pv_arg_change` |

---

## §7 Cross-cutting concerns

### 7.1 Single subscription per meeting

All four reducers + `useMeetingStreamStore`'s subscriber count guarantee exactly one SSE subscription per `meeting_id`, regardless of how many components consume reducers. Verified by `t_mss_late_join` and `t_cs_concurrent_with_outcome`.

### 7.2 Event log retention

`state.events` retains the full meeting log in memory. For v0.1 with bounded meeting sizes (30 s – 180 min, expected <10K events, <10 MB JSON), this is acceptable. v0.2 considerations:
- Sliding window with on-demand re-fetch from studio JSONL.
- IndexedDB persistence for cross-tab / page-reload survival.

Both are out of scope for v0.1.

### 7.3 Backpressure

SSE is push-based; the consumer cannot slow the producer. Strategy: store the entire log (7.2). If a consumer's reducer is slow, the reactive watcher batches updates (`flush: "post"`); consumers read batched snapshots, not individual events. No per-event `await` allowed in any reducer's body.

### 7.4 Error surfacing

Each reducer exposes an `error: ComputedRef<string | null>` derived from `useMeetingStreamStore.state.last_error`. UI components show an error banner; reducer state remains valid (last successfully folded snapshot).

`useCostState` additionally has its own `error` for poll failures; live count is unaffected (7.6 of §5).

### 7.5 Finalization

When `state.status` transitions to `"completed"`:
- `useOutcomeReducer` exposes `finalized` (the authoritative `MeetingOutcome` from the `meeting_finalized` event payload). UI MAY swap from working consensus to authoritative, OR keep both visible (UI choice in spec 05).
- `useDagState` continues to expose the last working DAG snapshot. (Studio's authoritative graph is implicit in `MeetingOutcome.consensus`; product MAY collapse the DAG to those claims for a "clean view" in spec 05.)
- `useCostState` issues one final `get_cost_report`; `is_finalized: true`.
- `useProvenance` becomes more useful — `key_facts` from outcome supplement evidence chains.

### 7.6 Failure

When `state.status` transitions to `"failed"`:
- All reducers expose their last successful snapshots; `error` reflects `state.failure_reason.message`.
- UI shows "Meeting failed" banner; user can navigate to the meeting status page.
- No automatic retry — meetings cannot resume after failure in studio v0.1.

### 7.7 Ordering guarantee

Reducers fold events strictly in `event_id` order. Studio guarantees per-meeting monotonic, gap-free events (`01-studio-client-spec.md` §7.8); the store appends in arrival order, which IS event_id order under that guarantee. Reducers' watchers iterate in array order. Defensive: each reducer rejects events with `event_id <= last_event_id`.

### 7.8 Reset semantics

`reset()` on each reducer clears the derived state (claims, nodes, edges, counters) but does not touch the store's event log. Triggered by `meeting_id` change (component bound to new meeting) or `forceFullReload()` (lost cursor recovery).

---

## §8 i18n

Reducers produce no user-visible strings. Field names (`state: "active" | "contested" | …`) are stable identifiers, not display text. Localization happens in agora components (`05-feature-agora-spec.md`), which map identifiers → localized labels via `packages/platform-shell/i18n/`.

---

## §9 Why this design — consolidated load-bearing decisions

**Why product-side reducers, not studio-side derivations.**
Studio's contract (per `01-studio-client-spec.md` §11) does not provide working outcome / DAG / provenance / live cost as first-class endpoints. Asking studio to derive each view per-client would couple the API to UI choices we want to keep flexible (different verticals may render the DAG differently, want different live-cost granularity, etc.). Reducing client-side keeps studio's surface lean and lets product evolve UI independently.
*Considered and rejected.* **Add `get_working_outcome`, `get_dag_view`, etc. to `StudioClient`** — couples studio to UI cadence; doubles the substitution-test surface; makes vertical-specific UI variations require studio cooperation.

**Why a Pinia store for the stream + composables for reducers, not stores for everything.**
The stream's subscription + event log is **shared cross-component** (multiple agora panels watch one meeting); Pinia's keyed singletons fit. The reducers' derived state is **per-component** (each `<DagViewer>` instance wants its own reactive snapshot to support multiple views or filters); composables with their own refs fit. Forcing reducers into Pinia would either share state across components that should be independent, OR require a Pinia instance per component — neither is what Pinia is for.
*Considered and rejected.* **All-Pinia** — unnecessary singleton-ness for derived state. **All-composable** — would force every component to reopen its own subscription.

**Why one shared event log, not per-reducer event filters.**
Filtering at the store level means each reducer would describe its event subset upfront; the store would maintain N filtered arrays. Memory cost is real (N copies of overlapping subsets). Easier: store keeps one log; reducers filter on watch (`switch (event_type)`). Watch overhead is negligible vs. SSE inbound rate.
*Considered and rejected.* **Per-reducer filtered streams** — extra abstraction with no observable benefit at v0.1 scale.

**Why deterministic node/edge IDs in `useDagState`.**
Idempotency. A reconnect that re-yields events (against studio's contract, but defensive) must not produce duplicate nodes. Random / event-counter IDs would; sha8(payload) + key-by-claim_id approaches are deterministic.
*Considered and rejected.* **Auto-incrementing IDs** — re-application creates dups; reconnect = chaos. **UUIDs at insert time** — same problem.

**Why `ConsensusReached` wins over later `ChallengeRaised` in `useOutcomeReducer`.**
Studio emits `ConsensusReached` only after agents reach explicit agreement. Treating later challenges as un-agreement would whipsaw the UI between "agreed" and "contested" within seconds. The audit trail (`challenges[]`) preserves the post-consensus challenge for review.
*Considered and rejected.* **Strict last-write-wins** — UI flicker; user confusion.

**Why two-track cost (live counter + authoritative poll).**
Live counter is zero-latency (UI ticks per agent turn — feels alive). Authoritative poll is accurate (USD, tokens) but lags ≤ poll_interval. Both shown side-by-side gives users immediate feedback + accurate billing.
*Considered and rejected.* **Live-only** — wrong USD numbers shown to users. **Poll-only** — UI feels dead between polls.

**Why on-demand `useProvenance`, not auto-built per claim.**
Provenance traces can be deep; building one per claim eagerly bloats memory and CPU for views the user never opens. Lazy + per-claim is cheap to recompute (debounce-bounded).
*Considered and rejected.* **Eager build for every claim on every event** — wasteful.

**Why reducer state lives in agora (not platform-shell), but the stream store lives in shell.**
Stream: shared across features (chathub also subscribes to single-agent meetings; observability could too). Reducers: agora-specific UI views. Putting reducers in shell would force every other consumer of meeting streams to import agora's reducer assumptions (claim states, DAG kinds) even when they don't render those views.
*Considered and rejected.* **All in shell** — couples non-agora features to agora's UI vocabulary. **All in agora** — prevents chathub from sharing the subscription.

---

## §10 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | Adds `packages/platform-shell/src/composables/useMeetingStreamStore.ts` to its inventory. Documents the public API (subscribe / unsubscribe / reconnect / reset / forceFullReload). |
| `05-feature-agora-spec.md` | Imports the four reducer composables; specifies the component → reducer mapping (DiscussionStream → useOutcomeReducer + raw events for utterances; DagViewer → useDagState; CostPanel → useCostState; EvidencePopover/ProvenanceModal → useProvenance). Specifies UI behavior on finalization (working vs. authoritative view). |
| `06-feature-reports-spec.md` | Renderer reads `OutcomeResponse` directly via `get_meeting_outcome`; does NOT consume reducers (reducers are live-meeting concerns; reports work on finalized data). |
| `07-feature-knowledge-spec.md` | Knowledge browser uses `list_meetings` + `get_meeting_outcome`; does NOT consume reducers (browses past meetings, no live state). |
| `08-feature-chathub-spec.md` | Chathub uses `useMeetingStreamStore` directly to surface `MessageEmitted` events (and `ToolCalled` if enabled); does NOT need the four reducers. |
| `12-feature-observability-spec.md` | Observability uses historical `get_cost_report` queries (its own composables); does NOT use `useCostState` (which is for live meeting cost). |
| `15-apps-api-spec.md` | `agora_proxy.py` is unaffected; remains an ASGI passthrough of studio's SSE. |
| `16-apps-frontend-spec.md` | Frontend wiring: Pinia plugin registers `useMeetingStreamStore`; agora composables imported per-component. |
| `17-substitution-tests-spec.md` | Substitution tests cover all `[SUB]` test_ids in this spec (one row per reducer + the store). Tests run against PseudoStudioClient in v0.1 and against HttpStudioClient when v0.2 lands. |

---

## §11 Pre-merge checklist

- [ ] Mission + Scope present; "out of scope for v0.1" listed (cross-tab, IndexedDB, sliding-window log)
- [ ] Upstream contract anchor (§1) cites every `01-studio-client-spec.md` section depended on
- [ ] `useMeetingStreamStore` (§2) has full state shape, action signatures, behavior contract, and test matrix marked `[SUB]`
- [ ] All four reducers have: module location, composable signature, input event subset (named EventTypes), output state TS interface, state-machine pseudocode, idempotency rule, reconnect/replay rule, lifecycle, test matrix
- [ ] `useOutcomeReducer` (§3) defines conflict-resolution rules (consensus wins over late challenge; first ClaimMade wins on content)
- [ ] `useDagState` (§4) defines deterministic node/edge ID rules (§4.6) — required for idempotency
- [ ] `useCostState` (§5) specifies polling cadence + error tolerance + dual-track (live counter + authoritative)
- [ ] `useProvenance` (§6) specifies depth_cap, max_links, cycle protection, recompute triggers
- [ ] Cross-cutting (§7) covers subscription sharing, event log retention, backpressure, errors, finalization, failure, ordering, reset
- [ ] No business / domain / product / agent-role string literal anywhere (only neutral placeholders like `c1`, `a1`, `a2`)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No `dict[str, Any]` / `Record<string, any>` / `unknown` without inline justification
- [ ] Every non-obvious decision in §9 has Why-this + Considered-and-rejected
- [ ] Downstream impact (§10) lists every spec that consumes this contract
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/01b-product-derivations-spec.md`
