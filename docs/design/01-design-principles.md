# Design Principles

Non-negotiable principles that gate every product architectural decision. These come from ADR-0001 + the founding brainstorm. CI mechanically enforces what it can; the rest is reviewer judgment.

---

## P1 — Product is the user-facing application; nothing more

Product owns: the Vue SPA, the FastAPI backend that wraps studio, the auth + user microservices, the platform shell, the platform features, the vertical packs.

Product does NOT own: deliberation runtime, agent runtime, LLM clients, paradigm logic, skill execution, memory backends, agent specs, project specs.

When in doubt: "could this run without a backend agent?" If yes, it's product. If no, it belongs to studio (and product talks to studio for it).

---

## P2 — Vertical is UI specialization, not domain logic

A vertical pack adds tabs / widgets / upload handlers / data-feed proxies. It does **not** carry agent logic, paradigm choice, skill content, or anything that requires reasoning. Agent capability is studio's `ProjectSpec`; verticals at most reference projects by ID (with `default_project_filter`).

If a vertical author finds themselves writing agent-like logic, the work belongs in studio.

---

## P3 — Studio is the only backend logic

All non-trivial backend behavior reaches the user through `studio-client`. The product's own backend (`apps/api/` + `verticals/*/api/`) does only:
- HTTP/WS endpoint definitions
- Request validation + auth
- Calls to `studio_client.*`
- Local data-feed proxies (e.g., a vertical proxying a market-data API to frontend)
- File upload buffering
- Static asset serving

Everything else flows through studio.

---

## P4 — Platform shell + platform features are stable

Once a platform feature is in `packages/platform-features/<name>/`, its public surface doesn't change without a major version bump of the product. Verticals depend on it; breaking it breaks every vertical.

Adding a new platform feature is a deliberate decision (PR + design review). Updating an existing platform feature is additive only.

---

## P5 — Verticals are independent

A vertical pack:
- Cannot modify platform shell or platform features
- Cannot import other verticals
- Cannot modify global state outside its own namespace
- Can only contribute via its declared manifest (tabs / widgets / handlers / data feeds / i18n)

This isolation is what lets us add a vertical in days without breaking any other vertical.

---

## P6 — Pseudo studio-client is faithful to the Protocol

`PseudoStudioClient` is not a one-off mock pile. It implements the full `StudioClient` Protocol with realistic mock data + realistic timing (e.g., simulating event streams with delays). This discipline keeps consumers honest about their dependencies and minimizes surprises when the real client is swapped in.

If a feature needs new mock data, add it to `PseudoStudioClient.fixtures/` properly (not a `# TODO: mock` block in a feature file).

---

## P7 — The translation layer lives in studio-client, not features

If studio's actual API differs from what the product assumes (which will happen — APIs evolve), the translation goes inside `HttpStudioClient` or a sandwich layer in `packages/studio-client/`. Feature code never sees the translation; it sees the same `StudioClient` Protocol.

This is the single most-leveraged abstraction in the product. Keep it clean.

---

## P8 — Loud failures, no silent fallback

Errors are typed exceptions raised loudly. `try: ... except Exception: pass` is forbidden. If `studio-client` throws, the feature surfaces the error to the user — it does not pretend things are fine and return mock data.

The studio-client's pseudo implementation never throws unrealistic errors; it returns valid data or `RaisesPseudo*` errors that match what the real client could realistically throw.

---

## P9 — No business / domain words in `packages/platform-*`

Within platform-shell and platform-features, no string literal may match specific business domains (`"investment"`, `"legal"`, `"medical"`, `"DCF"`, `"due_diligence"`) or specific upstream products (`"Magellan"`, `"Roundtable"`, etc.). These words appear only inside `packages/verticals/<id>/` (where they're correct) or `docs/migration-log.md` / `docs/adr/` (where historical accuracy requires them).

This is the same kind of red-line that engine and studio have. Engineers + product managers will be tempted to "just put 'investment' here for now" — `scripts/check-purity.sh` rejects that.

---

## P10 — Composition over configuration

A new "kind of vertical" is a new vertical pack, not a magic configuration flag. New "kind of platform behavior" is a new platform feature, not a special-case branch.

If you find yourself writing `if vertical_id == "investment":` inside a platform feature, stop. Either:
- The behavior belongs in the investment vertical (use the manifest mechanism)
- The behavior is generic platform — refactor to use a vertical-supplied protocol
- The behavior is product-level configuration — needs a deliberate platform feature for it

`scripts/check-purity.sh` checks for `"investment"` etc. in platform code as an indicator of this leak.

---

## How these principles compose

These principles reinforce each other:

- **P1 (product is user-facing only)** + **P3 (studio is backend logic)** = clean three-layer separation
- **P2 (vertical = UI)** + **P5 (verticals independent)** = pluggability works
- **P4 (platform stable)** + **P5 (verticals independent)** = verticals can ship at their own pace
- **P6 (pseudo faithful)** + **P7 (translation in studio-client)** = product develops without waiting on studio
- **P8 (loud failures)** + **P10 (composition)** = no spaghetti special cases

If a proposed change requires bending one principle, check the others. Usually the answer is to find a different design.
