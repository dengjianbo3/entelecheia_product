# 13 — `verticals/_template` v0.1 spec

> **Status**: v0.1 reference template. Lives at `packages/verticals/_template/`.
> **Consumes**: `02-platform-shell-spec.md` §3 (frontend `VerticalManifest` + `registerVertical`), `06-feature-reports-spec.md` §6.3 (`report_templates`), `09-feature-uploads-spec.md` §1.4 (custom upload handlers).
> **Used by**: spec 14 (the first concrete vertical, copies + renames `_template`); `15-apps-api-spec.md` §boot (entry-point discovery).
> **Forwarded to from**: every future vertical pack.

---

## Mission

This file defines the canonical `_template/` directory — the **copy-paste starting point** for every vertical pack. A vertical author runs `cp -r packages/verticals/_template packages/verticals/<my-vertical-id>` + a small rename pass + edits, and gets a working vertical that registers cleanly with the platform shell, contributes tabs / widgets / upload handlers / data feeds / report templates / fixtures, and passes the substitution test matrix without touching any platform code.

**Hard rule** (P5 + P10): the template demonstrates **every contribution type** (so authors don't have to invent integration patterns) and **nothing platform-specific**. It uses neutral placeholder names (`vertical-template`, `agent-x`, `proj-template-alpha`) so the literal copy of `_template/` could in principle ship as its own vertical without renaming. Every cross-cutting wire to platform features goes through declared manifest fields — no platform imports beyond the typed contracts.

---

## Scope

**Covers.**
- The full `packages/verticals/_template/` directory tree.
- `manifest.py` — backend `VerticalManifest` dataclass with `vertical_id`, `display_name`, `api_routers: list[APIRouter]`, `permissions_declared: list[PermissionDeclaration]`, `studio_fixture_overlay: str | None`, `report_templates: list[ReportTemplate]`.
- `manifest.ts` — frontend `VerticalManifest` instance with `vertical_id`, `display_name`, `description`, `icon`, `accent_color`, `tabs[]`, `dashboard_widgets[]`, `upload_handlers[]`, `data_feeds[]`, `default_project_filter`, `i18n`, `default_route`.
- `pyproject.toml` — workspace member with `[project.entry-points."entelecheia_product.verticals"]`.
- `README.md` — how to fork into a new vertical (the rename steps + a checklist).
- `api/` — sample FastAPI router (data feed proxy + upload handler endpoint).
- `frontend/` — sample tab component, widget component, upload handler component.
- `frontend/i18n/{zh,en}.json` — bundle structure.
- `fixture_overlay/` — studio-client fixture overlay structure with one `ProjectSpec` + one `meeting_template`.
- `tests/` — integration tests verifying registration + isolation.
- Validation rules the platform applies at registration time (`registerVertical` per `02` §3.2 + apps/api boot per `15`).
- The 5 substitution-style integration tests verticals MUST pass.
- Forward-compat: when `02` adds a new contribution type (e.g., `chat_projects` in v0.2), the template grows additively.

**Does not cover.**
- The `VerticalManifest` interface itself — `02-platform-shell-spec.md` §3.1 defines the TS interface; this spec instantiates it.
- The `ReportTemplate` interface — `06-feature-reports-spec.md` §6.1 defines; this spec instantiates.
- The `UploadHandlerContribution` interface — `02` §3.1 defines; this spec instantiates.
- The boot-time discovery flow itself — `02` §3.3 + `15-apps-api-spec.md` §boot. This spec describes what the discovery finds.
- The first concrete vertical — spec 14 shows how `_template` is copied + filled with real domain content.
- Studio's `ProjectSpec` authoring (admin work) — verticals only **reference** existing project_ids; they do not author specs.

**Out of scope for v0.1.**
- Plugin hot-reload (verticals discovered at boot only per `02` §3.3).
- Vertical versioning / migration.
- Vertical-to-vertical communication (forbidden by P5 + Red Line #4).
- Vertical-shipped studio agents / paradigms / skills (Red Line #5).
- Vertical override of platform i18n strings (only namespaced `vertical.<id>.*` keys).
- Per-vertical theming beyond the `accent_color` hex declared in manifest.
- Vertical-specific `app/api` middleware (verticals add only `APIRouter`s under `/api/verticals/<id>/...`).

---

## §1 Directory tree

The complete `_template/` layout. Every file shown is part of the template; nothing is conditional.

```
packages/verticals/_template/
├── pyproject.toml                                # workspace member; entry-point registration
├── README.md                                     # how-to-fork checklist
├── manifest.py                                   # backend VerticalManifest + entry-point target
├── api/
│   ├── __init__.py                               # re-exports the routers
│   ├── routers/
│   │   ├── __init__.py
│   │   ├── data.py                               # GET /api/verticals/<id>/data/<feed_id> proxy
│   │   └── uploads.py                            # POST /api/verticals/<id>/upload/<handler_kind> handler endpoint
│   ├── permissions.py                            # PERMISSIONS list (declared in manifest)
│   ├── report_templates/
│   │   ├── __init__.py
│   │   └── default_template.py                   # ReportTemplate instance + render hooks
│   └── tests/
│       ├── __init__.py
│       ├── test_data_router.py
│       └── test_upload_handler.py
├── frontend/
│   ├── package.json                              # local package; depends on @entelecheia/platform-shell
│   ├── tsconfig.json
│   ├── src/
│   │   ├── manifest.ts                           # default-export VerticalManifest
│   │   ├── components/
│   │   │   ├── tabs/
│   │   │   │   └── ExampleTab.vue                # tab content; rendered at /<vertical_id>/example
│   │   │   ├── widgets/
│   │   │   │   └── ExampleWidget.vue             # dashboard widget
│   │   │   └── handlers/
│   │   │       └── ExampleUploadHandler.vue      # custom upload-handler UI
│   │   ├── stores/
│   │   │   └── exampleStore.ts                   # Pinia store; namespaced as vertical.<id>.example
│   │   └── i18n/
│   │       ├── zh.json                           # vertical's zh strings (merged at registration)
│   │       └── en.json
│   └── tests/
│       ├── ExampleTab.spec.ts
│       └── manifest.spec.ts                      # validates the manifest shape
├── fixture_overlay/
│   ├── projects.yaml                             # vertical's ProjectSpec entries (drop into PseudoStudioClient)
│   ├── meeting_templates.yaml                    # vertical's meeting event scripts
│   └── outcomes.yaml                             # vertical's MeetingOutcome fixtures
└── tests/
    └── test_registration.py                      # integration: vertical registers cleanly into shell + apps/api
```

**Why `api/` + `frontend/` are sibling dirs (not nested under one tree).** Backend (Python uv workspace member) and frontend (npm-style local package) have different tool toolchains. Co-locating them in the same vertical directory keeps the vertical self-contained; siblings keep each toolchain's expectations met.

---

## §2 `pyproject.toml`

```toml
# packages/verticals/_template/pyproject.toml
[project]
name = "entelecheia-vertical-template"
version = "0.0.1"
description = "Reference template for an entelecheia-product vertical pack."
readme = "README.md"
license = {text = "Proprietary"}
requires-python = ">=3.11"

dependencies = [
    "fastapi>=0.110",
    "pydantic>=2.7",
    # NOT: entelecheia (engine) — Red Line #1
    # NOT: entelecheia_studio — Red Line #5
    # The platform-shell + studio-client deps are workspace-members; resolved by uv.workspace.
    "entelecheia-platform-shell",   # for VerticalManifest dataclass + PermissionDeclaration
    "entelecheia-studio-client",    # for ReportTemplate, ProjectId types only (not for direct studio access from this package)
]

[project.entry-points."entelecheia_product.verticals"]
# The string after `=` is "<python_module>:<attribute>". apps/api's boot
# discovery reads importlib.metadata.entry_points(group="entelecheia_product.verticals")
# and loads each manifest. The entry-point KEY (left side) is the
# vertical_id; it MUST equal manifest.py's `vertical_manifest.vertical_id`
# (validated at registration; mismatch raises VerticalRegistrationError per
# 02 §3.2 with reason="entry_point_id_mismatch").
template = "entelecheia_vertical_template.manifest:vertical_manifest"

[build-system]
requires = ["hatchling>=1.18"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/entelecheia_vertical_template"]
```

**Naming convention**:
- Python distribution name: `entelecheia-vertical-<id>` (lowercase + hyphens)
- Python module name: `entelecheia_vertical_<id>` (lowercase + underscores)
- Entry-point KEY (`= sign LHS`): `<vertical_id>` matching manifest.py's `vertical_id`
- These three names are coupled by convention; the rename script in `README.md` updates them in one pass.

---

## §3 `manifest.py` — backend manifest

```python
# packages/verticals/_template/src/entelecheia_vertical_template/manifest.py

from fastapi import APIRouter

from entelecheia_platform_shell.types import (
    VerticalManifest,
    PermissionDeclaration,
)
from entelecheia_studio_client.dto.reports import ReportTemplate

from .api.routers.data import data_router
from .api.routers.uploads import uploads_router
from .api.permissions import PERMISSIONS
from .api.report_templates.default_template import default_template


vertical_manifest = VerticalManifest(
    vertical_id="vertical-template",            # MUST match pyproject entry-point key
    display_name="Vertical Template",           # human-readable; surfaces in switcher when overlaid by frontend i18n

    # FastAPI routers contributed by this vertical. apps/api mounts each
    # under /api/verticals/<vertical_id>/... at boot (per 15 §vertical-mount).
    api_routers=[
        data_router,
        uploads_router,
    ],

    # Permissions this vertical declares. apps/api registers them with
    # auth-service at boot (per 03 §5.3). Format: <vertical_id>:<verb>.
    # Platform-shell's usePermission() reads grants per user; vertical
    # gates UI via <PermissionGate code="..."> (02 §8.3).
    permissions_declared=PERMISSIONS,

    # Studio fixture overlay name. PseudoStudioClient (per 01 §10.2) loads
    # base fixtures from packages/studio-client/fixtures/default/ then
    # overrides matching files from packages/studio-client/fixtures/<overlay_name>/.
    # The vertical SHIPS its overlay under fixture_overlay/ in this dir; the
    # apps/api boot dance copies (or symlinks) it into the studio-client
    # fixtures dir before instantiation (per 15 §fixture-overlay-bootstrap).
    studio_fixture_overlay="vertical-template",

    # Report templates this vertical contributes (per 06 §6.3). The
    # template_id MUST be prefixed with vertical_id ("vertical-template:default")
    # — apps/api validates the prefix matches declared_by at registration
    # (06 §6.3: "Verticals can't masquerade as platform templates").
    report_templates=[
        default_template,
    ],
)
```

### 3.1 `permissions.py`

```python
# packages/verticals/_template/src/entelecheia_vertical_template/api/permissions.py

from entelecheia_platform_shell.types import PermissionDeclaration

PERMISSIONS: list[PermissionDeclaration] = [
    PermissionDeclaration(
        code="vertical-template:read_data",
        description="Read this vertical's data feed.",
    ),
    PermissionDeclaration(
        code="vertical-template:upload_example",
        description="Upload files via this vertical's example handler.",
    ),
    # Add more as the vertical grows. Format MUST be <vertical_id>:<verb>;
    # auth-service registry rejects mismatches at boot (03 §5.3).
]
```

---

## §4 `manifest.ts` — frontend manifest

```typescript
// packages/verticals/_template/frontend/src/manifest.ts
import type { VerticalManifest } from "@entelecheia/platform-shell";
import type { ProjectId } from "@entelecheia/studio-client";

import ExampleTab from "./components/tabs/ExampleTab.vue";
import ExampleWidget from "./components/widgets/ExampleWidget.vue";
import ExampleUploadHandler from "./components/handlers/ExampleUploadHandler.vue";
import zh from "./i18n/zh.json";
import en from "./i18n/en.json";

const manifest: VerticalManifest = {
  // identity (per 02 §3.1)
  vertical_id: "vertical-template",
  display_name: "Vertical Template",
  description: "Reference template demonstrating every vertical contribution type.",
  icon: "Sparkles",                              // lucide-vue-next icon name; bundled with apps/frontend

  // appearance (optional)
  accent_color: "#7C3AED",                       // hex; CSS --color-accent override (02 §5.3)

  // tabs added to side nav under /<vertical_id>/<route_path>
  tabs: [
    {
      id: "example",                              // unique within vertical
      label_key: "vertical.vertical-template.tab.example",
      route_path: "/example",                     // mounts at /vertical-template/example
      component: ExampleTab,
      required_permission: "vertical-template:read_data",
      position: 100,                              // ordering hint; lower = earlier
    },
    // Add more tabs as needed. Each `id` MUST be unique within this manifest's
    // tabs array; registerVertical throws VerticalRegistrationError{reason:
    // "duplicate_tab_id"} on collision (02 §3.2).
  ],

  // dashboard widgets
  dashboard_widgets: [
    {
      id: "example-widget",
      component: ExampleWidget,
      preferred_position: "top-right",
      title_key: "vertical.vertical-template.widget.example.title",
      required_permission: "vertical-template:read_data",
    },
  ],

  // custom upload handlers (per 09 §1.4 + UploadHandlerContribution interface)
  upload_handlers: [
    {
      kind: "vertical-template:example-data",     // <vertical_id>:<handler_kind>
      label_key: "vertical.vertical-template.upload.example_data",
      accepts: [".json", "application/json"],
      max_size_bytes: 5 * 1024 * 1024,            // 5 MB; per-handler override (default 10 MB)
      handler_component: ExampleUploadHandler,
      studio_material_kind: "data",               // mapped to studio §3.6 Material kind
    },
  ],

  // external data feed proxies (backend lives in this vertical's api/ dir)
  data_feeds: [
    {
      id: "example-feed",
      api_path: "/api/verticals/vertical-template/data/example",
      description: "Example external data feed proxy. Replace with real source.",
    },
  ],

  // project filtering (per 01 §11.4 — studio's ProjectSpec has no labels;
  // verticals declare an explicit allowlist of project spec_ids)
  default_project_filter: {
    project_id_in: [
      "proj-template-alpha" as ProjectId,
      "proj-template-beta" as ProjectId,
    ],
  },

  // i18n bundles (merged into vue-i18n at registerVertical time under
  // namespace vertical.<vertical_id>.<key>)
  i18n: { zh, en },

  // optional: where switching to this vertical lands by default
  default_route: "/vertical-template/example",
};

export default manifest;
```

### 4.1 `i18n/en.json` (sample)

```json
{
  "tab.example":                            "Example",
  "widget.example.title":                   "Example Widget",
  "upload.example_data":                    "Example data file",
  "page.example.heading":                   "Example tab",
  "page.example.body":                      "Replace this with your vertical's UI."
}
```

### 4.2 `i18n/zh.json` (sample)

```json
{
  "tab.example":                            "示例",
  "widget.example.title":                   "示例小组件",
  "upload.example_data":                    "示例数据文件",
  "page.example.heading":                   "示例标签页",
  "page.example.body":                      "用本垂直的真实 UI 替换这里。"
}
```

After registration, accessible from anywhere via `useI18n().t("vertical.vertical-template.tab.example")`.

---

## §5 Sample components

### 5.1 `ExampleTab.vue`

```vue
<!-- packages/verticals/_template/frontend/src/components/tabs/ExampleTab.vue -->
<script setup lang="ts">
import { useI18n, useStudio } from "@entelecheia/platform-shell";

const { t } = useI18n();
const studio = useStudio();   // canonical access to StudioClient (Red Line #2)

// Vertical's local store (per Pinia namespacing convention)
import { useExampleStore } from "../../stores/exampleStore";
const store = useExampleStore();
</script>

<template>
  <section class="example-tab">
    <h1>{{ t("vertical.vertical-template.page.example.heading") }}</h1>
    <p>{{ t("vertical.vertical-template.page.example.body") }}</p>
    <!-- TODO (vertical author): replace with real content -->
  </section>
</template>
```

### 5.2 `ExampleWidget.vue`

```vue
<!-- packages/verticals/_template/frontend/src/components/widgets/ExampleWidget.vue -->
<script setup lang="ts">
import { useI18n } from "@entelecheia/platform-shell";
const { t } = useI18n();
</script>

<template>
  <article class="example-widget" role="region"
           :aria-labelledby="`vertical-template-widget-example-title`">
    <h2 :id="`vertical-template-widget-example-title`">
      {{ t("vertical.vertical-template.widget.example.title") }}
    </h2>
    <!-- TODO: widget content -->
  </article>
</template>
```

### 5.3 `ExampleUploadHandler.vue`

```vue
<!-- packages/verticals/_template/frontend/src/components/handlers/ExampleUploadHandler.vue -->
<script setup lang="ts">
import type { Upload } from "@entelecheia/uploads";
import { useI18n } from "@entelecheia/platform-shell";

const props = defineProps<{
  upload: Upload;
}>();

const emit = defineEmits<{
  (e: "confirm", upload_id: string, normalized_content: object): void;
  (e: "cancel"): void;
}>();

const { t } = useI18n();

// TODO: vertical-specific normalization. The handler may parse / validate /
// preview the upload, then emit `confirm` with a normalized payload that
// the wizard inlines as Material.content at run_meeting time (per 09 §7).
</script>

<template>
  <div class="example-handler">
    <p>{{ t("vertical.vertical-template.upload.example_data") }}: {{ props.upload.display_name }}</p>
    <button @click="emit('confirm', props.upload.upload_id, {})">Confirm</button>
    <button @click="emit('cancel')">Cancel</button>
  </div>
</template>
```

---

## §6 Sample backend routers

### 6.1 `api/routers/data.py`

```python
# packages/verticals/_template/src/entelecheia_vertical_template/api/routers/data.py
"""Sample data feed proxy. Replace with real upstream calls.

Verticals MAY make HTTP requests to *external* sources (per 03 design doc:
"data feeds proxy via vertical's own backend routers"). They MUST NOT
make HTTP requests to studio (Red Line #2; use studio-client instead).
"""

from fastapi import APIRouter, Depends, HTTPException, status
from entelecheia_auth.deps import require_auth, CurrentAuthContext
from entelecheia_platform_shell.permissions import require_permission

data_router = APIRouter(
    prefix="/api/verticals/vertical-template/data",
    tags=["vertical-template"],
)


@data_router.get("/example")
async def get_example_feed(
    ctx: CurrentAuthContext = Depends(require_auth),
    _perm = Depends(require_permission("vertical-template:read_data")),
) -> dict:
    """Sample feed endpoint. Replace with real upstream call."""
    return {"vertical_id": "vertical-template", "items": []}
```

### 6.2 `api/routers/uploads.py`

```python
# packages/verticals/_template/src/entelecheia_vertical_template/api/routers/uploads.py
"""Sample vertical-specific upload endpoint.

This is OPTIONAL — most verticals can use the platform's POST /api/uploads
(per 09 §4.1) directly via their handler_component. A vertical only adds
its own upload endpoint when it needs custom server-side validation /
parsing that doesn't fit the generic upload service.
"""

from fastapi import APIRouter, Depends, UploadFile
from entelecheia_auth.deps import require_auth, CurrentAuthContext
from entelecheia_platform_shell.permissions import require_permission

uploads_router = APIRouter(
    prefix="/api/verticals/vertical-template/upload",
    tags=["vertical-template"],
)


@uploads_router.post("/example")
async def upload_example(
    file: UploadFile,
    ctx: CurrentAuthContext = Depends(require_auth),
    _perm = Depends(require_permission("vertical-template:upload_example")),
) -> dict:
    """Custom upload endpoint. Vertical-specific validation goes here."""
    # TODO: vertical-specific parse / validate / store
    return {"ok": True, "filename": file.filename}
```

---

## §7 Sample report template

```python
# packages/verticals/_template/src/entelecheia_vertical_template/api/report_templates/default_template.py
from entelecheia_studio_client.dto.reports import ReportTemplate, ReportSection

default_template = ReportTemplate(
    template_id="vertical-template:default",     # <vertical_id>:<name> per 06 §6.3
    name="Vertical Template — Default Report",   # i18n key OR literal; literal here for template
    description="Sample report layout for the vertical-template.",
    formats=["pdf", "word", "markdown"],         # excel omitted as example of a template that doesn't support it
    declared_by="vertical-template",             # MUST match vertical_id; 06 §6.3 enforces
    sections=[
        ReportSection(
            section_id="meta",
            heading_key="vertical.vertical-template.report.section.meta",
            source_field="meta",
            visualization="paragraph",
            filter=None,
        ),
        ReportSection(
            section_id="key_facts",
            heading_key="vertical.vertical-template.report.section.key_facts",
            source_field="key_facts",
            visualization="list",
            filter=None,
        ),
    ],
)
```

---

## §8 Studio fixture overlay

The `fixture_overlay/` dir is the vertical's contribution to PseudoStudioClient (per `01-studio-client-spec.md` §10.2). At apps/api boot, the `studio_fixture_overlay` field in `manifest.py` triggers the boot dance to merge these files into `packages/studio-client/fixtures/<overlay_name>/`.

### 8.1 `fixture_overlay/projects.yaml`

```yaml
# Vertical-flavored ProjectSpecs that PseudoStudioClient surfaces alongside
# the default fixtures. Format MUST mirror packages/studio-client/fixtures/
# default/projects.yaml (per 01 §10.3).
- spec_kind: project
  schema_version: v0.1
  spec_id: proj-template-alpha
  version: 1
  status: published
  created_at: "2026-01-01T00:00:00Z"
  updated_at: "2026-04-15T00:00:00Z"
  created_by: vertical-template-author
  description: Reference project for the vertical-template; replace with real content.
  agents:
    - {agent_id: "agent-x", version: 1, enabled: true}
    - {agent_id: "agent-y", version: 1, enabled: true}
  engine_extensions:
    conclude_predicates:
      - {type: "builtin.max_turns", params: {max_turns: 10}}
    constraints: []
    speaker_selector: {type: "builtin.round_robin", params: {}}
    phase_machine:    {type: "builtin.linear", params: {phases: ["intro", "discuss", "conclude"]}}
  meeting_defaults: {max_turns: 10, language: en}
  skill_overrides: {}

- spec_kind: project
  schema_version: v0.1
  spec_id: proj-template-beta
  version: 1
  status: published
  # ... (similar; provides 2nd project so default_project_filter has multiple options)
```

### 8.2 `fixture_overlay/meeting_templates.yaml`

```yaml
# Event scripts PseudoStudioClient replays when run_meeting is called against
# this vertical's projects. See 01 §10.3 for full schema.
- template_id: tmpl_template_alpha
  match_rule:
    project_id_in: ["proj-template-alpha", "proj-template-beta"]
    topic_keywords_any_of: ["*"]
  initial_status: running
  events:
    - {at_offset_ms: 0,    event_type: MeetingStarted,        data: {paradigm: "react"}}
    - {at_offset_ms: 200,  event_type: RootQuestionPosed,     data: {question: "<topic>"}}
    - {at_offset_ms: 1500, event_type: ClaimMade,             data: {claim_id: "tc1", asserted_by: "agent-x", content: "First example claim."}}
    - {at_offset_ms: 3000, event_type: ConsensusReached,      data: {claim_ids: ["tc1"], confidence: 0.8}}
    - {at_offset_ms: 4000, event_type: MeetingFrozen,         data: {}}
    - {at_offset_ms: 4100, event_type: meeting_finalized,     data: {outcome_ref: "tmpl_template_alpha"}}
```

### 8.3 `fixture_overlay/outcomes.yaml`

```yaml
- outcome_ref: tmpl_template_alpha
  outcome:
    meeting_id: "<runtime>"           # filled by PseudoStudioClient at finalize
    concluded_by: consensus_reached
    consensus:                        [{claim_id: "tc1", content: "First example claim.", confidence: 0.8}]
    unresolved_disagreements:         []
    key_facts:                        []
    open_questions:                   []
    started_at:                       "<runtime>"
    concluded_at:                     "<runtime>"
    total_turns:                      2
    final_constraints_status:         []
    merkle_root:                      "0000000000000000000000000000000000000000000000000000000000000000"
```

---

## §9 Validation rules at registration

The platform applies these rules when loading a vertical (per `02` §3.2 + apps/api boot per `15`). Failures raise typed `VerticalRegistrationError` (per `02` §3.2).

| Rule | Validated at | Failure mode |
|---|---|---|
| `pyproject.toml` declares `[project.entry-points."entelecheia_product.verticals"]` with one key | apps/api boot | entry point absent → vertical silently not registered (no error; standard Python behavior) |
| Entry-point KEY equals `manifest.vertical_id` | apps/api boot | mismatch → `VerticalRegistrationError{reason: "entry_point_id_mismatch"}` |
| `vertical_id` matches `^[a-z][a-z0-9_-]*$` | apps/api boot | mismatch → `VerticalRegistrationError{reason: "invalid_format"}` |
| `vertical_id` unique among loaded verticals | apps/api boot | duplicate → `VerticalRegistrationError{reason: "duplicate_id"}` |
| Frontend `tabs[*].id` unique within manifest | shell registerVertical | duplicate → `VerticalRegistrationError{reason: "duplicate_tab_id"}` |
| Frontend `tabs[*].route_path` starts with `/` | shell registerVertical | bad → `VerticalRegistrationError{reason: "invalid_route_path"}` |
| All declared permissions match `^<vertical_id>:[a-z][a-z0-9_]*$` | apps/api boot | mismatch → registration aborts with reason |
| `report_templates[*].template_id` matches `^<vertical_id>:[a-z][a-z0-9_-]*$` | apps/api boot | mismatch → 06 §6.3 `TemplateRegistrationError` |
| `report_templates[*].declared_by == vertical_id` | apps/api boot | mismatch → same error |
| `default_project_filter.project_id_in[*]` references must exist (warn-only) | runtime, on first project list fetch | missing → log WARN; UI shows fewer projects gracefully |
| `studio_fixture_overlay` (if set) — directory `fixture_overlay/` exists | apps/api boot | missing → log WARN, vertical loads without overlay |
| Backend manifest module path matches `^entelecheia_vertical_<id>\\.manifest:vertical_manifest$` | apps/api boot (convention check) | mismatch → log WARN; vertical loads if importable |
| Vertical does NOT import another vertical (`from entelecheia_vertical_*` outside its own package) | scripts/check-purity.sh | violation → CI fails (Red Line #4) |
| Vertical does NOT import `entelecheia` (engine) | scripts/check-purity.sh | violation → CI fails (Red Line #1) |
| Vertical does NOT modify `packages/platform-*` | reviewer + CI path-watch | violation → PR rejected (Red Line #3) |

---

## §10 How to fork into a new vertical (the rename script in `README.md`)

```bash
#!/usr/bin/env bash
# packages/verticals/_template/README.md ships this script as ./fork-to.sh
# Usage: ./fork-to.sh my-vertical-id
set -euo pipefail

NEW_ID="$1"
if [[ ! "$NEW_ID" =~ ^[a-z][a-z0-9_-]*$ ]]; then
  echo "Invalid vertical_id: $NEW_ID (must match ^[a-z][a-z0-9_-]*\$)" >&2
  exit 1
fi

NEW_DIR="../$NEW_ID"
NEW_PY_MODULE="entelecheia_vertical_${NEW_ID//-/_}"
NEW_PY_DIST="entelecheia-vertical-${NEW_ID}"

# 1. Copy template to sibling dir
cp -r . "$NEW_DIR"
cd "$NEW_DIR"

# 2. Rename Python module dir
mv "src/entelecheia_vertical_template" "src/$NEW_PY_MODULE"

# 3. Find-and-replace the literal placeholder strings
# vertical_id: vertical-template → ${NEW_ID}
# Python module: entelecheia_vertical_template → ${NEW_PY_MODULE}
# Python dist:   entelecheia-vertical-template → ${NEW_PY_DIST}
find . -type f \( -name '*.py' -o -name '*.ts' -o -name '*.vue' -o -name '*.json' -o -name '*.toml' -o -name '*.yaml' -o -name '*.md' \) -print0 \
  | xargs -0 sed -i.bak \
      -e "s/vertical-template/${NEW_ID}/g" \
      -e "s/entelecheia_vertical_template/${NEW_PY_MODULE}/g" \
      -e "s/entelecheia-vertical-template/${NEW_PY_DIST}/g" \
      -e "s/Vertical Template/${NEW_ID}/g"  # display_name; user edits manually
find . -name '*.bak' -delete

# 4. Reset placeholder content
echo "Reset accent_color, icon, descriptions, fixture content manually."
echo "Then: cd ../../.. && uv sync --all-packages && bash scripts/check-purity.sh"
```

**Manual checklist after running** (the README repeats these):

1. Edit `manifest.py` `display_name` to a human-readable string.
2. Edit `manifest.ts` `display_name`, `description`, `icon`, `accent_color`.
3. Edit `i18n/{zh,en}.json` to localize strings.
4. Replace `proj-template-alpha` / `proj-template-beta` in `default_project_filter.project_id_in` with real `spec_id`s the vertical's PseudoStudioClient overlay (or the live studio) exposes.
5. Update `fixture_overlay/projects.yaml` + `meeting_templates.yaml` + `outcomes.yaml` with realistic vertical-specific content.
6. Update permissions in `api/permissions.py` to match real verbs the vertical needs.
7. Replace stub data feed in `api/routers/data.py` with real upstream calls.
8. Replace example tab / widget / handler with real domain content.
9. Run `bash scripts/check-purity.sh` — must exit 0.
10. Run `uv sync --all-packages` — workspace must accept the new member.
11. Run vertical's `tests/` — substitution + isolation tests must pass.

---

## §11 Test matrix

### 11.1 Substitution tests (also surface in `17-substitution-tests-spec.md`)

| scenario | expected | test_id |
|---|---|---|
| Vertical loads at boot | apps/api discovers via entry point; shell fetches via /api/platform/verticals; registerVertical succeeds | `[SUB] t_vt_boot_load` |
| Vertical absent (entry point removed) | shell renders without this vertical's tabs/widgets; no errors; other verticals unaffected | `[SUB] t_vt_absent_isolated` |
| Two verticals coexist | both register; tabs / widgets / fixtures don't collide; switcher shows both; switching navigates correctly | `[SUB] t_vt_two_coexist` |
| Vertical's manifest malformed | apps/api logs error + skips this vertical; rest of platform boots fine | `[SUB] t_vt_malformed_isolated` |
| Vertical's frontend module fails to dynamic-import | shell pushes toast + skips; other verticals load (per 02 §3.3 step 7c) | `[SUB] t_vt_frontend_import_fail` |

### 11.2 Permission registration

| scenario | expected | test_id |
|---|---|---|
| All declared permissions land in auth-service registry at boot | `GET /api/auth/permissions` returns the union | `t_vt_perm_register` |
| Permission with malformed prefix (not `<vertical_id>:`) | apps/api boot raises; vertical registration aborts | `t_vt_perm_bad_prefix` |
| User with vertical permission can access tab | route guard + PermissionGate both pass | `t_vt_perm_ui_grant` |
| User without vertical permission cannot access tab | tab hidden in nav; route guard redirects | `t_vt_perm_ui_deny` |

### 11.3 Fixture overlay

| scenario | expected | test_id |
|---|---|---|
| Overlay loads at PseudoStudioClient boot | proj-template-alpha appears in list_projects | `[SUB] t_vt_fixture_load` |
| Overlay's meeting_template fires on run_meeting | events stream as scripted | `[SUB] t_vt_fixture_meeting` |
| Overlay outcome resolves | get_meeting_outcome returns the canned MeetingOutcome | `[SUB] t_vt_fixture_outcome` |
| Vertical's projects appear in knowledge browser | when vertical active, list_projects results filtered to project_id_in includes them | `t_vt_fixture_in_knowledge` |
| Vertical's projects appear in wizard step 1 | same filter applies | `t_vt_fixture_in_wizard` |

### 11.4 Report templates

| scenario | expected | test_id |
|---|---|---|
| Vertical's templates appear in reports view when vertical active | `GET /api/reports/templates?vertical_id=<id>` includes platform:* + vertical:* | `t_vt_report_templates_listed` |
| Render with vertical's template | renderer outputs valid bytes (PDF / Word / Markdown) | `t_vt_report_render_ok` |
| Template prefix mismatch rejected | template_id starting with another vertical's id → registration error at boot | `t_vt_report_prefix_enforced` |

### 11.5 Upload handler

| scenario | expected | test_id |
|---|---|---|
| Custom handler appears in HandlerPicker when vertical active | useUploadHandlers returns vertical's + platform's | `t_vt_upload_handler_listed` |
| Upload via custom handler accepts only declared MIME | non-matching file rejected client-side + server-side | `t_vt_upload_handler_mime_filter` |
| Custom upload endpoint requires permission | user without `vertical-template:upload_example` → 403 | `t_vt_upload_perm_gate` |

---

## §12 Why this design — load-bearing decisions

**Why a `_template/` directory (not a CLI scaffold tool).**
A scaffold tool drifts (its templates fall behind the platform contracts). A literal `_template/` directory under `packages/verticals/` is always-present, always-tested by CI, copied via `cp -r`. PR diff against the template shows exactly what a new vertical changed. v0.2 may add a CLI wrapper (`make new-vertical NAME=x`) but the source of truth stays the directory.
*Considered and rejected.* **Cookiecutter / Yeoman-style generator** — separate maintenance, easy drift.

**Why entry-points (Python) for backend AND dynamic-import (TS) for frontend, not unified.**
Python's standard plugin mechanism is `importlib.metadata.entry_points`; using it lets `pip install entelecheia-vertical-X` register the vertical with zero boilerplate. The frontend can't use Python entry points; instead, apps/api enumerates installed verticals (via the same entry points) and exposes them as `GET /api/platform/verticals`; the frontend dynamic-imports each vertical's TS module via Vite. Per-toolchain-natural is cleaner than forcing one mechanism on both.
*Considered and rejected.* **YAML-based "registry" file** — duplicates the source of truth; harder to enforce vertical_id naming convention.

**Why the entry-point key MUST equal `manifest.vertical_id`.**
Without the equality check, an installed package could declare a vertical_id different from its registration key, leading to invisible mismatches between entry-point lookups and runtime manifests. Strict equality + boot-time validation makes the relationship verifiable in one place.
*Considered and rejected.* **Allow mismatch with a "name override"** — opens path to confusion.

**Why fixture overlay is per-vertical (not centralized).**
Each vertical knows its domain (which `ProjectSpec` shapes make sense for it). Centralizing in `packages/studio-client/fixtures/` would either (a) blob domain knowledge into studio-client (P3-violating coupling) or (b) require coordination across vertical authors. Per-vertical overlay + apps/api boot dance to merge keeps the right separation.
*Considered and rejected.* **Single shared fixtures dir** — coordination cost; coupling.

**Why `accent_color` is a hex literal (not a token reference).**
Vertical authors need to pick a color that matches their brand without learning the platform's design token system. A hex value is universally understood. Platform CSS variables expose the color via `--color-accent` for downstream styling. v0.2 may add a tokens-aware variant.
*Considered and rejected.* **`accent_token: "amber-600"`** — couples verticals to platform's token vocabulary.

**Why permissions live in a `PERMISSIONS` Python list (not derived).**
Explicit declaration is reviewable in PRs, validated at boot, and documents the vertical's required surface. Derivation (e.g., scanning `@require_permission(...)` decorators) is fragile.
*Considered and rejected.* **Decorator-only permissions** — fragile to refactor.

**Why the rename script is bash (not a Makefile / Python CLI).**
One-shot operation that needs to be reproducible in any environment with bash + sed + find. Adding Python or Make as a dependency for "copy + rename" is overkill. The script lives in README.md; vertical authors can also do the rename manually.
*Considered and rejected.* **Python CLI** — adds dependency for a one-shot operation.

**Why the template ships `fixture_overlay/` even though the user must replace its content.**
Demonstrates the FILE STRUCTURE (which files exist, which keys appear, where the overlay loads from). Empty fixture_overlay would leave authors guessing the schema.
*Considered and rejected.* **Empty fixture_overlay/** — authors miss schema. **Inline schema docs only** — schema-as-code (the file itself) is the most reliable doc.

**Why the template demonstrates EVERY contribution type.**
Authors copying the template see the complete mapping: tabs, widgets, upload handlers, data feeds, report templates, fixtures, permissions, i18n, accent color. Subsetting requires deleting (which is easy + reviewable in the diff). A minimal template would force authors to consult docs to add each missing piece.
*Considered and rejected.* **Minimal template (only manifest + 1 tab)** — pushes complexity to vertical authors for non-trivial verticals.

**Why CI's check-purity.sh enforces vertical isolation (not just docs).**
Red Line #4 ("verticals never import each other") is mechanically catchable; relying on reviewer judgment is unreliable as the platform grows. The script's regex catches `from entelecheia_vertical_*` and `from packages.verticals.*` patterns inside individual vertical packages.
*Considered and rejected.* **Reviewer judgment only** — drifts as more verticals land.

---

## §13 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | This template is the canonical instance of `VerticalManifest`. If 02's interface adds a field in v0.x, the template MUST add it (additively, with a placeholder value). |
| `03-auth-service-spec.md` | Permission registration at boot consumes `PERMISSIONS` list; per-vertical-id namespace enforced (already declared in 03 §5.3). |
| `06-feature-reports-spec.md` | The `<vertical_id>:default` template prefix convention enforced at registration (already in 06 §6.3). |
| `09-feature-uploads-spec.md` | Custom upload handler example demonstrates the `UploadHandlerContribution` interface (already in 09 §1.4). |
| Spec 14 (first concrete vertical) | Copies `_template`, applies the rename script, fills with real content. Detailed in 14. |
| `15-apps-api-spec.md` | Boot-time discovery (entry-point enumeration + GET /api/platform/verticals) + fixture overlay merge dance + permission registration are wired in 15 §boot. |
| `16-apps-frontend-spec.md` | Dynamic-import flow consumes the GET /api/platform/verticals response + calls registerVertical(manifest) per vertical (already in 02 §3.3 + 16 boot sequence). |
| `17-substitution-tests-spec.md` | The `[SUB]` test_ids in §11 (5 substitution + 5 fixture-substitution) inherited into 17's category 4 (vertical isolation) and category 5 (fixture parity). |

---

## §14 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (hot-reload, versioning, vertical-to-vertical, vertical-shipped agents, theme override beyond accent, vertical middleware)
- [ ] Directory tree (§1) enumerates every file
- [ ] `pyproject.toml` (§2) declares `[project.entry-points."entelecheia_product.verticals"]`; key matches manifest.vertical_id
- [ ] Backend `manifest.py` (§3) instantiates `VerticalManifest` with all 5 declarable kinds (api_routers, permissions, fixture_overlay, report_templates, vertical_id+display_name)
- [ ] Frontend `manifest.ts` (§4) instantiates `VerticalManifest` with all contribution types per 02 §3.1
- [ ] Sample components (§5) for tab, widget, upload handler — all importing from `@entelecheia/platform-shell` (no engine, no studio direct)
- [ ] Sample backend routers (§6) include data feed proxy + custom upload endpoint; both go through `require_auth` + `require_permission`
- [ ] Sample report template (§7) declares template_id with `<vertical_id>:` prefix matching declared_by
- [ ] Studio fixture overlay (§8) covers projects.yaml + meeting_templates.yaml + outcomes.yaml with at least 1 entry each
- [ ] Validation rules table (§9) covers all 13 rules with source-of-validation (boot vs registration vs CI)
- [ ] Fork-to script (§10) + manual checklist for what to edit after running
- [ ] Test matrix (§11): substitution tests (5), permission tests (4), fixture tests (5), report template tests (3), upload handler tests (3) — ≥ 20 rows total
- [ ] Why-this / why-not (§12) for ≥ 8 load-bearing decisions
- [ ] Downstream impact (§13) lists every spec affected
- [ ] No business / domain / product / agent-role string literals (uses neutral `vertical-template`, `agent-x`, `agent-y`, `proj-template-alpha`, etc.)
- [ ] No `from entelecheia` / `import entelecheia` (Red Line #1)
- [ ] No `from entelecheia_studio` / `import entelecheia_studio` (Red Line #5)
- [ ] No `from entelecheia_vertical_*` outside the vertical's own package (Red Line #4)
- [ ] No HTTP calls to studio (Red Line #2 — vertical's data feeds may call EXTERNAL URLs but not studio)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/13-vertical-template-spec.md`
