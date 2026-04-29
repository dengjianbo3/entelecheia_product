# Platform Features

The library of always-present capabilities that the platform shell exposes to every vertical. Each feature is a self-contained package under `packages/platform-features/<name>/`. Verticals don't *have* these features — verticals *use* them. The platform-features library is the product's shared substrate.

---

## Inventory

| Feature | Purpose | Studio dependency |
|---|---|---|
| **agora** | Multi-agent deliberation UI (the centerpiece) | `subscribe_meeting`, `get_meeting_outcome`, `get_dag_view`, `get_provenance` |
| **reports** | Persistent report viewer + history | `get_report`, `list_reports` |
| **knowledge** | Project + meeting outcome browser | `list_projects`, `list_meetings`, `get_meeting_summary` |
| **chathub** | Lightweight 1:1 chat with a single agent (non-deliberation) | `chat` (single-agent endpoint) |
| **uploads** | File uploads + transformation handoff | (file upload is local; downstream parse calls go via studio) |
| **wizard** | Guided multi-step task launcher (e.g., "start a deliberation about X") | `run_meeting`, `list_available_projects` |
| **settings** | User preferences + theme + active vertical | (none — local) |
| **observability** | Cost / latency / error dashboards | `get_cost_aggregate`, `get_meeting_metrics` |

These are the features verticals plug into. New features are added by deliberate decision (PR + design review per **P4**); existing features change additively.

---

## Agora — the centerpiece

`packages/platform-features/agora/` is where the user actually experiences a deliberation.

### What the user sees

When the user starts a deliberation (via the wizard, or by clicking on an existing one in knowledge), they land in agora's main view:

```
┌─ Topic ─────────────────────────────────────────────────────┐
│  [topic statement]                                           │
│  Project: <ProjectSpec name>   Round: 3 / 8                  │
└──────────────────────────────────────────────────────────────┘

┌─ Discussion stream ──────────────────────┬─ Live DAG ──────┐
│  Agent A (FactGather)                    │  ◯ FactGather   │
│  > "Q3 revenue: 14B, +12% YoY"           │  │              │
│    [evidence: report.pdf p.4]            │  ◯ Synth        │
│                                          │  │ \            │
│  Agent B (Synth)                         │  ◯  ◯ Critic    │
│  > "Reading this against margin: ..."    │  │             │
│                                          │  ◯ Conclude     │
│  Agent C (Critic)                        │                  │
│  > "Hold on — gross or operating? ..."   │                  │
│                                          │                  │
│  ...                                     │                  │
└──────────────────────────────────────────┴──────────────────┘

┌─ Materials ─┐ ┌─ Outcome (live) ─────────┐ ┌─ Cost so far ─┐
│ report.pdf │ │ Working consensus:         │ │ $1.42         │
│ memo.docx   │ │ "Q3 was strong but ..."   │ │ 8.4k tokens   │
│ ...         │ │ Confidence: 0.78          │ │ 47s elapsed   │
└─────────────┘ └────────────────────────────┘ └────────────────┘
```

### Components

The agora feature is organized as a small Vue tree under `packages/platform-features/agora/frontend/`:

```
src/
├── AgoraView.vue              # top-level page
├── components/
│   ├── DiscussionStream.vue   # main left pane (events as cards)
│   ├── DagViewer.vue          # right pane (force-directed graph)
│   ├── MaterialsPanel.vue     # bottom-left (uploaded files)
│   ├── OutcomePanel.vue       # bottom-center (working consensus)
│   ├── CostPanel.vue          # bottom-right (live tally)
│   ├── EvidencePopover.vue    # click an evidence chip → trace popover
│   └── ProvenanceModal.vue    # full provenance trace, opened on demand
└── composables/
    ├── useMeetingStream.ts    # subscribes to studio events via studio-client
    ├── useDagState.ts         # incremental DAG construction from events
    └── useOutcomeReducer.ts   # folds events into (working) outcome
```

### Backend: zero

Agora has no backend code in product. All deliberation logic — agent runtime, event log, paradigms, etc. — lives in studio. Product's backend role is solely to forward studio's WebSocket stream to the frontend (and even that is just a thin ASGI passthrough in `apps/api/agora_proxy.py`).

This is direct application of **P3 (studio is the only backend logic)**.

### Event stream contract

`useMeetingStream.ts` subscribes via `studio_client.subscribe_meeting(meeting_id)`, which yields `MeetingEvent` objects:

```typescript
type MeetingEvent =
  | { kind: "agent_speech";    agent_id: string; text: string; refs: EvidenceRef[]; ts: string }
  | { kind: "evidence_added";  agent_id: string; evidence: Evidence; ts: string }
  | { kind: "claim_proposed";  agent_id: string; claim: Claim; ts: string }
  | { kind: "claim_revised";   claim_id: string; new_text: string; ts: string }
  | { kind: "round_advanced";  round: number; ts: string }
  | { kind: "outcome_updated"; outcome: WorkingOutcome; ts: string }
  | { kind: "meeting_concluded"; outcome: FinalOutcome; ts: string }
  | { kind: "error";           message: string; agent_id?: string; ts: string }
```

The agora frontend treats these as the authoritative event log. DAG / outcome / cost panels all derive from folding events.

---

## Reports

Persistent report viewer for completed deliberations.

### What the user does

- Opens a report from the knowledge browser or a notification
- Reads the structured outcome (executive summary, key claims, evidence map, dissent log)
- Drills into provenance: clicks any claim → sees which agents proposed/revised it, in which events, against which materials
- Shares a link (with permission) to colleagues
- Exports to PDF / Markdown / Notion

### Studio coupling

Reports are produced by studio at meeting conclusion (`get_meeting_outcome`). Product caches them locally (so a user can view a report even if studio is briefly unavailable) but the canonical store is studio's persistence.

```
packages/platform-features/reports/
├── frontend/
│   ├── ReportView.vue
│   ├── components/{ExecutiveSummary, ClaimsTable, EvidenceMap, DissentLog, Exporter}.vue
│   └── composables/{useReport, useExport}.ts
└── api/
    ├── routers/reports.py       # thin wrapper around studio-client.get_report
    └── exporters/{pdf, markdown, notion}.py  # local export (no studio needed)
```

---

## Knowledge browser

A read-mostly view across all the user's projects + meetings + outcomes.

### What it shows

- **Project list** (filterable by vertical, owner, last-active-time)
- **Meeting list** (within a project, with status: running / concluded / failed / draft)
- **Outcome cards** (compact preview of meeting consensus + key claims)
- **Search** (full-text across meetings the user has access to)

The knowledge browser is the product's "library." Verticals can pre-filter it (e.g., investment vertical filters projects to `labels_any_of=["investment"]` by default), but the underlying views are always the same.

### Studio coupling

All reads. Knowledge browser is a frontend over `list_projects`, `list_meetings`, `get_meeting_summary`. No writes.

---

## Chathub

A lightweight 1:1 chat with a single agent — bypasses deliberation runtime entirely. Used for quick questions, drafting help, debugging an agent's behavior.

### Why

Sometimes the user doesn't need a multi-agent deliberation; they need to ask one expert a question. Chathub is that affordance. It's not a competitor to deliberation; it's a complement.

```
packages/platform-features/chathub/
├── frontend/
│   ├── ChatView.vue
│   └── components/{MessageList, InputBox, AgentPicker}.vue
└── api/
    └── routers/chat.py    # studio_client.chat(agent_id, messages) — single-agent endpoint
```

Studio exposes a `chat(agent_spec_id, messages)` endpoint that runs an `AgentSpec` against a message thread without spinning up a meeting. Product's chathub is just a UI for it.

---

## Uploads

File upload + handoff to studio for parsing / extraction / indexing.

### What the user does

- Drags a PDF / DOCX / XLSX / image into the upload panel
- Picks an upload kind (e.g., "research material" — generic; or vertical-specific like "financial report")
- Product backend buffers the file, calls the appropriate handler endpoint
- For generic uploads: `studio_client.parse_material(file)` → returns parsed text + metadata
- For vertical-specific: the vertical's upload handler receives the file, extracts vertical-relevant fields (e.g., extracting financial data from a 10-K), then calls studio's parse + index endpoints

### Vertical extension

Verticals can register custom upload handlers via their manifest:

```typescript
upload_handlers: [
  {
    kind: "financial-report",
    label: { zh: "财报", en: "Financial Report" },
    accepts: [".pdf", ".xlsx"],
    backend_endpoint: "/api/verticals/investment/upload/financial",
    handler_component: FinancialReportUploadHandler,
  },
],
```

When the upload panel sees a vertical-specific kind, it routes to the vertical's handler component for any vertical-specific UI (e.g., letting the user confirm extracted financial fields before indexing) and then to the vertical's backend endpoint for the actual processing.

The platform feature owns: file dropzone, kind picker, progress UI, error handling. The vertical owns: kind-specific extraction logic.

---

## Wizard

A guided multi-step task launcher.

Most product entry points start with a wizard:
- "Start a new deliberation" (pick project → pick topic → attach materials → review config → start)
- "Add materials to an existing meeting" (pick meeting → upload → confirm)
- Vertical-specific wizards (e.g., investment's "screen a new investment opportunity")

The wizard is a generic step-runner. Each step is a Vue component with a `validate()` function. The wizard handles navigation, progress display, and the final submission.

```
packages/platform-features/wizard/
├── frontend/
│   ├── WizardView.vue
│   ├── components/{StepShell, ProgressIndicator, NavButtons}.vue
│   ├── composables/useWizard.ts     # state machine for step progress
│   └── presets/                     # generic wizards (e.g., new-meeting)
│       └── new-meeting/
│           ├── WizardConfig.ts
│           └── steps/{PickProject, PickTopic, AttachMaterials, ReviewConfig}.vue
└── api/  (none — pure frontend; final submission goes via studio-client)
```

Verticals can register their own wizard presets through the manifest (not shown above for brevity).

---

## Settings

User preferences. Theme, language, default vertical, notification preferences, etc. Stored in `user_service`'s SQLite.

```
packages/platform-features/settings/
├── frontend/
│   ├── SettingsView.vue
│   └── components/{ThemePicker, LanguagePicker, NotificationPrefs, VerticalPrefs}.vue
└── api/  (uses user_service directly)
```

This is the most boring feature in the product. That's fine. Boring is a feature.

---

## Observability dashboards

Read-only views over studio's metrics aggregates.

### What it shows

- **Cost dashboard:** spend per project / per vertical / per user / per agent / per LLM, time-series + distribution
- **Latency dashboard:** meeting duration distribution, agent step latencies, LLM call latencies
- **Error dashboard:** failure rate per agent / per project, recent failures with traces
- **Volume dashboard:** meetings per day, messages per meeting, etc.

### Studio coupling

100% reads via `get_cost_aggregate`, `get_meeting_metrics`, etc. Product produces zero metrics of its own — studio is the source of truth (per **P3**).

This is also where users can drill into individual meetings to debug failures (clicking a failed meeting opens its agora view in read-only mode).

---

## Cross-feature concerns

### Permissions

Each feature respects user permissions (from `auth_service`). E.g., a user without `meeting:create` permission sees the wizard's "start meeting" button greyed out. Permissions are platform-level (declared by features) plus vertical-level (declared in vertical manifests).

### i18n

All features ship with `zh` + `en` translations in `<feature>/frontend/i18n/`. Verticals can add vertical-specific translations that get merged into the global i18n bundle at registration time.

### Theming

Features use platform-shell's theme variables (`--color-bg`, `--font-body`, etc.). Per the entelecheia design system: blue spine, periwinkle landing, ink ladder, glass cards, no emoji. Features must not introduce new theme variables — if they need something, it goes into platform-shell.

### Error handling

Per **P8 (loud failures)**: when `studio_client` raises, the feature surfaces the error to the user with a clear message + a button to retry (or report). No silent fallback to mock data, ever.

---

## Why this is the right feature set

**These features cover the user journey end-to-end:**

1. User logs in → settings says "default vertical = investment"
2. User browses knowledge → finds an existing project
3. User opens wizard → starts a new deliberation in that project
4. User watches agora → sees agents discuss, evidence flow, consensus form
5. User opens reports → reads the conclusion, exports to PDF, shares
6. User opens observability → sees how much it cost, how long it took
7. User opens chathub → asks one expert a follow-up
8. User opens uploads → adds new materials for the next meeting

There's no part of "use entelecheia" that requires a feature outside this list. New verticals add tabs / widgets / handlers, but the core journey stays the same. That's what makes the product a "mother ship" — verticals plug in *around* a stable journey.

---

## What's NOT a platform feature

To stay disciplined, here's what people might propose as a "platform feature" but actually belongs elsewhere:

- ❌ **Agent definitions** → studio's `AgentSpec`
- ❌ **Project definitions** → studio's `ProjectSpec`
- ❌ **Skill packs** → studio's substrate-skills
- ❌ **Vertical-specific dashboards** → that vertical's manifest
- ❌ **Custom report types per vertical** → vertical's report extension via the reports feature's extension hooks
- ❌ **Inline LLM playground** → that's studio's territory; product doesn't expose raw LLM access
- ❌ **Agent debugging UI** → studio's UI; product is for end users
- ❌ **Skill author UI** → studio's UI

The pattern: anything an *engineer or PM* needs is in studio. Anything an *end user* needs is in product. Platform features are the universally-needed end-user capabilities. Verticals add domain-specific end-user capabilities.

---

## Adding a new platform feature (developer flow)

1. Open a design proposal: `docs/proposals/feature-<name>.md` — describe the user-facing problem, why no existing feature solves it, why no vertical can solve it (i.e., why it's general)
2. Get reviewer sign-off (per **P4**, this is a deliberate decision)
3. `mkdir packages/platform-features/<name>/` with frontend + api subdirectories
4. Implement following the patterns above (Vue components for UI, FastAPI router if needed, studio-client calls only)
5. Write substitution tests (the feature must work against `PseudoStudioClient` and `HttpStudioClient` identically — see `02-studio-integration.md`)
6. Update `docs/migration-log.md` and bump product's minor version
7. PR with screencast (~3 min) showing the feature working end-to-end

A new platform feature is roughly **a week of work** for one engineer. We add them rarely (per **P4**, the platform should be stable). The bar is "every vertical needs this" — not "investment needs this and we hope policy will too eventually."
