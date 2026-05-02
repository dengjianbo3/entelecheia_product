# 17 — substitution tests v0.1 spec

> **Status**: v0.1 meta-contract for the substitution test suite.
> **Lives at**: `tests/substitution/` (top-level repo dir; not a package).
> **Consumes**: every prior spec's `[SUB]`-marked test rows. Aggregates them into one runnable matrix.
> **Forwards to**: `18-end-to-end-scenarios-spec.md` (substitution scenarios are a subset of e2e scenarios).

---

## Mission

This file defines the **substitution test suite** — the runnable proof that the platform contracts hold under their two most consequential swaps: (a) `PseudoStudioClient` ↔ `HttpStudioClient` (per `01-studio-client-spec.md` §10, P6), and (b) install / uninstall of a vertical pack (per `13-vertical-template-spec.md` §11, Red Line #4 + P5). Every test in the suite is also declared in its owning feature/vertical spec under a `[SUB]` marker; this spec is the **central scoreboard** that lists every `[SUB]` row, the framework that runs them in two configurations, and the gate that fails CI if any row passes against Pseudo but fails against Http (or vice versa).

**Hard rule** (P6 + P10): a `[SUB]` test must produce identical observable behavior under both `PseudoStudioClient` and `HttpStudioClient` — same DTOs, same error taxonomy leaves, same event ordering, same UX state transitions. If the test produces different results, the bug is **always** in `PseudoStudioClient` (it lied about what studio does) or in `HttpStudioClient` (it failed to translate honestly), never in the feature code. Features assume the Protocol contract; this suite enforces that the Protocol implementations hold to it.

---

## Scope

**Covers.**
- The substitution test framework (`tests/substitution/runner/`): a Vitest harness that runs every `[SUB]` test twice — once with `VITE_STUDIO_CLIENT_MODE=pseudo` and once with `mode=http` (against a mocked-studio HTTP server).
- 5 categories of substitution test (defined in §3); every `[SUB]` test in every prior spec maps to exactly one category.
- The full inventory (§4) — every `[SUB]` test_id introduced by specs 01–16, with its category, source spec, and one-line description.
- Mocked-studio HTTP server contract (§5) — how the http-mode tests stand up a fake studio that obeys `01` §6 (the binding API).
- Vertical install/uninstall harness (§6) — how a test toggles a vertical between "installed" and "uninstalled" without rebuilding the whole app.
- Pass criteria (§7) — what "the suite is green" means; which conditions fail the build.
- Diff reporter (§8) — when pseudo and http disagree, the runner prints a structured diff (DTO field-by-field + event ordering side-by-side) so the regressing implementation is obvious.
- CI integration (§9) — how this suite slots into `.github/workflows/ci.yml` after the unit-test job; gates merges.
- Per-spec coverage gate (§10) — every spec that introduces a Protocol method or a vertical contribution MUST have at least one `[SUB]` row referenced here; the runner emits a coverage table.

**Does not cover.**
- The Pseudo or Http implementations themselves — `01-studio-client-spec.md` §10 owns them.
- The end-to-end scenarios — `18-end-to-end-scenarios-spec.md` owns the larger workflows that string multiple Protocol calls together. Substitution tests are unit/integration-grade; e2e is workflow-grade. Some e2e scenarios are also tagged `[SUB]` and surface here.
- Performance comparison between Pseudo and Http — the suite checks correctness, not throughput. Performance lives in operational runbooks.
- Fault injection (random latency, dropped events) — v0.2 may add chaos tests; v0.1 substitution tests use deterministic fixtures + deterministic mocks.
- Security tests (auth bypass, CSRF, etc.) — owned by `03-auth-service-spec.md` test matrix; not substitution-class.

**Out of scope for v0.1.**
- Cross-version substitution (v0.1 vs v0.2 protocols). v0.2 will introduce a contract-versioning suite; v0.1's substitution suite tests the v0.1 binding only.
- Property-based testing (fuzz the Protocol). Useful but premature; v0.1 needs the literal `[SUB]` rows green first.
- Snapshot-based golden masters for event streams. Considered (§ Why) and rejected for v0.1 brittleness.
- Cross-vertical interaction tests (vertical A's tab uses vertical B's fixtures). Forbidden by P5; if it ever becomes useful it's a different suite.

---

## §1 Module layout

```
tests/substitution/
├── runner/
│   ├── runSubstitution.ts            # the main harness; iterates [SUB] tests across modes
│   ├── modes.ts                      # constants: ["pseudo","http"]
│   ├── mockStudioServer.ts           # http-mode mocked studio (msw-node based)
│   ├── verticalToggle.ts             # install/uninstall harness
│   ├── diffReporter.ts               # structured diff between pseudo + http outcomes
│   └── coverage.ts                   # emits coverage table per source spec
├── inventory/
│   └── subTests.ts                   # generated: imports every [SUB] test from feature packages
├── fixtures/
│   ├── studio-binding/               # fixtures conforming to 01 §6 binding (used by mock studio)
│   │   ├── projects.json
│   │   ├── meetings.json
│   │   ├── meeting-events/<id>.ndjson
│   │   ├── outcomes.json
│   │   └── cost-reports.json
│   └── verticals/                    # fixture overlays loaded into mock studio per scenario
├── integration/
│   ├── studio-protocol/              # category 1 tests (§3.1) — one file per Protocol method
│   ├── meeting-event-stream/         # category 2 tests (§3.2)
│   ├── error-taxonomy/               # category 3 tests (§3.3)
│   ├── vertical-isolation/           # category 4 tests (§3.4)
│   └── fixture-parity/               # category 5 tests (§3.5)
├── tsconfig.json
├── vitest.config.ts                  # extends apps/frontend's config; adds substitution-only globals
└── README.md                         # how to run + interpret failures
```

This is **not** a workspace package; it's a top-level test directory with its own Vitest config so it can be invoked by `pnpm test:substitution` independently of unit tests.

---

## §2 The runner

```typescript
// tests/substitution/runner/runSubstitution.ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { MODES, type SubstitutionMode } from "./modes";
import { startMockStudio, type MockStudio } from "./mockStudioServer";
import { setupVerticals, teardownVerticals } from "./verticalToggle";
import { reportDiff } from "./diffReporter";
import { SUB_TESTS } from "../inventory/subTests";

export interface SubTest {
  id:                string;             // e.g. "t_use_studio_returns_client"
  source_spec:       string;             // e.g. "02-platform-shell-spec.md"
  category:          1 | 2 | 3 | 4 | 5;  // see §3
  description:       string;             // 1 line
  required_vertical?: string;            // null = no vertical needed; or e.g. "investment"
  run(ctx: SubTestContext): Promise<unknown>;     // returns the observable outcome
}

export interface SubTestContext {
  mode:        SubstitutionMode;
  studio:      MockStudio | null;        // null in pseudo mode
  // ... stores, fetch overrides, registered verticals, etc.
}

// For each [SUB] test, run it under both modes and assert outcomes match.
for (const test of SUB_TESTS) {
  describe(`[SUB] ${test.id} (${test.source_spec})`, () => {
    const outcomes: Record<SubstitutionMode, unknown> = {} as any;

    for (const mode of MODES) {
      it(`mode=${mode}`, async () => {
        let mockStudio: MockStudio | null = null;
        if (mode === "http") mockStudio = await startMockStudio();
        if (test.required_vertical) await setupVerticals([test.required_vertical]);
        try {
          outcomes[mode] = await test.run({ mode, studio: mockStudio });
        } finally {
          if (test.required_vertical) await teardownVerticals();
          if (mockStudio) await mockStudio.stop();
        }
      });
    }

    it("pseudo and http produce equivalent outcomes", () => {
      const diff = reportDiff(outcomes.pseudo, outcomes.http);
      if (diff.differs) {
        throw new Error(
          `[SUB] ${test.id} disagrees between modes:\n${diff.formatted}`
        );
      }
      expect(diff.differs).toBe(false);
    });
  });
}
```

**Why one outcome per mode + a third "diff" assertion.** If the test fails inside `mode=pseudo` we know Pseudo is wrong; if it fails in `mode=http` we know Http (or the mock studio) is wrong; if both pass but disagree, the diff assertion fires with a precise field-level report. Diagnostic granularity falls out of the structure.

**Why a generated inventory file.** Each feature/vertical package exports its `[SUB]` tests via a stable barrel (`packages/<pkg>/tests/sub/index.ts`); a small build step (run before substitution tests) regenerates `inventory/subTests.ts` by scanning each package's `package.json` for a `subTests` field that lists the export path. The runner imports the generated file. This avoids the runner having a hand-maintained list (which inevitably drifts).

---

## §3 The 5 categories

Every `[SUB]` test fits into exactly one category. Categories are exhaustive and disjoint.

### §3.1 Category 1 — StudioClient Protocol method substitution

Each public method on the `StudioClient` Protocol (per `01` §6) gets at least one `[SUB]` test that exercises a happy path + each declared error leaf. Pseudo and Http must produce identical DTOs (field-by-field) and identical error types.

**Coverage rule**: every method in `01` §7's 11 sections has ≥ 1 happy-path `[SUB]` row + 1 row per declared error leaf. Total: one substitution-style row per (method × leaf) pair, plus per (method × happy).

### §3.2 Category 2 — Meeting event stream substitution

Tests that stream meeting events (`subscribe_meeting`) and assert:
- Event `seq_no` is strictly monotonic.
- Event payload schemas match `01` §6 frozen schemas exactly.
- Forward-compat unknown event types are passed through (per `01` §5.4).
- Reconnect via `last_seq_no` cursor produces no-loss / no-duplicate behavior.
- Late `meeting_finalized` event triggers correct freeze handling.

### §3.3 Category 3 — Error taxonomy substitution

Each leaf in `01` §8 (the 14-leaf taxonomy mapping the 60+ studio errors) gets a `[SUB]` test that:
- Forces the error in pseudo mode (via fixture flag).
- Forces the same error in http mode (via mock studio response).
- Asserts the same `StudioError` subclass is raised.
- Asserts the same `error.kind` + `error.context` are present.
- Asserts the UI surfaces the same localized message key.

### §3.4 Category 4 — Vertical isolation

Each vertical contribution type (tab, widget, upload handler, data feed, report template, fixture overlay, permission set) gets a `[SUB]` test that:
- Installs vertical A.
- Verifies vertical A's contributions appear (per its manifest).
- Uninstalls vertical A.
- Verifies the platform still boots and other verticals (or the bare-platform empty state) still work.

### §3.5 Category 5 — Fixture parity

Each `[SUB]` test in this category installs a vertical's fixture overlay into pseudo mode AND seeds the mock studio with the equivalent http-shaped data, then exercises the same UI flow. The flow's observable outcome (rendered DOM, store state, navigation) must be identical.

---

## §4 The full `[SUB]` inventory

Source: every `[SUB]`-marked row from specs 01–16. Inventory is generated; this section is the human-readable mirror. Bold rows are the canonical "minimum substitution surface" — if these green, the binding works.

| # | test_id | source spec | category | description |
|---:|---|---|---:|---|
| 1 | **`t_lp_happy`** | 01 §7.1 | 1 | `list_projects` happy path |
| 2 | `t_lp_studio_unavailable` | 01 §7.1 | 1 | `list_projects` raises `StudioUnavailable` on 502 |
| 3 | `t_lp_auth_required` | 01 §7.1 | 1 | `list_projects` raises `AuthRequired` on 401 |
| 4 | **`t_gp_happy`** | 01 §7.2 | 1 | `get_project` happy path |
| 5 | `t_gp_not_found` | 01 §7.2 | 1 | `get_project` raises `ProjectNotFound` |
| 6 | **`t_gpv_happy`** | 01 §7.3 | 1 | `get_project_version` returns DTO matching pinned version |
| 7 | `t_gpv_version_unknown` | 01 §7.3 | 1 | unknown version → `VersionNotFound` |
| 8 | **`t_rm_happy`** | 01 §7.4 | 1 | `run_meeting` returns started `meeting_id` |
| 9 | `t_rm_quota` | 01 §7.4 | 3 | `RateLimited` taxonomy leaf surfaces |
| 10 | `t_rm_invalid_topic` | 01 §7.4 | 3 | `InvalidArgument` leaf |
| 11 | `t_rm_constraint_violation` | 01 §7.4 | 3 | `ConstraintViolation` leaf |
| 12 | **`t_sm_happy`** | 01 §7.5 | 2 | `subscribe_meeting` streams events in seq_no order |
| 13 | `t_sm_reconnect` | 01 §7.5 | 2 | reconnect via last_seq_no produces no-loss/no-dup |
| 14 | `t_sm_unknown_event` | 01 §7.5 | 2 | forward-compat unknown event passes through |
| 15 | `t_sm_late_finalized` | 01 §7.5 | 2 | late `meeting_finalized` freezes the stream |
| 16 | `t_sm_integrity_incident` | 01 §7.5 | 3 | `IntegrityError` leaf surfaces |
| 17 | **`t_lm_happy`** | 01 §7.6 | 1 | `list_meetings` paginates correctly |
| 18 | `t_lm_filters` | 01 §7.6 | 1 | filters (project_id, status, since/until) honored |
| 19 | **`t_gms_happy`** | 01 §7.7 | 1 | `get_meeting_status` returns DTO incl. error_class for failed |
| 20 | **`t_gmo_happy`** | 01 §7.8 | 1 | `get_meeting_outcome` returns full MeetingOutcome |
| 21 | `t_gmo_not_finalized` | 01 §7.8 | 3 | `OutcomeNotReady` leaf when meeting still running |
| 22 | **`t_le_happy`** | 01 §7.9 | 1 | `list_evidence` returns evidence with citations |
| 23 | **`t_gcr_happy`** | 01 §7.10 | 1 | `get_cost_report` returns CostReport (no group_by) |
| 24 | `t_gcr_grouped` | 01 §7.10 | 1 | get_cost_report with group_by=[model_id] returns rows |
| 25 | `t_gcr_filters` | 01 §7.10 | 1 | get_cost_report filters honored |
| 26 | **`t_h_happy`** | 01 §7.11 | 1 | `health` returns live + ready |
| 27 | `t_h_degraded` | 01 §7.11 | 1 | live=true, ready=false → degraded |
| 28 | `t_h_down` | 01 §7.11 | 1 | health unreachable → null |
| 29 | `t_use_studio_returns_client` | 02 §11 hooks | 1 | `useStudio()` returns the configured client at boot |
| 30 | `t_use_studio_health_poll` | 02 §11 hooks | 2 | `useStudioHealth({poll_interval_ms: 100})` polls 3 times in 350 ms |
| 31 | `t_use_studio_health_error` | 02 §11 hooks | 3 | health poll raises `StudioUnavailable` → error set, prior retained |
| 32 | `t_boot_happy` | 02 §11 boot | 1 | full boot completes against pseudo + against http |
| 33 | `t_boot_studio_unreachable` | 02 §11 boot | 3 | studio unreachable at boot → shell renders, indicator red |
| 34 | `t_meeting_stream_subscribe` | 01b §3 | 2 | useMeetingStream subscribes + receives ordered events |
| 35 | `t_meeting_stream_refcount` | 01b §3 | 2 | two consumers refcount up; cleanup on last unsubscribe |
| 36 | `t_outcome_reducer_consensus` | 01b §4.1 | 2 | useOutcomeReducer folds ConsensusReached correctly |
| 37 | `t_dag_state_claim_added` | 01b §4.2 | 2 | useDagState adds nodes on ClaimMade |
| 38 | `t_cost_state_message_emitted` | 01b §4.3 | 2 | useCostState increments tokens on MessageEmitted |
| 39 | `t_provenance_evidence_cited` | 01b §4.4 | 2 | useProvenance records EvidenceCited |
| 40 | `t_agora_open_meeting` | 05 | 1 | opening a meeting URL fetches status + outcome + subscribes stream |
| 41 | `t_agora_consensus_reached` | 05 | 2 | ConsensusReached event updates ConsensusPanel |
| 42 | `t_reports_render_pdf` | 06 | 1 | request PDF render → arrives via fetch+Blob; metadata correct |
| 43 | `t_knowledge_search_paginates` | 07 | 1 | knowledge browser paginates list_meetings |
| 44 | `t_chathub_one_turn` | 08 | 1+2 | one chat turn = one short meeting; events stream + outcome surface |
| 45 | `t_uploads_post_normalized` | 09 | 1 | upload preview → normalize → wizard inlines as Material content |
| 46 | `t_wizard_run_meeting` | 10 | 1 | wizard step Submit calls run_meeting + navigates to /agora/<id> |
| 47 | `t_settings_password_change` | 11 | 3 | invalid_current_password leaf surfaces with localized message |
| 48 | `t_obs_cost_report_grouped` | 12 | 1 | observability cost panel renders get_cost_report result |
| 49 | `t_obs_meeting_volume_paginated` | 12 | 1 | activity panel paginates list_meetings until empty |
| 50 | `t_vt_boot_load` | 13 §11.1 | 4 | vertical loads at boot |
| 51 | `t_vt_absent_isolated` | 13 §11.1 | 4 | absent vertical leaves rest functional |
| 52 | `t_vt_two_coexist` | 13 §11.1 | 4 | two verticals coexist |
| 53 | `t_vt_malformed_isolated` | 13 §11.1 | 4 | malformed manifest does not crash boot |
| 54 | `t_vt_frontend_import_fail` | 13 §11.1 | 4 | failed dynamic import isolated |
| 55 | `t_vt_fixture_load` | 13 §11.3 | 5 | fixture overlay loads into PseudoStudioClient |
| 56 | `t_vt_fixture_meeting` | 13 §11.3 | 5 | fixture's meeting_template fires on run_meeting |
| 57 | `t_vt_fixture_outcome` | 13 §11.3 | 5 | fixture outcome resolves through get_meeting_outcome |
| 58 | `t_inv_boot_load` | 14 §12 | 4 | investment vertical loads at apps/api boot |
| 59 | `t_inv_coexist_with_other` | 14 §12 | 4 | investment coexists with another vertical |
| 60 | `t_inv_remove_isolated` | 14 §12 | 4 | uninstalling investment leaves rest intact |
| 61 | `t_apps_fe_boot_one_vertical` | 16 §9.1 | 1 | apps/frontend boots with 1 vertical against pseudo + http |
| 62 | `t_apps_fe_boot_two_verticals` | 16 §9.1 | 4 | apps/frontend boots with 2 verticals |
| 63 | `t_apps_fe_pseudo_full_path` | 16 §9.6 | 1 | apps/frontend in pseudo mode runs a full meeting flow |
| 64 | `t_apps_fe_http_full_path` | 16 §9.6 | 1 | apps/frontend in http mode runs the same flow |

**Inventory invariants** (enforced by `coverage.ts`):
- Every `[SUB]` test_id mentioned in any spec under specs 01–16 appears in this table.
- Every Protocol method in `01` §7 has at least one row.
- Every error taxonomy leaf in `01` §8 has at least one Category-3 row.
- Every spec listed in §11 of any feature spec ("Downstream impact") that lists `[SUB]` rows produces at least one row here.

If a row appears in a feature spec but is missing from this inventory (or vice versa), the runner's coverage step (per §10) fails CI.

---

## §5 Mocked-studio HTTP server

The http-mode harness stands up a mocked studio server (msw-node-based) that obeys `01-studio-client-spec.md` §6 (the binding API contract — endpoints, request/response schemas, error envelope). The mock is deterministic: same fixtures in → same DTOs out.

```typescript
// tests/substitution/runner/mockStudioServer.ts
import { setupServer } from "msw/node";
import { http, HttpResponse } from "msw";
import { loadStudioFixtures } from "./loaders";

export interface MockStudio {
  baseUrl: string;
  setFixture(path: string, body: unknown): void;
  triggerError(method: string, error: { type: string; status: number; extras?: unknown }): void;
  emitEvent(meeting_id: string, event: { type: string; seq_no: number; data: unknown }): void;
  stop(): Promise<void>;
}

export async function startMockStudio(): Promise<MockStudio> {
  const fixtures = await loadStudioFixtures();
  // ... define handlers per §6 binding (POST /v0.1/projects/list, GET /v0.1/meetings/<id>, ...)
  // ... define SSE stream for /v0.1/meetings/<id>/events that pushes deterministic events
  const server = setupServer(/* handlers */);
  server.listen({ onUnhandledRequest: "error" });
  return {
    baseUrl: "http://mock-studio.local",
    setFixture(path, body) { /* ... */ },
    triggerError(method, error) { /* ... */ },
    emitEvent(meeting_id, event) { /* ... */ },
    async stop() { server.close(); },
  };
}
```

**Why msw-node (not a real HTTP listener).** Tests run in jsdom + Node; msw-node intercepts `fetch` at the network layer without binding to a port (so tests parallelize cleanly). The mock acts as a fake studio adhering to the binding spec — if studio's contract changes in v0.2, only this mock + `01` need updating.

**Why deterministic events (not random).** Substitution requires bit-for-bit equivalence; randomness defeats the diff assertion. Each `meetings/<id>/events` SSE stream replays a fixed event script declared in `fixtures/studio-binding/meeting-events/<id>.ndjson`, mirrored by the equivalent meeting_template in pseudo's fixture overlay (per `01` §10.3). The two paths produce identical event sequences — that's the whole point.

---

## §6 Vertical install/uninstall harness

```typescript
// tests/substitution/runner/verticalToggle.ts
import { useVerticalsStore } from "@entelecheia/platform-shell";
import { discoverAndRegisterVerticals } from "../../../apps/frontend/src/boot/verticals";

const KNOWN_VERTICALS = {
  "investment":         { module: "@entelecheia/vertical-investment/manifest" },
  "vertical-template":  { module: "@entelecheia/vertical-template/manifest"  },
  // add more as new vertical packages ship
};

export async function setupVerticals(ids: string[]): Promise<void> {
  const entries = ids.map(id => ({
    vertical_id: id,
    frontend_module_path: KNOWN_VERTICALS[id as keyof typeof KNOWN_VERTICALS].module,
  }));
  await discoverAndRegisterVerticals(entries, (m) => useVerticalsStore.getState().register(m));
}

export async function teardownVerticals(): Promise<void> {
  useVerticalsStore.getState().reset();
}
```

The harness exercises the same code path the apps/frontend uses at boot (per `16` §4). Tests can install one vertical, two verticals, no verticals — and the inventory's Category-4 rows iterate through these combinations.

**Why tests use the production discovery path (not a mock).** The point of substitution is to verify the production path; mocking it would test the mock. The harness only differs from prod in *which* verticals it installs (test-controlled) — not *how* they're discovered + registered.

---

## §7 Pass criteria

The substitution suite passes IFF:

1. Every `[SUB]` test in §4 runs to completion under both `mode=pseudo` and `mode=http`.
2. The diff reporter (§8) reports `differs=false` for every test.
3. The coverage check (§10) reports zero gaps:
   - No Protocol method without a happy-path row.
   - No error taxonomy leaf without a Category-3 row.
   - No `[SUB]` test_id mentioned in a feature spec but absent from §4.
4. CI step `substitution-tests` exits 0.

Any failure causes CI to fail and blocks merge.

---

## §8 Diff reporter

```typescript
// tests/substitution/runner/diffReporter.ts
import { diff as deepDiff } from "structured-diff";    // or a small in-tree implementation

export interface DiffResult {
  differs:   boolean;
  formatted: string;        // multi-line; pseudo on left, http on right
}

export function reportDiff(pseudo: unknown, http: unknown): DiffResult {
  // 1. If both are arrays of meeting events, compare event-by-event with field highlighting.
  // 2. If both are DTOs, compare field-by-field; report extra / missing / changed fields.
  // 3. If both are errors, compare class name + kind + context.
  // 4. Format as pseudo │ http columns with ✓ / ✗ markers per field.
  // ... implementation
  return { differs: false, formatted: "" };
}
```

Sample output when a field disagrees:

```
[SUB] t_gms_happy disagrees:

  meeting_id           │ "m-abc123"               │ "m-abc123"               ✓
  status               │ "completed"              │ "completed"              ✓
  started_at           │ "2026-04-22T10:00:00Z"   │ "2026-04-22T10:00:00.000Z" ✗
  total_turns          │ 8                        │ 8                        ✓
  error_class          │ null                     │ null                     ✓

Hint: pseudo emits ISO without milliseconds; http includes them.
Fix: align both formats to RFC 3339 with millisecond precision (per 01 §5.1 timestamp rule).
```

**Why the diff is structured (not a string compare).** A naive `expect(pseudo).toEqual(http)` produces an unreadable wall of JSON when many fields differ. The structured diff names the path of each disagreement + provides a one-line hint, turning failures into fix-able tickets.

---

## §9 CI integration

```yaml
# .github/workflows/ci.yml (excerpt)
substitution-tests:
  runs-on: ubuntu-latest
  needs: [scaffolding-check, frontend-tests]
  if: needs.scaffolding-check.outputs.has_frontend == 'true'
  steps:
    - uses: actions/checkout@v4
    - uses: pnpm/action-setup@v3
    - uses: actions/setup-node@v4
      with: { node-version: 20, cache: 'pnpm' }
    - run: pnpm install --frozen-lockfile
    - run: pnpm --filter ./tests/substitution test:substitution
    - if: failure()
      uses: actions/upload-artifact@v4
      with:
        name: substitution-diff-report
        path: tests/substitution/.diff-report.txt
```

**Gate**: `substitution-tests` is required for merge. The job runs after `frontend-tests` (so unit failures surface first) and after `scaffolding-check` (gate per project's existing CI per `15-apps-api-spec.md` §boot).

---

## §10 Per-spec coverage gate

Each spec that introduces `[SUB]` rows is expected to declare them in its §11 (Downstream impact) row pointing to spec 17. The runner's coverage step:

1. Greps all `docs/specs/v0.1/*.md` for `\[SUB\] (t_[a-z0-9_]+)`.
2. Builds the union set.
3. Compares against §4's table.
4. Fails CI if either set has entries the other lacks.

This is not a sophisticated parser — the deliberate coupling to a marker convention keeps the gate simple + verifiable.

---

## §11 Test matrix (the runner itself)

The runner must itself be tested. These rows verify the harness, NOT the substitution behavior of features:

| scenario | expected | test_id |
|---|---|---|
| both modes pass + agree | one [SUB] suite green | `t_runner_both_modes_agree` |
| pseudo passes, http fails | runner reports per-mode failure (Http side) | `t_runner_http_only_fail` |
| both pass but disagree | diff assertion fires with structured output | `t_runner_disagreement_diff` |
| no fixture for required vertical | runner marks the [SUB] test as setup-failure (not pass) | `t_runner_missing_vertical_setup` |
| coverage gap | spec mentions [SUB] t_x but inventory missing → CI fails | `t_runner_coverage_gap_spec_to_inventory` |
| inverse coverage gap | inventory has t_y but no spec mentions it → CI fails | `t_runner_coverage_gap_inventory_to_spec` |
| Protocol method without happy-path SUB | coverage fails | `t_runner_missing_method_happy` |
| Taxonomy leaf without category-3 SUB | coverage fails | `t_runner_missing_leaf_cat3` |
| mock studio rejects unhandled request | runner exposes the mismatched call site | `t_runner_unhandled_request` |
| diff reporter handles arrays of events | per-event formatting | `t_runner_diff_event_array` |
| diff reporter handles DTOs | per-field formatting | `t_runner_diff_dto_fields` |
| diff reporter handles errors | class + kind + context formatting | `t_runner_diff_error` |

---

## §12 Why this design — load-bearing decisions

**Why one substitution suite (not per-package).**
The contract being substituted is the platform's, not any single package's. Splitting per-package would multiply harness boilerplate + fragment coverage. One central suite + one runner + one coverage table is the lowest-overhead way to make P6's "Pseudo and Http are interchangeable" provable.
*Considered and rejected.* **Per-package substitution sub-suites** — each package writes its own runner; coverage table impossible.

**Why the inventory is generated, not hand-written.**
Hand-maintained lists drift. The generator scans each package's barrel export of `[SUB]` tests; the coverage step closes the loop. If a feature adds a `[SUB]` test, it auto-registers; if a feature removes one, it auto-disappears. The §4 table in this spec is regenerated on commit (pre-commit hook).
*Considered and rejected.* **Hand-maintained inventory** — drift guaranteed.

**Why msw-node for the mocked studio (not a real HTTP server).**
msw-node intercepts fetch at the network layer; tests run in jsdom + Node without port binding (so they parallelize). A real server is overkill for v0.1 and adds port-allocation flakiness.
*Considered and rejected.* **Real HTTP server (express)** — port allocation; slower setup. **In-process JS function calls** — bypasses the actual HTTP path; doesn't catch URL/header/serialization bugs.

**Why deterministic event scripts (not snapshots).**
Snapshot testing of event streams is brittle: any event_id reshuffle or seq_no rebase invalidates the snapshot, requiring "approve all" flows that drift quality. Deterministic scripts (declared in fixtures, mirrored across pseudo + http) test the contract directly: did pseudo emit the same script as http?
*Considered and rejected.* **Snapshot of one mode, replayed in the other** — couples test code to a single mode.

**Why a structured diff (not `toEqual`).**
`toEqual` produces unreadable JSON dumps when DTOs disagree. A field-named diff with hints turns failures from "what changed?" into "fix this field, here's why."
*Considered and rejected.* **Vitest's built-in diff** — usable but not enough for nested arrays of events; this suite often compares 30+ events.

**Why the runner uses the production vertical-discovery code (not a mock).**
The point of category-4 tests is to verify that the production discovery path works under install/uninstall. Mocking it would test the mock. Tests differ from prod only in *which* verticals they install.
*Considered and rejected.* **Stubbed registerVertical** — tests stop testing the actual integration.

**Why the coverage gate is a grep + set-diff (not an AST parser).**
The marker convention (`[SUB] t_xxx`) is a single literal. A grep is honest about what it does; an AST parser pretends to understand more than it does, then breaks on Markdown edge cases. The convention is enforced socially + by reviewer; the grep enforces mechanically.
*Considered and rejected.* **Markdown-AST coverage** — overkill.

**Why category 4 tests live alongside categories 1-3 (not in a separate suite).**
Vertical install/uninstall is a substitution: replace "no vertical" with "vertical X installed" and assert observable behavior. Same harness, same diff logic, same runner. Splitting would multiply runtime + reduce shared invariants.
*Considered and rejected.* **A dedicated vertical-isolation suite** — same code twice.

**Why CI gates merges on this suite.**
A breaking change to the studio contract or to a vertical's manifest shape should fail loudly in CI, not silently in production. The substitution suite is the single CI gate that catches "we changed the binding without updating one side." Without the gate, drift accumulates.
*Considered and rejected.* **Optional / advisory** — drift accumulates.

**Why no performance comparison in v0.1.**
Pseudo is in-memory (microseconds); http hits a mocked server (milliseconds). Comparing throughput would be misleading + adds noise to the diff signal. Performance lives in operational runbooks, not the substitution suite.
*Considered and rejected.* **Latency assertions** — out of scope; correctness first.

**Why no fault injection in v0.1.**
Random latency, dropped events, partial responses — all are valuable, all are v0.2 work. v0.1 needs the literal `[SUB]` rows green first; chaos before correctness is wasted effort.
*Considered and rejected.* **Chaos in v0.1** — premature; correctness first.

**Why this suite is a top-level dir (not under packages/).**
It depends on every package; placing it under packages/ would require declaring it as a package depending on every workspace member, which loops the dependency graph. Top-level + its own vitest config + own tsconfig keeps it independent of the workspace's package conventions.
*Considered and rejected.* **`packages/substitution-tests/`** — dependency-graph cycle.

---

## §13 Downstream impact

| Spec | Adjustment |
|---|---|
| `01-studio-client-spec.md` | Every Protocol method's `[SUB]` rows referenced here; fixture binding (§10) must mirror the §6 binding shape so categories 1+2 produce identical outputs. |
| `01b-product-derivations-spec.md` | Reducer hooks each get one Category-2 `[SUB]` row (events → state). |
| `02-platform-shell-spec.md` | `useStudioHealth` polling + boot's `[SUB]` rows referenced. The shell's `useVerticalsStore.register()` is exercised by the verticalToggle harness. |
| `13-vertical-template-spec.md` | The 5 Category-4 + 3 Category-5 rows from §11 become the template's substitution surface. |
| `14-vertical-investment-spec.md` | The 3 `[SUB]` rows from §12 (boot_load, coexist, remove) join Category 4. |
| `15-apps-api-spec.md` | apps/api's boot must register the same verticals + serve the same `/api/platform/verticals` shape under both test fixtures and live mode. |
| `16-apps-frontend-spec.md` | apps/frontend's `[SUB]` rows from §9.1 + §9.6 are part of category 1 + 4. |
| `18-end-to-end-scenarios-spec.md` | Some e2e scenarios are also `[SUB]`; they appear in §4 here AND drive the workflow tests in 18. |
| Every future feature/vertical spec | MUST add `[SUB]` rows for any new Protocol method consumption + any new vertical contribution; coverage gate enforces. |

---

## §14 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (cross-version sub, property-based, snapshots, cross-vertical interaction)
- [ ] Module layout (§1) shows `tests/substitution/` as top-level dir with runner / inventory / fixtures / integration / vitest config
- [ ] Runner (§2) iterates each `[SUB]` test under both modes + a third diff assertion
- [ ] 5 categories (§3) defined exhaustively + disjointly; each maps every existing `[SUB]` row to exactly one
- [ ] Inventory (§4) lists all 60+ `[SUB]` rows from specs 01–16; each row has id / source / category / description; bold rows = canonical minimum
- [ ] Mocked-studio server (§5) is msw-node based; obeys `01` §6 binding; deterministic event scripts
- [ ] Vertical toggle (§6) uses production discoverAndRegisterVerticals path
- [ ] Pass criteria (§7) explicit + 4 conditions enumerated
- [ ] Diff reporter (§8) is structured; sample output included
- [ ] CI integration (§9) defines `substitution-tests` job that gates merge
- [ ] Coverage gate (§10) is grep-based + bidirectional
- [ ] Test matrix for the runner itself (§11): ≥ 12 rows
- [ ] Why-this / why-not (§12) for ≥ 11 load-bearing decisions
- [ ] Downstream impact (§13) lists every spec affected
- [ ] No business / domain / product / agent-role string literals (uses neutral test_id examples + per the philosophy skill, "investment" + "vertical-template" are allowed inside test fixtures because they are vertical_ids referenced in test data)
- [ ] No `from entelecheia` / `import entelecheia` (Red Line #1)
- [ ] No `try { ... } catch { /* swallow */ }` patterns (Red Line #8)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/17-substitution-tests-spec.md`
