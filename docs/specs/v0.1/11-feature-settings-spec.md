# 11 — `settings` feature v0.1 spec

> **Status**: v0.1 contract for the user-settings UI (React).
> **Lives at**: `packages/platform-features/settings/`.
> **Consumes**: `02-platform-shell-spec.md` §2.1–§2.10 (hooks for user / theme / i18n / vertical / notifications); `03-auth-service-spec.md` (account info + password-change + sign-out-all); `04-user-service-spec.md` §3 (`PATCH /api/user/preferences`).
> **Forwarded to from**: `02-platform-shell-spec.md` `<UserMenu>` "Settings" link + sidebar nav entry.
> **Supersedes**: the Vue version of this spec; React migration per session decision 2026-05-03.

---

## Mission

This file defines the settings feature — the single UI panel where users manage their own preferences (theme, locale, default vertical, notifications) and account (display name, email, password). All persistence is delegated to existing services (`03-auth-service-spec.md` for account, `04-user-service-spec.md` for preferences) and existing shell hooks. Settings introduces zero new backend endpoints, zero new SQLite tables, zero new permissions — it is a presentation layer that wraps what `02 / 03 / 04` already commit to.

**Hard rule** (P4 + minimal-feature discipline): settings adds no state of its own. It does not cache, it does not duplicate the `User` shape, it does not store anything in localStorage. Every change goes through a hook defined in `02`; every read uses `useUser().user`. If a future feature wants to add settings (e.g., per-vertical advanced flags), it adds them via the existing `UserPreferences` schema in `04` + a new `<XxxSection>` in this package — the framework is additive.

---

## Scope

**Covers.**
- Module layout under `packages/platform-features/settings/`.
- 2 routes: `/platform/settings` (defaults to Account section), `/platform/settings/:section` (direct deep link).
- 5 section components, each a self-contained form: `<AccountSection>`, `<AppearanceSection>`, `<VerticalSection>`, `<NotificationsSection>`, `<AboutSection>`.
- Supporting components: `<SettingsView>` (top-level shell), `<SettingsSidebar>` (section navigation), `<SectionHeader>`, `<SaveIndicator>`, `<ChangePasswordForm>`, `<SignOutAllDialog>`.
- 1 hook owned by this package: `useChangePassword` (wraps `POST /api/auth/change-password`).
- Save semantics: auto-save (debounced 500 ms) for toggleable preferences; form-style (explicit Submit) for password change.
- Section-level error display + per-field validation feedback.
- Test matrix per section + per save flow.
- v0.2 forward-compat: any new preference field added to `UserPreferences` (per `04`) gets a section in this view; the hook wiring is identical.

**Does not cover.**
- The `UserPreferences` schema — `04-user-service-spec.md` §2.2 owns it.
- Auth endpoints (sign in / sign up / password change wire) — `03-auth-service-spec.md` §6 owns them.
- The 11 shell hooks — `02-platform-shell-spec.md` §2 owns them. Settings calls them.
- Vertical-specific settings panels (e.g., a vertical's per-user data-feed config). v0.2 may add a `vertical_sections` extension; out of v0.1.
- Admin settings (user management, system config). Internal-product v0.1 has no admin surface.
- Studio-side settings (paradigm tuning, model overrides). Out of product scope per P3.
- Account deletion (right-to-delete). Out of v0.1.

**Out of scope for v0.1.**
- Two-factor authentication setup.
- Sessions list ("you're signed in on N devices"). Auth-service v0.1 has sign-out-all but no per-session listing.
- Connected accounts / OAuth providers.
- Personal API tokens for product API access.
- Email notification preferences (notifications are in-app only in v0.1 per `02` §7).
- Export-my-data (GDPR-style).
- Per-section view permissions (settings is all-or-nothing for the user's own data).
- Search across settings (5 sections fits in one viewport on most desktops).

---

## §1 Module layout

```
packages/platform-features/settings/
├── src/
│   ├── index.ts                              # exports SettingsView + settingsRoutes + permissions
│   ├── SettingsView.tsx                      # top-level
│   ├── components/
│   │   ├── SettingsSidebar.tsx               # left nav: 5 section links
│   │   ├── SectionHeader.tsx                 # section title + description + SaveIndicator
│   │   ├── SaveIndicator.tsx                 # "Saving…" / "Saved" / error icon
│   │   ├── ChangePasswordForm.tsx            # the password form (used by AccountSection)
│   │   ├── SignOutAllDialog.tsx              # confirm dialog (native <dialog> + focus-trap-react)
│   │   └── sections/
│   │       ├── AccountSection.tsx
│   │       ├── AppearanceSection.tsx
│   │       ├── VerticalSection.tsx
│   │       ├── NotificationsSection.tsx
│   │       └── AboutSection.tsx
│   ├── hooks/
│   │   └── useChangePassword.ts              # wraps POST /api/auth/change-password
│   ├── routes.ts
│   ├── permissions.ts
│   └── i18n/
│       ├── zh.json
│       └── en.json
├── tests/
└── package.json
```

**No backend, no Zustand store, no SQLite table.** Settings is purely a presentation layer over existing hooks.

### 1.1 Permissions declared

```typescript
// packages/platform-features/settings/src/permissions.ts
// Settings has no feature-specific gate; access requires only authentication
// (covered by route loader's requires_auth). Listed here for clarity.
export const SETTINGS_PERMISSIONS = [] as const;
```

Every authenticated user can manage their own settings. Users cannot manage others' settings (no admin endpoints in v0.1).

### 1.2 Routes declared

```typescript
// packages/platform-features/settings/src/routes.ts
import { lazy } from "react";
import type { RouteObject } from "react-router-dom";
import { redirect } from "react-router-dom";
import { makeRequiresAuthLoader } from "@platform/shell/router/loaders";

export const SETTINGS_SECTIONS = ["account", "appearance", "vertical", "notifications", "about"] as const;
export type SettingsSection = typeof SETTINGS_SECTIONS[number];

const SettingsView = lazy(() => import("./SettingsView"));

const requiresAuth = makeRequiresAuthLoader();

export const settingsRoutes: RouteObject[] = [
  {
    path: "/platform/settings",
    loader: () => redirect("/platform/settings/account"),
  },
  {
    path: "/platform/settings/:section",
    loader: async (args) => {
      await requiresAuth(args);
      const section = args.params.section ?? "";
      if (!SETTINGS_SECTIONS.includes(section as SettingsSection)) {
        throw redirect("/platform/settings/account");
      }
      return null;
    },
    handle: { title_key: "feature.settings.title" },
    Component: SettingsView,
  },
];
```

Unknown section in URL → redirect to Account (default landing). The loader throws `redirect()` per React Router v6 data API.

---

## §2 `<SettingsView>` lifecycle

### 2.1 Component contract

```typescript
import { useParams, useNavigate } from "react-router-dom";
import { useUser } from "@platform/shell/hooks";
import type { SettingsSection } from "./routes";
import { SETTINGS_SECTIONS } from "./routes";

export default function SettingsView() {
  const { section: rawSection } = useParams<{ section: string }>();
  const section = (SETTINGS_SECTIONS.includes(rawSection as SettingsSection)
    ? rawSection
    : "account") as SettingsSection;
  const navigate = useNavigate();
  const { user, isLoading } = useUser();

  function setSection(s: SettingsSection) {
    navigate(`/platform/settings/${s}`);
  }

  if (isLoading || !user) return <FullPageSpinner />;

  return (
    <div className="settings-view">
      <SettingsSidebar active={section} onChange={setSection} />
      <main className="settings-section">
        <SectionContent section={section} />
      </main>
    </div>
  );
}

function SectionContent({ section }: { section: SettingsSection }) {
  switch (section) {
    case "account":       return <AccountSection />;
    case "appearance":    return <AppearanceSection />;
    case "vertical":      return <VerticalSection />;
    case "notifications": return <NotificationsSection />;
    case "about":         return <AboutSection />;
  }
}
```

Renders 2-column layout: `<SettingsSidebar>` (left) + active section component (right) determined by `section` URL param. Section components are imported eagerly (each is small; lazy-loading per section adds suspense flash with no benefit).

### 2.2 Status states

| State | Trigger | Visual |
|---|---|---|
| `loading_user` | `useUser().user === null && useUser().isLoading` | full-page spinner |
| `unauthenticated` | route loader catches; redirected to /login | n/a (handled by `02` §4.1) |
| `ready` | `useUser().user !== null` | full UI; section content rendered |

Settings does not have its own loading state — it shares with the shell's user-fetch boot. By the time the user navigates to settings, `user` is already loaded (or they're on /login).

---

## §3 Layout

### 3.1 Desktop (≥ 1024 px)

```
┌──────────────────── /platform/settings/<section> ─────────────────────┐
│                                                                       │
│  ┌─ Sidebar ──────┐  ┌─ Section ─────────────────────────────────┐  │
│  │  • Account     │  │   <SectionHeader> + SaveIndicator         │  │
│  │  • Appearance  │  │                                            │  │
│  │  • Vertical    │  │   (form fields)                            │  │
│  │  • Notifications│  │                                            │  │
│  │  • About       │  │                                            │  │
│  └────────────────┘  └────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────┘
```

### 3.2 Tablet (640..1023 px)

Sidebar collapses to a horizontal tab bar above the section content.

### 3.3 Mobile (< 640 px)

Sidebar becomes a top-level dropdown ("Section: Appearance ▼"); section content fills viewport.

---

## §4 Sections

For each section: mission, props/callbacks, render rules, save semantics, validation, accessibility, test rows.

### 4.1 `<AccountSection>`

```typescript
interface AccountSectionProps {
  onSignedOutAll?: () => void;       // optional callback; default behavior is router redirect
}
```

**Renders.**
- **Display name** — read-only text from `useUser().user.display_name`. (v0.1 has no rename; documented as deferral.)
- **Email** — read-only from `useUser().user.email`.
- **Authenticated at** — read-only timestamp.
- **Permissions** — collapsed list of permission codes the user has (read-only diagnostic; useful for support).
- **Change password** — embedded `<ChangePasswordForm>`.
- **Sign out everywhere** — primary danger button → `<SignOutAllDialog>` confirm → `useUser().signOutAll()` → calls `onSignedOutAll` → router redirects to /login.

**Save semantics.** Read-only fields don't save. Password is form-style (see §5.2). Sign-out-all is action-style (immediate on confirm).

**Validation.** None at this level (password form has its own — §6).

**Test rows.**

| scenario | expected | test_id |
|---|---|---|
| renders user info | display_name + email + authenticated_at + permission count visible | `t_acct_render` |
| permissions expand | click expand → full list visible | `t_acct_permissions_expand` |
| change password embedded | ChangePasswordForm rendered | `t_acct_change_password_form` |
| sign-out-all confirm | click + confirm → signOutAll called → router to /login | `t_acct_signout_all` |
| sign-out-all cancel | click + dismiss → no API call | `t_acct_signout_all_cancel` |

### 4.2 `<AppearanceSection>`

```typescript
// no props (reads from hooks); no callbacks
```

**Renders.**
- **Theme** — segmented control: Light / Dark / Follow system. Reads + writes via `useTheme()`.
- **Language** — dropdown: 中文 / English. Reads + writes via `useI18nLocale()`. On change: `setLocale(value)`; UI re-renders in new locale immediately (react-i18next reactive subscription).

**Save semantics.** Auto-save on change. The hooks (per `02` §2.9 / §2.10) internally debounce 500 ms before PATCHing `/api/user/preferences`. SaveIndicator shows "Saved" briefly after each PATCH succeeds.

**Validation.** None — both fields are constrained by union types (`"light" | "dark" | "system"`, `"zh" | "en"`).

**Test rows.**

| scenario | expected | test_id |
|---|---|---|
| renders current theme | radio for current `useTheme().mode` checked | `t_app_theme_current` |
| theme change persists | click Dark | useTheme.setMode("dark") called; CSS attr updates; debounced PATCH | `t_app_theme_change` |
| system theme follows OS | mode="system" + OS dark | resolved theme = dark | `t_app_theme_system_os` |
| locale switch | click English | useI18nLocale.setLocale("en") called; UI re-renders in en | `t_app_locale_switch` |

### 4.3 `<VerticalSection>`

```typescript
interface VerticalSectionProps {
  onVerticalChanged?: (vertical_id: string) => void;
}
```

**Renders.**
- **Default vertical** — radio list of `useActiveVertical().available` (verticals user has any permission for).
  - Each item: vertical's display_name + description + small icon.
  - Currently-active radio checked.
- **Empty state** when `available.length === 0`: "No verticals available. Contact your admin."
- **Single-vertical state** when `available.length === 1`: shows the single vertical with note "This is your only available vertical."

**Save semantics.** On selection: `useActiveVertical().switchTo(id)` → which writes to `useUserPrefs.active_vertical` (debounced PATCH per `02` §2.4). Switching navigates the router (per `02` §2.4 "navigates to vertical's default tab"); this side-effect is intentional — users see the change reflected immediately, including in the sidebar.

**Confirmation.** When switching: brief toast "Switched to <vertical name>" via `useToast().push(...)`.

**Test rows.**

| scenario | expected | test_id |
|---|---|---|
| renders available verticals | one radio per vertical | `t_vert_render` |
| current vertical checked | active vertical's radio is checked | `t_vert_current_checked` |
| switch vertical | click another | switchTo called; toast shown; sidebar updates | `t_vert_switch` |
| empty state | available.length === 0 | helpful empty state | `t_vert_empty` |
| single vertical | available.length === 1 | "only available vertical" note | `t_vert_single` |

### 4.4 `<NotificationsSection>`

```typescript
// no props; no callbacks
```

**Renders.**
- **Enable notifications** — toggle switch. Bound to `useUser().user.preferences.notifications.enabled`; writes via `useUserPrefs().patch({ notifications: { enabled: ... } })`.
- **Severities to show** — multi-select checkbox grid (info / success / warning / error).
  - Disabled when "Enable" toggle is off.
- **Note**: "Errors are always shown to avoid hiding critical issues."

**Error severity is locked-on.** The "error" checkbox is rendered as always-checked + non-interactive (with the note as `aria-describedby`). The PATCH to user-service includes "error" regardless of UI state.

**Save semantics.** Auto-save on toggle / checkbox change; debounced 500 ms via `useUserPrefs.patch`.

**Validation.**
- Cannot disable "error" severity (UI-level lock).
- "Enable notifications" off → severities checkboxes disabled but values retained (so re-enabling restores prior selections).

**Test rows.**

| scenario | expected | test_id |
|---|---|---|
| renders current state | toggle + severities reflect user prefs | `t_notif_render` |
| toggle enable | click toggle | preference PATCHed | `t_notif_toggle` |
| change severities | uncheck "info" | severities array PATCHed without "info" | `t_notif_severity_change` |
| error severity locked | click "error" checkbox | no toggle; tooltip shown | `t_notif_error_locked` |
| disabled when off | toggle off | severity checkboxes greyed; values retained | `t_notif_disabled_state_retained` |

### 4.5 `<AboutSection>`

```typescript
// no props; no callbacks
```

**Renders.**
- **Product version** — string from a build-time injected env var (`import.meta.env.VITE_PRODUCT_VERSION`); fallback `"dev"`.
- **Studio version** — `useStudioHealth().health?.studio_version` (or "unknown" if health not yet polled).
- **Engine version** — `useStudioHealth().health?.engine_version`.
- **API contract** — `useStudioHealth().health?.api_contract` (e.g. "v0.1").
- **Build date** — `import.meta.env.VITE_BUILD_DATE` (ISO timestamp; fallback "unknown").
- **Studio reachability** — green dot (live + ready) / amber (live not ready) / red (unreachable). Refresh button calls `useStudioHealth().refresh()`.
- **Footer**: link to `/healthz` (the raw endpoint) + "Report a problem" button (mailto:support placeholder; real issue tracker integration deferred).

**Save semantics.** None — purely informational.

**Test rows.**

| scenario | expected | test_id |
|---|---|---|
| renders versions | all version strings visible (or "unknown" fallback) | `t_about_render` |
| reachability indicator | health.live=true && health.ready=true → green | `t_about_reachable_green` |
| reachability degraded | health.live=true, health.ready=false → amber | `t_about_amber` |
| reachability down | health=null after error | red dot + retry button | `t_about_red_retry` |
| refresh click | click refresh | useStudioHealth().refresh() called | `t_about_refresh` |

---

## §5 Save semantics

### 5.1 Auto-save (toggle / dropdown / radio)

For sections 4.2 (Appearance), 4.3 (Vertical), 4.4 (Notifications):

1. User changes a field (controlled input `onChange`).
2. Hook (`useTheme.setMode`, `useI18nLocale.setLocale`, `useActiveVertical.switchTo`, or `useUserPrefs.patch`) is called.
3. Hook internally debounces 500 ms before sending the PATCH (via the shell's debounced PATCH queue per `02` §2.5).
4. `<SaveIndicator>` shows "Saving…" while PATCH in flight.
5. On 200 success: "Saved" for 2 s, then fades.
6. On error (4xx / 5xx / network): "Couldn't save" with retry icon; clicking retries.

**Why debounced.** A user toggling the theme back and forth shouldn't spam the API; 500 ms after the last change is the natural settle.

### 5.2 Form-style save (`<ChangePasswordForm>`)

Password change is NOT auto-saved. Submit button is required. See §6.

### 5.3 Optimistic UI

For toggles / selects: the UI updates immediately (the hook updates its store synchronously, then schedules the PATCH); on error, the field reverts to the previously-saved value AND the SaveIndicator shows "Couldn't save" with the error message.

For password change: no optimistic UI — the form awaits the PATCH and surfaces the result explicitly.

### 5.4 Concurrent edits

If the user changes Theme, then immediately changes Locale within the 500 ms debounce window: only ONE PATCH fires (with both fields), per the user-service `PATCH` endpoint's tri-state semantics (per `04` §3.3). The shell's `useUserPrefs.patch` queue consolidates pending fields into one request.

If two PATCHes race (rare but possible): per `04` §10 "concurrency: last-writer-wins". Acceptable for v0.1.

### 5.5 `<SaveIndicator>` contract

```typescript
type SaveStatus = "idle" | "saving" | "saved" | "error";

interface SaveIndicatorProps {
  status: SaveStatus;
  errorMessage?: string;        // localized; required when status === "error"
  onRetry?: () => void;         // required when status === "error"
}

export function SaveIndicator({ status, errorMessage, onRetry }: SaveIndicatorProps) {
  // status === "saved" auto-clears after 2 s via parent's setTimeout
  // (the parent owns the timer; SaveIndicator is purely presentational)
  // ... renders icon + label per status
}
```

The parent section subscribes to its hook's `saveStatus` (each shell hook exposes a `saveStatus` value derived from the last PATCH outcome) and feeds it into `<SaveIndicator>`. Per-section, not global (see §10).

---

## §6 `<ChangePasswordForm>` and `useChangePassword`

### 6.1 Form

```typescript
interface ChangePasswordFormProps {
  onChanged?: () => void;        // emitted on success
}

export function ChangePasswordForm({ onChanged }: ChangePasswordFormProps) {
  const { t } = useTranslation();
  const { change, isChanging, error } = useChangePassword();
  const [current, setCurrent] = useState("");
  const [newPwd, setNewPwd]   = useState("");
  const [confirm, setConfirm] = useState("");

  const clientErrors = useMemo(() => validateClient({ current, newPwd, confirm }), [current, newPwd, confirm]);
  const canSubmit = !isChanging && clientErrors.length === 0 && current && newPwd && confirm;

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!canSubmit) return;
    try {
      await change(current, newPwd);
      setCurrent(""); setNewPwd(""); setConfirm("");
      onChanged?.();
    } catch { /* error already in hook state; surfaced via `error` */ }
  }

  // ... renders 3 password inputs, client-side error messages, submit button, hook error
}

interface ClientError { field: "new" | "confirm"; key: string; }

function validateClient(args: { current: string; newPwd: string; confirm: string }): ClientError[] {
  const errs: ClientError[] = [];
  if (args.newPwd && args.newPwd.length < 8) {
    errs.push({ field: "new", key: "feature.settings.password.req_min_length" });
  }
  if (args.newPwd && args.current && args.newPwd === args.current) {
    errs.push({ field: "new", key: "feature.settings.password.req_not_same" });
  }
  if (args.confirm && args.confirm !== args.newPwd) {
    errs.push({ field: "confirm", key: "feature.settings.password.req_match" });
  }
  return errs;
}
```

**Fields.**
- Current password (`<input type="password">`)
- New password (`<input type="password">`)
- Confirm new password (`<input type="password">`)

**Validation (client-side).**
- All 3 required.
- New password: min 8 chars (matches `03-auth-service-spec.md` §2 password requirements).
- New password: not equal to current password.
- Confirm: must equal new password.

**Submit.**
- Disabled until all client-side validations pass.
- On click: `change(current, new)`.
- Spinner during in-flight; disabled.
- On success: clear form, show toast "Password changed successfully", call `onChanged`. (No automatic sign-out — per `03` design, sessions remain valid; user can sign out all if desired.)
- On error: show inline message; current/new fields keep values; confirm clears.

### 6.2 Hook

```typescript
export interface UseChangePassword {
  change(current_password: string, new_password: string): Promise<void>;
  isChanging: boolean;
  error: string | null;       // localized
}

export function useChangePassword(): UseChangePassword {
  const { t } = useTranslation();
  const [isChanging, setIsChanging] = useState(false);
  const [error, setError]           = useState<string | null>(null);

  async function change(current_password: string, new_password: string) {
    setIsChanging(true);
    setError(null);
    try {
      const res = await fetch("/api/auth/change-password", {
        method: "POST",
        credentials: "same-origin",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ current_password, new_password }),
      });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw mapAuthError(body, t);
      }
    } catch (e) {
      setError((e as Error).message);
      throw e;
    } finally {
      setIsChanging(false);
    }
  }

  return { change, isChanging, error };
}

function mapAuthError(body: any, t: TFunction): Error {
  switch (body?.error?.type) {
    case "invalid_current_password":
      return new Error(t("feature.settings.password.error.wrong_current"));
    case "weak_password":
      return new Error(t("feature.settings.password.error.weak", { reason: body.error.extras?.reason ?? "" }));
    case "same_as_current":
      return new Error(t("feature.settings.password.error.same_as_current"));
    case "auth_required":
      // route loader catches via interceptor; here we still surface a message
      return new Error(t("feature.settings.password.error.generic"));
    default:
      return new Error(t("feature.settings.password.error.generic"));
  }
}
```

**Behavior.**
1. POST `/api/auth/change-password` body `{current_password, new_password}`.
2. On 200: clear `error`; resolve.
3. On 401 with `error.type === "invalid_current_password"`: surface "Current password is incorrect."
4. On 400 with `error.type === "weak_password"`: surface the specific reason from extras (`min_length`, `requires_*`, etc.).
5. On other errors: surface generic "Couldn't change password" + log.

**Error mapping** (the only product-side error mapping settings owns — covers the password-specific UX):

| auth-service error type | UI message key |
|---|---|
| `invalid_current_password` | `feature.settings.password.error.wrong_current` |
| `weak_password` | `feature.settings.password.error.weak` (with extras) |
| `same_as_current` | `feature.settings.password.error.same_as_current` (defensive — also client-side checked) |
| `auth_required` | (route loader catches via interceptor; surfaces generic) |
| (other) | `feature.settings.password.error.generic` |

### 6.3 `<SignOutAllDialog>` contract

Reuses the modal pattern standardized across specs 05/08/09/10: native `<dialog>` + `focus-trap-react`.

```typescript
interface SignOutAllDialogProps {
  open: boolean;
  onConfirm: () => void;        // calls useUser().signOutAll(), then router redirect
  onCancel: () => void;
  isPending: boolean;           // disables buttons + shows spinner during signOutAll in-flight
}

export function SignOutAllDialog({ open, onConfirm, onCancel, isPending }: SignOutAllDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const el = dialogRef.current;
    if (!el) return;
    if (open && !el.open) el.showModal();
    if (!open && el.open) el.close();
  }, [open]);

  return (
    <dialog ref={dialogRef} onCancel={(e) => { e.preventDefault(); if (!isPending) onCancel(); }}>
      <FocusTrap active={open}>
        <div className="signout-all-dialog">
          <h2>{t("feature.settings.account.signout_all")}</h2>
          <p>{t("feature.settings.account.signout_all_confirm")}</p>
          <button onClick={onCancel} disabled={isPending}>
            {t("feature.settings.account.signout_all_cancel")}
          </button>
          <button onClick={onConfirm} disabled={isPending} className="danger">
            {t("feature.settings.account.signout_all_action")}
          </button>
        </div>
      </FocusTrap>
    </dialog>
  );
}
```

---

## §7 Sealed error taxonomy

Settings owns 0 leaves. Everything relays from `03-auth-service-spec.md` (account / password) and `04-user-service-spec.md` (preferences) taxonomies.

The error mapping in §6.2 is a UI-layer wrapping for a small subset of auth errors; the underlying types come from `03` §6.

---

## §8 i18n

```json
{
  "feature.settings.title":                       "Settings",
  "feature.settings.section.account":             "Account",
  "feature.settings.section.appearance":          "Appearance",
  "feature.settings.section.vertical":            "Vertical",
  "feature.settings.section.notifications":       "Notifications",
  "feature.settings.section.about":               "About",

  "feature.settings.save.saving":                 "Saving…",
  "feature.settings.save.saved":                  "Saved",
  "feature.settings.save.error":                  "Couldn't save",
  "feature.settings.save.retry":                  "Retry",

  "feature.settings.account.heading":             "Account",
  "feature.settings.account.display_name":        "Display name",
  "feature.settings.account.email":               "Email",
  "feature.settings.account.authenticated_at":    "Last sign-in",
  "feature.settings.account.permissions":         "Permissions",
  "feature.settings.account.permissions_expand":  "Show {{count}} permissions",
  "feature.settings.account.permissions_collapse":"Hide",
  "feature.settings.account.signout_all":         "Sign out everywhere",
  "feature.settings.account.signout_all_confirm": "Sign you out from every device. You'll need to sign in again.",
  "feature.settings.account.signout_all_action":  "Sign out everywhere",
  "feature.settings.account.signout_all_cancel":  "Cancel",
  "feature.settings.account.rename_unavailable":  "Display name changes are not yet supported.",

  "feature.settings.password.heading":            "Change password",
  "feature.settings.password.current":            "Current password",
  "feature.settings.password.new":                "New password",
  "feature.settings.password.confirm":            "Confirm new password",
  "feature.settings.password.submit":             "Change password",
  "feature.settings.password.success":            "Password changed successfully.",
  "feature.settings.password.req_min_length":     "At least 8 characters.",
  "feature.settings.password.req_not_same":       "Must differ from current password.",
  "feature.settings.password.req_match":          "Confirmation must match new password.",
  "feature.settings.password.error.wrong_current":"Current password is incorrect.",
  "feature.settings.password.error.weak":         "New password is too weak: {{reason}}",
  "feature.settings.password.error.same_as_current":"New password must differ from current.",
  "feature.settings.password.error.generic":      "Couldn't change password. Try again.",

  "feature.settings.appearance.heading":          "Appearance",
  "feature.settings.appearance.theme":            "Theme",
  "feature.settings.appearance.theme.light":      "Light",
  "feature.settings.appearance.theme.dark":       "Dark",
  "feature.settings.appearance.theme.system":     "Follow system",
  "feature.settings.appearance.locale":           "Language",
  "feature.settings.appearance.locale.zh":        "中文",
  "feature.settings.appearance.locale.en":        "English",

  "feature.settings.vertical.heading":            "Default vertical",
  "feature.settings.vertical.helper":             "The vertical you land in when you sign in.",
  "feature.settings.vertical.empty":              "No verticals available. Contact your admin.",
  "feature.settings.vertical.single":             "This is your only available vertical.",
  "feature.settings.vertical.switched_toast":     "Switched to {{name}}",

  "feature.settings.notifications.heading":       "Notifications",
  "feature.settings.notifications.enabled":       "Enable notifications",
  "feature.settings.notifications.severities":    "Severities to show",
  "feature.settings.notifications.severity.info":    "Info",
  "feature.settings.notifications.severity.success": "Success",
  "feature.settings.notifications.severity.warning": "Warning",
  "feature.settings.notifications.severity.error":   "Error",
  "feature.settings.notifications.error_locked":  "Errors are always shown to avoid hiding critical issues.",

  "feature.settings.about.heading":               "About",
  "feature.settings.about.product_version":       "Product version",
  "feature.settings.about.studio_version":        "Studio version",
  "feature.settings.about.engine_version":        "Engine version",
  "feature.settings.about.api_contract":          "API contract",
  "feature.settings.about.build_date":            "Build date",
  "feature.settings.about.studio_reachable":      "Studio reachable",
  "feature.settings.about.studio_degraded":       "Studio degraded",
  "feature.settings.about.studio_down":           "Studio unreachable",
  "feature.settings.about.refresh":               "Refresh",
  "feature.settings.about.unknown":               "unknown",
  "feature.settings.about.healthz_link":          "Open /healthz",
  "feature.settings.about.report_problem":        "Report a problem"
}
```

`zh.json` mirrors with translated values; same key set.

---

## §9 Test matrix

### 9.1 Section tests

Each section has 3-5 tests (covered inline in §4). Aggregating: 22 rows.

### 9.2 SettingsView routing

| scenario | expected | test_id |
|---|---|---|
| /settings → /settings/account | loader `redirect` | `t_sv_default_redirect` |
| /settings/appearance | AppearanceSection rendered | `t_sv_section_appearance` |
| /settings/unknown | loader throws redirect to /settings/account | `t_sv_unknown_section_redirect` |
| sidebar click | navigate() to clicked section | `t_sv_sidebar_nav` |

### 9.3 Save flow tests

| scenario | expected | test_id |
|---|---|---|
| auto-save shows "Saving…" then "Saved" | toggle theme | indicator transitions | `t_save_indicator_happy` |
| auto-save error shows retry | mock PATCH 500 | indicator shows "Couldn't save" + retry | `t_save_indicator_error` |
| retry click re-PATCHes | click retry on errored save | second PATCH fires | `t_save_retry` |
| optimistic UI + revert | mock PATCH error → field reverts to last saved | `t_save_optimistic_revert` |
| concurrent edits batched | toggle theme + locale within 500 ms | one PATCH with both fields | `t_save_concurrent_batched` |

### 9.4 useChangePassword tests

| scenario | expected | test_id |
|---|---|---|
| happy | change called with valid creds | resolves; calls `onChanged` | `t_cp_happy` |
| wrong current | API returns 401 invalid_current_password | error set with localized msg | `t_cp_wrong_current` |
| weak new | API returns 400 weak_password | error set with reason | `t_cp_weak` |
| same as current (client-side) | client validation blocks submit | submit disabled | `t_cp_same_as_current_client` |
| same as current (server-side defensive) | API returns 400 same_as_current | error surfaced | `t_cp_same_as_current_server` |
| in-flight isChanging | during fetch | isChanging=true; submit disabled | `t_cp_in_flight` |
| network error | fetch throws | error="Couldn't change password. Try again." | `t_cp_network` |

### 9.5 SignOutAllDialog tests

| scenario | expected | test_id |
|---|---|---|
| open shows modal | open=true | dialogRef.showModal called; trap active | `t_soad_open` |
| ESC cancels | open + ESC | onCancel called (cancel event preventDefaulted) | `t_soad_esc_cancel` |
| confirm pending disables | isPending=true | both buttons disabled | `t_soad_pending_disabled` |
| close on cancel | click cancel | onCancel called; dialog.close() | `t_soad_close_cancel` |

---

## §10 Why this design — load-bearing decisions

**Why one view with sections, not separate routes per section.**
Most users open settings to flip one switch and leave; a sidebar nav with 5 sections is faster to scan and switch than 5 separate routes. The URL still encodes the section (per §1.2) so deep links work.
*Considered and rejected.* **One route per section** — slower navigation; less scannable. **Tabs without URL state** — breaks deep linking and browser back/forward.

**Why auto-save (debounced) for toggles / selects, but form-style for password.**
Toggles and selects are reversible in one click — auto-save fits the lightweight nature. Password change is high-stakes (you must remember the new one!) — explicit Submit + clear feedback is the right ceremony.
*Considered and rejected.* **Save button for everything** — extra clicks for trivial toggles. **Auto-save passwords** — accidental keystroke could change auth.

**Why "error" severity is locked-on in `<NotificationsSection>`.**
Users disabling error notifications would silently miss critical product issues (data integrity incidents per `01-studio-client-spec.md` §8.2 IntegrityError, meeting failures, etc.). UI lock + clarifying note avoids the footgun.
*Considered and rejected.* **Allow disable** — silent failures by user mistake. **Hide the option entirely** — opaque; users wonder why they got an error notification with notifications "off".

**Why settings owns zero state (no Zustand store, no cache).**
Adding a settings-specific state cache would create a second source of truth for `User` / `UserPreferences`, requiring sync logic with the shell's existing stores. Direct read from `useUser()` + direct write through hooks is the minimum viable path.
*Considered and rejected.* **Settings-local store** — duplicates state. **Local component state mirroring user prefs** — same problem in smaller scope.

**Why no rename in v0.1.**
Auth-service v0.1 doesn't expose a `PATCH /api/auth/me` for display_name. Adding one requires touching `03`'s frozen surface (additive but still a change). Defer to v0.2 when there's a clearer use case (currently every user is the operator who registered).
*Considered and rejected.* **Add rename now** — pulls scope into `03` for a feature no one's asked for.

**Why About section exists.**
Internal-product users file support tickets. "What version are you on?" is the first question. Showing product + studio + engine + API contract versions in one place removes a friction point. Bonus: the studio reachability indicator helps users self-diagnose ("studio is unreachable" → check VPN, not "the chat is broken").
*Considered and rejected.* **Hide version info** — friction for support. **Footer-only version** — easy to miss; not actionable.

**Why optimistic UI with revert (not pessimistic).**
Settings changes feel instant when optimistic. The revert-on-error path is reachable but rare (preference saves are simple). Pessimistic (wait for PATCH success then update UI) feels laggy.
*Considered and rejected.* **Pessimistic UI** — laggy.

**Why per-section `<SaveIndicator>` (not one global).**
Saves are scoped to a section's fields. A global indicator would be ambiguous when a user changes Appearance and Notifications in quick succession ("Saved what?"). Per-section keeps the feedback localized.
*Considered and rejected.* **Global indicator** — ambiguous.

**Why no two-factor / sessions / OAuth in v0.1.**
Auth-service v0.1 doesn't support these (per `03` scope). Adding settings UI for unimplemented backend features would lie to users.
*Considered and rejected.* **Stub UI for v0.2 features** — same anti-pattern as v0.2-stub Protocol methods (rejected at the studio-client rewrite).

**Why concurrent edits are batched (not serialized).**
The user-service PATCH supports tri-state partial updates (per `04` §3.3); a single PATCH with multiple fields is atomic + cheap. Serialized PATCHes would multiply round trips for no benefit.
*Considered and rejected.* **Serial per field** — unnecessary round trips.

**Why `<SignOutAllDialog>` reuses the native `<dialog>` + focus-trap-react pattern from specs 05/08/09/10.**
A standardized modal pattern (a) reduces accessibility regressions (focus trap, ESC handling, return focus all done once), (b) keeps the bundle small (one modal primitive instead of five), (c) gives users a consistent feel across the product. Sign-out-all is destructive, so the same focus discipline matters here.
*Considered and rejected.* **Roll a settings-specific modal** — duplicates a11y work. **window.confirm** — not localizable, not styleable, blocks the main thread.

**Why eager (not lazy) section components.**
Each section is small (a few hundred lines). Lazy-loading per section adds Suspense flash on every sidebar click — a bad trade for a UI users expect to feel snappy. Lazy boundaries belong at the route level (already done in `routes.ts`); inside a route they're noise.
*Considered and rejected.* **Lazy per section** — unnecessary spinner flash.

---

## §11 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | `<UserMenu>` "Settings" link navigates to `/platform/settings`. Sidebar's "Settings" entry too. No change to spec 02 itself. Each `usePref`-style hook (theme, i18n, vertical, userPrefs) must expose a `saveStatus` value derived from the last debounced PATCH. |
| `03-auth-service-spec.md` | Settings consumes `POST /api/auth/change-password` + `POST /api/auth/logout-all` + `GET /api/auth/me`. All declared in `03` §6 already; no change needed. |
| `04-user-service-spec.md` | Settings consumes `PATCH /api/user/preferences` via shell hooks. Tri-state semantics (per `04` §3.3) used by concurrent-edit batching. |
| `15-apps-api-spec.md` | No new endpoints. Settings adds zero apps/api surface. |
| `17-substitution-tests-spec.md` | No `[SUB]` tests — settings doesn't call studio-client directly (except `useStudioHealth` for About, which is covered by `01` §7.11 substitution tests already). |

---

## §12 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (2FA, sessions, OAuth, API tokens, email prefs, export-data, account deletion, vertical-specific settings, search)
- [ ] Module layout (§1) — frontend only; no backend; no Zustand store
- [ ] 0 permissions declared (§1.1) — only requires_auth
- [ ] 2 routes (§1.2) with section validation in loader (throws `redirect()`)
- [ ] All 5 sections (§4) have render rules + save semantics + validation + test rows
- [ ] AccountSection includes the rename-deferred note + sign-out-all confirmation flow via `<SignOutAllDialog>`
- [ ] AppearanceSection auto-saves theme + locale via shell hooks
- [ ] VerticalSection delegates to `useActiveVertical().switchTo` (which handles the navigation side-effect)
- [ ] NotificationsSection LOCKS the "error" severity on (defensive against silent critical-issue suppression)
- [ ] AboutSection shows product + studio + engine + API contract versions + reachability indicator
- [ ] Save semantics (§5): debounced auto-save for toggles; form-style for password; optimistic UI with revert; concurrent-edits batched via tri-state PATCH
- [ ] `<SaveIndicator>` is presentational; parent owns the auto-clear timer
- [ ] ChangePasswordForm (§6.1): client-side validation + submit + error mapping for the 4 documented auth error types
- [ ] useChangePassword hook (§6.2) wraps POST /api/auth/change-password with localized error mapping
- [ ] SignOutAllDialog (§6.3) reuses the native `<dialog>` + focus-trap-react pattern
- [ ] 0 settings-owned error leaves (everything relays from 03 + 04)
- [ ] i18n keys (§8) for every user-visible string with en values; uses `{{var}}` interpolation
- [ ] Test matrix (§9): sections (~22), routing (4), save flow (5), useChangePassword (7), SignOutAllDialog (4); ≥ 42 rows total
- [ ] Why-this / why-not (§10) for ≥ 12 load-bearing decisions
- [ ] Downstream impact (§11) — no new endpoints; consumes existing surface
- [ ] No business / domain / product / agent-role string literals (uses neutral examples)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No new Zustand store, no settings-specific cache
- [ ] No fabrication of unimplemented features (no 2FA UI, no sessions list, etc.)
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/11-feature-settings-spec.md`
