# 09 — `uploads` feature v0.1 spec

> **Status**: v0.1 contract for the file-upload feature. **Frontend stack**: React 18 + TypeScript + Zustand + React Router v6 + react-i18next + Tailwind, plus `focus-trap-react` (UploadPreviewOverlay; shared dep with 05/08).
> **Lives at**: `packages/platform-features/uploads/` (frontend) + `apps/api/uploads/` (backend; mounted per `15-apps-api-spec.md`).
> **Consumes**: `02-platform-shell-spec.md` (hooks + `VerticalManifest.upload_handlers`); `03-auth-service-spec.md` (auth + permissions); `04-user-service-spec.md` (per-user quota counters surfaced via prefs in v0.2 — out of v0.1 scope).
> **Forwarded to from**: `05-feature-agora-spec.md` §5.4 (MaterialsPanel preview), `10-feature-wizard-spec.md` (materials attach step), vertical-specific upload handlers (per `02-platform-shell-spec.md` §3.1 `UploadHandlerContribution`).
> **Supersedes**: the Vue version of this spec (committed in `bbfb583`); React migration per session decision 2026-05-03.

---

## Mission

This file defines the uploads feature — the product-side file buffer where users stage materials before attaching them to a meeting (via wizard) and where agora retrieves preview-renderable representations afterwards. Studio v0.1 takes materials inline at `run_meeting` time (per `01-studio-client-spec.md` §4.6); product persists files so users can preview, re-attach, and inspect later. Verticals plug in custom upload handlers via the `VerticalManifest.upload_handlers` extension declared in `02` §3.1.

**Hard rule** (P3 boundary + no engine import): uploads is a **file storage service** — store, validate, fetch, preview, delete. No parsing of file content into structured data, no LLM-driven extraction, no agent reasoning. The vertical's upload handler may pre-process bytes (e.g., parse a CSV into rows for inline preview) but that processing is **deterministic + within the vertical's package**, never a studio call. v0.1 ships disk-backed storage; v0.2 may swap to object storage with no contract change.

---

## Scope

**Covers.**
- Module layout (frontend feature package + apps/api `uploads` router with disk storage + SQLite metadata table).
- 2 routes: `/platform/uploads` (manage files), `/platform/uploads/:upload_id` (single file detail / preview).
- 9 React components: `<UploadsView>`, `<UploadDropZone>`, `<UploadList>`, `<UploadRow>`, `<HandlerPicker>`, `<FileSelector>`, `<UploadPreviewOverlay>`, `<UploadProgressIndicator>`, plus `<PreviewRenderers/{Pdf,Image,Text,Generic}>`.
- 4 React hooks: `useUpload`, `useUploadsList`, `useUploadPreview`, `useUploadHandlers`.
- 6 backend endpoints under `/api/uploads/*` — UNCHANGED from Vue version (Python).
- 1 SQLite table (`uploads`) keyed by upload_id — UNCHANGED.
- Disk-backed storage at `./.product_data/uploads/{user_id}/{upload_id}` with content-addressing (sha256) for dedup — UNCHANGED.
- Validation: per-file size cap (default 10 MB) + per-user total quota (default 1 GB) + MIME allowlist + handler-specific accept filter — UNCHANGED.
- 2 platform built-in handlers (`brief`, `data`) + the vertical extension API (handlers declared in `VerticalManifest.upload_handlers`).
- 4 preview renderers (PDF, image, text, generic-fallback).
- Sealed error taxonomy (6 leaves owned) — UNCHANGED.
- Integration contracts with wizard (step 3 of meeting creation) and agora (MaterialsPanel preview overlay).
- Test matrix per endpoint + per component + per renderer.
- v0.2 storage-swap path (object storage) documented as non-breaking — UNCHANGED.

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
│   ├── UploadsView.tsx                      # /platform/uploads main view
│   ├── components/
│   │   ├── UploadDropZone.tsx               # drag-drop area; HTML5 drag events
│   │   ├── UploadList.tsx                   # list of UploadRow
│   │   ├── UploadRow.tsx                    # one upload entry (name, kind, size, actions)
│   │   ├── HandlerPicker.tsx                # pick a handler kind (platform or vertical)
│   │   ├── FileSelector.tsx                 # native file picker trigger (<input type=file>)
│   │   ├── UploadPreviewOverlay.tsx         # native <dialog> + focus-trap-react; opened from agora
│   │   ├── UploadProgressIndicator.tsx      # per-file progress bar (XHR-driven)
│   │   └── PreviewRenderers/
│   │       ├── PdfPreview.tsx               # <iframe>-based PDF render
│   │       ├── ImagePreview.tsx             # <img> with object-fit
│   │       ├── TextPreview.tsx              # syntax-highlighted text/JSON/CSV (regex; no lib)
│   │       └── GenericPreview.tsx           # fallback: name + size + download button
│   ├── hooks/
│   │   ├── useUpload.ts                     # POST /api/uploads via XHR (for upload progress events)
│   │   ├── useUploadsList.ts                # GET /api/uploads
│   │   ├── useUploadPreview.ts              # GET /api/uploads/:id/preview
│   │   └── useUploadHandlers.ts             # platform built-ins + vertical extension merged
│   ├── stores/
│   │   ├── useUploadProgressStore.ts        # Zustand store for in-flight upload progress (shared across components)
│   │   └── useUploadsListStore.ts           # Zustand store for list + quota cache
│   ├── handlers/
│   │   ├── briefHandler.ts                  # platform built-in: brief / generic
│   │   └── dataHandler.ts                   # platform built-in: data / structured
│   ├── routes.ts
│   ├── permissions.ts
│   └── i18n/
│       ├── zh.json
│       └── en.json
├── tests/
└── package.json                             # depends on react, react-dom, react-router-dom,
                                             #            zustand, react-i18next,
                                             #            focus-trap-react (shared with 05/08)
```

### 1.2 Backend module (in apps/api) — UNCHANGED FROM VUE VERSION

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
import type { RouteObject } from "react-router-dom";
import { makePermissionsLoader, makePermissionLoader } from "@entelecheia/platform-shell";

export const uploadsRoutes: RouteObject[] = [
  {
    path: "/platform/uploads",
    lazy: async () => {
      const { UploadsView } = await import("./UploadsView");
      return { Component: UploadsView };
    },
    loader: makePermissionsLoader(["platform:upload", "platform:upload_list", "platform:upload_delete"]),
    handle: { title_key: "feature.uploads.title" },
  },
  {
    path: "/platform/uploads/:upload_id",
    lazy: async () => {
      const { UploadsView } = await import("./UploadsView");
      return { Component: UploadsView };
    },
    loader: makePermissionLoader("platform:upload_list"),
    handle: { title_key: "feature.uploads.title" },
  },
];
```

The wizard and agora's MaterialsPanel embed uploads hooks / overlay components directly — they don't navigate to `/platform/uploads` to use uploads functionality.

---

## §2 Data models — UNCHANGED FROM VUE VERSION

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

### 2.2 Pydantic models

```python
# apps/api/uploads/models.py — unchanged

from datetime import datetime
from typing import Annotated, Literal
from pydantic import BaseModel, StringConstraints

UploadId               = Annotated[str, StringConstraints(pattern=r"^[0-9A-HJKMNP-TV-Z]{26}$")]
HandlerKind            = Annotated[str, StringConstraints(pattern=r"^([a-z][a-z0-9_-]*|[a-z][a-z0-9_-]*:[a-z][a-z0-9_-]*)$", max_length=80)]
StudioMaterialKind     = Literal["brief", "data"]
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
    upload_id:             UploadId
    name:                  DisplayName
    kind:                  StudioMaterialKind
    size_bytes:            int
    preview_url:           str | None
```

### 2.3 Default MIME allowlist — UNCHANGED

```python
DEFAULT_MIME_ALLOWLIST: tuple[str, ...] = (
    "application/pdf",
    "text/plain",
    "text/markdown",
    "text/csv",
    "application/json",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/svg+xml",
)
```

---

## §3 Storage strategy — UNCHANGED

v0.1: filesystem-backed; per-user dirs at `UPLOADS_BASE_DIR/<user_id>/<upload_id>`. v0.2: `StorageBackend` Protocol allows S3 swap via env var. Full details unchanged from Vue version.

---

## §4 API endpoints — UNCHANGED FROM VUE VERSION

All under `/api/uploads/*`. All require auth. All bodies / responses follow the standard error envelope per `03-auth-service-spec.md` §6.

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
  201:    Upload (newly created; or existing if dedup hit)
  200:    Upload (dedup hit — returned existing record without writing)
  400:    InvalidArgument
  401/403: relayed
  413:    FileTooLarge (extras: { max_bytes, actual_bytes })
  415:    UnsupportedMime (extras: { mime_type, allowed_mimes })
  507:    StorageFull (extras: { user_quota_bytes, used_bytes })
  500:    InternalStorageError
```

### 4.2 `GET /api/uploads`

```
GET /api/uploads
  query:  ?limit=50, ?offset=0, ?kind=<handler_kind>
  auth:   required + permission "platform:upload_list"
  200:    { data: list[Upload], total: int, used_bytes: int, quota_bytes: int }
```

### 4.3 `GET /api/uploads/{upload_id}`

```
GET /api/uploads/{upload_id}
  auth:   required + permission "platform:upload_list"
  200:    Upload
  401/403: relayed
  404:    UploadNotFound (no row OR not owned by user; 404 not 403)
```

### 4.4 `GET /api/uploads/{upload_id}/content`

```
GET /api/uploads/{upload_id}/content
  auth:   required + permission "platform:upload_list"
  200:    binary stream
          Content-Type: <upload.mime_type>
          Content-Length: <upload.size_bytes>
          Content-Disposition: attachment; filename="<sanitized display_name>"
```

Used by wizard to read bytes for inline-attaching to `studio.run_meeting`. Updates `last_accessed_at`.

### 4.5 `GET /api/uploads/{upload_id}/preview`

```
GET /api/uploads/{upload_id}/preview
  query:  ?excerpt=true (optional; for text/csv/json: returns first 5000 chars)
  auth:   required + permission "platform:upload_list"
  200:    response shape per MIME (see table below)
          Content-Disposition: inline
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

### 4.6 `DELETE /api/uploads/{upload_id}`

```
DELETE /api/uploads/{upload_id}
  auth:   required + permission "platform:upload_delete"
  200:    { ok: true }
```

Hard delete + storage cleanup. Permanent. v0.1 has no soft-delete.

---

## §5 Frontend components

### 5.1 `<UploadsView>`

Top-level. Hosts the drag-drop zone, the list, the preview overlay (if a file is selected via route).

```typescript
import { useParams } from "react-router-dom";
import { useState } from "react";
import { useUploadsList } from "./hooks/useUploadsList";
import { useUploadHandlers } from "./hooks/useUploadHandlers";

export function UploadsView() {
  const { upload_id } = useParams<{ upload_id?: string }>();
  const { uploads, used_bytes, quota_bytes, isLoading, error, refresh, deleteUpload } = useUploadsList();
  const { handlers } = useUploadHandlers();
  const [previewUploadId, setPreviewUploadId] = useState<string | null>(upload_id ?? null);

  // ...render header + UploadDropZone + UploadList + UploadPreviewOverlay
}
```

**Renders.**
- Header: "Uploads" + quota indicator ("12 MB of 1 GB used").
- `<UploadDropZone>` at top.
- `<UploadList>` below.
- `<UploadPreviewOverlay>` if `previewUploadId !== null` (with that id).

### 5.2 `<UploadDropZone>`

```typescript
export interface UploadDropZoneProps {
  handlers:  UploadHandler[];          // platform + vertical
  disabled:  boolean;                   // e.g., quota nearly full
  onFilesDropped: (files: { file: File; handler_kind: string }[]) => void;
}

export function UploadDropZone(props: UploadDropZoneProps): React.ReactElement;
```

**Implementation.** HTML5 drag events + React state:

```typescript
const [isDragging, setIsDragging] = useState(false);
const [pendingFiles, setPendingFiles] = useState<File[] | null>(null);
const inputRef = useRef<HTMLInputElement>(null);

function onDragOver(e: React.DragEvent) {
  e.preventDefault();
  setIsDragging(true);
}
function onDragLeave(e: React.DragEvent) { setIsDragging(false); }
function onDrop(e: React.DragEvent) {
  e.preventDefault();
  setIsDragging(false);
  const files = Array.from(e.dataTransfer.files);
  setPendingFiles(files);     // triggers HandlerPicker
}
function onFileInputChange(e: React.ChangeEvent<HTMLInputElement>) {
  if (e.target.files) setPendingFiles(Array.from(e.target.files));
}
```

**Renders.**
- Dashed-border area with text "Drag files here or click to select".
- On hover-with-files (`isDragging`): highlighted styling.
- Hidden `<input ref={inputRef} type="file" multiple onChange={onFileInputChange}>`; click on the zone triggers `inputRef.current?.click()`.
- When `pendingFiles !== null`: renders inline `<HandlerPicker files_count={...} />`; on confirm, emits `onFilesDropped` with each file paired to chosen handler_kind, then clears pending.

**Validation in dropzone.** Pre-check size against handler's `max_size_bytes`; reject locally with toast (`useToast()`) before invoking `onFilesDropped`.

### 5.3 `<HandlerPicker>`

```typescript
export interface HandlerPickerProps {
  handlers:    UploadHandler[];
  files_count: number;
  onSelected:  (handler_kind: string) => void;
  onCancel:    () => void;
}

export function HandlerPicker(props: HandlerPickerProps): React.ReactElement;
```

Inline overlay listing handlers. Each row: handler `label` (i18n-resolved) + accepted MIME types/extensions + max size. Default selection: platform `brief`. Vertical-specific handlers shown above platform built-ins.

### 5.4 `<UploadList>` + `<UploadRow>`

```typescript
export interface UploadListProps {
  uploads:        Upload[];
  selected_id:    string | null;
  onRowClicked:   (upload_id: string) => void;
  onDeleteClicked: (upload_id: string) => void;
}

export function UploadList(props: UploadListProps): React.ReactElement;
```

`<UploadRow>`: icon (by MIME), display_name, kind chip, size humanized, created_at relative ("2h ago"), action buttons (preview / download / delete).

### 5.5 `<UploadProgressIndicator>`

Per-file linear progress bar. Shown overlaid in `<UploadDropZone>` while uploads are in flight (reads from `useUploadProgressStore`). On completion: replaced with success checkmark for 2s then dismissed.

```typescript
export function UploadProgressIndicator(): React.ReactElement | null {
  const inFlight = useUploadProgressStore(s => s.inFlight);  // Map<pending_id, UploadProgress>
  if (inFlight.size === 0) return null;
  return (
    <div className="space-y-2">
      {Array.from(inFlight.values()).map(p => (
        <ProgressBar key={p.upload_id_pending} progress={p} />
      ))}
    </div>
  );
}
```

### 5.6 `<UploadPreviewOverlay>`

```typescript
export interface UploadPreviewOverlayProps {
  upload_id:  string;
  open:       boolean;
  onClose:    () => void;
}

export function UploadPreviewOverlay(props: UploadPreviewOverlayProps): React.ReactElement | null;
```

**Implementation.** Native `<dialog>` + `focus-trap-react` (same pattern as `05-feature-agora-spec.md` §5.7 ProvenanceModal + `08-feature-chathub-spec.md` §5.3 NewChatModal). Shared dep — zero new bundle.

**Renders.** Full-screen modal with:
- Header: display_name + close button + download link.
- Body: one of `<PdfPreview>` / `<ImagePreview>` / `<TextPreview>` / `<GenericPreview>` selected based on `Upload.mime_type`.
- Footer: metadata (size, kind, created_at, sha256 short).

**Per-renderer details:**

```typescript
// <PdfPreview>: <iframe src={`/api/uploads/${id}/preview`} title={display_name} />
// <ImagePreview>: <img src={`/api/uploads/${id}/preview`} alt={display_name} className="object-contain" />
// <TextPreview>: useUploadPreview(id) → fetch text excerpt → render in <pre> with line numbers
// <GenericPreview>: large icon + name + size + <a href={`/api/uploads/${id}/content`} download>Download</a>
```

`<TextPreview>` syntax highlighting via lightweight regex (no library — for JSON/CSV common cases).

---

## §6 Hooks

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

export interface UseUploadReturn {
  upload(opts: {
    file:                File;
    handler_kind:        string;
    studio_material_kind: "brief" | "data";
    display_name?:       string;
  }): Promise<Upload>;
  inFlightCount: number;
}

export function useUpload(): UseUploadReturn;
```

**Implementation.** Uses XHR (NOT fetch — XHR is the only browser API that exposes upload progress events; fetch v0.1 doesn't support `Request` body progress without ReadableStream complexity). Progress state lives in `useUploadProgressStore` so `<UploadProgressIndicator>` can render it.

```typescript
export function useUpload(): UseUploadReturn {
  const upload = useCallback((opts) => {
    const upload_id_pending = crypto.randomUUID();

    // Local validation
    if (opts.file.size > getHandler(opts.handler_kind).max_size_bytes) {
      throw new ValidationError("file_too_large");
    }
    if (!matchesAccepts(opts.file, opts.handler_kind)) {
      throw new ValidationError("unsupported_mime");
    }

    // Init progress
    useUploadProgressStore.getState().start(upload_id_pending, opts.file.name, opts.file.size);

    return new Promise<Upload>((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      const formData = new FormData();
      formData.append("file", opts.file);
      formData.append("kind", opts.handler_kind);
      formData.append("studio_material_kind", opts.studio_material_kind);
      if (opts.display_name) formData.append("display_name", opts.display_name);

      xhr.upload.onprogress = (e) => {
        if (e.lengthComputable) {
          useUploadProgressStore.getState().update(upload_id_pending, e.loaded);
        }
      };
      xhr.onload = () => {
        if (xhr.status === 200 || xhr.status === 201) {
          const upload: Upload = JSON.parse(xhr.responseText);
          useUploadProgressStore.getState().complete(upload_id_pending);
          resolve(upload);
        } else {
          const err = parseErrorEnvelope(xhr.responseText);
          useUploadProgressStore.getState().fail(upload_id_pending, err.message);
          reject(err);
        }
      };
      xhr.onerror = () => {
        const msg = "Network error";
        useUploadProgressStore.getState().fail(upload_id_pending, msg);
        reject(new Error(msg));
      };
      xhr.open("POST", "/api/uploads");
      xhr.send(formData);
    });
  }, []);

  const inFlightCount = useUploadProgressStore(s => s.inFlight.size);

  return { upload, inFlightCount };
}
```

### 6.2 `useUploadsList`

```typescript
export interface UseUploadsListReturn {
  uploads:      Upload[];
  used_bytes:   number;
  quota_bytes:  number;
  isLoading:    boolean;
  error:        string | null;
  refresh:      () => Promise<void>;
  deleteUpload: (upload_id: string) => Promise<void>;
}

export function useUploadsList(opts?: { kind_filter?: string }): UseUploadsListReturn;
```

**Behavior.** Uses `useUploadsListStore` Zustand store. On mount + on `useActiveVertical()` change: GET `/api/uploads` via `fetch()` with AbortController; cleanup on unmount. Cached in store for 30s; manual `refresh()` bypasses cache. `deleteUpload()` calls DELETE then optimistically removes from local state; on failure, refetches.

### 6.3 `useUploadPreview`

```typescript
export interface UseUploadPreviewReturn {
  content:       string | Blob | null;     // string for text; Blob for binary
  mime_type:     string | null;
  truncated:     boolean;                   // true when excerpt=true returned partial
  isLoading:     boolean;
  error:         string | null;
}

export function useUploadPreview(upload_id: string): UseUploadPreviewReturn;
```

**Behavior.** On mount + on `upload_id` change: GET `/api/uploads/:id/preview?excerpt=true`. Auto-detect from response Content-Type whether to populate `content` as string vs Blob. For PDF / image: keep null and let the renderer use the URL directly via `<iframe>` / `<img>`. AbortController cleanup on unmount or `upload_id` change.

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
  handler_component:    React.ComponentType<any>;     // React component for vertical-specific UI; null for platform
}

export interface UseUploadHandlersReturn {
  handlers: UploadHandler[];                          // platform built-ins + active vertical's handlers
}

export function useUploadHandlers(): UseUploadHandlersReturn;
```

**Behavior.** Reads platform built-ins from `handlers/{briefHandler,dataHandler}.ts`; reads vertical handlers from `useActiveVertical().active?.upload_handlers` (the manifest field per `02` §3.1); merges via `useMemo([active])`; returns combined list ordered: vertical handlers first, then platform built-ins.

---

## §7 Integration with wizard

The wizard's "attach materials" step (per `10-feature-wizard-spec.md`) consumes uploads as follows:

```typescript
// inside wizard's materials step
import { useUpload, useUploadHandlers } from "@entelecheia/uploads";

function MaterialsStep() {
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
  // ...
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
                 ? await content.text()                       // string for brief
                 : parseDataContent(content),                  // dict for data (JSON parse if applicable)
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

```tsx
// in AgoraView
const [previewingUploadId, setPreviewingUploadId] = useState<string | null>(null);

<MaterialsPanel
  meeting_id={meeting_id}
  onMaterialPreviewClicked={async (material_name) => {
    // Resolve material_name → upload_id via meeting_metadata table
    const id = await resolveMaterialName(meeting_id, material_name);
    setPreviewingUploadId(id);
  }}
/>
{previewingUploadId && (
  <UploadPreviewOverlay
    upload_id={previewingUploadId}
    open={true}
    onClose={() => setPreviewingUploadId(null)}
  />
)}
```

The `meeting_metadata.materials` JSON field stores `MaterialDescriptor` with an extra `upload_id` field (apps/api's internal extension; not exposed in the descriptor returned to clients except as `preview_url`). Spec 15 finalizes this.

---

## §9 Sealed error taxonomy (uploads-owned) — UNCHANGED

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

## §10 Configuration — UNCHANGED

```python
# apps/api/uploads/config.py
class UploadsSettings(BaseSettings):
    base_dir:                  str = "./.product_data/uploads"
    storage_backend:           Literal["filesystem", "s3"] = "filesystem"
    max_file_bytes:            int = 10 * 1024 * 1024
    user_quota_bytes:          int = 1024 * 1024 * 1024
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
  "feature.uploads.quota_indicator": "{{used}} of {{quota}} used",

  "feature.uploads.dropzone.idle":           "Drag files here or click to select",
  "feature.uploads.dropzone.hover":          "Drop to upload",
  "feature.uploads.dropzone.disabled":       "Quota nearly full; delete files before uploading more.",
  "feature.uploads.dropzone.toast.too_large":"File too large for this handler ({{max}}).",

  "feature.uploads.handler_picker.title":    "What kind of file?",
  "feature.uploads.handler_picker.cancel":   "Cancel",
  "feature.uploads.handler_picker.confirm":  "Upload {{count}} file(s) as {{kind}}",
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
  "feature.uploads.list.delete_confirm":     "Delete {{name}}? This cannot be undone.",

  "feature.uploads.progress.uploading":      "Uploading {{name}}…",
  "feature.uploads.progress.complete":       "{{name}} uploaded",

  "feature.uploads.preview.close":           "Close",
  "feature.uploads.preview.download":        "Download",
  "feature.uploads.preview.unavailable":     "Preview not available for this file type.",
  "feature.uploads.preview.truncated":       "Showing first {{chars}} characters; download to see full file.",

  "feature.uploads.error.file_too_large":    "File is {{actual}}; maximum is {{max}}.",
  "feature.uploads.error.unsupported_mime":  "File type {{mime}} is not supported by this handler.",
  "feature.uploads.error.invalid_handler":   "That upload kind is not available.",
  "feature.uploads.error.storage_full":      "You've used {{used}} of {{quota}}. Delete files before uploading more.",
  "feature.uploads.error.upload_not_found":  "File not found.",
  "feature.uploads.error.internal_storage":  "Could not save your file. Try again."
}
```

i18next `{{var}}` interpolation. `zh.json` mirrors with Chinese.

---

## §12 Test matrix

### 12.1 API endpoints — UNCHANGED

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
| dropzone drop fires onFilesDropped | 3 files dropped → callback with array (after handler picked) | `t_dz_drop_callback` |
| dropzone drag visual | onDragOver sets isDragging=true; onDragLeave resets | `t_dz_drag_visual` |
| dropzone rejects too-large pre-flight | local validation; toast | `t_dz_pre_validate` |
| dropzone click triggers file input | clicking zone calls inputRef.current.click() | `t_dz_click_input` |
| handler picker default selection | platform brief | `t_hp_default` |
| handler picker vertical first | vertical handler appears above platform | `t_hp_vertical_above` |
| upload progress updates | xhr.upload.onprogress fires; useUploadProgressStore updated; ProgressBar fills | `t_up_progress` |
| upload error shows in row | API returns 413 | row shows error icon + message | `t_up_error_inline` |
| preview pdf renders iframe | mime=pdf | iframe with src=/preview | `t_pp_pdf_iframe` |
| preview image renders img | mime=image/png | img tag with object-contain | `t_pp_image` |
| preview text renders pre | mime=text/plain | pre/code element with content | `t_pp_text` |
| preview text truncated banner | truncated=true | banner + download link | `t_pp_text_truncated` |
| preview generic fallback | mime=docx | GenericPreview with download button | `t_pp_generic` |
| list empty state | 0 uploads | empty state visible | `t_ul_empty` |
| list quota indicator | used + quota in header | accurate display | `t_ul_quota_display` |
| delete confirm | confirm modal then API call | row removed | `t_ul_delete_confirm` |
| route /uploads/:id pre-selects | direct nav | preview overlay open | `t_uv_deep_link` |
| dialog ESC closes | open + ESC | calls onClose; native dialog onCancel | `t_overlay_esc` |
| focus trap on dialog open | first focusable receives focus; tab cycles | `t_overlay_focus_trap` |

### 12.3 Hooks

| scenario | expected | test_id |
|---|---|---|
| useUpload XHR progress | upload.onprogress events propagate to store | `t_uu_xhr_progress` |
| useUpload local size validation | rejects locally; no XHR sent | `t_uu_local_validate` |
| useUpload local mime validation | rejects locally; no XHR sent | `t_uu_local_mime` |
| useUploadsList AbortController cleanup | unmount mid-fetch; no setState warning | `t_ul_abort_unmount` |
| useUploadHandlers merges | platform + vertical | `t_uh_merge` |
| useUploadHandlers vertical change | re-merges via useMemo deps | `t_uh_vertical_change` |
| useUploadPreview text fetch | excerpt mode | string content + truncated | `t_upv_text` |
| useUploadPreview upload_id change | new fetch; old aborted | `t_upv_id_change_abort` |

---

## §13 Why this design — load-bearing decisions

**Why product-side storage (not studio).**
Studio takes materials inline at `run_meeting` time (per `01-studio-client-spec.md` §4.6) — there's no storage round trip. Product needs persistence so users can preview later (agora MaterialsPanel) and re-attach (re-running similar meetings without re-uploading). Studio explicitly does not store inputs.
*Considered and rejected.* **Push to studio for storage** — studio doesn't have an upload endpoint.

**Why disk in v0.1, not object storage.**
Operational simplicity for an internal v0.1 product. The `StorageBackend` Protocol lets v0.2 swap to S3 / MinIO without API changes. Local disk works for sub-1-GB-per-user volumes; the disk fills before the user feels it — enforced via the 1 GB quota.
*Considered and rejected.* **S3 from day 1** — needs cloud creds + buckets + IAM; over-engineering for internal use.

**Why content-addressed dedup (sha256), per-user only.**
Same file uploaded twice by same user → same upload_id → no disk waste, wizard re-attach is seamless. Cross-user dedup would save more disk but leak: user A could discover that user B uploaded the same file by getting back an existing upload_id (timing oracle). Per-user-only sidesteps that.
*Considered and rejected.* **Cross-user dedup** — privacy leak. **No dedup** — disk waste for users who re-upload the same brief.

**Why MIME detection from content, not filename.**
Filename extensions can be spoofed. `python-magic` reads the first ~512 bytes for MIME determination — security-sound + standard. Test `t_api_upload_mime_spoofing` enforces.
*Considered and rejected.* **Trust the filename extension** — trivially bypassed.

**Why no extension on disk filename.**
Disk filename is opaque (the upload_id ULID). Display name + MIME live in DB. Avoids any extension-based attack surface (e.g., webserver mistakenly serving as .html instead of as binary).
*Considered and rejected.* **`<upload_id>.<extension>` on disk** — small attack surface for no benefit.

**Why per-user dir (not flat dir with all uploads).**
Filesystem-level user isolation; trivial chmod 700 per dir; one-line `rm -rf` per-user purge if a user is deactivated and admin wants to reclaim space. Flat dir would conflate users.
*Considered and rejected.* **Flat `<upload_id>` paths** — harder to reason about isolation.

**Why 10 MB per-file + 1 GB per-user defaults.**
10 MB fits a complex PDF, several spreadsheets, dozens of images — covers typical "brief" sizes. 1 GB per user lets users accumulate ~100 of those — generous for an internal product. Quotas tunable via env. Beyond these, deferred to v0.2 with chunked uploads.
*Considered and rejected.* **No quotas** — runaway disk; bad operations. **Lower limits** — too restrictive for normal use.

**Why dedup returns 200 not 201 on hit.**
HTTP semantic: 201 means "created". A dedup hit creates nothing. 200 + identical body is honest. Frontend treats both equivalently — the response shape is a `Upload` either way.
*Considered and rejected.* **Always 201** — semantically wrong.

**Why vertical handlers extend the platform allowlist (not replace).**
A vertical needs to allow `.tsv` (say); platform's brief handler doesn't include it. The vertical's handler-specific `accepts` extends what's allowed when uploading via that handler. The platform default still applies for `brief` / `data` (no handler picked). This way verticals can't shrink platform's surface (only grow per-handler).
*Considered and rejected.* **Verticals replace allowlist** — gives verticals power to forbid things they shouldn't. **Single global allowlist** — verticals can't add formats the platform doesn't anticipate.

**Why no virus scanning v0.1.**
Internal trusted-tenant; user uploads files for their own meetings. v0.2 ClamAV integration is straightforward (the `StorageBackend.write` step gets a pre-write hook). Documented as deferral.
*Considered and rejected.* **ClamAV in v0.1** — requires separate process, signature DB updates, operational overhead.

**Why `useUpload` uses XHR (not fetch) — React-specific.**
XHR is the only browser API that exposes upload progress events directly via `xhr.upload.onprogress`. Modern fetch can do this only with `Request` body as a `ReadableStream`, requiring `TransformStream` plumbing not yet broadly supported. For uploads (where progress is genuinely useful), XHR is the right call. Spec 06 (reports) uses fetch for downloads since render is server-controlled and progress doesn't matter; spec 08 (chathub) uses fetch + AbortController for client-timeout. Three feature specs, three different fetch / XHR / AbortController patterns — each justified by the use case.
*Considered and rejected.* **fetch + ReadableStream** — browser support gaps; complexity not worth it in v0.1. **No progress at all** — uploads can be 10MB; users need feedback.

**Why upload progress lives in a Zustand store (not component-local useState).**
`<UploadDropZone>` initiates the upload but `<UploadProgressIndicator>` may render elsewhere in the layout (e.g., wizard's materials step shows progress at the bottom, dropzone at the top). A shared store decouples emitter and renderer.
*Considered and rejected.* **Component-local state** — would require prop drilling or context.

**Why `<UploadPreviewOverlay>` reuses native `<dialog>` + focus-trap-react (vs. Radix UI / Headless UI).**
Same rationale as `05-feature-agora-spec.md` §10's `<ProvenanceModal>` decision and `08-feature-chathub-spec.md` §12's `<NewChatModal>` decision. Three modals across three features all use the same pattern — consistent UX + zero new bundle (focus-trap-react is a shared dep).
*Considered and rejected.* **Radix UI Dialog** — larger bundle. **Per-feature modal libraries** — UX inconsistency.

**Why DELETE is hard (not soft) — same as chathub.**
Users own their uploads. Hard delete + storage cleanup keeps things simple. v0.2 may add "in use by N meetings" warning before delete. Storage cleanup is on the same DB transaction (file delete + row delete), but file delete failure is logged and proceeds anyway (orphan files cleaned by future GC script).
*Considered and rejected.* **Soft delete** — disk doesn't shrink; no audit need at v0.1.

---

## §14 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | `useActiveVertical().active.upload_handlers` consumed by `useUploadHandlers()` — already in 02 §3.1 manifest interface; no change. |
| `03-auth-service-spec.md` | 3 new permissions (`platform:upload`, `platform:upload_list`, `platform:upload_delete`) registered at boot. |
| `05-feature-agora-spec.md` | `<MaterialsPanel>` `onMaterialPreviewClicked` opens `<UploadPreviewOverlay>` (§8). The `meeting_metadata.materials` records `upload_id` alongside the descriptor (apps/api internal — surfaced as `preview_url` to clients). Already in 05 §7. |
| `10-feature-wizard-spec.md` | Wizard's "attach materials" step uses `useUpload` per §7 contract; collects `upload_id`s; on run_meeting reads bytes and passes inline to studio. |
| `13-vertical-template-spec.md` | Vertical template's `frontend/handlers/` folder MAY contain vertical-specific upload handler components matching the `UploadHandlerContribution` interface (component type now `React.ComponentType` per `02` §3.1). |
| `15-apps-api-spec.md` | Mounts `/api/uploads/*` router; provisions `UPLOADS_BASE_DIR`; runs Alembic migrations for `uploads.db`; wires `meeting_metadata.materials` to also store `upload_id` references for the agora preview path. |
| `16-apps-frontend-spec.md` | `focus-trap-react` already declared as dep for 05/08; reused — no new dep. |
| `17-substitution-tests-spec.md` | No `[SUB]` tests here (uploads is product-side; no studio interaction). API tests run against the FilesystemStorage backend; v0.2 adds S3Storage backend with the same suite. |

---

## §15 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (object storage, chunked uploads, virus scan, encryption, folders, sharing, versioning, bulk folder upload)
- [ ] Module layout (§1) covers frontend (.tsx) + backend (Python; UNCHANGED)
- [ ] 3 permissions declared (§1.3); registered at boot
- [ ] 2 routes (§1.4) covering list + detail using React Router v6 RouteObject + lazy() + makePermissionsLoader
- [ ] SQLite schema (§2.1) has 1 table with content-address index; storage strategy explicit (§3) UNCHANGED
- [ ] Pydantic models (§2.2) UNCHANGED
- [ ] All 6 API endpoints (§4) UNCHANGED
- [ ] Per-MIME preview response table (§4.5) covers PDF / image / text / unsupported
- [ ] All 9 frontend components (§5) with full TS Props interface + onXxx callback props + render rules; UploadPreviewOverlay reuses 05/08's <dialog> + focus-trap-react pattern
- [ ] All 4 hooks (§6) with signatures + behavior; useUpload uses XHR for progress events; useUploadProgressStore Zustand store decouples emitter and renderer
- [ ] Wizard integration contract (§7) shows full flow: upload → buffer → run_meeting inline → metadata persist
- [ ] Agora MaterialsPanel preview integration (§8) documented; meeting_metadata.materials includes upload_id
- [ ] Sealed error taxonomy (§9): 6 leaves with extras (UNCHANGED)
- [ ] Configuration (§10): every env var with default (UNCHANGED)
- [ ] i18n keys (§11) for every user-visible string with `{{var}}` interpolation
- [ ] Test matrix (§12): API (~19 UNCHANGED), components (~19 with new dialog/focus-trap rows), hooks (~8 with new abort-cleanup); ≥ 35 rows total
- [ ] Why-this / why-not (§13) for ≥ 8 load-bearing decisions including React-specific ones (XHR vs fetch for upload progress; Zustand for cross-component progress; native dialog + focus-trap reuse)
- [ ] Downstream impact (§14) lists every spec affected; notes shared dep (focus-trap-react) with 05/08
- [ ] No business / domain / product / agent-role string literals
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No `try: ... except Exception: pass` patterns
- [ ] MIME detection is content-based (not filename-based)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/09-feature-uploads-spec.md`
