---
name: entelecheia-product-philosophy
description: Use when designing, planning, or implementing ANY code, spec, or doc inside the entelecheia_product repo — writing v0.1 specs, drafting an API endpoint, adding a platform feature, adding a vertical pack, touching studio-client, naming a component, or extending a vertical manifest. Symptoms you need this skill: about to write a business/domain string literal in platform-*, about to import the engine, about to hardcode a studio URL, about to add inline mock data, about to special-case a vertical_id, about to swallow an exception, or unsure whether logic belongs in studio vs product vs vertical. Required before any non-trivial change in packages/, apps/, verticals/, or docs/specs/.
---

# entelecheia-product-philosophy

## Mission

entelecheia-product is the user-facing application layer: it talks to studio for everything, never sees engine, and verticals are UI plug-ins — not agents.

## Iron Routing Question

Before writing any line, answer:

- **Backend reasoning (LLM / paradigm / agent / skill)?** → studio's `ProjectSpec`, via `studio-client`. Never in this repo.
- **UI / data-feed for a single business domain?** → `packages/verticals/<id>/` via manifest. Never in `packages/platform-*`.
- **Capability *every* vertical needs?** → `packages/platform-features/<name>/`. Bar: every vertical, not "X needs it and we hope Y will too."
- **Auth / nav / theme / i18n / multi-vertical switcher?** → `packages/platform-shell/`.
- **Login / JWT?** → `packages/auth-service/`. **User prefs?** → `packages/user-service/`.
- **Product↔studio boundary?** → `packages/studio-client/` (and nowhere else).

## Routing Matrix

| Want to do | Put it in | Never put it in |
|---|---|---|
| Define an agent / paradigm / skill / LLM call | studio's `ProjectSpec` | anywhere in this repo |
| Tab/widget for a single domain | `packages/verticals/<id>/` via manifest | `packages/platform-*` |
| Capability every vertical needs | `packages/platform-features/<name>/` | `packages/verticals/*` |
| Translate studio real API ↔ Protocol | `packages/studio-client/HttpStudioClient` (P7) | feature/vertical code |
| New mock data | `packages/studio-client/fixtures/` (P6) | inline `# TODO: mock` in features |
| External data-feed proxy | `packages/verticals/<id>/api/` router | `platform-features` |
| Errors from studio | typed exception, surface to user (P8) | `try: ... except Exception: pass` |
| `if vertical_id == "X":` in platform | refactor to manifest-supplied protocol (P10) | inline branch in `platform-*` |

## P1–P10 — index (full text in `docs/design/01-design-principles.md`)

- **P1** Product is the user-facing application; nothing more.
- **P2** Vertical is UI specialization, not domain logic.
- **P3** Studio is the only backend logic.
- **P4** Platform shell + features are stable; additive change only.
- **P5** Verticals are independent — no cross-vertical imports, no platform edits.
- **P6** `PseudoStudioClient` is faithful to the Protocol (not a mock pile).
- **P7** Translation layer lives in `studio-client`, not in features.
- **P8** Loud failures, no silent fallback.
- **P9** No business / domain words in `packages/platform-*`.
- **P10** Composition over configuration — no `if vertical_id == "X":` in platform.

## The 8 Red Lines (full text in `CONTRIBUTING.md` §The red lines)

| # | Rule | Enforced by |
|---|---|---|
| 1 | Product code never imports `entelecheia` (engine) | `check-purity.sh` |
| 2 | Studio access only via `packages/studio-client/` | `check-purity.sh` |
| 3 | Verticals never modify `platform-shell/` or `platform-features/*` | CI + reviewer |
| 4 | Verticals never import each other | `check-purity.sh` |
| 5 | No agent / paradigm / skill / model logic anywhere in this repo | reviewer |
| 6 | No business / domain / product / agent-role string literals in `platform-*` | `check-purity.sh` |
| 7 | `PseudoStudioClient` is a faithful Protocol implementation | reviewer |
| 8 | Loud failures — no `try: ... except Exception: pass` | reviewer |

## Forbidden vocabulary in `packages/platform-*` and `apps/*`

Source of truth: `scripts/check-purity.sh`. Update there first if this list ever grows.

```
business domains:  investment, legal, medical, policy, due_diligence,
                   investment_research, risk_management
product names:     Magellan, magellan, BP
agent roles:       RiskAssessor, DCFAnalyst, CaseLawAnalyst, MarketAnalyst,
                   ContrarianAnalyst, FinancialExpert, MacroEconomist,
                   ESGAnalyst, SentimentAnalyst, QuantStrategist, LegalAdvisor
deprecated:        roundtable, Roundtable    (use: agora)
```

Allowed in: `packages/verticals/<id>/`, `docs/migration-log.md`, `docs/adr/`.

## Rationalizations — STOP and re-route

| "But it's just…" | Reality |
|---|---|
| "…a placeholder, I'll move it later" | Placeholders ship. Put it in the right package now. |
| "…one quick `if vertical_id == 'investment':`" | P10 violation. Refactor to a manifest-supplied protocol. |
| "…X is the only vertical we have" | The whole point of v0.1 is to prove pluggability. Do not bake the assumption in. |
| "…the spec is just describing what studio does" | Then it belongs in studio's repo, not this one. |
| "…mocking the value inline is faster than touching fixtures" | Faster today, broken at the v0.2 swap. P6 / Red-line #7 catches this. |
| "…adding the LLM call temporarily for testing" | Red-line #5. There is no temporary. |
| "…a comment, not a string literal" | Reviewer will still flag it; rename now. |
| "…the spec is just sketching" | Specs become code. Sketch in the right package. |

## Verification

Before any commit: `bash scripts/check-purity.sh` must exit 0.

When uncertain, read the canonical source: `docs/design/01-design-principles.md` (P1–P10), `CONTRIBUTING.md` (red lines), `docs/design/02-studio-integration.md` (Protocol + Pseudo↔Http swap), `docs/design/03-vertical-pack-model.md` (manifest + registration), `docs/design/04-platform-features.md` (agora-centric inventory).
