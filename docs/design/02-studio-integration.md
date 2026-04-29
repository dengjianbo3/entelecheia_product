# Studio Integration — the Pseudo Client Now, Real Client Later

How product talks to studio: what the contract is, why it's pseudo for v0.1, how the swap to real works, and where the future translation layer lives.

---

## Why this is the most important abstraction

The `StudioClient` Protocol is the single boundary between product and the rest of the Entelecheia stack. If it's clean, product can develop independently of studio's actual API timing; if it's polluted, every feature couples to whatever studio happens to ship today.

Every platform feature and vertical pack depends on this Protocol. Get it right and the product is portable across studio versions; get it wrong and we'll spend the rest of v1.0 fighting integration drift.

---

## The Protocol

`packages/studio-client/src/entelecheia_studio_client/protocol.py`:

```python
from typing import Protocol, AsyncIterator
from datetime import datetime

# (All types defined in this package; mirror in TypeScript for frontend)

class StudioClient(Protocol):
    """
    The full surface for product → studio communication.
    Product code depends on this Protocol; never on a concrete implementation.

    All methods are async. All errors are typed exceptions in
    entelecheia_studio_client.errors.
    """

    # ── Project + Agent discovery ────────────────────────────────────
    async def list_available_projects(
        self,
        user_id: str,
        vertical_id: str | None = None,
        labels_any_of: list[str] | None = None,
    ) -> list[ProjectSummary]: ...

    async def get_project(self, project_id: str, version: int | None = None) -> ProjectSummary: ...

    async def list_available_agents(
        self,
        user_id: str,
        role_tags_any_of: list[str] | None = None,
    ) -> list[AgentSummary]: ...

    # ── Meeting lifecycle ────────────────────────────────────────────
    async def run_meeting(
        self,
        project_id: str,
        topic: str,
        materials: list[Material],
        user_id: str,
        config: MeetingRunConfig | None = None,
    ) -> MeetingHandle: ...

    async def get_meeting_outcome(self, meeting_id: str) -> MeetingOutcome: ...

    async def list_meetings(
        self,
        user_id: str | None = None,
        project_id: str | None = None,
        status: MeetingStatus | None = None,
        limit: int = 50,
    ) -> list[MeetingSummary]: ...

    async def pause_meeting(self, meeting_id: str) -> None: ...
    async def resume_meeting(self, meeting_id: str) -> None: ...
    async def stop_meeting(self, meeting_id: str, reason: str) -> None: ...

    async def inject_human_input(
        self, meeting_id: str, content: str, author_user_id: str,
    ) -> None: ...

    # ── Live event subscription ──────────────────────────────────────
    async def subscribe_meeting(
        self, meeting_id: str,
    ) -> AsyncIterator[MeetingEvent]: ...

    # ── Read-only views (replaces direct engine imports) ─────────────
    async def get_dag_view(
        self, meeting_id: str, *, at_clock: int | None = None,
    ) -> DagViewSnapshot: ...

    async def get_provenance(
        self, meeting_id: str, claim_id: str,
    ) -> ProvenanceTrace: ...

    async def get_knowledge_tree(self, tree_id: str) -> KnowledgeTreeSnapshot: ...

    async def subscribe_knowledge_tree_events(
        self, tree_id: str,
    ) -> AsyncIterator[KnowledgeTreeEvent]: ...

    # ── Cost + observability ─────────────────────────────────────────
    async def get_cost_aggregate(
        self,
        *,
        project_id: str | None = None,
        user_id: str | None = None,
        vertical_id: str | None = None,
        from_date: datetime | None = None,
        to_date: datetime | None = None,
    ) -> CostReport: ...

    async def get_meeting_metrics(
        self, meeting_id: str,
    ) -> MeetingMetrics: ...

    # ── Exports / reports ────────────────────────────────────────────
    async def render_outcome_report(
        self,
        meeting_id: str,
        format: ReportFormat,    # "pdf" | "word" | "excel" | "markdown"
        template_id: str | None = None,
    ) -> ReportArtifact: ...
```

This is **~16 methods**. The exact set is finalized during v0.1 plan-creation; deferred per the v2 spec § "open questions" pattern.

### Naming convention

- `list_*` returns multiple records
- `get_*` returns one record
- `run_*` / `*_meeting` mutate or trigger
- `subscribe_*` returns AsyncIterator (event stream)
- `render_*` produces an artifact (binary or large doc)

---

## v0.1 — `PseudoStudioClient`

```python
# packages/studio-client/src/entelecheia_studio_client/pseudo.py

class PseudoStudioClient:
    """
    Realistic mock implementation of StudioClient.

    Backed by YAML/JSON fixtures in packages/studio-client/fixtures/.
    Designed so that product UI development can proceed without studio
    existing. Fixtures cover all major UI states (loading, success,
    partial-completion, error).
    """

    def __init__(self, fixture_set: str = "default"):
        self._fixtures = load_fixtures(fixture_set)

    async def list_available_projects(self, user_id, vertical_id=None, labels_any_of=None):
        projects = self._fixtures.projects
        if vertical_id:
            projects = [p for p in projects if vertical_id in p.labels]
        if labels_any_of:
            projects = [p for p in projects if any(l in p.labels for l in labels_any_of)]
        # Simulate latency for realism
        await asyncio.sleep(0.05)
        return projects

    async def run_meeting(self, project_id, topic, materials, user_id, config=None):
        meeting_id = f"meeting-mock-{uuid4()}"
        # Spawn a background task that emits realistic events
        # over ~30 seconds, simulating an agora session
        asyncio.create_task(self._simulate_meeting(meeting_id, project_id, topic))
        return MeetingHandle(meeting_id=meeting_id, started_at=now_iso())

    async def subscribe_meeting(self, meeting_id):
        # Yield mock events from the simulator at realistic timing
        async for event in self._meeting_simulators[meeting_id].events():
            yield event

    # ... rest of the methods, all backed by fixture data + realistic simulation
```

**Fixture organization:**

```
packages/studio-client/fixtures/
├── default/
│   ├── projects.yaml         # 5-10 mock ProjectSummary
│   ├── agents.yaml           # 10-20 mock AgentSummary
│   ├── meeting-templates.yaml # 3-5 templates the simulator uses
│   ├── outcomes.yaml         # 3-5 pre-rendered MeetingOutcomes
│   ├── dag-snapshots.yaml    # Sample DAG views
│   ├── provenance.yaml       # Sample provenance traces
│   ├── cost-aggregates.yaml  # Sample CostReports
│   └── trees.yaml            # Sample knowledge trees
└── investment/                # Vertical-specific fixture overlay
    ├── projects.yaml          # Override with investment-flavored projects
    └── agents.yaml
```

The `fixture_set` parameter selects which overlay applies. Verticals can ship their own fixture sets that override default ones.

### Mock event simulation

The most complex pseudo behavior is `subscribe_meeting()` — it must emit realistic event streams that look like a real agora session. The simulator:

1. Loads a meeting template (number of agents, event timeline)
2. Schedules events at realistic intervals (e.g., every 2-5 seconds)
3. Emits the canonical event types from the engine's vocabulary (MessageEmitted, ClaimMade, EvidenceCited, ChallengeRaised, ConsensusReached, MeetingFrozen)
4. Generates synthetic content via templates

This lets the entire agora UI develop against believable data: live message threading, evidence sidebar updates, DAG growing in real-time, conclude state transitions.

### What's NOT in pseudo

The pseudo client never:
- Crashes randomly (real client might; pseudo simulates errors only on demand via `raise_on_call=`)
- Returns malformed data (always passes Protocol type validation)
- Has surprising latency (uses bounded sleeps; configurable)
- Persists state (next process start = fresh fixtures; no leakage)

This is intentional. Pseudo's job is to give consumers a clean, predictable surface that exercises every code path.

---

## v0.2+ — `HttpStudioClient`

When studio v0.1 ships and exposes its API, we add:

```python
# packages/studio-client/src/entelecheia_studio_client/http.py

class HttpStudioClient:
    """
    Real HTTP/WebSocket implementation. Drop-in replacement for PseudoStudioClient.
    """
    def __init__(
        self,
        base_url: str,
        token: str,
        timeout_s: float = 30.0,
        retry_policy: RetryPolicy = DEFAULT_RETRY_POLICY,
    ): ...

    async def list_available_projects(self, user_id, vertical_id=None, labels_any_of=None):
        params = {"user_id": user_id}
        if vertical_id: params["vertical_id"] = vertical_id
        if labels_any_of: params["labels_any_of"] = labels_any_of
        resp = await self._http.get(f"{self.base_url}/api/projects", params=params)
        return [ProjectSummary.model_validate(item) for item in resp.json()]

    # ... 15 more methods, all calling studio's real API
```

The swap is one configuration line:

```python
# apps/api/main.py
def get_studio_client() -> StudioClient:
    if settings.studio_mode == "pseudo":
        return PseudoStudioClient(fixture_set=settings.fixture_set)
    elif settings.studio_mode == "http":
        return HttpStudioClient(
            base_url=settings.studio_base_url,
            token=settings.studio_token,
        )
    else:
        raise ConfigError(f"unknown studio_mode: {settings.studio_mode}")
```

UI / feature / vertical code is **unchanged**.

---

## The translation layer

If studio's real API doesn't match the Protocol exactly, we have three options:

### Option A — Update the Protocol

If studio's shape is genuinely better, update `StudioClient` Protocol + `PseudoStudioClient` + UI consumers. Single source-of-truth migration.

### Option B — Translate inside `HttpStudioClient`

If studio has minor differences (different endpoint paths, different field names, different paging conventions) but the same conceptual shape, translate inside `HttpStudioClient`. The Protocol stays clean; UI doesn't change.

```python
async def list_available_projects(self, user_id, vertical_id=None, labels_any_of=None):
    # Studio's API uses "tag" instead of "label"; translate
    params = {"user": user_id}
    if vertical_id:
        params["tag"] = f"vertical:{vertical_id}"
    if labels_any_of:
        params["any_of_tags"] = ",".join(f"label:{l}" for l in labels_any_of)
    resp = await self._http.get(f"{self.base_url}/api/v1/agent-bundles", params=params)
    # Translate studio's "AgentBundle" → product's "ProjectSummary"
    return [_translate_agent_bundle_to_project_summary(item) for item in resp.json()]
```

### Option C — Insert a sandwich layer

If translations are cross-cutting (e.g., authentication, retries, observability), put them in a sandwich layer: `HttpStudioClient → SandwichLayer → studio API`. The sandwich is composable middleware.

We start simple and grow as needed. v0.1 has only `PseudoStudioClient`. v0.2 adds `HttpStudioClient`. v0.3+ may grow translation/middleware layers if the integration matures.

---

## Authentication forwarding

When `HttpStudioClient` ships, the auth flow is:

1. User logs into product via `auth_service` → gets a product JWT
2. Product backend validates the JWT
3. Product backend mints a **studio access token** scoped to that user (either by exchanging the product JWT for a studio token via studio's API, or by signing a delegated token with a shared key)
4. Product passes the studio token to `HttpStudioClient`
5. Studio API validates the token, identifies the user, applies user-scoped permissions

Details deferred to v0.2 spec when studio's auth model is final. For v0.1 with pseudo client, no real auth — just a `user_id` parameter passed through.

---

## Error model

`packages/studio-client/src/entelecheia_studio_client/errors.py`:

```python
class StudioClientError(Exception):
    """Base for all studio client errors."""

class StudioConnectionError(StudioClientError):
    """Cannot reach studio (network, DNS, ...)"""

class StudioAuthError(StudioClientError):
    """Studio rejected the token or user."""

class StudioNotFoundError(StudioClientError):
    """Resource (project, meeting, ...) does not exist."""

class StudioInvalidArgumentError(StudioClientError):
    """Bad request (validation failed at studio side)."""

class StudioRateLimitError(StudioClientError):
    """Studio rate-limited the call. Includes retry-after."""

class StudioServerError(StudioClientError):
    """Studio reported an internal error."""

class StudioVersionMismatchError(StudioClientError):
    """Product's StudioClient Protocol version does not match studio's actual API version."""
```

`PseudoStudioClient` raises these on demand (e.g., calling `pseudo.simulate_error("StudioRateLimitError")` makes the next call throw). This lets product features test error paths without needing a broken real studio.

---

## Versioning the contract

The `StudioClient` Protocol is versioned with the product. Major bumps to the product (1.0 → 2.0) can break the Protocol; minor and patch versions cannot.

When we add a new method, it's additive — existing consumers don't notice. When we change a method signature, both `PseudoStudioClient` and `HttpStudioClient` update simultaneously, and consumers update too. The Protocol is the single source of truth.

If studio's real API changes in a breaking way, we either:
- Bump product to 2.0 (rare; reserved for genuinely new directions)
- Translate inside `HttpStudioClient` to preserve Protocol stability (preferred)

---

## Summary

The studio-client SDK is the load-bearing wall of product. Pseudo lets us develop independently; the Protocol is the contract; translations live inside the concrete implementations, never in feature code; and the swap from pseudo → real is a single config change.

Get this layer right, and adding new features or new verticals is straightforward. Get it wrong, and integration drift accumulates fast.
