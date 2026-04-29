# Working in entelecheia_product

Before designing or implementing **anything** in this repo (specs in `docs/specs/*`, code
in `packages/*`, `apps/*`, or `verticals/*`), invoke the project skill:

    Skill: entelecheia-product-philosophy

It loads P1–P10, the 8 red lines, the routing matrix
(shell / feature / vertical / studio / auth / user), and the forbidden-vocabulary list.

Canonical sources of truth:

- `docs/design/01-design-principles.md` — P1–P10
- `CONTRIBUTING.md` — the red lines
- `scripts/check-purity.sh` — the mechanical enforcer

Run `bash scripts/check-purity.sh` before every commit; it must exit 0.
