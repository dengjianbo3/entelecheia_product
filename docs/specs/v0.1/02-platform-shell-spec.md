# 02 — `platform-shell` v0.1 spec

> **Status**: v0.1 contract for the platform's shell layer — the always-present scaffolding around features and verticals.
> **Lives at**: `packages/platform-shell/`.
> **Upstream contracts**: `01-studio-client-spec.md` (StudioClient + DTOs), `01b-product-derivations-spec.md` (`useMeetingStreamStore` lives here per §10).
> **Consumed by**: every feature in Batch C (`05`–`12`), every vertical in Batch D, the frontend app shell in `16-apps-frontend-spec.md`.

---

## Mission

This file defines the platform shell — the always-present application scaffolding (layout, router, theming, i18n, multi-vertical switcher, public composables, vertical extension surface) that every product user sees regardless of which vertical pack is active. The shell is the host; features plug in as panels, verticals plug in via manifest. Removing any vertical or feature does not affect the shell; the shell does not know what specific verticals or features exist.

**Hard rule** (P4 + P10): the shell's public surface — composables, layout slots, vertical extension API — is **stable + additive only** within v0.x. Adding a new composable / slot is fine; removing or changing the signature of an existing one breaks every feature and every vertical at once.

---

## Scope

**Covers.**
- Module layout (`packages/platform-shell/src/...`).
- Top-level Vue layout components (`<PlatformShell>`, `<Header>`, `<SideNav>`, `<MainOutlet>`, `<ToastContainer>`).
- Vue Router configuration: route taxonomy (auth / platform / vertical-prefixed / catch-all), guards (auth-required, permission-required, vertical-active).
- Public composables (the contract every feature + every vertical depends on): `useUser`, `useStudio`, `useStudioHealth`, `useActiveVertical`, `useNotifications`, `useToast`, `useMeetingStreamStore`, `usePermission`, `useFeatureFlag`, `useTheme`, `useI18n`, `useRouter` (re-exported).
- Vertical extension API: `VerticalManifest` TypeScript interface + `registerVertical(manifest)` registration function + boot-time discovery flow.
- Theming (light / dark / system + per-vertical accent), persisted via user-service.
- i18n (vue-i18n; `zh` + `en` for v0.1; locale persisted; vertical bundles merged on registration).
- Notification model (transient toasts vs persistent notifications; sources, dedup, retention).
- Permission model (string-typed grants from auth-service; reactive checks).
- Multi-vertical switcher (UI element + state management; switching semantics).
- Boot sequence (the order in which shell, features, verticals come up).
- Test matrix per composable + per layout slot + per route guard.

**Does not cover.**
- The `StudioClient` Protocol or its DTOs — `01-studio-client-spec.md`.
- The 4 agora-specific reducers (`useOutcomeReducer`, `useDagState`, `useCostState`, `useProvenance`) — `01b-product-derivations-spec.md` (they live in agora, not shell).
- Login UI flow (form, validation, session creation) — `03-auth-service-spec.md` provides the backend; the shell only guards routes via `useUser()` and redirects to `/login` when needed.
- User preferences storage — `04-user-service-spec.md` provides the backend; the shell reads/writes via composables.
- Specific feature panels — `05`–`12`.
- Vertical-specific UI / data feeds — `13-vertical-template-spec.md` + `14-...`.
- Backend (FastAPI) — `15-apps-api-spec.md`. The shell only TALKS to product API endpoints; it does not host them.
- Frontend bootstrap (Vite config, entry HTML, font loading) — `16-apps-frontend-spec.md`.

**Out of scope for v0.1.**
- Plugin hot-reload (verticals discovered once at boot; reload requires page refresh).
- Multi-tenant org scoping (single-tenant for v0.x).
- Theme authoring UI (themes pinned at build time + per-vertical accent declared in manifest).
- Cross-tab notification sync (notifications are per-tab in v0.1).
- Offline mode (every shell action assumes the product API is reachable).

---

## §1 Module layout

```
packages/platform-shell/
├── src/
│   ├── index.ts                          # public exports (composables + types + registerVertical)
│   ├── components/
│   │   ├── PlatformShell.vue             # top-level layout
│   │   ├── Header.vue
│   │   ├── SideNav.vue
│   │   ├── MainOutlet.vue
│   │   ├── ToastContainer.vue
│   │   ├── VerticalSwitcher.vue
│   │   ├── UserMenu.vue
│   │   ├── NotificationBell.vue
│   │   ├── StudioHealthIndicator.vue
│   │   └── PermissionGate.vue            # <PermissionGate code="...">slot</PermissionGate>
│   ├── composables/
│   │   ├── useUser.ts
│   │   ├── useStudio.ts
│   │   ├── useStudioHealth.ts
│   │   ├── useActiveVertical.ts
│   │   ├── useNotifications.ts           # also exports useToast
│   │   ├── useMeetingStreamStore.ts      # the store from 01b §2
│   │   ├── usePermission.ts
│   │   ├── useFeatureFlag.ts
│   │   ├── useTheme.ts
│   │   └── useI18n.ts                    # thin wrapper over vue-i18n
│   ├── stores/                            # Pinia stores (private; consumed via composables)
│   │   ├── studio.ts                     # holds the StudioClient instance
│   │   ├── user.ts
│   │   ├── verticals.ts                  # registered manifests + active id
│   │   ├── notifications.ts
│   │   ├── theme.ts
│   │   └── feature-flags.ts
│   ├── router/
│   │   ├── index.ts                      # createRouter() + route table
│   │   └── guards.ts                     # auth-required / permission-required / vertical-active
│   ├── verticals/
│   │   ├── manifest.ts                   # VerticalManifest type + validation
│   │   └── registry.ts                   # registerVertical, listVerticals, getActiveVertical
│   ├── i18n/
│   │   ├── index.ts                      # createI18n() + base bundles
│   │   ├── zh.json
│   │   └── en.json
│   ├── theme/
│   │   ├── tokens.ts                     # design tokens (colors, spacing, radius)
│   │   └── apply.ts                      # apply theme to <html data-theme="...">
│   └── types/
│       ├── permission.ts                 # PermissionCode = string (branded)
│       └── notification.ts
├── tests/                                  # Vitest + Vue Testing Library
│   ├── composables/
│   ├── components/
│   └── router/
├── package.json
└── tsconfig.json
```

**No backend code.** Shell is pure frontend (Vue 3 + TS + Pinia). Backend equivalents (auth-service, user-service, apps/api) are separate packages.

---

## §2 Public composables

This is the **contract every feature + vertical depends on**. Adding a composable is a minor bump; removing or changing a signature is forbidden in v0.x (P4).

### 2.1 `useUser`

```typescript
import type { Ref, ComputedRef } from "vue";

export interface User {
  user_id:        string;            // opaque to product (passed through to studio as-is)
  display_name:   string;            // user-facing
  email:          string;
  permissions:    string[];          // permission codes; e.g. ["platform:list_projects", "vertical-a:open_meeting"]
  preferences:    UserPreferences;   // see 2.10
  authenticated_at: string;          // ISO-8601
}

export function useUser(): {
  user:               ComputedRef<User | null>;     // null when unauthenticated
  is_authenticated:   ComputedRef<boolean>;
  refresh():          Promise<void>;                // re-fetch from auth-service /me endpoint
  signOut():          Promise<void>;                // invalidate session, redirect to /login
};
```

**Source.** Backed by `useUserStore` (Pinia) which fetches from `GET /api/auth/me` on app mount and caches. Re-fetched on `refresh()` or when an `AuthRequired` error surfaces from any API call.

**Reactivity.** All consumers watching `user` re-render when sign-in / sign-out / preference-update happens.

### 2.2 `useStudio`

```typescript
import type { StudioClient } from "@entelecheia/studio-client";

export function useStudio(): StudioClient;
```

**Source.** `useStudioStore` holds the configured `StudioClient` instance; it is set once at app boot by `apps/frontend/main.ts` (per `16-apps-frontend-spec.md`). Shell does NOT decide which implementation (`PseudoStudioClient` vs `HttpStudioClient`) — that's `apps/frontend`'s job based on env config.

**Throws.** `Error("StudioClient not configured")` if called before `apps/frontend` has provided one. Surfaces as a developer error; never reaches end users in correctly-built deployments.

### 2.3 `useStudioHealth`

```typescript
import type { StudioHealth } from "@entelecheia/studio-client";

export function useStudioHealth(opts?: {
  poll_interval_ms?:   number;     // default 30_000 (30s)
  enabled?:            boolean;    // default true; false to suspend polling
}): {
  health:    ComputedRef<StudioHealth | null>;
  is_loading: ComputedRef<boolean>;
  error:      ComputedRef<string | null>;
  refresh():  Promise<void>;       // force one immediate fetch
};
```

**Behavior.** On mount: one immediate fetch (`StudioClient.get_studio_health()`); thereafter polls every `poll_interval_ms`. Errors set `error` but keep last-known `health` for UI continuity. On unmount: cancel polling.

**UI consumer.** `<StudioHealthIndicator>` renders a small dot in the header (green = both live and ready; amber = live not ready; red = unreachable).

### 2.4 `useActiveVertical`

```typescript
export function useActiveVertical(): {
  active:                ComputedRef<VerticalManifest | null>;  // null only during boot
  available:             ComputedRef<VerticalManifest[]>;       // verticals user has any permission for
  switchTo(id: string):  Promise<void>;                         // navigates to vertical's default tab
};
```

**Switching semantics.**
- Updates active vertical in `useVerticalsStore`.
- Persists choice to user-service preferences (`active_vertical`).
- Navigates router to `/{vertical_id}/{first_tab_id}` (or vertical's declared `default_route`).
- Does NOT tear down meeting subscriptions; `useMeetingStreamStore` instances are keyed by `meeting_id` (not `vertical_id`), so switching and switching back leaves them intact.
- Re-evaluates permission gates: tabs / widgets the user lacks permission for stay hidden.

**Single-vertical user.** When `available.length === 1`, the switcher UI is hidden (CSS); `active` is set to that vertical at boot.

**Zero verticals available.** Surfaces as a fatal-but-handled boot state: shell renders an empty-state page with a sign-out link.

### 2.5 `useNotifications` + `useToast`

```typescript
export type NotificationSeverity = "info" | "success" | "warning" | "error";
export type NotificationSource   = "studio" | "product" | "vertical";

export interface Notification {
  id:           string;                                    // uuid
  severity:     NotificationSeverity;
  source:       NotificationSource;
  title:        string;                                    // <= 80 chars; localizable key
  body:         string | null;                             // <= 400 chars; localizable key
  created_at:   string;                                    // ISO-8601
  read:         boolean;
  action:       { label: string; route: string } | null;  // optional CTA (e.g., "Go to meeting")
  dedupe_key:   string | null;                             // dedupe within a 5-min window
}

export function useNotifications(): {
  list:           ComputedRef<Notification[]>;             // ordered by created_at desc; last 50 retained
  unread_count:   ComputedRef<number>;
  push(n: Omit<Notification, "id" | "created_at" | "read">): void;
  markRead(id: string):   void;
  markAllRead():          void;
  dismiss(id: string):    void;
};

export function useToast(): {
  show(opts: {
    severity:    NotificationSeverity;
    title:       string;
    body?:       string;
    duration_ms?: number;          // default 5000; 0 = sticky until manual dismiss
  }): void;
};
```

**Toast vs Notification.**
- **Toast**: ephemeral; renders in `<ToastContainer>`; auto-dismisses; NOT added to the bell list.
- **Notification**: persisted in `useNotificationsStore`; shows in `<NotificationBell>`; manually dismissible.

A common pattern: features call BOTH `useToast().show(...)` (immediate UX) and `useNotifications().push(...)` (history) for important events.

**Dedup.** When pushed with `dedupe_key`, suppresses if an unread notification with the same key was pushed in the last 5 minutes.

**Retention.** Bell list keeps last 50; older drop on push (oldest-first eviction).

### 2.6 `useMeetingStreamStore`

Defined in `01b-product-derivations-spec.md` §2. Lives at `packages/platform-shell/src/composables/useMeetingStreamStore.ts`. Re-exported from `packages/platform-shell/src/index.ts`.

Signature recap (full contract in 01b):

```typescript
export function useMeetingStreamStore(meeting_id: string): {
  state:        Ref<MeetingStreamState>;
  subscribe():  Promise<void>;
  unsubscribe(): Promise<void>;
  reconnect():  Promise<void>;
  reset():      void;
  forceFullReload(): Promise<void>;
};
```

### 2.7 `usePermission`

```typescript
export function usePermission(code: string): ComputedRef<boolean>;

export function usePermissions(codes: string[], mode: "any" | "all" = "all"): ComputedRef<boolean>;
```

**Source.** `useUser().user.value.permissions` array.
**Reactivity.** Re-evaluates when `user.permissions` changes (e.g., admin grants new permission, user re-authenticates).
**Naming convention.** Permissions are `<scope>:<verb>` strings: `platform:list_projects`, `platform:run_meeting`, `<vertical_id>:open_meeting`, `<vertical_id>:upload_data_kind_X`. Vertical-scoped permissions use the vertical's id as scope.

### 2.8 `useFeatureFlag`

```typescript
export function useFeatureFlag(flag: string, default_value: boolean = false): ComputedRef<boolean>;
```

**Source.** `useFeatureFlagsStore` is populated at boot from `GET /api/platform/feature-flags` (apps/api endpoint, see `15-apps-api-spec.md`).
**v0.1 use case.** Roll out an in-progress feature behind `experimental:knowledge_v2_layout` (etc.). Avoid using flags for vertical-specific routing — that's what verticals are for (P10).

### 2.9 `useTheme`

```typescript
export type ThemeMode = "light" | "dark" | "system";

export function useTheme(): {
  mode:        Ref<ThemeMode>;          // resolved theme; "system" follows OS prefers-color-scheme
  setMode(m: ThemeMode):  void;         // persists to user prefs
  accent:      ComputedRef<string>;     // hex color from active vertical's accent_color or platform default
};
```

**Persistence.** Theme mode is stored in user-service preferences. On mount, restore.

**Accent color.** Derived from `useActiveVertical().active.value?.accent_color ?? "#3B82F6"` (platform default). Verticals MAY declare `accent_color` in their manifest (per §3); shell applies it as a CSS variable consumed by Tailwind tokens.

### 2.10 `useI18n`

```typescript
export type Locale = "zh" | "en";   // v0.1 fixed; new locales added via vue-i18n

export function useI18n(): {
  t(key: string, args?: Record<string, string | number>): string;
  locale:    Ref<Locale>;
  setLocale(l: Locale):  void;       // persists to user prefs; refreshes route titles + meta
};
```

Thin wrapper over vue-i18n's `useI18n`. Provides typed `t()` against the merged translation bundles (platform + active vertical + currently-loaded feature). Missing-key fallback logs a warning and returns the key string in dev; returns the English value in production.

**Per-vertical i18n bundles** are merged into the global vue-i18n instance at `registerVertical` time (per §3.3).

### 2.11 `UserPreferences` (returned by `useUser`)

```typescript
export interface UserPreferences {
  theme_mode:        ThemeMode;             // "light" | "dark" | "system"
  locale:            Locale;                // "zh" | "en"
  active_vertical:   string | null;         // vertical_id; null at first run
  notifications:     {
    enabled:         boolean;
    severities:      NotificationSeverity[];   // which to show (others dropped silently)
  };
}
```

**Storage.** All persisted to user-service via `PUT /api/user/preferences` (per `04-user-service-spec.md`). Shell debounces writes (500 ms) so rapid toggles don't spam the server.

---

## §3 Vertical extension API

This is the **only** way verticals plug into the shell (P5). The shell exposes one TypeScript interface (`VerticalManifest`) and one registration function (`registerVertical`); verticals call `registerVertical(myManifest)` exactly once at module load time.

### 3.1 `VerticalManifest`

```typescript
import type { Component } from "vue";
import type { ProjectId } from "@entelecheia/studio-client";

export interface VerticalManifest {
  // identity
  vertical_id:    string;                       // matches backend manifest's vertical_id; lowercase snake; e.g. "vertical-a"
  display_name:   string;                       // user-facing; shown in switcher; localizable via i18n
  description:    string;                       // <= 200 chars; one-liner
  icon:           string;                       // lucide-vue-next icon name; rendered in switcher

  // appearance (optional)
  accent_color:   string | null;                // hex like "#FF8800"; default null = platform default

  // contributions
  tabs:                  TabContribution[];
  dashboard_widgets:     WidgetContribution[];
  upload_handlers:       UploadHandlerContribution[];
  data_feeds:            DataFeedContribution[];

  // project filtering (per 01-studio-client §11.4)
  default_project_filter: { project_id_in: ProjectId[] };

  // i18n bundles (merged into global vue-i18n on registration)
  i18n:           { zh: Record<string, string>; en: Record<string, string> };

  // optional: where switching to this vertical lands by default
  default_route:  string | null;                // e.g. "/<vertical_id>/<first_tab_id>"; null = first tab in tabs[]
}

export interface TabContribution {
  id:                    string;                // unique within vertical; lowercase snake; e.g. "data-explorer"
  label_key:             string;                // i18n key; resolved at render via useI18n().t()
  route_path:            string;                // mounted under /<vertical_id>/<route_path>; must start with /
  component:             Component;             // Vue component (lazy-load supported via () => import(...))
  required_permission:   string | null;         // gate; null = no gate beyond being in the vertical
  position:              number;                // ordering hint; lower = earlier in side nav
}

export interface WidgetContribution {
  id:                    string;
  component:             Component;
  preferred_position:    "top-left" | "top-right" | "bottom-left" | "bottom-right";
  title_key:             string;                // i18n key
  required_permission:   string | null;
}

export interface UploadHandlerContribution {
  kind:                  string;                // user-facing kind label; e.g. "csv-table"; not a studio Material kind
  label_key:             string;                // i18n key for picker label
  accepts:               string[];              // file extensions or MIME types; e.g. [".csv", ".xlsx"]
  max_size_bytes:        number;                // default 10_000_000 (10 MB)
  handler_component:     Component;             // renders the per-file UI (preview, parse confirmation)
  studio_material_kind:  "brief" | "data";      // how it gets passed to studio at run_meeting (per 01 §4.6)
}

export interface DataFeedContribution {
  id:                    string;
  api_path:              string;                // e.g. "/api/verticals/<vertical_id>/data/<feed_id>"
  description:           string;
}
```

### 3.2 `registerVertical`

```typescript
export function registerVertical(manifest: VerticalManifest): void;
```

**Behavior.**
1. Validates the manifest against the schema (throws `VerticalRegistrationError` on validation failure with the offending field).
2. Validates `vertical_id` uniqueness; throws if a vertical with that id is already registered.
3. Merges `manifest.i18n.zh` and `manifest.i18n.en` into the global vue-i18n instance under namespace `vertical.<vertical_id>.<key>`.
4. Adds tabs to Vue Router (mounted under `/{vertical_id}/...`).
5. Adds widgets to the dashboard layout registry.
6. Adds upload handlers to the uploads-feature registry.
7. Adds data-feed metadata (the actual proxy lives in the vertical's backend per `13-vertical-template-spec.md`).
8. Stores the full manifest in `useVerticalsStore` for retrieval via `useActiveVertical().available`.

**Errors.**

```typescript
export class VerticalRegistrationError extends Error {
  field:   string;
  reason:  "missing" | "invalid_format" | "duplicate_id" | "duplicate_tab_id" | "invalid_route_path";
}
```

### 3.3 Boot-time discovery flow

The shell does NOT scan the filesystem for verticals. It loads them via the apps/frontend boot path (per `16-apps-frontend-spec.md`):

```
apps/frontend/main.ts startup:
  1. Fetch GET /api/platform/verticals → { available: [{vertical_id, frontend_module_path}, ...] }
  2. For each available vertical:
       a. Dynamic import: const mod = await import(frontend_module_path)
       b. mod.default is a VerticalManifest (per convention)
       c. registerVertical(mod.default)
  3. Resolve active vertical:
       a. Read useUser().user.value.preferences.active_vertical
       b. If null OR not in registered set: pick first vertical user has permission for
       c. Set as active via useVerticalsStore.setActive(id)
  4. Mount <PlatformShell /> + Router
```

Failures during step 2 (one vertical fails to load) are logged + reported to the user via a toast ("Vertical 'X' failed to load: <reason>"); the shell continues with the remaining verticals (P5 isolation: a broken vertical does not bring down the shell).

---

## §4 Routing

```
Route table (declared in packages/platform-shell/src/router/index.ts)

/                                     → redirect to /platform/dashboard (or /login if unauthenticated)
/login                                → <LoginPage />          (provided by auth-service spec 03; shell only mounts it)
/platform/dashboard                   → <Dashboard />          (renders active vertical's widgets)
/platform/agora/:meeting_id?          → <AgoraView />          (from feature spec 05)
/platform/reports                     → <ReportsView />        (from feature spec 06)
/platform/reports/:report_id          → <ReportDetail />
/platform/knowledge                   → <KnowledgeView />      (from feature spec 07)
/platform/chathub                     → <ChathubView />        (from feature spec 08)
/platform/chathub/:chat_id            → <ChathubSession />
/platform/uploads                     → <UploadsView />        (from feature spec 09)
/platform/wizard/:project_id          → <WizardView />         (from feature spec 10)
/platform/settings                    → <SettingsView />       (from feature spec 11)
/platform/observability               → <ObservabilityView />  (from feature spec 12)

/{vertical_id}/{tab_route_path}       → resolved at registration via TabContribution
                                        e.g. /vertical-a/data-explorer

/:catch_all(.*)                       → <NotFound />
```

### 4.1 Route guards

```typescript
// packages/platform-shell/src/router/guards.ts

router.beforeEach(async (to, from, next) => {
  // 1. Auth guard
  if (to.meta.requires_auth !== false && !useUser().is_authenticated.value) {
    return next({ path: "/login", query: { redirect: to.fullPath } });
  }

  // 2. Permission guard
  const required: string[] = to.meta.required_permissions ?? [];
  if (required.length > 0 && !usePermissions(required, "all").value) {
    useToast().show({ severity: "error", title: "permission.denied" });
    return next({ path: "/platform/dashboard" });
  }

  // 3. Vertical-active guard (for /{vertical_id}/... routes)
  if (to.params.vertical_id) {
    const vid = to.params.vertical_id as string;
    const vertical = useVerticalsStore().byId(vid);
    if (!vertical) return next({ name: "not-found" });
    // auto-switch active vertical if user navigated to a different vertical's URL
    if (useActiveVertical().active.value?.vertical_id !== vid) {
      await useActiveVertical().switchTo(vid);
    }
  }

  next();
});
```

**Default meta on routes.**
- `/login`: `{ requires_auth: false }`
- `/platform/agora/:meeting_id?`: `{ required_permissions: ["platform:run_meeting"] }`
- `/platform/observability`: `{ required_permissions: ["platform:view_observability"] }`
- (Other defaults declared in each feature's spec.)

### 4.2 Route → vertical mapping

Vertical tabs mount at `/{vertical_id}/{tab_route_path}` exactly. The shell handles the URL parsing; verticals only declare relative `route_path` in their manifest. This means switching verticals via the switcher updates the URL prefix; bookmarks always include the vertical id.

---

## §5 Theming

### 5.1 Tokens

Tailwind config (`packages/platform-shell/tailwind.preset.cjs`, consumed by `apps/frontend`) defines:

```javascript
{
  colors: {
    bg: "var(--color-bg)",
    surface: "var(--color-surface)",
    text: "var(--color-text)",
    text_muted: "var(--color-text-muted)",
    accent: "var(--color-accent)",
    accent_text: "var(--color-accent-text)",
    border: "var(--color-border)",
    error: "var(--color-error)",
    warning: "var(--color-warning)",
    success: "var(--color-success)",
  },
  fontFamily: {
    sans: ["Plus Jakarta Sans", "system-ui", "sans-serif"],
    serif: ["Crimson Pro", "Georgia", "serif"],
    mono: ["ui-monospace", "monospace"],
  },
  borderRadius: { ... }, spacing: { ... }, ...
}
```

### 5.2 Theme apply

`useTheme().setMode(mode)` calls `applyTheme(mode, accent)`:

```typescript
function applyTheme(mode: "light" | "dark" | "system", accent: string): void {
  const resolved = mode === "system"
    ? (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light")
    : mode;
  document.documentElement.dataset.theme = resolved;       // <html data-theme="dark">
  document.documentElement.style.setProperty("--color-accent", accent);
  document.documentElement.style.setProperty("--color-accent-text", contrastingText(accent));
}
```

CSS variables are declared per `data-theme="..."` selector in `packages/platform-shell/src/theme/tokens.css`.

### 5.3 Per-vertical accent

When `useActiveVertical().active.value?.accent_color` changes, `useTheme()` re-applies. UI updates immediately via CSS variable propagation; no component re-render needed.

### 5.4 Material Symbols

Icons rendered via Material Symbols font (loaded once in `apps/frontend`, see spec 16) plus Lucide for vertical icons.

---

## §6 i18n

### 6.1 Engine

`vue-i18n` (Composition API mode). Created once in `packages/platform-shell/src/i18n/index.ts`:

```typescript
import { createI18n } from "vue-i18n";
import zh from "./zh.json";
import en from "./en.json";

export const i18n = createI18n({
  legacy: false,
  locale: "en",                // overridden at boot from user prefs
  fallbackLocale: "en",
  messages: { zh, en },
  missingWarn: import.meta.env.DEV,
  fallbackWarn: import.meta.env.DEV,
});
```

### 6.2 Bundle structure

```
packages/platform-shell/src/i18n/
├── zh.json          # platform-level keys (layout, errors, common UI)
└── en.json
```

Top-level namespaces in JSON: `layout.*`, `nav.*`, `common.*`, `error.*`, `permission.*`, `theme.*`.

### 6.3 Vertical bundles merged at registration

`registerVertical(manifest)` merges `manifest.i18n.zh` under namespace `vertical.<vertical_id>.<key>`:

```typescript
// In manifest:
i18n: {
  zh: { "tab.data_explorer": "数据浏览" },
  en: { "tab.data_explorer": "Data Explorer" },
}

// After registration, accessible as:
useI18n().t(`vertical.${verticalId}.tab.data_explorer`)
```

Key collisions across verticals are isolated by namespace; no collision is possible.

### 6.4 Feature i18n

Each platform feature ships its own bundle and registers it via a feature-internal API (defined in each feature spec); the registration mechanism is the same merge into vue-i18n with namespace `feature.<feature_name>.<key>`.

---

## §7 Notifications

### 7.1 Notification store

Pinia store at `packages/platform-shell/src/stores/notifications.ts`:

```typescript
interface NotificationsState {
  items:           Notification[];     // ordered by created_at desc
  retention_count: number;             // 50 by default
  dedupe_window_ms: number;            // 300_000 (5 min)
}
```

### 7.2 Sources

| Source     | Examples                                           | Default severity |
|------------|----------------------------------------------------|------------------|
| `studio`   | `MeetingFailed`, `RateLimited`, `IntegrityError`   | error / warning  |
| `product`  | `Saved successfully`, `Vertical X failed to load`  | success / warning|
| `vertical` | `Market data feed unavailable` (from a vertical)   | warning          |

Each source's emitter calls `useNotifications().push({ source, severity, title, body, ... })`.

### 7.3 Studio errors → notifications

`HttpStudioClient`'s `ObservabilityLayer` (deferred to v0.2 per `01-studio-client-spec.md` §9.5) hooks into the error path; the v0.1 placeholder is a try/catch in feature code that pushes a notification on `StudioClientError` types that surface_verbatim. Specifically:

| Error leaf            | Toast                                  | Notification |
|-----------------------|----------------------------------------|--------------|
| `StudioUnavailable`   | `error.studio_unavailable`             | yes (5-min dedupe) |
| `RateLimited`         | `error.rate_limited` (with seconds)    | no |
| `IntegrityError`      | `error.integrity_incident`             | yes (sticky; no dedupe — every occurrence) |
| `MeetingFailed`       | `error.meeting_failed`                 | yes (per meeting_id dedupe) |
| `MeetingNotReady`     | (silent — features handle inline)      | no |
| (others)              | (feature-specific decisions)            | feature-specific |

---

## §8 Permissions

### 8.1 Format

Permission codes are `<scope>:<verb>` strings. Reserved scopes:

- `platform`: cross-vertical capabilities (`platform:list_projects`, `platform:run_meeting`, `platform:view_observability`, `platform:list_meetings`).
- `<vertical_id>`: vertical-scoped capabilities; the vertical declares them in its backend manifest (per `13-vertical-template-spec.md`); auth-service stores per-user grants.

### 8.2 Source

`useUser().user.value.permissions: string[]` — the full list, populated from `GET /api/auth/me`. Refreshed on user re-authentication.

### 8.3 `<PermissionGate>` component

```vue
<template>
  <PermissionGate code="platform:run_meeting">
    <template #default>
      <button @click="startMeeting">Start meeting</button>
    </template>
    <template #fallback>
      <span class="text-muted">You don't have permission to start meetings.</span>
    </template>
  </PermissionGate>
</template>
```

Fallback slot is optional; when omitted, the gate renders nothing if denied.

### 8.4 No permission, no UI

Tabs and widgets contributed by verticals declare `required_permission`; the shell hides them entirely when the user lacks the permission. Routes guarded with `meta.required_permissions` redirect to `/platform/dashboard` with a toast.

---

## §9 Layout components

### 9.1 `<PlatformShell>` (top-level)

```vue
<template>
  <div class="grid grid-rows-[auto_1fr] grid-cols-[16rem_1fr] h-screen">
    <Header class="col-span-2" />
    <SideNav />
    <MainOutlet />
    <ToastContainer />
  </div>
</template>
```

Single instance, mounted at app root.

### 9.2 `<Header>`

Slots (in order): `<Logo />`, `<VerticalSwitcher />`, `<RouterBreadcrumbs />`, spacer, `<StudioHealthIndicator />`, `<NotificationBell />`, `<UserMenu />`.

### 9.3 `<SideNav>`

Two sections:
- **Platform**: links to `/platform/dashboard`, `/platform/knowledge`, `/platform/chathub`, `/platform/reports`, `/platform/observability`, `/platform/settings` (those user has permission for).
- **Vertical** (when `useActiveVertical().active.value` is non-null): tabs from `active.tabs` ordered by `position`, each gated by its `required_permission`.

### 9.4 `<MainOutlet>`

```vue
<template>
  <main class="overflow-auto bg-bg">
    <RouterView v-slot="{ Component }">
      <Suspense>
        <component :is="Component" />
        <template #fallback><LoadingSpinner /></template>
      </Suspense>
    </RouterView>
  </main>
</template>
```

`<Suspense>` wrapper supports lazy-loaded route components (used by all feature panels for code-splitting).

### 9.5 `<VerticalSwitcher>`

Dropdown rendering `useActiveVertical().available` with the active highlighted. Hidden when `available.length === 1`. Selecting an item calls `switchTo(id)`.

---

## §10 Boot sequence

The exact order in which the shell comes up. Authoritative for `apps/frontend/main.ts` (per spec 16):

```
1. Create Vue app instance
2. Install Pinia
3. Install vue-i18n (platform bundles only at this point)
4. Configure StudioClient (env-driven: pseudo or http)
5. useStudioStore().setClient(client)            # makes useStudio() work
6. Fetch initial state in parallel:
     a. GET /api/auth/me              → useUserStore().setUser(user)
        (if 401, navigate to /login and stop here)
     b. GET /api/platform/feature-flags → useFeatureFlagsStore().load(flags)
     c. GET /api/platform/verticals    → list of {vertical_id, frontend_module_path}
7. For each vertical entry from 6c:
     - Dynamic import frontend_module_path
     - registerVertical(module.default)
     - On error: push toast + skip
8. Apply user preferences:
     - useTheme().setMode(user.preferences.theme_mode)
     - useI18n().setLocale(user.preferences.locale)
     - useActiveVertical().switchTo(user.preferences.active_vertical
                                      ?? firstAvailableForUser())
9. Install router (after verticals registered → tabs are in route table)
10. app.mount("#app")  → <PlatformShell> renders
11. Background: useStudioHealth() begins polling
```

If step 6a returns 401: skip steps 7-8 (no user → no preferences); navigate to `/login`. After successful login (auth-service spec 03), restart from step 6a.

---

## §11 Test matrix

Every public composable + every layout slot + every route guard has tests. All tests run with Vitest + Vue Testing Library; substitution-eligible tests (those that exercise StudioClient indirectly) marked `[SUB]`.

### Composables

| scenario | composable | expected | test_id |
|---|---|---|---|
| user authenticated | `useUser` | `is_authenticated: true`, `user.permissions` populated | `t_use_user_authed` |
| user 401 mid-session | `useUser` after 401 from API | `signOut` called automatically; `is_authenticated: false` | `t_use_user_session_expired` |
| StudioClient available | `useStudio` after boot | returns the configured client | `[SUB] t_use_studio_returns_client` |
| StudioClient missing | `useStudio` before boot | throws "StudioClient not configured" | `t_use_studio_unconfigured` |
| Health polling | `useStudioHealth(poll_interval_ms=100)` | 3 polls in 350 ms; `health` updates | `[SUB] t_use_studio_health_poll` |
| Health error tolerated | poll raises `StudioUnavailable` | `error` set; previous `health` retained; polling continues | `[SUB] t_use_studio_health_error` |
| Active vertical switch | `useActiveVertical().switchTo("v-b")` | active updates; URL changes; preferences persisted | `t_use_active_vertical_switch` |
| Single-vertical user | only one vertical available | switcher hidden; active set on boot | `t_use_active_vertical_single` |
| Zero-vertical user | no verticals available | empty-state page rendered; sign-out link present | `t_use_active_vertical_zero` |
| Notifications dedup | push twice with same `dedupe_key` within 5 min | one entry in list | `t_notifications_dedup` |
| Notifications retention | push 60 notifications | only last 50 retained | `t_notifications_retention` |
| Toast auto-dismiss | `useToast().show({duration_ms: 100})` | removed from DOM after 100 ms | `t_toast_dismiss` |
| Permission grant | user has `platform:run_meeting` | `usePermission("platform:run_meeting").value === true` | `t_permission_grant` |
| Permission deny | user missing permission | `usePermission(...).value === false` | `t_permission_deny` |
| Permissions all-mode | user has 1 of 2 required | `usePermissions([...], "all").value === false` | `t_permissions_all_mode` |
| Feature flag | flag set true at boot | `useFeatureFlag("x").value === true` | `t_feature_flag_true` |
| Feature flag default | flag absent | returns `default_value` | `t_feature_flag_default` |
| Theme persistence | `useTheme().setMode("dark")` | preferences PUT called; `<html data-theme="dark">` | `t_theme_persists` |
| Theme system mode | `setMode("system")` with OS dark | resolved to "dark"; on OS change → re-applies | `t_theme_system_follows_os` |
| Vertical accent color | active vertical declares `accent_color` | `--color-accent` CSS var matches | `t_theme_vertical_accent` |
| i18n locale switch | `useI18n().setLocale("zh")` | preferences PUT; `t()` returns Chinese | `t_i18n_locale_switch` |
| i18n missing key | `t("nonexistent.key")` | returns key in dev; logs warning | `t_i18n_missing_key` |
| i18n vertical bundle | vertical merged keys | `t("vertical.v_a.tab.x")` returns vertical's value | `t_i18n_vertical_namespace` |

### Vertical extension

| scenario | input | expected | test_id |
|---|---|---|---|
| valid manifest | full valid manifest | tabs / widgets / handlers / i18n all registered | `t_register_vertical_valid` |
| missing required field | manifest without `vertical_id` | throws `VerticalRegistrationError{field: "vertical_id", reason: "missing"}` | `t_register_vertical_missing` |
| invalid vertical_id format | `"Vertical A!"` | throws `..., reason: "invalid_format"` | `t_register_vertical_bad_id` |
| duplicate vertical_id | register twice with same id | second throws `..., reason: "duplicate_id"` | `t_register_vertical_dup_id` |
| duplicate tab id within manifest | two TabContributions same id | throws `..., reason: "duplicate_tab_id"` | `t_register_vertical_dup_tab` |
| invalid route_path (no leading /) | `route_path: "data-explorer"` | throws `..., reason: "invalid_route_path"` | `t_register_vertical_bad_route` |
| vertical fails to load (boot) | dynamic import rejects | toast pushed; shell continues with remaining verticals | `t_boot_vertical_load_failure` |

### Routing

| scenario | URL | user state | expected | test_id |
|---|---|---|---|---|
| unauthed root | `/` | not authed | redirect to `/login?redirect=/` | `t_route_unauth_root` |
| authed root | `/` | authed | redirect to `/platform/dashboard` | `t_route_authed_root` |
| login while authed | `/login` | authed | redirect to `/platform/dashboard` | `t_route_login_while_authed` |
| permission denied route | `/platform/observability` | user missing `platform:view_observability` | redirect to `/platform/dashboard` + toast | `t_route_perm_denied` |
| vertical URL switches active | `/v-b/tab-x` while v-a active | active becomes v-b before route mounts | `t_route_vertical_switches_active` |
| unknown vertical | `/v-unknown/...` | any state | 404 page | `t_route_unknown_vertical` |
| catch-all | `/random/path` | any state | `<NotFound />` | `t_route_catch_all` |

### Boot sequence

| scenario | environment | expected | test_id |
|---|---|---|---|
| happy boot | studio reachable, user authed, 2 verticals | shell renders dashboard with widgets from active vertical | `[SUB] t_boot_happy` |
| auth fails at boot | `/api/auth/me` 401 | navigate to `/login`; do not load verticals | `t_boot_unauthed` |
| one vertical fails | one of 2 verticals' import rejects | shell renders with only the working vertical; toast shown | `t_boot_partial_failure` |
| all verticals fail | both verticals fail to load | empty-state page; sign-out link | `t_boot_total_failure` |
| studio unreachable at boot | health endpoint fails | shell still renders; health indicator red; features handle StudioUnavailable inline | `[SUB] t_boot_studio_unreachable` |

---

## §12 i18n strings introduced by the shell

(Required by writing-product-specs cross-cutting rule.)

```json
// packages/platform-shell/src/i18n/en.json
{
  "layout": {
    "loading": "Loading…",
    "empty_state.no_verticals.title": "No verticals available",
    "empty_state.no_verticals.body": "Your account has no permissions for any installed vertical."
  },
  "nav": {
    "dashboard": "Dashboard",
    "knowledge": "Knowledge",
    "chathub": "Chat",
    "reports": "Reports",
    "observability": "Observability",
    "settings": "Settings",
    "switch_vertical": "Switch vertical"
  },
  "common": {
    "sign_out": "Sign out",
    "close": "Close",
    "save": "Save",
    "cancel": "Cancel"
  },
  "error": {
    "studio_unavailable": "Studio is unavailable. Some features may not work.",
    "rate_limited": "Rate limited. Try again in {seconds} seconds.",
    "integrity_incident": "A data integrity issue was detected. Engineering has been alerted.",
    "meeting_failed": "Meeting {meeting_id} failed: {reason}",
    "vertical_load_failure": "Failed to load vertical '{vertical_id}': {reason}"
  },
  "permission": {
    "denied": "You don't have permission for that action."
  },
  "theme": {
    "light": "Light",
    "dark": "Dark",
    "system": "Follow system"
  }
}
```

`zh.json` mirrors with Chinese translations. Verticals MAY override platform keys by providing the same key under their `vertical.<id>.<key>` namespace; shell resolution prefers vertical-namespaced keys when present.

---

## §13 Why this design — consolidated load-bearing decisions

**Why the shell exposes composables, not Pinia stores directly.**
Composables are the public API; Pinia stores are implementation. Composables let us evolve the storage / source / caching strategy (e.g., move from Pinia to a Vuex-like or Zustand-like) without breaking every consumer. They also enforce a uniform call shape (`useX()` everywhere) regardless of underlying mechanism (some composables wrap Pinia, others wrap vue-i18n, others wrap inject/provide).
*Considered and rejected.* **Export Pinia stores as the public API** — couples consumers to Pinia's exact reactive semantics; harder to mock in tests; mixes "use a store" with "use a service" in a single API.

**Why `useStudio` returns the StudioClient directly, not a wrapped facade.**
The StudioClient is already the public Protocol (`01-studio-client-spec.md`); wrapping it would re-introduce the contract drift risk we just eliminated by mirroring studio's frozen schemas. Features that need cross-cutting concerns (retries, telemetry) get them via `HttpStudioClient`'s sandwich layers (P7).
*Considered and rejected.* **Facade with shell-side caching / retry** — pulls translation logic into shell, violating P7.

**Why `registerVertical` is imperative (called by the vertical itself), not declarative (manifest scanned by shell).**
Verticals are TS modules; the manifest is the module's default export. Imperative `registerVertical(manifest)` lets the vertical's module decide when to register (e.g., after async initialization) and lets the bundler tree-shake the registration call when unused. Declarative scanning would require a static manifest format separate from the TS module, doubling the source of truth.
*Considered and rejected.* **JSON manifest scanned by shell** — duplicate source of truth; no place for inline `Component` references.

**Why permissions are unstructured `string`, not a typed enum.**
Verticals declare arbitrary new permission codes at registration time; the shell cannot enumerate them ahead of time (P10: shell doesn't know what verticals exist). Strings keep the Protocol open. Auth-service spec 03 maintains the canonical list of granted codes per user.
*Considered and rejected.* **Typed enum** — would require shell to know every vertical's permissions; couples shell to verticals.

**Why notifications and toasts are separate APIs, not unified with a "persist?" flag.**
They have different lifecycles: toasts auto-dismiss + are not historical; notifications persist + count as unread. Unifying with a flag means callers must remember to pass `persist: true` for important things; forgetting drops the history. Separate functions force the choice.
*Considered and rejected.* **`useNotifications().push({persist: bool})`** — too easy to forget the flag; bad ergonomics for "show this and remember it" (the common case).

**Why theming uses CSS variables + Tailwind data-theme, not a JS-driven theme provider.**
CSS variables propagate without re-render; switching from light to dark is a single attribute write. JS theme providers (e.g., emotion / styled-components themes) re-render the entire tree on change.
*Considered and rejected.* **CSS-in-JS theme provider** — performance cost on every theme toggle.

**Why the boot sequence is fixed, not pluggable.**
The order matters: StudioClient must exist before `useStudio()` is called by any vertical's manifest registration; user preferences must load before active vertical is resolved; verticals must register before the router mounts. Pluggable boot would let some vertical's plugin reorder steps and break invariants.
*Considered and rejected.* **Plugin-controlled boot** — over-engineering; v0.1 has no use case.

**Why `useMeetingStreamStore` lives in shell, not in agora.**
Per `01b-product-derivations-spec.md` §9: chathub also consumes meeting streams (single-agent meetings); putting the store in agora would force chathub to import agora's namespace just to subscribe to a stream.
*Considered and rejected.* **Store in agora** — already covered in 01b's Why section.

**Why active-vertical switching does NOT tear down meeting subscriptions.**
A user might be observing a meeting in vertical A, switch to vertical B briefly to check something, switch back. Tearing down + re-subscribing on each switch is wasteful and loses any in-flight events between unsubscribe and re-subscribe. Reference-counted subscriptions in `useMeetingStreamStore` handle this naturally.
*Considered and rejected.* **Vertical switch = full meeting unsubscribe** — bad UX.

---

## §14 Downstream impact

| Spec | Adjustment |
|---|---|
| `03-auth-service-spec.md` | Defines `GET /api/auth/me` shape (User payload), permission model (string codes), session lifecycle. Shell reads these unchanged. |
| `04-user-service-spec.md` | Defines `GET/PUT /api/user/preferences` (UserPreferences shape). Shell reads / debounces writes. |
| `05`–`12` (every feature spec) | Each feature's spec declares its routes (under `/platform/<feature>/...`), required permissions, i18n bundle, and any composables it adds. Each feature CONSUMES the shell's composables and `<PermissionGate>` for UI gating. |
| `13-vertical-template-spec.md` | The `_template/` package's `frontend/manifest.ts` MUST conform to the `VerticalManifest` interface defined here (§3.1). Includes the validation requirements + a sample manifest. |
| `14-...` (first concrete vertical) | Same — must conform. Adds `accent_color` if vertical has one; declares permissions, project_id_in allowlist. |
| `15-apps-api-spec.md` | Defines `GET /api/platform/verticals` and `GET /api/platform/feature-flags` endpoints (consumed by shell at boot per §10). |
| `16-apps-frontend-spec.md` | Defines `apps/frontend/main.ts` boot script following §10's order; configures StudioClient (env-driven); installs Pinia / vue-i18n / shell. |
| `17-substitution-tests-spec.md` | Substitution tests cover all `[SUB]`-marked rows in §11 (boot, useStudio, useStudioHealth). |

---

## §15 Pre-merge checklist

- [ ] Mission + Scope present; "out of scope for v0.1" listed (hot-reload, multi-tenant, theme authoring, cross-tab sync, offline)
- [ ] Module layout (§1) enumerates every file the shell ships
- [ ] All 11 public composables (§2) documented with full TS signature, source, reactivity rule, lifecycle
- [ ] `VerticalManifest` (§3.1) interface complete with all 5 contribution types + `default_project_filter` (per `01-studio-client` §11.4) + i18n + accent_color
- [ ] `registerVertical` (§3.2) declares its 8 behaviors + `VerticalRegistrationError` type with all 5 reasons
- [ ] Boot-time discovery flow (§3.3) pinned to the apps/frontend boot path; no filesystem scan
- [ ] Route table (§4) lists every route the shell registers; guards (§4.1) declare auth + permission + vertical-active
- [ ] Theming (§5) covers tokens, apply mechanism, per-vertical accent, font stack
- [ ] i18n (§6) covers engine, bundle structure, vertical merge mechanism, feature merge mechanism
- [ ] Notifications (§7) covers store shape, sources, toast vs notification distinction, dedup, retention, studio-error mapping
- [ ] Permissions (§8) covers format convention, source, `<PermissionGate>` API, hide-on-deny behavior
- [ ] Layout components (§9) enumerated with slot structure
- [ ] Boot sequence (§10) is the authoritative ordering for `apps/frontend/main.ts`
- [ ] Test matrix (§11) covers every composable, every registration scenario, every route guard, every boot scenario; substitution-eligible tests marked `[SUB]`
- [ ] i18n strings (§12) lists every user-visible key with `en` value (Chinese mirror documented separately in shell's repo)
- [ ] Why-this / Why-not blocks (§13) for every load-bearing decision (≥ 8)
- [ ] Downstream impact (§14) lists every spec affected
- [ ] No business / domain / product / agent-role string literal anywhere (uses neutral `vertical-a`, `v-b`, etc.)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No `dict[str, Any]` / `Record<string, any>` / `unknown` without inline justification (used `Record<string, string>` for i18n bundles which is intentional and typed-as-such)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/02-platform-shell-spec.md`
