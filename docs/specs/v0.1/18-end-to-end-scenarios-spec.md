# 18 — end-to-end scenarios v0.1 spec

> **Status**: v0.1 contract for the end-to-end (e2e) test scenarios.
> **Lives at**: `tests/e2e/` (top-level repo dir; not a package).
> **Consumes**: every prior spec; this is the integration proof that they compose.
> **Depends on**: `16-apps-frontend-spec.md` (the running app); `15-apps-api-spec.md` (the FastAPI surface); `17-substitution-tests-spec.md` (e2e scenarios marked `[SUB]` are also run by the substitution runner).

---

## Mission

This file defines the end-to-end test suite — the runnable proof that a real user can sign in, switch verticals, run a meeting, watch deliberation in agora, render a report, browse past meetings via knowledge, chat 1:1 via chathub, change preferences in settings, and inspect cost in observability **as a single coherent product**, with the platform shell + features + verticals composing without friction. Each scenario is a concrete user journey with explicit Given/When/Then steps, a stable test_id, and a determination of whether it runs only in pseudo mode (default) or both modes (when `[SUB]`-tagged per `17`).

**Hard rule** (P6 + the spec's reason for existing): the e2e suite is the **acceptance gate for v0.1**. If every e2e scenario passes, the product ships. If any scenario fails, the failure is real (not a flaky test, not a missing fixture) — every scenario uses deterministic fixtures + the production app shell + the production apps/api. The suite catches integration breaks that unit + substitution tests cannot: cross-feature workflows, cross-package i18n drift, real router navigation, real DOM state, real SSE streams.

---

## Scope

**Covers.**
- The e2e test framework choice (Playwright; rationale in §10).
- Module layout under `tests/e2e/`.
- 18 concrete e2e scenarios (§5) covering every feature area + every cross-feature handoff:
  - 5 platform-shell scenarios (login, switcher, theme/locale, permissions, notifications)
  - 4 deliberation-flow scenarios (wizard → agora → reports)
  - 3 chathub scenarios (1:1 chat lifecycle)
  - 2 knowledge browser scenarios
  - 2 uploads scenarios
  - 1 settings scenario (password change)
  - 1 observability scenario (cost dashboard)
- Per-scenario: title, tags (`[SUB]` / `[SMOKE]` / `[CRITICAL]`), preconditions, steps (Given/When/Then), assertions, error-path variants, test_id.
- The shared fixture set (§3) — auth users, vertical activations, seeded studio fixtures.
- Page object model (§4) — one `Page` class per route the scenarios visit.
- Pass criteria + flake policy (§7).
- CI integration (§8) — the e2e job runs after substitution-tests; smoke subset gates PRs, full suite runs nightly.
- v0.2 forward-compat: as new features ship, scenarios extend additively; the framework + PO model don't change.

**Does not cover.**
- Component-level testing — owned by per-feature spec test matrices.
- Substitution testing — owned by `17-substitution-tests-spec.md`. E2e scenarios marked `[SUB]` are also re-run by the substitution runner; that's a meta-relationship, not an obligation imposed by this spec.
- Performance / load testing — out of scope (operational runbooks).
- Visual regression testing — Playwright supports it but v0.1 doesn't ship per-pixel baselines. v0.2 may add for critical screens.
- Accessibility audits — manual reviews + axe-in-CI deferred to v0.2.
- Mobile e2e — desktop only in v0.1 per most feature specs' "out of scope" lists; mobile responsive is render-only checked in unit tests.

**Out of scope for v0.1.**
- Multi-user concurrent scenarios (two users editing portfolio simultaneously). Single-user flows only in v0.1.
- Multi-tab scenarios (open meeting in tab A, browse knowledge in tab B). Single-tab in v0.1.
- Browser-back-button regression suite (relies on router state we trust in v0.1; v0.2 may explicitly cover).
- Real network conditions (slow 3G, offline). Tests run on dev-server; production shell is internal-only.
- Full localization audit (every key in every locale). Spot-checks per scenario; full audit is a separate translation QA pass.

---

## §1 Module layout

```
tests/e2e/
├── playwright.config.ts             # browsers, base URL, fixture loader, retries=2 in CI
├── fixtures/
│   ├── auth/                        # seeded users with permission combos
│   │   ├── admin.json               # all permissions; for full-suite scenarios
│   │   ├── basic.json               # platform:run_meeting + investment:* but no observability
│   │   └── readonly.json            # platform:list_projects only; for permission-deny tests
│   ├── studio/                      # studio-binding fixtures loaded by apps/api in test mode
│   │   └── (mirrors tests/substitution/fixtures/studio-binding/)
│   └── verticals/                   # per-vertical fixture overlays activated per scenario
├── pages/                           # Page Object Model: one .ts per route
│   ├── LoginPage.ts
│   ├── DashboardPage.ts
│   ├── WizardPage.ts
│   ├── AgoraPage.ts
│   ├── ReportsPage.ts
│   ├── KnowledgePage.ts
│   ├── ChathubPage.ts
│   ├── UploadsPage.ts
│   ├── SettingsPage.ts
│   └── ObservabilityPage.ts
├── helpers/
│   ├── seedFixtures.ts              # POST /test/seed (only enabled in test mode)
│   ├── auth.ts                      # login(user) helper
│   ├── waitForEvent.ts              # waits for SSE event matching predicate
│   └── timeBox.ts                   # bounded waits with explicit error messages
├── scenarios/
│   ├── 01-login-and-dashboard.spec.ts
│   ├── 02-vertical-switcher.spec.ts
│   ├── 03-theme-and-locale.spec.ts
│   ├── 04-permission-deny.spec.ts
│   ├── 05-notifications-bell.spec.ts
│   ├── 06-deliberation-happy-path.spec.ts
│   ├── 07-deliberation-with-uploads.spec.ts
│   ├── 08-deliberation-failed-meeting.spec.ts
│   ├── 09-deliberation-report-render.spec.ts
│   ├── 10-chathub-single-turn.spec.ts
│   ├── 11-chathub-multi-turn-history.spec.ts
│   ├── 12-chathub-rate-limited.spec.ts
│   ├── 13-knowledge-browse-and-filter.spec.ts
│   ├── 14-knowledge-open-past-meeting.spec.ts
│   ├── 15-uploads-platform-handler.spec.ts
│   ├── 16-uploads-vertical-handler.spec.ts
│   ├── 17-settings-password-change.spec.ts
│   └── 18-observability-cost-overview.spec.ts
└── README.md                        # how to run + flake policy
```

**Why `tests/e2e/` is a top-level dir (not a package).** Same reason as `17`'s `tests/substitution/` — it depends on every package, and Playwright runs against the built app, not against the source. Top-level keeps the dependency graph clean.

---

## §2 Test mode wiring

E2e tests run against the real app in a "test mode" that:

1. **apps/api** boots with `ENT_PRODUCT_TEST_MODE=1` which:
   - Mounts a `POST /test/seed` endpoint that resets the auth-service users + user-prefs + (if pseudo) reloads fixture overlays. Idempotent.
   - Disables rate-limit middleware (per `15` §middleware) so deterministic flows aren't throttled.
   - Forces `ENT_STUDIO_CLIENT_MODE=pseudo` by default; e2e CI also runs the `[SUB]` subset in `mode=http` against a stand-up of the substitution mock studio (per `17` §5).

2. **apps/frontend** is built with `VITE_STUDIO_CLIENT_MODE=pseudo` for the default e2e run, `=http` for the substitution variant.

3. **Playwright** boots both servers via `webServer` in `playwright.config.ts`:
   - apps/api on `:8000`
   - apps/frontend dev server on `:5173`
   - Browsers point at `http://localhost:5173/`.

```typescript
// tests/e2e/playwright.config.ts
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./scenarios",
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? [["html"], ["github"]] : [["list"]],
  use: {
    baseURL: "http://localhost:5173",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    { name: "chromium-pseudo", use: { ...devices["Desktop Chrome"] } },
    // chromium-http only when --grep [SUB] (the substitution variant)
  ],
  webServer: [
    {
      command: "ENT_PRODUCT_TEST_MODE=1 ENT_STUDIO_CLIENT_MODE=pseudo pnpm --filter ./apps/api dev",
      url: "http://localhost:8000/healthz",
      timeout: 60_000,
      reuseExistingServer: !process.env.CI,
    },
    {
      command: "VITE_STUDIO_CLIENT_MODE=pseudo pnpm --filter ./apps/frontend dev",
      url: "http://localhost:5173/",
      timeout: 60_000,
      reuseExistingServer: !process.env.CI,
    },
  ],
});
```

**Why we boot the real apps (not a Storybook or jsdom emulation).** Many e2e bugs only show up when the real router + the real SSE stream + the real i18n setup interact. jsdom doesn't run a service worker or a real `fetch`; Storybook isolates components. Playwright + a real Chromium is the cheapest honest way to get coverage.

---

## §3 Fixtures

### 3.1 Seeded users

```jsonc
// tests/e2e/fixtures/auth/admin.json
{
  "user_id":   "u-admin-e2e",
  "email":     "admin@e2e.test",
  "password":  "AdminPass123!",
  "display_name": "E2E Admin",
  "permissions": [
    "platform:run_meeting", "platform:list_projects", "platform:list_meetings",
    "platform:view_observability",
    "investment:market_watch", "investment:portfolio",
    "investment:upload_financial_report", "investment:upload_business_plan",
    "investment:open_meeting"
  ],
  "preferences": {
    "theme_mode":  "light",
    "locale":      "en",
    "active_vertical": "investment",
    "notifications": { "enabled": true, "severities": ["info","success","warning","error"] }
  }
}

// fixtures/auth/basic.json — same shape; subset of permissions; no observability.
// fixtures/auth/readonly.json — only platform:list_projects.
```

Each scenario declares which user it logs in as (`auth: "admin" | "basic" | "readonly"`). The `helpers/auth.ts.login(user)` helper:
1. Calls `POST /test/seed` with the user payload.
2. Visits `/login`.
3. Fills the form + submits.
4. Waits for navigation to `/platform/dashboard` (or the user's `default_route` per their active vertical).

### 3.2 Studio fixtures

The pseudo-mode fixture overlay used by these scenarios is the union of:
- `packages/studio-client/fixtures/default/` (platform's baseline projects + meetings)
- `packages/verticals/investment/fixture_overlay/` (per spec 14: 5 projects + 5 meeting templates + 5 outcomes)

apps/api's test-mode boot copies / symlinks these into a known location under `/pseudo-fixtures/` served back to the frontend. Each scenario can call `POST /test/seed` to reset state (e.g., clear watchlist + portfolio between scenarios).

### 3.3 No mock studio in default e2e mode

The default e2e run uses pseudo + fixtures, not a mock HTTP studio. The substitution variant (e2e + `[SUB]` only) runs against the same mock studio defined in `17` §5; this catches "the real binding works for full workflows, not just unit calls."

---

## §4 Page Object Model

Each route the scenarios visit gets one `Page` class with locators + actions, never assertions. Assertions live in scenarios.

```typescript
// tests/e2e/pages/AgoraPage.ts
import type { Page, Locator } from "@playwright/test";

export class AgoraPage {
  constructor(private page: Page) {}

  url(meeting_id: string) { return `/platform/agora/${meeting_id}`; }

  // Locators (lazy-evaluated; no DOM lookup until awaited)
  get header()                { return this.page.getByTestId("agora-header"); }
  get statusPill()            { return this.page.getByTestId("agora-status-pill"); }
  get consensusPanel()        { return this.page.getByTestId("agora-consensus-panel"); }
  get dagSvg()                { return this.page.getByTestId("agora-dag"); }
  get costPanel()             { return this.page.getByTestId("agora-cost-panel"); }
  get viewReportButton()      { return this.page.getByRole("button", { name: /view report/i }); }
  eventCardByClaimId(id: string) { return this.page.getByTestId(`event-card-claim-${id}`); }

  async waitUntilStatus(status: "running" | "completed" | "failed") {
    await this.statusPill.getByText(status, { exact: false }).waitFor();
  }

  async waitForConsensus(claim_id: string) {
    await this.consensusPanel.getByTestId(`consensus-claim-${claim_id}`).waitFor();
  }
}
```

**Why POM (and not raw selectors in scenarios).** Scenarios become readable workflows; selectors live in one place per route, so a route-level UI change is one edit.

---

## §5 Scenarios

Each scenario specifies: title, tags, preconditions, steps, assertions, error-path notes, test_id.

### Scenario 01 — Login and dashboard

- **Tags**: `[SMOKE] [CRITICAL]`
- **Auth**: admin
- **Preconditions**: clean slate (POST /test/seed with admin)
- **Steps**:
  1. **Given** I am at `/login`
  2. **When** I enter admin credentials and submit
  3. **Then** I am navigated to `/investment/market-watch` (admin's default_route via active_vertical=investment)
  4. **And** the side nav shows: Dashboard, Knowledge, Chat, Reports, Observability, Settings, Market Watch, Portfolio
  5. **And** the user menu shows "E2E Admin" with the right avatar fallback
- **test_id**: `t_e2e_login_and_dashboard`

### Scenario 02 — Vertical switcher

- **Tags**: `[SMOKE]`
- **Auth**: admin (with both `investment` + `vertical-template` available — test mode has both installed)
- **Steps**:
  1. **Given** I am logged in with active_vertical=investment
  2. **When** I open the switcher and pick "Vertical Template"
  3. **Then** the URL navigates to `/vertical-template/example` (template's default_route)
  4. **And** the side nav updates to show vertical-template's tabs
  5. **And** `/api/user/preferences` PATCH is called with `{active_vertical: "vertical-template"}`
- **test_id**: `t_e2e_vertical_switcher`

### Scenario 03 — Theme and locale

- **Tags**: none
- **Auth**: basic
- **Steps**:
  1. **Given** I am logged in
  2. **When** I open Settings → Appearance and pick Dark
  3. **Then** `<html data-theme="dark">` updates immediately (optimistic per `11` §5.3)
  4. **And** within 500 ms a debounced PATCH to `/api/user/preferences` lands with `theme_mode=dark`
  5. **When** I pick locale `中文`
  6. **Then** the page UI re-renders with Chinese labels (e.g., side nav "知识库" instead of "Knowledge")
  7. **And** another debounced PATCH lands with `locale=zh`
- **test_id**: `t_e2e_theme_and_locale`

### Scenario 04 — Permission deny

- **Tags**: `[CRITICAL]`
- **Auth**: basic (no `platform:view_observability`)
- **Steps**:
  1. **Given** I am logged in as basic
  2. **When** I directly visit `/platform/observability`
  3. **Then** I am redirected to `/platform/dashboard` (per `02` §4.1)
  4. **And** a toast appears with key `permission.denied`
  5. **And** the side nav does NOT include the Observability entry
- **test_id**: `t_e2e_permission_deny`

### Scenario 05 — Notifications bell

- **Tags**: none
- **Auth**: admin
- **Steps**:
  1. **Given** I am logged in
  2. **When** an upload fails (force via `POST /test/inject-event { kind: "upload-failed" }`)
  3. **Then** a toast appears with severity=error
  4. **And** the bell icon shows a badge
  5. **When** I open the bell
  6. **Then** the failed-upload notification appears with action "View"
  7. **When** I dismiss
  8. **Then** badge clears
- **test_id**: `t_e2e_notifications_bell`

### Scenario 06 — Deliberation happy path

- **Tags**: `[SMOKE] [CRITICAL] [SUB]`
- **Auth**: admin
- **Preconditions**: studio fixtures loaded (investment-equity-research project + tmpl_investment_equity_research script)
- **Steps**:
  1. **Given** I am on the Wizard at `/platform/wizard`
  2. **When** I select project `investment-equity-research`
  3. **And** I enter topic "Should we hold our long position in $TICKER?"
  4. **And** I click Next through Materials (no uploads) and Review
  5. **And** I click Submit
  6. **Then** apps/api calls `studio.run_meeting(...)` and returns a `meeting_id`
  7. **And** the wizard navigates to `/platform/agora/<meeting_id>`
  8. **When** the SSE stream replays the meeting_template events
  9. **Then** the agora view shows ClaimMade events as cards in real time
  10. **And** ConsensusReached event appears in the ConsensusPanel (claim "f1" with confidence 0.85)
  11. **And** ChallengeRaised appears under the t1 claim
  12. **And** when MeetingFrozen + meeting_finalized arrive, the status pill flips to "completed"
  13. **And** the "View report" button appears
- **test_id**: `t_e2e_deliberation_happy_path`
- **Substitution note**: the http-mode variant uses the mock studio's identical event script + fixtures.

### Scenario 07 — Deliberation with uploads

- **Tags**: `[CRITICAL]`
- **Auth**: admin
- **Steps**:
  1. **Given** I am on the Wizard
  2. **When** I select project `investment-due-diligence`
  3. **And** I enter topic
  4. **And** at the Materials step I upload `acme-10k-2024q4.pdf` via the FinancialReportHandler (vertical handler from spec 14)
  5. **Then** the FinancialReportHandler shows extracted fields: company="acme", period="2024Q4"
  6. **When** I confirm
  7. **And** I Submit
  8. **Then** the meeting starts with the uploaded material inlined in the run_meeting call
  9. **And** in agora, the EvidenceCited event references the uploaded material's excerpt
- **test_id**: `t_e2e_deliberation_with_uploads`

### Scenario 08 — Deliberation failed meeting

- **Tags**: none
- **Auth**: admin
- **Preconditions**: a fixture flag forces `tmpl_investment_due_diligence` to emit `MeetingFailed` event mid-stream
- **Steps**:
  1. **Given** I start a due-diligence meeting
  2. **When** the SSE stream emits a `MeetingFailed` event with `error_class="ConstraintViolation"`
  3. **Then** the agora status pill flips to "failed" with the error_class as a tooltip
  4. **And** a banner per `05` §3.2 explains the failure
  5. **And** the "View report" button is replaced with "Try again" → opens a new wizard prefilled
- **test_id**: `t_e2e_deliberation_failed_meeting`

### Scenario 09 — Report render

- **Tags**: `[SMOKE] [CRITICAL]`
- **Auth**: admin
- **Steps**:
  1. **Given** I have a completed meeting (from scenario 06)
  2. **When** I click "View report"
  3. **Then** I navigate to `/platform/reports/<meeting_id>`
  4. **And** the TemplatePicker shows `investment:summary` + `investment:due_diligence` + platform default
  5. **When** I pick `investment:summary` + format PDF
  6. **And** I click "Download"
  7. **Then** apps/api streams a PDF; browser downloads file `summary-<meeting_id>.pdf`
  8. **And** the content-type is `application/pdf`
- **test_id**: `t_e2e_report_render`

### Scenario 10 — Chathub single turn

- **Tags**: `[SMOKE] [SUB]`
- **Auth**: admin
- **Preconditions**: chat-equity-analyst project loaded
- **Steps**:
  1. **Given** I navigate to `/platform/chat`
  2. **When** I pick agent "chat-equity-analyst"
  3. **And** I type "What's your view on $TICKER?" and press Enter
  4. **Then** apps/api kicks off a one-shot meeting (per `08` §3); turn appears with "thinking" indicator
  5. **And** when MessageEmitted arrives over SSE, the agent's reply appears
  6. **And** when meeting_finalized arrives, the "thinking" indicator clears
- **test_id**: `t_e2e_chathub_single_turn`

### Scenario 11 — Chathub multi-turn history

- **Tags**: none
- **Auth**: admin
- **Steps**:
  1. **Given** I had a chat with chat-equity-analyst (from scenario 10)
  2. **When** I send a follow-up "Why?"
  3. **Then** the new turn includes the full history (prior question + reply) in its run_meeting call (per `08` §3.4)
  4. **And** scrolling up shows the prior turn intact
  5. **And** auto-scroll re-engages on new agent reply
- **test_id**: `t_e2e_chathub_multi_turn_history`

### Scenario 12 — Chathub rate limited

- **Tags**: none
- **Auth**: admin
- **Preconditions**: rate-limit injection on (test mode bypasses the global skip; a test endpoint forces 429 on the next run_meeting)
- **Steps**:
  1. **Given** I send a chat turn
  2. **Then** apps/api returns 429 with `RateLimited`
  3. **And** the chat turn shows error state with retry button
  4. **And** error message uses key `feature.chathub.error.rate_limited`
- **test_id**: `t_e2e_chathub_rate_limited`

### Scenario 13 — Knowledge browse and filter

- **Tags**: `[SMOKE] [SUB]`
- **Auth**: admin
- **Preconditions**: 12 past meetings seeded across the 5 investment projects
- **Steps**:
  1. **Given** I navigate to `/platform/knowledge`
  2. **Then** the table shows up to 20 rows per page (paginated; per `07` §4)
  3. **When** I filter by project=investment-due-diligence
  4. **Then** rows reduce to those matching; URL updates with `?project_id=investment-due-diligence`
  5. **When** I reload the page
  6. **Then** the filter persists (read from search params)
- **test_id**: `t_e2e_knowledge_browse_and_filter`

### Scenario 14 — Knowledge open past meeting

- **Tags**: `[SMOKE]`
- **Auth**: admin
- **Steps**:
  1. **Given** I am on the knowledge browser
  2. **When** I click row for a completed meeting
  3. **Then** I navigate to `/platform/agora/<meeting_id>`
  4. **And** the meeting view loads in "frozen" mode (no live SSE; renders from get_meeting_outcome + replayed event log)
  5. **And** the consensus panel + DAG render the persisted state
- **test_id**: `t_e2e_knowledge_open_past_meeting`

### Scenario 15 — Uploads platform handler

- **Tags**: none
- **Auth**: admin
- **Steps**:
  1. **Given** I am on the wizard at the Materials step
  2. **When** I upload `simple-brief.txt` (no vertical handler matches; falls back to platform's BriefHandler)
  3. **Then** the BriefHandler shows the text content + a "Trim leading whitespace" toggle
  4. **And** confirming inlines it as Material{kind:"brief", content: <text>}
- **test_id**: `t_e2e_uploads_platform_handler`

### Scenario 16 — Uploads vertical handler

- **Tags**: `[SUB]`
- **Auth**: admin
- **Steps**:
  1. **Given** I am on the wizard at Materials
  2. **When** I upload `acme-bp-pitch.pdf` (matches vertical's BusinessPlanHandler kind by accept list)
  3. **Then** the HandlerPicker prefers the vertical handler over platform fallback
  4. **And** the handler renders + parses successfully
  5. **And** Wizard's MaterialsPanel shows the upload chip with the vertical's icon
- **test_id**: `t_e2e_uploads_vertical_handler`

### Scenario 17 — Settings password change

- **Tags**: `[CRITICAL]`
- **Auth**: basic (with known current password)
- **Steps**:
  1. **Given** I am on `/platform/settings/account`
  2. **When** I expand Change Password
  3. **And** I enter wrong current password + valid new + valid confirm
  4. **Then** form shows error key `feature.settings.password.error.wrong_current` (per `11` §6.1)
  5. **When** I correct the current password and submit
  6. **Then** toast "Password changed successfully" appears
  7. **And** form clears
  8. **And** I remain signed in (sessions not invalidated per `11` §6.1)
- **test_id**: `t_e2e_settings_password_change`

### Scenario 18 — Observability cost overview

- **Tags**: `[SMOKE]`
- **Auth**: admin (has `platform:view_observability`)
- **Preconditions**: 30 days of seeded cost ledger data across 3 models
- **Steps**:
  1. **Given** I navigate to `/platform/observability`
  2. **Then** the URL becomes `/platform/observability/cost`
  3. **And** Panel A shows total cost USD + line chart with 30 daily points
  4. **And** Panel B (Breakdown by) defaults to project_id with bar chart top 10
  5. **When** I change Breakdown to "model_id"
  6. **Then** the bar chart re-renders showing 3 models' shares
  7. **And** Panel C (Cost by model) shows the same 3 slices in a donut
  8. **When** I change time range to "Last 7 days"
  9. **Then** all 3 panels refetch + render the smaller window
- **test_id**: `t_e2e_observability_cost_overview`

---

## §6 Cross-cutting helpers

### 6.1 `helpers/seedFixtures.ts`

```typescript
import type { APIRequestContext } from "@playwright/test";

export async function seedAdmin(api: APIRequestContext): Promise<void> {
  await api.post("/test/seed", { data: require("../fixtures/auth/admin.json") });
}

// Inject a custom event into the next meeting's stream (pseudo only; mock-studio in http mode).
export async function injectEvent(
  api: APIRequestContext,
  meeting_id: string,
  event: { type: string; data: unknown },
): Promise<void> {
  await api.post(`/test/meetings/${meeting_id}/inject-event`, { data: event });
}
```

The `/test/*` endpoints are mounted only when `ENT_PRODUCT_TEST_MODE=1`. In production, they 404. CI test `t_apps_api_test_mode_off_in_prod` verifies they don't leak (per `15-apps-api-spec.md` §middleware test rows).

### 6.2 `helpers/auth.ts`

```typescript
import type { Page, APIRequestContext } from "@playwright/test";

export async function login(
  page: Page,
  api: APIRequestContext,
  user: "admin" | "basic" | "readonly",
): Promise<void> {
  const fixture = require(`../fixtures/auth/${user}.json`);
  await api.post("/test/seed", { data: fixture });
  await page.goto("/login");
  await page.fill("[name=email]", fixture.email);
  await page.fill("[name=password]", fixture.password);
  await page.click("button[type=submit]");
  // Wait for navigation to either dashboard or vertical's default_route
  await page.waitForURL(url => url.pathname !== "/login", { timeout: 10_000 });
}
```

### 6.3 `helpers/waitForEvent.ts`

```typescript
import type { Page } from "@playwright/test";

// Waits for a specific event card to appear in agora, derived from SSE stream.
// Bounded by timeout; throws with a structured message that includes the
// last-N events that DID arrive so flakes are diagnosable.
export async function waitForClaimEvent(page: Page, claim_id: string, timeoutMs = 10_000) {
  const card = page.getByTestId(`event-card-claim-${claim_id}`);
  try {
    await card.waitFor({ timeout: timeoutMs });
  } catch (err) {
    const seen = await page.locator("[data-testid^='event-card-']").allTextContents();
    throw new Error(`waitForClaimEvent(${claim_id}) timed out. Seen: ${JSON.stringify(seen)}`);
  }
}
```

---

## §7 Pass criteria + flake policy

The e2e suite is green IFF:
1. All 18 scenarios pass on the default (pseudo) project.
2. All `[SUB]`-tagged scenarios additionally pass on the `chromium-http` project (in the substitution variant run).
3. No scenario relies on `test.skip(...)`.
4. No scenario uses `test.fixme(...)` outside an active bug-fix PR.

**Flake policy.**
- Playwright's `retries: 2` in CI means a scenario gets up to 3 attempts.
- A scenario that fails on first attempt + passes on retry is logged but does NOT fail CI.
- A scenario that flakes (different attempts → different outcomes) on > 3 consecutive runs in main is opened as a P1 ticket; the offending scenario is `[SKIP]`-tagged with a TODO until fixed. SKIP-tagged scenarios DO fail CI if more than 1 exists at any time (forces flake-fixing).

**No silent retries inside scenarios.** Helpers like `waitForClaimEvent` use bounded waits with explicit error messages; no `setTimeout` / `sleep(...)` in scenario code.

---

## §8 CI integration

```yaml
# .github/workflows/ci.yml (excerpt)
e2e-smoke:
  runs-on: ubuntu-latest
  needs: [scaffolding-check, frontend-tests, substitution-tests]
  if: needs.scaffolding-check.outputs.has_frontend == 'true'
  steps:
    - uses: actions/checkout@v4
    - uses: pnpm/action-setup@v3
    - uses: actions/setup-node@v4
      with: { node-version: 20, cache: 'pnpm' }
    - run: pnpm install --frozen-lockfile
    - run: pnpm exec playwright install --with-deps chromium
    - run: pnpm --filter ./tests/e2e test --grep '@smoke'
    - if: failure()
      uses: actions/upload-artifact@v4
      with: { name: e2e-trace, path: tests/e2e/test-results/ }

e2e-full-nightly:
  if: github.event_name == 'schedule'
  # ...same setup...
  - run: pnpm --filter ./tests/e2e test
```

**PR gate**: only `[SMOKE]` scenarios run on every PR (≈ 6 scenarios; ~3-5 minutes).
**Nightly**: full 18-scenario suite + the substitution variant for `[SUB]` scenarios (~15-25 minutes).

---

## §9 Test matrix (the harness itself)

These rows verify the e2e infrastructure, NOT the scenarios:

| scenario | expected | test_id |
|---|---|---|
| `/test/seed` resets state | post twice; second response acknowledges idempotent reset | `t_e2e_inf_seed_idempotent` |
| `/test/seed` is gated by ENT_PRODUCT_TEST_MODE | with mode off, /test/* returns 404 | `t_e2e_inf_test_mode_gate` |
| webServer boots + healthchecks | playwright config's `url` polling completes | `t_e2e_inf_webserver_health` |
| trace artifacts uploaded on failure | inject a failure; verify trace uploaded | `t_e2e_inf_trace_upload` |
| login helper waits for nav | with valid creds; navigates within 10 s | `t_e2e_inf_login_helper` |
| waitForEvent helpful timeout | force timeout; error message includes seen events | `t_e2e_inf_wait_helpful` |
| substitution variant uses mock studio | `[SUB]` scenarios in chromium-http use `:8000` mocked endpoints | `t_e2e_inf_sub_uses_mock` |

---

## §10 Why this design — load-bearing decisions

**Why Playwright (not Cypress, not Selenium, not Puppeteer).**
Playwright handles SSE streams without flake (where Cypress historically struggled), supports modern auto-waiting APIs (no manual `wait(500)`), bundles its own browser binaries (no Selenium grid), and produces high-fidelity traces on failure. MIT-licensed; maintained by Microsoft; active community. Cypress's per-test iframe model breaks SSE; Selenium is too low-level; Puppeteer is fine but lacks the test runner Playwright ships.
*Considered and rejected.* **Cypress** — SSE fragility. **Selenium WebDriver** — too low-level; flaky on modern frontends. **Puppeteer + Mocha** — re-implements what Playwright bundles.

**Why a real apps/api in test mode (not a mock backend).**
The whole point of e2e is to verify the integration including the FastAPI surface, the auth flow, the SSE proxy, and the real router navigation. Mocking apps/api would be unit testing through the browser. The test-mode flag (mounted only when env is set) is the cleanest way to give tests deterministic seeding without polluting prod code.
*Considered and rejected.* **Mock backend (msw in browser)** — bypasses apps/api entirely; misses integration bugs. **Production backend with shared test data** — non-deterministic; can't seed reliably.

**Why pseudo by default + http via the substitution variant.**
Pseudo gives deterministic, fast, hermetic fixtures — perfect for default e2e. The http variant (mock studio, per `17` §5) provides parity coverage on `[SUB]`-tagged scenarios without doubling default runtime. This split mirrors the substitution suite's split: most coverage in pseudo, parity coverage on critical paths.
*Considered and rejected.* **Always run both modes** — doubles e2e runtime; most scenarios don't gain coverage from the http run.

**Why Page Object Model (and not raw selectors per scenario).**
Selectors change as UIs evolve; centralizing them in POM means a UI change is one edit. POM also serves as live documentation of the route's surface. The trade-off (small extra file per page) is overwhelmingly worth it for an 18-scenario suite that will grow.
*Considered and rejected.* **Inline selectors** — every UI tweak breaks N scenarios.

**Why test_ids on every observable element (not text-based locators).**
Text-based locators break on i18n changes (English text → Chinese text invalidates them). `data-testid` attributes are stable across locale + cosmetic changes. The shell's components ship `data-testid` per `02` + each feature spec; e2e tests rely on those.
*Considered and rejected.* **Text-based locators** — brittle to i18n + copy changes. **CSS class-based** — couples tests to styling.

**Why scenarios are numbered + named (not just numbered).**
File names `06-deliberation-happy-path.spec.ts` are scannable in PR diffs; the leading number gives stable ordering for "smoke-first, deeper-after" mental model. Renaming scenarios (rare) requires only the file rename — test_ids inside stay stable.
*Considered and rejected.* **Just numbers** — opaque in lists. **Just names** — non-deterministic ordering.

**Why `[SMOKE]` subset gates PRs (not the full suite).**
Full e2e is 18 scenarios × ~30s each + browser startup ≈ 15-25 minutes. Running on every PR would slow iteration without proportional value (most PRs don't touch every workflow). Smoke (≈ 6 scenarios, 3-5 min) catches the regressions that block deploy. Full suite runs nightly.
*Considered and rejected.* **Full suite on every PR** — too slow; bad iteration. **No e2e on PR** — regressions slip through.

**Why no visual regression testing in v0.1.**
Visual regression has its own labeling + maintenance overhead (every UI tweak invalidates a snapshot; review burden). v0.1 ships with structural assertions only. v0.2 may add visual regression for critical screens once the design system stabilizes.
*Considered and rejected.* **Visual regression now** — premature; design still evolving in v0.1.

**Why no a11y audit in CI v0.1.**
axe-in-CI catches real issues but produces noise (color contrast on intentional palette choices, etc.) that requires baseline tuning. Manual reviews per spec + axe runs as part of nightly are the v0.1 plan; CI gate is a v0.2 step.
*Considered and rejected.* **axe in PR gate** — false positives drown signal in v0.1.

**Why test mode endpoints are gated by env (not removed from prod build).**
Removing them via dead-code-elimination tied to env is fragile (build-time vs runtime; bundler optimization). A runtime check on `ENT_PRODUCT_TEST_MODE` with explicit 404 is honest + verifiable + survives bundling decisions. CI test `t_apps_api_test_mode_off_in_prod` proves the gate.
*Considered and rejected.* **Tree-shake at build** — works until bundler config drifts. **Separate prod build that excludes test routes** — two builds to maintain.

**Why no random / property-based scenarios.**
E2e flakes are amplified by randomness; debugging a flaky property-based e2e test is a nightmare. Deterministic scripted scenarios are easier to reason about + easier to fix. v0.2 may add property-based at the unit/component layer.
*Considered and rejected.* **Property-based at e2e** — flake-amplifier.

---

## §11 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | Components MUST ship `data-testid` per the e2e POM expectations; scenario 02/03/04/05 reference these. |
| `05-feature-agora-spec.md` | Agora's components ship `agora-header`, `agora-status-pill`, `agora-consensus-panel`, `agora-dag`, `agora-cost-panel`, `event-card-claim-<id>`, `consensus-claim-<id>` test_ids. Scenarios 06/07/08/14 reference. |
| `06-feature-reports-spec.md` | TemplatePicker exposes template options + format options as test_id-tagged radios; scenario 09 references. |
| `07-feature-knowledge-spec.md` | Knowledge browser table rows expose meeting_id as test_id; scenarios 13/14 reference. |
| `08-feature-chathub-spec.md` | Chat turns expose role + state as test_ids; scenarios 10/11/12 reference. |
| `09-feature-uploads-spec.md` | HandlerPicker + UploadPreviewOverlay expose handler_kind as test_id; scenarios 15/16 reference. |
| `10-feature-wizard-spec.md` | Wizard step components expose step name as test_id; scenarios 06/07 reference. |
| `11-feature-settings-spec.md` | ChangePasswordForm + AccountSection expose field names as test_id; scenario 17 references. |
| `12-feature-observability-spec.md` | Charts + dimension picker expose test_ids per panel; scenario 18 references. |
| `13-vertical-template-spec.md` | Template's tabs / widget / handler all use test_id pattern `vertical-<id>-<thing>` so the e2e harness can target verticals generically. |
| `14-vertical-investment-spec.md` | Investment-specific test_ids declared (`vertical-investment-market-watch-row`, etc.) for scenarios 06/07/16. |
| `15-apps-api-spec.md` | Test-mode middleware + `/test/seed`, `/test/inject-event`, `/test/meetings/<id>/inject-event` endpoints declared; gated by `ENT_PRODUCT_TEST_MODE`. |
| `16-apps-frontend-spec.md` | The boot orchestration is exercised end-to-end; scenarios 01-02 verify boot completes against fixtures. |
| `17-substitution-tests-spec.md` | E2e scenarios marked `[SUB]` (06, 10, 13, 16) join 17's category 1 / 2 inventory; the substitution runner re-runs them in mock-studio mode. |

---

## §12 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (multi-user, multi-tab, browser-back, real network, full localization audit)
- [ ] Module layout (§1) shows `tests/e2e/` top-level dir with playwright config + fixtures + pages + helpers + scenarios + README
- [ ] Test mode wiring (§2) defined: ENT_PRODUCT_TEST_MODE, /test/* endpoints, webServer config
- [ ] Fixtures (§3) include 3 user profiles (admin/basic/readonly) + studio binding + per-vertical overlays
- [ ] Page Object Model (§4) defined; one Page class per route; locators only, no assertions
- [ ] 18 scenarios (§5) each with title / tags / auth / preconditions / numbered Given-When-Then steps / test_id
- [ ] At least 6 scenarios are `[SMOKE]`-tagged (PR gate)
- [ ] At least 4 scenarios are `[SUB]`-tagged (mirrored in 17 §4 inventory)
- [ ] At least 4 scenarios are `[CRITICAL]`-tagged (auth, deny, deliberation happy, password change)
- [ ] Cross-cutting helpers (§6) defined: seedFixtures, login, waitForEvent (with helpful timeouts)
- [ ] Pass criteria + flake policy (§7) explicit: retries=2 in CI; SKIP-cap = 1
- [ ] CI integration (§8) gates PR on smoke; nightly runs full + substitution variant
- [ ] Harness self-tests (§9): ≥ 7 rows verifying seed-idempotency, mode-gate, helpers
- [ ] Why-this / why-not (§10) for ≥ 11 load-bearing decisions
- [ ] Downstream impact (§11) lists every spec affected; data-testid contract demanded
- [ ] No business / domain / product / agent-role string literals in scenario PROSE (test fixtures may reference vertical_ids per philosophy skill allowlist)
- [ ] No `from entelecheia` / `import entelecheia` (Red Line #1)
- [ ] No silent retries / sleep loops in scenarios (Red Line #8 in spirit; flake policy bans)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/18-end-to-end-scenarios-spec.md`
