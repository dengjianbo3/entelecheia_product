# 06 — `reports` feature v0.1 spec

> **Status**: v0.1 contract for the report-rendering feature. **Frontend stack**: React 18 + TypeScript + Zustand + React Router v6 + react-i18next + Tailwind, plus `react-markdown` + `remark-gfm` (preview rendering of Markdown output).
> **Lives at**: `packages/platform-features/reports/` (frontend) + `apps/api/reports/` (server-side renderers per `15-apps-api-spec.md`).
> **Consumes**: `01-studio-client-spec.md` §5.1 (`OutcomeResponse` + `MeetingOutcome`), `01-studio-client-spec.md` §7.9 (`get_meeting_outcome`), `02-platform-shell-spec.md` (hooks + routing + permissions), `13-vertical-template-spec.md` (`report_templates` field in vertical backend manifest).
> **Forwarded to from**: `05-feature-agora-spec.md` ("View report" callback navigates here when meeting is finalized).
> **Supersedes**: the Vue version of this spec (committed in `bb9b804`); React migration per session decision 2026-05-03.

---

## Mission

This file defines the reports feature — the product-side renderer that turns a finalized `MeetingOutcome` into a downloadable artifact (PDF / Word / Excel / Markdown). Per `01-studio-client-spec.md` §11.3, studio does NOT render reports; product is the renderer. Templates are per-vertical-extensible: a vertical's backend manifest may declare additional templates that show up alongside the platform defaults.

**Hard rule** (P3 boundary): rendering is **deterministic transformation**, not reasoning. PDF/Word/Excel renderers run in `apps/api` (server-side, pure Python with reportlab / python-docx / openpyxl); Markdown renders client-side as a pure string template + is displayed via `react-markdown`. Studio is uninvolved beyond providing the source `MeetingOutcome`. Templates are data + small render functions — never paradigm logic, never LLM calls.

---

## Scope

**Covers.**
- Module layout (frontend feature package + server-side renderers in apps/api).
- Single route: `/platform/reports/:meeting_id`. Listing past reports = listing finished meetings = knowledge browser's job (spec 07); reports has no list view of its own.
- 6 React components: `<ReportView>`, `<ReportHeader>`, `<TemplatePicker>`, `<FormatPicker>`, `<RenderPreview>`, `<ExportControls>`, `<ReportFooter>`.
- 2 React hooks: `useReportRender` (wraps the render API), `useReportTemplates` (lists available templates).
- 4 output formats with render contracts: PDF (server), Word (server), Excel (server), Markdown (client text + client display).
- Template system: `ReportTemplate` interface + the 2 platform default templates (`platform:default-comprehensive`, `platform:default-summary`) + the per-vertical extension mechanism.
- `POST /api/reports/render` apps/api endpoint that accepts `{meeting_id, format, template_id}` and returns artifact bytes (or `Retry-After` if studio outcome not ready).
- `GET /api/reports/templates` apps/api endpoint that lists templates available to the active user / vertical.
- Lifecycle: fetch outcome → preview → export.
- Sealed error taxonomy (5 leaves: 2 owned + auth-relayed listed).
- Test matrix per renderer + per component.
- Forward-compat: unknown `concluded_by` enum values render to a generic "Concluded" header.

**Does not cover.**
- The list of past meetings — that's `07-feature-knowledge-spec.md`.
- The agora "View report" button — that's `05-feature-agora-spec.md` §5.3 (this spec only declares the route it navigates to).
- Studio's `MeetingOutcome` shape — that's `01-studio-client-spec.md` §5.1.
- Vertical-specific report content — verticals contribute templates; the vertical's spec (e.g. `14`) names which templates it ships, not their internal logic at the platform level.
- Email delivery / scheduled reports — out of v0.1.
- Report sharing (publish-to-link, embed) — out of v0.1.

**Out of scope for v0.1.**
- Caching of rendered artifacts. Re-render on every request; outcomes are immutable post-finalization, so a future cache is safe to add additively.
- Differential / incremental rendering (only re-render what changed).
- Report diffing across meetings.
- Real-time collaborative editing of report drafts (reports are derived, not authored).
- LaTeX output.
- Print-style CSS for browser-print-to-PDF (reports are binary downloads, not pages to print).
- Per-section permission gating ("user X cannot see the cost section") — render is all-or-nothing per template.

---

## §1 Module layout

### 1.1 Frontend package

```
packages/platform-features/reports/
├── src/
│   ├── index.ts                            # exports: ReportView + reportsRoutes
│   ├── ReportView.tsx                      # top-level view at /platform/reports/:meeting_id
│   ├── components/
│   │   ├── ReportHeader.tsx                # title + project + dates + concluded_by chip
│   │   ├── TemplatePicker.tsx              # dropdown of available templates
│   │   ├── FormatPicker.tsx                # 4 buttons: PDF / Word / Excel / Markdown
│   │   ├── RenderPreview.tsx               # always-on rendered Markdown preview (via react-markdown)
│   │   ├── ExportControls.tsx              # export, copy, share-link buttons
│   │   └── ReportFooter.tsx                # merkle_root + render metadata
│   ├── hooks/
│   │   ├── useReportRender.ts              # wraps POST /api/reports/render; returns Blob + triggers download
│   │   └── useReportTemplates.ts           # wraps GET /api/reports/templates
│   ├── render/
│   │   └── markdown.ts                     # client-side MD text generator (pure string template; no library)
│   ├── routes.ts
│   ├── permissions.ts
│   └── i18n/
│       ├── zh.json
│       └── en.json
├── tests/
│   ├── components/
│   ├── hooks/
│   └── render/
│       └── markdown-snapshots/
├── package.json                            # depends on react, react-dom, react-router-dom,
│                                           #            zustand, react-i18next,
│                                           #            react-markdown, remark-gfm
└── tsconfig.json
```

### 1.2 Server-side renderer module (in apps/api)

```
apps/api/
└── reports/
    ├── __init__.py
    ├── api.py                              # /api/reports/* router (mounted by apps/api/main.py per spec 15)
    ├── models.py                           # RenderRequest, ReportTemplate, RenderError
    ├── templates/
    │   ├── __init__.py
    │   ├── registry.py                     # in-memory template registry; vertical templates registered at boot
    │   ├── default_comprehensive.py        # the default template (full outcome)
    │   └── default_summary.py              # condensed template (key_facts + decision only)
    ├── renderers/
    │   ├── __init__.py
    │   ├── pdf.py                          # reportlab-backed
    │   ├── word.py                         # python-docx-backed
    │   ├── excel.py                        # openpyxl-backed
    │   └── markdown.py                     # plain-string (used both server- and client-side; same template logic)
    └── tests/
```

### 1.3 Permissions declared

```typescript
// packages/platform-features/reports/src/permissions.ts
export const REPORTS_PERMISSIONS = [
  { code: "platform:render_report",  description: "Render and download a meeting report" },
] as const;
```

`platform:render_report` is required for `/platform/reports/:meeting_id` route + for `POST /api/reports/render`. Granted to any user who has `platform:run_meeting` by convention (admin-level grants per `03` §5).

### 1.4 Routes declared

```typescript
// packages/platform-features/reports/src/routes.ts
import { type RouteObject, redirect } from "react-router-dom";
import { makePermissionLoader } from "@entelecheia/platform-shell";

export const reportsRoutes: RouteObject[] = [
  {
    path: "/platform/reports/:meeting_id",
    lazy: async () => {
      const { ReportView } = await import("./ReportView");
      return { Component: ReportView };
    },
    loader: makePermissionLoader("platform:render_report"),
    handle: { title_key: "feature.reports.title" },
  },
  {
    path: "/platform/reports",
    loader: () => redirect("/platform/knowledge"),        // listing past meetings is knowledge's job
  },
];
```

---

## §2 Lifecycle

### 2.1 Component contract — `<ReportView>`

```typescript
import { useParams } from "react-router-dom";
import { useState, useEffect } from "react";
import { useStudio } from "@entelecheia/platform-shell";
import { useReportRender } from "./hooks/useReportRender";
import { useReportTemplates } from "./hooks/useReportTemplates";
import type { OutcomeResponse } from "@entelecheia/studio-client";

export function ReportView() {
  const { meeting_id } = useParams<{ meeting_id: string }>();
  if (!meeting_id) throw new Error("ReportView requires meeting_id route param");

  const studio = useStudio();

  // Fetch outcome (initial + on meeting_id change)
  const [outcome, setOutcome] = useState<OutcomeResponse | null>(null);
  const [outcomeLoading, setOutcomeLoading] = useState(true);
  const [outcomeError, setOutcomeError] = useState<unknown>(null);

  useEffect(() => {
    let cancelled = false;
    setOutcomeLoading(true);
    setOutcome(null);
    setOutcomeError(null);
    studio.get_meeting_outcome({ meeting_id })
      .then(r => { if (!cancelled) setOutcome(r); })
      .catch(e => { if (!cancelled) setOutcomeError(e); })
      .finally(() => { if (!cancelled) setOutcomeLoading(false); });
    return () => { cancelled = true; };
  }, [meeting_id, studio]);

  // Templates (depends on active vertical)
  const { templates } = useReportTemplates();

  // Selected template + format (UI state)
  const [selectedTemplate, setSelectedTemplate] = useState<string>("platform:default-comprehensive");
  const [selectedFormat, setSelectedFormat] = useState<ReportFormat>("pdf");

  // Render trigger
  const { render, isRendering, lastError } = useReportRender();

  // ...render switch over status states (per §2.2)
}
```

### 2.2 Status states

`<ReportView>` renders one of 5 visual states based on outcome fetch + render:

| State | Trigger | Visual |
|---|---|---|
| `loading_outcome` | `outcomeLoading === true` | full-page spinner with "Loading outcome…" |
| `outcome_not_ready` | `outcomeError instanceof MeetingNotReady` | placeholder "Meeting still in progress; report becomes available when finalized" + back link to agora |
| `outcome_not_found` | `outcomeError instanceof NotFound` | 404 page |
| `outcome_failed` | `outcomeError instanceof MeetingFailed` | "This meeting failed; no report available" + back link |
| `ready` | `outcome` non-null with `outcome.outcome` non-null | full UI: header + pickers + preview + export controls |

If `outcome.outcome` is null but `outcome.error` is non-null (per `01` §5.1's `OutcomeResponse` envelope where one of the two is non-null), treat as `outcome_failed`.

### 2.3 Permission check

Route loader (`makePermissionLoader("platform:render_report")` from spec 02) ensures permission. Per-meeting visibility enforced by studio (returns `MeetingNotFound` → surfaces here as `outcome_not_found`).

---

## §3 Layout

### 3.1 Desktop (≥ 1024 px)

```
┌────────────────────────────── ReportHeader ───────────────────────────────┐
│  [back] [project name]: [topic preview]   [concluded_by chip]  [date]   │
├──────────────────────────────────────────┬───────────────────────────────┤
│                                          │                               │
│           RenderPreview                  │       TemplatePicker          │
│           (Markdown, scrollable)         │       FormatPicker            │
│                                          │       ExportControls          │
│                                          │       ReportFooter            │
│                                          │                               │
└──────────────────────────────────────────┴───────────────────────────────┘
```

Two-column via Tailwind grid: preview takes ~70%, controls ~30%.

### 3.2 Mobile (< 640 px)

Single column: header → controls (sticky bottom bar) → preview (full width). Export controls collapse into a sheet.

---

## §4 Components

### 4.1 `<ReportHeader>`

```typescript
export interface ReportHeaderProps {
  outcome:        OutcomeResponse;       // assumed loaded
  onBackClicked?: () => void;             // back to agora or knowledge
}

export function ReportHeader(props: ReportHeaderProps): React.ReactElement;
```

**Renders.** Project name (from `outcome.project_id`; lookup name via cached `useStudio().get_project()`), `topic` (truncated), `concluded_at` formatted, `concluded_by` rendered as a colored chip:

| `concluded_by` | Chip color |
|---|---|
| `consensus_reached` | green |
| `max_turns` | gray |
| `deadline` | gray |
| `human_stop` | yellow |
| `constraint_violation` | amber |
| `concluded_by_facilitator` | blue |
| (unknown — forward-compat) | gray with tooltip showing raw value |

### 4.2 `<TemplatePicker>`

```typescript
export interface TemplatePickerProps {
  templates:        ReportTemplate[];
  value:            string;             // template_id (controlled)
  format:           ReportFormat;        // current format; templates filtered to those that support it
  onChange:         (template_id: string) => void;
}

export function TemplatePicker(props: TemplatePickerProps): React.ReactElement;
```

**Renders.** Dropdown listing templates whose `formats` array includes the current `format`. Defaults to `platform:default-comprehensive`.

If a template stops supporting the current format (theoretical edge case across vertical reloads), the picker auto-selects the first compatible template and calls `onChange` via `useEffect` watching `format`.

### 4.3 `<FormatPicker>`

```typescript
export interface FormatPickerProps {
  value:    ReportFormat;     // "pdf" | "word" | "excel" | "markdown"
  onChange: (format: ReportFormat) => void;
}

export function FormatPicker(props: FormatPickerProps): React.ReactElement;
```

**Renders.** 4 segmented buttons (PDF / Word / Excel / Markdown). Selecting Markdown updates the preview live (client-side render); selecting any other format leaves preview unchanged but updates which renderer the export button calls.

### 4.4 `<RenderPreview>`

```typescript
export interface RenderPreviewProps {
  outcome:       OutcomeResponse;
  template_id:   string;
}

export function RenderPreview(props: RenderPreviewProps): React.ReactElement;
```

**Renders.**
1. Generates Markdown TEXT from the selected template via `render/markdown.ts` (the same logic as the server-side `render_markdown.py` — see §5.5).
2. Displays the rendered Markdown via `<ReactMarkdown remarkPlugins={[remarkGfm]}>` so the user sees formatted text (not raw `**bold**` syntax).

```tsx
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { renderMarkdown } from "../render/markdown";

export function RenderPreview({ outcome, template_id }: RenderPreviewProps) {
  const template = useTemplateRegistry().get(template_id);
  if (!template) return <EmptyState message_key="feature.reports.template_not_available" />;

  const md = renderMarkdown(outcome, template);   // pure string; deterministic

  return (
    <article className="prose max-w-none">
      <ReactMarkdown remarkPlugins={[remarkGfm]}>{md}</ReactMarkdown>
    </article>
  );
}
```

**Why Markdown is the preview.** Lightest to render; shared template logic with the server-side Markdown renderer (cross-language parity test enforces); reads well in browser; matches the structured data shape; format-agnostic for layout decisions.

**Empty state.** If `template_id` is unknown (404 from `useReportTemplates`), shows "Template not available." with a button to switch to default.

### 4.5 `<ExportControls>`

```typescript
export interface ExportControlsProps {
  outcome:        OutcomeResponse;
  template_id:    string;
  format:         ReportFormat;
  isRendering:    boolean;
  lastError:      string | null;
  onExportClicked:        () => void;
  onCopyClipboardClicked: () => void;       // copies Markdown text only
  onShareLinkClicked:     () => void;       // copies the URL of /platform/reports/:meeting_id
}

export function ExportControls(props: ExportControlsProps): React.ReactElement;
```

**Renders.** Primary button "Export <format>"; secondary "Copy as Markdown" (always available client-side); tertiary "Copy link". Disabled state during `isRendering`. Below button: error message if `lastError`.

### 4.6 `<ReportFooter>`

```typescript
export interface ReportFooterProps {
  outcome: OutcomeResponse;
}

export function ReportFooter(props: ReportFooterProps): React.ReactElement;
```

**Renders.** Small gray text:
- `Audit anchor: <merkle_root>` (the 64-hex sha256 from `MeetingOutcome.merkle_root`; full value visible on hover; truncated to 16 chars in display)
- `Rendered at: <client local timestamp>`
- `Studio meeting id: <meeting_id>`

Provides the audit trail for downstream verification.

---

## §5 Render contracts (per format)

The same template produces different artifacts per format. Each renderer reads `MeetingOutcome` (canonical fields below) and emits its format. Renderers are **pure functions** — no LLM, no IO beyond the outcome input + template reference.

### 5.1 Canonical input fields used by ALL renderers

From `01-studio-client-spec.md` §5.1:

```python
class MeetingOutcome:
    meeting_id: str
    concluded_by: str                       # see chip rules in §4.1
    consensus: list[dict]                   # ConsensusItem[]; engine §3.5 shape
    unresolved_disagreements: list[dict]    # Disagreement[]
    key_facts: list[dict]                   # Fact[]
    open_questions: list[dict]              # OpenQuestion[]
    started_at: str
    concluded_at: str
    total_turns: int
    final_constraints_status: list[dict]    # ConstraintResult[]
    merkle_root: str

class OutcomeResponse:
    meeting_id, project_id, project_version, started_at, ended_at, duration_seconds
    outcome:    MeetingOutcome | None
    error:      dict | None
```

Renderers MUST handle missing optional fields per the engine forward-compat rule (`01` §5.1: "products switching on it should have an `else` branch") — unknown `concluded_by` enum value, missing `merkle_root` (defensively `null` allowed), empty `key_facts`, etc.

### 5.2 PDF (server-side, reportlab)

`apps/api/reports/renderers/pdf.py`:

```python
def render_pdf(outcome: MeetingOutcome, template: ReportTemplate) -> bytes:
    """
    Returns PDF bytes. Page size: A4 default; configurable per template.
    Layout:
      - Cover page: title, project name, dates, concluded_by chip
      - TOC
      - Sections per template.sections[] (each section gets its own H1)
      - Footer per page: page number + merkle_root short (last 16 hex)
    Fonts: Plus Jakarta Sans (sans), Crimson Pro (serif) — bundled in apps/api
    Embedded images: none in v0.1 (engine doesn't surface images)
    """
```

**Why reportlab.** Mature; pure Python; no native deps; produces tagged PDF (accessibility); supports embedded fonts; small (~3MB install).
*Considered and rejected.* WeasyPrint (HTML→PDF) — pulls Pango/Cairo native deps; reportlab is leaner.

### 5.3 Word (server-side, python-docx)

`apps/api/reports/renderers/word.py`:

```python
def render_word(outcome: MeetingOutcome, template: ReportTemplate) -> bytes:
    """
    Returns .docx bytes.
    Layout:
      - Title page (Heading 1 style)
      - Sections per template.sections[] (Heading 2 + body)
      - Tables for ConsensusItem[], Disagreement[] (multi-column)
      - Footer: page number + merkle_root short
    Style: minimal — uses built-in styles; users edit downstream
    """
```

### 5.4 Excel (server-side, openpyxl)

`apps/api/reports/renderers/excel.py`:

```python
def render_excel(outcome: MeetingOutcome, template: ReportTemplate) -> bytes:
    """
    Returns .xlsx bytes. Multi-sheet workbook:
      Sheet 1: Summary (one-row meta: project, dates, concluded_by, total_turns, merkle_root)
      Sheet 2: Consensus (one row per ConsensusItem; columns from engine schema)
      Sheet 3: Disagreements (one row per Disagreement)
      Sheet 4: Key Facts (one row per Fact)
      Sheet 5: Open Questions
      Sheet 6: Constraints (one row per ConstraintResult)
    Auto-fits column widths; headers bold + sticky.
    """
```

**Per-template variation.** Templates may suppress sheets (e.g., `default-summary` produces only Summary + Key Facts).

### 5.5 Markdown (client + server, plain string)

`packages/platform-features/reports/src/render/markdown.ts` (client) and `apps/api/reports/renderers/markdown.py` (server) implement the **same logic** in their respective languages. Test parity is enforced by snapshot tests on a fixed `MeetingOutcome` fixture (`tests/render/markdown-snapshots/`).

```typescript
// Client signature
export function renderMarkdown(outcome: OutcomeResponse, template: ReportTemplate): string;
```

```python
# Server signature
def render_markdown(outcome: MeetingOutcome, template: ReportTemplate) -> bytes:
    return _render(...).encode("utf-8")
```

**Format.** GFM-flavored Markdown, with:
- `# {title}` header
- `## Concluded` paragraph (concluded_by humanized + concluded_at)
- `## Consensus` (numbered list of consensus items, with confidence badge)
- `## Key Facts` (bullet list)
- `## Unresolved Disagreements` (table of pro / con per disagreement)
- `## Open Questions` (numbered list)
- `## Constraints` (table)
- `---\n*Audit anchor: {merkle_root}*`

**Why client-side Markdown render** (text generation, not display). The TEXT generation runs client-side so `<RenderPreview>` can show a preview without a server round trip; <100 LOC; the rendered DOM uses `react-markdown` (see §4.4) for display.

**Two distinct concerns**:
1. **Markdown text generation** (`render/markdown.ts`) — pure function, no UI, language-parallel with server.
2. **Markdown display in browser** (`react-markdown` in `<RenderPreview>`) — UI concern, React-specific.

The cross-language parity test (`t_md_parity_client_server`) covers (1); React Testing Library tests cover (2).

---

## §6 Templates

### 6.1 Template interface

```typescript
// packages/platform-features/reports/src/hooks/useReportTemplates.ts

export type ReportFormat = "pdf" | "word" | "excel" | "markdown";

export interface ReportTemplate {
  template_id:    string;                   // unique; "<scope>:<name>"; scope = "platform" or vertical_id
  name:           string;                   // i18n key OR literal display name
  description:    string;                   // short
  formats:        ReportFormat[];           // which output formats this template supports
  declared_by:    "platform" | string;      // "platform" or vertical_id
  sections:       ReportSection[];          // ordered; renderer iterates
}

export interface ReportSection {
  section_id:     string;                   // unique within template
  heading_key:    string;                   // i18n key for section heading
  source_field:   "consensus" | "key_facts" | "open_questions" | "unresolved_disagreements"
                  | "final_constraints_status" | "meta";
  visualization:  "list" | "table" | "paragraph" | "stat";
  filter:         { field: string; op: "eq" | "ne" | "contains" | "gt"; value: string } | null;
  // Forward-compat: unknown source_field / visualization causes the section to be skipped
  // (with a server-side warning log) rather than failing the whole render.
}
```

### 6.2 Platform default templates

Two templates ship with `apps/api/reports/templates/` and are registered at boot:

#### `platform:default-comprehensive`

All 6 sections (consensus / key_facts / open_questions / unresolved_disagreements / final_constraints_status / meta). Supports all 4 formats.

#### `platform:default-summary`

3 sections (consensus / key_facts / meta). Supports all 4 formats.

### 6.3 Per-vertical templates

Verticals declare templates in their backend manifest (per `13-vertical-template-spec.md`). Forward-declaration of the manifest field:

```python
# in vertical's backend manifest.py
report_templates: list[ReportTemplate] = [
    ReportTemplate(
        template_id="vertical-a:executive-summary",
        name_key="vertical.vertical-a.report.executive_summary.name",
        description_key="vertical.vertical-a.report.executive_summary.desc",
        formats=["pdf", "word"],
        declared_by="vertical-a",
        sections=[...],  # vertical-specific arrangement
    ),
]
```

At boot (per `15-apps-api-spec.md` §boot):
1. apps/api iterates registered verticals' `report_templates`.
2. Each is registered in `apps/api/reports/templates/registry.py` under its `template_id`.
3. Frontend's `useReportTemplates()` calls `GET /api/reports/templates?vertical_id=<active>` and gets `platform:*` + `<active_vertical>:*` filtered list.

**No vertical can register `platform:*` templates.** The `template_id` prefix must match `declared_by`. Validated at registration; conflicts raise `TemplateRegistrationError`.

### 6.4 Template lookup

`POST /api/reports/render` resolves `template_id` against the registry. Unknown `template_id` returns 404 `TemplateNotFound`.

---

## §7 API endpoints (in apps/api)

These are forward-declared here; full apps/api spec in `15-apps-api-spec.md`.

### 7.1 `POST /api/reports/render`

```
POST /api/reports/render
  body:   { meeting_id: str, format: ReportFormat, template_id: str }
  auth:   required + permission "platform:render_report"
  200:    application/{format-mime}; binary body; Content-Disposition: attachment; filename="{meeting_id}-{template_short}.{ext}"
  400:    InvalidArgument (bad format, bad template_id structure)
  401/403: relayed from auth-service
  404:    MeetingNotFound (meeting doesn't exist) | TemplateNotFound
  409:    MeetingNotReady (meeting still running; outcome not available) — sets Retry-After: 5
  500:    RenderFailed (renderer crashed) | InternalError
  502:    StudioUnavailable (couldn't reach studio to fetch outcome)
```

**MIME types per format**:
- `pdf` → `application/pdf`
- `word` → `application/vnd.openxmlformats-officedocument.wordprocessingml.document`
- `excel` → `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`
- `markdown` → `text/markdown; charset=utf-8`

**Behavior.**
1. Look up `template_id` in registry (404 if not found).
2. Verify `format in template.formats` (400 `InvalidArgument` if not).
3. Call `studio_client.get_meeting_outcome(meeting_id)` (relays 404 / 409 / 502).
4. Dispatch to renderer based on `format`.
5. Stream response body; set Content-Disposition.
6. Log: meeting_id, template_id, format, render duration, byte size.

**Rendering time budget**: 10 s typical, 60 s hard cap. Beyond 60 s the renderer raises `RenderFailed{reason: "timeout"}`.

### 7.2 `GET /api/reports/templates`

```
GET /api/reports/templates
  query:  ?vertical_id=<active_vertical_id> (optional; default = no vertical filter)
  auth:   required
  200:    { data: list[ReportTemplate] }
            includes platform:* always + <vertical_id>:* if vertical_id provided
```

Returns templates the user can pick. Frontend caches per-active-vertical for the session via Zustand store inside the hook.

---

## §8 Hooks

### 8.1 `useReportRender`

```typescript
export interface UseReportRenderReturn {
  render(opts: { meeting_id: string; template_id: string; format: ReportFormat }): Promise<void>;
  isRendering:  boolean;
  lastError:    string | null;
  lastBytes:    Blob | null;
}

export function useReportRender(): UseReportRenderReturn;
```

**Behavior.** Internal `useState` for `isRendering` / `lastError` / `lastBytes`.
1. POST `/api/reports/render` with the request body via `fetch()`.
2. On 200: read response as Blob; trigger a download via `URL.createObjectURL(blob)` + temp `<a download>` click + revoke URL after 1s; set `lastBytes`.
3. On 4xx / 5xx: parse error envelope; set `lastError` (localized via `useI18n().t()` from `feature.reports.error.*`).
4. On `MeetingNotReady` (409 + Retry-After): show toast via `useToast().show({severity:"warning", title:"feature.reports.error.not_ready", body:`...{{seconds}}s` })`; do NOT auto-retry.

### 8.2 `useReportTemplates`

```typescript
export interface UseReportTemplatesReturn {
  templates:    ReportTemplate[];
  isLoading:    boolean;
  error:        string | null;
}

export function useReportTemplates(): UseReportTemplatesReturn;
```

**Behavior.**
1. On mount: read `useActiveVertical().active?.vertical_id`; call `fetch('/api/reports/templates?vertical_id=...')` inside a `useEffect`.
2. Result cached in a tiny Zustand store keyed by `vertical_id` (so vertical switch invalidates).
3. Re-fetch on vertical switch (hook re-runs on `useActiveVertical().active` change).

---

## §9 Error model (sealed)

```python
# apps/api/reports/models.py

class ReportsError(Exception):
    error_type:  str
    http_status: int
    message:     str

class TemplateNotFound(ReportsError):       ...   # 404
class RenderFailed(ReportsError):           ...   # 500  — renderer raised; extras: {renderer, reason}
# (MeetingNotFound, MeetingNotReady, MeetingFailed, StudioUnavailable, AuthRequired,
#  PermissionDenied, InvalidArgument, RateLimited surface from studio-client / auth-service
#  per their respective specs; this taxonomy adds ONLY the leaves owned by reports.)
```

**Per-error extras**:
- `TemplateNotFound`: `{"template_id": "<id>"}`
- `RenderFailed`: `{"renderer": "pdf|word|excel|markdown", "reason": "<short>", "trace_id": "<uuid>"}`

**Total leaves owned by this feature**: 2. The rest is delegated.

---

## §10 Test matrix

### 10.1 Component tests

| scenario | preconditions | expected | test_id |
|---|---|---|---|
| outcome loading | studio mock pending | spinner visible | `t_rv_loading` |
| outcome ready (consensus) | mock returns OutcomeResponse with outcome | full UI rendered; preview shows rendered Markdown via react-markdown | `t_rv_ready` |
| outcome not ready | studio raises MeetingNotReady | placeholder + back link | `t_rv_not_ready` |
| outcome failed | OutcomeResponse with outcome=null, error set | "meeting failed" placeholder | `t_rv_failed` |
| outcome not found | studio raises NotFound | 404 page | `t_rv_not_found` |
| template switch | user picks "default-summary" | preview re-renders with summary template (renderMarkdown re-called via React state change) | `t_rv_template_switch` |
| format switch | user picks Word | export button label updates; preview unchanged | `t_rv_format_switch` |
| export click triggers download | user clicks export | POST /render called; Blob URL created; download attempted | `t_rv_export_download` |
| copy-clipboard | user clicks copy | Markdown text on clipboard via navigator.clipboard.writeText | `t_rv_copy_md` |
| copy-link | user clicks share-link | URL on clipboard | `t_rv_copy_link` |
| forward-compat concluded_by | unknown enum value | gray chip with tooltip showing raw value | `t_rv_concluded_by_forward_compat` |
| chip per concluded_by | each documented value | correct color per §4.1 | `t_rv_chip_colors` |
| empty consensus | outcome with consensus=[] | "No consensus reached" placeholder in section | `t_rv_empty_consensus` |
| missing merkle_root | outcome with merkle_root=null | footer hides audit-anchor row | `t_rv_no_merkle` |

### 10.2 Renderer tests (snapshot-based)

For each renderer (`pdf`, `word`, `excel`, `markdown`), 3 snapshot tests:

| renderer | input fixture | snapshot | test_id |
|---|---|---|---|
| markdown | `fixtures/outcome_consensus_reached.json` + comprehensive template | `markdown-snapshots/consensus-comprehensive.md` | `t_md_consensus_comprehensive` |
| markdown | `outcome_max_turns.json` + summary template | `markdown-snapshots/max-turns-summary.md` | `t_md_max_turns_summary` |
| markdown | `outcome_failed.json` (outcome=null) | renderer raises `RenderFailed{reason: "no_outcome"}` | `t_md_no_outcome` |
| pdf | `outcome_consensus_reached.json` + comprehensive | non-empty bytes; first 4 bytes = `%PDF` | `t_pdf_consensus` |
| pdf | (same) — render twice | byte-identical (deterministic; same input + same template = same output) | `t_pdf_deterministic` |
| pdf | timeout fixture (renderer sleep 65s) | `RenderFailed{reason: "timeout"}` | `t_pdf_timeout` |
| word | `outcome_consensus_reached.json` | non-empty bytes; first 4 bytes = `PK\x03\x04` | `t_word_consensus` |
| word | (same) | deterministic | `t_word_deterministic` |
| excel | `outcome_consensus_reached.json` | first 4 bytes = `PK\x03\x04`; opens with 6 sheets per default-comprehensive | `t_excel_consensus_sheets` |

**Cross-language parity** (Markdown only): `t_md_parity_client_server` — given the same fixture, client TS `renderMarkdown(...)` and server Python `render_markdown(...)` produce byte-identical output. Critical for preview-vs-export consistency.

**Display test for `<RenderPreview>`**: `t_preview_renders_html` — given the Markdown text output, react-markdown renders an `<h1>` for `# title` etc. (separate from the parity test).

### 10.3 API endpoint tests

| scenario | request | expected | test_id |
|---|---|---|---|
| happy pdf | POST /render valid | 200 + binary + correct Content-Disposition | `t_api_pdf_happy` |
| unknown template | template_id="nope" | 404 `template_not_found` | `t_api_template_404` |
| unsupported format for template | summary template + excel (if filtered) | 400 `invalid_argument` | `t_api_format_unsupported` |
| meeting not ready | studio raises MeetingNotReady | 409 + Retry-After: 5 | `t_api_not_ready` |
| meeting not found | studio raises NotFound | 404 | `t_api_not_found` |
| studio down | studio raises StudioUnavailable | 502 | `t_api_studio_down` |
| no auth | no token | 401 (relayed) | `t_api_no_auth` |
| no permission | user lacks platform:render_report | 403 (relayed) | `t_api_no_perm` |
| GET templates filter by vertical | vertical_id=v-a | returns platform:* + v-a:* templates | `t_api_templates_vertical` |
| GET templates no vertical | no vertical_id | platform:* only | `t_api_templates_platform_only` |

---

## §11 i18n

Lives at `packages/platform-features/reports/src/i18n/{zh,en}.json`. Merged into i18next at feature load under namespace `feature.reports.*`. Interpolation uses `{{var}}`.

```json
{
  "feature.reports.title": "Report",
  "feature.reports.loading_outcome": "Loading outcome…",
  "feature.reports.outcome_not_ready": "Meeting still in progress; report becomes available when finalized.",
  "feature.reports.outcome_failed": "This meeting failed; no report available.",
  "feature.reports.back_to_meeting": "Back to meeting",
  "feature.reports.template_not_available": "Template not available.",

  "feature.reports.section.consensus": "Consensus",
  "feature.reports.section.key_facts": "Key Facts",
  "feature.reports.section.open_questions": "Open Questions",
  "feature.reports.section.unresolved_disagreements": "Unresolved Disagreements",
  "feature.reports.section.constraints": "Constraints",
  "feature.reports.section.meta": "Meeting Information",

  "feature.reports.empty.consensus": "No consensus reached.",
  "feature.reports.empty.key_facts": "No key facts identified.",
  "feature.reports.empty.questions": "No open questions remain.",

  "feature.reports.concluded_by.consensus_reached":      "Consensus reached",
  "feature.reports.concluded_by.max_turns":              "Reached max turns",
  "feature.reports.concluded_by.deadline":               "Deadline reached",
  "feature.reports.concluded_by.human_stop":             "Stopped by user",
  "feature.reports.concluded_by.constraint_violation":   "Constraint violated",
  "feature.reports.concluded_by.concluded_by_facilitator":"Facilitator concluded",

  "feature.reports.template_picker": "Template",
  "feature.reports.format_picker": "Format",
  "feature.reports.export_button": "Export {{format}}",
  "feature.reports.copy_clipboard": "Copy as Markdown",
  "feature.reports.copy_link": "Copy report link",

  "feature.reports.error.template_not_found": "That template is not available.",
  "feature.reports.error.render_failed":      "Could not render report ({{renderer}}). Try again.",
  "feature.reports.error.studio_unavailable": "Studio is unavailable. Try again shortly.",
  "feature.reports.error.not_ready":          "Outcome not ready yet; try again in {{seconds}}s.",

  "feature.reports.audit.anchor_label":       "Audit anchor",
  "feature.reports.audit.rendered_at":        "Rendered at",
  "feature.reports.audit.studio_meeting_id":  "Studio meeting id"
}
```

`zh.json` mirrors with Chinese.

---

## §12 Why this design — load-bearing decisions

**Why product-side render (not studio-side).**
Per `01-studio-client-spec.md` §11.3: studio doesn't render reports. Even if it did, render templates need to vary per vertical (a vertical may have a domain-specific report layout); coupling render templates to studio would force studio to know about verticals, violating the boundary. Product is the right layer.
*Considered and rejected.* **`POST /v1/meetings/{id}/render?format=pdf` on studio** — studio rejects (per its contract); also couples vertical-specific layout to studio.

**Why server-side for binary formats (PDF / Word / Excel) but client-side for Markdown.**
- Bundle size: jsPDF + docx.js + xlsx is ~600KB-1MB combined; that's expensive for every page load. Server has the libs already.
- Determinism: server-side rendering is more reliable across browsers; binary file generation in browsers has known edge cases (font embedding, page breaks).
- Markdown: trivial to render client-side text-wise (<100 LOC); display via `react-markdown` (already a dep from spec 05's MessageEmittedCard); avoids a network round trip for the always-on preview.
*Considered and rejected.* **All client-side** — bundle bloat. **All server-side** — preview requires a round trip per template/format change; sluggish UX.

**Why renderers are pure functions (no IO, no LLM).**
Renderers are deterministic transformations of `MeetingOutcome` data. Snapshot tests verify byte-identity given the same input. Any LLM call here would re-introduce the agent-logic boundary we just shipped studio-client to enforce.
*Considered and rejected.* **"Smart" rendering with LLM-generated summaries** — would violate Red Line #5; also non-deterministic.

**Why no caching of rendered artifacts in v0.1.**
Outcomes are immutable post-finalize, so cache would be safe — but rendering is fast (< 1s typical), the cache adds operational complexity (invalidation on template change, storage management), and CONFLICTS with the "renderer is a pure function" property which makes re-render essentially free. v0.2 can add caching transparently.
*Considered and rejected.* **Disk-cached PDFs keyed by (meeting_id, template_id, format)** — premature optimization.

**Why per-vertical templates via manifest declaration (not config files).**
Consistent with the rest of the vertical extension model (P10 + `02` §3): verticals contribute capabilities through their manifest; the platform discovers them at boot. Config files would be a separate registration mechanism.
*Considered and rejected.* **YAML config in `apps/api/reports/templates/`** — bypasses the manifest; harder for a vertical to ship templates with its package.

**Why `template_id` namespace prefix `<scope>:<name>` enforced.**
Prevents verticals from masquerading as platform templates. A future template ID collision is impossible because vertical IDs are unique (per `02` §3.2 `duplicate_id` check) and the prefix matches `declared_by`.
*Considered and rejected.* **Flat IDs with `declared_by` field only** — IDs would collide; manifest validation gets harder.

**Why the route lives at `/platform/reports/:meeting_id` and the bare `/platform/reports` redirects to knowledge.**
Reports are meeting-bound; opening "reports" without context is meaningless. Knowledge is the natural place to discover past meetings; redirecting there is what users actually want. React Router v6 supports this via a no-component route with a `loader: () => redirect(...)`.
*Considered and rejected.* **`/platform/reports` shows a list of all reports** — duplicates knowledge browser; UX confusion about which is the "right" entry point.

**Why Markdown preview uses `react-markdown` for display (vs raw `<pre>`).**
The preview is for content; users want to see formatted text (headings, lists, tables), not raw `**bold**` syntax. `react-markdown` is already a dep (spec 05 uses it for utterances) — no new bundle cost. Format-specific previews (literally rendering a PDF in browser) would re-introduce the bundle bloat we avoided.
*Considered and rejected.* **`<pre>` raw text** — defeats "preview" purpose. **Format-specific previews** — pulls in the binary-format libs we kept server-side.

**Why client-server Markdown TEXT parity is a hard test.**
If the preview shows X (rendered from client-generated MD text) but the exported Markdown file shows Y (server-generated MD text), users lose trust. A snapshot test on a fixed fixture forces both implementations to evolve together.
*Considered and rejected.* **Two implementations free to drift** — likely subtle bugs.

**Why `useReportRender` uses `fetch()` + Blob (not XHR).**
Renders complete in seconds (server-side); progress tracking is unnecessary. `fetch()` + `response.blob()` + `URL.createObjectURL()` is the canonical modern download pattern; XHR is legacy. Spec 09 (uploads) does use XHR — but for legitimate upload progress tracking, not download.
*Considered and rejected.* **XHR for downloads** — XHR for downloads has no progress benefit (server controls timing); modern fetch is cleaner.

---

## §13 Downstream impact

| Spec | Adjustment |
|---|---|
| `05-feature-agora-spec.md` | OutcomePanel "View report" calls `onViewReportClicked`; AgoraView handles by `navigate('/platform/reports/' + meeting_id)`. Already reflected in 05 §11. |
| `07-feature-knowledge-spec.md` | Each completed meeting row links to `/platform/reports/<id>` via "Report" action. |
| `13-vertical-template-spec.md` | Backend manifest's `report_templates: list[ReportTemplate]` field; validation rule that `template_id` prefix matches `declared_by`. |
| `14-...` (first concrete vertical) | MAY ship vertical-specific templates; not required for v0.1 — verticals can ship none and rely on platform defaults. |
| `15-apps-api-spec.md` | Mounts `/api/reports/*` router; loads server-side renderers (reportlab, python-docx, openpyxl) as Python deps; runs template-registry boot dance (§6.3); declares `meeting_metadata` is OUT of reports' scope (different table; reports doesn't store anything). |
| `16-apps-frontend-spec.md` | `react-markdown` + `remark-gfm` already declared as deps for spec 05 (agora's MessageEmittedCard); reports re-uses them — no new dep. |
| `17-substitution-tests-spec.md` | The Markdown parity test `t_md_parity_client_server` joins the substitution suite (cross-runtime parity, not pseudo↔http parity, but same discipline). |

---

## §14 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (caching, diff, sharing, scheduled, LaTeX, print-CSS, per-section permissions)
- [ ] Module layout (§1) covers frontend feature (.tsx files) + server-side renderer module (.py files)
- [ ] Permissions declared (§1.3) and route declared (§1.4) using React Router v6 RouteObject + lazy() + makePermissionLoader
- [ ] All 5 visual states (§2.2) documented
- [ ] All 6 components (§4) have full TS Props interface + onXxx callback props + render rules + accessibility notes
- [ ] All 4 renderers (§5) have signatures + library choice + Why
- [ ] Markdown TEXT parity (client/server) called out as critical (§5.5 + §10.2); display in browser via react-markdown is a separate concern with its own test
- [ ] Template interface (§6.1) + 2 platform default templates (§6.2) + per-vertical extension (§6.3) all defined
- [ ] `POST /api/reports/render` (§7.1) + `GET /api/reports/templates` (§7.2) signatures complete with status codes + error mapping + MIME types
- [ ] Hooks (§8) signatures + behavior contracts; useReportRender uses fetch+Blob pattern; useReportTemplates uses Zustand store for per-vertical cache
- [ ] Sealed error taxonomy (§9): 2 leaves owned by reports + 8 delegated leaves named
- [ ] Test matrix (§10): components (~14), renderer snapshots (~9 + parity + react-markdown display), API (~10); ≥ 30 rows total
- [ ] i18n keys (§11) for every user-visible string with en values; interpolation uses `{{var}}` (i18next syntax)
- [ ] Why-this / why-not (§12) for ≥ 8 load-bearing decisions including React-specific ones (react-markdown for preview display; fetch+Blob for download)
- [ ] Downstream impact (§13) lists every spec affected; notes react-markdown is shared dep with spec 05
- [ ] No business / domain / product / agent-role string literals (uses neutral `vertical-a`, fixture filenames)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] Renderers explicitly documented as pure functions; no LLM, no IO beyond input
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/06-feature-reports-spec.md`
