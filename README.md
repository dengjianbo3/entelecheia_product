# entelecheia-product

> Multi-vertical product platform — a "mother ship" for vertical packs (investment, policy, legal, ...) sharing a common shell + features and consuming Entelecheia-studio's API for all agent capabilities.

**Status:** v0.0.1 — Pre-1.0. Day 0 scaffolding + canonical design docs only. No implementation yet.

---

## What it is

entelecheia-product is the **third project** in the Entelecheia three-project architecture:

```
                                                   ┌─ entelecheia-product ──────────┐
   user ──→ frontend ──→ product API ──→ studio API│ (this repo)                    │
                                          ↓        │                                │
                                     entelecheia-  │ Platform shell + features      │
                                     studio        │ + pluggable vertical packs     │
                                          ↓        │                                │
                                     entelecheia-  └────────────────────────────────┘
                                     engine
```

**The product talks to studio only.** It never imports the engine, never directly manages agents/projects/skills, never runs meetings itself. It assembles a coherent user-facing application from:

1. **Platform shell** — auth, navigation, theming, i18n, multi-vertical switcher (always present)
2. **Platform features** — agora (deliberation UI), reports, knowledge browser, chathub, uploads, wizard, settings, observability dashboards (always present, vertical-agnostic)
3. **Vertical packs** — pluggable UI/data customizations for a specific business domain (e.g., the `investment` vertical adds a 行情 tab + 持仓 widget + external market data feed). Verticals do **not** carry agent logic — that lives in studio's `ProjectSpec`s, which the product requests on demand based on user permissions.

## What "vertical" means here (important — not what you might think)

The agent layer's verticalization is **already** handled by studio (each `ProjectSpec` is a verticalized agent bundle). The product's verticals are about **UI / data feed / external integration** customization for a domain — not agents.

Examples:

- **investment** vertical adds: `行情` tab, `持仓` widget, `财报上传 + 解析` flow, external market-data API proxy
- **policy** vertical (future) might add: `舆情监控` widget, `法规对比表`, `政策追踪` dashboard
- **legal** vertical (future) might add: `判例时间线`, `卷宗导航`, `案件管理`

Each vertical is a manifest + Vue components + a small backend router proxying external data feeds. Nothing more. Agent capability comes from studio.

## Why it exists

After [engine ADR-0002](https://github.com/dengjianbo3/Entelecheia_engine/blob/main/docs/adr/0002-three-project-architecture.md) extracted the engine into its own package and studio extracted all "agent-related" capabilities into its own platform, what remains is the **user-facing application layer**. This layer was previously tangled inside an upstream codebase mixed with engine internals; here it lives cleanly with no engine knowledge whatsoever.

The "mother ship" model lets us serve multiple vertical markets (investment, policy, legal, future verticals) from one platform without duplicating shell, features, or studio integration code.

## Read in order (~50 minutes)

| # | Document | Purpose | Time |
|---|---|---|---|
| 1 | [`README.md`](README.md) | orientation (you are here) | 5 min |
| 2 | [`ARCHITECTURE.md`](ARCHITECTURE.md) | three-project model + product layout + 30-min brief | 30 min |
| 3 | [`CONTRIBUTING.md`](CONTRIBUTING.md) | red lines + quality gates | 10 min |
| 4 | [`docs/design/00-product-vision.md`](docs/design/00-product-vision.md) | canonical vision (full) | 60 min |

Deep dives:

| Document | Purpose |
|---|---|
| [`docs/adr/0001-product-as-multi-vertical-platform.md`](docs/adr/0001-product-as-multi-vertical-platform.md) | founding decision |
| [`docs/design/01-design-principles.md`](docs/design/01-design-principles.md) | non-negotiable principles |
| [`docs/design/02-studio-integration.md`](docs/design/02-studio-integration.md) | the pseudo studio-client + future translation layer |
| [`docs/design/03-vertical-pack-model.md`](docs/design/03-vertical-pack-model.md) | what a vertical IS, manifest, registration |
| [`docs/design/04-platform-features.md`](docs/design/04-platform-features.md) | what each platform feature does, with agora as the centerpiece |

## Audience

- **Engineers** who build platform features + vertical packs (CLI + spec YAML + Vue)
- **Product managers** who configure verticals (which projects from studio, which feature blocks enabled — UI in v0.2+)

Not customer-facing as an SDK; this is the application layer that customers' end users use through a browser.

## Repo layout (Day 0 scaffold)

```
entelecheia_product/
├── packages/                       # uv workspace members
│   ├── platform-shell/             # auth, nav, theme, i18n (frontend + minimal backend)
│   ├── platform-features/
│   │   ├── agora/                  # deliberation discussion UI (was "roundtable")
│   │   ├── reports/                # report browser + exports
│   │   ├── knowledge/              # knowledge tree browser
│   │   ├── chathub/                # generic expert chat
│   │   ├── uploads/                # file upload + generic PDF parsing
│   │   ├── wizard/                 # onboarding
│   │   ├── settings/               # user preferences
│   │   └── observability/          # cost / latency dashboards
│   ├── studio-client/              # SDK to studio API (v0.1: pseudo with mocks)
│   └── verticals/
│       ├── _template/              # how to write a new vertical
│       └── investment/             # first vertical pack
│           ├── frontend/
│           ├── api/
│           └── manifest.ts
├── apps/
│   ├── frontend/                   # main Vue 3 SPA (composes shell + features + verticals)
│   └── api/                        # main FastAPI backend (composes platform routers + vertical routers)
├── auth_service/                   # lightweight microservice (auth flow)
├── user_service/                   # lightweight microservice (user prefs)
├── docs/
│   ├── design/                     # canonical design docs (00 is the vision)
│   ├── adr/                        # architectural decision records
│   └── migration-log.md            # provenance ledger
├── scripts/
│   └── check-purity.sh             # product's red-line lint
├── pyproject.toml + uv.workspace   # monorepo root
├── mypy.ini, ruff.toml
└── .github/workflows/ci.yml
```

## Versioning + release

- **v0.1**: platform shell + agora + reports + uploads + wizard + settings work end-to-end with **pseudo studio-client returning mock data**. First `investment` vertical demonstrates plug-in. CLI + dev mode only.
- **v0.2**: studio-client switches from pseudo to real HTTP/WS (after studio v0.1 ships and exposes its API). Translation layer added inside `studio-client` if needed.
- **v1.0**: at least one real vertical (investment) running with real users on real studio + engine for 7+ days stable.

## License

Proprietary, all rights reserved. License model TBD before any external distribution. See [`LICENSE.PROPRIETARY`](LICENSE.PROPRIETARY).
