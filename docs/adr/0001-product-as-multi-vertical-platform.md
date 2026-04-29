# ADR-0001: Product as a Multi-Vertical Platform with Pseudo Studio-Client

- **Status**: Accepted
- **Date**: 2026-04-29
- **Decision-makers**: 邓剑波 (project owner)
- **Builds on**:
  - [Engine ADR-0002](https://github.com/dengjianbo3/Entelecheia_engine/blob/main/docs/adr/0002-three-project-architecture.md) (three-project architecture)
  - [Engine ADR-0003](https://github.com/dengjianbo3/Entelecheia_engine/blob/main/docs/adr/0003-engine-language-choice.md) (Python rationale)
  - [Studio ADR-0001](https://github.com/dengjianbo3/Entelecheia_studio/blob/main/docs/adr/0001-studio-as-internal-agent-ops-platform.md) (studio scope)

---

## Context

Engine ADR-0002 settled the three-project architecture: engine → studio → product. Studio ADR-0001 settled studio's role as the internal platform that owns all "agent-related" capabilities (substrate, paradigms, specs, registry, runtime, observability). What was left undecided was **what the product layer actually is**, given that everything agent-related has been pulled out.

A multi-round brainstorm on 2026-04-29 settled the following clarifications:

1. **Vertical means UI / data-feed specialization, not agent specialization.** Agent-side verticalization is already handled by studio's `ProjectSpec` (each project is a verticalized agent bundle). What product verticals add is *user-facing* domain customization: investment users see a 行情 tab and 持仓 widget; policy users see 舆情监控; legal users see 判例时间线. Verticals carry zero agent logic.

2. **The product is a "mother ship" — multiple verticals share one platform.** Platform shell + platform features (deliberation UI, reports, knowledge browser, etc.) are always present. Verticals plug in tabs, widgets, upload handlers, and external data-feed proxies via a manifest. Adding a vertical does not modify platform code.

3. **Studio integration is pseudo first, real later.** Until studio v0.1 finalizes its API, product implements a pseudo `StudioClient` returning mock data. Platform features and vertical packs are written against the Protocol; the implementation is swapped from pseudo to real HTTP/WS later. If studio's API differs from product's assumptions, the translation lives inside the real `HttpStudioClient`, not in feature code.

4. **"Roundtable" naming is deprecated; the deliberation discussion feature is renamed `agora`.** Rationale: roundtable is too literal (a shape) and too commercial (boardroom imagery); agora (古希腊市民集会) fits the entelecheia naming scheme, conveys "many citizens deliberating," and has no upstream cultural baggage.

5. **First vertical is `investment`.** Subsequent verticals (policy, legal, etc.) are out of v0.1 scope.

## Decision

### Product's mission

> **entelecheia-product is the user-facing application layer of the Entelecheia three-project stack. It serves multiple verticals from one mother-ship platform, talks to studio for all backend logic, and never sees engine.**

### What product IS

- A **Vue 3 SPA + FastAPI backend** assembling an end-user application
- A **platform shell** (auth, navigation, multi-vertical switcher, theming, i18n, settings) — always present
- A **platform feature library** (agora deliberation UI, reports, knowledge browser, chathub, uploads, wizard, observability dashboards) — always present, used by every vertical
- A **vertical-pack mechanism** for plugging in domain-specific UI (tabs, widgets, upload handlers, data-feed proxies) without modifying platform code
- A **studio-client SDK** as the single contract for talking to studio
- Two **lightweight microservices** (`auth_service`, `user_service`) for auth + preferences

### What product is NOT

- ❌ Not a deliberation runtime — that's engine (consumed via studio)
- ❌ Not an agent platform — that's studio
- ❌ Not an LLM client / paradigm host / skill registry — all studio
- ❌ Not multi-tenant — single-tenant for v0.x; future v2.0+ if external use opens
- ❌ Not a customer SaaS — internal infrastructure (matching studio's scope)

### What "vertical" means

A **vertical pack** in product is a self-contained directory at `packages/verticals/<id>/` containing:

- A `manifest.ts` declaring the vertical's UI surface (tabs, widgets, upload handlers, data feeds, default project filter, i18n)
- Vue components for those tabs / widgets / handlers
- A FastAPI router for vertical-specific data-feed proxies (e.g., a thin proxy to a market-data API)
- A backend `manifest.py` registered as a Python entry point

When a vertical is enabled (via configuration), the product's frontend boot reads its manifest and registers routes/widgets/handlers; the backend boot reads the entry-point manifest and includes the router. The vertical changes what the user *sees and does* but never touches platform shell or features.

### Pseudo studio-client model

`packages/studio-client/` defines:

```python
class StudioClient(Protocol):
    async def list_available_projects(self, user_id: str, vertical_id: str | None = None) -> list[ProjectSummary]: ...
    async def run_meeting(self, project_id: str, topic: str, materials: list[Material]) -> MeetingHandle: ...
    async def get_meeting_outcome(self, meeting_id: str) -> MeetingOutcome: ...
    async def get_dag_view(self, meeting_id: str) -> DagViewSnapshot: ...
    async def get_provenance(self, meeting_id: str, claim_id: str) -> ProvenanceTrace: ...
    async def subscribe_meeting(self, meeting_id: str) -> AsyncIterator[MeetingEvent]: ...
    async def get_cost_aggregate(self, **dimensions) -> CostReport: ...
    # ~15 methods total
```

Two implementations:

- `PseudoStudioClient` (v0.1): returns realistic mock data; lets the entire product UI develop without studio existing
- `HttpStudioClient` (v0.2+): real HTTP/WebSocket calls; if studio's API shape differs from what the product assumes, translation lives here

Platform features and vertical packs depend only on the `StudioClient` Protocol — never on a specific implementation.

### `roundtable` → `agora` rename

The deliberation discussion feature (the central UI where users see agents discussing a topic, evidence flowing, consensus forming) is named **agora** throughout this repo. No code, doc, file, or comment uses the word "roundtable." Migration log records the rename.

## Consequences

### Positive

- **Clear product role.** No more confusion about whether product owns engine internals or studio's substrate. Product is the user-facing shell + vertical UI customization. That's it.
- **Verticals can be added by product managers (eventually) without engineer involvement.** The manifest-driven model is approachable; engineering effort for new verticals is hours, not weeks.
- **Independent development from studio v0.1.** Pseudo studio-client lets the entire product UI ship without depending on studio's actual API. When studio is ready, the swap is small.
- **Vertical-as-UI-plugin keeps platform stable.** Platform shell + features evolve once; verticals plug in. Version-skew between platform and verticals is low because the platform contract changes rarely.
- **Cost / observability is centralized.** All cross-vertical cost/latency/error metrics flow through studio's observability and the product reads aggregates. No per-vertical custom metric infrastructure.

### Negative / costs

- **Pseudo client diverging from real studio API is a real risk.** Mitigation: the StudioClient Protocol is the contract; if real studio API needs more or fewer methods, the Protocol changes (one place), and consumers updates follow. The translation layer in `HttpStudioClient` absorbs minor API shape mismatches.
- **Multi-vertical permission/routing is non-trivial.** Each user might have access to different verticals; the platform's vertical switcher must respect permissions. Auth flow needs to handle this. Deferred to v0.1 detailed plan.
- **Product team and studio team must coordinate API design.** Even with pseudo-client decoupling, the eventual real integration requires the two sides to agree on contracts. Solution: studio publishes its REST/WS API spec when v0.1 is approved; product reviews and adjusts the pseudo-client Protocol to match (or adds a translation layer).

### Future flexibility preserved

- Multi-tenancy hooks (tenant_id everywhere it could conceivably matter) are added now even though no multi-tenancy is implemented in v0.x — schemas leave room.
- Vertical packs are independent Python+Vue packages; in the future, they could be installed via `pip install` from external repos (vertical marketplace), enabling third-party verticals.
- The studio-client Protocol can grow additively; existing consumers don't break when new methods are added.

## References

- [Engine ADR-0002](https://github.com/dengjianbo3/Entelecheia_engine/blob/main/docs/adr/0002-three-project-architecture.md)
- [Engine ADR-0003](https://github.com/dengjianbo3/Entelecheia_engine/blob/main/docs/adr/0003-engine-language-choice.md)
- [Studio ADR-0001](https://github.com/dengjianbo3/Entelecheia_studio/blob/main/docs/adr/0001-studio-as-internal-agent-ops-platform.md)
- [`docs/design/00-product-vision.md`](../design/00-product-vision.md) — canonical vision
- [`docs/design/01-design-principles.md`](../design/01-design-principles.md)
- [`docs/design/02-studio-integration.md`](../design/02-studio-integration.md)
- [`docs/design/03-vertical-pack-model.md`](../design/03-vertical-pack-model.md)
- [`docs/design/04-platform-features.md`](../design/04-platform-features.md)

## Decision recorded by

Brainstorming session 2026-04-29 across multiple sub-rounds: (a) initial product layer survey + cross-layer leakage map, (b) clarification that "vertical" is product-UI not agent-domain, (c) confirmation of `entelecheia-product` repo + `agora` rename + `investment` first vertical + pseudo studio-client.
