# 00 — v0.1 cross-spec consistency report

> **Status**: snapshot taken 2026-05-03 after spec 18 landed. Records the 7 cross-spec checks performed against `docs/specs/v0.1/01..18-*.md` plus their findings + remediation outcomes. Not a contract; an audit log.
> **Successor**: a `consistency-check` CI job (proposed in §6) keeps these invariants alive going forward.

---

## §1 What was checked

| # | Check | Method | Universe |
|---:|---|---|---|
| 1 | `[SUB]` test_id inventory in spec 17 §4 ↔ actual `[SUB]` tokens in specs 01–16 + 18 | `grep -oE '\[SUB\] (t_[a-z0-9_]+)'` and set-diff | 19 specs |
| 2 | `data-testid` contracts demanded by spec 18 §11 ↔ declarations in feature/vertical specs | `grep -nE 'data-testid\|getByTestId'` per spec | 19 specs |
| 3 | i18n key namespace consistency (`feature.<x>.*`, `vertical.<id>.*`) | `grep -oE '"feature\.[a-z_]+\.'` + `grep -oE '"vertical\.[a-z_-]+\.'` | 19 specs |
| 4 | Permission code format `<scope>:<verb>` (snake_case verb) | `grep -oE '"[a-z][a-z0-9_-]*:[A-Za-z][A-Za-z0-9_]*"'` | 19 specs |
| 5 | Frontend dependency version consistency | extract `package.json` snippets in 16 vs. mentions in 12 / 14 / 17 / 18 | 5 specs |
| 6 | Studio `StudioClient` Protocol method coverage in spec 17 §4 | `grep -nE 'async def [a-z_]+\('` against spec 01 vs §4 references | 2 specs |
| 7 | `ProjectSpec.spec_id` references vs declarations in fixture overlays | `grep -oE 'spec_id: \[a-zA-Z0-9_-\]+'` vs `grep -oE '"(investment-…\|chat-…\|proj-…)"'` | 19 specs |

---

## §2 Findings summary

| # | Finding | Severity | Decision |
|---:|---|---|---|
| F1 | Spec 17 §4 inventory has 53 fabricated test_ids + omits 64 real ones | **HIGH** | Regenerate §4 from grep; align with reality |
| F2 | Spec 17 references 2 non-existent Protocol methods (`list_evidence`, `get_project_version`); omits `list_agents` + `get_agent` entirely | **HIGH** | Folded into F1's regeneration |
| F3 | Specs 05 (agora) and 14 (investment) declare zero `data-testid` though spec 18 §11 demands them | **MED** | Add explicit `data-testid` contract sections; backed by spec 18 POM listing |
| F4 | Spec 02 §11 uses example namespace `vertical.v_a.tab.x` with underscore (production verticals all use hyphen-style ids) | **LOW** | Change illustrative example to `vertical.v-a.tab.x` for consistency with §13's regex `^[a-z][a-z0-9_-]*$` and 13/14 actuals |
| ✓ | Permission code format consistent across all real codes (`<scope>:<snake_case_verb>`); `node:path` and `test:watch` are import-path / pnpm-script false positives | clean | no action |
| ✓ | Frontend dep versions: spec 16 has the canonical declaration; no other spec re-declares versions | clean | no action |
| ✓ | All `project_id` references resolve to declared `spec_id`s; no orphan references | clean | no action |
| ✓ | i18n `feature.*` namespaces are unique per feature (no cross-feature collision) | clean | no action |

**Net**: 4 findings, 2 HIGH + 1 MED + 1 LOW. Remediation is a single tightly-scoped commit per finding (4 commits total) plus the report itself.

---

## §3 F1 + F2 — spec 17 inventory drift (HIGH)

### Evidence

```
86 [SUB] test_ids declared in specs 01-16+18
76 [SUB] test_ids listed in spec 17 §4
overlap:           22  (one canonical name on both sides)
spec-only:         64  (real, missing from inventory)
inventory-only:    53  (fabricated; would never run)
```

### Drift breakdown by spec-only test_ids (the 64 missing)

| prefix | count | corresponds to spec 01 §7 method | example |
|---|---:|---|---|
| `t_lp_*` | 5 | §7.1 list_projects | `t_lp_default`, `t_lp_paging`, `t_lp_archived`, `t_lp_invalid_limit`, `t_lp_studio_down` |
| `t_gp_*` | 5 | §7.2 get_project | `t_gp_latest`, `t_gp_pinned`, `t_gp_invalid_version`, `t_gp_version_not_found` |
| `t_la_*` | 3 | §7.3 list_agents | `t_la_default`, `t_la_paging`, `t_la_invalid_limit` |
| `t_ga_*` | 3 | §7.4 get_agent | `t_ga_latest`, `t_ga_pinned`, `t_ga_not_found` |
| `t_rm_*` | 5 | §7.5 run_meeting | `t_rm_pinned_version`, `t_rm_empty_topic`, `t_rm_not_found`, `t_rm_not_published` |
| `t_lm_*` | 4 | §7.6 list_meetings | `t_lm_paging`, `t_lm_by_project`, `t_lm_by_status`, `t_lm_since` |
| `t_gms_*` | 4 | §7.7 get_meeting_status | `t_gms_running`, `t_gms_completed`, `t_gms_failed`, `t_gms_not_found` |
| `t_sm_*` | 8 | §7.8 subscribe_meeting | `t_sm_from_start`, `t_sm_from_cursor`, `t_sm_reconnect_dedup`, `t_sm_failed_terminates`, `t_sm_finalized`, `t_sm_unknown_type_forward_compat`, `t_sm_heartbeat_strip`, `t_sm_not_found` |
| `t_gmo_*` | 4 | §7.9 get_meeting_outcome | `t_gmo_running`, `t_gmo_completed`, `t_gmo_failed`, `t_gmo_not_found` |
| `t_gcr_*` | 7 | §7.10 get_cost_report | `t_gcr_empty`, `t_gcr_project`, `t_gcr_meeting`, `t_gcr_group_user`, `t_gcr_group_multi`, `t_gcr_invalid_group` |
| `t_gsh_*` | 4 | §7.11 get_studio_health | `t_gsh_healthy`, `t_gsh_live_not_ready`, `t_gsh_down`, `t_gsh_version_drift` |
| `t_mss_*` | 9 | §3 (01b useMeetingStream registry) | `t_mss_first_subscribe_live`, `t_mss_first_subscribe_completed`, `t_mss_late_join`, `t_mss_transient_drop`, `t_mss_cursor_lost`, `t_mss_failed`, `t_mss_finalized`, `t_mss_meeting_id_change`, `t_mss_refcount_close` |
| `t_vt_*` | 8 | §11 (vertical template) | `t_vt_boot_load`, `t_vt_absent_isolated`, … |
| `t_ep_*` | 2 | spec 15 (apps/api event proxy) | `t_ep_sse_live`, `t_ep_sse_reconnect` |
| `t_av_*` | 1 | spec 12 observability | `t_av_forward_compat_event` |
| `t_studio_*` | 2 | spec 01 §10.4 swap | `t_studio_swap_pseudo`, `t_studio_swap_http_v01_stub` |

### Inventory-only test_ids (the 53 fabricated)

Categorized by why they're wrong:

- **References methods that don't exist** (4 rows): `t_le_happy`, `t_gpv_happy`, `t_gpv_version_unknown` — spec 01 has `get_project(version=...)`, not `get_project_version`; spec 01 has no `list_evidence` method at all.
- **Made-up "happy" suffixes** (~30 rows): `t_lp_happy`, `t_gp_happy`, `t_h_happy`, `t_gms_happy`, `t_gmo_happy`, etc. The actual specs use `_default` / `_latest` / `_running` / `_completed` / `_healthy` for happy paths — never `_happy`.
- **Made-up high-level names** (~10 rows): `t_agora_open_meeting`, `t_chathub_one_turn`, `t_reports_render_pdf`, `t_knowledge_search_paginates`, `t_uploads_post_normalized`, `t_wizard_run_meeting`, `t_settings_password_change`, `t_obs_*`, `t_meeting_stream_*`, `t_outcome_reducer_consensus`, `t_dag_state_claim_added`, `t_cost_state_message_emitted`, `t_provenance_evidence_cited`. None of these test_ids appear in any feature spec.
- **Runner self-tests misclassified** (12 rows): `t_runner_*` belong in spec 17 §11 (the harness's own test matrix), not §4 (the [SUB] inventory).
- **Uncategorized leakage**: `t_h_degraded`, `t_h_down`, `t_lp_studio_unavailable`, `t_lp_auth_required`, `t_lm_filters` — nominally plausible but invented names.

### Root cause

I wrote spec 17 §4 by hand as a "canonical inventory" without grepping the actual feature specs first. Spec 17 §10 explicitly says the inventory should be **generated** by `tests/substitution/runner/coverage.ts` from a grep of `\[SUB\] (t_[a-z0-9_]+)`. The hand-written §4 violated its own §10 generation rule.

### Decision

**Regenerate spec 17 §4 from the grep**, replacing the 76-row hand list with the 86 real `[SUB]` rows organized by category (per §3 of 17). Drop the 4 fabricated-method rows. Move the runner self-tests where they belong (already in §11; just remove from §4). Add a short note at top of §4 confirming "this table is regenerated; the source of truth is the grep over `docs/specs/v0.1/*.md`."

---

## §4 F3 — `data-testid` contracts (MED)

### Evidence

Spec 18 §4 (Page Object Model) and §5 (scenarios) reference these `data-testid` values:

| Demanded by spec 18 | Owner spec | Currently declared? |
|---|---|---|
| `agora-header`, `agora-status-pill`, `agora-consensus-panel`, `agora-dag`, `agora-cost-panel` | spec 05 | **NO** |
| `event-card-claim-{id}`, `consensus-claim-{id}` | spec 05 | **NO** |
| `vertical-investment-market-watch-row` (per §11 demand) | spec 14 | **NO** |
| settings password fields (form input names) | spec 11 | implicit via input `name` attrs |
| reports template/format pickers | spec 06 | implicit via radio role + name |

`grep -nE 'data-testid|getByTestId' docs/specs/v0.1/05-feature-agora-spec.md` → 0 matches.
`grep -nE 'data-testid|getByTestId' docs/specs/v0.1/14-vertical-investment-spec.md` → 0 matches.

### Decision

Add a short `§N+1 Test-ID contract` subsection to:

- **Spec 05** — listing the 7 `agora-*` test_ids + the 2 templated `event-card-claim-{id}` / `consensus-claim-{id}` patterns. Components ship `data-testid` per this section.
- **Spec 14** — listing `vertical-investment-market-watch-row` + `vertical-investment-portfolio-row` (a parallel one for the portfolio table, since scenario 18-Settings + 18-Observability paths likely need it).

These are 1-table additions, not architectural. Remaining feature specs (06/08/11/12) get the same treatment as a follow-up if e2e scenarios start failing on missing locators.

**Why not via convention** (e.g., "every component MUST add `data-testid={name}`"). A blanket rule produces noise (test_ids on every `<div>`); demand-driven declaration (only what spec 18 actually targets) keeps the test_id surface meaningful.

---

## §5 F4 — `vertical.v_a.*` namespace example (LOW)

### Evidence

`docs/specs/v0.1/02-platform-shell-spec.md` line 951:

```
| i18n vertical bundle | vertical merged keys | `t("vertical.v_a.tab.x")` returns vertical's value | `t_i18n_vertical_namespace` |
```

The `v_a` underscore-style identifier is valid per spec 13 §9 regex `^[a-z][a-z0-9_-]*$`, but every production vertical (template, investment) uses hyphen-style. Mixed conventions in illustrative examples create cognitive overhead.

### Decision

Change to `vertical.v-a.tab.x` for consistency with `vertical-template` / `investment` style. One-character edit; cosmetic.

---

## §6 Going-forward gate (proposed CI job)

```yaml
# .github/workflows/ci.yml (excerpt — to be added)
consistency-check:
  runs-on: ubuntu-latest
  needs: scaffolding-check
  steps:
    - uses: actions/checkout@v4
    - name: SUB inventory bidirectional
      run: |
        grep -hoE '\[SUB\] (t_[a-z0-9_]+)' docs/specs/v0.1/0[1-9]*.md docs/specs/v0.1/1[0-689]*.md docs/specs/v0.1/01b-*.md | sort -u > /tmp/in_specs.txt
        grep -oE '`(t_[a-z0-9_]+)`' docs/specs/v0.1/17-substitution-tests-spec.md | tr -d '`' | sort -u > /tmp/in_17.txt
        if ! diff -q /tmp/in_specs.txt /tmp/in_17.txt > /dev/null; then
          echo "::error::SUB inventory drift between specs and 17 §4"
          diff /tmp/in_specs.txt /tmp/in_17.txt
          exit 1
        fi
    - name: data-testid demands satisfied
      run: |
        # extract test-ids spec 18 calls getByTestId on
        grep -oE 'getByTestId\("([a-z][a-z0-9-]+)"\)' docs/specs/v0.1/18-end-to-end-scenarios-spec.md | grep -oE '"[^"]+"' | tr -d '"' | sort -u > /tmp/demanded.txt
        # check each appears at least once in feature/vertical specs
        for tid in $(cat /tmp/demanded.txt); do
          if ! grep -lE "$tid" docs/specs/v0.1/0[5-9]*.md docs/specs/v0.1/1[0-4]*.md > /dev/null; then
            echo "::error::data-testid '$tid' demanded by 18 but not declared in any feature/vertical spec"
            exit 1
          fi
        done
    - name: ProjectSpec spec_id references resolve
      run: |
        grep -hoE 'spec_id: ([a-zA-Z0-9_-]+)' docs/specs/v0.1/*.md | awk '{print $2}' | sort -u > /tmp/declared.txt
        # extract project_id_in references (rough)
        grep -hoE '"(investment-[a-z-]+|chat-[a-z-]+|proj-[a-z-]+)"' docs/specs/v0.1/*.md | tr -d '"' | sort -u > /tmp/referenced.txt
        for ref in $(cat /tmp/referenced.txt); do
          if ! grep -qF "$ref" /tmp/declared.txt; then
            echo "::error::project_id '$ref' referenced but not declared in any fixture overlay"
            exit 1
          fi
        done
```

This job is doc-only (paths-include the docs/specs/v0.1/* paths; gated by the existing scaffolding-check). Catches drift on every PR that touches a spec.

---

## §7 Remediation plan + sequencing

| step | action | spec(s) touched | LOC delta | commit |
|---:|---|---|---:|---|
| 1 | Land this report (00-consistency-report.md) | new file | +~250 | `docs(spec): consistency audit report — 4 findings` |
| 2 | Regenerate spec 17 §4 from grep (F1 + F2) | 17 | ~-30 / +50 | `docs(spec): 17 — regenerate SUB inventory from real grep` |
| 3 | Add data-testid contract sections (F3) | 05, 14 | +~30 each | `docs(spec): 05+14 — declare data-testid contract demanded by 18` |
| 4 | Cosmetic namespace fix (F4) | 02 | ±1 | `docs(spec): 02 — vertical.v_a.* example → vertical.v-a.* (cosmetic)` |
| 5 | Add `consistency-check` CI job (§6) | .github/workflows/ci.yml | +~30 | `ci: add consistency-check job to gate spec drift` |

Total: 5 commits, all doc/CI only, no code, no architectural change.

---

## §8 What was NOT checked (deferred)

- **Cross-spec timestamp / cursor / opaque-id format consistency** — would require parsing every DTO definition.
- **Cross-spec error taxonomy leaf coverage** — partially covered by F1/F2 (every leaf in spec 01 §8 should produce a category-3 SUB row); will be enforced by the regenerated spec 17 §4 + the CI gate above.
- **Spec word count / structure linting** — covered by the writing-product-specs skill's Pre-commit checklist; reviewer-enforced.
- **Cross-spec section numbering consistency** (e.g., does every spec have §10 "Why this design"? Yes by skill convention; not mechanically checked).

---

## §9 Sign-off

Reviewed by: pending.
Findings to address: F1, F2, F3, F4 — all REMEDIABLE doc-only edits.
After steps 1–5 land, the v0.1 spec batch is **consistency-clean** and ready for path B (workspace scaffolding) + path C (implementation).
