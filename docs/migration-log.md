# Migration Log

Provenance ledger for upstream migrations into `entelecheia-product`. Every code or design idea pulled from another repository is recorded here, with date, source, and rationale. This log is append-only.

This log is not a changelog. Day-to-day work is recorded in git. This log records *origins* — where ideas and code came from, and why a version was chosen as the starting point.

---

## 2026-04-29 — Repository founded

- **Repository:** `git@github.com:dengjianbo3/entelecheia_product.git`
- **Decision:** ADR-0001 (product as multi-vertical platform with pseudo studio-client)
- **Builds on:**
  - Engine ADR-0002 (three-project architecture) — established that product is the third project alongside engine + studio
  - Engine ADR-0003 (Python rationale) — informs product's Python backend choice
  - Studio ADR-0001 (studio-as-internal-ops-platform) — establishes the boundary; product talks to studio for all backend logic
- **Founding documents created:**
  - `README.md`, `ARCHITECTURE.md`, `CONTRIBUTING.md`
  - `docs/adr/0001-product-as-multi-vertical-platform.md`
  - `docs/design/00-product-vision.md`
  - `docs/design/01-design-principles.md` (P1–P10)
  - `docs/design/02-studio-integration.md` (pseudo studio-client + Protocol)
  - `docs/design/03-vertical-pack-model.md`
  - `docs/design/04-platform-features.md`
- **Tooling:** uv workspaces, ruff, mypy strict, pytest, GitHub Actions CI, `scripts/check-purity.sh`
- **Repository state:** Day 0 — no `packages/` or `apps/` content yet beyond `.gitkeep` placeholders. v0.1 detailed specs and implementation start in the next session.

---

## 2026-04-29 — `roundtable` → `agora` rename

The deliberation discussion feature (the central UI where users see agents discussing a topic, evidence flowing, consensus forming) is named **agora** throughout this repo, NOT `roundtable`.

- **Source of old name:** Magellan internal product name
- **Why deprecated:** "Roundtable" is too literal (a shape) and too commercial (boardroom imagery); does not fit the entelecheia naming scheme
- **Rationale for `agora`:**
  - Fits entelecheia's Greek/philosophical naming (entelecheia = "actuality / completion")
  - Means "Greek public assembly" — citizens deliberating in the open
  - Conveys "many voices, one space" — exactly what the product's deliberation UI is
  - No upstream cultural baggage; not a trademarked name
- **Alternatives considered and rejected:** `symposium` (too elite), `panel` (too judgmental), `forum` (too generic), `council` (too formal/governance-flavored)
- **Code-level effect:** Zero files in this repo use the word `roundtable`. The platform feature is `packages/platform-features/agora/`. CI's `scripts/check-purity.sh` rejects `"roundtable"` and `"Roundtable"` as string literals in code (under red line #2).

---

## 2026-04-29 — First vertical: `investment`

- **Vertical id:** `investment`
- **Why first:**
  - Largest realized internal use case (Magellan's investment-research workflows are the original motivator for the entelecheia stack)
  - Most stress on the platform: financial reports + market data + multi-doc cross-referencing
  - Already has working agent compositions in studio's first ProjectSpecs
- **What it contributes (per `docs/design/03-vertical-pack-model.md`):**
  - Tabs: 行情 (Market Watch), 持仓 (Portfolio)
  - Widgets: market summary
  - Upload handlers: financial report, business plan
  - Data feeds: yahoo-finance, akshare (proxied via vertical's FastAPI router)
  - Default project filter: `labels_any_of=["investment"]`
- **Subsequent verticals (out of v0.1 scope):** policy, legal, medical — each in its own follow-on session.

---

## 2026-04-29 — Pseudo studio-client adopted for v0.1

- **Decision:** ADR-0001 §"Pseudo studio-client model"
- **Rationale:**
  - Studio v0.1 is in parallel development; its REST/WS API surface is not finalized
  - Without a stand-in, product UI development would be blocked until studio ships
  - A pseudo client implementing the full `StudioClient` Protocol unblocks the product without compromising the contract
- **Implementation plan:**
  - `packages/studio-client/` defines the `StudioClient` Protocol (~16 methods: `list_available_projects`, `run_meeting`, `subscribe_meeting`, `get_meeting_outcome`, `get_dag_view`, `get_provenance`, `get_cost_aggregate`, `chat`, etc.)
  - `PseudoStudioClient` returns realistic mock data from `packages/studio-client/fixtures/`
  - `HttpStudioClient` (added in v0.2+) makes real HTTP/WebSocket calls; if studio's actual API differs from product's assumptions, translation lives inside `HttpStudioClient` (per **P7**), never in feature code
- **Substitution tests:** every platform feature and vertical that uses studio-client must run against both `PseudoStudioClient` and `HttpStudioClient` identically (per `02-studio-integration.md`)

---

## Conventions

- **Date format:** `YYYY-MM-DD`
- **One entry per migration event.** Don't merge entries.
- **Append-only.** Past entries are never edited; corrections go in a new entry.
- **No code in this log.** Code lives in git. This log records *why* an upstream choice was made.
- **No vague entries.** "Fixed bugs" or "improved things" don't belong here. Specific origins, specific decisions only.

---

## Future entries

When subsequent verticals are added, when a major refactor lands, when an upstream dep is changed for a non-trivial reason — append here. New ADRs link here; new design docs link here. The migration log is the project's memory.
