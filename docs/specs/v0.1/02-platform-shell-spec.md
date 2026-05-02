# 02 — `platform-shell` v0.1 spec

> **Status**: v0.1 contract for the platform's shell layer — the always-present scaffolding around features and verticals. **Frontend stack**: React 18 + TypeScript + Zustand + React Router v6 + react-i18next + Tailwind.
> **Lives at**: `packages/platform-shell/`.
> **Upstream contracts**: `01-studio-client-spec.md` (StudioClient + DTOs), `01b-product-derivations-spec.md` (`useMeetingStreamRegistry` + `useMeetingStream` live here per §2.1 of 01b).
> **Consumed by**: every feature in Batch C (`05`–`12`), every vertical in Batch D, the frontend app shell in `16-apps-frontend-spec.md`.
> **Supersedes**: the Vue/Pinia version of this spec (committed in `80e39c8`); React migration per session decision 2026-05-03.

---

## Mission

This file defines the platform shell — the always-present application scaffolding (layout, router, theming, i18n, multi-vertical switcher, public hooks, vertical extension surface) that every product user sees regardless of which vertical pack is active. The shell is the host; features plug in as panels, verticals plug in via manifest. Removing any vertical or feature does not affect the shell; the shell does not know what specific verticals or features exist.

**Hard rule** (P4 + P10): the shell's public surface — hooks, layout slots, vertical extension API — is **stable + additive only** within v0.x. Adding a new hook / slot is fine; removing or changing the signature of an existing one breaks every feature and every vertical at once.

---

## Scope

**Covers.**
- Module layout (`packages/platform-shell/src/...`).
- Top-level React layout components (`<PlatformShell>`, `<Header>`, `<SideNav>`, `<MainOutlet>`, `<ToastContainer>`).
- React Router v6 configuration (data API via `createBrowserRouter`): route taxonomy (auth / platform / vertical-prefixed / catch-all), loaders (auth-required, permission-required, vertical-active resolution).
- Public React hooks (the contract every feature + every vertical depends on): `useUser`, `useStudio`, `useStudioHealth`, `useActiveVertical`, `useNotifications`, `useToast`, `useMeetingStream` (re-exported from `01b`), `usePermission`, `usePermissions`, `useFeatureFlag`, `useTheme`, `useI18n`.
- Vertical extension API: `VerticalManifest` TypeScript interface + `registerVertical(manifest)` registration function + boot-time discovery flow.
- Theming (light / dark / system + per-vertical accent), persisted via user-service.
- i18n (react-i18next; `zh` + `en` for v0.1; locale persisted; vertical bundles merged on registration via `addResourceBundle`).
- Notification model (transient toasts vs persistent notifications; sources, dedup, retention).
- Permission model (string-typed grants from auth-service; reactive checks via Zustand selectors).
- Multi-vertical switcher (UI element + state management; switching semantics).
- Boot sequence (the order in which shell, features, verticals come up).
- Test matrix per hook + per layout slot + per route loader.

**Does not cover.**
- The `StudioClient` Protocol or its DTOs — `01-studio-client-spec.md`.
- The 4 agora-specific reducer hooks (`useOutcomeReducer`, `useDagState`, `useCostState`, `useProvenance`) — `01b-product-derivations-spec.md` (they live in agora, not shell).
- Login UI flow (form, validation, session creation) — `03-auth-service-spec.md` provides the backend; the shell only guards routes via `useUser()` and redirects to `/login` when needed.
- User preferences storage — `04-user-service-spec.md` provides the backend; the shell reads/writes via hooks.
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
│   ├── index.ts                          # public exports (hooks + types + registerVertical + components)
│   ├── components/
│   │   ├── PlatformShell.tsx             # top-level layout
│   │   ├── Header.tsx
│   │   ├── SideNav.tsx
│   │   ├── MainOutlet.tsx
│   │   ├── ToastContainer.tsx
│   │   ├── VerticalSwitcher.tsx
│   │   ├── UserMenu.tsx
│   │   ├── NotificationBell.tsx
│   │   ├── StudioHealthIndicator.tsx
│   │   └── PermissionGate.tsx            # <PermissionGate code="..." fallback={...}>{children}</PermissionGate>
│   ├── hooks/
│   │   ├── useUser.ts
│   │   ├── useStudio.ts
│   │   ├── useStudioHealth.ts
│   │   ├── useActiveVertical.ts
│   │   ├── useNotifications.ts           # also exports useToast
│   │   ├── useMeetingStream.ts           # re-export from 01b §2.4
│   │   ├── usePermission.ts              # also exports usePermissions
│   │   ├── useFeatureFlag.ts
│   │   ├── useTheme.ts
│   │   └── useI18n.ts                    # thin wrapper over react-i18next's useTranslation
│   ├── stores/                            # Zustand stores (private; consumed via hooks)
│   │   ├── useStudioStore.ts             # holds the StudioClient instance
│   │   ├── useUserStore.ts
│   │   ├── useVerticalsStore.ts          # registered manifests + active id
│   │   ├── useNotificationsStore.ts
│   │   ├── useThemeStore.ts
│   │   ├── useFeatureFlagsStore.ts
│   │   └── useMeetingStreamRegistry.ts   # Zustand store from 01b §2.2
│   ├── router/
│   │   ├── index.ts                      # createBrowserRouter() + route table builder
│   │   ├── loaders.ts                    # auth-required / permission-required / vertical-active
│   │   └── guards.tsx                    # Layout components + redirect helpers
│   ├── verticals/
│   │   ├── manifest.ts                   # VerticalManifest type + validation
│   │   └── registry.ts                   # registerVertical, listVerticals, getActiveVertical
│   ├── i18n/
│   │   ├── index.ts                      # i18next.init() with platform bundles
│   │   ├── zh.json
│   │   └── en.json
│   ├── theme/
│   │   ├── tokens.ts                     # design tokens (colors, spacing, radius)
│   │   └── apply.ts                      # apply theme to <html data-theme="...">
│   └── types/
│       ├── permission.ts                 # PermissionCode = string (branded)
│       └── notification.ts
├── tests/                                  # Vitest + React Testing Library
│   ├── hooks/
│   ├── components/
│   └── router/
├── package.json                            # depends on react, react-dom, react-router-dom,
│                                           #            zustand, react-i18next, i18next
└── tsconfig.json
```

**No backend code.** Shell is pure frontend (React 18 + TypeScript + Zustand + React Router v6 + react-i18next + Tailwind). Backend equivalents (auth-service, user-service, apps/api) are separate packages.

---

## §2 Public hooks

This is the **contract every feature + vertical depends on**. Adding a hook is a minor bump; removing or changing a signature is forbidden in v0.x (P4).

### 2.1 `useUser`

```typescript
export interface User {
  user_id:        string;            // opaque to product (passed through to studio as-is)
  display_name:   string;            // user-facing
  email:          string;
  permissions:    string[];          // permission codes; e.g. ["platform:list_projects", "vertical-a:open_meeting"]
  preferences:    UserPreferences;   // see 2.10
  authenticated_at: string;          // ISO-8601
}

export interface UseUserReturn {
  user:               User | null;     // null when unauthenticated
  is_authenticated:   boolean;
  refresh():          Promise<void>;   // re-fetch from auth-service /me endpoint
  signOut():          Promise<void>;   // invalidate this session, redirect to /login
  signOutAll():       Promise<void>;   // invalidate every session for this user
}

export function useUser(): UseUserReturn;
```

**Source.** Backed by `useUserStore` (Zustand) which fetches from `GET /api/auth/me` on app boot and caches. Re-fetched on `refresh()` or when an `AuthRequired` error surfaces from any API call.

**Reactivity.** All consumers selecting `user` re-render when sign-in / sign-out / preference-update happens. Zustand selectors ensure components only re-render on the slices they read.

### 2.2 `useStudio`

```typescript
import type { StudioClient } from "@entelecheia/studio-client";

export function useStudio(): StudioClient;
```

**Source.** `useStudioStore` holds the configured `StudioClient` instance; it is set once at app boot by `apps/frontend/main.tsx` (per `16-apps-frontend-spec.md`). Shell does NOT decide which implementation (`PseudoStudioClient` vs `HttpStudioClient`) — that's `apps/frontend`'s job based on env config.

**Throws.** `Error("StudioClient not configured")` if called before `apps/frontend` has provided one. Surfaces as a developer error; never reaches end users in correctly-built deployments.

### 2.3 `useStudioHealth`

```typescript
import type { StudioHealth } from "@entelecheia/studio-client";

export interface UseStudioHealthOptions {
  poll_interval_ms?:   number;     // default 30_000 (30s)
  enabled?:            boolean;    // default true; false to suspend polling
}

export interface UseStudioHealthReturn {
  health:    StudioHealth | null;
  is_loading: boolean;
  error:      string | null;
  refresh():  Promise<void>;       // force one immediate fetch
}

export function useStudioHealth(opts?: UseStudioHealthOptions): UseStudioHealthReturn;
```

**Behavior.** On mount: one immediate fetch (`StudioClient.get_studio_health()`); thereafter polls every `poll_interval_ms` via `setInterval` registered in `useEffect`; cleanup clears the interval on unmount. Errors set `error` but keep last-known `health` for UI continuity.

**UI consumer.** `<StudioHealthIndicator>` renders a small dot in the header (green = both live and ready; amber = live not ready; red = unreachable).

### 2.4 `useActiveVertical`

```typescript
export interface UseActiveVerticalReturn {
  active:                VerticalManifest | null;  // null only during boot
  available:             VerticalManifest[];       // verticals user has any permission for
  switchTo(id: string):  Promise<void>;            // navigates to vertical's default route
}

export function useActiveVertical(): UseActiveVerticalReturn;
```

**Switching semantics.**
- Updates active vertical in `useVerticalsStore`.
- Persists choice to user-service preferences (`active_vertical`).
- Calls React Router's `navigate()` to `/{vertical_id}/{first_tab_id}` (or vertical's declared `default_route`).
- Does NOT tear down meeting subscriptions; `useMeetingStream` instances are keyed by `meeting_id` (not `vertical_id`), so switching and switching back leaves them intact.
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

export interface UseNotificationsReturn {
  list:           Notification[];                          // ordered by created_at desc; last 50 retained
  unread_count:   number;
  push(n: Omit<Notification, "id" | "created_at" | "read">): void;
  markRead(id: string):   void;
  markAllRead():          void;
  dismiss(id: string):    void;
}

export function useNotifications(): UseNotificationsReturn;

export interface UseToastReturn {
  show(opts: {
    severity:    NotificationSeverity;
    title:       string;
    body?:       string;
    duration_ms?: number;          // default 5000; 0 = sticky until manual dismiss
  }): void;
}

export function useToast(): UseToastReturn;
```

**Toast vs Notification.**
- **Toast**: ephemeral; renders in `<ToastContainer>`; auto-dismisses; NOT added to the bell list.
- **Notification**: persisted in `useNotificationsStore`; shows in `<NotificationBell>`; manually dismissible.

A common pattern: features call BOTH `useToast().show(...)` (immediate UX) and `useNotifications().push(...)` (history) for important events.

**Dedup.** When pushed with `dedupe_key`, suppresses if an unread notification with the same key was pushed in the last 5 minutes.

**Retention.** Bell list keeps last 50; older drop on push (oldest-first eviction).

### 2.6 `useMeetingStream`

Re-exported from `01b-product-derivations-spec.md` §2.4. Lives at `packages/platform-shell/src/hooks/useMeetingStream.ts`. Re-exported from `packages/platform-shell/src/index.ts`.

Signature recap (full contract in 01b):

```typescript
export interface UseMeetingStreamReturn {
  state:           MeetingStreamState | undefined;
  reconnect:       () => Promise<void>;
  reset:           () => void;
  forceFullReload: () => Promise<void>;
}

export function useMeetingStream(meeting_id: string): UseMeetingStreamReturn;
```

The underlying Zustand registry (`useMeetingStreamRegistry`) is also exported from this package for advanced use (chathub directly subscribes via the registry — see `08-feature-chathub-spec.md`).

### 2.7 `usePermission`

```typescript
export function usePermission(code: string): boolean;

export function usePermissions(codes: string[], mode?: "any" | "all"): boolean;   // mode default "all"
```

**Source.** Selects from `useUserStore`'s `user.permissions` array via Zustand selector — components only re-render when the relevant permission changes (or sign-in / sign-out happens).
**Naming convention.** Permissions are `<scope>:<verb>` strings: `platform:list_projects`, `platform:run_meeting`, `<vertical_id>:open_meeting`, `<vertical_id>:upload_data_kind_X`. Vertical-scoped permissions use the vertical's id as scope.

### 2.8 `useFeatureFlag`

```typescript
export function useFeatureFlag(flag: string, default_value?: boolean): boolean;   // default false
```

**Source.** `useFeatureFlagsStore` is populated at boot from `GET /api/platform/feature-flags` (apps/api endpoint, see `15-apps-api-spec.md`).
**v0.1 use case.** Roll out an in-progress feature behind `experimental:knowledge_v2_layout` (etc.). Avoid using flags for vertical-specific routing — that's what verticals are for (P10).

### 2.9 `useTheme`

```typescript
export type ThemeMode = "light" | "dark" | "system";

export interface UseThemeReturn {
  mode:        ThemeMode;          // resolved theme; "system" follows OS prefers-color-scheme
  setMode(m: ThemeMode):  void;    // persists to user prefs
  accent:      string;             // hex color from active vertical's accent_color or platform default
}

export function useTheme(): UseThemeReturn;
```

**Persistence.** Theme mode is stored in user-service preferences. On boot, restore.

**Accent color.** Derived from `useActiveVertical().active?.accent_color ?? "#3B82F6"` (platform default). Verticals MAY declare `accent_color` in their manifest (per §3); shell applies it as a CSS variable consumed by Tailwind tokens.

**System mode.** When `mode === "system"`, the shell registers a `MediaQueryList` listener for `(prefers-color-scheme: dark)` via a `useEffect` in `<PlatformShell>` and re-applies the theme on OS change.

### 2.10 `useI18n`

```typescript
export type Locale = "zh" | "en";   // v0.1 fixed; new locales added via i18next config

export interface UseI18nReturn {
  t(key: string, args?: Record<string, string | number>): string;
  locale:    Locale;
  setLocale(l: Locale):  void;       // persists to user prefs; refreshes route titles + meta
}

export function useI18n(): UseI18nReturn;
```

Thin wrapper over react-i18next's `useTranslation()`. Provides typed `t()` against the merged translation bundles (platform + active vertical + currently-loaded feature). Missing-key fallback logs a warning and returns the key string in dev; returns the English value in production (configured via `i18next.init({ fallbackLng: "en" })`).

**Per-vertical i18n bundles** are merged into the global i18next instance at `registerVertical` time via `i18next.addResourceBundle(lng, namespace, bundle, deep=true, overwrite=true)` (per §3.3 and §6.3).

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

**Storage.** All persisted to user-service via `PUT /api/user/preferences` (per `04-user-service-spec.md`). Shell debounces writes (500 ms via per-store debounced action) so rapid toggles don't spam the server.

---

## §3 Vertical extension API

This is the **only** way verticals plug into the shell (P5). The shell exposes one TypeScript interface (`VerticalManifest`) and one registration function (`registerVertical`); verticals call `registerVertical(myManifest)` exactly once at module load time.

### 3.1 `VerticalManifest`

```typescript
import type { ComponentType, LazyExoticComponent } from "react";
import type { ProjectId } from "@entelecheia/studio-client";

// React component type accepted by every contribution slot.
// Allows both eager components and lazy-loaded (code-split) ones.
export type VerticalReactComponent = ComponentType<any> | LazyExoticComponent<ComponentType<any>>;

export interface VerticalManifest {
  // identity
  vertical_id:    string;                       // matches backend manifest's vertical_id; lowercase snake; e.g. "vertical-a"
  display_name:   string;                       // user-facing; shown in switcher; localizable via i18n
  description:    string;                       // <= 200 chars; one-liner
  icon:           string;                       // lucide-react icon name; rendered in switcher

  // appearance (optional)
  accent_color:   string | null;                // hex like "#FF8800"; default null = platform default

  // contributions
  tabs:                  TabContribution[];
  dashboard_widgets:     WidgetContribution[];
  upload_handlers:       UploadHandlerContribution[];
  data_feeds:            DataFeedContribution[];

  // project filtering (per 01-studio-client §11.4)
  default_project_filter: { project_id_in: ProjectId[] };

  // i18n bundles (merged into global i18next instance on registration via addResourceBundle)
  i18n:           { zh: Record<string, string>; en: Record<string, string> };

  // optional: where switching to this vertical lands by default
  default_route:  string | null;                // e.g. "/<vertical_id>/<first_tab_id>"; null = first tab in tabs[]
}

export interface TabContribution {
  id:                    string;                // unique within vertical; lowercase snake; e.g. "data-explorer"
  label_key:             string;                // i18n key; resolved at render via useI18n().t()
  route_path:            string;                // mounted under /<vertical_id>/<route_path>; must start with /
  component:             VerticalReactComponent; // React component; lazy-load supported
  required_permission:   string | null;         // gate; null = no gate beyond being in the vertical
  position:              number;                // ordering hint; lower = earlier in side nav
}

export interface WidgetContribution {
  id:                    string;
  component:             VerticalReactComponent;
  preferred_position:    "top-left" | "top-right" | "bottom-left" | "bottom-right";
  title_key:             string;                // i18n key
  required_permission:   string | null;
}

export interface UploadHandlerContribution {
  kind:                  string;                // user-facing kind label; e.g. "csv-table"; not a studio Material kind
  label_key:             string;                // i18n key for picker label
  accepts:               string[];              // file extensions or MIME types; e.g. [".csv", ".xlsx"]
  max_size_bytes:        number;                // default 10_000_000 (10 MB)
  handler_component:     VerticalReactComponent; // React component
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
3. Merges `manifest.i18n.zh` and `manifest.i18n.en` into the global i18next instance under namespace `vertical.<vertical_id>.<key>` via `i18next.addResourceBundle`.
4. Adds tabs to the React Router route table builder (mounted under `/{vertical_id}/...` after all verticals are registered — see §3.3).
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
apps/frontend/main.tsx startup:
  1. Fetch GET /api/platform/verticals → { available: [{vertical_id, frontend_module_path}, ...] }
  2. For each available vertical:
       a. Dynamic import: const mod = await import(/* @vite-ignore */ frontend_module_path)
       b. mod.default is a VerticalManifest (per convention)
       c. registerVertical(mod.default)
  3. Resolve active vertical:
       a. Read useUserStore.getState().user?.preferences.active_vertical
       b. If null OR not in registered set: pick first vertical user has permission for
       c. Set as active via useVerticalsStore.getState().setActive(id)
  4. Build router: createBrowserRouter([...]) with all routes (platform + vertical-contributed) registered
  5. createRoot(document.getElementById("root")!).render(<RouterProvider router={router} />)
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

*                                     → <NotFound />
```

Built via React Router v6 data API (`createBrowserRouter`):

```typescript
export function buildRouter() {
  const verticalRoutes = useVerticalsStore.getState().listVerticals().flatMap(v =>
    v.tabs.map(tab => ({
      path: `/${v.vertical_id}${tab.route_path}`,
      lazy: typeof tab.component === "function"
        ? async () => ({ Component: tab.component })
        : undefined,
      element: typeof tab.component !== "function" ? <tab.component /> : undefined,
      loader: makePermissionLoader(tab.required_permission),
    }))
  );

  return createBrowserRouter([
    {
      path: "/login",
      lazy: () => import("@auth-service/LoginPage").then(m => ({ Component: m.default })),
    },
    {
      path: "/",
      element: <PlatformShell />,
      loader: requireAuthLoader,
      children: [
        { index: true, loader: () => redirect("/platform/dashboard") },
        { path: "platform/dashboard", lazy: () => import("./Dashboard").then(m => ({ Component: m.default })) },
        { path: "platform/agora/:meeting_id?", lazy: () => import("@feature/agora").then(m => ({ Component: m.AgoraView })) },
        // ... other platform-feature routes
        ...verticalRoutes,
      ],
    },
    { path: "*", element: <NotFound /> },
  ]);
}
```

### 4.1 Route loaders + Layout-level guards

React Router v6 doesn't have a global `beforeEach`. Use:
- **Loaders for auth + permissions.** Each protected route declares a `loader` that throws a `redirect()` response when unauthenticated or unauthorized.
- **`<PlatformShell>` Layout component** for vertical-active resolution (it reads `useParams()` for `:vertical_id` and calls `useActiveVertical().switchTo()` if the URL implies a vertical change; runs in a `useEffect`).

```typescript
// packages/platform-shell/src/router/loaders.ts

export async function requireAuthLoader({ request }: LoaderFunctionArgs) {
  const user = useUserStore.getState().user;
  if (!user) {
    const url = new URL(request.url);
    return redirect(`/login?redirect=${encodeURIComponent(url.pathname + url.search)}`);
  }
  return null;
}

export function makePermissionLoader(required: string | null) {
  if (!required) return undefined;
  return async () => {
    const perms = useUserStore.getState().user?.permissions ?? [];
    if (!perms.includes(required)) {
      // Toast + redirect
      useNotificationsStore.getState().pushToast({
        severity: "error",
        title: "permission.denied",
      });
      return redirect("/platform/dashboard");
    }
    return null;
  };
}
```

The vertical-active guard lives in `<PlatformShell>` itself:

```tsx
// packages/platform-shell/src/components/PlatformShell.tsx (excerpt)
function PlatformShell() {
  const params = useParams();
  const switchTo = useVerticalsStore(s => s.setActive);
  const active = useVerticalsStore(s => s.activeId);

  useEffect(() => {
    const urlVerticalId = params.vertical_id;
    if (urlVerticalId && urlVerticalId !== active) {
      switchTo(urlVerticalId);
    }
  }, [params.vertical_id, active]);

  return (
    <div className="grid ...">
      <Header />
      <SideNav />
      <MainOutlet />
      <ToastContainer />
    </div>
  );
}
```

### 4.2 Default meta on routes

Each route's metadata (`required_permissions`, `title_key`) is encoded directly in the loader / route object — React Router doesn't have a generic `meta` field like Vue Router. Each feature's spec declares its loader in its own routes file.

**Examples** (per feature spec):
- `/login`: no `requireAuthLoader`
- `/platform/agora/:meeting_id?`: requires `platform:run_meeting` (loader from `05`)
- `/platform/observability`: requires `platform:view_observability` (loader from `12`)

### 4.3 Route → vertical mapping

Vertical tabs mount at `/{vertical_id}/{tab_route_path}` exactly. The shell handles the URL parsing via React Router's path params; verticals only declare relative `route_path` in their manifest. This means switching verticals via the switcher updates the URL prefix; bookmarks always include the vertical id.

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

When `useActiveVertical().active?.accent_color` changes, `useTheme()`'s underlying Zustand store re-applies via a subscription effect. UI updates immediately via CSS variable propagation; no React re-render needed for color change.

### 5.4 Material Symbols

Icons rendered via Material Symbols font (loaded once in `apps/frontend`, see spec 16) plus lucide-react for vertical icons.

---

## §6 i18n

### 6.1 Engine

`react-i18next` over `i18next`. Created once in `packages/platform-shell/src/i18n/index.ts`:

```typescript
import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import zh from "./zh.json";
import en from "./en.json";

await i18n
  .use(initReactI18next)
  .init({
    resources: {
      zh: { translation: zh },
      en: { translation: en },
    },
    lng: "en",                      // overridden at boot from user prefs
    fallbackLng: "en",
    interpolation: { escapeValue: false },  // React already escapes
    debug: import.meta.env.DEV,
  });

export { i18n };
```

### 6.2 Bundle structure

```
packages/platform-shell/src/i18n/
├── zh.json          # platform-level keys (layout, errors, common UI)
└── en.json
```

Top-level namespaces in JSON: `layout.*`, `nav.*`, `common.*`, `error.*`, `permission.*`, `theme.*`.

### 6.3 Vertical bundles merged at registration

`registerVertical(manifest)` merges `manifest.i18n.zh` under namespace `vertical.<vertical_id>.<key>` via `i18next.addResourceBundle`:

```typescript
// In manifest:
i18n: {
  zh: { "tab.data_explorer": "数据浏览" },
  en: { "tab.data_explorer": "Data Explorer" },
}

// At registerVertical time, the shell calls:
i18next.addResourceBundle("zh", "translation",
  { vertical: { [manifest.vertical_id]: manifest.i18n.zh } }, true, true);
i18next.addResourceBundle("en", "translation",
  { vertical: { [manifest.vertical_id]: manifest.i18n.en } }, true, true);

// After registration, accessible as:
useI18n().t(`vertical.${verticalId}.tab.data_explorer`)
```

Key collisions across verticals are isolated by namespace; no collision is possible.

### 6.4 Feature i18n

Each platform feature ships its own bundle and registers it via a feature-internal API (defined in each feature spec); the registration mechanism is the same `i18next.addResourceBundle` call with namespace `feature.<feature_name>.<key>`.

---

## §7 Notifications

### 7.1 Notification store

Zustand store at `packages/platform-shell/src/stores/useNotificationsStore.ts`:

```typescript
export interface NotificationsState {
  items:           Notification[];     // ordered by created_at desc
  retention_count: number;             // 50 by default
  dedupe_window_ms: number;            // 300_000 (5 min)
  push(n: Omit<Notification, "id" | "created_at" | "read">): void;
  pushToast(t: { severity: NotificationSeverity; title: string; body?: string; duration_ms?: number }): void;
  markRead(id: string):  void;
  markAllRead():         void;
  dismiss(id: string):   void;
}
```

Toast queue is a separate slice within the same store (UI consumed by `<ToastContainer>`); transient items removed via `setTimeout` registered when `pushToast` is called.

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

`useUser().user?.permissions: string[]` — the full list, populated from `GET /api/auth/me`. Refreshed on user re-authentication.

### 8.3 `<PermissionGate>` component

```tsx
import { PermissionGate } from "@entelecheia/platform-shell";

<PermissionGate code="platform:run_meeting" fallback={<span className="text-muted">You don't have permission to start meetings.</span>}>
  <button onClick={startMeeting}>Start meeting</button>
</PermissionGate>
```

Component contract:

```typescript
export interface PermissionGateProps {
  code:      string;
  children:  React.ReactNode;
  fallback?: React.ReactNode;       // optional; defaults to null (renders nothing)
}

export function PermissionGate(props: PermissionGateProps): React.ReactElement | null;
```

When `usePermission(code) === false`: renders `fallback ?? null`.

### 8.4 No permission, no UI

Tabs and widgets contributed by verticals declare `required_permission`; the shell hides them entirely when the user lacks the permission. Routes guarded with `makePermissionLoader(...)` redirect to `/platform/dashboard` with a toast.

---

## §9 Layout components

### 9.1 `<PlatformShell>` (top-level)

```tsx
export function PlatformShell() {
  return (
    <div className="grid grid-rows-[auto_1fr] grid-cols-[16rem_1fr] h-screen">
      <Header className="col-span-2" />
      <SideNav />
      <MainOutlet />
      <ToastContainer />
    </div>
  );
}
```

Single instance, mounted as the root layout via React Router.

### 9.2 `<Header>`

Slot order: `<Logo />`, `<VerticalSwitcher />`, `<RouterBreadcrumbs />`, spacer, `<StudioHealthIndicator />`, `<NotificationBell />`, `<UserMenu />`.

### 9.3 `<SideNav>`

Two sections:
- **Platform**: links to `/platform/dashboard`, `/platform/knowledge`, `/platform/chathub`, `/platform/reports`, `/platform/observability`, `/platform/settings` (those user has permission for).
- **Vertical** (when `useActiveVertical().active` is non-null): tabs from `active.tabs` ordered by `position`, each gated by its `required_permission`.

### 9.4 `<MainOutlet>`

```tsx
import { Outlet } from "react-router-dom";
import { Suspense } from "react";

export function MainOutlet() {
  return (
    <main className="overflow-auto bg-bg">
      <Suspense fallback={<LoadingSpinner />}>
        <Outlet />
      </Suspense>
    </main>
  );
}
```

`<Suspense>` supports the lazy-loaded route components (used by all feature panels for code-splitting).

### 9.5 `<VerticalSwitcher>`

Dropdown rendering `useActiveVertical().available` with the active highlighted. Hidden when `available.length === 1`. Selecting an item calls `switchTo(id)`.

---

## §10 Boot sequence

The exact order in which the shell comes up. Authoritative for `apps/frontend/main.tsx` (per spec 16):

```
1. Read app config (env-driven; for VITE_* vars and feature-flag path)
2. Initialize i18next (with platform bundles only at this point)
3. Configure StudioClient (env-driven: pseudo or http) and call:
     useStudioStore.getState().setClient(client)        # makes useStudio() work
4. Fetch initial state in parallel:
     a. GET /api/auth/me              → useUserStore.getState().setUser(user)
        (if 401, navigate to /login and stop here)
     b. GET /api/platform/feature-flags → useFeatureFlagsStore.getState().load(flags)
     c. GET /api/platform/verticals    → list of {vertical_id, frontend_module_path}
5. For each vertical entry from 4c:
     - Dynamic import frontend_module_path
     - registerVertical(module.default)
     - On error: push toast + skip
6. Apply user preferences:
     - useTheme().setMode(user.preferences.theme_mode)
     - i18n.changeLanguage(user.preferences.locale)
     - useVerticalsStore.getState().setActive(
         user.preferences.active_vertical ?? firstAvailableForUser())
7. Build router: createBrowserRouter([...])  # AFTER step 5 — vertical tabs are in the route table
8. createRoot(document.getElementById("root")!).render(
     <RouterProvider router={router} />
   )
9. Background: useStudioHealth() begins polling on first <StudioHealthIndicator> mount
```

If step 4a returns 401: skip steps 5-6 (no user → no preferences); navigate to `/login`. After successful login (auth-service spec 03), restart from step 4a.

**Why step 7 is after step 5.** React Router's `createBrowserRouter` builds the route table once; vertical-contributed routes (mounted at `/<vertical_id>/...`) must be present in the route objects array at construction time, not added later. v0.2 may switch to dynamic route addition via React Router's `router.addRoutes` if it ships, but v0.1 builds-once.

**Note on Zustand initialization.** Unlike Vue/Pinia, Zustand stores are module-level and initialize on first import. No `app.use(...)` step is needed for stores — they're "installed" implicitly. Likewise no provider component for the registry: components import the store hook directly and React subscribes via `useSyncExternalStore` under the hood.

---

## §11 Test matrix

Every public hook + every layout slot + every route loader has tests. All tests run with Vitest + React Testing Library + jsdom; substitution-eligible tests (those that exercise StudioClient indirectly) marked `[SUB]`.

### Hooks

| scenario | hook | expected | test_id |
|---|---|---|---|
| user authenticated | `useUser` | `is_authenticated: true`, `user.permissions` populated | `t_use_user_authed` |
| user 401 mid-session | `useUser` after 401 from API | `signOut` called automatically; `is_authenticated: false` | `t_use_user_session_expired` |
| StudioClient available | `useStudio` after boot | returns the configured client | `[SUB] t_use_studio_returns_client` |
| StudioClient missing | `useStudio` before boot | throws "StudioClient not configured" | `t_use_studio_unconfigured` |
| Health polling | `useStudioHealth({poll_interval_ms: 100})` | 3 polls in 350 ms; `health` updates | `[SUB] t_use_studio_health_poll` |
| Health error tolerated | poll raises `StudioUnavailable` | `error` set; previous `health` retained; polling continues | `[SUB] t_use_studio_health_error` |
| Health unmount cancels | hook unmounted mid-interval | no further polls; in-flight aborted | `t_use_studio_health_unmount` |
| Active vertical switch | `useActiveVertical().switchTo("v-b")` | active updates; URL changes via navigate(); preferences persisted | `t_use_active_vertical_switch` |
| Single-vertical user | only one vertical available | switcher hidden; active set on boot | `t_use_active_vertical_single` |
| Zero-vertical user | no verticals available | empty-state page rendered; sign-out link present | `t_use_active_vertical_zero` |
| Notifications dedup | push twice with same `dedupe_key` within 5 min | one entry in list | `t_notifications_dedup` |
| Notifications retention | push 60 notifications | only last 50 retained | `t_notifications_retention` |
| Toast auto-dismiss | `useToast().show({duration_ms: 100})` | removed from DOM after 100 ms | `t_toast_dismiss` |
| Permission grant | user has `platform:run_meeting` | `usePermission("platform:run_meeting") === true` | `t_permission_grant` |
| Permission deny | user missing permission | `usePermission(...) === false` | `t_permission_deny` |
| Permissions all-mode | user has 1 of 2 required | `usePermissions([...], "all") === false` | `t_permissions_all_mode` |
| Feature flag | flag set true at boot | `useFeatureFlag("x") === true` | `t_feature_flag_true` |
| Feature flag default | flag absent | returns `default_value` | `t_feature_flag_default` |
| Theme persistence | `useTheme().setMode("dark")` | preferences PATCH called; `<html data-theme="dark">` | `t_theme_persists` |
| Theme system mode | `setMode("system")` with OS dark | resolved to "dark"; on OS change → re-applies | `t_theme_system_follows_os` |
| Vertical accent color | active vertical declares `accent_color` | `--color-accent` CSS var matches | `t_theme_vertical_accent` |
| i18n locale switch | `useI18n().setLocale("zh")` | preferences PATCH; `t()` returns Chinese | `t_i18n_locale_switch` |
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
| vertical URL switches active | `/v-b/tab-x` while v-a active | PlatformShell's useEffect calls switchTo before tab content renders | `t_route_vertical_switches_active` |
| unknown vertical | `/v-unknown/...` | any state | 404 page (no matching route) | `t_route_unknown_vertical` |
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
    "rate_limited": "Rate limited. Try again in {{seconds}} seconds.",
    "integrity_incident": "A data integrity issue was detected. Engineering has been alerted.",
    "meeting_failed": "Meeting {{meeting_id}} failed: {{reason}}",
    "vertical_load_failure": "Failed to load vertical '{{vertical_id}}': {{reason}}"
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

`zh.json` mirrors with Chinese translations. Verticals MAY override platform keys by providing the same key under their `vertical.<id>.<key>` namespace; shell resolution prefers vertical-namespaced keys when present. Note: i18next interpolation uses `{{var}}` syntax (not Vue's `{var}`).

---

## §13 Why this design — consolidated load-bearing decisions

**Why the shell exposes hooks (not Zustand stores) directly to features.**
Hooks are the public API; Zustand stores are implementation. Hooks let us evolve the storage / source / caching strategy (e.g., move from Zustand to Jotai or Recoil) without breaking every consumer. They also enforce a uniform call shape (`useX()` everywhere) regardless of underlying mechanism (some hooks wrap a Zustand store, others wrap react-i18next, others compute derived values).
*Considered and rejected.* **Export Zustand stores as the public API** — couples consumers to Zustand's exact selector semantics; harder to mock in tests; mixes "use a store" with "use a service" in a single API.

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
CSS variables propagate without re-render; switching from light to dark is a single attribute write. JS theme providers (e.g., Emotion / styled-components themes) re-render the entire tree on change.
*Considered and rejected.* **CSS-in-JS theme provider** — performance cost on every theme toggle.

**Why React Router v6 data API (`createBrowserRouter`), not the older declarative `<Routes>`.**
Data API supports loaders + actions, which give us per-route auth + permission gating without wrapper components everywhere. Loaders run BEFORE rendering, enabling clean redirects via the `redirect()` response. The legacy declarative `<Routes>` would push guards into wrapper components, polluting the component tree.
*Considered and rejected.* **Declarative `<Routes>` + per-feature wrapper guards** — wrapper soup. **TanStack Router** — newer + powerful but adds a non-canonical dep; React Router v6 is the canonical choice + its data API covers our needs.

**Why the boot sequence is fixed, not pluggable.**
The order matters: StudioClient must exist before `useStudio()` is called by any vertical's manifest registration; user preferences must load before active vertical is resolved; verticals must register before the router is built. Pluggable boot would let some vertical's plugin reorder steps and break invariants.
*Considered and rejected.* **Plugin-controlled boot** — over-engineering; v0.1 has no use case.

**Why `useMeetingStreamRegistry` lives in shell, not in agora.**
Per `01b-product-derivations-spec.md` §9: chathub also consumes meeting streams (single-agent meetings); putting the store in agora would force chathub to import agora's namespace just to subscribe to a stream.
*Considered and rejected.* **Store in agora** — already covered in 01b's Why section.

**Why active-vertical switching does NOT tear down meeting subscriptions.**
A user might be observing a meeting in vertical A, switch to vertical B briefly to check something, switch back. Tearing down + re-subscribing on each switch is wasteful and loses any in-flight events between unsubscribe and re-subscribe. Reference-counted subscriptions in `useMeetingStream` handle this naturally — components unmount but the registry slice persists until the next subscriber.
*Considered and rejected.* **Vertical switch = full meeting unsubscribe** — bad UX.

**Why Zustand (vs Redux Toolkit / Jotai / Recoil / Context-only).**
Zustand offers store-as-hook with minimal boilerplate; closest match to the prior Pinia design's spirit. Selector-based subscriptions ensure components only re-render on the slices they read. Module-level instantiation (no provider needed) keeps the boot sequence simple. Redux Toolkit was rejected as too heavy (action/reducer/slice ceremony for shell-scale state). Jotai's atom model would diverge from the "one store per concern" mental model the rest of the spec assumes. React Context alone re-renders all consumers on any change, defeating fine-grained reactivity.
*Considered and rejected.* **Redux Toolkit** — boilerplate. **Jotai** — atom model is a different mental shift. **React Context only** — over-renders.

---

## §14 Downstream impact

| Spec | Adjustment |
|---|---|
| `03-auth-service-spec.md` | Defines `GET /api/auth/me` shape (User payload), permission model (string codes), session lifecycle. Shell reads these unchanged. |
| `04-user-service-spec.md` | Defines `GET/PUT /api/user/preferences` (UserPreferences shape). Shell reads / debounces writes. |
| `05`–`12` (every feature spec) | Each feature's spec declares its routes (under `/platform/<feature>/...`), required permissions, i18n bundle, and any hooks it adds. Each feature CONSUMES the shell's hooks and `<PermissionGate>` for UI gating. |
| `13-vertical-template-spec.md` | The `_template/` package's `frontend/manifest.ts` MUST conform to the `VerticalManifest` interface defined here (§3.1). Includes the validation requirements + a sample manifest. Component types MUST be React, not Vue. |
| `14-...` (first concrete vertical) | Same — must conform. Adds `accent_color` if vertical has one; declares permissions, project_id_in allowlist. |
| `15-apps-api-spec.md` | Defines `GET /api/platform/verticals` and `GET /api/platform/feature-flags` endpoints (consumed by shell at boot per §10). |
| `16-apps-frontend-spec.md` | Defines `apps/frontend/main.tsx` boot script following §10's order; configures StudioClient (env-driven); initializes i18next; mounts `<RouterProvider>`. |
| `17-substitution-tests-spec.md` | Substitution tests cover all `[SUB]`-marked rows in §11 (boot, useStudio, useStudioHealth). |

---

## §15 Pre-merge checklist

- [ ] Mission + Scope present; "out of scope for v0.1" listed (hot-reload, multi-tenant, theme authoring, cross-tab sync, offline)
- [ ] Module layout (§1) enumerates every file the shell ships; React file extensions (.tsx) used
- [ ] All 11 public hooks (§2) documented with full TS signature, source store, reactivity rule, lifecycle
- [ ] `VerticalManifest` (§3.1) interface complete with all 5 contribution types + `default_project_filter` (per `01-studio-client` §11.4) + i18n + accent_color; component types use `React.ComponentType` / `LazyExoticComponent`
- [ ] `registerVertical` (§3.2) declares its 8 behaviors + `VerticalRegistrationError` type with all 5 reasons
- [ ] Boot-time discovery flow (§3.3) pinned to the apps/frontend boot path; no filesystem scan
- [ ] Route table (§4) lists every route the shell registers; loaders (§4.1) declare auth + permission; vertical-active resolution in `<PlatformShell>` Layout component
- [ ] Theming (§5) covers tokens, apply mechanism, per-vertical accent, font stack
- [ ] i18n (§6) covers engine (i18next), bundle structure, vertical merge mechanism (`addResourceBundle`), feature merge mechanism, interpolation syntax (`{{var}}`)
- [ ] Notifications (§7) covers store shape, sources, toast vs notification distinction, dedup, retention, studio-error mapping
- [ ] Permissions (§8) covers format convention, source, `<PermissionGate>` API with children + fallback prop, hide-on-deny behavior
- [ ] Layout components (§9) enumerated with slot structure and `<Outlet>` + `<Suspense>` for lazy routes
- [ ] Boot sequence (§10) is the authoritative ordering for `apps/frontend/main.tsx`; notes Zustand module-level init (no provider)
- [ ] Test matrix (§11) covers every hook, every registration scenario, every route loader, every boot scenario; substitution-eligible tests marked `[SUB]`
- [ ] i18n strings (§12) lists every user-visible key with `en` value (Chinese mirror documented separately in shell's repo); interpolation uses i18next `{{var}}` syntax
- [ ] Why-this / Why-not blocks (§13) for every load-bearing decision (≥ 11 documented including Zustand choice + React Router data API choice)
- [ ] Downstream impact (§14) lists every spec affected
- [ ] No business / domain / product / agent-role string literal anywhere (uses neutral `vertical-a`, `v-b`, etc.)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No `Record<string, any>` / `unknown` / `any` without inline justification (used `Record<string, string>` for i18n bundles which is intentional and typed-as-such)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/02-platform-shell-spec.md`
