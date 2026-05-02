# 16 — `apps/frontend` v0.1 spec

> **Status**: v0.1 contract for the React + Vite application shell.
> **Lives at**: `apps/frontend/`.
> **Consumes**: `02-platform-shell-spec.md` §10 (the canonical 11-step boot sequence), §3 (`registerVertical`), §4 (router contract); `01-studio-client-spec.md` §10 (StudioClient construction); `03-auth-service-spec.md` §6 (`GET /api/auth/me`); `04-user-service-spec.md` §3 (`GET /api/user/preferences`); `15-apps-api-spec.md` §boot (`GET /api/platform/verticals`, `GET /api/platform/feature-flags`).
> **Forwards to**: every feature spec (05-12) — they ship as packages consumed here as workspace members; every vertical spec (13/14) — discovered + dynamically imported here.

---

## Mission

This file defines the Vite-built React 18 single-page application that is the **only entry point** end-users hit in their browser. It owns: the static `index.html` shell; the `main.tsx` boot orchestrator that implements `02-platform-shell-spec.md` §10's 11-step sequence (auth fetch → preferences → vertical discovery → dynamic vertical imports → router build → mount); the `vite.config.ts` build + dev-server configuration (including the `/api/*` proxy to apps/api); the env-driven studio-client construction (Pseudo vs Http); the design-token CSS that the shell's `useTheme()` toggles via `<html data-theme="...">`; the test infrastructure (Vitest + React Testing Library + jsdom). It does **not** own any feature UI — every visible component lives in a `packages/platform-features/<name>/` or `packages/verticals/<id>/` package and is referenced through routes contributed by the shell + the discovered verticals.

**Hard rule** (P4 + P9 + Red Line #2): apps/frontend ships zero feature code. It is a glue layer. It contains no `if (vertical_id === "...")`, no business strings, no studio URL literals, no API call beyond the four documented platform fetches in step 4 of §10. The whole point is that swapping `PseudoStudioClient` ↔ `HttpStudioClient` (per `01` §10), or installing/uninstalling a vertical package (per `13` §1), changes nothing in this app — only the data the shell hooks return changes.

---

## Scope

**Covers.**
- Module layout under `apps/frontend/` (Vite single-page app, TypeScript strict).
- `index.html` — static shell with `<div id="root">`, font preload, no business chrome.
- `main.tsx` — entry script implementing every step of `02` §10 with explicit error handling.
- `vite.config.ts` — build + dev-server config, alias map for workspace packages, dev `/api` proxy.
- Env-driven `StudioClient` construction (`VITE_STUDIO_CLIENT_MODE` ∈ `pseudo` | `http`).
- Design-token CSS files (`src/styles/tokens.css`, `theme-light.css`, `theme-dark.css`) consumed by the shell's `useTheme()`.
- i18next bootstrap (platform bundles only at this stage; vertical bundles merged later by `registerVertical`).
- Router build helper that combines `02`'s baseline routes + each registered vertical's tab routes.
- Tailwind CSS configuration with the workspace's design tokens.
- Sealed error taxonomy at the boot layer (`AppBootError`).
- Build chunk strategy (vendor split, per-vertical async chunks via dynamic import).
- Test infrastructure (Vitest + jsdom + React Testing Library) — config + first-class boot-tests.
- Test matrix per boot step + per failure mode.
- v0.2 forward-compat notes (route lazy upgrade once React Router ships dynamic route addition).

**Does not cover.**
- Any individual hook, layout slot, or component — `02-platform-shell-spec.md` owns those.
- Any feature route or panel — features (05–12) own those.
- Any vertical contribution — verticals (13/14/...) own those.
- HttpStudioClient implementation — `01-studio-client-spec.md` §10.4 owns it; this spec only chooses between Pseudo and Http via env.
- Backend FastAPI surface — `15-apps-api-spec.md` owns it.
- Authentication flows beyond `/api/auth/me` — `03-auth-service-spec.md` owns sign-in/sign-up/sign-out.
- Production deployment topology (CDN, edge cache, blue/green) — out of v0.1 application scope; ship plan tracked separately.
- E2E test runner (Playwright et al.) — the e2e scenarios live in `18-end-to-end-scenarios-spec.md`; this spec owns unit/component test infra only.

**Out of scope for v0.1.**
- Server-side rendering. The product is internal-tool-grade; SPA + dev/login redirect is sufficient.
- Service worker / offline mode. Requires careful cache-invalidation design with studio's event stream; deferred.
- Code-splitting beyond the route-level `lazy()` already in feature specs + per-vertical async chunks.
- Runtime telemetry SDK (Sentry, etc.). v0.1 logs to console; observability of errors is via apps/api logs.
- A11y audit harness in CI (axe). Manual audits during review; v0.2 may add automated.
- Storybook / component gallery. Components are documented inline in feature specs.

---

## §1 Module layout

```
apps/frontend/
├── package.json                       # deps + scripts; depends on every workspace package below
├── tsconfig.json                      # strict TypeScript; "moduleResolution": "bundler"
├── tsconfig.node.json                 # for vite.config.ts
├── vite.config.ts                     # build + dev server + dev proxy
├── tailwind.config.ts                 # consumes design tokens
├── postcss.config.cjs
├── vitest.config.ts                   # test runner; jsdom env
├── index.html                         # static shell (no chrome; just <div id="root">)
├── public/
│   ├── favicon.svg
│   └── (no other assets in v0.1; verticals ship their own assets via their dynamic chunk)
├── src/
│   ├── main.tsx                       # boot orchestrator (the 11-step §10 sequence)
│   ├── boot/
│   │   ├── studioClient.ts            # buildStudioClient(env) — Pseudo vs Http per VITE_STUDIO_CLIENT_MODE
│   │   ├── i18n.ts                    # initI18n() — platform bundles only at boot; setLocale() later
│   │   ├── router.ts                  # buildRouter(verticalRoutes) — combines shell + verticals
│   │   ├── verticals.ts               # discoverAndRegisterVerticals() — fetch + dynamic-import + register
│   │   ├── errors.ts                  # AppBootError sealed taxonomy
│   │   └── shutdown.ts                # disposeAndReboot() — used by 401 handler to soft-reboot
│   ├── styles/
│   │   ├── tokens.css                 # CSS custom properties (colors, spacing, radii, shadows)
│   │   ├── theme-light.css            # default theme overrides
│   │   ├── theme-dark.css             # [data-theme="dark"] overrides
│   │   └── globals.css                # CSS reset + Tailwind directives
│   ├── env.d.ts                       # typed import.meta.env
│   └── vite-env.d.ts                  # Vite ambient types
└── tests/
    ├── boot.spec.tsx                  # main.tsx boot scenarios
    ├── router.spec.tsx                # buildRouter unit tests
    ├── verticals.spec.tsx             # discoverAndRegisterVerticals scenarios
    └── studioClient.spec.ts           # buildStudioClient env switching
```

### 1.1 package.json (key parts)

```json
{
  "name": "entelecheia-product-frontend",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev":      "vite",
    "build":    "tsc -p tsconfig.json --noEmit && vite build",
    "preview":  "vite preview",
    "test":     "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "react":            "^18.3.0",
    "react-dom":        "^18.3.0",
    "react-router-dom": "^6.26.0",
    "i18next":          "^23.11.0",
    "react-i18next":    "^14.1.0",
    "zustand":          "^4.5.0",
    "lucide-react":     "^0.400.0",
    "@entelecheia/platform-shell":      "workspace:*",
    "@entelecheia/studio-client":       "workspace:*",
    "@entelecheia/uploads":             "workspace:*",
    "@entelecheia/auth-service-client": "workspace:*",
    "@entelecheia/user-service-client": "workspace:*",
    "@entelecheia/feature-agora":         "workspace:*",
    "@entelecheia/feature-reports":       "workspace:*",
    "@entelecheia/feature-knowledge":     "workspace:*",
    "@entelecheia/feature-chathub":       "workspace:*",
    "@entelecheia/feature-uploads":       "workspace:*",
    "@entelecheia/feature-wizard":        "workspace:*",
    "@entelecheia/feature-settings":      "workspace:*",
    "@entelecheia/feature-observability": "workspace:*",
    "chart.js":         "^4.4.0",
    "react-chartjs-2":  "^5.2.0",
    "react-markdown":   "^9.0.0",
    "remark-gfm":       "^4.0.0",
    "@floating-ui/react": "^0.26.0",
    "focus-trap-react": "^10.2.0",
    "d3":               "^7.9.0",
    "tailwindcss":      "^3.4.0"
  },
  "devDependencies": {
    "vite":                       "^5.4.0",
    "@vitejs/plugin-react":       "^4.3.0",
    "typescript":                 "^5.5.0",
    "vitest":                     "^2.0.0",
    "@vitest/ui":                 "^2.0.0",
    "@testing-library/react":     "^16.0.0",
    "@testing-library/jest-dom":  "^6.4.0",
    "@testing-library/user-event":"^14.5.0",
    "jsdom":                      "^24.1.0",
    "msw":                        "^2.3.0"
  }
}
```

Vertical packages are NOT listed here. They are discovered at runtime per §4 (`discoverAndRegisterVerticals()`); installing a vertical means adding it to the apps/api Python entry-points, not to the frontend's package.json.

---

## §2 `index.html`

```html
<!doctype html>
<html lang="en" data-theme="light">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <meta name="color-scheme" content="light dark" />
    <link rel="icon" href="/favicon.svg" />
    <link rel="preload" as="font" href="/fonts/inter-var.woff2" type="font/woff2" crossorigin />
    <title>entelecheia-product</title>
    <script>
      // Pre-paint theme to avoid white flash. Uses ONLY localStorage hint;
      // the shell's useTheme() reconciles to the user's preference at step 6.
      (function () {
        try {
          var hint = localStorage.getItem("ent.theme.hint");
          if (hint === "dark") document.documentElement.dataset.theme = "dark";
          else if (hint === "system") {
            if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
              document.documentElement.dataset.theme = "dark";
            }
          }
        } catch (_) { /* noop; default 'light' is already set */ }
      })();
    </script>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

**Why the pre-paint script.** Without it, the page paints in light mode for a frame before main.tsx applies the dark theme — a flash of unstyled colors. The hint is written by `useTheme().setMode(...)` (per `02` §5.4 contract) every time the user changes preference. Default fallback is `light` if no hint exists.

**Why the title is generic.** Verticals can override per-route via React Router's `handle.title_key` (per `02` §4.4); but the static document title at boot is intentionally generic to avoid implying any specific vertical / business identity in the platform shell HTML.

---

## §3 `main.tsx` — the boot orchestrator

```tsx
// apps/frontend/src/main.tsx
import "./styles/globals.css";

import { createRoot, type Root } from "react-dom/client";
import { RouterProvider } from "react-router-dom";

import {
  useUserStore,
  useFeatureFlagsStore,
  useStudioStore,
  useVerticalsStore,
  useTheme,
  registerVertical,
} from "@entelecheia/platform-shell";

import { buildStudioClient } from "./boot/studioClient";
import { initI18n }          from "./boot/i18n";
import { buildRouter }       from "./boot/router";
import { discoverAndRegisterVerticals } from "./boot/verticals";
import { AppBootError }      from "./boot/errors";

let root: Root | null = null;

async function boot() {
  // STEP 1 — read env config (typed; throws if VITE_STUDIO_CLIENT_MODE missing)
  const env = readEnv();

  // STEP 2 — initialize i18next (platform bundles only)
  await initI18n({ defaultLng: env.defaultLocale });

  // STEP 3 — configure StudioClient and register it
  const studioClient = buildStudioClient(env);
  useStudioStore.getState().setClient(studioClient);

  // STEP 4 — fetch initial state in parallel (auth.me, feature-flags, verticals list)
  const [meResult, flagsResult, verticalsListResult] = await Promise.allSettled([
    fetch("/api/auth/me",                  { credentials: "same-origin" }),
    fetch("/api/platform/feature-flags",   { credentials: "same-origin" }),
    fetch("/api/platform/verticals",       { credentials: "same-origin" }),
  ]);

  // STEP 4a — handle auth
  const meRes = unwrapFetch(meResult, "auth_me_unreachable");
  if (meRes.status === 401) {
    return mountUnauthed("/login");
  }
  if (!meRes.ok) {
    throw new AppBootError("auth_me_failed", { status: meRes.status });
  }
  const user = await meRes.json();
  useUserStore.getState().setUser(user);

  // STEP 4b — feature flags (loud failure if unreachable)
  const flagsRes = unwrapFetch(flagsResult, "feature_flags_unreachable");
  if (!flagsRes.ok) throw new AppBootError("feature_flags_failed", { status: flagsRes.status });
  const flags = await flagsRes.json();
  useFeatureFlagsStore.getState().load(flags);

  // STEP 4c — verticals list (best-effort: zero verticals is a valid state per 02 §2.3)
  const verticalsRes = unwrapFetch(verticalsListResult, "verticals_list_unreachable");
  if (!verticalsRes.ok) throw new AppBootError("verticals_list_failed", { status: verticalsRes.status });
  const verticalEntries: VerticalEntry[] = await verticalsRes.json();

  // STEP 5 — dynamic-import each vertical and register
  await discoverAndRegisterVerticals(verticalEntries, registerVertical);

  // STEP 6 — apply user preferences
  useTheme.getState().setMode(user.preferences.theme_mode);              // applies CSS var + writes hint
  await initI18n({ defaultLng: user.preferences.locale });                // changeLanguage
  useVerticalsStore.getState().setActive(
    user.preferences.active_vertical
      ?? useVerticalsStore.getState().firstAvailableForUser(user.permissions)
      ?? null,
  );

  // STEP 7 — build router (vertical routes are now in useVerticalsStore)
  const router = buildRouter();

  // STEP 8 — mount
  root = createRoot(document.getElementById("root")!);
  root.render(<RouterProvider router={router} />);

  // STEP 9 — health polling begins on first <StudioHealthIndicator> mount (no explicit start here)
}

function mountUnauthed(redirectTo: string) {
  const router = buildRouter();      // /login route is part of the shell's baseline
  root = createRoot(document.getElementById("root")!);
  root.render(<RouterProvider router={router} />);
  // The router's root loader will redirect "/" → "/login?redirect=/" per 02 §4.1.
  // Suppress unused warning in v0.1: the redirectTo param is for v0.2 deep-link preservation.
  void redirectTo;
}

function readEnv() {
  const mode = import.meta.env.VITE_STUDIO_CLIENT_MODE;
  if (mode !== "pseudo" && mode !== "http") {
    throw new AppBootError("missing_env", { var: "VITE_STUDIO_CLIENT_MODE", got: mode });
  }
  return {
    studioClientMode: mode as "pseudo" | "http",
    studioBaseUrl:    import.meta.env.VITE_STUDIO_BASE_URL ?? null,
    defaultLocale:    (import.meta.env.VITE_DEFAULT_LOCALE as "zh" | "en") ?? "en",
    productVersion:   import.meta.env.VITE_PRODUCT_VERSION ?? "dev",
    buildDate:        import.meta.env.VITE_BUILD_DATE      ?? "unknown",
  };
}

function unwrapFetch(r: PromiseSettledResult<Response>, label: string): Response {
  if (r.status === "rejected") throw new AppBootError("network_error", { label, error: String(r.reason) });
  return r.value;
}

interface VerticalEntry { vertical_id: string; frontend_module_path: string; }

void boot().catch(handleFatalBoot);

function handleFatalBoot(err: unknown) {
  // Render a minimal fallback shell with the error + a reload button.
  // No feature code; no react-router; just enough to give the operator a path.
  const message = err instanceof AppBootError
    ? `${err.kind}: ${JSON.stringify(err.context)}`
    : String(err);
  document.getElementById("root")!.innerHTML = `
    <div style="font: 14px system-ui; padding: 24px; max-width: 720px; margin: 64px auto;">
      <h1 style="margin: 0 0 8px;">Application failed to start</h1>
      <p style="color:#666;">${escapeHtml(message)}</p>
      <button onclick="location.reload()" style="padding: 8px 16px; margin-top: 16px;">Reload</button>
    </div>
  `;
  console.error("[boot] fatal", err);
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, ch => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[ch]!));
}
```

**Why the boot is a single async function with explicit step numbering.** It mirrors `02-platform-shell-spec.md` §10 line-for-line; reviewers reading either spec see the same control flow. The numbered comments aren't decorative — they make the boot test matrix in §9.1 directly addressable (step 4a fail, step 5 fail, etc.).

**Why `Promise.allSettled` (not `Promise.all`) at step 4.** A network blip on the verticals list shouldn't gate auth. We unwrap each one explicitly with a labelled `AppBootError` so the fallback shell shows which fetch failed.

**Why fatal errors render a minimal HTML fallback (not a React tree).** If the boot fails before `createRoot`, React isn't running yet. Mounting a React error UI would require a working RouterProvider + the very stores that may have failed to populate. Plain HTML + "Reload" is the only honest UX in that state.

---

## §4 `boot/verticals.ts`

```typescript
// apps/frontend/src/boot/verticals.ts
import type { VerticalManifest } from "@entelecheia/platform-shell";
import { useNotificationsStore } from "@entelecheia/platform-shell";

export interface VerticalEntry {
  vertical_id:          string;
  frontend_module_path: string;        // e.g. "@entelecheia/vertical-investment/manifest"
}

export type RegisterFn = (manifest: VerticalManifest) => void;

export async function discoverAndRegisterVerticals(
  entries: VerticalEntry[],
  register: RegisterFn,
): Promise<void> {
  // Run in parallel; per-vertical failure is isolated (Red Line #4 + 02 §10 step 5c).
  await Promise.all(entries.map(async (entry) => {
    try {
      // Vite resolves dynamic-import strings statically when they match
      // pre-known patterns. We use an indirected helper so the bundler
      // doesn't try to inline every possible module: each vertical ships its
      // manifest under a stable path, declared in entry.frontend_module_path.
      const mod = await importVerticalManifest(entry.frontend_module_path);
      const manifest = mod.default as VerticalManifest;
      if (manifest.vertical_id !== entry.vertical_id) {
        throw new Error(`manifest.vertical_id mismatch: entry=${entry.vertical_id}, manifest=${manifest.vertical_id}`);
      }
      register(manifest);
    } catch (err) {
      useNotificationsStore.getState().push({
        severity: "error",
        title_key: "error.vertical_load_failure",
        title_args: { vertical_id: entry.vertical_id, reason: String(err) },
        dedupe_key: `vertical-load-${entry.vertical_id}`,
      });
      console.error(`[boot] vertical '${entry.vertical_id}' failed to load`, err);
    }
  }));
}

// Indirection point: the bundler sees `import(modulePath)` with a variable
// and falls back to runtime resolution against a small allowlist baked into
// the dev/prod build. In v0.1 we ship one allowlist entry per shipped vertical
// (declared in vite.config.ts -> verticalAllowlist). v0.2 may switch to a
// glob-driven discovery once Vite's import.meta.glob covers the pattern.
async function importVerticalManifest(modulePath: string): Promise<{ default: VerticalManifest }> {
  return await import(/* @vite-ignore */ modulePath);
}
```

**Why `@vite-ignore` on the dynamic import.** The path comes from runtime data (`/api/platform/verticals`), not static source. Without `@vite-ignore`, Vite emits a warning and refuses to chunk the module. The trade-off: each shipped vertical's manifest module must be importable by name in the running build. v0.1 enforces this by listing each vertical's package as a workspace member at build time (see §1.1 — verticals package the manifest under a stable export path, e.g. `@entelecheia/vertical-investment/manifest`); the apps/api `/api/platform/verticals` endpoint returns those paths verbatim. CI test `t_apps_fe_vertical_path_resolves` verifies the path returned for each installed vertical resolves successfully.

---

## §5 `boot/studioClient.ts`

```typescript
// apps/frontend/src/boot/studioClient.ts
import {
  PseudoStudioClient,
  HttpStudioClient,
  type StudioClient,
} from "@entelecheia/studio-client";
import { AppBootError } from "./errors";

export interface BuildStudioEnv {
  studioClientMode: "pseudo" | "http";
  studioBaseUrl:    string | null;
}

export function buildStudioClient(env: BuildStudioEnv): StudioClient {
  if (env.studioClientMode === "pseudo") {
    // Pseudo loads fixtures from /pseudo-fixtures/* served by apps/api
    // (apps/api boot copies the fixture overlay tree into a static dir).
    // No extra config required.
    return new PseudoStudioClient({
      fixtureBaseUrl: "/pseudo-fixtures",
    });
  }
  if (env.studioClientMode === "http") {
    if (!env.studioBaseUrl) {
      throw new AppBootError("missing_env", { var: "VITE_STUDIO_BASE_URL", reason: "required when mode=http" });
    }
    return new HttpStudioClient({
      baseUrl: env.studioBaseUrl,        // e.g. "https://studio.internal/v0.1"
      // auth header injection — uses cookie credentials (same-origin) by default
    });
  }
  // exhaustive — TypeScript infers the unreachable case
  const _exhaustive: never = env.studioClientMode;
  throw new AppBootError("missing_env", { var: "VITE_STUDIO_CLIENT_MODE", got: _exhaustive });
}
```

**Per `01-studio-client-spec.md` §10**: substituting Pseudo ↔ Http is a one-line change in apps/frontend's build env (`VITE_STUDIO_CLIENT_MODE=http`). No feature code changes. The substitution test matrix (`17-substitution-tests-spec.md`) verifies parity by toggling this env in a test harness.

---

## §6 `boot/router.ts`

```typescript
// apps/frontend/src/boot/router.ts
import { createBrowserRouter, type RouteObject } from "react-router-dom";

import {
  useVerticalsStore,
  shellRoutes,                 // baseline: /login, /platform/dashboard, /platform/*, /, *
} from "@entelecheia/platform-shell";

// Each platform-feature ships its own RouteObject[] under <package>/routes
import { agoraRoutes }         from "@entelecheia/feature-agora";
import { reportsRoutes }       from "@entelecheia/feature-reports";
import { knowledgeRoutes }     from "@entelecheia/feature-knowledge";
import { chathubRoutes }       from "@entelecheia/feature-chathub";
import { uploadsRoutes }       from "@entelecheia/feature-uploads";
import { wizardRoutes }        from "@entelecheia/feature-wizard";
import { settingsRoutes }      from "@entelecheia/feature-settings";
import { observabilityRoutes } from "@entelecheia/feature-observability";

export function buildRouter() {
  const verticalRoutes = useVerticalsStore.getState().buildRouteObjects();
  // verticalRoutes returns one RouteObject per vertical with children = each tab's route
  // (per 02 §3.3 step 4: "shell adds routes /<vertical_id>/<tab.route_path>").

  const routes: RouteObject[] = [
    ...shellRoutes,
    ...agoraRoutes,
    ...reportsRoutes,
    ...knowledgeRoutes,
    ...chathubRoutes,
    ...uploadsRoutes,
    ...wizardRoutes,
    ...settingsRoutes,
    ...observabilityRoutes,
    ...verticalRoutes,
    {
      path: "*",
      lazy: () => import("@entelecheia/platform-shell/NotFound"),
    },
  ];

  return createBrowserRouter(routes, { basename: "/" });
}
```

**Why router is built ONCE in v0.1.** React Router v6's `createBrowserRouter` returns an immutable router; adding routes after construction is not in the public API as of v6.26. The boot sequence (per `02` §10 step 7) deliberately builds the router AFTER all verticals register. v0.2 may switch if React Router ships dynamic addition.

---

## §7 `vite.config.ts`

```typescript
// apps/frontend/vite.config.ts
import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "VITE_");
  return {
    plugins: [react()],
    resolve: {
      // Workspace package aliases. The packages live under ../../packages/*.
      // tsconfig path aliases mirror these so editor IntelliSense agrees.
      alias: {
        "@entelecheia/platform-shell":      resolve(__dirname, "../../packages/platform-shell/src"),
        "@entelecheia/studio-client":       resolve(__dirname, "../../packages/studio-client/src"),
        "@entelecheia/uploads":             resolve(__dirname, "../../packages/uploads/src"),
        // ... (one entry per workspace package + per shipped vertical)
      },
    },
    server: {
      port: 5173,
      strictPort: true,
      proxy: {
        // /api/* → apps/api (FastAPI on :8000 by convention; per 15 §boot)
        "/api": {
          target: env.VITE_API_BASE_URL || "http://localhost:8000",
          changeOrigin: true,
        },
        // /pseudo-fixtures/* — also proxied to apps/api which serves the
        // merged fixture overlay tree from a static dir
        "/pseudo-fixtures": {
          target: env.VITE_API_BASE_URL || "http://localhost:8000",
          changeOrigin: true,
        },
      },
    },
    build: {
      outDir: "dist",
      sourcemap: true,
      rollupOptions: {
        output: {
          manualChunks(id) {
            // Vendor split: keep React + router + i18n + chart.js + d3 in distinct chunks
            if (id.includes("node_modules/react/")            ||
                id.includes("node_modules/react-dom/"))         return "vendor-react";
            if (id.includes("node_modules/react-router-dom/"))  return "vendor-router";
            if (id.includes("node_modules/i18next")            ||
                id.includes("node_modules/react-i18next/"))     return "vendor-i18n";
            if (id.includes("node_modules/chart.js/")          ||
                id.includes("node_modules/react-chartjs-2/"))   return "vendor-charts";
            if (id.includes("node_modules/d3/"))                return "vendor-d3";
            if (id.includes("packages/verticals/")) {
              // Each vertical lands in its own chunk via dynamic import
              const m = /packages\/verticals\/([^/]+)/.exec(id);
              if (m) return `vertical-${m[1]}`;
            }
          },
        },
      },
    },
  };
});
```

**Why per-vertical chunks.** A user only loads the vertical they're switching to (active vertical's chunk fetched on demand by the dynamic import in §4). Adding a new vertical doesn't grow the initial bundle. Removing a vertical removes its chunk entirely.

**Why proxy `/api` and `/pseudo-fixtures` in dev.** The frontend runs on Vite's dev server (port 5173); the backend FastAPI runs on port 8000. The proxy keeps the production same-origin shape (no CORS) for both real API calls and the Pseudo-mode fixture loads.

---

## §8 `boot/errors.ts`

```typescript
// apps/frontend/src/boot/errors.ts

export type AppBootErrorKind =
  | "missing_env"
  | "auth_me_unreachable"
  | "auth_me_failed"
  | "feature_flags_unreachable"
  | "feature_flags_failed"
  | "verticals_list_unreachable"
  | "verticals_list_failed"
  | "network_error"
  | "router_build_failed";

export class AppBootError extends Error {
  constructor(public readonly kind: AppBootErrorKind, public readonly context: Record<string, unknown> = {}) {
    super(`AppBootError(${kind}): ${JSON.stringify(context)}`);
    this.name = "AppBootError";
  }
}
```

**Sealed taxonomy.** Adding a new boot failure mode requires:
1. Add a literal to `AppBootErrorKind`.
2. Add the corresponding throw site in `main.tsx`.
3. Add a test row to §9.1.

The fallback shell's HTML rendering reads `err.kind` + `err.context` to give operators an actionable message.

---

## §9 Test matrix

### 9.1 Boot scenarios

| scenario | env / mock state | expected | test_id |
|---|---|---|---|
| happy boot, 0 verticals | auth.me 200 (zero permissions or none for verticals); verticals list `[]` | router mounts; useVerticalsStore.available=[]; empty-state route per `02` §2.3 | `t_apps_fe_boot_zero_verticals` |
| happy boot, 1 vertical | auth.me 200; verticals list `[{id:"investment",...}]` | shell renders; investment vertical's tabs in side nav | `[SUB] t_apps_fe_boot_one_vertical` |
| happy boot, 2 verticals coexist | both load OK | both registered; switcher shows both | `[SUB] t_apps_fe_boot_two_verticals` |
| auth.me 401 at boot | mock 401 | `mountUnauthed` runs; navigate to /login per `02` §4.1 | `t_apps_fe_boot_unauthed` |
| auth.me 5xx | mock 500 | AppBootError "auth_me_failed" thrown; fallback shell rendered | `t_apps_fe_boot_auth_failed` |
| auth.me network error | reject fetch | AppBootError "network_error" with label="auth_me_unreachable" | `t_apps_fe_boot_auth_unreachable` |
| feature-flags 5xx | mock 500 | AppBootError "feature_flags_failed" | `t_apps_fe_boot_flags_failed` |
| verticals list 5xx | mock 500 | AppBootError "verticals_list_failed" | `t_apps_fe_boot_vlist_failed` |
| one vertical fails dynamic-import | mock dynamic import reject | per-vertical toast pushed; other verticals load; boot continues | `t_apps_fe_boot_vertical_partial_fail` |
| every vertical fails | both imports reject | empty-state per `02` §2.3 (zero verticals registered) | `t_apps_fe_boot_vertical_total_fail` |
| missing VITE_STUDIO_CLIENT_MODE | env unset | AppBootError "missing_env"; fallback shell with var name | `t_apps_fe_boot_missing_env` |
| http mode missing studio base URL | mode=http, base unset | AppBootError "missing_env" with var=VITE_STUDIO_BASE_URL | `t_apps_fe_boot_http_no_base` |
| user prefs theme dark | user.preferences.theme_mode="dark" | step 6 sets `<html data-theme="dark">` | `t_apps_fe_boot_theme_dark` |
| user prefs locale zh | user.preferences.locale="zh" | step 6 changes i18n; UI in zh | `t_apps_fe_boot_locale_zh` |
| router built once | step 7 verified to construct exactly once | createBrowserRouter mock counted | `t_apps_fe_boot_router_once` |
| pre-paint dark theme | localStorage hint "dark" on initial HTML | `data-theme="dark"` set BEFORE main.tsx runs | `t_apps_fe_prepaint_dark` |

### 9.2 buildStudioClient

| scenario | env | expected | test_id |
|---|---|---|---|
| pseudo mode | mode=pseudo | returns PseudoStudioClient instance | `t_bsc_pseudo` |
| http mode with base URL | mode=http, baseUrl=set | returns HttpStudioClient with baseUrl | `t_bsc_http_ok` |
| http mode missing base URL | mode=http, baseUrl=null | throws AppBootError "missing_env" | `t_bsc_http_no_base` |
| invalid mode | mode="bogus" | throws AppBootError "missing_env" with got="bogus" | `t_bsc_invalid_mode` |

### 9.3 discoverAndRegisterVerticals

| scenario | inputs | expected | test_id |
|---|---|---|---|
| empty list | `entries=[]` | resolves immediately; no register calls | `t_dav_empty` |
| all succeed | 2 entries; both modules import OK; manifest IDs match | both registered | `t_dav_all_ok` |
| manifest ID mismatch | entry.id="a"; manifest.vertical_id="b" | toast pushed; not registered; other entries still try | `t_dav_id_mismatch` |
| dynamic import rejects | entry's module path 404 | toast pushed; not registered | `t_dav_import_reject` |
| one of two fails | entry A succeeds; entry B rejects | A registered, B toast | `t_dav_partial` |

### 9.4 buildRouter

| scenario | shell + features + verticals | expected | test_id |
|---|---|---|---|
| baseline routes only | no verticals | shell + 8 feature route groups + catch-all in createBrowserRouter call | `t_br_baseline` |
| with vertical routes | 1 vertical with 2 tabs | router includes /investment/* with 2 child routes | `t_br_with_vertical` |
| catch-all last | any inputs | the `path:"*"` route is always last in the array | `t_br_catchall_last` |

### 9.5 vite.config behaviour (sanity)

| scenario | expected | test_id |
|---|---|---|
| /api proxy in dev | dev server forwards `/api/*` to VITE_API_BASE_URL | `t_vite_api_proxy` |
| /pseudo-fixtures proxy | dev server forwards `/pseudo-fixtures/*` to apps/api | `t_vite_pseudo_proxy` |
| vendor chunks emitted | build output contains vendor-react / vendor-router / vendor-i18n / vendor-charts / vendor-d3 | `t_vite_vendor_chunks` |
| per-vertical chunk emitted | build with 1 vertical present produces vertical-investment chunk | `t_vite_vertical_chunk` |

### 9.6 Substitution sanity (mirrors 17 §category 1)

| scenario | expected | test_id |
|---|---|---|
| boot with VITE_STUDIO_CLIENT_MODE=pseudo, run a meeting via wizard | meeting completes against fixtures | `[SUB] t_apps_fe_pseudo_full_path` |
| boot with VITE_STUDIO_CLIENT_MODE=http, mock studio over the proxy, run a meeting | identical UX path; events arrive over SSE | `[SUB] t_apps_fe_http_full_path` |

---

## §10 Why this design — load-bearing decisions

**Why apps/frontend ships zero feature code.**
P4 (platform shell + features are stable; additive change only) demands that adding a feature or vertical never requires editing the app shell. Keeping main.tsx limited to wiring + the boot orchestration means a new feature ships as a new package; a new vertical ships via the entry-point + dynamic import path. Reviewers can verify "did this PR touch apps/frontend?" as a proxy for "did it widen the platform contract?"
*Considered and rejected.* **Embed feature route lists inline** — bloats main.tsx; every feature change touches it.

**Why a single async `boot()` function (not per-step React components).**
Boot is fundamentally sequential I/O. Modeling it as an async function with numbered comments makes the `02` §10 mapping verifiable line-by-line; pulling it into React (Suspense boundaries per step) would add ceremony and obscure the order. The single function also gives one catch site for the fatal-fallback HTML.
*Considered and rejected.* **Suspense-driven boot** — premature; v0.1 wants explicit ordering. **Multiple parallel "all of the above"** — order matters at step 6 (theme/locale must apply BEFORE first paint to avoid flash).

**Why fatal-fallback is plain HTML (not React).**
If the boot fails before `createRoot` succeeds (or the router build itself throws), React simply isn't running. A plain HTML message + Reload button is the only thing we can guarantee renders. It also forces operators to file a bug with a clear `kind:context` line they can copy-paste.
*Considered and rejected.* **React error boundary** — requires React to be running; useless for early-boot failures. **Just `console.error` + blank page** — terrible operator UX.

**Why a pre-paint inline `<script>` for theme.**
Without it, the page paints in light mode for a frame; users on dark theme see a white flash. The hint in localStorage is written by the shell's `useTheme().setMode(...)` (per `02` §5.4) every time the user changes preference. Default-light if no hint is the safest fallback.
*Considered and rejected.* **CSS-only `prefers-color-scheme`** — ignores user override. **No pre-paint** — flash on every load for dark-theme users.

**Why per-vertical chunks (not a single bundle).**
A user typically uses one vertical per session. Per-vertical chunks let them load only that. Adding a new vertical doesn't grow other users' initial download. Removing a vertical removes its bytes entirely from the build.
*Considered and rejected.* **Single bundle** — every vertical pays for every other. **Chunk per route within vertical** — over-splitting; verticals are small.

**Why `Promise.allSettled` (not `Promise.all`) at step 4.**
A network blip on one of three independent fetches shouldn't kill the others' parallelism — but each has a different failure mode (auth=401 special, flags=mandatory, verticals=mandatory). Settled + per-result unwrap with labelled errors gives surgical control.
*Considered and rejected.* **Three sequential awaits** — slower; same effect. **`Promise.all`** — first failure short-circuits; one bad fetch hides the others' status.

**Why `@vite-ignore` on the vertical dynamic import.**
The path comes from runtime data, not source. Without it, Vite warns and refuses to chunk. The trade-off is documented: each shipped vertical exports its manifest from a stable path baked into the build. v0.2 may switch to `import.meta.glob` if it grows to cover the case.
*Considered and rejected.* **Hard-coded list of vertical imports in main.tsx** — defeats the runtime-pluggable goal. **Vite's `import.meta.glob` with eager:false** — Vite inlines all matching modules into the build output regardless of whether the runtime asks for them; same problem as a single bundle.

**Why workspace packages are aliased in vite.config.ts.**
During development, edits to a feature or shell package should hot-reload immediately without a `npm link` ceremony. Vite alias + tsconfig path map = zero-overhead workspace dev. In production (built packages), the alias still resolves to the package's `dist/` via the package's `exports` field; no runtime difference.
*Considered and rejected.* **Symlinks via npm workspaces only** — works but Vite's HMR is faster + more reliable with explicit aliases.

**Why router is built ONCE at boot (not lazy / additive).**
React Router v6's `createBrowserRouter` returns an immutable router as of v6.26. Per `02` §10 step 7, vertical routes must be in the array at construction time. v0.2 may switch when React Router ships dynamic addition.
*Considered and rejected.* **Wait for the user to switch verticals before mounting their routes** — broken back/forward navigation; broken deep links.

**Why apps/frontend has its own test matrix (separate from feature specs).**
Boot is the only consumer of every step's contract. If `useVerticalsStore.firstAvailableForUser()` changes signature, the boot test catches the integration break before the feature tests do. Per-step test rows make regressions diagnosable to the line.
*Considered and rejected.* **Rely on feature tests** — they don't exercise the boot orchestration.

**Why MSW (mock service worker) is the test backend.**
Boot tests need to mock the four `fetch` calls (auth.me, feature-flags, verticals, plus pseudo-fixtures). MSW intercepts at the network layer, so the same fetch code runs in tests as in prod. Alternatives (manual `vi.spyOn(global, "fetch")`) are brittle to fetch-call shape changes.
*Considered and rejected.* **vi.spyOn on fetch** — verbose + brittle. **Custom adapter** — duplicates production code.

---

## §11 Downstream impact

| Spec | Adjustment |
|---|---|
| `01-studio-client-spec.md` | Substitution test framework (`17` category 1) toggles `VITE_STUDIO_CLIENT_MODE` and re-runs the boot; HttpStudioClient stub must accept the env-driven `baseUrl`. |
| `02-platform-shell-spec.md` | Confirms the §10 11-step sequence is honored by `main.tsx`. The shell exports `shellRoutes` (baseline route array) + `useVerticalsStore.buildRouteObjects()` consumed by `buildRouter()`. |
| `03-auth-service-spec.md` | apps/frontend issues `GET /api/auth/me` at boot step 4a; 401 path documented. |
| `04-user-service-spec.md` | User preferences land via `GET /api/auth/me`'s embedded preferences (per 03 + 04 contract); apps/frontend does not call user-service directly at boot. |
| `13-vertical-template-spec.md` | Each vertical exports its manifest from a stable path matching the apps/api `/api/platform/verticals` `frontend_module_path` value. |
| `14-vertical-investment-spec.md` | Investment ships its manifest as `@entelecheia/vertical-investment/manifest`; per-vertical chunk named `vertical-investment` is produced by Vite. |
| `15-apps-api-spec.md` | apps/api serves: `/api/auth/me`, `/api/platform/feature-flags`, `/api/platform/verticals`, `/pseudo-fixtures/*` static. The frontend's dev proxy targets apps/api at `:8000` by convention. |
| `17-substitution-tests-spec.md` | The `[SUB]` rows in §9.1, §9.6 join 17's substitution suite. |
| `18-end-to-end-scenarios-spec.md` | All e2e scenarios run against this app shell (in pseudo mode by default; http mode covered for substitution scenarios). |

---

## §12 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (SSR, service worker, runtime telemetry SDK, axe in CI, Storybook)
- [ ] Module layout (§1) shows the full apps/frontend tree; no feature code
- [ ] package.json (§1.1) lists every workspace package + every shared dep used across features (chart.js, react-markdown, focus-trap-react, d3, etc.)
- [ ] index.html (§2) is minimal: no business chrome; pre-paint theme script present
- [ ] main.tsx (§3) implements every step of `02` §10 with explicit numbered comments
- [ ] discoverAndRegisterVerticals (§4) handles empty list + per-vertical isolation + manifest-id-mismatch + dynamic-import-reject
- [ ] buildStudioClient (§5) supports `pseudo` AND `http` modes; `http` requires baseUrl
- [ ] buildRouter (§6) combines shellRoutes + every feature's routes + verticals' routes + catch-all in that order
- [ ] vite.config.ts (§7) declares `/api` AND `/pseudo-fixtures` proxies; vendor + per-vertical chunk strategy
- [ ] AppBootError (§8) is a sealed taxonomy with 9 leaves; each leaf appears in §9.1
- [ ] Test matrix (§9): boot scenarios (16 rows including substitution), studioClient (4), verticals (5), router (3), vite sanity (4), substitution (2) — ≥ 34 rows; substitution rows marked `[SUB]`
- [ ] Why-this / why-not (§10) for ≥ 11 load-bearing decisions
- [ ] Downstream impact (§11) lists every spec affected
- [ ] No feature route literals embedded in main.tsx (P4)
- [ ] No business / domain / product / agent-role string literals (P9)
- [ ] No raw studio URL literals; studio access via studio-client only (Red Line #2)
- [ ] No `from entelecheia` / `import entelecheia` (Red Line #1)
- [ ] No agent / paradigm / skill logic (Red Line #5)
- [ ] No `try { ... } catch { /* swallow */ }` patterns (Red Line #8); every boot failure path produces an AppBootError or pushes a toast
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/16-apps-frontend-spec.md`
