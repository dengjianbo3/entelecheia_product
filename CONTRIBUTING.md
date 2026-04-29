# Contributing to entelecheia-product

Rulebook for any code change here. Every PR is reviewed against it.

---

## Before you write a line of code

Read in order:

1. [`README.md`](README.md) — overview
2. [`ARCHITECTURE.md`](ARCHITECTURE.md) — three-project model, vertical-pack mechanism, studio integration
3. [`docs/design/00-product-vision.md`](docs/design/00-product-vision.md) — canonical vision
4. [`docs/design/01-design-principles.md`](docs/design/01-design-principles.md) — non-negotiable principles

---

## The red lines (non-negotiable)

If a PR violates any of these, it is rejected outright.

### 1. Product code never imports engine

The engine package (`entelecheia`) is **not a runtime dependency** of any product code. The only path to backend logic is through `entelecheia_studio_client`. PRs containing `from entelecheia import …` or `import entelecheia` anywhere in `packages/`, `apps/`, or `verticals/` are rejected.

### 2. Product code talks to studio only via `studio-client`

No package outside `packages/studio-client/` calls studio's API directly (no raw `httpx.get("studio.example.com/...")` in feature or vertical code). Everything flows through the `StudioClient` Protocol. The pseudo implementation and the future real HTTP implementation both implement that Protocol; consumers don't know which is which.

### 3. Verticals do not modify platform shell or platform features

A vertical pack contributes only via its manifest (tabs, widgets, upload handlers, data feeds, i18n). Verticals **cannot** edit `packages/platform-shell/` or `packages/platform-features/*`. Adding a vertical changes the product's surface; it cannot change the product's core. PRs touching platform code from inside a vertical's directory are rejected.

### 4. Verticals do not import each other

`packages/verticals/investment/` cannot import from `packages/verticals/policy/`. Each vertical is independent. Cross-vertical functionality belongs in platform features.

### 5. No agent / paradigm / skill / model logic anywhere in this repo

This repo contains zero LLM client code, zero paradigm implementations, zero agent base classes, zero skill bundle loading, zero LLM configuration. Every such concern goes through studio's API. PRs that introduce LLM calls, paradigm logic, or agent base classes are rejected.

### 6. No business / domain words in `packages/platform-*`

Within platform-shell and platform-features, no string literal may match specific business domains (`"investment"`, `"legal"`, `"medical"`, `"DCF"`, `"due_diligence"`, etc.) or specific upstream products (`"Magellan"`, `"Roundtable"`, etc.). These words appear only inside `packages/verticals/<id>/` (where they're correct, since the vertical is specifically about that domain), or inside `docs/migration-log.md` / `docs/adr/` (historical accuracy).

`scripts/check-purity.sh` enforces #1, #2, #5, #6 mechanically.

### 7. Pseudo studio-client must remain a faithful Protocol implementation

`PseudoStudioClient` is not a one-off mock pile — it implements `StudioClient` Protocol with realistic mock data. If a feature needs new mock data, add it to `PseudoStudioClient` properly (not `# TODO: mock` blocks scattered across consumers). This discipline keeps consumers honest about their dependencies.

### 8. Loud failures, no silent fallback

Errors are typed exceptions raised loudly. `try: ... except Exception: pass` is forbidden. Caller decides recovery.

---

## Quality gates (CI enforces all)

| Gate | Command | Notes |
|---|---|---|
| Backend lint | `ruff check packages apps` | Strict |
| Backend format | `ruff format --check packages apps` | Strict |
| Backend type | `mypy packages apps` (strict) | No implicit Any |
| Backend tests | `pytest` | Unit + integration |
| Frontend lint | `pnpm lint` (in `apps/frontend/`) | ESLint + Vue rules |
| Frontend tests | `pnpm test` (in `apps/frontend/`) | Vitest |
| Purity | `bash scripts/check-purity.sh` | Red lines #1, #2, #5, #6 |

---

## How to add a new platform feature

Platform features are vertical-agnostic; they're used by every vertical. Adding one is a deliberate decision because all verticals depend on the contract.

1. Create `packages/platform-features/<name>/` with frontend Vue module + (optional) backend router
2. Backend depends only on `studio-client` and stdlib FastAPI conventions
3. Frontend exports a `feature.manifest.ts` declaring its routes / components / dependencies
4. Add unit + integration tests
5. Update [`docs/design/04-platform-features.md`](docs/design/04-platform-features.md)
6. Update [`ARCHITECTURE.md`](ARCHITECTURE.md) "What product owns" if the feature is conceptually new

## How to add a new vertical pack

A vertical pack is a self-contained directory at `packages/verticals/<id>/`. Adding one should not require any platform changes.

1. `cp -r packages/verticals/_template packages/verticals/<id>/`
2. Edit `manifest.ts` and `manifest.py` (frontend + backend manifests)
3. Frontend: add Vue components for tabs / widgets / upload handlers
4. Backend: add FastAPI routers for data feeds (e.g., proxying external APIs)
5. Add tests in `packages/verticals/<id>/tests/`
6. Run substitution validation: with the new vertical enabled, run a smoke test that platform features still work and the new vertical's tabs appear
7. Update [`docs/design/03-vertical-pack-model.md`](docs/design/03-vertical-pack-model.md) only if your vertical demonstrates a new pattern (most don't)
8. PR description includes a 2-min screencast of the vertical's tabs + widgets working

## How to add a new public symbol

Public surface = each package's `__init__.py` exports for backend; `index.ts` for frontend.

1. Implement in proper module
2. Add to package's `__init__.py` `__all__` (or `index.ts` exports)
3. Add a smoke test under `packages/<pkg>/tests/`
4. Update relevant ARCHITECTURE.md / design doc if conceptually new

---

## Pull request template

```markdown
## What this changes
<one paragraph>

## Layer impact
- [ ] platform-shell
- [ ] platform-features (which?)
- [ ] verticals (which?)
- [ ] studio-client
- [ ] auth_service / user_service
- [ ] tests only
- [ ] docs only
- [ ] build / CI / tooling

## Red-line check
- [ ] No `from entelecheia import …` (engine internals not allowed)
- [ ] All studio access via `studio-client`
- [ ] Vertical (if any) does not modify platform-shell or platform-features
- [ ] Verticals (if multiple touched) do not import each other
- [ ] No agent / paradigm / skill / model logic
- [ ] No business / domain / product names in platform-*
- [ ] Pseudo client mock data remains faithful to Protocol
- [ ] No silent failures

## Tests added
<which tests, what they cover>

## Spec compliance
- [ ] Implementation matches `docs/design/00-product-vision.md` and relevant 0X spec
- [ ] If a spec was updated, the update PR is referenced
```

---

## When in doubt

Ask in the PR. The cost of a 24-hour delay for clarification is much smaller than the cost of accidentally re-introducing the layer-coupling that this whole project exists to escape.
