# 09 — `uploads` feature v0.1 spec

> **Status**: v0.1 contract for the file-upload feature.
> **Lives at**: `packages/platform-features/uploads/` (frontend) + `apps/api/uploads/` (backend; mounted per `15-apps-api-spec.md`).
> **Consumes**: `02-platform-shell-spec.md` (composables + `VerticalManifest.upload_handlers`); `03-auth-service-spec.md` (auth + permissions); `04-user-service-spec.md` (per-user quota counters surfaced via prefs in v0.2 — out of v0.1 scope).
> **Forwarded to from**: `05-feature-agora-spec.md` §5.4 (MaterialsPanel preview), `10-feature-wizard-spec.md` (materials attach step), vertical-specific upload handlers (per `02-platform-shell-spec.md` §3.1 `UploadHandlerContribution`).

---

## Mission

This file defines the uploads feature — the product-side file buffer where users stage materials before attaching them to a meeting (via wizard) and where agora retrieves preview-renderable representations afterwards. Studio v0.1 takes materials inline at `run_meeting` time (per `01-studio-client-spec.md` §4.6); product persists files so users can preview, re-attach, and inspect later. Verticals plug in custom upload handlers via the `VerticalManifest.upload_handlers` extension declared in `02` §3.1.

**Hard rule** (P3 boundary + no engine import): uploads is a **file storage service** — store, validate, fetch, preview, delete. No parsing of file content into structured data, no LLM-driven extraction, no agent reasoning. The vertical's upload handler may pre-process bytes (e.g., parse a CSV into rows for inline preview) but that processing is **deterministic + within the vertical's package**, never a studio call. v0.1 ships disk-backed storage; v0.2 may swap to object storage with no contract change.

---

## Scope

**Covers.**
- Module layout (frontend feature package + apps/api `uploads` router with disk storage + SQLite metadata table).
- 2 routes: `/platform/uploads` (manage files), `/platform/uploads/:upload_id` (single file detail / preview).
- 9 Vue components: `<UploadsView>`, `<UploadDropZone>`, `<UploadList>`, `<UploadRow>`, `<HandlerPicker>`, `<FileSelector>`, `<UploadPreviewOverlay>`, `<UploadProgressIndicator>`, plus `<PreviewRenderers/{Pdf,Image,Text,Generic}.vue>`.
- 4 composables: `useUpload`, `useUploadsList`, `useUploadPreview`, `useUploadHandlers`.
- 6 backend endpoints under `/api/uploads/*`.
- 1 SQLite table (`uploads`) keyed by upload_id.
- Disk-backed storage at `./.product_data/uploads/{user_id}/{upload_id}` with content-addressing (sha256) for dedup.
- Validation: per-file size cap (default 10 MB) + per-user total quota (default 1 GB) + MIME allowlist + handler-specific accept filter.
- 2 platform built-in handlers (`brief`, `data`) + the vertical extension API (handlers declared in `VerticalManifest.upload_handlers`).
- 4 preview renderers (PDF, image, text, generic-fallback).
- Sealed error taxonomy (6 leaves owned).
- Integration contracts with wizard (step 3 of meeting creation) and agora (MaterialsPanel preview overlay).
- Test matrix per endpoint + per component + per renderer.
- v0.2 storage-swap path (object storage) documented as non-breaking.

**Does not cover.**
- Wizard's overall flow — `10-feature-wizard-spec.md`. This spec only defines what the wizard's "attach materials" step calls.
- Agora's MaterialsPanel rendering — `05-feature-agora-spec.md` §5.4. This spec only defines the preview overlay opened from there.
- Vertical-specific file processing logic (e.g., parsing financial reports). Verticals may declare custom handlers per `02` §3.1; the handler component is the vertical's own code. This spec defines the extension contract, not handler implementations.
- Studio-side material handling — studio takes materials inline; uploads is product-side.
- File transformation pipelines (OCR, audio transcription, video extraction). v0.2.
- Multi-user shared uploads. v0.1 uploads are per-user.

**Out of scope for v0.1.**
- Object storage (S3-compatible). Local disk only; swap path documented (§3.2).
- Chunked / resumable uploads. 10 MB cap fits in a single multipart POST.
- Server-side virus scanning. Internal-product trust assumption; v0.2 may add ClamAV integration.
- Encryption-at-rest. Same rationale as `03-auth-service-spec.md` (single-tenant internal).
- Per-folder organization / tagging. Flat list per user.
- Sharing / public links.
- Versioning of an uploaded file. Re-uploading creates a new upload_id; no overwrite.
- Bulk upload via folder drag.

---

## §1 Module layout

### 1.1 Frontend package

```
packages/platform-features/uploads/
├── src/
│   ├── index.ts                             # exports UploadsView + uploadsRoutes + handler registry helpers
│   ├── UploadsView.vue                      # /platform/uploads main view
│   ├── components/
│   │   ├── UploadDropZone.vue               # drag-drop area
│   │   ├── UploadList.vue                   # vertical list of UploadRow
│   │   ├── UploadRow.vue                    # one upload entry (name, kind, size, actions)
│   │   ├── HandlerPicker.vue                # pick a handler kind (platform or vertical)
│   │   ├── FileSelector.vue                 # native file picker trigger
│   │   ├── UploadPreviewOverlay.vue         # modal opened from agora MaterialsPanel
│   │   ├── UploadProgressIndicator.vue      # per-file progress bar
│   │   └── PreviewRenderers/
│   │       ├── PdfPreview.vue               # iframe-based PDF render
│   │       ├── ImagePreview.vue             # img tag with object-fit
│   │       ├── TextPreview.vue              # syntax-highlighted text/JSON/CSV
│   │       └── GenericPreview.vue           # fallback: name + size + download button
│   ├── composables/
│   │   ├── useUpload.ts                     # POST /api/uploads with progress
│   │   ├── useUploadsList.ts                # GET /api/uploads
│   │   ├── useUploadPreview.ts              # GET /api/uploads/:id/preview
│   │   └── useUploadHandlers.ts             # platform built-ins + vertical extension merged
│   ├── handlers/
│   │   ├── briefHandler.ts                  # platform built-in: brief / generic
│   │   └── dataHandler.ts                   # platform built-in: data / structured
│   ├── routes.ts
│   ├── permissions.ts
│   └── i18n/
│       ├── zh.json
│       └── en.json
├── tests/
└── package.json
```

### 1.2 Backend module (apps/api)

```
apps/api/
└── uploads/
    ├── __init__.py
    ├── api.py                               # /api/uploads/* router
    ├── models.py                            # Upload, UploadDescriptor (mirrors MaterialDescriptor)
    ├── db/
    │   ├── tables.py
    │   └── crud.py
    ├── storage.py                           # FilesystemStorage (default); StorageBackend protocol
    ├── validation.py                        # size, MIME, handler-accept checks
    ├── preview.py                           # MIME-aware preview response builder
    ├── errors.py
    ├── config.py                            # UPLOADS_BASE_DIR, UPLOADS_MAX_FILE_BYTES, UPLOADS_USER_QUOTA_BYTES, UPLOADS_MIME_ALLOWLIST
    └── tests/
```

### 1.3 Permissions declared

```typescript
// packages/platform-features/uploads/src/permissions.ts
export const UPLOADS_PERMISSIONS = [
  { code: "platform:upload",        description: "Upload files to product storage" },
  { code: "platform:upload_list",   description: "List own uploads" },
  { code: "platform:upload_delete", description: "Delete own uploads" },
] as const;
```

The `/platform/uploads` route requires all three.

### 1.4 Routes declared

```typescript
// packages/platform-features/uploads/src/routes.ts
import type { RouteRecordRaw } from "vue-router";

export const uploadsRoutes: RouteRecordRaw[] = [
  {
    path: "/platform/uploads",
    name: "uploads",
    component: () => import("./UploadsView.vue"),
    meta: {
      required_permissions: ["platform:upload", "platform:upload_list", "platform:upload_delete"],
      title_key: "feature.uploads.title",
    },
  },
  {
    path: "/platform/uploads/:upload_id",
    name: "uploads-detail",
    component: () => import("./UploadsView.vue"),     // same view; pre-selects the file
    meta: {
      required_permissions: ["platform:upload_list"],
      title_key: "feature.uploads.title",
    },
    props: true,
  },
];
```

The wizard and agora's MaterialsPanel embed uploads composables / overlay components directly — they don't navigate to `/platform/uploads` to use uploads functionality.

---

## §2 Data models

### 2.1 SQLite schema

```sql
CREATE TABLE uploads (
    upload_id            TEXT PRIMARY KEY,                              -- ULID
    user_id              TEXT NOT NULL,                                  -- matches auth-service users.user_id (no FK; per 04 §10)
    display_name         TEXT NOT NULL,                                  -- original filename or user-supplied; <= 200 chars
    kind                 TEXT NOT NULL,                                  -- handler kind: "brief" | "data" | <vertical_id>:<handler_kind>
    studio_material_kind TEXT NOT NULL CHECK (studio_material_kind IN ('brief','data')),
    mime_type            TEXT NOT NULL,                                  -- detected at upload time
    size_bytes           INTEGER NOT NULL,
    sha256               TEXT NOT NULL,                                  -- hex; for dedup + integrity
    storage_path         TEXT NOT NULL,                                  -- relative to UPLOADS_BASE_DIR
    created_at           TEXT NOT NULL,
    last_accessed_at     TEXT NOT NULL,                                  -- updated on every fetch / preview / content read
    vertical_id          TEXT                                            -- snapshot of active vertical at upload time; nullable
);
CREATE INDEX idx_uploads_user ON uploads(user_id, created_at DESC);
CREATE INDEX idx_uploads_sha256 ON uploads(sha256);                     -- for dedup lookup (same user, same content)
```

**Why `last_accessed_at`.** Future garbage collection can prune uploads not accessed in N days. v0.1 has no GC; field reserved.

**Why content-addressing via `sha256`.** Same user uploading the identical file twice → same `sha256` → second upload returns the existing `upload_id` (with a 200 instead of 201). Saves disk + lets wizard re-attach without realizing. Cross-user dedup NOT done in v0.1 (privacy isolation outweighs disk).

### 2.2 Pydantic models

```python
# apps/api/uploads/models.py

from datetime import datetime
from typing import Annotated, Literal
from pydantic import BaseModel, StringConstraints

UploadId               = Annotated[str, StringConstraints(pattern=r"^[0-9A-HJKMNP-TV-Z]{26}$")]
HandlerKind            = Annotated[str, StringConstraints(pattern=r"^([a-z][a-z0-9_-]*|[a-z][a-z0-9_-]*:[a-z][a-z0-9_-]*)$", max_length=80)]
StudioMaterialKind     = Literal["brief", "data"]                       # matches studio §3.6
DisplayName            = Annotated[str, StringConstraints(min_length=1, max_length=200, strip_whitespace=True)]


class Upload(BaseModel):
    upload_id:             UploadId
    user_id:               str
    display_name:          DisplayName
    kind:                  HandlerKind
    studio_material_kind:  StudioMaterialKind
    mime_type:             str
    size_bytes:            int
    sha256:                str
    created_at:            datetime
    last_accessed_at:      datetime
    vertical_id:           str | None

class UploadDescriptor(BaseModel):
    """Sent to the wizard when it bundles MaterialDescriptor[] for run_meeting,
    AND mirrored to apps/api's meeting_metadata table per 05 §7."""
    upload_id:             UploadId
    name:                  DisplayName             # the descriptor's display name; matches Upload.display_name
    kind:                  StudioMaterialKind      # studio §3.6: "brief" | "data"
    size_bytes:            int
    preview_url:           str | None              # "/api/uploads/{upload_id}/preview" if previewable; null otherwise
```

### 2.3 Default MIME allowlist

```python
# apps/api/uploads/config.py
DEFAULT_MIME_ALLOWLIST: tuple[str, ...] = (
    # Documents
    "application/pdf",
    "text/plain",
    "text/markdown",
    "text/csv",
    "application/json",
    # Office
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",   # .docx
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",         # .xlsx
    # Images
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/svg+xml",
)
```

Verticals can EXTEND the allowlist via their handler's `accepts` field (per `02` §3.1) — handler-specific MIME types beyond the platform default are permitted only when the user uploads via that handler. The platform default is the "no specific handler" fallback.

---

## §3 Storage strategy

### 3.1 v0.1: filesystem-backed

```
UPLOADS_BASE_DIR/                                # default ./.product_data/uploads/
├── <user_id>/                                   # one dir per user
│   ├── <upload_id>                              # the actual file (no extension; content via DB)
│   └── ...
└── ...
```

`storage_path` in the DB is the relative path: `<user_id>/<upload_id>`.

**Why per-user dir.** Filesystem-level isolation; `chmod 700` per dir; one-line per-user purge if needed.

**Why no extension on disk.** Filename is `display_name` in DB; the disk file is purely opaque content. Avoids extension-spoofing attacks (display vs actual MIME mismatch).

### 3.2 v0.2 storage-swap path

`apps/api/uploads/storage.py` defines a `StorageBackend` Protocol:

```python
class StorageBackend(Protocol):
    async def write(self, *, user_id: str, upload_id: str, stream: AsyncIterable[bytes]) -> int:
        """Write bytes; return total size written."""
    async def read(self, *, user_id: str, upload_id: str) -> AsyncIterable[bytes]:
        """Stream bytes."""
    async def delete(self, *, user_id: str, upload_id: str) -> None: ...
    async def exists(self, *, user_id: str, upload_id: str) -> bool: ...
```

`FilesystemStorage` implements it for v0.1; `S3Storage` (or equivalent) implements it for v0.2 without changing API contracts. Configuration: `UPLOADS_STORAGE_BACKEND="filesystem" | "s3"` env var picks at boot.

---

## §4 API endpoints

All endpoints under `/api/uploads/*`. All require auth. All bodies / responses follow the standard error envelope per `03-auth-service-spec.md` §6.

### 4.1 `POST /api/uploads`

```
POST /api/uploads
  Content-Type: multipart/form-data
  fields:
    file:                  binary (required)
    kind:                  HandlerKind (required)
    studio_material_kind:  StudioMaterialKind (required)
    display_name:          str (optional; defaults to file's filename)
  auth:   required + permission "platform:upload"
  201:    Upload (newly created; or existing if dedup hit — see Behavior)
  200:    Upload (dedup hit — returned existing record without writing)
  400:    InvalidArgument (missing field; bad kind format; mismatched studio_material_kind for handler)
  401/403: relayed
  413:    FileTooLarge (extras: { max_bytes, actual_bytes })
  415:    UnsupportedMime (extras: { mime_type, allowed_mimes })
  507:    StorageFull (extras: { user_quota_bytes, used_bytes })
  500:    InternalStorageError
```

**Behavior.**
1. Validate `kind` against handler registry (404 if unknown — but actually 400 since the registry list is queryable).
2. Stream file into temp; compute SHA-256 + size.
3. Verify `size_bytes <= UPLOADS_MAX_FILE_BYTES` (default 10 MB) → else 413.
4. Detect MIME (via `python-magic` from content; do NOT trust filename).
5. Verify `mime_type` is in: handler's `accepts` (for vertical handlers) OR platform allowlist (for `kind in ("brief","data")`) → else 415.
6. Verify user's total quota: `SUM(size_bytes) WHERE user_id = ctx.user_id` + new size ≤ `UPLOADS_USER_QUOTA_BYTES` (default 1 GB) → else 507.
7. Dedup check: `SELECT upload_id WHERE user_id = ? AND sha256 = ?`. If row exists → return existing Upload with status 200 (no disk write).
8. Write file to `<user_id>/<upload_id>` via storage backend.
9. INSERT `uploads` row.
10. Return Upload with status 201.

### 4.2 `GET /api/uploads`

```
GET /api/uploads
  query:  ?limit=50, ?offset=0, ?kind=<handler_kind>
  auth:   required + permission "platform:upload_list"
  200:    { data: list[Upload], total: int, used_bytes: int, quota_bytes: int }
  401/403: relayed
```

Returns user's own uploads, ordered by `created_at` DESC. Includes quota info for UI display.

### 4.3 `GET /api/uploads/{upload_id}`

```
GET /api/uploads/{upload_id}
  auth:   required + permission "platform:upload_list"
  200:    Upload
  401/403: relayed
  404:    UploadNotFound (no row OR not owned by user)
```

User isolation: 404 (not 403) when not owned — avoids existence enumeration.

### 4.4 `GET /api/uploads/{upload_id}/content`

```
GET /api/uploads/{upload_id}/content
  auth:   required + permission "platform:upload_list"
  200:    binary stream
          Content-Type: <upload.mime_type>
          Content-Length: <upload.size_bytes>
          Content-Disposition: attachment; filename="<sanitized display_name>"
  401/403: relayed
  404:    UploadNotFound
  500:    InternalStorageError
```

Used by wizard to read bytes for inline-attaching to `studio.run_meeting`. Updates `last_accessed_at`.

### 4.5 `GET /api/uploads/{upload_id}/preview`

```
GET /api/uploads/{upload_id}/preview
  query:  ?excerpt=true (optional; for text/csv/json: returns first 5000 chars)
  auth:   required + permission "platform:upload_list"
  200:    response shape per MIME (see table below)
          Content-Disposition: inline
  401/403: relayed
  404:    UploadNotFound
  500:    InternalStorageError
```

**Per-MIME response**:

| MIME | Response | Disposition |
|---|---|---|
| `application/pdf` | full file | inline (browser embeds via `<iframe src=...>`) |
| `image/*` | full file | inline |
| `text/plain`, `text/markdown` | full file (or first 5000 chars if `excerpt=true`) | inline |
| `text/csv`, `application/json` | full file (or first 5000 chars) | inline |
| Office docs (`.docx`, `.xlsx`) | 415 — preview not supported in v0.1; UI falls back to GenericPreview | n/a |
| Other | 415 — same fallback | n/a |

Updates `last_accessed_at`.

### 4.6 `DELETE /api/uploads/{upload_id}`

```
DELETE /api/uploads/{upload_id}
  auth:   required + permission "platform:upload_delete"
  200:    { ok: true }
  401/403: relayed
  404:    UploadNotFound
  500:    InternalStorageError
```

Deletes file from storage AND removes row. **Caveat**: if the file is referenced by a `meeting_metadata` row (per `05-feature-agora-spec.md` §7), the meeting's MaterialsPanel will show "Materials unavailable" for the missing entry. v0.1 does NOT prevent this — uploads is the user's own filesystem; users can delete what they own. v0.2 may add a "in use by N meetings" warning before delete.

---

## §5 Frontend components

### 5.1 `<UploadsView>`

Top-level. Hosts the drag-drop zone, the list, the preview overlay (if a file is selected via route).

```typescript
export default defineComponent({
  props: {
    upload_id: { type: String, default: null },     // from /uploads/:upload_id route
  },
  setup(props) {
    const { uploads, used_bytes, quota_bytes, isLoading, error, refresh, deleteUpload } = useUploadsList();
    const { handlers } = useUploadHandlers();
    const previewOpen = ref(props.upload_id !== null);

    return { uploads, used_bytes, quota_bytes, isLoading, error, refresh, deleteUpload,
             handlers, previewOpen };
  },
});
```

**Renders.**
- Header: "Uploads" + quota indicator ("12 MB of 1 GB used").
- `<UploadDropZone>` at top.
- `<UploadList>` below.
- `<UploadPreviewOverlay>` if `previewOpen` (with `props.upload_id`).

### 5.2 `<UploadDropZone>`

```typescript
interface UploadDropZoneProps {
  handlers:  UploadHandler[];          // platform + vertical
  disabled:  boolean;                   // e.g., quota nearly full
}
interface UploadDropZoneEmits {
  (e: "files-dropped", files: { file: File; handler_kind: string }[]): void;
}
```

**Renders.** Dashed-border area with text "Drag files here or click to select". On hover-with-files: highlighted.

When user drops files OR picks via `<FileSelector>`: opens `<HandlerPicker>` as an inline overlay below the zone, asking "What kind?" per file (or apply to all). After confirmation, emits `files-dropped` with file + chosen handler_kind.

**Validation in dropzone.** Pre-check size against handler's `max_size_bytes`; reject locally with toast ("File too large") before POSTing.

### 5.3 `<HandlerPicker>`

```typescript
interface HandlerPickerProps {
  handlers:    UploadHandler[];
  files_count: number;
}
interface HandlerPickerEmits {
  (e: "selected", handler_kind: string): void;
  (e: "cancel"): void;
}
```

Modal/inline overlay listing handlers. Each row:
- Handler `label` (i18n-resolved)
- Accepted MIME types / extensions
- Max size

Default selection: platform `brief` (most permissive). Vertical-specific handlers shown above platform built-ins (so domain-specific intent is surfaced first).

### 5.4 `<UploadList>` + `<UploadRow>`

```typescript
interface UploadListProps {
  uploads:  Upload[];
  selected_id: string | null;
}
interface UploadListEmits {
  (e: "row-clicked", upload_id: string): void;
  (e: "delete-clicked", upload_id: string): void;
}
```

Vertical list of `<UploadRow>`s. Each row: icon (by MIME), display_name, kind chip, size humanized, created_at relative ("2h ago"), action buttons (preview / download / delete).

### 5.5 `<UploadProgressIndicator>`

Per-file linear progress bar. Shown overlaid in `<UploadDropZone>` while uploads are in flight. On completion: replaced with success checkmark for 2s then dismissed.

### 5.6 `<UploadPreviewOverlay>`

```typescript
interface UploadPreviewOverlayProps {
  upload_id:  string;
  open:       boolean;
}
interface UploadPreviewOverlayEmits {
  (e: "update:open", v: boolean): void;
}
```

**Renders.** Full-screen modal with:
- Header: display_name + close button + download link.
- Body: `<PreviewRenderers/Pdf|Image|Text|Generic>` selected based on `Upload.mime_type`.
- Footer: metadata (size, kind, created_at, sha256 short).

`<PdfPreview>` uses `<iframe src="/api/uploads/{id}/preview">` (browser-native).
`<ImagePreview>` uses `<img>` with object-fit contain.
`<TextPreview>` fetches via `useUploadPreview` (excerpt mode for files > 5000 chars); renders with monospace font + line numbers; syntax highlighting for JSON / CSV via lightweight client-side detection (no library — simple regex highlighting).
`<GenericPreview>` is the fallback: large icon + name + size + download button + "Preview not available for this file type."

---

## §6 Composables

### 6.1 `useUpload`

```typescript
export interface UploadProgress {
  upload_id_pending:  string;        // client-generated UUID for tracking before server assigns
  display_name:       string;
  bytes_uploaded:     number;
  bytes_total:        number;
  status:             "pending" | "uploading" | "complete" | "error";
  error:              string | null;
}

export function useUpload(): {
  upload(opts: {
    file:                File;
    handler_kind:        string;
    studio_material_kind: "brief" | "data";
    display_name?:       string;
  }): Promise<Upload>;
  progressFor(upload_id_pending: string): ComputedRef<UploadProgress | null>;
  inFlightCount: ComputedRef<number>;
};
```

**Behavior.**
1. Generate client-side `upload_id_pending` (UUID).
2. Validate locally (size, MIME against handler).
3. Build FormData; POST `/api/uploads` with `XMLHttpRequest` (for progress events, not fetch).
4. Track progress via `xhr.upload.onprogress`.
5. On success: resolve with `Upload` from response.
6. On error: surface localized error message.

### 6.2 `useUploadsList`

```typescript
export function useUploadsList(opts?: { kind_filter?: string }): {
  uploads:      ComputedRef<Upload[]>;
  used_bytes:   ComputedRef<number>;
  quota_bytes:  ComputedRef<number>;
  isLoading:    ComputedRef<boolean>;
  error:        ComputedRef<string | null>;
  refresh:      () => Promise<void>;
  deleteUpload: (upload_id: string) => Promise<void>;
};
```

### 6.3 `useUploadPreview`

```typescript
export function useUploadPreview(upload_id: string): {
  content:       ComputedRef<string | Blob | null>;     // string for text; Blob for binary
  mime_type:     ComputedRef<string | null>;
  truncated:     ComputedRef<boolean>;                   // true when excerpt=true returned partial
  isLoading:     ComputedRef<boolean>;
  error:         ComputedRef<string | null>;
};
```

**Behavior.** On mount: GET `/api/uploads/:id/preview?excerpt=true`. Auto-detect from response Content-Type whether to populate `content` as string vs Blob. For PDF / image: keep null and let the renderer use the URL directly via iframe / img.

### 6.4 `useUploadHandlers`

```typescript
export interface UploadHandler {
  kind:                 string;                        // "brief" | "data" | <vertical_id>:<handler_kind>
  source:               "platform" | string;           // vertical_id when from a vertical
  label:                string;                        // i18n-resolved
  description:          string;
  accepts:              string[];                      // MIME types or extensions
  max_size_bytes:       number;
  studio_material_kind: "brief" | "data";
  handler_component:    Component;                     // Vue component for vertical-specific UI; null for platform
}

export function useUploadHandlers(): {
  handlers: ComputedRef<UploadHandler[]>;              // platform built-ins + active vertical's handlers
};
```

**Behavior.** Reads platform built-ins from `handlers/{briefHandler,dataHandler}.ts`; reads vertical handlers from `useActiveVertical().active.value.upload_handlers` (the manifest field per `02` §3.1); merges; returns combined list ordered: vertical handlers first, then platform built-ins.

---

## §7 Integration with wizard

The wizard's "attach materials" step (per `10-feature-wizard-spec.md`, forward-declared) consumes uploads as follows:

```typescript
// inside wizard's materials step
import { useUpload, useUploadHandlers } from "@entelecheia/uploads";

const { upload } = useUpload();
const { handlers } = useUploadHandlers();

async function attachFile(file: File, handler: UploadHandler) {
  const uploaded = await upload({
    file,
    handler_kind:        handler.kind,
    studio_material_kind: handler.studio_material_kind,
  });
  // wizard pushes uploaded.upload_id into its draft.materials[]
}

// at run_meeting time:
async function buildMaterialsForRunMeeting(): Promise<Material[]> {
  const materials: Material[] = [];
  for (const upload_id of draft.materials) {
    const upload = await fetchUpload(upload_id);
    const content = await fetchUploadContent(upload_id);     // bytes; up to 10 MB
    materials.push({
      kind:    upload.studio_material_kind,
      name:    upload.display_name,
      content: upload.studio_material_kind === "brief"
                 ? content.toString("utf-8")     // string for brief
                 : parseDataContent(content),    // dict for data (JSON parse if applicable)
    });
  }
  return materials;
}

// after run_meeting:
async function persistMaterialMetadata(meeting_id: string) {
  // POST /api/meetings/{meeting_id}/metadata with MaterialDescriptor[] per 05 §7
  const descriptors: MaterialDescriptor[] = await Promise.all(
    draft.materials.map(async (upload_id) => {
      const u = await fetchUpload(upload_id);
      return {
        name:        u.display_name,
        kind:        u.studio_material_kind,
        size_bytes:  u.size_bytes,
        preview_url: previewable(u.mime_type) ? `/api/uploads/${upload_id}/preview` : null,
      };
    })
  );
  await postMeetingMetadata(meeting_id, { materials: descriptors });
}
```

This contract is what `10-feature-wizard-spec.md` MUST honor.

---

## §8 Integration with agora's MaterialsPanel

When the user clicks a material in agora's `<MaterialsPanel>` (per `05-feature-agora-spec.md` §5.4), the parent (`<AgoraView>`) opens `<UploadPreviewOverlay>` from this package:

```typescript
// agora's parent listens to MaterialsPanel emit
<MaterialsPanel @material-preview-clicked="onMaterialPreview" />
<UploadPreviewOverlay v-if="previewingUploadId"
                      :upload_id="previewingUploadId"
                      v-model:open="previewOpen" />

function onMaterialPreview(material_name: string) {
  // material_name is the display_name; we need to resolve to upload_id
  // Approach: meeting_metadata in apps/api stores both name AND upload_id refs
  // (forward-declared in 05 §7; spec 15 fully defines)
  // Find the matching upload_id from meeting_metadata, then open preview
}
```

The `meeting_metadata.materials` JSON field stores `MaterialDescriptor` with an extra `upload_id` field (apps/api's internal extension; not exposed in the descriptor returned to clients except as `preview_url`). Spec 15 finalizes this.

---

## §9 Sealed error taxonomy (uploads-owned)

```python
# apps/api/uploads/errors.py

class UploadsError(Exception):
    error_type:  str
    http_status: int
    message:     str

# 400
class InvalidHandler(UploadsError):           ...   # 400  — kind not in registered handlers; extras: { kind, available_kinds }

# 404
class UploadNotFound(UploadsError):           ...   # 404  — covers "doesn't exist" + "not owned by user"

# 413
class FileTooLarge(UploadsError):             ...   # 413  — extras: { max_bytes, actual_bytes }

# 415
class UnsupportedMime(UploadsError):          ...   # 415  — extras: { mime_type, allowed_mimes, handler_kind }

# 507
class StorageFull(UploadsError):              ...   # 507  — user quota exceeded; extras: { quota_bytes, used_bytes, attempted_bytes }

# 500
class InternalStorageError(UploadsError):     ...   # 500  — disk write/read failure; extras: { trace_id }
```

**Total leaves owned: 6.** Auth-relayed leaves (`AuthRequired`, `PermissionDenied`) come from `03`.

---

## §10 Configuration

```python
# apps/api/uploads/config.py
class UploadsSettings(BaseSettings):
    base_dir:                  str = "./.product_data/uploads"
    storage_backend:           Literal["filesystem", "s3"] = "filesystem"
    max_file_bytes:            int = 10 * 1024 * 1024              # 10 MB
    user_quota_bytes:          int = 1024 * 1024 * 1024            # 1 GB
    mime_allowlist:            list[str] = list(DEFAULT_MIME_ALLOWLIST)
    preview_excerpt_max_chars: int = 5000

    class Config:
        env_prefix = "UPLOADS_"
```

---

## §11 i18n

```json
{
  "feature.uploads.title": "Uploads",
  "feature.uploads.quota_indicator": "{used} of {quota} used",

  "feature.uploads.dropzone.idle":           "Drag files here or click to select",
  "feature.uploads.dropzone.hover":          "Drop to upload",
  "feature.uploads.dropzone.disabled":       "Quota nearly full; delete files before uploading more.",
  "feature.uploads.dropzone.toast.too_large":"File too large for this handler ({max}).",

  "feature.uploads.handler_picker.title":    "What kind of file?",
  "feature.uploads.handler_picker.cancel":   "Cancel",
  "feature.uploads.handler_picker.confirm":  "Upload {count} file(s) as {kind}",
  "feature.uploads.handler_picker.platform.brief":  "Brief / Document",
  "feature.uploads.handler_picker.platform.data":   "Data / Structured",

  "feature.uploads.list.empty":              "No uploads yet.",
  "feature.uploads.list.col_name":           "Name",
  "feature.uploads.list.col_kind":           "Kind",
  "feature.uploads.list.col_size":           "Size",
  "feature.uploads.list.col_created":        "Uploaded",
  "feature.uploads.list.col_actions":        "Actions",
  "feature.uploads.list.action_preview":     "Preview",
  "feature.uploads.list.action_download":    "Download",
  "feature.uploads.list.action_delete":      "Delete",
  "feature.uploads.list.delete_confirm":     "Delete {name}? This cannot be undone.",

  "feature.uploads.progress.uploading":      "Uploading {name}…",
  "feature.uploads.progress.complete":       "{name} uploaded",

  "feature.uploads.preview.close":           "Close",
  "feature.uploads.preview.download":        "Download",
  "feature.uploads.preview.unavailable":     "Preview not available for this file type.",
  "feature.uploads.preview.truncated":       "Showing first {chars} characters; download to see full file.",

  "feature.uploads.error.file_too_large":    "File is {actual}; maximum is {max}.",
  "feature.uploads.error.unsupported_mime":  "File type {mime} is not supported by this handler.",
  "feature.uploads.error.invalid_handler":   "That upload kind is not available.",
  "feature.uploads.error.storage_full":      "You've used {used} of {quota}. Delete files before uploading more.",
  "feature.uploads.error.upload_not_found":  "File not found.",
  "feature.uploads.error.internal_storage":  "Could not save your file. Try again."
}
```

---

## §12 Test matrix

### 12.1 API endpoints

| scenario | request | expected | test_id |
|---|---|---|---|
| upload happy | valid file + brief handler | 201 with Upload; file on disk; row in DB | `t_api_upload_happy` |
| upload dedup | same file twice (same sha256, same user) | second returns 200 with existing Upload; no second disk write | `t_api_upload_dedup` |
| file too large | 11 MB file with default 10 MB cap | 413 `file_too_large` with extras | `t_api_upload_too_large` |
| unsupported mime | .exe file | 415 `unsupported_mime` | `t_api_upload_bad_mime` |
| handler accepts override | vertical handler accepts ".tsv" not in default allowlist; upload .tsv via that handler | 201 ok | `t_api_upload_handler_accepts` |
| invalid handler kind | kind="nonsense" | 400 `invalid_handler` | `t_api_upload_bad_handler` |
| user quota exceeded | user has 1 GB used; uploads any file | 507 `storage_full` | `t_api_upload_quota` |
| MIME spoofing | .pdf extension on actually .exe content | 415 (mime detection from content, not filename) | `t_api_upload_mime_spoofing` |
| list happy | user has 5 uploads | 200 with paged list + quota info | `t_api_list_happy` |
| list filter by kind | ?kind=brief | only brief uploads | `t_api_list_filter` |
| get own | upload exists | 200 Upload | `t_api_get_own` |
| get not owned | other user's upload | 404 `upload_not_found` (not 403) | `t_api_get_isolation` |
| download content | own upload | 200 binary with Content-Disposition: attachment | `t_api_download` |
| preview pdf | pdf upload | 200 with Content-Disposition: inline | `t_api_preview_pdf` |
| preview text excerpt | 10000-char text + ?excerpt=true | first 5000 chars + truncated indicator | `t_api_preview_text_excerpt` |
| preview unsupported | .docx | 415 (UI falls back to GenericPreview) | `t_api_preview_unsupported` |
| delete own | own upload | 200; row gone; file gone | `t_api_delete_happy` |
| delete not owned | other user's | 404 | `t_api_delete_isolation` |
| concurrent upload | 5 simultaneous POSTs by same user | all succeed; quota updated atomically | `t_api_upload_concurrent` |

### 12.2 Components

| scenario | expected | test_id |
|---|---|---|
| dropzone accepts files | 3 files dropped → emits `files-dropped` with array | `t_dz_drop_emit` |
| dropzone rejects too-large file pre-flight | local validation; toast | `t_dz_pre_validate` |
| handler picker default selection | platform brief | `t_hp_default` |
| handler picker vertical first | vertical handler appears above platform | `t_hp_vertical_above` |
| upload progress updates | xhr.onprogress fires; bar fills | `t_up_progress` |
| upload error shows in row | API returns 413 | row shows error icon + message | `t_up_error_inline` |
| preview pdf renders iframe | mime=pdf | iframe with src=/preview | `t_pp_pdf_iframe` |
| preview image renders img | mime=image/png | img tag with object-fit | `t_pp_image` |
| preview text renders monospace | mime=text/plain | pre/code element with content | `t_pp_text` |
| preview text truncated banner | truncated=true | banner + download link | `t_pp_text_truncated` |
| preview generic fallback | mime=docx | GenericPreview with download button | `t_pp_generic` |
| list empty state | 0 uploads | empty state visible | `t_ul_empty` |
| list quota indicator | used + quota in header | accurate display | `t_ul_quota_display` |
| delete confirm | confirm modal then API call | row removed | `t_ul_delete_confirm` |
| route /uploads/:id pre-selects | direct nav | preview overlay open | `t_uv_deep_link` |

### 12.3 Composables

| scenario | expected | test_id |
|---|---|---|
| useUpload progress | xhr progress events propagate | `t_uu_progress` |
| useUpload local size validation | rejects locally; no POST | `t_uu_local_validate` |
| useUploadHandlers merges | platform + vertical | `t_uh_merge` |
| useUploadHandlers vertical change | re-merges on switch | `t_uh_vertical_change` |
| useUploadPreview text fetch | excerpt mode | `t_upv_text` |

---

## §13 Why this design — load-bearing decisions

**Why product-side storage (not studio).**
Studio takes materials inline at `run_meeting` time (per `01-studio-client-spec.md` §4.6) — there's no storage round trip. Product needs persistence so users can preview later (agora MaterialsPanel) and re-attach (re-running similar meetings without re-uploading). Studio explicitly does not store inputs (per `01` §11.5 / §11.7 derivative pattern).
*Considered and rejected.* **Push to studio for storage** — studio doesn't have an upload endpoint; would require studio API expansion.

**Why disk in v0.1, not object storage.**
Operational simplicity for an internal v0.1 product. The `StorageBackend` Protocol (§3.2) lets v0.2 swap to S3 / MinIO without API changes. Local disk works for sub-1-GB-per-user volumes; the disk fills before the user feels it — enforced via the 1 GB quota.
*Considered and rejected.* **S3 from day 1** — needs cloud creds + buckets + IAM; over-engineering for internal use.

**Why content-addressed dedup (sha256), per-user only.**
Same file uploaded twice by same user → same upload_id → no disk waste, wizard re-attach is seamless. Cross-user dedup would save more disk but leak: user A could discover that user B uploaded the same file by getting back an existing upload_id (timing oracle). Per-user-only sidesteps that.
*Considered and rejected.* **Cross-user dedup** — privacy leak. **No dedup** — disk waste for users who re-upload the same brief.

**Why MIME detection from content, not filename.**
Filename extensions can be spoofed. `python-magic` reads the first ~512 bytes for MIME determination — security-sound + standard. Test `t_api_upload_mime_spoofing` enforces.
*Considered and rejected.* **Trust the filename extension** — trivially bypassed.

**Why no extension on disk filename.**
Disk filename is opaque (the upload_id ULID). Display name + MIME live in DB. Avoids any extension-based attack surface (e.g., webserver mistakenly serving as .html instead of as binary). Also keeps directory listings free of meaningful info if the dir is leaked.
*Considered and rejected.* **`<upload_id>.<extension>` on disk** — small attack surface for no benefit.

**Why per-user dir (not flat dir with all uploads).**
Filesystem-level user isolation; trivial chmod 700 per dir; one-line `rm -rf` per-user purge if a user is deactivated and admin wants to reclaim space. Flat dir would conflate users.
*Considered and rejected.* **Flat `<upload_id>` paths** — harder to reason about isolation.

**Why 10 MB per-file + 1 GB per-user defaults.**
10 MB fits a complex PDF, several spreadsheets, dozens of images — covers typical "brief" sizes. 1 GB per user lets users accumulate ~100 of those — generous for an internal product. Quotas tunable via env. Beyond these, deferred to v0.2 with chunked uploads.
*Considered and rejected.* **No quotas** — runaway disk; bad operations. **Lower limits** — too restrictive for normal use.

**Why dedup returns 200 not 201 on hit.**
HTTP semantic: 201 means "created". A dedup hit creates nothing. 200 + identical body is honest. Frontend treats both equivalently — the response shape is a `Upload` either way.
*Considered and rejected.* **Always 201** — semantically wrong. **204 + no body** — frontend would have to follow up with GET to get the upload_id.

**Why vertical handlers extend the platform allowlist (not replace).**
A vertical needs to allow `.tsv` (say); platform's brief handler doesn't include it. The vertical's handler-specific `accepts` extends what's allowed when uploading via that handler. The platform default still applies for `brief` / `data` (no handler picked). This way verticals can't shrink platform's surface (only grow per-handler).
*Considered and rejected.* **Verticals replace allowlist** — gives verticals power to forbid things they shouldn't. **Single global allowlist** — verticals can't add formats the platform doesn't anticipate.

**Why no virus scanning v0.1.**
Internal trusted-tenant; user uploads files for their own meetings. v0.2 ClamAV integration is straightforward (the `StorageBackend.write` step gets a pre-write hook). Documented as deferral.
*Considered and rejected.* **ClamAV in v0.1** — requires separate process, signature DB updates, operational overhead.

**Why DELETE is hard (not soft) — same as chathub.**
Users own their uploads. Hard delete + storage cleanup keeps things simple. v0.2 may add "in use by N meetings" warning before delete. Storage cleanup is on the same DB transaction (file delete + row delete), but file delete failure is logged and proceeds anyway (orphan files cleaned by future GC script).
*Considered and rejected.* **Soft delete** — disk doesn't shrink; no audit need at v0.1.

---

## §14 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | `useActiveVertical().active.value.upload_handlers` consumed by `useUploadHandlers()` — already in 02 §3.1 manifest interface; no change. |
| `03-auth-service-spec.md` | 3 new permissions (`platform:upload`, `platform:upload_list`, `platform:upload_delete`) registered at boot. |
| `05-feature-agora-spec.md` | `<MaterialsPanel>` `material-preview-clicked` opens `<UploadPreviewOverlay>` (§8). The `meeting_metadata.materials` records `upload_id` alongside the descriptor (apps/api internal — surfaced as `preview_url` to clients). Already in 05 §7. |
| `10-feature-wizard-spec.md` | Wizard's "attach materials" step uses `useUpload` per §7 contract; collects `upload_id`s; on run_meeting reads bytes and passes inline to studio. |
| `13-vertical-template-spec.md` | Vertical template's `frontend/handlers/` folder MAY contain vertical-specific upload handler components matching the `UploadHandlerContribution` interface. The spec must explicitly document the file pattern + entry point. |
| `15-apps-api-spec.md` | Mounts `/api/uploads/*` router; provisions `UPLOADS_BASE_DIR`; runs Alembic migrations for `uploads.db`; wires `meeting_metadata.materials` to also store `upload_id` references for the agora preview path. |
| `17-substitution-tests-spec.md` | No `[SUB]` tests here (uploads is product-side; no studio interaction). API tests run against the FilesystemStorage backend; v0.2 adds S3Storage backend with the same suite. |

---

## §15 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (object storage, chunked uploads, virus scan, encryption, folders, sharing, versioning, bulk folder upload)
- [ ] Module layout (§1) covers frontend + backend
- [ ] 3 permissions declared (§1.3); registered at boot
- [ ] 2 routes (§1.4) covering list + detail
- [ ] SQLite schema (§2.1) has 1 table with content-address index; storage strategy explicit (§3)
- [ ] Pydantic models (§2.2) with regex constraints; Upload + UploadDescriptor distinct
- [ ] Default MIME allowlist (§2.3) explicit; vertical extension rule documented
- [ ] All 6 API endpoints (§4) with method + path + body + auth + status + extras + behavior
- [ ] Per-MIME preview response table (§4.5) covers PDF / image / text / unsupported
- [ ] All 9 frontend components (§5) with full TS prop / emit signatures + render rules
- [ ] All 4 composables (§6) with signatures + behavior
- [ ] Wizard integration contract (§7) shows full flow: upload → buffer → run_meeting inline → metadata persist
- [ ] Agora MaterialsPanel preview integration (§8) documented; meeting_metadata.materials includes upload_id
- [ ] Sealed error taxonomy (§9): 6 leaves with extras
- [ ] Configuration (§10): every env var with default
- [ ] i18n keys (§11) for every user-visible string
- [ ] Test matrix (§12): API (~19), components (~15), composables (~5); ≥ 35 rows total
- [ ] Why-this / why-not (§13) for ≥ 8 load-bearing decisions
- [ ] Downstream impact (§14) lists every spec affected
- [ ] No business / domain / product / agent-role string literals (uses neutral file types and `vertical-a`)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No `try: ... except Exception: pass` patterns
- [ ] MIME detection is content-based (not filename-based)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/09-feature-uploads-spec.md`
