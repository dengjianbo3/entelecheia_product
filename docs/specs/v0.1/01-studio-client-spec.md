# 01 — `studio-client` v0.1 spec

> **Status**: v0.1 contract. Lives at `packages/studio-client/`.
> **Owner of this contract**: product. Owner of the studio-side implementation: studio repo.
> **Supersedes**: nothing (this is the first formal spec of the boundary).

---

## Mission

This file defines the `StudioClient` Protocol — the **only** path by which `entelecheia_product` reaches studio — together with all DTOs that cross that boundary, the sealed error taxonomy, the v0.1 `PseudoStudioClient` (fixture-backed) implementation, the v0.2+ `HttpStudioClient` placeholder, and the substitution-test contract that keeps the two implementations behaviorally interchangeable.

## Scope

**Covers.**
- `StudioClient` Protocol: 18 async methods that exhaust product↔studio communication for v0.1 features (agora, reports, knowledge, chathub, wizard, observability).
- All cross-boundary DTOs (`ProjectSummary`, `MeetingHandle`, `MeetingEvent` and its 9 variants, `WorkingOutcome`, `FinalOutcome`, `DagViewSnapshot`, `ProvenanceTrace`, `KnowledgeTreeSnapshot`, `KnowledgeTreeEvent`, `CostReport`, `MeetingMetrics`, `ReportArtifact`, `Material`, …).
- Identifier types (opaque to product).
- Sealed error taxonomy (one base + 14 leaf classes).
- `PseudoStudioClient` fixture directory layout, fixture file schemas, time-simulation rules, error-injection rules, in-memory state machine, invariants.
- `HttpStudioClient` v0.2+ placeholder: module location, translation-layer strategy (P7), sandwich-layer hooks.
- Substitution test matrix: which tests must pass under **both** implementations (`[SUB]` markers throughout).

**Does not cover.**
- Studio's internal mechanics: paradigm execution, agent runtime, skill bundles, memory backends, LLM client selection, prompt templates, evaluators, project-spec authoring tooling. These are studio's repo. This spec describes only what product **asks** studio for, never what studio **does** to answer.
- Product feature internals (agora component tree, knowledge browser, wizard flow, …). Those live in feature specs (`05`–`12`).
- Auth/JWT/session — `auth-service` spec (`03`).
- User preferences — `user-service` spec (`04`).
- TS mirror types for the frontend — `16-apps-frontend-spec.md` declares `apps/frontend/src/types/studio-client/` as the codegen target (Python is canonical here).

**Out of scope for v0.1.**
- `HttpStudioClient` implementation (only its location and translation-layer strategy are pinned here; full implementation in v0.2+ once studio's real API is published).
- Bidirectional WebSocket protocol details (subscribe is one-way async iterator at this level; transport is HttpStudioClient's concern).
- Caching / memoization layers (`SandwichLayer` topic, deferred to v0.3+).
- Cost ledger writes (read-only here; writes are studio's).
- Multi-tenancy / org scoping (single-tenant for v0.x).

---

## Glossary

| Term | Meaning in this spec |
|---|---|
| **studio** | The orchestration layer (`entelecheia_studio`) that hosts paradigms, agents, skills, and LLM clients. Out of this repo. |
| **engine** | The lower research engine (`entelecheia`). Product never imports it (Red Line #1). |
| **product** | This repo. The user-facing application + verticals. |
| **vertical** | A pluggable UI pack at `packages/verticals/<id>/`. Opaque to studio-client; only `vertical_id: str` crosses the boundary. |
| **meeting** | A bounded deliberation run (started by `run_meeting`, ends with one of `MeetingStopped`, `MeetingFailed`, `MeetingFinished`). |
| **project** | A studio-side `ProjectSpec`: an agent bundle + paradigm choice. Product references it by `project_id` only. |
| **clock** | A monotonic `int` per meeting. Each `MeetingEvent` carries `at_clock` for ordering, dedup, and reconnect cursors. Distinct from wall-clock timestamp. |
| **substitution test** | A test marked `[SUB]` that exercises Protocol behavior and **must pass** under both `PseudoStudioClient` and `HttpStudioClient`. |
| **fixture overlay** | A vertical-named YAML directory that overrides the `default/` fixture set when `PseudoStudioClient(fixture_set=...)` is instantiated. |

---

## Identifier types

All IDs are opaque to product. They are typed with `typing.NewType` so the type system rejects passing one ID where another is expected.

```python
# packages/studio-client/src/entelecheia_studio_client/ids.py

from typing import NewType

ProjectId   = NewType("ProjectId",   str)   # e.g. "proj_01HX..."  (studio-assigned)
AgentId     = NewType("AgentId",     str)   # e.g. "agt_01HX..."
MeetingId   = NewType("MeetingId",   str)   # e.g. "mtg_01HX..."
UserId      = NewType("UserId",      str)   # e.g. "usr_01HX..."  (auth-service-assigned, surfaces to studio for ownership)
MaterialId  = NewType("MaterialId",  str)   # e.g. "mat_01HX..."  (assigned by studio after upload registration)
ClaimId     = NewType("ClaimId",     str)   # e.g. "clm_01HX..."  (a claim made by an agent within a meeting)
TreeId      = NewType("TreeId",      str)   # e.g. "tre_01HX..."  (a knowledge tree)
ReportId    = NewType("ReportId",    str)   # e.g. "rep_01HX..."  (a rendered report artifact)
EventClock  = NewType("EventClock",  int)   # monotonic per meeting; starts at 0 inclusive
```

TS mirrors live in `apps/frontend/src/types/studio-client/ids.ts` as branded string types. Single source of truth: this file.

**Why NewType over raw `str`.** Type system catches `subscribe_meeting(project_id)` where `meeting_id` was meant — a class of bug we will hit otherwise. Cost is one cast at deserialization boundaries; cheap.
**Considered and rejected.** *Plain `str`* — type system can't help. *`pydantic.SecretStr`-style* wrapper class — adds runtime weight for no extra safety.

---

## Common DTOs

```python
# packages/studio-client/src/entelecheia_studio_client/dto/common.py

from datetime import datetime
from enum import Enum
from typing import Annotated, Literal
from pydantic import BaseModel, Field


class Material(BaseModel):
    """A piece of input the user attaches to a meeting (file, link, or note)."""
    material_id:   MaterialId
    kind:          Literal["file", "link", "note"]
    display_name:  str                       # user-facing; <= 200 chars
    mime_type:     str | None                # for kind="file"; None otherwise
    size_bytes:    int  | None               # for kind="file"; None otherwise
    url:           str  | None               # for kind="link"; None otherwise
    note_text:     str  | None               # for kind="note"; None otherwise
    uploaded_by:   UserId
    uploaded_at:   datetime                  # UTC

    # Invariant: exactly one of (mime_type+size_bytes), url, note_text is non-None,
    # consistent with `kind`. Validated by a model_validator.


class Permission(BaseModel):
    """A scoped capability granted to a user (mirrored from auth-service into studio's view)."""
    code:        str                          # e.g. "platform:list_projects", "vertical_x:open_meeting"
    granted_at:  datetime
```

---

## Project + Agent DTOs

```python
# packages/studio-client/src/entelecheia_studio_client/dto/projects.py

class ProjectSummary(BaseModel):
    """A studio-side ProjectSpec, as visible to product. Authoring lives in studio."""
    project_id:    ProjectId
    display_name:  str                        # user-facing; <= 80 chars; not localized at this layer
    description:   str                        # one-paragraph; not localized at this layer
    labels:        list[str]                  # vertical filter keys; lowercase snake; opaque to studio-client
    version:       int                        # monotonic; pinned by callers for cache validity
    created_at:    datetime
    updated_at:    datetime
    paradigm_kind: str                        # opaque tag (e.g. "deliberation", "single-expert"); used by UI to pick a launcher


class AgentSummary(BaseModel):
    """A studio-side AgentSpec exposed for selection / display in product UI."""
    agent_id:     AgentId
    display_name: str                         # user-facing; <= 60 chars
    role_tags:    list[str]                   # opaque tags; UI may render as chips
    bio:          str                         # short; <= 400 chars
    avatar_url:   str | None                  # optional small-image URL; product proxies if cross-origin


class ProjectVersion(BaseModel):
    """A pinned (project_id, version) pair returned when an old version is requested explicitly."""
    project_id:  ProjectId
    version:     int
    summary:     ProjectSummary               # the historical snapshot
    deprecated:  bool                         # true means studio recommends upgrading
    successor_version: int | None             # the version studio recommends switching to
```

**Why labels are opaque strings, not an enum.** Studio-client must not enumerate verticals (P10). Verticals add labels by manifest; studio sees them as data.

---

## Meeting DTOs

```python
# packages/studio-client/src/entelecheia_studio_client/dto/meetings.py

class MeetingStatus(str, Enum):
    PENDING   = "pending"     # accepted, not yet started
    RUNNING   = "running"
    PAUSED    = "paused"
    STOPPED   = "stopped"     # terminal, user-initiated
    FAILED    = "failed"      # terminal, internal
    FINISHED  = "finished"    # terminal, success


class MeetingRunConfig(BaseModel):
    """Per-meeting tuning knobs. Studio decides defaults; product overrides selectively."""
    max_rounds:        int  | None = None        # None means studio-default
    cost_ceiling_usd:  float| None = None        # None means studio-default
    locale:            str  | None = None        # e.g. "zh-CN", "en-US"; for studio-side localization of agent prompts
    extra:             dict[str, str] = {}       # opaque kv passthrough; studio may ignore unknown keys
    # WHY dict[str, str]: extension point that lets studio evolve its config surface
    # without breaking this Protocol; values are stringified at the boundary so JSON
    # serialization is trivial. Documented exception to the no-`dict[str, ...]` rule.


class MeetingHandle(BaseModel):
    """Returned by run_meeting. Bundles the immediate context callers need to subscribe."""
    meeting_id:    MeetingId
    project_id:    ProjectId
    started_at:    datetime
    status:        MeetingStatus              # at the moment of return; may already be RUNNING
    initial_clock: EventClock                 # 0 normally; non-zero only after a server-side replay


class MeetingSummary(BaseModel):
    """Snapshot for list views (knowledge browser, history, observability)."""
    meeting_id:        MeetingId
    project_id:        ProjectId
    display_topic:     str                    # user-typed topic; first 200 chars
    status:            MeetingStatus
    started_at:        datetime
    ended_at:          datetime | None
    last_event_clock:  EventClock
    cost_usd_so_far:   float
    n_agents:          int
    initiated_by:      UserId


class MeetingMetrics(BaseModel):
    """Performance / observability snapshot — cost + latency + counts."""
    meeting_id:           MeetingId
    wall_seconds:         float
    cost_usd:             float
    cost_breakdown:       list["CostSlice"]   # see Cost DTOs
    n_agent_turns:        int
    n_human_inputs:       int
    n_dag_nodes:          int
    n_dag_edges:          int
    last_event_clock:     EventClock
```

---

## Event stream (`MeetingEvent`)

The Protocol's `subscribe_meeting` yields `MeetingEvent`s — a discriminated union over `kind`. Every variant carries `meeting_id`, monotonic `at_clock`, and wall-clock `at_timestamp`. Consumers exhaust-check on `kind`.

```python
# packages/studio-client/src/entelecheia_studio_client/dto/events.py

class _MeetingEventBase(BaseModel):
    meeting_id:    MeetingId
    at_clock:      EventClock                 # monotonic; gap-free per meeting
    at_timestamp:  datetime                   # UTC wall clock; for "X seconds ago" UI
    sequence_uid:  str                        # opaque uuid; for client-side dedup across reconnects
    # WHY both at_clock AND at_timestamp: at_clock is for ordering/dedup/cursor;
    # at_timestamp is for human-readable rendering. Server clock can drift; client
    # cannot assume timestamp monotonicity.


class AgentSpoke(_MeetingEventBase):
    kind:           Literal["agent_spoke"] = "agent_spoke"
    agent_id:       AgentId
    content:        str                        # the agent's utterance; markdown-flavored plain text
    evidence_refs:  list[ClaimId]              # claim IDs this utterance cites
    round_index:    int                        # 0-based; ties events to a "round" for UI grouping


class OutcomeUpdated(_MeetingEventBase):
    kind:               Literal["outcome_updated"] = "outcome_updated"
    outcome_revision:   int                    # monotonic per meeting
    working_outcome:    "WorkingOutcome"       # FULL snapshot (not a delta) — see Why-block below


class DagMutated(_MeetingEventBase):
    kind:           Literal["dag_mutated"] = "dag_mutated"
    dag_revision:   int                         # monotonic per meeting
    mutations:      list["DagMutation"]         # ordered batch applied atomically


class CostAccrued(_MeetingEventBase):
    kind:                 Literal["cost_accrued"] = "cost_accrued"
    agent_id:             AgentId | None        # None if not attributable to an agent (e.g. evaluator)
    tokens_in:            int
    tokens_out:           int
    cost_usd_delta:       float                 # this slice
    cost_usd_cumulative:  float                 # since meeting start


class HumanInputAccepted(_MeetingEventBase):
    kind:           Literal["human_input_accepted"] = "human_input_accepted"
    author_user_id: UserId
    content:        str                         # plain text; surfaces in the discussion stream as a human turn


class MeetingPaused(_MeetingEventBase):
    kind:    Literal["meeting_paused"] = "meeting_paused"
    reason:  Literal["user", "studio_paused", "cost_ceiling"]


class MeetingResumed(_MeetingEventBase):
    kind: Literal["meeting_resumed"] = "meeting_resumed"


class MeetingStopped(_MeetingEventBase):
    kind:    Literal["meeting_stopped"] = "meeting_stopped"
    reason:  str                                # free-form; surfaced verbatim


class MeetingFinished(_MeetingEventBase):
    kind:                Literal["meeting_finished"] = "meeting_finished"
    final_outcome_ref:   MeetingId              # caller fetches via get_meeting_outcome(meeting_id)
    # WHY a ref, not the full outcome inline: keeps the event stream uniformly
    # small; final outcomes can be larger than ordinary events. The fetch is
    # a single round-trip and idempotent.


MeetingEvent = (
    AgentSpoke
    | OutcomeUpdated
    | DagMutated
    | CostAccrued
    | HumanInputAccepted
    | MeetingPaused
    | MeetingResumed
    | MeetingStopped
    | MeetingFinished
)
```

**Why discriminated union with `kind` literal.** Native to pydantic + TS; consumers can `match event.kind:` exhaustively; serialization-friendly across the JSON boundary.
**Considered and rejected.** *Class hierarchy without explicit discriminator* — JSON serialization needs a tag anyway, may as well make it explicit.
*Single `MeetingEvent` with optional fields per variant* — collapses the type system into runtime checks; rejected.

**Why `OutcomeUpdated` ships a full snapshot, not a delta.** Outcomes are bounded in size (a working consensus over claims; ~few KB). Deltas would force every consumer to maintain a state machine identical to studio's, which contradicts P6 (substitution: Pseudo and Http must be observably identical) by widening the surface where they could disagree. Bandwidth cost of full snapshots is negligible at v0.1 sizes.
**Considered and rejected.** *Delta-only* — see above.
*Snapshots with periodic full-frame keyframes* — premature optimization for a problem we don't have.

**Why `MeetingFinished` carries a ref, not the full `FinalOutcome`.** Keeps event payload sizes uniform; allows the final-outcome representation to grow over versions without bloating every event.

---

## Outcome DTOs

```python
# packages/studio-client/src/entelecheia_studio_client/dto/outcomes.py

class OutcomeClaim(BaseModel):
    """One assertion in a working/final outcome."""
    claim_id:        ClaimId
    text:            str                       # the assertion; markdown plain text
    asserted_by:     list[AgentId]             # 1+ agents that endorse this claim (intersection of consensus)
    contested_by:    list[AgentId]             # agents that explicitly opposed it; empty if uncontested
    evidence_refs:   list[ClaimId | MaterialId]# upstream claims and/or attached materials supporting this claim
    confidence:      float                     # 0.0 .. 1.0; studio-defined scale (opaque to product)


class WorkingOutcome(BaseModel):
    """A non-final, in-progress consensus snapshot. Carried inside OutcomeUpdated events."""
    meeting_id:        MeetingId
    outcome_revision:  int                     # matches OutcomeUpdated.outcome_revision
    claims:            list[OutcomeClaim]
    summary_text:      str                     # one-paragraph human-readable digest
    open_questions:    list[str]               # things the meeting is still working on


class FinalOutcome(BaseModel):
    """The terminal outcome. Returned by get_meeting_outcome only when status is FINISHED."""
    meeting_id:        MeetingId
    finalized_at:      datetime
    claims:            list[OutcomeClaim]
    summary_text:      str
    decision:          str                     # one-paragraph recommended decision; may be empty for purely-exploratory paradigms
    confidence:        float                   # overall confidence in the decision; 0.0 .. 1.0
```

**Why `WorkingOutcome` and `FinalOutcome` are distinct types, not one with a `status` field.** Type system prevents storing a `WorkingOutcome` where a `FinalOutcome` is required (e.g. report rendering, knowledge tree append). A runtime `if status == "final"` check is weaker discipline that bugs slip past.
**Considered and rejected.** *Single `MeetingOutcome` with `status` field* — see above; the spec literally lists them as separate DTOs because separation matters.

---

## DAG DTOs

```python
# packages/studio-client/src/entelecheia_studio_client/dto/dag.py

class DagNode(BaseModel):
    node_id:    str                            # opaque; stable across mutations
    kind:       Literal["agent", "claim", "material", "round_anchor"]
    label:      str                            # display label; <= 80 chars
    payload:    dict[str, str] = {}            # opaque kv for UI rendering hints (e.g. color group)


class DagEdge(BaseModel):
    edge_id:    str                            # opaque; stable across mutations
    source:     str                            # node_id
    target:     str                            # node_id
    kind:       Literal["supports", "rebuts", "references", "speaks_in"]
    weight:     float                          # 0.0 .. 1.0; UI strength hint


class DagViewSnapshot(BaseModel):
    """A point-in-time view of the deliberation DAG. Returned by get_dag_view."""
    meeting_id:    MeetingId
    at_clock:      EventClock                  # the clock this snapshot is consistent with
    dag_revision:  int
    nodes:         list[DagNode]
    edges:         list[DagEdge]


# Mutations — sealed union, used inside DagMutated.mutations[]

class _DagMutationBase(BaseModel):
    pass

class AddNode(_DagMutationBase):
    op: Literal["add_node"] = "add_node"
    node: DagNode

class RemoveNode(_DagMutationBase):
    op: Literal["remove_node"] = "remove_node"
    node_id: str

class UpdateNode(_DagMutationBase):
    op: Literal["update_node"] = "update_node"
    node_id: str
    label:   str | None = None                 # if non-None, replace
    payload_patch: dict[str, str] = {}         # shallow merge

class AddEdge(_DagMutationBase):
    op: Literal["add_edge"] = "add_edge"
    edge: DagEdge

class RemoveEdge(_DagMutationBase):
    op: Literal["remove_edge"] = "remove_edge"
    edge_id: str

DagMutation = AddNode | RemoveNode | UpdateNode | AddEdge | RemoveEdge
```

**Why mutations + occasional `get_dag_view` snapshot, not snapshots-only.** Bandwidth: a full snapshot per event is O(N); mutations are O(1) per change. Late-joiners and post-disconnect re-syncs use `get_dag_view(meeting_id, at_clock)` to get a one-shot consistent view, then resume the mutation stream from `at_clock + 1`.
**Considered and rejected.** *Snapshots-only* — see above.
*Server-pushed snapshots interleaved with mutations* — adds protocol complexity for a problem (re-sync) that the explicit `get_dag_view` solves more cleanly.

---

## Provenance DTOs

```python
# packages/studio-client/src/entelecheia_studio_client/dto/provenance.py

class EvidenceSource(BaseModel):
    kind:        Literal["material", "claim", "external_url"]
    material_id: MaterialId | None
    claim_id:    ClaimId    | None
    url:         str        | None             # only when kind=="external_url"
    excerpt:     str | None                    # short quoted snippet, if studio surfaced one


class EvidenceLink(BaseModel):
    """One step in the chain of evidence for a claim."""
    from_claim_id:  ClaimId
    to_source:      EvidenceSource
    relation:       Literal["supports", "rebuts", "qualifies"]
    weight:         float                      # 0.0 .. 1.0


class ProvenanceTrace(BaseModel):
    """The full evidence chain rooted at a claim, returned by get_provenance(meeting_id, claim_id)."""
    meeting_id:    MeetingId
    root_claim_id: ClaimId
    links:         list[EvidenceLink]          # depth-first traversal, ordered
    truncated:     bool                        # true if studio capped the trace; UI shows "Show more"
```

---

## Knowledge tree DTOs

```python
# packages/studio-client/src/entelecheia_studio_client/dto/knowledge.py

class KnowledgeTreeNode(BaseModel):
    node_id:     str
    parent_id:   str | None                    # None for root
    label:       str                           # <= 200 chars
    kind:        Literal["topic", "claim", "decision", "evidence"]
    payload:     dict[str, str] = {}
    children:    list[str] = []                # node_ids; ordered


class KnowledgeTreeSnapshot(BaseModel):
    tree_id:     TreeId
    revision:    int                           # monotonic
    root_id:     str
    nodes:       list[KnowledgeTreeNode]       # all nodes; UI traverses by parent_id/children
    last_updated_at: datetime


# Events for subscribe_knowledge_tree_events — sealed union

class _KTEventBase(BaseModel):
    tree_id:     TreeId
    revision:    int                           # monotonic per tree
    at_timestamp: datetime
    sequence_uid: str

class KTNodeAdded(_KTEventBase):
    kind: Literal["node_added"] = "node_added"
    node: KnowledgeTreeNode

class KTNodeUpdated(_KTEventBase):
    kind: Literal["node_updated"] = "node_updated"
    node_id: str
    label: str | None = None
    payload_patch: dict[str, str] = {}

class KTNodeRemoved(_KTEventBase):
    kind: Literal["node_removed"] = "node_removed"
    node_id: str

class KTReindexed(_KTEventBase):
    kind: Literal["reindexed"] = "reindexed"
    snapshot: KnowledgeTreeSnapshot            # studio rebuilt the tree; consumers should replace state

KnowledgeTreeEvent = KTNodeAdded | KTNodeUpdated | KTNodeRemoved | KTReindexed
```

**Why `subscribe_knowledge_tree_events` is separate from `subscribe_meeting`.** Knowledge trees are persistent across sessions; meetings are bounded streams. Mixing them in one stream creates a god-channel where consumers must filter, and lifecycle bugs become hard to reason about (closing a meeting subscription would close knowledge subscriptions for the same user — wrong).
**Considered and rejected.** *One `subscribe(...)` method with a `topic_filter` arg* — increases the test matrix combinatorially; obscures lifecycles.

---

## Cost / Report DTOs

```python
# packages/studio-client/src/entelecheia_studio_client/dto/cost.py

class CostSlice(BaseModel):
    label:        str                          # e.g. "agent_turn", "evaluator", "tooling"
    cost_usd:     float
    tokens_in:    int
    tokens_out:   int


class CostReport(BaseModel):
    """Aggregated cost view returned by get_cost_aggregate. Read-only."""
    scope_kind:           Literal["project", "user", "vertical", "meeting", "global"]
    scope_id:             str | None           # None when scope_kind=="global"
    from_date:            datetime
    to_date:              datetime
    total_cost_usd:       float
    breakdown:            list[CostSlice]
    n_meetings:           int
    n_agent_turns:        int


# packages/studio-client/src/entelecheia_studio_client/dto/reports.py

class ReportFormat(str, Enum):
    PDF      = "pdf"
    WORD     = "word"
    EXCEL    = "excel"
    MARKDOWN = "markdown"


class ReportArtifact(BaseModel):
    """A rendered report. Bytes are inline; HttpStudioClient is responsible for fetching from
    studio's URL and packing here so feature code never sees a download URL."""
    report_id:    ReportId
    meeting_id:   MeetingId
    format:       ReportFormat
    bytes_:       bytes                        # the artifact; pydantic serializes via base64 at boundaries
    rendered_at:  datetime
    sha256:       str                          # hex digest for integrity / cache key
    page_count:   int | None                   # for paged formats; None for markdown / excel
```

**Why `ReportArtifact.bytes_` is inline, not a download URL.** Hides the transport from feature code (P7). For pseudo, the bytes come from a fixture file. For Http, the SDK fetches the URL studio returns and packs the bytes in. Either way, callers get the same shape.
**Considered and rejected.** *URL field that the caller fetches* — leaks transport into feature code; complicates auth handoff (caller would need studio's token).

---

## Error model — sealed taxonomy

All exceptions inherit from `StudioClientError`. Each method declares its full union of raisable leaf types. No bare `Exception`. No `OtherError`. Leaf classes are **closed**: adding one is a Protocol bump.

```python
# packages/studio-client/src/entelecheia_studio_client/errors.py

class StudioClientError(Exception):
    """Abstract base. Catch this at the product API boundary for fall-through logging."""

    def __init__(self, *, message: str, retryable: bool, surfaces_verbatim: bool, http_status: int):
        super().__init__(message)
        self.message = message
        self.retryable = retryable
        self.surfaces_verbatim = surfaces_verbatim
        self.http_status = http_status


# --- transport / connectivity ---

class StudioUnavailable(StudioClientError):
    """Studio is unreachable or returned 5xx. Retryable. UI: 'Service temporarily unavailable.'"""
    http_status = 502

class StudioProtocolMismatch(StudioClientError):
    """The studio version this client connected to is incompatible (semver gate). NOT retryable. UI: 'Please update.'"""
    http_status = 502


# --- auth ---

class AuthRequired(StudioClientError):
    """No or expired token. UI: redirect to login."""
    http_status = 401

class PermissionDenied(StudioClientError):
    """Token is valid but lacks the required permission for this call. UI: 'You don't have access.'"""
    http_status = 403


# --- not found ---

class ProjectNotFound(StudioClientError):
    """project_id does not exist or is not visible to this user."""
    http_status = 404

class AgentNotFound(StudioClientError):
    """agent_id does not exist or is not visible."""
    http_status = 404

class MeetingNotFound(StudioClientError):
    """meeting_id does not exist or is not visible."""
    http_status = 404


# --- state / readiness ---

class MeetingNotReady(StudioClientError):
    """Operation requires meeting in a specific state (e.g. get_meeting_outcome on a RUNNING meeting)."""
    http_status = 409

class ConflictingState(StudioClientError):
    """e.g. resume on a STOPPED meeting; pause on a FINISHED meeting."""
    http_status = 409


# --- terminal ---

class MeetingFailed(StudioClientError):
    """Meeting died on studio side. Non-retryable; carries `reason: str`."""
    http_status = 500

class ReportRenderFailed(StudioClientError):
    """Report rendering died. Non-retryable; carries `reason: str`."""
    http_status = 500


# --- input / quotas ---

class InvalidArgument(StudioClientError):
    """Caller-side input validation failure. NOT retryable without changing input."""
    http_status = 400

class QuotaExceeded(StudioClientError):
    """Cost ceiling, rate limit, or org quota hit. UI: 'Quota reached.'"""
    http_status = 429


# --- streaming ---

class StreamReconnectFailed(StudioClientError):
    """subscribe_meeting / subscribe_knowledge_tree_events could not catch up from cursor.
    Caller should re-fetch a snapshot and resume."""
    http_status = 410
```

**Why leaf classes (sealed taxonomy) instead of `Exception` with codes.** mypy + IDE can exhaust-check `try / except` on a per-method declared union; runtime `isinstance` narrows variants. Substitution rule (P6): each leaf must be representable in fixtures.
**Considered and rejected.** *Single `StudioClientError` with `code: str`* — string-typed errors don't exhaust-check; one missed branch is a silent bug.
*Union-only (`raises: StudioUnavailable | AuthRequired`)* — Python doesn't have native union-typed `raises`; mypy's enforcement is via inline annotations only. Class hierarchy + per-method union annotation gives both worlds.

---

## `StudioClient` Protocol — all 18 methods

Module: `packages/studio-client/src/entelecheia_studio_client/protocol.py`.
All methods are `async`. All raise from the sealed taxonomy above. Test matrices below mark substitution-eligible tests with `[SUB]` (must pass under both Pseudo and Http per `17-substitution-tests-spec.md`).

```python
class StudioClient(Protocol):
    """The single boundary between product and studio. Product code depends on this Protocol; never on a concrete implementation."""
```

### 1. `list_available_projects`

```python
async def list_available_projects(
    self,
    *,
    user_id:        UserId,
    vertical_id:    str | None = None,         # e.g. "<v>"; opaque
    labels_any_of:  list[str] | None = None,   # OR semantics (see Why)
    cursor:         str | None = None,         # opaque next-page cursor
    limit:          int = 50,                  # 1 .. 200
) -> tuple[list[ProjectSummary], str | None]:  # (items, next_cursor)
    ...
```

**Semantics.** Returns projects this user is permitted to see, optionally filtered by vertical scoping and label union. Paged via opaque cursor.
**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy path, no filter | `user_id=u`, no filters | non-empty list, possibly with cursor | `[SUB] t_lap_happy` |
| filter by vertical | `vertical_id="<v>"` | only projects whose labels include the vertical hint | `[SUB] t_lap_filter_vertical` |
| `labels_any_of` OR semantics | `labels_any_of=["a","b"]` | projects matching either label | `[SUB] t_lap_labels_or` |
| empty result | `vertical_id="<unknown>"` | `([], None)` | `[SUB] t_lap_empty` |
| pagination | `limit=2` then follow `cursor` | items partitioned, no overlap, no missing | `[SUB] t_lap_paging` |
| studio down | fixture `studio_down` | raises `StudioUnavailable` | `[SUB] t_lap_studio_down` |
| no permission | user lacks `platform:list_projects` | raises `PermissionDenied` | `[SUB] t_lap_perm` |
| invalid limit | `limit=999` | raises `InvalidArgument` | `[SUB] t_lap_invalid_limit` |

### 2. `get_project`

```python
async def get_project(
    self,
    *,
    project_id: ProjectId,
    version:    int | None = None,             # None = latest
) -> ProjectSummary | ProjectVersion:          # ProjectVersion when version is pinned
    ...
```

**Semantics.** Single-project lookup. When `version` is provided, returns a `ProjectVersion` carrying the historical snapshot + `deprecated` / `successor_version`.
**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | ProjectNotFound | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy, latest | `project_id=p` | `ProjectSummary` for latest version | `[SUB] t_gp_latest` |
| happy, pinned | `project_id=p, version=1` | `ProjectVersion` with summary + flags | `[SUB] t_gp_pinned` |
| pinned deprecated | version flagged in fixture | `deprecated=True`, `successor_version` set | `[SUB] t_gp_deprecated` |
| not found | `project_id="missing"` | raises `ProjectNotFound` | `[SUB] t_gp_not_found` |
| negative version | `version=-1` | raises `InvalidArgument` | `[SUB] t_gp_invalid_version` |

### 3. `list_available_agents`

```python
async def list_available_agents(
    self,
    *,
    user_id:           UserId,
    role_tags_any_of:  list[str] | None = None,
    cursor:            str | None = None,
    limit:             int = 50,
) -> tuple[list[AgentSummary], str | None]:
    ...
```

**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy | `user_id=u` | non-empty list | `[SUB] t_laa_happy` |
| filter by role tag | `role_tags_any_of=["t1"]` | only matching agents | `[SUB] t_laa_filter_role` |
| empty | `role_tags_any_of=["nope"]` | `([], None)` | `[SUB] t_laa_empty` |
| permission denied | user lacks `platform:list_agents` | raises `PermissionDenied` | `[SUB] t_laa_perm` |

### 4. `run_meeting`

```python
async def run_meeting(
    self,
    *,
    project_id: ProjectId,
    topic:      str,                            # 1..2000 chars
    materials:  list[Material],
    user_id:    UserId,
    config:     MeetingRunConfig | None = None,
) -> MeetingHandle:
    ...
```

**Semantics.** Asks studio to start a meeting. Returns the handle as soon as studio has accepted (status PENDING or RUNNING). Subscribe via `subscribe_meeting(meeting_id)`.
**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | ProjectNotFound | InvalidArgument | QuotaExceeded`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy | valid project, topic, materials | `MeetingHandle{ status in (PENDING, RUNNING) }` | `[SUB] t_rm_happy` |
| empty topic | `topic=""` | raises `InvalidArgument` | `[SUB] t_rm_empty_topic` |
| topic too long | `len(topic)=2001` | raises `InvalidArgument` | `[SUB] t_rm_long_topic` |
| project not found | `project_id="x"` | raises `ProjectNotFound` | `[SUB] t_rm_not_found` |
| over quota | fixture `quota_exhausted` | raises `QuotaExceeded` | `[SUB] t_rm_quota` |

### 5. `get_meeting_outcome`

```python
async def get_meeting_outcome(self, *, meeting_id: MeetingId) -> FinalOutcome:
    ...
```

**Semantics.** Returns the **final** outcome only when meeting status is FINISHED. For in-progress consensus, consume `OutcomeUpdated` events from `subscribe_meeting` (those carry `WorkingOutcome`).
**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | MeetingNotFound | MeetingNotReady | MeetingFailed`.

| scenario | input | expected | test_id |
|---|---|---|---|
| finished meeting | `meeting_id=m_finished` | `FinalOutcome` | `[SUB] t_gmo_finished` |
| running meeting | `meeting_id=m_running` | raises `MeetingNotReady` | `[SUB] t_gmo_running` |
| failed meeting | `meeting_id=m_failed` | raises `MeetingFailed` | `[SUB] t_gmo_failed` |
| not found | `meeting_id="missing"` | raises `MeetingNotFound` | `[SUB] t_gmo_not_found` |

### 6. `list_meetings`

```python
async def list_meetings(
    self,
    *,
    user_id:    UserId  | None = None,
    project_id: ProjectId | None = None,
    status:     MeetingStatus | None = None,
    cursor:     str | None = None,
    limit:      int = 50,
) -> tuple[list[MeetingSummary], str | None]:
    ...
```

**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| by user | `user_id=u` | meetings for u | `[SUB] t_lm_by_user` |
| by project | `project_id=p` | meetings for p | `[SUB] t_lm_by_project` |
| by status | `status=FINISHED` | only finished | `[SUB] t_lm_by_status` |
| paging | `limit=2` then cursor | partitioned, no dups | `[SUB] t_lm_paging` |
| invalid limit | `limit=0` | raises `InvalidArgument` | `[SUB] t_lm_invalid_limit` |

### 7. `pause_meeting`, 8. `resume_meeting`, 9. `stop_meeting`

```python
async def pause_meeting(self,  *, meeting_id: MeetingId) -> None: ...
async def resume_meeting(self, *, meeting_id: MeetingId) -> None: ...
async def stop_meeting(self,   *, meeting_id: MeetingId, reason: str) -> None: ...
```

**Semantics.** Best-effort state changes. Effect surfaces as a `MeetingPaused` / `MeetingResumed` / `MeetingStopped` event in the subscribe stream; the call returns when studio has accepted the request.
**Raises (each).** `StudioUnavailable | AuthRequired | PermissionDenied | MeetingNotFound | ConflictingState`.

| scenario | input | expected | test_id |
|---|---|---|---|
| pause running | running meeting | returns; emits `MeetingPaused` | `[SUB] t_pm_pause_running` |
| pause already-paused | paused meeting | raises `ConflictingState` | `[SUB] t_pm_pause_paused` |
| resume paused | paused meeting | returns; emits `MeetingResumed` | `[SUB] t_pm_resume_paused` |
| resume running | running meeting | raises `ConflictingState` | `[SUB] t_pm_resume_running` |
| stop running | running meeting, reason | returns; emits `MeetingStopped(reason)` | `[SUB] t_pm_stop_running` |
| stop finished | finished meeting | raises `ConflictingState` | `[SUB] t_pm_stop_finished` |

### 10. `inject_human_input`

```python
async def inject_human_input(
    self,
    *,
    meeting_id:     MeetingId,
    content:        str,                       # 1..4000 chars
    author_user_id: UserId,
) -> None:
    ...
```

**Semantics.** Adds a human turn. Effect surfaces as `HumanInputAccepted` event (then potentially follow-on `AgentSpoke` events as agents react).
**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | MeetingNotFound | ConflictingState | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy, running | running meeting, valid content | returns; emits `HumanInputAccepted` then ≥1 `AgentSpoke` | `[SUB] t_ihi_happy` |
| empty content | `content=""` | raises `InvalidArgument` | `[SUB] t_ihi_empty` |
| stopped meeting | stopped meeting | raises `ConflictingState` | `[SUB] t_ihi_stopped` |

### 11. `subscribe_meeting`

```python
async def subscribe_meeting(
    self,
    *,
    meeting_id: MeetingId,
    from_clock: EventClock | None = None,      # None = from latest; 0 = from start
) -> AsyncIterator[MeetingEvent]:
    ...
```

**Semantics.** Streams events as they happen. Resumes from `from_clock` when reconnecting. Each event has unique `(meeting_id, at_clock)` and `sequence_uid`. Caller dedupes on either.
**Termination.** Iterator ends after one of `MeetingStopped` / `MeetingFinished`.
**Ordering guarantee.** Strict per-meeting monotonic in `at_clock`; no gaps.
**Idempotency on reconnect.** Same `(meeting_id, at_clock)` → same event payload.
**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | MeetingNotFound | StreamReconnectFailed`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy, from start | `from_clock=0` | yields events starting at clock=0 in order | `[SUB] t_sm_from_start` |
| from cursor | `from_clock=N` | yields events starting at N, no gaps | `[SUB] t_sm_from_cursor` |
| reconnect dedup | drop & resubscribe at last seen | resumed events match originals (same `sequence_uid`) | `[SUB] t_sm_reconnect_dedup` |
| terminates on finish | run to completion | iterator yields `MeetingFinished` then ends | `[SUB] t_sm_finishes` |
| reconnect too late | cursor far in past, retention exceeded | raises `StreamReconnectFailed` | `[SUB] t_sm_reconnect_lost` |
| not found | `meeting_id="missing"` | raises `MeetingNotFound` | `[SUB] t_sm_not_found` |

### 12. `get_dag_view`

```python
async def get_dag_view(
    self,
    *,
    meeting_id: MeetingId,
    at_clock:   EventClock | None = None,      # None = latest
) -> DagViewSnapshot:
    ...
```

**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | MeetingNotFound | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| latest | `at_clock=None` | snapshot at last event | `[SUB] t_gdv_latest` |
| historical | `at_clock=N` | snapshot consistent with clock N | `[SUB] t_gdv_historical` |
| future clock | `at_clock=` huge | raises `InvalidArgument` | `[SUB] t_gdv_future` |
| not found | `meeting_id="missing"` | raises `MeetingNotFound` | `[SUB] t_gdv_not_found` |

### 13. `get_provenance`

```python
async def get_provenance(
    self,
    *,
    meeting_id: MeetingId,
    claim_id:   ClaimId,
) -> ProvenanceTrace:
    ...
```

**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | MeetingNotFound | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy | known claim | non-empty `links` | `[SUB] t_gpv_happy` |
| truncated | claim with deep chain | `truncated=True` | `[SUB] t_gpv_truncated` |
| invalid claim | `claim_id="x"` | raises `InvalidArgument` | `[SUB] t_gpv_invalid` |

### 14. `get_knowledge_tree`

```python
async def get_knowledge_tree(self, *, tree_id: TreeId) -> KnowledgeTreeSnapshot:
    ...
```

**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy | known tree | snapshot | `[SUB] t_gkt_happy` |
| invalid tree | `tree_id="x"` | raises `InvalidArgument` | `[SUB] t_gkt_invalid` |

### 15. `subscribe_knowledge_tree_events`

```python
async def subscribe_knowledge_tree_events(
    self,
    *,
    tree_id:     TreeId,
    from_revision: int | None = None,          # None = from latest
) -> AsyncIterator[KnowledgeTreeEvent]:
    ...
```

**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | InvalidArgument | StreamReconnectFailed`.

| scenario | input | expected | test_id |
|---|---|---|---|
| live | from latest | yields new events as they arrive | `[SUB] t_skt_live` |
| from past revision | `from_revision=R` | yields events starting at R | `[SUB] t_skt_from_rev` |
| reindex emitted | studio rebuild | yields a `KTReindexed` carrying full snapshot | `[SUB] t_skt_reindex` |
| past too far | `from_revision=` very old | raises `StreamReconnectFailed` | `[SUB] t_skt_lost` |

### 16. `get_cost_aggregate`

```python
async def get_cost_aggregate(
    self,
    *,
    project_id:  ProjectId | None = None,
    user_id:     UserId    | None = None,
    vertical_id: str       | None = None,
    meeting_id:  MeetingId | None = None,
    from_date:   datetime  | None = None,
    to_date:     datetime  | None = None,
) -> CostReport:
    ...
```

**Semantics.** Read-only cost aggregation. Exactly one of the four scope filters (project / user / vertical / meeting) must be set, OR all four are None (global). Studio resolves date defaults if dates are None.
**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| by project | `project_id=p` | `CostReport(scope_kind="project")` | `[SUB] t_gca_project` |
| by user | `user_id=u` | `CostReport(scope_kind="user")` | `[SUB] t_gca_user` |
| by vertical | `vertical_id="<v>"` | `CostReport(scope_kind="vertical")` | `[SUB] t_gca_vertical` |
| by meeting | `meeting_id=m` | `CostReport(scope_kind="meeting")` | `[SUB] t_gca_meeting` |
| global | no filters | `CostReport(scope_kind="global", scope_id=None)` | `[SUB] t_gca_global` |
| two scopes | project_id AND user_id | raises `InvalidArgument` | `[SUB] t_gca_two_scopes` |

### 17. `get_meeting_metrics`

```python
async def get_meeting_metrics(self, *, meeting_id: MeetingId) -> MeetingMetrics: ...
```

**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | MeetingNotFound`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy, finished | finished meeting | `MeetingMetrics` populated | `[SUB] t_gmm_finished` |
| happy, running | running meeting | `MeetingMetrics`; values reflect partial state | `[SUB] t_gmm_running` |
| not found | missing | raises `MeetingNotFound` | `[SUB] t_gmm_not_found` |

### 18. `render_outcome_report`

```python
async def render_outcome_report(
    self,
    *,
    meeting_id:  MeetingId,
    format:      ReportFormat,
    template_id: str | None = None,             # None = studio default for that format
) -> ReportArtifact:
    ...
```

**Semantics.** Returns the rendered bytes inline (transport hidden by P7).
**Raises.** `StudioUnavailable | AuthRequired | PermissionDenied | MeetingNotFound | MeetingNotReady | ReportRenderFailed | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| pdf default template | finished meeting | `ReportArtifact(format=PDF, page_count>=1)` | `[SUB] t_ror_pdf` |
| markdown | finished | `ReportArtifact(format=MARKDOWN, page_count=None)` | `[SUB] t_ror_md` |
| running meeting | running | raises `MeetingNotReady` | `[SUB] t_ror_running` |
| bad template | `template_id="missing"` | raises `InvalidArgument` | `[SUB] t_ror_bad_tpl` |
| renderer dies | fixture `render_fail` | raises `ReportRenderFailed` | `[SUB] t_ror_fail` |

---

## `PseudoStudioClient` v0.1

Module: `packages/studio-client/src/entelecheia_studio_client/pseudo/__init__.py`.

### Constructor

```python
class PseudoStudioClient(StudioClient):
    def __init__(
        self,
        *,
        fixture_set:        str = "default",       # selects an overlay directory
        time_acceleration:  float = 1.0,           # 1.0 = realistic; 100.0 = tests
        random_seed:        int | None = None,     # for deterministic event spacing jitter
        clock:              "Clock | None" = None, # injection point for tests; default = wall clock
    ) -> None: ...
```

### Fixture directory layout

```
packages/studio-client/fixtures/
├── default/                                # required
│   ├── projects.yaml
│   ├── agents.yaml
│   ├── permissions.yaml                    # user → permission codes
│   ├── meeting_templates.yaml              # see below
│   ├── outcomes.yaml                       # final outcomes per template
│   ├── dag_seeds.yaml                      # initial DAG nodes per template
│   ├── provenance.yaml                     # provenance traces per claim
│   ├── trees.yaml                          # knowledge trees + their event scripts
│   ├── cost_aggregates.yaml                # canned cost reports per scope
│   └── reports/                            # rendered artifacts per (template_id, format)
│       ├── default-pdf.pdf
│       ├── default-md.md
│       └── ...
└── <vertical_id>/                          # optional overlay; only files present override default/
    ├── projects.yaml
    └── ...
```

### Fixture file schemas

```yaml
# projects.yaml
- project_id:    "proj_alpha"
  display_name:  "Alpha Deliberation"
  description:   "A general-purpose multi-agent deliberation."
  labels:        ["a", "b"]
  version:       1
  paradigm_kind: "deliberation"
  created_at:    "2026-01-01T00:00:00Z"
  updated_at:    "2026-04-15T00:00:00Z"

# meeting_templates.yaml
- template_id:   "tmpl_default"
  match_rule:                                # used by run_meeting to pick a template
    project_id_in: ["proj_alpha"]
    topic_keywords_any_of: ["*"]             # matches any topic
  initial_status: "running"
  events:                                    # the event script
    - at_offset_ms: 0
      kind: agent_spoke
      payload:
        agent_id: "agt_archi"
        content:  "I propose we examine the question in three parts..."
        evidence_refs: []
        round_index: 0
    - at_offset_ms: 1500
      kind: dag_mutated
      payload:
        mutations:
          - {op: "add_node", node: {node_id: "n1", kind: "claim", label: "Part 1: scope"}}
    - at_offset_ms: 3000
      kind: outcome_updated
      payload:
        outcome_revision: 1
        working_outcome:
          summary_text: "Working consensus: scope is bounded to ..."
          claims: [...]
          open_questions: ["What about edge case X?"]
    # ...
    - at_offset_ms: 60000
      kind: meeting_finished
      payload:
        final_outcome_id: "tmpl_default"     # references outcomes.yaml entry

# error injection on a meeting
- template_id:   "tmpl_failing"
  match_rule:    {topic_keywords_any_of: ["fail"]}
  initial_status: "running"
  inject_error:
    at_offset_ms: 5000
    error_class: "MeetingFailed"
    message:     "Synthetic failure"
    extra:       {reason: "fixture_injected"}
```

### Time-simulation rules

- The simulator schedules events by `at_offset_ms` from meeting start, divided by `time_acceleration`.
- Maximum sleep between consecutive yields is **200 ms** (after acceleration). If a fixture has a 60 s gap and `time_acceleration=1.0`, the simulator chunks the wait into 200 ms heartbeat ticks so a `pause_meeting` call can interrupt promptly.
- Wall-clock `at_timestamp` on each event is `meeting_started_at + at_offset_ms`, **not** `now()`. This keeps fixtures deterministic across runs.
- Jitter (±10% of inter-event gap) is applied iff `random_seed is not None`, deterministic per seed.

### Error injection rules

- Per-call: a fixture entry under `permissions.yaml` or `projects.yaml` produces synchronous errors (`PermissionDenied`, `ProjectNotFound`).
- Per-stream: `meeting_templates.yaml` entries with `inject_error:` raise the named error at `at_offset_ms` instead of yielding subsequent events. The error class string MUST match a leaf in the sealed taxonomy; mismatch = startup-time validation failure (P6: pseudo is faithful, not free-form).
- Global: when `fixture_set` resolves a special overlay named `studio_down`, **every** Protocol method raises `StudioUnavailable` immediately. Used to simulate the transport-down case without per-call wiring.
- Global: `quota_exhausted` overlay — `run_meeting` raises `QuotaExceeded`; everything else passes.

### State machine (in-memory)

```python
@dataclass
class _MeetingState:
    handle:           MeetingHandle
    template_id:      str
    next_clock:       EventClock
    status:           MeetingStatus
    events_emitted:   list[MeetingEvent]            # for replay on reconnect
    final_outcome:    FinalOutcome | None
    cost_so_far:      float
    n_human_inputs:   int
```

The simulator holds a `dict[MeetingId, _MeetingState]`. On `pause_meeting`, the scheduler stops yielding non-control events; on `resume_meeting`, it resumes from the next pending offset.

### Invariants (enforced by tests; see substitution matrix)

- `subscribe_meeting` after meeting finished returns the recorded events from `from_clock` through `MeetingFinished`, then ends.
- Reconnect with cursor never re-yields events with `at_clock <= cursor`.
- Two `subscribe_meeting` consumers see identical event sequences (per-meeting monotonic).
- Calling `inject_human_input` during PAUSED yields a `HumanInputAccepted` event only after `resume_meeting`.
- Calling `stop_meeting` always terminates the iterator with `MeetingStopped`, never `MeetingFinished`.
- `time_acceleration=0` is forbidden (`InvalidArgument` at construction; pseudo would never advance).

**Why YAML for fixtures.** Comments + multiline strings + anchors; humans hand-author and read them; PR diffs are reviewable.
**Considered and rejected.** *JSON* — no comments, hostile to authors. *Python modules* — would let dynamic mocks creep in (P6 violation: fixtures must be data, not code).

**Why bounded sleep with 200 ms heartbeat.** Lets `pause_meeting` / `stop_meeting` interrupt promptly without busy-looping. Bounded so tests with `time_acceleration=100` don't get bursty.
**Considered and rejected.** *Zero delay* — loses stream-feel; consumers race. *Real-time only* — too slow for fixture-based tests.

**Why declarative error injection (in fixture), not API-side `set_next_error`.** Fixture-based is replayable + version-controlled + visible in PR diffs. An imperative `set_next_error` would let callers pretend they're talking to pseudo (P6 violation: consumers must not know).
**Considered and rejected.** *`PseudoStudioClient.set_next_error(...)` debug API* — see above.

---

## `HttpStudioClient` v0.2+ (forward-looking placeholder)

Module: `packages/studio-client/src/entelecheia_studio_client/http/__init__.py` (file exists in v0.1 only as a stub raising `NotImplementedError("HttpStudioClient is v0.2+; use PseudoStudioClient")`).

### Translation-layer strategy (P7)

When studio's actual API differs from this Protocol, translation lives **inside** `HttpStudioClient`, never in features. The three permitted strategies (from `docs/design/02-studio-integration.md`):

- **A. Update the Protocol.** Studio's shape is genuinely better; we update Protocol + Pseudo + consumers in one PR.
- **B. Translate inside `HttpStudioClient`.** Endpoint paths / field names / paging differ but the conceptual shape matches; HttpStudio rewrites in/out.
- **C. Sandwich layer.** Cross-cutting concerns (auth refresh, retry with backoff, request-id injection, observability) live in middleware between `HttpStudioClient` and the network.

v0.2 starts with **B** as the default and adds **C** middleware as concerns surface. **A** is reserved for cases where adapting locally would cost more than a Protocol bump.

### Configuration

```python
class HttpStudioClientConfig(BaseModel):
    base_url:               str                    # e.g. "https://studio.internal/api/v1"
    auth_token_provider:    "Callable[[], Awaitable[str]]"   # async; injected; sandwich layer may wrap
    request_timeout_s:      float = 30.0
    stream_timeout_s:       float = 120.0
    max_inflight_requests:  int   = 32
    retry_policy:           "RetryPolicy" = ...
```

### Sandwich-layer hooks (composable middleware contract, deferred details)

`HttpStudioClient` accepts an ordered list of `SandwichLayer` objects; each wraps the next. v0.1 fixes the contract so v0.2 can add layers without touching call sites:

```python
class SandwichLayer(Protocol):
    async def around_call(
        self,
        *,
        method_name: str,
        kwargs:      dict[str, object],
        next_:       "Callable[..., Awaitable[object]]",
    ) -> object:
        ...
```

Concrete layers planned for v0.2: `AuthRefreshLayer`, `RetryLayer`, `ObservabilityLayer`. Each is a single file at `packages/studio-client/src/entelecheia_studio_client/http/middleware/`.

---

## Substitution test matrix

Substitution tests live at `packages/studio-client/tests/substitution/` and run the same test bodies against both implementations via parametrization:

```python
@pytest.fixture(params=["pseudo", "http_recorded"])
def studio(request) -> StudioClient: ...
```

`http_recorded` uses recorded fixtures of real studio responses (added in v0.2; in v0.1 the `http` parameter is skipped). All `[SUB]`-marked tests in this spec run under this fixture.

**Categories.**

| # | Category | What it validates | Tests it covers |
|---|---|---|---|
| 1 | DTO round-trip | every DTO serializes → wire → deserializes to equal value | one test per DTO type |
| 2 | Method behavior parity | every `[SUB]` test_id passes identically | every `[SUB]` row above |
| 3 | Stream ordering & dedup | `subscribe_*` yields monotonic, gap-free, dedup-safe events | `t_sm_*` and `t_skt_*` |
| 4 | Error parity | each leaf error is raised under the same condition by both impls | one test per error class |
| 5 | Reconnect parity | reconnect from cursor does not re-yield, does not skip | `t_sm_reconnect_dedup`, `t_skt_*` |

Naming convention: `tests/substitution/test_<surface>__<scenario>.py` with test_ids matching the table rows above so failures point at this spec.

**Definition of "passes identically".** Same return type, same field values for deterministic fields, same exception type. Wall-clock fields are compared with tolerance.

---

## i18n

This package produces no user-visible strings. Errors carry English `message` for logging, plus `code` (the class name) which the product API layer maps to localized UI strings in `packages/platform-shell/i18n/`. Studio-side localized content (e.g. `paradigm_kind` display labels) is fetched separately and is not this module's concern.

---

## Why this design / Why not the alternative — consolidated load-bearing decisions

Decisions covered inline above are not repeated. The following are cross-cutting.

**Why a single `StudioClient` Protocol, not per-domain interfaces** (`ProjectsClient`, `MeetingsClient`, …).
Composition costs (DI wiring of N small clients across features) outweigh modularity gains; per-domain split also makes substitution-test parametrization N× more wiring. One Protocol + one swap point matches P7's "single most-leveraged abstraction."
**Considered and rejected.** *Per-domain interfaces* — see above. *No Protocol, just direct `HttpStudioClient`* — destroys testability and the v0.1 → v0.2 swap path.

**Why all methods are `async`.**
Studio I/O is naturally async (HTTP / WebSocket). A sync method on the Protocol forces blocking from agora's stream consumer down to the network — which is incorrect for a stream-driven UI.
**Considered and rejected.** *Mixed sync + async* — confusing; substitution tests would have to handle both.

**Why opaque `vertical_id: str` (instead of typed enum).**
Studio-client cannot know which verticals exist (P10). A typed enum would force studio-client to update for every new vertical pack — an architectural inversion.
**Considered and rejected.** *`Literal["v1", "v2", ...]`* — see above.

**Why `MeetingHandle` (rich) instead of returning a bare `MeetingId`.**
Callers (wizard, agora) need at minimum `meeting_id`, `started_at`, `status` immediately to render UI without a second round-trip. Bundling them is one extra struct, no extra round-trip.
**Considered and rejected.** *Bare `MeetingId`* — every caller would `get_meeting_summary` immediately; chatty.

**Why `get_meeting_outcome` raises `MeetingNotReady` instead of returning a partial outcome.**
Type system (separate `WorkingOutcome` / `FinalOutcome`) plus runtime check prevent storing a transient outcome as if it were final — the kind of bug that becomes a serious data-quality problem at scale.
**Considered and rejected.** *Return `WorkingOutcome | FinalOutcome` union* — defers the safety check to every caller; one missed branch is a silent corruption.

**Why explicit `from_clock` reconnect cursor.**
Reconnect semantics must be deterministic and replayable. Hidden cursors leak state across the boundary and are impossible to debug from logs.
**Considered and rejected.** *Server-tracked subscriber state* — server-side state for every subscriber is operational pain; `from_clock` makes the client honest.

**Why one stream per meeting per call (no fan-in / fan-out).**
Multiple consumers can each call `subscribe_meeting`; each gets the same per-meeting monotonic sequence. Multi-meeting fan-in or topic filters complicate cancellation and increase the substitution-test surface combinatorially.
**Considered and rejected.** *`subscribe_many_meetings([m1,m2])`* — composable on the consumer side via `asyncio.gather`; not worth a Protocol method.

**Why `CostReport` is read-only here (no `accrue_cost(...)`).**
Cost ledger is studio's source of truth (P3). Product reads aggregates for observability; product never writes cost.
**Considered and rejected.** *Two-way cost API* — invites product features to fudge cost numbers; bad incentive structure.

**Why `ReportArtifact.bytes_` is inline.**
Hides transport from feature code (P7). Pseudo reads from a fixture file; Http downloads from studio and packs in. Either way, callers get the same shape.
**Considered and rejected.** *`download_url`* — feature would need studio's auth token; transport leaks upward.

**Why `permissions.yaml` is a separate fixture (not embedded in `projects.yaml`).**
Permission checks are cross-cutting across all methods. A central permission map matches how the real auth-service surfaces grants; embedding per-resource would force every fixture file to know about users.
**Considered and rejected.** *Per-resource embedded permissions* — duplication.

**Why studio-side internals are explicitly out of this spec.**
This spec is the contract. Studio's implementation can change without touching this spec, as long as the Protocol holds. Documenting studio's mechanics here would invite drift between two repos.
**Considered and rejected.** *"Reference appendix" of studio internals* — documentation rot risk.

---

## Pre-merge checklist

- [ ] Mission + Scope present; "out of scope for v0.1" listed
- [ ] All 18 Protocol methods defined with full async signatures
- [ ] All cross-boundary DTOs defined as `pydantic.BaseModel` with full field signatures
- [ ] `MeetingEvent` is a discriminated union over `kind`; all 9 variants present
- [ ] `WorkingOutcome` and `FinalOutcome` are distinct types (not unified by status field)
- [ ] Sealed error taxonomy: 1 base + 14 leaf classes; each declares retryable / surfaces_verbatim / http_status
- [ ] Each Protocol method has an explicit `Raises:` declaration matching the taxonomy (no bare `Exception`)
- [ ] Each Protocol method has a test matrix table covering at minimum: happy, empty/boundary, each declared exception, each permission gate
- [ ] Every test_id in the matrices is marked `[SUB]` if substitution-eligible (default: yes for this spec)
- [ ] `PseudoStudioClient` fixture directory layout is fully enumerated
- [ ] Fixture file schemas (projects.yaml, meeting_templates.yaml, …) shown with full examples
- [ ] Time-simulation rules pinned (200 ms heartbeat, deterministic timestamps, jitter rule)
- [ ] Error-injection rules pinned (per-call, per-stream, global overlays)
- [ ] State-machine invariants enumerated and tied to test_ids
- [ ] `HttpStudioClient` placeholder location + translation-layer strategy (A/B/C) named
- [ ] Substitution test matrix: 5 categories enumerated with what each validates
- [ ] No business / domain / product / agent-role string literals in this spec (only neutral placeholders like `"<v>"`, `"agt_archi"`)
- [ ] No reference to `entelecheia` (engine) anywhere
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/01-studio-client-spec.md`
