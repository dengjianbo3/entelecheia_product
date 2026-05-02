# 10 — `wizard` feature v0.1 spec

> **Status**: v0.1 contract for the meeting-creation wizard. **Frontend stack**: React 18 + TypeScript + Zustand + React Router v6 + react-i18next + Tailwind, plus `focus-trap-react` (CancelConfirmDialog; shared dep with 05/08/09).
> **Lives at**: `packages/platform-features/wizard/` (frontend) + `apps/api/meetings/` (the meeting_metadata endpoint, also consumed by `05-feature-agora-spec.md` §7).
> **Consumes**: `01-studio-client-spec.md` §7.1 (`list_projects`), §7.5 (`run_meeting`); `02-platform-shell-spec.md` (hooks + routing + permissions); `03-auth-service-spec.md` (`platform:run_meeting`); `09-feature-uploads-spec.md` (`useUpload`, `useUploadHandlers`, `MaterialDescriptor`).
> **Forwards to**: `05-feature-agora-spec.md` (navigate to agora on success).
> **Forwarded to from**: `02-platform-shell-spec.md` sidebar; `07-feature-knowledge-spec.md` "+ Start meeting" CTA; agora's "Start new meeting" empty-state CTA.
> **Supersedes**: the Vue version of this spec (committed in `53c8f7f`); React migration per session decision 2026-05-03.

---

## Mission

This file defines the wizard — a 4-step guided flow that turns "I want to start a meeting" into a successful `studio.run_meeting()` + handoff to agora. The wizard collects (1) project, (2) topic, (3) materials, (4) confirmation; submits to studio; persists product-side meeting metadata so agora can render materials; navigates to agora. All state survives page reload (sessionStorage) but is ephemeral (cleared on success / cancel / vertical switch).

**Hard rule** (P3 + P5): wizard does NOT fabricate any state studio doesn't already track. The product-side `meeting_metadata` table (introduced by `05-feature-agora-spec.md` §7) holds **only** the descriptors the user submitted at create time — it's a faithful snapshot of inputs, not a parallel meeting state. Studio's `MeetingHandle` is the source of truth for the meeting's existence and lifecycle.

---

## Scope

**Covers.**
- Module layout under `packages/platform-features/wizard/`.
- 2 routes: `/platform/wizard` (step 1; no preselect), `/platform/wizard/:project_id` (skip to step 2 with project preselected).
- Top-level `<WizardView>` lifecycle: mount → restore draft (or fresh) → step navigation → submit → handoff.
- 4 step components: `<ProjectStep>`, `<TopicStep>`, `<MaterialsStep>`, `<ReviewStep>` with validation rules per step.
- Supporting components: `<WizardHeader>` (step indicator + cancel), `<WizardNavigation>` (back/next/submit buttons), `<ProjectCard>` (project tile in step 1), `<CancelConfirmDialog>` (native dialog + focus-trap-react).
- 3 React hooks: `useWizardDraft` (reactive draft + sessionStorage), `useWizardProjects` (filtered project list), `useWizardSubmit` (the full submit flow).
- Per-step validation (block "Next" until valid; surface errors inline).
- Draft persistence: sessionStorage keyed by `wizard_draft_<vertical_id>`; restored on mount; cleared on success / explicit cancel / vertical switch.
- Submit sequence: `studio.run_meeting` → `POST /api/meetings/:id/metadata` (best-effort) → clear draft → React Router `navigate('/platform/agora/:id')`.
- Forward-declared apps/api endpoint `POST /api/meetings/{meeting_id}/metadata` (full spec lives in `15-apps-api-spec.md` §meeting-metadata).
- Sealed error taxonomy at the wizard layer (0 leaves owned + relayed leaves).
- Test matrix per step + per hook + the full submit flow.
- v0.2 forward-compat: when studio adds `MeetingRunConfig` knobs surfaced to users, wizard adds an optional advanced-settings step without breaking existing draft schema.

**Does not cover.**
- Project authoring — that's studio admin work; wizard ONLY picks among `published` projects.
- Studio's `run_meeting` Protocol — `01` §7.5.
- Materials buffering / upload UI — `09-feature-uploads-spec.md`. Wizard ONLY consumes `useUpload` + `useUploadHandlers` for the materials step.
- The `meeting_metadata` table schema — full schema in `15-apps-api-spec.md`. Forward-declared minimally here.
- Agora rendering — `05-feature-agora-spec.md`. Wizard hands off and stops.
- Per-meeting cost ceiling, max-rounds, locale overrides — these knobs live in `ProjectSpec.meeting_defaults` (project author's job, not user's). Wizard accepts no advanced config in v0.1.
- Concurrent multi-meeting starts. v0.1 wizard is one-meeting-at-a-time.

**Out of scope for v0.1.**
- Saving named drafts ("templates") for later reuse.
- Recommending projects based on prior usage.
- Pre-filling topic from clipboard / URL query / paste.
- Voice / audio topic input.
- Multi-step branching (different flows per project type).
- "Schedule for later" — meetings start immediately.
- Cost preview ("this meeting will cost ~$X"). Studio doesn't expose cost estimates.
- Sharing in-progress drafts with another user.

---

## §1 Module layout

```
packages/platform-features/wizard/
├── src/
│   ├── index.ts                              # exports WizardView + wizardRoutes
│   ├── WizardView.tsx                        # /platform/wizard top-level
│   ├── components/
│   │   ├── WizardHeader.tsx                  # step indicator (1 of 4) + project name + cancel
│   │   ├── WizardNavigation.tsx              # back / next / submit buttons
│   │   ├── ProjectCard.tsx                   # one project tile in step 1
│   │   ├── CancelConfirmDialog.tsx           # native <dialog> + focus-trap-react
│   │   └── steps/
│   │       ├── ProjectStep.tsx               # step 1: pick a project
│   │       ├── TopicStep.tsx                 # step 2: enter topic
│   │       ├── MaterialsStep.tsx             # step 3: attach materials (uses 09's useUpload)
│   │       └── ReviewStep.tsx                # step 4: review + submit
│   ├── hooks/
│   │   ├── useWizardDraft.ts                 # reactive draft + sessionStorage sync
│   │   ├── useWizardProjects.ts              # filtered project list (vertical-scoped)
│   │   └── useWizardSubmit.ts                # full submit flow + error mapping
│   ├── stores/
│   │   └── useWizardDraftStore.ts            # Zustand store backing useWizardDraft
│   ├── routes.ts
│   ├── permissions.ts
│   └── i18n/
│       ├── zh.json
│       └── en.json
├── tests/
└── package.json                              # depends on react, react-dom, react-router-dom,
                                              #            zustand, react-i18next,
                                              #            focus-trap-react (shared with 05/08/09)
```

**No backend in this package.** The `POST /api/meetings/:id/metadata` endpoint lives in `apps/api/meetings/` (per `15-apps-api-spec.md` §meeting-metadata; forward-declared in `05-feature-agora-spec.md` §7).

### 1.1 Permissions declared

```typescript
// packages/platform-features/wizard/src/permissions.ts
export const WIZARD_PERMISSIONS = [
  // Wizard's own gate is platform:run_meeting (already declared in 03 §5.2).
  // Listed here for the boot-dance reaffirmation.
  { code: "platform:run_meeting",   description: "Open the meeting wizard and start meetings" },
  { code: "platform:list_projects", description: "List projects in step 1" },
  { code: "platform:upload",        description: "Attach materials in step 3" },
] as const;
```

### 1.2 Routes declared

```typescript
// packages/platform-features/wizard/src/routes.ts
import type { RouteObject } from "react-router-dom";
import { makePermissionsLoader, makePermissionLoader } from "@entelecheia/platform-shell";

export const wizardRoutes: RouteObject[] = [
  {
    path: "/platform/wizard",
    lazy: async () => {
      const { WizardView } = await import("./WizardView");
      return { Component: WizardView };
    },
    loader: makePermissionsLoader(["platform:run_meeting", "platform:list_projects"]),
    handle: { title_key: "feature.wizard.title" },
  },
  {
    path: "/platform/wizard/:project_id",
    lazy: async () => {
      const { WizardView } = await import("./WizardView");
      return { Component: WizardView };
    },
    loader: makePermissionLoader("platform:run_meeting"),
    handle: { title_key: "feature.wizard.title" },
  },
];
```

Same component for both routes; `:project_id` variant pre-selects + advances to step 2 on mount via `useParams()`.

---

## §2 Top-level `<WizardView>` lifecycle

### 2.1 Component contract

```typescript
import { useParams, useNavigate } from "react-router-dom";
import { useState } from "react";
import { useActiveVertical } from "@entelecheia/platform-shell";
import { useWizardDraft } from "./hooks/useWizardDraft";
import { useWizardProjects } from "./hooks/useWizardProjects";
import { useWizardSubmit } from "./hooks/useWizardSubmit";

export function WizardView() {
  const { project_id: urlProjectId } = useParams<{ project_id?: string }>();
  const { active: activeVertical } = useActiveVertical();
  const navigate = useNavigate();

  // Reactive draft + sessionStorage
  const { draft, currentStep, setProject, setTopic, addMaterial, removeMaterial,
          setStep, isStepValid, reset } = useWizardDraft({
    activeVerticalId: activeVertical?.vertical_id ?? null,
    initialProjectId: urlProjectId ?? null,
  });

  // Project list (vertical-scoped)
  const { projects, isLoadingProjects, projectsError } = useWizardProjects(activeVertical);

  // Submit flow
  const { submit, isSubmitting, submitError } = useWizardSubmit();

  // Cancel confirm
  const [showCancelConfirm, setShowCancelConfirm] = useState(false);

  function onCancel() {
    if (draft.topic || draft.materials.length > 0) {
      setShowCancelConfirm(true);
    } else {
      reset();
      navigate("/platform/dashboard");
    }
  }

  async function onSubmit() {
    try {
      await submit(draft);    // navigates to agora on success
    } catch {
      /* error already in submitError state; UI shows */
    }
  }

  // ... render header + WizardNavigation + step component (current step)
  //     + CancelConfirmDialog (when showCancelConfirm)
}
```

### 2.2 Status states

| State | Trigger | Visual |
|---|---|---|
| `loading_projects` | step 1, projects fetching | step 1 with spinner |
| `step_1_no_projects` | step 1, projects fetch returned empty | inline empty state with "Switch vertical" link |
| `step_1_projects_error` | step 1, projects fetch failed | inline error + retry button |
| `step_n` (n ∈ {1..4}) | normal flow | full UI with current step's content |
| `submitting` | user clicked "Start" in step 4 | full-page overlay with spinner + "Starting meeting…" |
| `submit_error_recoverable` | studio raised retryable error (StudioUnavailable / RateLimited) | step 4 with error banner + Retry button; draft retained |
| `submit_error_fatal` | studio raised non-retryable error (PublishValidation / NotFound / InvalidArgument) | step 4 with error banner + Back button to fix; draft retained |

### 2.3 Permission check

Route loader (per `02` §4.1) ensures `platform:run_meeting` + (for `/wizard` no-preselect) `platform:list_projects`. Missing permission → redirect to dashboard with toast (loader-driven).

---

## §3 The 4 steps

### 3.1 Step 1 — `<ProjectStep>`

```typescript
export interface ProjectStepProps {
  projects:           ProjectSummary[];        // already vertical-filtered
  selected_project_id: string | null;
  is_loading:         boolean;
  error:              string | null;
  onSelect:           (project_id: string) => void;
  onRetry:            () => void;
}

export function ProjectStep(props: ProjectStepProps): React.ReactElement;
```

**Renders.**
- Grid of `<ProjectCard>` tiles (one per project).
- Each card: project `display_name`, `description` (truncated 200 chars), `paradigm_kind` chip, `version` indicator.
- Selected card has accent border.
- Clicking a card calls `onSelect`.
- Empty state: "No projects available for this vertical. Switch vertical or contact admin."
- Loading: skeleton tiles.
- Error: red banner + "Retry" button.

**Validation (for `<WizardNavigation>`).**
- Step is valid when `selected_project_id !== null` AND that project's `status === "published"`.

**Auto-advance.** When mounted with `urlProjectId` non-null AND that project exists in the fetched list AND is published: auto-advance to step 2 via `useEffect` (skip the manual click).

### 3.2 Step 2 — `<TopicStep>`

```typescript
export interface TopicStepProps {
  topic:           string;
  project:         ProjectSummary;       // selected; displayed for context
  onTopicChange:   (v: string) => void;
}

export function TopicStep(props: TopicStepProps): React.ReactElement;
```

**Renders.**
- Project context card at top: "Starting meeting in: <project name>".
- Multi-line `<textarea>` for topic with `value={props.topic}` + `onChange`.
- Character counter: `{used}/2000` (red when over).
- Helper text below textarea: "Describe the question or topic the agents should deliberate on. Be specific — agents work better with focused prompts."

**Validation.**
- 1 ≤ length ≤ 2000 chars (matches studio §3.6 + `01` §7.5 invariant).
- Trim whitespace before length check (single-space-only is invalid).
- Validation runs on every keystroke (synchronous, no debounce — cheap).

**Pre-fill.** If `draft.topic` was set previously (e.g., user went back from step 3), re-populate via controlled input.

### 3.3 Step 3 — `<MaterialsStep>`

```typescript
export interface MaterialsStepProps {
  attached_materials: AttachedMaterial[];
  onAddMaterial:    (upload: Upload, handler_kind: string) => void;
  onRemoveMaterial: (upload_id: string) => void;
}

export interface AttachedMaterial {
  upload_id:           string;
  display_name:        string;
  size_bytes:          number;
  mime_type:           string;
  studio_material_kind: "brief" | "data";
  handler_kind:        string;
  preview_url:         string | null;
}

export function MaterialsStep(props: MaterialsStepProps): React.ReactElement;
```

**Renders.**
- Heading: "Attach materials (optional)".
- Helper: "Briefs, data files, links — context the agents should read before deliberating."
- Embeds `<UploadDropZone>` from `09-feature-uploads-spec.md` (with `<HandlerPicker>`).
- Below: list of currently-attached materials with name, size, kind chip, remove button (×).
- Empty state allowed: "No materials attached. You can proceed without any."

**Behavior.**
- `<UploadDropZone>` calls `onFilesDropped`; for each file, the step calls `useUpload().upload()` (from 09); on success, calls `onAddMaterial`.
- Remove button: `onRemoveMaterial`; the upload remains in `/api/uploads` (user's library) but is dropped from this draft.

**Validation.**
- Always valid (materials are optional). Step 3 → step 4 button always enabled.

**Visual flag** for in-flight uploads: rows show progress bar via `useUploadProgressStore`; "Next" button disabled while ANY upload is in-flight (`useUpload().inFlightCount > 0`) — prevents user clicking Next before files finish posting; otherwise their `upload_id` would be missing from the draft at submit time.

### 3.4 Step 4 — `<ReviewStep>`

```typescript
export interface ReviewStepProps {
  draft:            WizardDraft;
  project:          ProjectSummary;
  is_submitting:    boolean;
  submit_error:     string | null;
  submit_error_kind: "recoverable" | "fatal" | null;
  onSubmit:         () => void;
  onBackToStep:     (step: 1 | 2 | 3) => void;
}

export function ReviewStep(props: ReviewStepProps): React.ReactElement;
```

**Renders.**
- Heading: "Review and start meeting".
- 3 collapsible review sections (each with `<details>` element or controlled state):
  1. **Project**: name + description + version + paradigm; "Edit" button → `onBackToStep(1)`.
  2. **Topic**: full topic text (no truncation here — last chance to read); "Edit" → step 2.
  3. **Materials**: list of attached materials with names + kinds; "Edit" → step 3.
- Footer: "Start meeting" primary button.
- During submit: button disabled, full-page overlay (per §2.2 `submitting` state).
- On error:
  - Recoverable: red banner with message + "Retry" button.
  - Fatal: red banner + "Go back to fix" button (jumps to relevant step based on error type — see §5.2).

---

## §4 Hooks

### 4.1 `useWizardDraft`

```typescript
export interface WizardDraft {
  draft_version:   1;                          // schema version for migration
  vertical_id:     string;                     // snapshot at create time
  project_id:      string | null;
  topic:           string;
  materials:       AttachedMaterial[];
  current_step:    1 | 2 | 3 | 4;
  created_at:      string;                     // ISO; for stale-draft cleanup
}

export interface UseWizardDraftOptions {
  activeVerticalId: string | null;
  initialProjectId: string | null;
}

export interface UseWizardDraftReturn {
  draft:           WizardDraft;
  currentStep:     1 | 2 | 3 | 4;
  setProject:      (project_id: string) => void;
  setTopic:        (v: string) => void;
  addMaterial:     (m: AttachedMaterial) => void;
  removeMaterial:  (upload_id: string) => void;
  setStep:         (step: 1 | 2 | 3 | 4) => void;
  isStepValid:     (step: 1 | 2 | 3 | 4) => boolean;
  reset:           () => void;
}

export function useWizardDraft(opts: UseWizardDraftOptions): UseWizardDraftReturn;
```

**Behavior** (backed by `useWizardDraftStore` Zustand store keyed by `vertical_id`).

1. **Initialization** (on mount, via `useEffect([opts.activeVerticalId])`):
   - Read sessionStorage key `wizard_draft_<vertical_id>`.
   - If found AND `draft.vertical_id === activeVerticalId`: restore.
   - Else: create fresh draft with `project_id = opts.initialProjectId`, `current_step = opts.initialProjectId ? 2 : 1`.
2. **Persistence.** Every mutation triggers a `useEffect` that writes the full draft to sessionStorage (debounced 100 ms via `setTimeout` in the effect).
3. **Vertical change.** When `opts.activeVerticalId` changes mid-wizard: `reset()` is called automatically (effect with `[opts.activeVerticalId]` dep); user is bumped to step 1; toast notifies "Vertical switched; wizard reset".
4. **Stale draft cleanup.** On init, if a restored draft's `created_at` is > 7 days old, discard + start fresh.
5. **`reset()`** clears sessionStorage + draft state; `current_step` returns to 1.

**Schema versioning.** `draft_version: 1` is a hardcoded literal. v0.2 may bump to 2; the restore logic checks the version and migrates (or discards if no migration path).

### 4.2 `useWizardProjects`

```typescript
import type { VerticalManifest } from "@entelecheia/platform-shell";

export interface UseWizardProjectsReturn {
  projects:        ProjectSummary[];
  isLoadingProjects: boolean;
  projectsError:   string | null;
  refresh:         () => Promise<void>;
}

export function useWizardProjects(activeVertical: VerticalManifest | null): UseWizardProjectsReturn;
```

**Behavior.** On mount + active-vertical change (`useEffect([activeVertical?.vertical_id])`):
1. Compute `project_id_in = activeVertical?.default_project_filter.project_id_in ?? []`.
2. `studio.list_projects({ status: "published", limit: 200 })` via `useStudio()`.
3. Filter client-side to `spec_id in project_id_in`.
4. Sort by `display_name` ascending.
5. Cache per-vertical for the session via `useState` + `useRef<Map>` (or small Zustand store; choice is implementation detail).
6. AbortController cleanup on unmount.

**Fetch errors** stored in `projectsError` ref (localized message); rest of wizard renders empty step-1 state.

### 4.3 `useWizardSubmit`

```typescript
export interface UseWizardSubmitReturn {
  submit(draft: WizardDraft): Promise<MeetingHandle>;     // navigates on success
  isSubmitting: boolean;
  submitError:  { message: string; kind: "recoverable" | "fatal"; back_to_step?: 1 | 2 | 3 } | null;
}

export function useWizardSubmit(): UseWizardSubmitReturn;
```

**Behavior.** See §5 for the full submit flow. Internal `useState` for `isSubmitting` + `submitError`. Calls `useNavigate()` to go to agora on success.

---

## §5 Submit flow

### 5.1 The 4-phase sequence

```typescript
async function submit(draft: WizardDraft): Promise<MeetingHandle> {
  setIsSubmitting(true);
  setSubmitError(null);

  // ── Phase 1: Build inline materials ────────────────────────────────
  const inlineMaterials: Material[] = [];
  for (const m of draft.materials) {
    const blob = await fetchUploadContent(m.upload_id);   // GET /api/uploads/:id/content
    const content = m.studio_material_kind === "brief"
      ? await blob.text()
      : safeParseStructured(await blob.text(), m.mime_type);
    inlineMaterials.push({
      kind: m.studio_material_kind,
      name: m.display_name,
      content,
    });
  }

  // ── Phase 2: studio.run_meeting ───────────────────────────────────
  let handle: MeetingHandle;
  try {
    handle = await studio.run_meeting({
      project_id: draft.project_id!,
      topic:      draft.topic,
      materials:  inlineMaterials,
      user_id:    useUserStore.getState().user!.user_id,
    });
  } catch (err) {
    setIsSubmitting(false);
    setSubmitError(mapStudioErrorToSubmitError(err));   // see §5.2
    throw err;
  }

  // ── Phase 3: persist meeting metadata (best-effort) ────────────────
  try {
    await postMeetingMetadata(handle.meeting_id, {
      project_id:  draft.project_id!,
      project_version: handle.project_version,
      user_id:     useUserStore.getState().user!.user_id,
      topic:       draft.topic,
      materials:   draft.materials.map(m => ({
        upload_id:  m.upload_id,
        name:       m.display_name,
        kind:       m.studio_material_kind,
        size_bytes: m.size_bytes,
        preview_url: m.preview_url,
      })),
    });
  } catch (err) {
    // Best-effort: meeting started successfully; metadata persistence failed.
    useToast().show({
      severity: "warning",
      title:    "feature.wizard.warning.metadata_failed",
    });
  }

  // ── Phase 4: clear draft + navigate ───────────────────────────────
  reset();
  setIsSubmitting(false);
  navigate(`/platform/agora/${handle.meeting_id}`);
  return handle;
}
```

### 5.2 Error mapping

```typescript
function mapStudioErrorToSubmitError(err: unknown):
  { message: string; kind: "recoverable" | "fatal"; back_to_step?: 1 | 2 | 3 }
{
  if (err instanceof NotFound) {
    return { message: t("feature.wizard.error.project_not_found"), kind: "fatal", back_to_step: 1 };
  }
  if (err instanceof PublishValidation) {
    return { message: t("feature.wizard.error.project_not_published"), kind: "fatal", back_to_step: 1 };
  }
  if (err instanceof InvalidArgument) {
    return { message: t("feature.wizard.error.invalid_argument"), kind: "fatal", back_to_step: 2 };
  }
  if (err instanceof StudioUnavailable) {
    return { message: t("feature.wizard.error.studio_unavailable"), kind: "recoverable" };
  }
  if (err instanceof RateLimited) {
    return { message: t("feature.wizard.error.rate_limited", { seconds: err.extras?.retry_after_seconds ?? 60 }), kind: "recoverable" };
  }
  if (err instanceof AuthRequired) {
    return { message: t("error.auth.auth_required"), kind: "fatal" };
  }
  return { message: t("feature.wizard.error.generic"), kind: "fatal" };
}
```

**Recoverable**: stay in wizard step 4; user can click Retry; draft retained.
**Fatal**: stay in wizard step 4 with "Go back to fix" button that jumps to `back_to_step` (or stays on step 4 if no back-to suggestion); draft retained for editing.

### 5.3 Why phase 3 is best-effort, not transactional

The meeting STARTED successfully on studio (phase 2 returned MeetingHandle) → it WILL run regardless of what product does next. Aborting navigation because metadata persistence failed leaves the user in wizard with no obvious next step + a meeting running invisibly. Better: show toast, navigate, let MaterialsPanel show "unavailable" (per 05 §4.4 documented behavior).

---

## §6 Forward-declared `POST /api/meetings/{meeting_id}/metadata`

Full schema in `15-apps-api-spec.md` §meeting-metadata. This spec declares the contract we depend on:

```
POST /api/meetings/{meeting_id}/metadata
  body:
    {
      project_id:       str,
      project_version:  int,
      user_id:          str,
      topic:            str,                                # 1..2000 chars
      materials:        list[{
                          upload_id:    str,                # ULID
                          name:         str,
                          kind:         "brief" | "data",
                          size_bytes:   int,
                          preview_url:  str | null,
                        }]
    }
  auth: required + permission "platform:run_meeting"
  201:  201 Created (no body)
  400:  InvalidArgument
  401/403: relayed
  409:  MeetingMetadataAlreadyExists (idempotent re-POST)
  500:  InternalError
```

---

## §7 Sealed error taxonomy

Wizard-owned leaves: 0 (everything relays from studio-client / auth-service / uploads / apps/api).

The wizard's `useWizardSubmit().submitError` is a UI-layer wrapping struct (per §5.2 `mapStudioErrorToSubmitError`); the underlying errors come from the Protocol's `01` §8 taxonomy.

---

## §8 i18n

```json
{
  "feature.wizard.title":                     "Start a meeting",

  "feature.wizard.step.indicator":            "Step {{current}} of {{total}}",
  "feature.wizard.step.project":              "Pick a project",
  "feature.wizard.step.topic":                "Enter the topic",
  "feature.wizard.step.materials":            "Attach materials",
  "feature.wizard.step.review":               "Review and start",

  "feature.wizard.nav.back":                  "Back",
  "feature.wizard.nav.next":                  "Next",
  "feature.wizard.nav.submit":                "Start meeting",
  "feature.wizard.nav.cancel":                "Cancel",
  "feature.wizard.nav.cancel_confirm":        "Discard this meeting setup?",

  "feature.wizard.project.heading":           "Pick a project",
  "feature.wizard.project.helper":            "Each project bundles a set of agents and a paradigm.",
  "feature.wizard.project.empty":             "No projects available for this vertical.",
  "feature.wizard.project.empty_action":      "Switch vertical",
  "feature.wizard.project.error":             "Could not load projects: {{message}}",
  "feature.wizard.project.retry":             "Retry",
  "feature.wizard.project.version_label":     "v{{version}}",
  "feature.wizard.project.paradigm_label":    "{{paradigm}}",

  "feature.wizard.topic.heading":             "What should the agents discuss?",
  "feature.wizard.topic.placeholder":         "e.g., Should we expand into the European market in Q3?",
  "feature.wizard.topic.helper":              "Be specific. Agents work better with focused prompts.",
  "feature.wizard.topic.char_count":          "{{used}}/{{max}}",
  "feature.wizard.topic.too_long":            "Topic is too long; shorten to {{max}} characters.",
  "feature.wizard.topic.required":            "Topic is required.",
  "feature.wizard.topic.context_label":       "Starting meeting in:",

  "feature.wizard.materials.heading":         "Attach materials (optional)",
  "feature.wizard.materials.helper":          "Briefs, data files — context the agents should read before deliberating.",
  "feature.wizard.materials.empty":           "No materials attached. You can proceed without any.",
  "feature.wizard.materials.attached_count":  "{{count}} attached",
  "feature.wizard.materials.uploading":       "Uploading {{name}}…",
  "feature.wizard.materials.remove":          "Remove",
  "feature.wizard.materials.next_disabled_uploading": "Wait for uploads to finish before continuing.",

  "feature.wizard.review.heading":            "Review and start meeting",
  "feature.wizard.review.section.project":    "Project",
  "feature.wizard.review.section.topic":      "Topic",
  "feature.wizard.review.section.materials":  "Materials",
  "feature.wizard.review.edit":               "Edit",
  "feature.wizard.review.submit":             "Start meeting",
  "feature.wizard.review.submitting":         "Starting meeting…",
  "feature.wizard.review.error_recoverable":  "{{message}}",
  "feature.wizard.review.error_retry":        "Retry",
  "feature.wizard.review.error_fatal":        "{{message}}",
  "feature.wizard.review.error_back":         "Go back to fix",

  "feature.wizard.warning.metadata_failed":   "Meeting started, but materials list may not show in agora. (Studio is fine; product metadata persistence failed.)",

  "feature.wizard.error.project_not_found":     "That project no longer exists. Pick another.",
  "feature.wizard.error.project_not_published": "That project is not published. Pick another.",
  "feature.wizard.error.invalid_argument":      "The meeting was rejected. Check your topic and materials.",
  "feature.wizard.error.studio_unavailable":    "Studio is unavailable. Try again shortly.",
  "feature.wizard.error.rate_limited":          "Too many meetings. Try again in {{seconds}}s.",
  "feature.wizard.error.generic":               "Could not start meeting. Try again."
}
```

i18next `{{var}}` interpolation. `zh.json` mirrors with Chinese.

---

## §9 Test matrix

### 9.1 Component tests

| scenario | preconditions | expected | test_id |
|---|---|---|---|
| step 1 mount no preselect | `/wizard` route, projects loaded | step 1 visible; no project selected | `t_w_step1_mount` |
| step 1 mount with preselect | `/wizard/proj-a`, proj-a in list | auto-advances to step 2 via useEffect | `t_w_step1_preselect_skip` |
| step 1 preselect not found | `/wizard/missing`, not in list | stays on step 1 with toast "project not found" | `t_w_step1_preselect_missing` |
| step 1 empty | no projects in vertical | empty state with "Switch vertical" CTA | `t_w_step1_empty` |
| step 1 fetch error | list_projects throws | error state with retry | `t_w_step1_fetch_error` |
| step 1 next disabled | no project selected | Next button disabled | `t_w_step1_next_disabled` |
| step 1 → 2 navigate | select project + click Next | step 2 visible | `t_w_step1_to_2` |
| step 2 char count | type 50 chars | counter shows "50/2000" | `t_w_step2_count` |
| step 2 too long | type 2001 chars | counter red; Next disabled | `t_w_step2_too_long` |
| step 2 trim whitespace | enter "   " | length validation = 0; Next disabled | `t_w_step2_whitespace_only` |
| step 2 → 3 with valid topic | valid topic + Next | step 3 visible | `t_w_step2_to_3` |
| step 2 ← 1 back retains topic | type then back to 1 then forward | topic preserved (controlled input read from draft) | `t_w_step2_topic_persist` |
| step 3 attach material | drop file | useUpload called; on success row added via onAddMaterial callback | `t_w_step3_attach` |
| step 3 remove material | click remove on a row | onRemoveMaterial; material removed from draft | `t_w_step3_remove` |
| step 3 next disabled while uploading | upload in flight | useUpload().inFlightCount > 0 → Next disabled with helper text | `t_w_step3_uploading_disabled` |
| step 3 next enabled with 0 materials | no materials attached | Next enabled (materials optional) | `t_w_step3_zero_ok` |
| step 4 review render | reach step 4 | all 3 sections show draft data | `t_w_step4_render` |
| step 4 edit jumps back | click edit on Project | jumps to step 1 | `t_w_step4_edit_jump` |
| submit happy | full draft + click Start | submitting state → navigate("/platform/agora/:id") | `t_w_submit_happy` |
| submit recoverable error | studio raises StudioUnavailable | error banner with Retry; draft retained | `t_w_submit_recoverable` |
| submit fatal error | studio raises NotFound | error banner with "Go back to fix" → step 1 | `t_w_submit_fatal_back_to_1` |
| submit metadata fails | run_meeting OK, metadata POST fails | toast warning; still navigates to agora | `t_w_submit_metadata_best_effort` |
| cancel with content | typed topic + click Cancel | CancelConfirmDialog opens | `t_w_cancel_confirms_when_dirty` |
| cancel without content | empty draft + click Cancel | direct navigate (no confirm) | `t_w_cancel_clean_no_confirm` |
| cancel confirm | click Cancel + Discard | draft cleared; navigate to dashboard | `t_w_cancel_discard` |
| cancel dismiss | click Cancel + Keep editing | stay in wizard | `t_w_cancel_dismiss` |
| ESC closes cancel dialog | dialog open + ESC | dialog closes; stays in wizard | `t_w_cancel_esc` |

### 9.2 Hook tests

| hook | scenario | expected | test_id |
|---|---|---|---|
| useWizardDraft | fresh init no preselect | current_step=1, empty draft | `t_wd_fresh_init` |
| useWizardDraft | fresh init with preselect | current_step=2, project_id set | `t_wd_preselect_init` |
| useWizardDraft | restore from sessionStorage | matches stored | `t_wd_restore` |
| useWizardDraft | restore wrong vertical | starts fresh | `t_wd_restore_wrong_vertical` |
| useWizardDraft | restore stale (>7d) | starts fresh | `t_wd_restore_stale` |
| useWizardDraft | restore wrong schema version | starts fresh; logs WARN | `t_wd_restore_bad_version` |
| useWizardDraft | mutation persists | sessionStorage updated within 100ms via debounced useEffect | `t_wd_persist_debounce` |
| useWizardDraft | vertical switch resets | reset called via [activeVerticalId] dep effect; step=1 | `t_wd_vertical_switch_reset` |
| useWizardProjects | filters by project_id_in | only allowlisted projects | `t_wp_filter` |
| useWizardProjects | sorts alpha | list sorted by display_name | `t_wp_sort` |
| useWizardProjects | unmount aborts in-flight | AbortController fires | `t_wp_abort_unmount` |
| useWizardSubmit | full happy flow | all 4 phases run; navigate called | `t_ws_full_flow` |
| useWizardSubmit | error mapping | each studio error → correct submit error shape | `t_ws_error_mapping` |

---

## §10 Why this design — load-bearing decisions

**Why 4 steps, not single form.**
Cognitive load. A single form with 4 sections forces the user to scan / understand all required fields at once — overwhelming for a complex action like starting a meeting. A wizard makes the flow linear and gives meaningful "Next" buttons. The Review step (4) brings everything back into a single view for confirmation, so power users don't lose oversight.
*Considered and rejected.* **Single accordion form** — discoverability problems. **2 steps (project + everything-else)** — topic and materials are different concerns; mixing them confuses validation feedback.

**Why sessionStorage (not localStorage, not server-side draft).**
sessionStorage survives page reload but not browser close — matches "ephemeral wizard intent". localStorage would persist across browser restarts, leading to stale drafts haunting users. Server-side draft would need an apps/api endpoint, table, cleanup script — over-engineering for an in-progress flow.
*Considered and rejected.* **localStorage** — drafts surviving for weeks confuse. **Server-side draft** — too much infra for a transient state.

**Why per-vertical draft key (`wizard_draft_<vertical_id>`).**
Projects available in vertical A might not exist in vertical B. A draft started in A and restored in B with mismatched project_id is broken. Per-vertical key sidesteps this; switching vertical mid-wizard triggers reset (per §4.1 step 3).
*Considered and rejected.* **Single global draft key** — invalid restored state on vertical switch.

**Why submit phase 3 (metadata) is best-effort.**
The meeting STARTED on studio after phase 2; aborting navigation because of phase 3 leaves the user stranded with a meeting they can't reach. Better to navigate + show a warning toast + let MaterialsPanel show degraded UX.
*Considered and rejected.* **Transactional submit** — would require studio rollback (impossible). **Retry phase 3 on failure** — wizard should not block the user.

**Why error mapping with `back_to_step` hint.**
Different fatal errors have different fixes (project not found → pick another; topic too long → shorten). A generic "Go back" leaves users guessing which step has the problem. The mapping `mapStudioErrorToSubmitError` makes the back-action precise.
*Considered and rejected.* **Generic "Back to start"** — bad UX.

**Why MaterialsStep embeds 09's `<UploadDropZone>` (vs. its own simpler picker).**
Consistency with `/platform/uploads` UX; reuses HandlerPicker so vertical handlers are surfaced; avoids duplicate dropzone code. Cost: tighter coupling between wizard and uploads packages — but they're both platform-features and 02's hook model accepts cross-feature reuse.
*Considered and rejected.* **Wizard-internal file picker** — duplicates dropzone + MIME handling + progress UI; bug fixes happen twice.

**Why next-button is disabled while uploads are in flight.**
The draft holds `upload_id`s; if user advances before an upload finishes posting, the upload_id is missing → submit later passes incomplete materials → studio agents have less context. Disabling Next during upload (via `useUpload().inFlightCount > 0`) is the simplest invariant.
*Considered and rejected.* **Allow advance with pending uploads** — submit-time materials bag becomes flaky.

**Why no advanced settings step (max_rounds / cost_ceiling / locale).**
Studio §3.6's `run_meeting` body has only `version, topic, materials, user_id`. There's no `MeetingRunConfig` exposed; advanced knobs are in `ProjectSpec.meeting_defaults` (project author's job, not user's). Surfacing knobs that don't exist would be lying to users.
*Considered and rejected.* **Add knobs UI for v0.1** — doesn't map to studio's surface.

**Why the cancel flow shows a confirm dialog when draft has content.**
Drafts can have substantial state (long topic + multiple files); accidental cancel loses work. Confirm dialog is standard pattern. Empty draft → no confirm needed (nothing to lose). ESC dismisses (treats as no-op, not as cancel). `<CancelConfirmDialog>` reuses native `<dialog>` + focus-trap-react pattern from 05/08/09.
*Considered and rejected.* **Cancel with no confirm** — too easy to lose work. **Always confirm** — friction when nothing to lose.

**Why `<CancelConfirmDialog>` reuses the same native dialog + focus-trap-react pattern as 05/08/09.**
Fourth feature using this pattern; consistent UX + zero new bundle (focus-trap-react is shared dep).
*Considered and rejected.* **Browser confirm()** — modal that looks alien; can't style; blocks event loop.

---

## §11 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | No change. Hooks consumed unchanged. |
| `03-auth-service-spec.md` | No new permissions (uses existing `platform:run_meeting`, `platform:list_projects`, `platform:upload`). |
| `05-feature-agora-spec.md` | The handoff target. Wizard's success path navigates to `/platform/agora/:meeting_id`; `meeting_metadata` table populated by wizard's phase 3. Already in 05 §7. |
| `07-feature-knowledge-spec.md` | "+ Start meeting" CTA navigates to `/platform/wizard` (no preselect) OR `/platform/wizard/<project_id>` (when invoked from a project's row). Already in 07 §11. |
| `09-feature-uploads-spec.md` | Wizard step 3 embeds `<UploadDropZone>` + uses `useUpload`. Materials integration contract per 09 §7 is honored. |
| `15-apps-api-spec.md` | Defines `POST /api/meetings/{id}/metadata` per §6. Hosts `meeting_metadata` SQLite table introduced in 05 §7 + extended here to include `upload_id` per material (per 09 §8). |
| `16-apps-frontend-spec.md` | `focus-trap-react` already declared as dep for 05/08/09; reused — no new dep. |
| `17-substitution-tests-spec.md` | The submit flow (`useWizardSubmit`) calls `studio.run_meeting`; `[SUB]` tests in 01 §7.5 cover the studio-side parity. Wizard's own substitution-relevant test is `t_ws_full_flow`. |

---

## §12 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (saved templates, recommendations, prefill, voice, branching, schedule-later, cost preview, draft sharing)
- [ ] Module layout (§1) covers frontend feature (.tsx); no backend in this package
- [ ] 3 permissions reaffirmed (§1.1) — all already declared upstream
- [ ] 2 routes (§1.2) — bare + preselect; React Router v6 RouteObject + lazy() + makePermissionsLoader / makePermissionLoader
- [ ] All 7 visual states (§2.2) covered including 2 submit-error variants (recoverable / fatal)
- [ ] All 4 step components (§3) with full TS Props interface + onXxx callback props + render rules + validation rules
- [ ] All 3 hooks (§4) with signatures + behavior + persistence rules
- [ ] Submit flow (§5) numbered phase-by-phase including byte fetching + structured parsing branch + error mapping table
- [ ] Best-effort phase 3 rationale documented (§5.3)
- [ ] Forward-declared `POST /api/meetings/{id}/metadata` body shape pinned (§6) for spec 15 to honor
- [ ] Error taxonomy: 0 wizard-owned leaves; relayed leaves enumerated
- [ ] CancelConfirmDialog uses native <dialog> + focus-trap-react (4th feature reusing pattern)
- [ ] i18n keys (§8) for every user-visible string with `{{var}}` interpolation
- [ ] Test matrix (§9): components (~26 incl. cancel-confirm + ESC), hooks (~13 incl. abort-cleanup); ≥ 35 rows
- [ ] Why-this / why-not (§10) for ≥ 8 load-bearing decisions including React-specific ones (CancelConfirmDialog reuses dialog pattern; useState + useEffect for sessionStorage sync)
- [ ] Downstream impact (§11) lists every spec affected
- [ ] No business / domain / product / agent-role string literals (uses neutral `proj-a`, `vertical-a`, generic example topics)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No `try: ... except Exception: pass` patterns shown
- [ ] No fabrication of studio knobs that don't exist (no `max_rounds` / `cost_ceiling` / `locale` UI)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/10-feature-wizard-spec.md`
