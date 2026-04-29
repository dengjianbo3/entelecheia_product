---
name: writing-product-specs
description: Use when writing or editing any v0.1 spec file under docs/specs/ in entelecheia_product — drafting a new spec, adding a section, defining a data model, declaring an API endpoint, listing an error type, building a test matrix, or making a design decision. Symptoms you need this skill: about to write "an endpoint that receives X" instead of method+path+schema, about to describe a data model in prose instead of a TypedDict/pydantic/TS interface, about to leave "other" / "Any" in an error taxonomy, about to skip the "Why this design / why not the alternative" on a non-obvious decision, about to omit a test matrix for a public method, or unsure of the spec house style. Required for every spec change in docs/specs/v0.1/.
---

# writing-product-specs

## Mission

A spec is a contract, not prose. A competent engineer must implement directly from the file without asking questions. If they would need to ask, the spec is incomplete.

For routing / red lines / forbidden vocabulary, defer to `entelecheia-product-philosophy`. This skill is about document craft only.

## Required structure (every spec, in this order)

1. **Mission** — one sentence: *"this file defines X so Y can do Z."*
2. **Scope** — three bullet lists: covers / does not cover / out of scope for v0.1.
3. **Data models** — full signatures.
4. **APIs / interfaces** — full signatures (method + path + request + response).
5. **Error model** — sealed taxonomy.
6. **Test matrix** — table per public method.
7. **Why this design / why not the alternative** — per non-obvious decision.

File path: `docs/specs/v0.1/NN-name-spec.md`. Target length 600–1500 lines.

## Data model conventions

- Python: `pydantic.BaseModel` for validated payloads, `TypedDict` for pure typing of dict-shaped data, `Enum` / `Literal` for closed sets.
- TS: `interface` for object shapes, `type` for unions/aliases, single source of truth per model, exported.
- No `Any` / `unknown` / `dict[str, Any]` / `object` without an inline `# WHY` comment.
- Every field: type, default (if any), docstring or TSDoc explaining meaning, units, range, constraints.

```python
class ProjectSummary(BaseModel):
    project_id: ProjectId         # opaque to product; assigned by studio
    display_name: str             # user-facing; <= 80 chars; not localized
    labels: list[str]             # vertical filter keys; lowercase snake
    version: int                  # monotonic; pinned by callers for cache validity
```

Prose-only definitions (e.g. *"ProjectSummary contains the project ID and a list of labels"*) are not acceptable.

## API / interface conventions

For every endpoint or Protocol method, specify ALL of: HTTP method (or async signature), final path string (no `/api/...something...` placeholders), request schema (typed; query / path / body separated), response schema (typed; per status code), status codes per outcome, error responses mapped to the sealed taxonomy, auth + permission requirement (or `none`, explicitly).

```
GET /api/platform/projects
  query: vertical_id?: str, labels_any_of?: list[str], cursor?: str
  auth:  required (user JWT); permission "platform:list_projects"
  200:   ProjectSummariesResponse { items: list[ProjectSummary], next_cursor: str | None }
  401:   AuthRequired
  403:   PermissionDenied
  502:   StudioUnavailable    # propagated from studio-client
```

For Protocol methods (in `studio-client`), apply the same discipline to the async signature: full type, full kwargs, full return type, full raised exception union.

## Error model — sealed taxonomy

Every public method declares its full exception set as a closed union. No bare `Exception`, no `OtherError`, no string-typed errors. Each error declares: name, when raised, recovery hint, whether it surfaces verbatim to the user, HTTP mapping (if applicable).

```python
ListProjectsError = StudioUnavailable | AuthRequired | PermissionDenied
# No catch-all. Adding a new failure mode requires extending the union here AND
# in every fixture / test that exercises this method.
```

Substitution rule (P6): any error a real `HttpStudioClient` could plausibly raise must also be representable by `PseudoStudioClient`, and vice versa.

## Test matrix conventions

For every public method, one table. Columns: scenario, input, expected output OR raised exception, test_id. Must cover at minimum: happy path, empty / boundary, each declared exception, each declared permission gate.

| scenario | input | expected output / raised | test_id |
|---|---|---|---|
| happy path | `vertical_id="<v>"`, `labels_any_of=["a"]` | non-empty `ProjectSummariesResponse` | `t_list_projects_happy` |
| empty result | `vertical_id="<unknown>"` | `items=[]`, `next_cursor=None` | `t_list_projects_empty` |
| studio down | fixture `studio_down` | raises `StudioUnavailable` | `t_list_projects_studio_down` |
| no permission | user without `platform:list_projects` | raises `PermissionDenied` | `t_list_projects_perm_denied` |

**Substitution tests**: where the spec describes a `studio-client` Protocol method, mark each `test_id` with `[SUB]` if it must pass under both `PseudoStudioClient` and `HttpStudioClient`. The substitution-test spec (`17-substitution-tests-spec.md`) is the meta-contract.

## "Why this design / why not the alternative"

Required for every non-obvious decision: data shape, error split, fixture layout, ordering guarantee, eviction policy, naming, default value, paging style, etc.

> **Why this design.** One paragraph. State the chosen option and the concrete reason it wins.
>
> **Considered and rejected.**
> - *Alternative A* — rejected because `<concrete reason; not "felt better">`.
> - *Alternative B* — rejected because `<concrete reason>`.

At least one rejected alternative when any plausible one exists. "No alternatives considered" is a smell — usually means the decision wasn't analyzed and will be revisited under pressure later.

## Cross-cutting

- **Routing / red lines / vocabulary** → `entelecheia-product-philosophy`. Do not duplicate.
- **Studio internals** (paradigms, agents, skills, LLM choice) → out of scope. Describe what product **asks** studio for via the Protocol, not what studio **does** internally.
- **Fixtures** → live in `packages/studio-client/fixtures/`. The spec must list the fixture shapes it requires (P6); a feature spec must never write `# TODO: mock`.
- **i18n** → if a spec introduces user-visible strings, list every key with its `zh` + `en` value.
- **Events / streams** → spec must define ordering guarantee, idempotency rule, reconnect cursor semantics, and event-folding rule explicitly. No "the UI will figure it out."

## Rationalizations — STOP

| "But it's just…" | Reality |
|---|---|
| "…the schema is obvious from the name" | Then it costs 30 seconds to write. The implementer should not need to infer. |
| "…I'll add the 'why' later" | Future-you forgets the rejected alternatives. Write now. |
| "…test matrix is implementation work" | The matrix is what makes implementation deterministic. Write before. |
| "…leave `OtherError` for now" | `OtherError` is where bugs hide. Be exhaustive or the taxonomy is wrong. |
| "…prose is faster than a class" | Faster to write, slower to implement, often subtly wrong at the seams. |
| "…I don't know the path yet, placeholder OK" | Decide now. A placeholder path means the spec is not ready to merge. |

## Pre-commit checklist

- [ ] Mission + Scope present, one-paragraph each, "out of scope for v0.1" listed
- [ ] Every data model has a full signature (no prose-only definitions)
- [ ] Every API has method + path + request + response + error mapping + auth
- [ ] Every public method has a test matrix table; substitution tests marked `[SUB]`
- [ ] No `Any` / `unknown` / "other" / bare `Exception` without inline justification
- [ ] Every non-obvious decision has Why-this / Why-not blocks (≥ 1 rejected alternative)
- [ ] Fixture shapes listed; i18n strings (if any) listed with zh + en
- [ ] `entelecheia-product-philosophy` re-scanned: no vocab / routing / red-line drift
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/NN-name-spec.md`
