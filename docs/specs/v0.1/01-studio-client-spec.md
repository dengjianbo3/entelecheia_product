# 01 — `studio-client` v0.1 spec

> **Status**: v0.1 contract, aligned to studio's binding API contract effective 2026-04-30 (studio v0.1.0+).
> **Lives at**: `packages/studio-client/`.
> **Upstream contract**: [`Entelecheia_studio/docs/api-contract.md`](../../../../Entelecheia_studio/docs/api-contract.md), frozen through studio v2.0.
> **Owner of this contract**: product. Owner of the studio-side implementation: studio repo.
> **Supersedes**: the fictional draft at the same path committed in `d0b7699` (pre-studio-contract).

---

## Mission

This file defines the `StudioClient` Protocol — the only path by which `entelecheia_product` reaches studio — together with all DTOs that cross that boundary, the sealed product-side error taxonomy, the v0.1 `PseudoStudioClient` (fixture-backed) implementation, and the v0.2+ `HttpStudioClient` translation layer that maps studio's frozen HTTP/SSE surface to this Protocol.

**Hard rule:** the DTOs in this spec mirror studio's frozen schemas (api-contract.md §4–§5) field-for-field. Field names, types, and nullability are NOT design choices on our side — studio froze them, we relay. Any divergence is a bug.

---

## Scope

**Covers.**
- `StudioClient` Protocol: 11 async methods that cover product's read access to studio (projects / agents / meetings / outcomes / cost / health). Each method maps 1:1 to a studio HTTP endpoint.
- All cross-boundary DTOs mirroring studio's `§4 Frozen JSON Schemas` (specs we read) and `§5 Frozen Response Schemas` (responses we consume): `AgentSpec`, `ProjectSpec`, `SkillManifest`, sub-schemas, `OutcomeResponse` + `MeetingOutcome`, `CostReport` + `CostReportRow` + `CostQuery`, `MeetingSummary`, `MeetingStatus`, `SpecSummary`, `ErrorResponse`.
- The 26-variant `MeetingEvent` model: studio's 24 frozen `EventType` literals (inherited from engine) + 2 studio-injected (`meeting_finalized`, `meeting_failed`).
- Sealed product-side error taxonomy (1 base + 14 leaves) plus the explicit **studio→product error mapping table** (60+ studio error types → 14 product leaves) that lives inside `HttpStudioClient`.
- `PseudoStudioClient` v0.1 fixture directory layout, fixture file schemas, time-simulation rules (200 ms heartbeat, deterministic timestamps), declarative error injection, in-memory state machine, invariants.
- `HttpStudioClient` v0.2+ concrete responsibilities: URL composition, SSE → AsyncIterator translation, `Last-Event-Id` reconnect, error mapping, auth (v0.2 bearer token deferral).
- Substitution test matrix: 5 categories with `[SUB]` markers throughout.
- **Known studio v0.1 limitations** (capabilities product needs but studio doesn't yet expose): documented as deferred to studio v0.2+ and explicitly OUT of this Protocol so product code cannot pretend they exist.
- **Downstream impact on Batches B–F**: routing notes for every later spec that depends on this contract.

**Does not cover.**
- Studio's internal mechanics (paradigm execution, agent runtime, skill bundles, memory backends, LLM client selection). This spec describes only what product asks studio for, never what studio does to answer.
- Spec authoring (`POST /v1/agents`, `/publish`, `/archive`, plus the project-side counterparts). Per **P1**, agent / project authoring is studio-admin work, not end-user product. Studio exposes those routes; product does not call them. (See §10.7 below.)
- Skill installation (`POST /v1/skills/install`). Same rationale.
- Studio admin introspection (`GET /v1/paradigms`, `GET /v1/extensions`, `GET /v1/models`). Not consumed by any v0.1 product feature.
- Product-side derivations: working consensus reducer, DAG construction, provenance trace assembly, knowledge-tree view, report rendering. These are PRODUCT-SIDE features that consume studio events / outcomes; they are out of `studio-client` and live in agora / reports / knowledge feature specs (`05`–`07`). See §11 below.
- Auth / JWT / session — `auth-service` spec (`03`).
- TS mirror types for the frontend — `16-apps-frontend-spec.md` declares `apps/frontend/src/types/studio-client/` as the codegen target (Python is canonical here).

**Out of scope for v0.1 (deferred to v0.2+).**
- `HttpStudioClient` implementation. v0.1 ships its module location, the URL/SSE/error mapping rules, and auth deferral; full implementation lands in v0.2 once studio is reachable.
- `Authorization: Bearer <token>` header (studio v0.2; see studio §10).
- Pause / resume / stop meeting + inject human input (studio §3.6 does not yet expose endpoints; see §10 below).

---

## Upstream contract anchor

This spec MIRRORS, never contradicts, studio's binding contract. References below cite the relevant section of [`Entelecheia_studio/docs/api-contract.md`](../../../../Entelecheia_studio/docs/api-contract.md):

| Studio §  | Subject                                                        | Where it lands in this spec                |
|-----------|----------------------------------------------------------------|--------------------------------------------|
| §1        | Stability commitment (`>=0.1,<2.0` window)                     | §0 Mission; pinning lives in pyproject.toml |
| §3.1      | General HTTP conventions (base URL, Content-Type, ISO-8601, identifier formats) | §3 Identifier types; §9 HttpStudioClient |
| §3.4      | `GET /v1/agents`, `GET /v1/agents/{id}`, `GET /v1/agents/{id}/{version}` | §7 Protocol methods 3, 4 |
| §3.5      | `GET /v1/projects`, `GET /v1/projects/{id}`, `GET /v1/projects/{id}/{version}` | §7 Protocol methods 1, 2 |
| §3.6      | `POST /v1/projects/{id}/run`, `GET /v1/meetings`, `GET /v1/meetings/{id}`, `GET /v1/meetings/{id}/events`, `GET /v1/meetings/{id}/outcome` | §7 Protocol methods 5–9 |
| §3.7      | `GET /v1/cost/report`                                          | §7 Protocol method 10                      |
| §3.8      | `GET /healthz`, `GET /readyz`, `GET /v1/version`               | §7 Protocol method 11                      |
| §4.1–§4.4 | Frozen request schemas (`AgentSpec`, `ProjectSpec`, `SkillManifest`, sub-schemas) | §4 DTOs                                   |
| §5.1–§5.5 | Frozen response schemas (`MeetingOutcome`, `CostReport`, `MeetingSummary`, `MeetingStatus`, `SpecSummary`, `ErrorResponse`) | §5 DTOs                                   |
| §6        | SSE event stream contract (24 EventTypes + `meeting_finalized` + `meeting_failed`, `Last-Event-Id` resumption, format) | §6 MeetingEvent + SSE translation       |
| §7        | Skill bundle authoring contract                                | not consumed by v0.1 product              |
| §8        | Error catalog (60+ types, HTTP status mapping, extra fields)   | §8 Error model + 60→14 mapping table     |
| §9        | Behavior contracts (long-running 202+SSE pattern, immutability, monotonic version, idempotency, loud failures) | §9 HttpStudioClient §11 limitations    |
| §10       | Auth (v0.1: none; v0.2: bearer token)                         | §9 HttpStudioClient (auth deferral)       |
| §11       | Deprecation process                                            | §10.8 Pinning / drift detection           |
| §12       | CI compatibility self-test                                     | §10.9 referenced from substitution tests   |

If studio's contract changes within the `>=0.1,<2.0` window per its rules (additive only — new routes, new optional fields, new EventType literals, new error subtypes), this spec needs additive updates only. Breaking changes require a studio v2.0; product at that point gates on the new contract via `pyproject.toml` constraint update.

---

## §3 Identifier types

Identifier formats are pinned by studio §3.1. We type them with `typing.NewType` so the type system rejects passing one ID where another is expected. Format constraints are NOT validated at the boundary — studio rejects malformed IDs with `ApiInvalidRequestError`; we surface that as `InvalidArgument`.

```python
# packages/studio-client/src/entelecheia_studio_client/ids.py

from typing import NewType

# slug: ^[a-z][a-z0-9_-]*$  (studio §3.1)
SpecId    = NewType("SpecId",    str)   # alias for any spec_id (agent / project / skill)
ProjectId = NewType("ProjectId", str)   # alias of SpecId in the project space
AgentId   = NewType("AgentId",   str)   # alias of SpecId in the agent space
SkillId   = NewType("SkillId",   str)

# 12-character hex (studio §3.1)
MeetingId = NewType("MeetingId", str)

# free-form v0.1; studio's `created_by`/`user_id`; product treats opaque
UserId    = NewType("UserId",    str)

# positive int (studio §3.1)
SpecVersion = NewType("SpecVersion", int)

# integer JSONL line number (studio §6.1: `id: 42`)
EventId   = NewType("EventId",   int)
```

TS mirrors at `apps/frontend/src/types/studio-client/ids.ts` are branded string types. Single source of truth: this file.

**Why `NewType` over raw `str`.** Catches `subscribe_meeting(project_id)` where `meeting_id` was meant — a class of bug we will hit otherwise. Cost is one cast at deserialization; cheap.

---

## §4 DTOs from studio §4 — Specs (read-only for product)

Product **reads** these via the Protocol's `get_*` / `list_*` methods. Product **never authors** them (P1: spec authoring is studio admin). Field names / types / nullability mirror studio §4 verbatim.

### 4.1 `SpecSummary`

Lightweight metadata returned by list endpoints (`§5.3` of studio).

```python
class SpecSummary(BaseModel):
    spec_kind:    Literal["agent", "project", "skill_manifest"]
    spec_id:      SpecId
    version:      int                       # 0 for drafts (we should never see 0 from product Protocol; we only list published)
    status:       Literal["draft", "published", "archived"]
    created_at:   datetime                  # ISO-8601 UTC
    updated_at:   datetime
    created_by:   str                       # free-form v0.1 (env user)
    description:  str | None
    is_draft:     bool                      # = (status == "draft")
```

### 4.2 `AgentSpec`

Studio §4.1.

```python
class AgentSpec(BaseModel):
    spec_kind:        Literal["agent"]
    schema_version:   Literal["v0.1"]
    spec_id:          AgentId
    version:          SpecVersion           # >=1 for published; 0 for drafts (we don't see 0)
    status:           Literal["draft", "published", "archived"]
    created_at:       datetime
    updated_at:       datetime
    created_by:       str
    description:      str | None

    paradigm:         "ParadigmRef"
    model:            "ModelRef" | None
    skills:           list["SkillRef"]
    system_prompt:    str
    role_tags:        list[str]
    memory:           dict[str, object] | None     # studio §4.1: v0.1 always None; v0.1.5 introduces shape
    # WHY dict[str, object]: the field is forward-declared by studio; product treats opaque until v0.1.5.
```

### 4.3 `ProjectSpec`

Studio §4.2.

```python
class ProjectSpec(BaseModel):
    spec_kind:           Literal["project"]
    schema_version:      Literal["v0.1"]
    spec_id:             ProjectId
    version:             SpecVersion
    status:              Literal["draft", "published", "archived"]
    created_at:          datetime
    updated_at:          datetime
    created_by:          str
    description:         str | None

    agents:              list["AgentMemberRef"]
    engine_extensions:   "EngineExtensionsRef"
    meeting_defaults:    "MeetingDefaults"
    skill_overrides:     dict[str, "SkillOverride"]   # skill_id -> override
```

### 4.4 Sub-schemas

Studio §4.4. The four built-in `paradigm.type` values, the two built-in `model.provider` values, and the three built-in extension `type` values are stable through studio v2.0; new ones may be added (additive).

```python
class ParadigmRef(BaseModel):
    type:    str                        # "cot" | "rewoo" | "react" | "custom" | <plugin>
    params:  dict[str, object]


class ModelRef(BaseModel):
    provider: str                       # "anthropic" | "openai" | <plugin>
    model_id: str
    params:   dict[str, object]         # temperature, max_tokens, top_p, ...


class SkillRef(BaseModel):
    skill_id: SkillId
    version:  str                       # semver constraint or "*"
    config:   dict[str, object] | None


class AgentMemberRef(BaseModel):
    agent_id: AgentId
    version:  SpecVersion               # pinned (immutability per studio §9.2)
    enabled:  bool = True


class EngineExtensionsRef(BaseModel):
    conclude_predicates:  list["ExtensionRef"]
    constraints:          list["ExtensionRef"]
    speaker_selector:     "ExtensionRef" | None
    phase_machine:        "ExtensionRef" | None


class ExtensionRef(BaseModel):
    type:    str                        # "builtin.linear" | "builtin.round_robin" | "builtin.max_turns" | <plugin>
    params:  dict[str, object]


class MeetingDefaults(BaseModel):
    max_turns: int = 20
    language:  str = "en"               # "en" | "zh" | ...


class SkillOverride(BaseModel):
    configuration: dict[str, object] | None
    budget_caps:   dict[str, object] | None      # v0.1 placeholder; reserved for v0.2
```

### 4.5 `SkillManifest`

Studio §4.3. Product reads this when displaying a skill's metadata; product never authors skill manifests at the Protocol layer (skill bundle authoring is out of v0.1 product, per §2 — though verticals MAY ship bundled skills, see §11.5).

```python
class SkillManifest(BaseModel):
    # agentskills.io standard fields (studio §4.3)
    name:                    str
    description:             str
    manifest_version:        str
    compatibility:           dict[str, str]                  # e.g. {"studio": ">=0.1,<2.0"}
    allowed_tools:           list[str]
    required_secrets:        list[str]
    disable_model_invocation: bool = False
    user_invocable:          bool = True

    # Studio extensions
    spec_kind:               Literal["skill_manifest"]
    schema_version:          Literal["v0.1"]
    spec_id:                 SkillId
```

### 4.6 `Material` (product-side; passed inline to studio at run time)

Studio's `POST /v1/projects/{id}/run` body takes `materials: [{kind, name, content}]` inline. There is **no upload registration step in v0.1** — studio does not assign material IDs. Product's uploads feature buffers files product-side; at meeting-start time the bytes are read and inlined.

```python
class Material(BaseModel):
    kind:    Literal["brief", "data"]    # studio's two documented kinds (§3.6 example)
    name:    str                         # filename or note title; <= 200 chars
    content: str | dict[str, object]     # str for text/markdown; dict for structured "data" payloads
    # WHY str|dict: studio's example shows {"kind":"brief","name":"context.txt","content":"..."} and
    # {"kind":"data","name":"metrics.json","content":{...}}. We mirror exactly.
```

**Why product never authors specs at the Protocol layer.** Per **P1** (product is end-user UI) + studio's documented persona model (specs are authored by studio operators / engineers, not end users), the v0.1 product's `StudioClient` Protocol exposes only **read** access to AgentSpec / ProjectSpec / SkillManifest. Studio's authoring endpoints (`POST /v1/agents`, `/publish`, `/archive`, etc.) are reachable from a future "studio admin vertical" with its own client; they are not exposed to end-user features.
**Considered and rejected.** *Include `archive_*` for "vertical wants to retire old projects"* — that's still admin work; if it becomes needed, a separate `StudioAdminClient` Protocol can be added without bloating the read-path.

---

## §5 DTOs from studio §5 — Responses (consumed by product)

### 5.1 `OutcomeResponse` + `MeetingOutcome`

Studio §5.1. Returned by `GET /v1/meetings/{id}/outcome` once `status == "completed"`.

```python
class OutcomeResponse(BaseModel):
    meeting_id:        MeetingId
    project_id:        ProjectId
    project_version:   SpecVersion
    started_at:        datetime
    ended_at:          datetime
    duration_seconds:  float
    outcome:           "MeetingOutcome | None"     # null if error
    error:             dict[str, object] | None    # null if success; matches §5.5 error envelope shape
    # WHY dict for error: studio uses the standard ErrorBody shape; product unpacks if needed.


class MeetingOutcome(BaseModel):                   # studio §5.1; mirrors engine's MeetingOutcome
    meeting_id:                 MeetingId
    concluded_by:               Literal[
        "consensus_reached",
        "max_turns",
        "deadline",
        "human_stop",
        "constraint_violation",
        "concluded_by_facilitator",
    ]
    consensus:                  list[dict[str, object]]   # ConsensusItem; engine-defined shape (engine §3.5)
    unresolved_disagreements:   list[dict[str, object]]   # Disagreement
    key_facts:                  list[dict[str, object]]   # Fact
    open_questions:             list[dict[str, object]]   # OpenQuestion
    started_at:                 datetime
    concluded_at:               datetime
    total_turns:                int
    final_constraints_status:   list[dict[str, object]]   # ConstraintResult
    merkle_root:                str                       # 64-hex sha256; portable audit anchor
    # WHY list[dict] for the inner items: studio explicitly relays engine shapes verbatim and we don't
    # have engine's contract pinned in this spec yet. Product code accesses fields by key. v0.2 may
    # introduce typed inner DTOs once engine's contract is mirrored under
    # packages/studio-client/src/entelecheia_studio_client/dto/engine.py.
```

`concluded_by` is a stable enum; product `match` blocks should include `case _:` to forward-compatibly skip new values added in studio pre-2.0 minors.

### 5.2 `CostReport` / `CostReportRow` / `CostQuery`

Studio §5.2. Returned by `GET /v1/cost/report`.

```python
class CostQuery(BaseModel):                       # echo of the query parameters
    project_id:  ProjectId | None
    meeting_id:  MeetingId | None
    user_id:     UserId    | None
    agent_id:    AgentId   | None
    skill_id:    SkillId   | None
    model_id:    str       | None
    kind:        str       | None
    since:       datetime  | None
    until:       datetime  | None
    group_by:    list[str]                        # subset of {project_id, meeting_id, user_id, agent_id, skill_id, model_id, kind}


class CostReportRow(BaseModel):
    project_id:         ProjectId | None          # group-by echo (null for ungrouped dims)
    meeting_id:         MeetingId | None
    user_id:            UserId    | None
    agent_id:           AgentId   | None
    skill_id:           SkillId   | None
    model_id:           str       | None
    kind:               str       | None
    record_count:       int
    total_cost_usd:     float
    total_tokens_in:    int
    total_tokens_out:   int
    total_duration_ms:  int


class CostReport(BaseModel):
    rows:           list[CostReportRow]
    total_cost_usd: float
    total_records:  int
    query:          CostQuery                     # echoed for traceability
```

### 5.3 `MeetingSummary` / `MeetingStatus`

Studio §5.4.

```python
class MeetingSummary(BaseModel):                  # GET /v1/meetings list-row shape
    meeting_id:       MeetingId
    project_id:       ProjectId
    project_version:  SpecVersion
    status:           Literal["running", "completed", "failed"]
    started_at:       datetime
    ended_at:         datetime | None             # null when running
    user_id:          UserId


class MeetingStatus(BaseModel):                   # GET /v1/meetings/{id} detail shape
    meeting_id:       MeetingId
    project_id:       ProjectId
    project_version:  SpecVersion
    status:           Literal["running", "completed", "failed"]
    started_at:       datetime
    ended_at:         datetime | None
    user_id:          UserId
    events_url:       str                         # path under base, e.g. "/v1/meetings/<id>/events"
    outcome_url:      str | None                  # null when running
    error_class:      str | None                  # set only on failed; one of studio §8.2 type strings
    error_message:    str | None                  # human-readable; NOT contract-stable per studio §5.5
```

`POST /v1/projects/{id}/run` returns a 202 envelope distinct from these shapes; product's Protocol returns it as `MeetingHandle` (§5.4).

### 5.4 `MeetingHandle` (product-side type wrapping studio's 202 response)

Studio §3.6's `POST /v1/projects/{id}/run` returns 202 with body `{meeting_id, project_id, project_version, status, started_at, events_url, outcome_url, status_url}`. We mirror exactly:

```python
class MeetingHandle(BaseModel):
    meeting_id:       MeetingId
    project_id:       ProjectId
    project_version:  SpecVersion
    status:           Literal["running"]          # always "running" at 202 time
    started_at:       datetime
    events_url:       str                         # "/v1/meetings/<id>/events"
    outcome_url:      str                         # "/v1/meetings/<id>/outcome"
    status_url:       str                         # "/v1/meetings/<id>"
```

### 5.5 `ErrorResponse`

Studio §5.5. Every non-2xx body has this shape.

```python
class ErrorBody(BaseModel):
    type:    str                                   # one of studio §8.2 frozen type strings
    message: str                                   # human-readable; NOT part of the contract
    # additional fields per error type per studio §8.3 (e.g. retry_after_seconds, missing_env_vars)
    extras:  dict[str, object] = {}                # captured by HttpStudioClient at parse time


class ErrorResponse(BaseModel):
    error: ErrorBody
```

Product code switches on `error.type` to map to a product-side leaf (see §8.2 mapping table); `error.message` is for logging only.

---

## §6 `MeetingEvent` — the 26-variant model

Studio §6 freezes the SSE stream format, the 24 engine `EventType` literals, and the 2 studio-injected types (`meeting_finalized`, `meeting_failed`). `subscribe_meeting` yields `MeetingEvent` instances; HttpStudioClient parses SSE lines into these.

### 6.1 The frozen 26 event types

```python
EventType = Literal[
    # Cognitive (14) — studio §6.2
    "RootQuestionPosed", "ClaimMade", "ChallengeRaised", "TriggerDefined",
    "UnknownRaised",     "ConsensusReached", "ContradictionFound",
    "FragilityRaised",   "PathProposed", "UserInjected", "PivotIdentified",
    "EmergenceObserved", "DeadEndDeclared", "ArgumentDimensionDeclared",

    # Lifecycle (6)
    "MeetingStarted", "StageAdvanced", "ChallengeResolved",
    "MeetingPaused",  "MeetingResumed", "MeetingFrozen",

    # Low-level operations (4)
    "MessageEmitted", "EvidenceCited", "ToolCalled", "InternalStep",

    # Studio-injected (2) — studio §6.4
    "meeting_finalized", "meeting_failed",
]
```

This list is frozen through studio v2.0. New types may be added in pre-2.0 minors (additive); product event handlers MUST treat unknown `event_type` values as **log-and-skip** (forward-compat per studio §6.2).

### 6.2 `MeetingEvent`

```python
class MeetingEvent(BaseModel):
    event_id:    EventId                           # SSE `id:` line; line number in studio's per-meeting JSONL archive
    event_type:  EventType                         # SSE `event:` line; one of the 26 frozen names
    data:        dict[str, object]                 # SSE `data:` line; engine-defined payload object (dataclasses.asdict from engine)
    # WHY data: dict[str, object] (not typed): per-event payload schemas live in engine's contract §4
    # which we have not yet mirrored. Product code reduces events through TypedDict-like accessors
    # (see §6.3 typed views below). When engine's contract is imported into
    # packages/studio-client/src/entelecheia_studio_client/dto/engine.py (post-v0.1), data becomes
    # a discriminated union over event_type. Forward-compatible.
```

### 6.3 Typed-view helpers for the events product reduces

Product code reduces five event types into UI state (see §11 Downstream Impact and `01b-product-derivations-spec.md` once that's written). For these, we provide TypedDict shape declarations. The remaining 21 event types remain as opaque `dict[str, object]` payloads accessed by key.

```python
# Provided in packages/studio-client/src/entelecheia_studio_client/event_views.py

class ClaimMadeData(TypedDict, total=False):
    claim_id:     str
    asserted_by:  str          # agent_id of speaker
    content:      str          # the claim text
    # plus engine-defined fields product treats as forward-compatible


class ConsensusReachedData(TypedDict, total=False):
    claim_ids:    list[str]
    confidence:   float


class MessageEmittedData(TypedDict, total=False):
    agent_id:     str
    content:      str
    timestamp:    str          # ISO-8601


class MeetingFinalizedData(TypedDict, total=False):
    # studio §6.4: data is the OutcomeResponse envelope
    outcome:      dict[str, object]    # OutcomeResponse shape, see §5.1


class MeetingFailedData(TypedDict, total=False):
    error:        dict[str, object]    # ErrorBody shape, see §5.5
```

### 6.4 SSE → AsyncIterator translation rules (lives in HttpStudioClient)

Studio §6.1 wire format:

```
id: 42
event: ClaimMade
data: {"claim_id": "c1", "asserted_by": "agent-A", "content": "...", ...}

```

Translation discipline (HttpStudioClient implements; PseudoStudioClient does not need SSE because it produces `MeetingEvent` objects directly from fixtures):

1. Read three lines per event: `id:` → int, `event:` → string, `data:` → JSON parse. Blank line terminates.
2. Heartbeat lines (`: keepalive`) studio §6.1 — strip silently; do not yield.
3. **Termination signal**: when `event_type` is `meeting_finalized` OR `meeting_failed`, yield the event then close the iterator. The HTTP connection may be closed afterwards.
4. **Unknown `event_type`**: yield the event as-is (no exception). Consumer log-and-skips per studio §6.2 forward-compatibility rule.
5. **Missing `id:`** (shouldn't happen per studio contract, but defensive): treat as `event_id = -1`; consumers using the cursor will miss it, which is acceptable degradation.
6. **Connection drop mid-event**: HttpStudioClient catches `ConnectionError` and re-raises as `StudioUnavailable`. The caller is responsible for re-subscribing with the last `event_id` it saw (see §7 method 8).

---

## §7 `StudioClient` Protocol — 11 methods

Module: `packages/studio-client/src/entelecheia_studio_client/protocol.py`.
All methods are `async`. All raise from the sealed taxonomy in §8. Test matrices below mark substitution-eligible tests with `[SUB]` (must pass under both Pseudo and Http per `17-substitution-tests-spec.md`).

```python
class StudioClient(Protocol):
    """The single boundary between product and studio. Product code depends on this Protocol;
    never on a concrete implementation. Methods map 1:1 to studio's HTTP endpoints (§3 of
    studio's api-contract.md)."""
```

### 7.1 `list_projects`

```python
async def list_projects(
    self,
    *,
    status:           Literal["draft", "published", "archived"] | None = "published",
    include_archived: bool = False,
    limit:            int = 50,                    # studio §3.1: max 500
    offset:           int = 0,
) -> list[SpecSummary]:                            # studio returns {"data": [...], "total": N}; we expose the items
    ...
```

**Wraps.** `GET /v1/projects` (studio §3.5). The `limit` / `offset` paging style is studio's (not cursor-based).
**Default behavior.** Returns published projects only. Pass `status=None, include_archived=True` for all.
**Raises.** `StudioUnavailable | InvalidArgument`.
**Does NOT do.** Vertical filtering (studio's ProjectSpec has no `labels` field). Product's vertical manifest declares an explicit `project_id_in: list[str]` allowlist consumed by feature code; that filtering is product-side. See §11.4.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy, default | no args | non-empty list of `status="published"` summaries | `[SUB] t_lp_default` |
| explicit status filter | `status="archived", include_archived=True` | only archived | `[SUB] t_lp_archived` |
| paging | `limit=2, offset=2` | next 2 entries (no overlap with offset=0) | `[SUB] t_lp_paging` |
| invalid limit | `limit=501` | raises `InvalidArgument` | `[SUB] t_lp_invalid_limit` |
| studio down | fixture `studio_down` | raises `StudioUnavailable` | `[SUB] t_lp_studio_down` |

### 7.2 `get_project`

```python
async def get_project(
    self,
    *,
    project_id: ProjectId,
    version:    SpecVersion | None = None,         # None = latest published
) -> ProjectSpec:
    ...
```

**Wraps.** `GET /v1/projects/{id}` when `version is None`; `GET /v1/projects/{id}/{version}` otherwise (studio §3.5).
**Raises.** `StudioUnavailable | NotFound | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| latest | `project_id=p` | `ProjectSpec` with status `published` | `[SUB] t_gp_latest` |
| pinned | `project_id=p, version=1` | `ProjectSpec` for that version (any status) | `[SUB] t_gp_pinned` |
| not found (id) | `project_id="missing"` | raises `NotFound` (mapped from `SpecNotFoundError`) | `[SUB] t_gp_not_found` |
| not found (version) | `project_id=p, version=999` | raises `NotFound` (mapped from `VersionNotFoundError`) | `[SUB] t_gp_version_not_found` |
| invalid version | `version=-1` | raises `InvalidArgument` | `[SUB] t_gp_invalid_version` |

### 7.3 `list_agents`

```python
async def list_agents(
    self,
    *,
    status:           Literal["draft", "published", "archived"] | None = "published",
    include_archived: bool = False,
    limit:            int = 50,
    offset:           int = 0,
) -> list[SpecSummary]:
    ...
```

**Wraps.** `GET /v1/agents` (studio §3.4).
**Raises.** `StudioUnavailable | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy | no args | published agents | `[SUB] t_la_default` |
| paging | `limit=2, offset=4` | next 2 | `[SUB] t_la_paging` |
| invalid limit | `limit=0` | raises `InvalidArgument` | `[SUB] t_la_invalid_limit` |

### 7.4 `get_agent`

```python
async def get_agent(
    self,
    *,
    agent_id: AgentId,
    version:  SpecVersion | None = None,
) -> AgentSpec:
    ...
```

**Wraps.** `GET /v1/agents/{id}` or `/v1/agents/{id}/{version}` (studio §3.4).
**Raises.** `StudioUnavailable | NotFound | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| latest | `agent_id=a` | `AgentSpec` (published) | `[SUB] t_ga_latest` |
| pinned | `agent_id=a, version=2` | `AgentSpec` for that version | `[SUB] t_ga_pinned` |
| not found | `agent_id="missing"` | raises `NotFound` | `[SUB] t_ga_not_found` |

### 7.5 `run_meeting`

```python
async def run_meeting(
    self,
    *,
    project_id:      ProjectId,
    topic:           str,                          # studio §3.6 body
    materials:       list[Material],
    user_id:         UserId,
    project_version: SpecVersion | None = None,    # None = latest published
) -> MeetingHandle:
    ...
```

**Wraps.** `POST /v1/projects/{project_id}/run` with body `{version, topic, materials, user_id}` (studio §3.6). Returns 202 within ~100 ms; the meeting itself runs **30 seconds to 180 minutes** in background per studio §9.1.
**Raises.** `StudioUnavailable | NotFound | PublishValidation | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| happy | valid project, topic, materials | `MeetingHandle{ status: "running" }` within 100 ms | `[SUB] t_rm_happy` |
| pinned version | `project_version=2` | handle with `project_version=2` | `[SUB] t_rm_pinned_version` |
| project not found | `project_id="x"` | raises `NotFound` | `[SUB] t_rm_not_found` |
| project not published | unpublished project | raises `PublishValidation` (mapped from `PublishValidationError`) | `[SUB] t_rm_not_published` |
| empty topic | `topic=""` | raises `InvalidArgument` | `[SUB] t_rm_empty_topic` |

### 7.6 `list_meetings`

```python
async def list_meetings(
    self,
    *,
    project_id: ProjectId | None = None,
    status:     Literal["running", "completed", "failed"] | None = None,
    since:      datetime | None = None,
    limit:      int = 50,
    offset:     int = 0,
) -> list[MeetingSummary]:
    ...
```

**Wraps.** `GET /v1/meetings` (studio §3.6).
**Raises.** `StudioUnavailable | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| by project | `project_id=p` | meetings for p | `[SUB] t_lm_by_project` |
| by status | `status="completed"` | only completed | `[SUB] t_lm_by_status` |
| since | `since=<24h ago>` | recent only | `[SUB] t_lm_since` |
| paging | `limit=2, offset=2` | next 2 | `[SUB] t_lm_paging` |

### 7.7 `get_meeting_status`

```python
async def get_meeting_status(self, *, meeting_id: MeetingId) -> MeetingStatus:
    ...
```

**Wraps.** `GET /v1/meetings/{id}` (studio §3.6).
**Raises.** `StudioUnavailable | NotFound`.

| scenario | input | expected | test_id |
|---|---|---|---|
| running | running meeting | `MeetingStatus{ status: "running", outcome_url: None }` | `[SUB] t_gms_running` |
| completed | completed meeting | `MeetingStatus{ status: "completed", outcome_url: "<path>" }` | `[SUB] t_gms_completed` |
| failed | failed meeting | `MeetingStatus{ status: "failed", error_class, error_message }` | `[SUB] t_gms_failed` |
| not found | missing | raises `NotFound` | `[SUB] t_gms_not_found` |

### 7.8 `subscribe_meeting`

```python
async def subscribe_meeting(
    self,
    *,
    meeting_id:    MeetingId,
    last_event_id: EventId | None = None,           # None = from start (studio archives all)
) -> AsyncIterator[MeetingEvent]:
    ...
```

**Wraps.** `GET /v1/meetings/{meeting_id}/events` (studio §3.6 + §6) with `Accept: text/event-stream` and optional `Last-Event-Id: <int>` header.
**Termination.** Iterator ends after one of `meeting_finalized` / `meeting_failed` is yielded (studio §6.4).
**Ordering guarantee** (studio §6.3). Strict per-meeting monotonic in `event_id`; gap-free; `Last-Event-Id` resumption returns events with `event_id > last_event_id`.
**Raises.** `StudioUnavailable | NotFound`.

| scenario | input | expected | test_id |
|---|---|---|---|
| from start | `last_event_id=None` | yields events from id=1 in order | `[SUB] t_sm_from_start` |
| from cursor | `last_event_id=42` | yields events with `event_id >= 43` | `[SUB] t_sm_from_cursor` |
| reconnect dedup | drop & resubscribe at last seen | resumed events have new `event_id`s; no duplicates | `[SUB] t_sm_reconnect_dedup` |
| terminates on finalized | run to completion | iterator yields `meeting_finalized` then ends | `[SUB] t_sm_finalized` |
| terminates on failed | meeting raises | yields `meeting_failed` then ends | `[SUB] t_sm_failed_terminates` |
| heartbeats stripped | studio sends `: keepalive` | not yielded; no spurious event | `[SUB] t_sm_heartbeat_strip` |
| unknown event_type | studio adds new type | yielded as-is; consumer log-and-skip | `[SUB] t_sm_unknown_type_forward_compat` |
| not found | `meeting_id="missing"` | raises `NotFound` | `[SUB] t_sm_not_found` |

### 7.9 `get_meeting_outcome`

```python
async def get_meeting_outcome(self, *, meeting_id: MeetingId) -> OutcomeResponse:
    ...
```

**Wraps.** `GET /v1/meetings/{id}/outcome` (studio §3.6). Studio returns 404 with `Retry-After: 5` header if meeting is still running; HttpStudioClient surfaces this as `MeetingNotReady`. Studio returns 404 without that header if `meeting_id` doesn't exist; surfaced as `NotFound`.
**Raises.** `StudioUnavailable | NotFound | MeetingNotReady`.

| scenario | input | expected | test_id |
|---|---|---|---|
| completed | completed meeting | `OutcomeResponse{ outcome: <MeetingOutcome>, error: None }` | `[SUB] t_gmo_completed` |
| failed | failed meeting | `OutcomeResponse{ outcome: None, error: <dict> }` | `[SUB] t_gmo_failed` |
| running | running meeting (404 + Retry-After) | raises `MeetingNotReady` | `[SUB] t_gmo_running` |
| not found | missing | raises `NotFound` | `[SUB] t_gmo_not_found` |

### 7.10 `get_cost_report`

```python
async def get_cost_report(
    self,
    *,
    project_id: ProjectId | None = None,
    meeting_id: MeetingId | None = None,
    user_id:    UserId    | None = None,
    agent_id:   AgentId   | None = None,
    skill_id:   SkillId   | None = None,
    model_id:   str       | None = None,
    kind:       str       | None = None,
    since:      datetime  | None = None,
    until:      datetime  | None = None,
    group_by:   list[str] = [],                     # subset of dimension names
) -> CostReport:
    ...
```

**Wraps.** `GET /v1/cost/report` (studio §3.7). All filters AND-combine.
**Raises.** `StudioUnavailable | InvalidArgument`.

| scenario | input | expected | test_id |
|---|---|---|---|
| by project | `project_id=p` | `CostReport` filtered to p | `[SUB] t_gcr_project` |
| by meeting | `meeting_id=m` | filtered to m | `[SUB] t_gcr_meeting` |
| group_by user | `group_by=["user_id"]` | rows grouped by user_id, others null | `[SUB] t_gcr_group_user` |
| group_by multi | `group_by=["project_id","model_id"]` | rows grouped by both | `[SUB] t_gcr_group_multi` |
| empty | filter with no matches | `CostReport{ rows: [], total_cost_usd: 0.0, total_records: 0 }` | `[SUB] t_gcr_empty` |
| invalid group_by | `group_by=["unknown"]` | raises `InvalidArgument` | `[SUB] t_gcr_invalid_group` |

### 7.11 `get_studio_health`

```python
async def get_studio_health(self) -> "StudioHealth":
    ...

class StudioHealth(BaseModel):
    live:            bool                          # /healthz returned 200
    ready:           bool                          # /readyz returned 200
    studio_version:  str
    engine_version:  str
    api_contract:    str                           # e.g. "v0.1"
    fetched_at:      datetime
```

**Wraps.** `GET /healthz` + `GET /readyz` + `GET /v1/version` (studio §3.8). HttpStudioClient calls all three concurrently and merges. PseudoStudioClient returns canned values.
**Raises.** `StudioUnavailable` if `/healthz` fails (the "is studio reachable at all" signal).

| scenario | expected | test_id |
|---|---|---|
| both healthy | `live=True, ready=True` | `[SUB] t_gsh_healthy` |
| live but not ready | `/readyz` returns 503 | `live=True, ready=False` (no exception) | `[SUB] t_gsh_live_not_ready` |
| studio down | `/healthz` connection refused | raises `StudioUnavailable` | `[SUB] t_gsh_down` |
| version drift | `api_contract="v0.0"` | returns; product checks via §10.8 | `[SUB] t_gsh_version_drift` |

---

## §8 Error model

### 8.1 Product-side sealed taxonomy (14 leaf classes)

Every Protocol method declares its full union of raisable exceptions. No bare `Exception`. No `OtherError`. Adding a leaf is a `studio-client` minor bump.

```python
# packages/studio-client/src/entelecheia_studio_client/errors.py

class StudioClientError(Exception):
    """Abstract base. Catch this at the product API boundary for fall-through logging."""

    studio_error_type:   str | None      # original studio §8.2 type string, when available
    retryable:           bool
    surfaces_verbatim:   bool            # whether `message` is safe to show users
    http_status:         int
    extras:              dict[str, object]


# transport / connectivity
class StudioUnavailable(StudioClientError):       """Network / 5xx / studio not reachable. Retryable."""
class StudioContractMismatch(StudioClientError):  """Studio is outside our pinned `>=0.1,<2.0` window."""

# input validation
class InvalidArgument(StudioClientError):         """Caller-side input rejected by studio (4xx of validation kind)."""

# not found (collapses studio's 9 NotFound variants)
class NotFound(StudioClientError):                """Resource doesn't exist or isn't visible. Studio sub-types in extras['studio_error_type']."""

# auth (v0.2 surface; placeholder leaves in v0.1)
class AuthRequired(StudioClientError):            """No / expired / invalid token (v0.2 only)."""
class PermissionDenied(StudioClientError):        """Token valid; lacks the required scope (v0.2 only)."""

# state / readiness
class MeetingNotReady(StudioClientError):         """get_meeting_outcome on a still-running meeting."""
class ConflictingState(StudioClientError):        """Lifecycle conflict (e.g. studio's SpecLifecycleError, RegistryLockError, EventLogConflictError)."""

# terminal
class PublishValidation(StudioClientError):       """Project not published / cross-reference failure (studio's PublishValidationError) — covers run_meeting refusal."""
class MeetingFailed(StudioClientError):           """Meeting died on studio side. Reason in extras."""

# rate / quota
class RateLimited(StudioClientError):             """LLMRateLimitError or similar; carries retry_after_seconds."""

# integrity (loud failure modes from studio)
class IntegrityError(StudioClientError):          """EventLogChainBrokenError and similar data-incident classes. ALWAYS alert."""

# stream-specific
class StreamUnavailable(StudioClientError):       """SSE connection failed or studio archive evicted the cursor."""

# unrecoverable / unknown
class StudioInternalError(StudioClientError):     """5xx from studio not otherwise classified. Includes EngineError, RuntimeError, SupervisorError, etc."""
```

### 8.2 Studio → product error mapping table (the translation HttpStudioClient owns)

This table is **the** source of truth for the translation layer (P7). Adding a row requires both a studio §8.2 type and a target product leaf; no row may end up at "unknown" because every studio type must map.

| Studio `error.type` (§8.2)              | Product leaf            | HTTP status (§8.1) | Notes                         |
|-----------------------------------------|-------------------------|-------------------:|-------------------------------|
| `SpecValidationError`                   | `InvalidArgument`       | 400                |                               |
| `SpecKindMismatchError`                 | `InvalidArgument`       | 400                |                               |
| `SchemaVersionMismatchError`            | `StudioContractMismatch`| 400                | escalate via §10.8            |
| `PublishValidationError`                | `PublishValidation`     | 400                | from `run_meeting` typically  |
| `SpecImmutabilityError`                 | `ConflictingState`      | 400                | only seen if admin path leaks |
| `SpecLifecycleError`                    | `ConflictingState`      | 409                |                               |
| `SpecNotFoundError`                     | `NotFound`              | 404                |                               |
| `VersionNotFoundError`                  | `NotFound`              | 404                |                               |
| `DraftNotFoundError`                    | `NotFound`              | 404                | admin path; should be unreachable from product |
| `DraftConflictError`                    | `ConflictingState`      | 409                | admin path                    |
| `RegistryStoreError`                    | `StudioInternalError`   | 500                |                               |
| `RegistryLockError`                     | `ConflictingState`      | 423                | extras: `timeout_seconds`     |
| `GitOperationError`                     | `StudioInternalError`   | 500                |                               |
| `SkillNotFoundError`                    | `NotFound`              | 404                |                               |
| `SkillManifestInvalidError`             | `InvalidArgument`       | 400                |                               |
| `SkillVersionMismatchError`             | `StudioContractMismatch`| 400                |                               |
| `SkillSecretMissingError`               | `StudioInternalError`   | 500                | studio op problem             |
| `SkillAlreadyInstalledError`            | `ConflictingState`      | 409                | admin path                    |
| `ToolImportError`                       | `StudioInternalError`   | 500                |                               |
| `ToolArgValidationError`                | `InvalidArgument`       | 400                |                               |
| `ToolExecutionError`                    | `StudioInternalError`   | 500                |                               |
| `ModelProviderNotFoundError`            | `NotFound`              | 404                |                               |
| `ModelNotFoundError`                    | `NotFound`              | 404                |                               |
| `LLMAuthError`                          | `StudioInternalError`   | 401                | studio's provider auth, not ours |
| `LLMRateLimitError`                     | `RateLimited`           | 429                | extras: `retries_attempted`, `retry_after_seconds` |
| `LLMTimeoutError`                       | `StudioInternalError`   | 504                |                               |
| `LLMRequestError`                       | `StudioInternalError`   | 502                |                               |
| `ParadigmNotFoundError`                 | `NotFound`              | 404                |                               |
| `ExtensionNotFoundError`                | `NotFound`              | 404                |                               |
| `ConfigStackingError`                   | `InvalidArgument`       | 400                |                               |
| `ParadigmCotError` and 9 sibling kinds  | `StudioInternalError`   | 500                | engine-side paradigm crashes  |
| `PlanParseError` / `PlaceholderResolutionError` | `StudioInternalError`| 500           |                               |
| `MaxIterationsReachedError`             | `StudioInternalError`   | 504                | extras: `iterations`, `tools_called_total` |
| `HumanInputTimeoutError`                | `StudioInternalError`   | 504                | v0.2 surface only             |
| `HumanInputClosedError`                 | `StudioInternalError`   | 500                | v0.2                          |
| `ToolDispatchTimeoutError`              | `StudioInternalError`   | 504                |                               |
| `LedgerStoreError` / `LedgerSchemaVersionError` | `StudioInternalError` | 500          |                               |
| `EventArchiverError` / `EventBusBindingError` | `StudioInternalError` | 500            |                               |
| `ApiError` / `ApiBootstrapError` / `ApiInvalidRequestError` | `InvalidArgument` if 4xx, else `StudioInternalError` | 400/500 | switch on status |
| `ApiMeetingNotFoundError`               | `NotFound`              | 404                | extras: `meeting_id`          |
| `ApiMeetingTaskFailedError`             | `MeetingFailed`         | 500                |                               |
| `EngineError`                           | `StudioInternalError`   | 500                |                               |
| `EventLogError`                         | `StudioInternalError`   | 500                |                               |
| `EventLogChainBrokenError`              | `IntegrityError`        | 500                | DATA INCIDENT — alert immediately; extras: `broken_at_event_id` |
| `EventLogBackendUnavailableError`       | `StudioUnavailable`     | 503                |                               |
| `EventLogConflictError`                 | `ConflictingState`      | 409                |                               |
| `AgentError` / `AgentTimeoutError` / `AgentInvalidOutputError` / `AgentRefusedError` | `StudioInternalError` | 500/504 |  |
| `DeliberationError` / `ConstraintViolationError` / `MalformedFactError` / `MalformedConsensusError` / `EvidenceReferenceError` | `StudioInternalError` | 422 | meeting died from studio's QA gates |
| `SupervisorError` / `PhaseTransitionError` / `HumanInterventionTimeoutError` | `StudioInternalError` | 500/504 |  |
| `ConfigError`                           | `InvalidArgument`       | 400                |                               |
| `InternalError`                         | `StudioInternalError`   | 500                |                               |
| (unrecognized type)                     | `StudioInternalError`   | actual status      | log full body + studio version |

**Why a 60→14 collapse, not 1:1.** Product code switching on 60 types becomes unmaintainable; the 14 leaves group by **how product handles it** (retry / surface to user / log integrity incident / reject input / route to login). The original `studio_error_type` is preserved in `extras` for diagnostics.
**Considered and rejected.** *1:1 mirror of studio's taxonomy* — tightly couples product to studio's churn; new studio leaves would mean product code edits.
*Single `StudioClientError` with `code: str`* — kills `match` exhaustiveness; one missed branch is silent.

---

## §9 `HttpStudioClient` — the translation layer (P7)

Module: `packages/studio-client/src/entelecheia_studio_client/http/__init__.py`. v0.1 ships a stub that raises `NotImplementedError("HttpStudioClient lands in v0.2; configure studio_mode='pseudo' for v0.1")` at construction time. v0.2 implements per the rules below; the rules themselves are stable from v0.1.

### 9.1 URL composition rules

| Protocol method            | studio HTTP                                                |
|----------------------------|------------------------------------------------------------|
| `list_projects`            | `GET  /v1/projects?status=&include_archived=&limit=&offset=` |
| `get_project(...,version=None)` | `GET  /v1/projects/{project_id}`                       |
| `get_project(...,version=v)`    | `GET  /v1/projects/{project_id}/{v}`                   |
| `list_agents`              | `GET  /v1/agents?...`                                       |
| `get_agent(...,version=None)`   | `GET  /v1/agents/{agent_id}`                            |
| `get_agent(...,version=v)`      | `GET  /v1/agents/{agent_id}/{v}`                        |
| `run_meeting`              | `POST /v1/projects/{project_id}/run` body `{version?, topic, materials, user_id}` |
| `list_meetings`            | `GET  /v1/meetings?project_id=&status=&since=&limit=&offset=` |
| `get_meeting_status`       | `GET  /v1/meetings/{meeting_id}`                            |
| `subscribe_meeting`        | `GET  /v1/meetings/{meeting_id}/events` headers `{Accept: text/event-stream, Last-Event-Id?: <int>}` |
| `get_meeting_outcome`      | `GET  /v1/meetings/{meeting_id}/outcome`                    |
| `get_cost_report`          | `GET  /v1/cost/report?project_id=&...&group_by=p,m,...`     |
| `get_studio_health`        | concurrent `GET /healthz` + `GET /readyz` + `GET /v1/version` |

### 9.2 SSE translation rules — see §6.4.

### 9.3 `Last-Event-Id` reconnect

When `subscribe_meeting(last_event_id=N)` is called, HttpStudioClient sends `Last-Event-Id: N` as a request header (studio §6.3). Studio resumes from event `N+1`. If the cursor is too far in the past and studio's archive has rotated, studio responds with an empty stream and immediate close; HttpStudioClient re-raises as `StreamUnavailable` so the caller can refresh from outcome / status instead.

### 9.4 Auth (v0.1 / v0.2)

- **v0.1**: studio §10.1 — no auth. HttpStudioClient sends no `Authorization` header. Localhost binding (default `127.0.0.1:8000`) is the network-level boundary.
- **v0.2**: studio §10.2 introduces `Authorization: Bearer <token>`. HttpStudioClient accepts an `auth_token_provider: Callable[[], Awaitable[str]]` injectable; sandwich layer `AuthRefreshLayer` wraps refresh logic. Token is product's `auth-service` JWT, NOT a studio token (subject to revisit when studio's identity package documents the bridge).
- Migration path: bumping `studio-client` minor adds the auth surface as opt-in; existing callers continue to work.

### 9.5 Sandwich-layer middleware contract

```python
class SandwichLayer(Protocol):
    async def around_call(
        self,
        *,
        method_name: str,
        kwargs:      dict[str, object],
        next_:       "Callable[..., Awaitable[object]]",
    ) -> object: ...
```

v0.2 layers planned: `AuthRefreshLayer`, `RetryLayer` (5xx + `Retry-After` per studio §9.6), `ObservabilityLayer` (request-id, latency histograms). Each is one file under `packages/studio-client/src/entelecheia_studio_client/http/middleware/`.

### 9.6 Configuration

```python
class HttpStudioClientConfig(BaseModel):
    base_url:               str                    # e.g. "http://localhost:8000" — studio §3.1 default
    auth_token_provider:    "Callable[[], Awaitable[str]] | None" = None    # v0.2
    request_timeout_s:      float = 30.0
    stream_timeout_s:       float = 0.0            # 0 = unlimited; meetings are 30s..180min per studio §9.1
    max_inflight_requests:  int   = 32
    sandwich_layers:        list[SandwichLayer] = []
```

---

## §10 `PseudoStudioClient` v0.1

Module: `packages/studio-client/src/entelecheia_studio_client/pseudo/__init__.py`. **v0.1 production default** — used by feature development, demos, and substitution tests until `HttpStudioClient` lands.

### 10.1 Constructor

```python
class PseudoStudioClient(StudioClient):
    def __init__(
        self,
        *,
        fixture_set:        str = "default",       # selects an overlay directory
        time_acceleration:  float = 1.0,           # 1.0 = realistic; 100.0 = tests
        random_seed:        int | None = None,     # for jitter determinism
        clock:              "Clock | None" = None, # injected for tests; default = wall clock
    ) -> None: ...
```

### 10.2 Fixture directory layout

```
packages/studio-client/fixtures/
├── default/                               # required
│   ├── projects.yaml                      # ProjectSpec entries
│   ├── agents.yaml                        # AgentSpec entries
│   ├── meeting_templates.yaml             # event scripts (see 10.3)
│   ├── outcomes.yaml                      # MeetingOutcome per template
│   ├── cost_reports.yaml                  # canned CostReport per scope filter
│   └── health.yaml                        # studio_version, engine_version, api_contract
└── <vertical_id>/                         # optional overlay; only present files override default/
    ├── projects.yaml
    └── outcomes.yaml
```

### 10.3 Fixture file schemas (excerpts)

```yaml
# projects.yaml — entries are ProjectSpec instances per §4.3
- spec_kind: project
  schema_version: v0.1
  spec_id: alpha-deliberation
  version: 1
  status: published
  created_at: "2026-01-01T00:00:00Z"
  updated_at: "2026-04-15T00:00:00Z"
  created_by: alice
  description: General-purpose multi-agent deliberation
  agents:
    - {agent_id: "agent-architect", version: 1, enabled: true}
    - {agent_id: "agent-critic",    version: 1, enabled: true}
  engine_extensions:
    conclude_predicates:
      - {type: "builtin.max_turns", params: {max_turns: 20}}
    constraints: []
    speaker_selector: {type: "builtin.round_robin", params: {}}
    phase_machine:    {type: "builtin.linear", params: {phases: ["explore","converge","conclude"]}}
  meeting_defaults: {max_turns: 20, language: en}
  skill_overrides: {}
```

```yaml
# meeting_templates.yaml — match rules + event script (the SSE replay)
- template_id: tmpl_default
  match_rule:                              # used by run_meeting to pick the script
    project_id_in: ["alpha-deliberation"]
    topic_keywords_any_of: ["*"]           # "*" matches any topic
  initial_status: running
  events:                                  # replayed in order; event_id assigned monotonically
    - {at_offset_ms: 0,    event_type: MeetingStarted,   data: {paradigm: cot}}
    - {at_offset_ms: 200,  event_type: RootQuestionPosed, data: {question: "<topic>"}}
    - {at_offset_ms: 1500, event_type: ClaimMade, data: {claim_id: c1, asserted_by: agent-architect, content: "..."}}
    - {at_offset_ms: 3000, event_type: ChallengeRaised, data: {claim_id: c1, by: agent-critic, content: "..."}}
    - {at_offset_ms: 5000, event_type: ConsensusReached, data: {claim_ids: [c1], confidence: 0.7}}
    - {at_offset_ms: 6000, event_type: MeetingFrozen,  data: {}}
    - {at_offset_ms: 6100, event_type: meeting_finalized, data: {outcome_ref: tmpl_default}}
  # outcome_ref points to outcomes.yaml entry; pseudo materializes it at finalization

- template_id: tmpl_failing
  match_rule: {topic_keywords_any_of: ["fail"]}
  initial_status: running
  events:
    - {at_offset_ms: 0,    event_type: MeetingStarted, data: {}}
    - {at_offset_ms: 2000, event_type: meeting_failed,  data: {error: {type: ApiMeetingTaskFailedError, message: "Synthetic failure"}}}
```

```yaml
# outcomes.yaml — referenced from meeting_templates.events[].data.outcome_ref
- outcome_ref: tmpl_default
  outcome:
    meeting_id: "<runtime>"                # filled by pseudo at finalization
    concluded_by: consensus_reached
    consensus:        [{claim_id: c1, content: "...", confidence: 0.7}]
    unresolved_disagreements: []
    key_facts:        []
    open_questions:   []
    started_at:       "<runtime>"
    concluded_at:     "<runtime>"
    total_turns:      4
    final_constraints_status: []
    merkle_root:      "0000000000000000000000000000000000000000000000000000000000000000"
```

### 10.4 Time simulation rules

- Events scheduled by `at_offset_ms / time_acceleration`.
- Maximum sleep between consecutive yields is **200 ms** after acceleration; longer waits are chunked to keep cancellation responsive.
- `event_id` is assigned monotonically starting at 1 (matching studio §6.1's 1-indexed JSONL line numbers).
- Wall-clock fields (`at_timestamp` if emitted) are computed as `meeting_started_at + at_offset_ms`, NOT `now()`, so fixture replays are deterministic.
- Jitter (±10% of inter-event gap) applied iff `random_seed is not None`.

### 10.5 Error injection rules

- **Synchronous**: a fixture entry can omit a `spec_id` to make `get_*` return `NotFound`. Special `studio_down` fixture overlay forces every method to raise `StudioUnavailable`.
- **Stream**: a `meeting_template` whose event script terminates with `meeting_failed` produces the documented error envelope (mapped to `MeetingFailed` if the consumer subscribes).
- **Per-method**: `permissions.yaml` (when v0.2 auth lands) will declare per-user denials; v0.1 has no auth so this file is empty.
- **Validation**: at constructor time, every `event_type` in fixtures is validated against the frozen 26-list (P6: pseudo is faithful, not free-form). Unknown types are rejected with a constructor error.

### 10.6 In-memory state machine

```python
@dataclass
class _MeetingState:
    handle:          MeetingHandle
    template_id:     str
    next_event_id:   int                          # monotonic; starts at 1
    status:          Literal["running", "completed", "failed"]
    events_emitted:  list[MeetingEvent]           # for replay on reconnect via Last-Event-Id
    outcome:         OutcomeResponse | None       # set when status transitions to completed/failed
```

The simulator holds `dict[MeetingId, _MeetingState]`. Two concurrent `subscribe_meeting` consumers see identical sequences (per-meeting monotonic).

### 10.7 Invariants (tied to substitution tests)

- I1 — `subscribe_meeting(meeting_id, last_event_id=N)` never re-yields events with `event_id <= N`.
- I2 — Reconnect after disconnect yields events with strictly greater `event_id`s.
- I3 — Iterator terminates after `meeting_finalized` OR `meeting_failed`, never both.
- I4 — Two concurrent subscribers see byte-identical sequences.
- I5 — `get_meeting_outcome` returns `OutcomeResponse{outcome: ...}` only when status is `completed`; raises `MeetingNotReady` while running; returns `OutcomeResponse{outcome: None, error: ...}` for failed (per studio §5.1).
- I6 — `time_acceleration <= 0` raises `InvalidArgument` at construction.

**Why YAML for fixtures.** Comments + multiline strings + anchors; humans hand-author and read; PR diffs reviewable.
*Considered and rejected.* **JSON** — no comments. **Python modules** — invites dynamic mocks (P6 violation: fixtures are data, not code).

**Why fixture-validated event types.** Catches typos at constructor time, not at subscribe time. Pseudo is a faithful Protocol implementation (Red Line #7); a `RuntimeWarning` type would silently grow the surface.

**Why declarative error injection.** Replayable + version-controlled + visible in PR diffs. An imperative `set_next_error` API would let consumers know they're talking to pseudo (P6 violation).

---

## §11 Known studio v0.1 limitations + product-side derivations

This section documents capabilities that **product needs but studio v0.1 does not provide**. Each is either (a) deferred to a request for studio v0.2+, or (b) explicitly product-derived (computed product-side from studio's raw event stream + outcome shape).

### 11.1 No pause / resume / stop meeting endpoint (deferred)

Studio §3.6 has no endpoints for these; studio §6.2 has events `MeetingPaused` / `MeetingResumed` / `MeetingFrozen` but no user-callable triggers. Until studio v0.2 adds endpoints (tracked in `docs/migration-log.md` as "Studio v0.2 requests"), product cannot expose a "Stop meeting" button in agora. Workaround: meetings naturally terminate via `concluded_by="max_turns"` or `"deadline"`; users may close their browser tab — the meeting continues running on studio and the outcome is fetchable later.

### 11.2 No inject-human-input endpoint (deferred)

Studio §6 has the `UserInjected` event but no HTTP endpoint to trigger it. Product's wizard / agora cannot mid-meeting inject user notes in v0.1. Same disposition: deferred to studio v0.2 request.

### 11.3 No `render_outcome_report` (PRODUCT-SIDE)

Studio does not render reports. Product's `reports` feature (Batch C, spec `06`) is the renderer: input `OutcomeResponse` → output PDF / Word / Excel / Markdown. Templates are configurable per vertical (vertical can ship report templates).

### 11.4 No `labels` on `ProjectSpec` (PRODUCT-SIDE filtering)

Studio §4.2 ProjectSpec has no labels / tags / category field. **Per-vertical project filtering is product-side**:

- Each vertical manifest declares `default_project_filter: { project_id_in: list[ProjectId] }` — an explicit allowlist of `spec_id`s the vertical "owns."
- `useActiveVertical` composable reads the manifest and applies the filter on top of `list_projects()` results.
- This replaces the original `labels_any_of: list[str]` design (which assumed studio support).
- Tracked as a v0.1.5+ studio request: "add `labels: list[str]` to ProjectSpec for declarative vertical scoping."

### 11.5 No `get_provenance` (PRODUCT-SIDE derivation)

Studio §6 emits `EvidenceCited` events; studio §5.1 `MeetingOutcome.key_facts` has facts with their evidence references. Product's `useProvenance(claim_id)` composable in agora reduces these into a trace. Specs in `01b-product-derivations-spec.md` (next deliverable).

### 11.6 No `get_dag_view` / `DagMutated` events (PRODUCT-SIDE)

Studio does not expose a DAG. Product builds it from `ClaimMade` + `ChallengeRaised` + `EvidenceCited` + `TriggerDefined` + `ContradictionFound` + `ConsensusReached` events. Lives in agora's `useDagState` composable. Specs in `01b-product-derivations-spec.md`.

### 11.7 No `WorkingOutcome` (PRODUCT-SIDE)

Studio only finalizes `MeetingOutcome` at meeting end. Product's "working consensus" view in agora is reduced product-side from streaming `ClaimMade` / `ChallengeRaised` / `ConsensusReached` events. Lives in agora's `useOutcomeReducer`. Specs in `01b-product-derivations-spec.md`.

### 11.8 No `get_knowledge_tree` (REDEFINED)

The "knowledge tree" envisioned in design doc 04 is operationally **past meetings + their outcomes** for v0.1. Knowledge feature (spec `07`) calls `list_meetings` + `get_meeting_outcome`, builds a tree-view client-side. No separate API call. Studio may add an explicit knowledge graph in a future release; not a v0.1 dependency.

### 11.9 No `MeetingMetrics` (PRODUCT-SIDE)

Derived from `get_cost_report(meeting_id=m)` + counting `MessageEmitted` / `ToolCalled` events from the event archive (or from `total_turns` in the outcome). Lives in observability feature (spec `12`).

### 11.10 No spec authoring (OUT OF SCOPE per P1)

Studio §3.4 / §3.5 expose draft / publish / archive / draft-from for agents and projects. Per **P1** these are NOT part of the v0.1 product `StudioClient` Protocol. If a "studio admin vertical" is built in the future, it will use a separate `StudioAdminClient` Protocol that wraps these endpoints; the read-side Protocol defined here remains unchanged.

---

## §12 Substitution test matrix

Substitution tests live at `packages/studio-client/tests/substitution/` and run identical bodies against both implementations:

```python
@pytest.fixture(params=["pseudo", pytest.param("http", marks=pytest.mark.skipif(condition='v0.1', reason='HttpStudioClient lands v0.2'))])
def studio(request) -> StudioClient: ...
```

In v0.1 only `pseudo` is exercised; v0.2 enables `http` against a recorded fixture of real studio responses. All `[SUB]`-marked tests in §7 run under both.

| # | Category                          | What it validates                                                          | Tests covered                                  |
|---|-----------------------------------|----------------------------------------------------------------------------|------------------------------------------------|
| 1 | DTO round-trip                    | Each DTO serializes → wire shape (matches studio §4 / §5 byte-for-byte) → deserializes to equal value | one test per DTO type                |
| 2 | Method behavior parity            | Every `[SUB]` test_id passes identically                                   | every `[SUB]` row in §7                        |
| 3 | SSE stream parity                 | All 24 EventTypes + `meeting_finalized` + `meeting_failed` parse and yield correctly; heartbeats stripped; unknown types forward-compat | `t_sm_*` + the SSE wire-format tests |
| 4 | Error parity (60→14)              | Each studio §8.2 type maps to the documented product leaf                  | one test per studio error type (60+ rows in §8.2 mapping table) |
| 5 | Reconnect / cursor parity         | `Last-Event-Id` reconnect yields events with strictly greater `event_id`s, no dup, no skip; archive-eviction raises `StreamUnavailable` | `t_sm_reconnect_*` |

Naming convention: `tests/substitution/test_<surface>__<scenario>.py`; test_ids match the §7 tables exactly so a failure points at this spec.

**Definition of "passes identically."** Same return type; same field values for deterministic fields; same exception leaf class. Wall-clock fields and request/response timing are compared with tolerance.

---

## §13 Pinning, drift detection, deprecation handling

### 13.1 Pinning

`packages/studio-client/pyproject.toml` pins:

```toml
[project]
dependencies = [
  # studio's binding contract is `>=0.1,<2.0`; we follow exactly.
  "entelecheia-studio-api >=0.1,<2.0",   # the http-callable surface lives upstream; we don't import it
]
```

Note: product **does not** import any studio Python modules at runtime. The pin is for CI/local-dev convenience (running pseudo's substitute tests against a recorded studio response set).

### 13.2 Drift detection

The substitution-tests spec (`17`) implements studio §12's CI compatibility self-test against a live or recorded studio:

- Required-routes check: every `[SUB]` test_id touching a real endpoint expects the documented status.
- Schema field check: required fields per §4 / §5 must be present on responses.
- EventType check: every yielded `event_type` must be in the frozen 26 OR new (forward-compat).

Failures here mean either (a) studio shipped a breaking change (escalate immediately — should be impossible inside `>=0.1,<2.0`), or (b) studio shipped an additive change we should ingest.

### 13.3 Deprecation handling (studio §11)

If studio deprecates an endpoint or field before v2.0:

1. studio's response carries `Deprecation: true` + `Sunset: <ISO-date>` headers.
2. HttpStudioClient's `ObservabilityLayer` (v0.2) logs the deprecation at WARNING.
3. Engineering opens a migration task with > 4 weeks lead time before studio v2.0.
4. The product spec for the affected feature documents the migration; this spec is updated to reflect the new endpoint when the migration ships.

---

## §14 i18n

This package produces no user-visible strings. Errors carry English `message` for logging plus `studio_error_type` (the original studio §8.2 type string preserved in `extras`); the product API layer maps them to localized UI strings in `packages/platform-shell/i18n/`. Studio-side localized content (e.g. `paradigm.type` display labels) is out of this module's scope.

---

## §15 Downstream impact — adjustments to upcoming Batch B–F specs

Every later spec depends on this contract. The following are the concrete adjustments each subsequent spec must absorb (specs themselves will detail; this is the routing).

### Batch B

- **02 platform-shell**: `useStudio()` composable returns the configured `StudioClient`. `useStudioHealth()` polls `get_studio_health` periodically (default 30 s) for a status indicator.
- **03 auth-service**: studio v0.1 has no auth; product's auth-service handles JWT. `user_id` passed to `run_meeting` is product's auth-service user identifier (free-form; studio §4.1 just stores it).
- **04 user-service**: unaffected.

### Batch C

- **05 agora**: heaviest impact. The 24 EventType stream + product-side reducers replace the previous custom event union.
  - `useMeetingStream(meeting_id)` → wraps `subscribe_meeting`; keeps `last_event_id` for reconnect.
  - `useDagState`: reduces `ClaimMade / ChallengeRaised / EvidenceCited / TriggerDefined / ContradictionFound / ConsensusReached` into nodes/edges (PRODUCT-DERIVED).
  - `useOutcomeReducer`: reduces `ClaimMade / ChallengeRaised / ConsensusReached` into a working consensus view (PRODUCT-DERIVED).
  - `useCostState(meeting_id)`: counts `MessageEmitted / ToolCalled` for live-tally; also queries `get_cost_report(meeting_id=m)` for authoritative numbers.
  - `useProvenance(claim_id)`: builds trace from `EvidenceCited` events + `MeetingOutcome.key_facts` (PRODUCT-DERIVED).
  - **No "Stop meeting" button** in v0.1 (§11.1).
  - **No human-input injection** in v0.1 (§11.2).
  - All derivation specs live in `01b-product-derivations-spec.md` (next deliverable).
- **06 reports**: renderer is product-side (§11.3). Inputs: `OutcomeResponse` from `get_meeting_outcome`. Output formats: PDF / Word / Excel / Markdown. Templates per vertical.
- **07 knowledge**: implemented as `list_meetings` + `get_meeting_outcome` browser; tree-view client-side (§11.8).
- **08 chathub**: implemented as a single-agent `ProjectSpec` (one `AgentMemberRef` + a low-friction paradigm like `react`); `run_meeting` per chat turn or per session — design choice deferred to that spec.
- **09 uploads**: buffers files product-side; reads bytes at `run_meeting` time and passes inline as `Material` (no upload registration in studio §3.6).
- **10 wizard**: orchestrates project pick (`list_projects` + vertical filter) → topic input → materials attach → `run_meeting`. Hands off to agora.
- **11 settings**: unaffected by studio.
- **12 observability**: dashboards from `get_cost_report` (multi-`group_by`) + meeting counts via `list_meetings`.

### Batch D

- **13 vertical-template**: frontend manifest's `default_project_filter` shape changes to `{ project_id_in: list[ProjectId] }` (was `labels_any_of: list[str]`); see §11.4.
- **14 first concrete vertical pack**: declares `project_id_in` allowlist for the project specs the vertical supports; vertical's fixture overlay (PseudoStudioClient) adds matching `ProjectSpec` entries. (Vertical-specific naming lives in that spec, not in this neutral contract.)

### Batch E

- **15 apps/api**: FastAPI app with vertical entry-point discovery; `StudioClient` injected from env-driven config (`studio_mode = pseudo | http`). `apps/api/agora_proxy.py` does ASGI passthrough of `/v1/meetings/{id}/events` SSE — no event re-encoding.
- **16 apps/frontend**: SSE consumed via browser-native `EventSource`; TS DTO mirrors at `apps/frontend/src/types/studio-client/`.

### Batch F

- **17 substitution-tests**: must additionally cover SSE → AsyncIterator translation, every `Last-Event-Id` reconnect path, and every row in §8.2's 60→14 error mapping table.
- **18 e2e scenarios**: 7 e2e flows now consume the studio-aligned API: login → vertical pick → wizard → `run_meeting` → agora SSE → outcome → report render → knowledge browse → new chat.

---

## §16 Why this design — consolidated load-bearing decisions

**Why mirror studio's frozen schemas verbatim instead of remapping field names.**
Frozen contract; remapping creates two sources of truth and invites drift. The cost (slightly less Pythonic field names like `concluded_by` over `terminated_because`) is borne in one place (`packages/studio-client/`); product feature code reads through TS / Python types unchanged.
*Considered and rejected.* **Pythonic remapping** — every renamed field is a future migration task when studio adds optional fields with new names.

**Why a smaller (11-method) Protocol than the 30-route studio surface.**
Per **P1**, the v0.1 product is end-user UI. Spec authoring (admin), skill installation (admin), introspection of paradigms / models / extensions (admin) are NOT end-user features. The Protocol is bounded to what end-user features actually need.
*Considered and rejected.* **Wrap all 30 routes** — bloats the substitution-test surface; invites accidental admin-path use in features.

**Why `dict[str, object]` for `MeetingEvent.data`.**
Engine's payload schemas are declared frozen by studio §6.2 but live in engine's contract, which we have not yet mirrored. Typed accessors (TypedDict) are provided for the 5 events product reduces; the rest are accessed by key. v0.2 imports engine's contract and tightens to a discriminated union.
*Considered and rejected.* **Type each of 24 payloads now** — premature; we don't have engine's contract pinned in this repo.

**Why a 60→14 error collapse.**
Product code switching on 60 types becomes unmaintainable. Grouping by **how product handles** the failure (retry vs surface vs alert vs reject) gives 14 leaves. Original `studio_error_type` preserved in `extras` for diagnostics.
*Considered and rejected.* **1:1 mirror of studio's 60-type taxonomy** — tight coupling to studio's churn.

**Why `Material` is inline, not registered.**
Studio §3.6 takes inline `{kind, name, content}` at meeting-start; there is no upload-registration endpoint. Product's uploads feature buffers files, reads bytes, inlines.
*Considered and rejected.* **Pre-register materials and pass IDs** — studio doesn't support; would force a fictional API.

**Why "v0.2 deferred" capabilities are NOT in the Protocol (option 1A).**
Putting `pause_meeting` etc. in the Protocol as "raises NotImplementedError under HttpStudioClient" lets product UI code call methods that won't actually work in production. Cleaner to keep the Protocol honest and document the gap (§11). When studio adds the endpoints, we add the methods.
*Considered and rejected.* **v0.2 stub methods (option 1B)** — UX pretence; high risk of shipping non-functional buttons.

**Why spec authoring is OUT (option 2A).**
Per **P1**: agent / project / skill authoring is studio-admin work, not end-user product. The "studio admin vertical" use case (if it materializes) gets its own `StudioAdminClient`.
*Considered and rejected.* **Minimal admin surface (option 2B)** — slippery slope; the moment we add `archive_*`, the next request is `publish_*`, then `save_draft_*`, until product is duplicating studio's admin UI.

**Why product-side derivations (working outcome, DAG, provenance, knowledge tree) are documented in this spec.**
Anyone reading `01-studio-client-spec.md` has the full picture: what studio gives us, what product derives, where each derivation lives. Spec `01b-product-derivations-spec.md` (next deliverable) details the reducers; this spec is the index.
*Considered and rejected.* **Defer all derivation context to feature specs** — readers of the studio-client spec wouldn't know which UI features depend on which event types until reading 4 more specs.

---

## §17 Pre-merge checklist

- [ ] Mission + Scope present; "out of scope for v0.1" listed (incl. v0.2 deferrals)
- [ ] Upstream contract anchor table (§2) cites every studio §3–§9 section the spec depends on
- [ ] Identifier types match studio §3.1 format constraints (slug, hex, monotonic int, line-number int)
- [ ] All cross-boundary DTOs mirror studio §4 / §5 frozen schemas field-for-field
- [ ] `MeetingEvent` lists all 26 frozen `event_type` literals (24 EventType + 2 studio-injected)
- [ ] Product-side error taxonomy: 1 base + 14 leaves; every leaf declares retryable / surfaces_verbatim / http_status
- [ ] **§8.2 60→14 mapping table** covers every studio §8.2 type string with a target leaf
- [ ] All 11 Protocol methods defined with full async signatures, semantics, raises, and test matrix
- [ ] Each method's test matrix marks `[SUB]` for substitution-eligible rows
- [ ] HttpStudioClient §9 documents URL composition, SSE translation, `Last-Event-Id` reconnect, auth deferral, sandwich-layer contract
- [ ] PseudoStudioClient §10 enumerates fixture layout, all schemas, time / error injection, state machine, 6 invariants
- [ ] §11 enumerates every studio v0.1 limitation product needs (deferred or product-derived); links to derivation spec
- [ ] §12 substitution test matrix names all 5 categories
- [ ] §13 pinning + drift detection + deprecation handling tied to studio §11 / §12
- [ ] §15 downstream impact lists every Batch B–F spec's adjustment
- [ ] No business / domain / product / agent-role string literal anywhere in the spec (only neutral placeholders like `agent-architect`, `alpha-deliberation`)
- [ ] No `from entelecheia` / `import entelecheia` anywhere
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/01-studio-client-spec.md`
- [ ] Supersedes notice at top points to the previous commit (`d0b7699`)
