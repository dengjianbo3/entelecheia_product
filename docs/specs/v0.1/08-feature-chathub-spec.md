# 08 — `chathub` feature v0.1 spec

> **Status**: v0.1 contract for the lightweight 1:1 chat feature. **Frontend stack**: React 18 + TypeScript + Zustand + React Router v6 + react-i18next + Tailwind, plus `react-markdown` + `remark-gfm` (already a dep from spec 05; reused for assistant messages), `focus-trap-react` (for NewChatModal — already a dep from spec 05).
> **Lives at**: `packages/platform-features/chathub/` (frontend) + `apps/api/chathub/` (sessions + messages persistence; mounted per `15-apps-api-spec.md`).
> **Consumes**: `01-studio-client-spec.md` §7.1 (`list_projects`), §7.5 (`run_meeting`), §7.8 (`subscribe_meeting`), §7.9 (`get_meeting_outcome`); `02-platform-shell-spec.md` (hooks); `03-auth-service-spec.md` (auth + permission registry).
> **Forwarded to from**: `02-platform-shell-spec.md` sidebar nav.
> **Supersedes**: the Vue version of this spec (committed in `5c5cda0`); React migration per session decision 2026-05-03.

---

## Mission

This file defines chathub — a 1:1 chat surface where the user converses with one agent at a time. Per `01-studio-client-spec.md` §15 (Batch C row), chathub is **implemented as a single-agent meeting**: the agent lives in a `ProjectSpec` with exactly one `AgentMemberRef` and a low-friction paradigm (`react`); each user message starts a **new short meeting** with prior history prepended into the meeting's `topic`. Product-side persists the chat session + message log so users see continuity even though studio sees independent meetings.

**Hard rule** (the v0.1 honest workaround): studio v0.1 has no `inject_human_input` endpoint (per `01-studio-client-spec.md` §11.2) and no agent-override on `run_meeting`. We do NOT pretend either exists. The "one meeting per turn" pattern is the cleanest v0.1 path that gives users a real chat experience without violating the contract. v0.2 (when studio adds endpoints) can switch to long-running sessions transparently — chathub's frontend contract stays the same; only the apps/api turn handler changes.

---

## Scope

**Covers.**
- Module layout: frontend feature package + apps/api `chathub` router with SQLite persistence.
- 3 routes: `/platform/chathub` (sessions list), `/platform/chathub/:session_id` (one session), `/platform/chathub/new` (sessions list with NewChatModal auto-opened).
- 8 React components: `<ChathubView>`, `<SessionList>`, `<SessionListRow>`, `<ChathubSession>`, `<ChatHistory>`, `<ChatMessageBubble>`, `<ChatInput>`, `<TypingIndicator>`, `<NewChatModal>`, `<SessionHeader>`, `<EmptyState>`.
- 3 React hooks: `useChatSessions`, `useChatSession`, `useChatAgents`.
- 7 backend endpoints under `/api/chathub/*` for session + message CRUD + send-message-and-await-response (UNCHANGED from Vue version — backend is Python).
- 2 SQLite tables (`chat_sessions`, `chat_messages`) — product-owned persistent state (UNCHANGED).
- Convention for "chat-eligible projects": `spec_id` matching `^chat-[a-z][a-z0-9_-]*$` AND visible to the active vertical (per `01-studio-client-spec.md` §11.4 + `02-platform-shell-spec.md` §3.1 `default_project_filter.project_id_in`).
- Per-turn workflow (UNCHANGED — backend logic): validate → persist user message → build context-prepended topic → `run_meeting` → subscribe + collect `MessageEmitted` content → finalize → persist assistant message → return both.
- Sealed error taxonomy (4 leaves owned by chathub; ~6 delegated) — UNCHANGED.
- Hard timeout (60s per turn server-side; 90s client-side fetch timeout); over-cap behavior.
- Privacy note: messages stored plaintext in product DB (acceptable for v0.1 internal product; documented).
- Test matrix per endpoint + per component + the per-turn workflow contract.
- v0.2 migration path documented (switch to long-running session via `inject_human_input` when studio adds it; chathub's frontend contract is unchanged).

**Does not cover.**
- Multi-agent group chat — that's agora's territory. Chathub is intentionally 1:1.
- Real-time token streaming inside a single agent response. v0.1 returns the consolidated final response when the per-turn meeting finalizes; user sees a typing indicator during the wait. v0.2 may stream `MessageEmitted` events live.
- File / image attachments in chat — out of v0.1; uploads feature is for meeting-bound materials.
- Voice / video input.
- Agent ratings / reactions / threading.
- Search across chat history (use the standard browser Find for v0.1).
- Cross-vertical chat sessions (sessions are scoped to active vertical at create time).

**Out of scope for v0.1.**
- Long-running session via `inject_human_input` — depends on studio v0.2 endpoint per `01` §11.2.
- Server-side message stream to frontend (SSE) — v0.1 uses request/response per turn.
- Encrypted-at-rest message storage. Plaintext in SQLite is acceptable for the internal-product / single-tenant assumption (per studio §1.5 + `03-auth-service-spec.md` §scope).
- Cross-device / cross-tab live sync (open the same session in two tabs → messages appear after refresh, not push).
- Bulk delete / bulk archive.
- Export chat to file (the canonical export is reports for meetings; chat is ephemeral by design).
- Per-agent system prompt overrides at session creation — that's the agent author's job (in studio's `AgentSpec.system_prompt`).

---

## §1 Module layout

### 1.1 Frontend package

```
packages/platform-features/chathub/
├── src/
│   ├── index.ts                            # exports ChathubView + ChathubSession + chathubRoutes
│   ├── ChathubView.tsx                     # /platform/chathub list view (also /new variant)
│   ├── ChathubSession.tsx                  # /platform/chathub/:session_id session view
│   ├── components/
│   │   ├── SessionList.tsx                 # list of user's sessions
│   │   ├── SessionListRow.tsx
│   │   ├── ChatHistory.tsx                 # scrollable message list with auto-follow
│   │   ├── ChatMessageBubble.tsx           # one message (user or assistant); markdown via react-markdown
│   │   ├── ChatInput.tsx                   # textarea + send button; Enter sends, Shift+Enter newline
│   │   ├── TypingIndicator.tsx             # animated dots while awaiting response
│   │   ├── NewChatModal.tsx                # native <dialog> + focus-trap-react; agent picker
│   │   ├── SessionHeader.tsx               # agent name + archive / delete actions
│   │   └── EmptyState.tsx
│   ├── hooks/
│   │   ├── useChatSessions.ts              # list / create / archive / delete sessions
│   │   ├── useChatSession.ts               # one session: load, send (90s fetch timeout), refresh
│   │   └── useChatAgents.ts                # list chat-eligible projects (the agent picker)
│   ├── stores/
│   │   ├── useChatSessionsStore.ts         # Zustand store backing useChatSessions cache
│   │   └── useChatAgentsStore.ts           # Zustand store backing useChatAgents per-vertical cache
│   ├── routes.ts
│   ├── permissions.ts
│   └── i18n/
│       ├── zh.json
│       └── en.json
├── tests/
└── package.json                            # depends on react, react-dom, react-router-dom,
                                            #            zustand, react-i18next,
                                            #            react-markdown + remark-gfm (shared with 05),
                                            #            focus-trap-react (shared with 05)
```

### 1.2 Backend module (in apps/api) — UNCHANGED FROM VUE VERSION

```
apps/api/
└── chathub/
    ├── __init__.py
    ├── api.py                              # /api/chathub/* router
    ├── models.py                           # ChatSession, ChatMessage, request/response pydantic
    ├── db/
    │   ├── tables.py                       # SQLAlchemy
    │   └── crud.py
    ├── turn.py                             # the per-turn workflow (run_meeting + subscribe + collect)
    ├── errors.py
    ├── config.py                           # CHATHUB_MESSAGES_PER_SESSION_CAP, CHATHUB_TURN_TIMEOUT_S, CHATHUB_HISTORY_TURNS_IN_TOPIC
    └── tests/
```

### 1.3 Permissions declared

```typescript
// packages/platform-features/chathub/src/permissions.ts
export const CHATHUB_PERMISSIONS = [
  { code: "platform:chathub",       description: "Use the 1:1 chat feature" },
] as const;
```

`platform:chathub` granted alongside `platform:run_meeting` to standard users.

### 1.4 Routes declared

```typescript
// packages/platform-features/chathub/src/routes.ts
import type { RouteObject } from "react-router-dom";
import { makePermissionsLoader } from "@entelecheia/platform-shell";

export const chathubRoutes: RouteObject[] = [
  {
    path: "/platform/chathub",
    lazy: async () => {
      const { ChathubView } = await import("./ChathubView");
      return { Component: ChathubView };
    },
    loader: makePermissionsLoader(["platform:chathub", "platform:list_projects"]),
    handle: { title_key: "feature.chathub.title" },
  },
  {
    path: "/platform/chathub/:session_id",
    lazy: async () => {
      const { ChathubSession } = await import("./ChathubSession");
      return { Component: ChathubSession };
    },
    loader: makePermissionsLoader(["platform:chathub", "platform:run_meeting"]),
    handle: { title_key: "feature.chathub.session_title" },
  },
  {
    path: "/platform/chathub/new",
    lazy: async () => {
      const { ChathubView } = await import("./ChathubView");
      return { Component: ChathubView };
    },
    loader: makePermissionsLoader(["platform:chathub", "platform:run_meeting"]),
    handle: { title_key: "feature.chathub.title", open_new_modal: true },
  },
];
```

`<ChathubView>` reads its `useMatches()` for the route handle to detect `open_new_modal: true` and auto-opens `<NewChatModal>`.

---

## §2 Data models (apps/api) — UNCHANGED FROM VUE VERSION

### 2.1 SQLite schema

```sql
-- chat_sessions
CREATE TABLE chat_sessions (
    session_id        TEXT PRIMARY KEY,                              -- ULID
    user_id           TEXT NOT NULL,                                  -- matches auth-service users.user_id (no FK; per 04 §10)
    chat_project_id   TEXT NOT NULL,                                  -- a studio ProjectSpec's spec_id (must match ^chat-[a-z][a-z0-9_-]*$)
    display_name      TEXT NOT NULL,                                  -- e.g. "Chat with Coach (May 2)"
    created_at        TEXT NOT NULL,                                  -- ISO-8601 UTC
    last_message_at   TEXT,                                           -- nullable until first message
    message_count     INTEGER NOT NULL DEFAULT 0,
    is_archived       INTEGER NOT NULL DEFAULT 0,
    vertical_id       TEXT NOT NULL                                   -- snapshot of active vertical at create time
);
CREATE INDEX idx_chat_sessions_user ON chat_sessions(user_id, last_message_at DESC);

-- chat_messages
CREATE TABLE chat_messages (
    message_id        TEXT PRIMARY KEY,                              -- ULID
    session_id        TEXT NOT NULL,
    role              TEXT NOT NULL CHECK (role IN ('user','assistant','system')),
    content           TEXT NOT NULL,                                  -- ≤ 4000 chars (validated at insert)
    created_at        TEXT NOT NULL,
    meeting_id        TEXT,                                           -- studio meeting that produced this message; NULL for role='user'
    error             TEXT,                                           -- non-NULL if role='assistant' AND meeting_failed; carries reason
    FOREIGN KEY (session_id) REFERENCES chat_sessions(session_id) ON DELETE CASCADE
);
CREATE INDEX idx_chat_messages_session ON chat_messages(session_id, created_at);
```

**Privacy note.** Messages stored plaintext (no column-level encryption). Acceptable for v0.1 internal-tenant product; documented as a deferred concern. Same DB instance as auth-service / user-service (separate file `./.product_data/chathub.db`) per `15-apps-api-spec.md`.

**Cap**: `message_count` per session capped at `CHATHUB_MESSAGES_PER_SESSION_CAP` (default 100). Beyond cap: `POST /messages` returns 409 `SessionMessageCapReached`; user MUST start a new session.

### 2.2 Pydantic models

```python
# apps/api/chathub/models.py — unchanged from Vue version

from datetime import datetime
from typing import Annotated, Literal
from pydantic import BaseModel, Field, StringConstraints

SessionId       = Annotated[str, StringConstraints(pattern=r"^[0-9A-HJKMNP-TV-Z]{26}$")]
MessageId       = SessionId
ChatProjectId   = Annotated[str, StringConstraints(pattern=r"^chat-[a-z][a-z0-9_-]*$", max_length=60)]
MessageContent  = Annotated[str, StringConstraints(min_length=1, max_length=4000, strip_whitespace=True)]
MessageRole     = Literal["user", "assistant", "system"]


class ChatSession(BaseModel):
    session_id:       SessionId
    user_id:          str
    chat_project_id:  ChatProjectId
    display_name:     str                                             # ≤ 200 chars
    created_at:       datetime
    last_message_at:  datetime | None
    message_count:    int
    is_archived:      bool
    vertical_id:      str


class ChatMessage(BaseModel):
    message_id:   MessageId
    session_id:   SessionId
    role:         MessageRole
    content:      str
    created_at:   datetime
    meeting_id:   str | None
    error:        str | None


# Request / response bodies same as Vue version
class CreateSessionRequest(BaseModel):
    chat_project_id:  ChatProjectId
    display_name:     str | None = None

class SendMessageRequest(BaseModel):
    content:  MessageContent

class SendMessageResponse(BaseModel):
    user_message:        ChatMessage
    assistant_message:   ChatMessage           # may have non-null `error` if turn failed
    meeting_id:          str
    turn_duration_ms:    int
```

---

## §3 Per-turn workflow (the v0.1 workaround) — UNCHANGED FROM VUE VERSION

This is the load-bearing v0.1 mechanism; backend Python logic is identical to the Vue spec. Frontend just calls the endpoint via `fetch()` with a 90s timeout.

### 3.1 Sequence (apps/api side)

```
POST /api/chathub/sessions/{session_id}/messages body = {content}

┌── apps/api/chathub/turn.py: run_turn(session_id, content) ──────────────┐
│                                                                          │
│ 1. Look up session; verify user owns it; verify is_archived = False     │
│ 2. Verify message_count < CHATHUB_MESSAGES_PER_SESSION_CAP              │
│ 3. INSERT user_message into chat_messages                                │
│ 4. SELECT recent N=CHATHUB_HISTORY_TURNS_IN_TOPIC*2 messages            │
│ 5. Build topic =                                                         │
│      "Conversation history:\n"                                           │
│      + "\n".join(f"{m.role}: {m.content}" for m in recent)              │
│      + f"\nuser: {content}"                                              │
│      (capped at 12000 chars; truncate from oldest if longer)            │
│ 6. handle = await studio.run_meeting(                                    │
│        project_id=session.chat_project_id,                               │
│        topic=topic,                                                      │
│        materials=[],                                                     │
│        user_id=session.user_id,                                          │
│    )                                                                     │
│ 7. assistant_text_chunks = []                                            │
│    async for event in studio.subscribe_meeting(handle.meeting_id):      │
│        if event.event_type == "MessageEmitted":                         │
│            assistant_text_chunks.append(event.data["content"])          │
│        elif event.event_type == "meeting_finalized":                    │
│            break                                                         │
│        elif event.event_type == "meeting_failed":                       │
│            assistant_text = "(failed)"                                   │
│            error_reason = event.data["error"]["message"]                │
│            INSERT assistant_message (error=error_reason, content="")    │
│            return SendMessageResponse(...)  # with error                │
│        # else: ignored (claims, evidence, etc. not surfaced to user)    │
│ 8. assistant_text = "\n".join(assistant_text_chunks).strip()            │
│ 9. INSERT assistant_message (content=assistant_text, meeting_id=...)    │
│10. UPDATE chat_sessions SET last_message_at=now(), message_count+=2     │
│11. return SendMessageResponse(user_message, assistant_message,          │
│                               meeting_id, turn_duration_ms)             │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘

Total wrapped in asyncio.wait_for(timeout=CHATHUB_TURN_TIMEOUT_S, default 60s):
  on timeout:
    INSERT assistant_message (error="turn_timeout", content="")
    return 504 with MeetingTimeout error envelope
```

### 3.2 Topic format rationale

Conversational paradigms (especially `react` per `01` §4.4) use the topic as the user-facing question. Prepending history is the standard pattern for stateless single-turn agent runtimes. Cap at 12000 chars; truncate from oldest if exceeded; never truncate the new user message. Truncation marker `[earlier history truncated]` prepended.

### 3.3 Failure modes per turn

| Failure | Action | UX |
|---|---|---|
| Studio unreachable (`StudioUnavailable` from `run_meeting`) | INSERT assistant_message with `error="studio_unavailable"`, content="" | bubble shows error icon + "Studio unreachable; retry" button |
| `PublishValidation` (chat project not published) | 400 to client; user message NOT persisted | toast "Chat agent unavailable" |
| `RateLimited` from studio | INSERT assistant_message with `error="rate_limited"`; surface `Retry-After` | bubble shows "Rate limited; try again in {{seconds}}s" |
| Turn timeout (60s server / 90s client) | INSERT assistant_message with `error="turn_timeout"` | bubble shows error; user can retry by sending again |
| `meeting_failed` event | INSERT assistant_message with `error=<reason>` | bubble shows error |
| All other studio errors | INSERT assistant_message with `error=<error_type>` | bubble shows generic "Something went wrong" |

Failed turns do NOT block subsequent turns; user sends another message and a new meeting starts.

---

## §4 Agent picker convention — UNCHANGED

A project is "chat-eligible" when ALL of:
1. `spec_id` matches `^chat-[a-z][a-z0-9_-]*$` (convention; v0.2 may switch to an explicit vertical-manifest field).
2. `status === "published"`.
3. Project is in active vertical's `default_project_filter.project_id_in`.

`useChatAgents()` calls `studio.list_projects({status: "published", limit: 200})` and filters client-side. Result: list of `ProjectSummary[]` representing the agents the user can chat with in this vertical.

If `agents.length !== 1` for a project matching the convention: hide it from the picker AND log a WARN ("misconfigured chat project: {project_id} has {N} agents"). Defensive.

Empty state in `<NewChatModal>`: "No chat agents available. Ask your admin to create a `chat-*` project for this vertical." No CTA — user can't fix it themselves.

---

## §5 Frontend components

### 5.1 `<ChathubView>` (sessions list)

```typescript
import { useNavigate, useMatches } from "react-router-dom";
import { useState, useMemo } from "react";
import { useChatSessions } from "./hooks/useChatSessions";

export function ChathubView() {
  const navigate = useNavigate();
  const matches = useMatches();
  const handle = matches.at(-1)?.handle as { open_new_modal?: boolean } | undefined;
  const [showNewModal, setShowNewModal] = useState(handle?.open_new_modal === true);

  const { sessions, isLoading, error, refresh, archive, deleteSession } = useChatSessions();

  function onCreated(session: ChatSession) {
    setShowNewModal(false);
    navigate(`/platform/chathub/${session.session_id}`);
  }

  // ...render header + SessionList + (showNewModal && <NewChatModal>)
}
```

**Renders.**
- Header: "Chat" + "+ New chat" primary button → opens `<NewChatModal>`.
- `<SessionList>` showing user's non-archived sessions, sorted by `last_message_at` desc.
- "Show archived" toggle (local `useState`).
- Empty state when no sessions.

### 5.2 `<SessionList>` + `<SessionListRow>`

```typescript
export interface SessionListProps {
  sessions:          ChatSession[];
  show_archived:     boolean;
  onSessionClicked:  (session_id: string) => void;
  onArchiveClicked:  (session_id: string) => void;
  onDeleteClicked:   (session_id: string) => void;     // confirm modal handled by parent
  onToggleArchived:  (show: boolean) => void;
}

export function SessionList(props: SessionListProps): React.ReactElement;
```

`<SessionListRow>` shows: chat agent name (from `display_name`), last message timestamp ("2h ago"), message count, archive icon, delete icon.

### 5.3 `<NewChatModal>`

```typescript
export interface NewChatModalProps {
  open:       boolean;
  onClose:    () => void;
  onCreated:  (session: ChatSession) => void;
}

export function NewChatModal(props: NewChatModalProps): React.ReactElement | null;
```

**Implementation.** Native `<dialog>` + `focus-trap-react` (same pattern as `05-feature-agora-spec.md` §5.7 ProvenanceModal). `useRef<HTMLDialogElement>` + `useEffect` calling `dialogRef.current?.showModal()` / `close()` based on `open`. ESC handled natively + `onCancel` calls `onClose`.

**Renders.**
- Title: "Start a new chat"
- Body: list of chat-eligible projects from `useChatAgents()` — one row each with display_name + description + agent name.
- Selecting a row + clicking "Start" calls `useChatSessions().create(chat_project_id)`, calls `onCreated(newSession)`.
- Empty state when no eligible projects (see §4).

### 5.4 `<ChathubSession>` (session view)

```typescript
import { useParams } from "react-router-dom";
import { useChatSession } from "./hooks/useChatSession";

export function ChathubSession() {
  const { session_id } = useParams<{ session_id: string }>();
  if (!session_id) throw new Error("ChathubSession requires session_id route param");

  const { session, messages, isLoading, isSending, error, refresh, sendMessage, archive } =
    useChatSession(session_id);

  // ...render SessionHeader + ChatHistory + (isSending && <TypingIndicator>) + ChatInput
}
```

**Renders.**
- `<SessionHeader>` (agent name + archive button + back link).
- `<ChatHistory>` — scrollable; auto-scrolls to bottom on new message via the same IntersectionObserver pattern from `05-feature-agora-spec.md` §5.1 DiscussionStream.
- `<TypingIndicator>` shown while `isSending`.
- `<ChatInput>` — disabled while `isSending`.

### 5.5 `<ChatHistory>` + `<ChatMessageBubble>`

```typescript
export interface ChatHistoryProps {
  messages:    ChatMessage[];        // sorted by created_at asc
  is_sending:  boolean;
}

export function ChatHistory(props: ChatHistoryProps): React.ReactElement;

export interface ChatMessageBubbleProps {
  message:        ChatMessage;
  onRetryClicked: () => void;        // only invoked when message has error AND is the latest
}

export function ChatMessageBubble(props: ChatMessageBubbleProps): React.ReactElement;
```

**Bubble visual.**
- `role === "user"`: right-aligned; user accent color.
- `role === "assistant"`: left-aligned; agent name above bubble; markdown-rendered content via `<ReactMarkdown remarkPlugins={[remarkGfm]}>` (shared dep with spec 05).
- `role === "system"`: center; gray; smaller text.
- `error !== null`: red border + error icon + retry button (last message only).

**Auto-scroll.** Same logic as `<DiscussionStream>` in `05-feature-agora-spec.md` §5.1: IntersectionObserver on bottom sentinel; follow on new messages unless user scrolled up; pill "↓ N new" appears on scroll-up.

### 5.6 `<ChatInput>`

```typescript
export interface ChatInputProps {
  disabled:        boolean;
  max_length:      number;           // 4000
  onSend:          (content: string) => void;
}

export function ChatInput(props: ChatInputProps): React.ReactElement;
```

**Implementation.**
- `useState<string>("")` for input value (controlled component).
- `<textarea>` with `onChange` updating value.
- `onKeyDown` handler:
  - Enter (no shift) → call `onSend(value.trim())` if non-empty + within max_length, then clear value
  - Shift+Enter → default behavior (newline)
- Send button disabled when `disabled`, value empty, or value > max_length. Character counter on the right.

### 5.7 `<TypingIndicator>`

Animated three-dot `...` bubble in agent's color. ARIA `aria-live="polite"` + `aria-label="Agent is responding"` so screen readers announce. Pure CSS animation; no JS interval needed.

---

## §6 API endpoints (apps/api) — UNCHANGED FROM VUE VERSION

All under `/api/chathub/*`. All require `platform:chathub` permission. All bodies / responses follow the standard error envelope per `03-auth-service-spec.md` §6.

### 6.1 `GET /api/chathub/sessions`

```
GET /api/chathub/sessions
  query:  ?include_archived={true|false} (default false), ?limit=50, ?offset=0
  auth:   required + permission "platform:chathub"
  200:    { data: list[ChatSession], total: int }
  401/403: relayed
```

### 6.2 `POST /api/chathub/sessions`

```
POST /api/chathub/sessions
  body:   CreateSessionRequest { chat_project_id, display_name? }
  auth:   required + permission "platform:chathub" + "platform:list_projects"
  200:    ChatSession
  400:    InvalidArgument (chat_project_id format wrong)
  401/403: relayed
  404:    ChatProjectNotFound (validated against studio: project must exist + be published + have spec_id matching chat-* convention)
```

### 6.3 `GET /api/chathub/sessions/{session_id}`

```
GET /api/chathub/sessions/{session_id}
  auth:   required + permission "platform:chathub"
  200:    ChatSession
  401/403: relayed
  404:    SessionNotFound (no row OR user doesn't own it; 404 not 403 to avoid existence enumeration)
```

### 6.4 `GET /api/chathub/sessions/{session_id}/messages`

```
GET /api/chathub/sessions/{session_id}/messages
  query:  ?limit=100, ?before=<ISO-8601> (paginate older messages)
  auth:   required + permission "platform:chathub"
  200:    { data: list[ChatMessage], has_more: bool }
  401/403: relayed
  404:    SessionNotFound
```

### 6.5 `POST /api/chathub/sessions/{session_id}/messages`

```
POST /api/chathub/sessions/{session_id}/messages
  body:    SendMessageRequest { content }
  auth:    required + permission "platform:chathub" + "platform:run_meeting"
  200:     SendMessageResponse { user_message, assistant_message, meeting_id, turn_duration_ms }
           (assistant_message MAY have non-null `error`; status is still 200 because the
            user message was accepted and stored)
  400:     InvalidArgument (content empty / too long)
  401/403: relayed
  404:     SessionNotFound
  409:     SessionMessageCapReached | SessionArchived
  502:     StudioUnavailable
  504:     MeetingTimeout (turn exceeded CHATHUB_TURN_TIMEOUT_S; no assistant message)
```

**Long-running.** This endpoint may take 30–60 seconds. Frontend client `fetch()` MUST use `AbortController` with a 90s `setTimeout` for the abort (see §7.2). v0.2 may switch to streaming response (SSE) once long-running sessions land.

### 6.6 `POST /api/chathub/sessions/{session_id}/archive`

```
POST /api/chathub/sessions/{session_id}/archive
  body:   { archived: bool }      # true = archive, false = unarchive
  auth:   required + permission "platform:chathub"
  200:    ChatSession (updated)
  401/403: relayed
  404:    SessionNotFound
```

### 6.7 `DELETE /api/chathub/sessions/{session_id}`

```
DELETE /api/chathub/sessions/{session_id}
  auth:   required + permission "platform:chathub"
  200:    { ok: true }
  401/403: relayed
  404:    SessionNotFound
```

Cascades messages (per FK `ON DELETE CASCADE`). Permanent. v0.1 has no soft-delete / undo.

---

## §7 Hooks

### 7.1 `useChatSessions`

```typescript
export interface UseChatSessionsReturn {
  sessions:        ChatSession[];
  isLoading:       boolean;
  error:           string | null;
  refresh():       Promise<void>;
  create(chat_project_id: string, display_name?: string): Promise<ChatSession>;
  archive(session_id: string, archived: boolean): Promise<void>;
  deleteSession(session_id: string): Promise<void>;
}

export function useChatSessions(): UseChatSessionsReturn;
```

**Behavior.** Backed by `useChatSessionsStore` Zustand store. On mount + on `useActiveVertical()` change: GET `/api/chathub/sessions`, client-side filter by `vertical_id === active_vertical.vertical_id`. Cached per-active-vertical for the session via Zustand selector keyed on vertical_id.

### 7.2 `useChatSession`

```typescript
export interface UseChatSessionReturn {
  session:    ChatSession | null;
  messages:   ChatMessage[];
  isLoading:  boolean;
  isSending:  boolean;
  error:      string | null;
  refresh():  Promise<void>;
  sendMessage(content: string): Promise<void>;
  archive(archived: boolean): Promise<void>;
}

export function useChatSession(session_id: string): UseChatSessionReturn;
```

**Behavior.**
1. On mount or `session_id` change (`useEffect([session_id])`): GET session + GET messages in parallel via `Promise.all`. AbortController cleanup on unmount.
2. `sendMessage(content)`:
   a. `setIsSending(true)`
   b. POST to send-message endpoint with `AbortController` + `setTimeout(90_000, () => ctrl.abort())` for client-side timeout
   c. On 200: append `user_message` + `assistant_message` to local state via `setMessages(prev => [...prev, ...new])`; update session's `last_message_at` + `message_count` via local merge (avoid full refetch)
   d. `setIsSending(false)`
   e. On error: surface via `setError`; toast for transient (StudioUnavailable / RateLimited)
   f. On AbortError (client timeout reached): treat as `MeetingTimeout`-equivalent
3. `refresh()`: re-fetches both session + messages from current state.

**Local state for messages**: `useState<ChatMessage[]>([])` — held per-session. Switching `session_id` resets via `useEffect([session_id])`.

**No SSE.** Per §scope, v0.1 is request/response. Other tabs won't see new messages until manual refresh.

### 7.3 `useChatAgents`

```typescript
export interface UseChatAgentsReturn {
  agents:     ProjectSummary[];     // chat-eligible projects in active vertical
  isLoading:  boolean;
  error:      string | null;
}

export function useChatAgents(): UseChatAgentsReturn;
```

**Behavior.** Backed by `useChatAgentsStore` Zustand store. On mount + active-vertical change: `studio.list_projects({status: "published", limit: 200})` → client-side filter to `spec_id.startsWith("chat-")` AND in `active_vertical.default_project_filter.project_id_in`. Cached per-vertical via Zustand selector.

---

## §8 Sealed error taxonomy (chathub-owned) — UNCHANGED

```python
# apps/api/chathub/errors.py

class ChathubError(Exception):
    error_type:  str
    http_status: int
    message:     str

# 400
class InvalidChatProject(ChathubError):     ...   # 400  — chat_project_id format wrong OR project misconfigured

# 404
class ChatProjectNotFound(ChathubError):    ...   # 404  — chat_project_id doesn't exist in studio
class SessionNotFound(ChathubError):        ...   # 404  — covers "doesn't exist" + "user doesn't own"

# 409
class SessionMessageCapReached(ChathubError): ... # 409  — extras: { cap: int }
class SessionArchived(ChathubError):        ...   # 409  — can't send to archived session

# 504
class MeetingTimeout(ChathubError):         ...   # 504  — extras: { timeout_seconds }
```

**Total leaves owned by chathub: 6.** Other failures relay through unchanged from studio-client / auth-service per `03` and `01`.

---

## §9 Configuration — UNCHANGED

```python
# apps/api/chathub/config.py
class ChathubSettings(BaseSettings):
    db_url:                              str = "sqlite:///./.product_data/chathub.db"
    messages_per_session_cap:            int = 100
    turn_timeout_s:                      int = 60
    history_turns_in_topic:              int = 10        # how many prior turns to prepend
    topic_max_chars:                     int = 12000     # truncate-from-oldest threshold

    class Config:
        env_prefix = "CHATHUB_"
```

---

## §10 i18n

```json
{
  "feature.chathub.title":             "Chat",
  "feature.chathub.session_title":     "Chat session",
  "feature.chathub.new":               "+ New chat",
  "feature.chathub.show_archived":     "Show archived",

  "feature.chathub.sessions.empty":           "No chats yet.",
  "feature.chathub.sessions.empty_action":    "Start your first chat",
  "feature.chathub.sessions.last_message":    "Last message {{time}}",
  "feature.chathub.sessions.message_count":   "{{count}} messages",
  "feature.chathub.sessions.archive":         "Archive",
  "feature.chathub.sessions.unarchive":       "Unarchive",
  "feature.chathub.sessions.delete":          "Delete",
  "feature.chathub.sessions.delete_confirm":  "Delete this chat permanently?",

  "feature.chathub.new_modal.title":          "Start a new chat",
  "feature.chathub.new_modal.start":          "Start",
  "feature.chathub.new_modal.cancel":         "Cancel",
  "feature.chathub.new_modal.empty_title":    "No chat agents available",
  "feature.chathub.new_modal.empty_body":     "Ask your admin to create a chat-* project for this vertical.",

  "feature.chathub.session.placeholder":      "Type a message…",
  "feature.chathub.session.send":             "Send",
  "feature.chathub.session.typing":           "Agent is responding…",
  "feature.chathub.session.char_count":       "{{used}}/{{max}}",
  "feature.chathub.session.cap_reached":      "This chat reached its message limit ({{cap}}). Start a new chat to continue.",

  "feature.chathub.error.studio_unavailable": "Studio is unreachable. Try again.",
  "feature.chathub.error.rate_limited":       "Rate limited. Try again in {{seconds}}s.",
  "feature.chathub.error.turn_timeout":       "The agent took too long. Try again.",
  "feature.chathub.error.meeting_failed":     "Agent failed: {{reason}}",
  "feature.chathub.error.session_archived":   "This chat is archived. Unarchive to continue.",
  "feature.chathub.error.session_not_found":  "Chat not found.",
  "feature.chathub.error.chat_project_not_found": "Chat agent unavailable.",

  "feature.chathub.bubble.retry":             "Retry",
  "feature.chathub.bubble.error_label":       "Failed"
}
```

i18next `{{var}}` interpolation. `zh.json` mirrors with Chinese.

---

## §11 Test matrix

### 11.1 Per-turn workflow (apps/api/chathub/tests/) — UNCHANGED

| scenario | preconditions | expected | test_id |
|---|---|---|---|
| happy turn | session exists; studio responds with consensus | both messages persisted; meeting_id set | `t_turn_happy` |
| empty content | content="" | 400 `invalid_argument` | `t_turn_empty` |
| over-cap | message_count = 100 | 409 `session_message_cap_reached` | `t_turn_cap` |
| archived | session.is_archived=true | 409 `session_archived` | `t_turn_archived` |
| not owner | other user's session | 404 `session_not_found` (not 403) | `t_turn_not_owner` |
| studio down | studio.run_meeting raises StudioUnavailable | 502; assistant message INSERTed with error="studio_unavailable" | `t_turn_studio_down` |
| meeting failed | meeting_failed event arrives | 200; assistant_message has error | `t_turn_meeting_failed` |
| rate limited | studio raises RateLimited | 200; assistant_message error="rate_limited"; Retry-After surfaced | `t_turn_rate_limited` |
| turn timeout | meeting takes > 60s | 504 `meeting_timeout`; assistant message INSERTed with error="turn_timeout" | `t_turn_timeout` |
| topic includes prior history | session has 4 prior turns | studio.run_meeting called with topic containing those turns | `t_turn_topic_includes_history` |
| topic truncation | history > 12000 chars | oldest turns dropped; "[earlier history truncated]" prepended; new message present | `t_turn_topic_truncated` |
| MessageEmitted concatenation | 3 MessageEmitted events | assistant content = `e1\ne2\ne3` | `t_turn_message_concat` |
| ignore non-MessageEmitted | ClaimMade / EvidenceCited mixed in | only MessageEmitted concatenated | `t_turn_ignore_other_events` |

### 11.2 API endpoints — UNCHANGED

| endpoint | scenario | expected | test_id |
|---|---|---|---|
| GET /sessions | happy | 200 with paged list | `t_api_list_happy` |
| GET /sessions | filter archived | only archived returned | `t_api_list_archived` |
| POST /sessions | happy | 200 with new ChatSession | `t_api_create_happy` |
| POST /sessions | bad chat_project_id format | 400 | `t_api_create_bad_format` |
| POST /sessions | project not in studio | 404 `chat_project_not_found` | `t_api_create_not_found` |
| POST /sessions | project has 2 agents (misconfigured) | 400 `invalid_chat_project` | `t_api_create_misconfigured` |
| GET /sessions/{id} | own session | 200 | `t_api_get_own` |
| GET /sessions/{id} | other user's | 404 `session_not_found` | `t_api_get_isolation` |
| GET /sessions/{id}/messages | happy paginated | 200 with has_more | `t_api_list_messages_paginated` |
| POST /archive | happy | session updated | `t_api_archive_happy` |
| POST /archive | idempotent | second archive call ok | `t_api_archive_idempotent` |
| DELETE | cascades | session + messages gone | `t_api_delete_cascade` |

### 11.3 Frontend components

| scenario | expected | test_id |
|---|---|---|
| ChathubView mounts with sessions | list rendered; "+ New chat" visible | `t_cv_mount` |
| New chat modal opens from /new route | useMatches() handle.open_new_modal=true → modal opens | `t_cv_new_route_opens_modal` |
| NewChatModal empty state | no chat agents | helpful empty state | `t_ncm_empty` |
| NewChatModal native dialog | dialogRef.current?.showModal() called when open | `t_ncm_dialog_open` |
| NewChatModal ESC closes | onCancel handler → onClose | `t_ncm_esc` |
| Create session navigates | session created; navigate("/platform/chathub/<id>") | `t_cv_create_navigates` |
| ChathubSession mounts | session + messages load in parallel; AbortController cleanup on unmount | `t_cs_mount_parallel` |
| Send message UI flow | type + Enter → typing indicator → assistant bubble | `t_cs_send_ui_flow` |
| Send disabled while sending | send button disabled; input disabled | `t_cs_send_disabled` |
| Cap reached UI | message_count = 100 | input disabled; cap notice shown | `t_cs_cap_ui` |
| Failed message bubble | message has error | red border + retry button | `t_cs_error_bubble` |
| Retry on last failed | retry button click | resends content; new turn | `t_cs_retry_last_failed` |
| Auto-scroll on new message | history scrolls (IntersectionObserver pattern from 05) | `t_cs_auto_scroll` |
| Pause on user scroll | scroll up; new msg arrives | "↓ 1 new" pill | `t_cs_scroll_pause` |
| Markdown render in assistant bubble | content with `**bold**` | bold rendered via react-markdown | `t_cs_markdown_render` |
| Enter sends, Shift+Enter newline | onKeyDown handler | distinct behavior | `t_cs_keyboard_handler` |
| Client timeout fires | fetch hung > 90s | AbortController fires; error="turn_timeout" surfaced | `t_cs_client_timeout` |
| Archive from header | confirms; list updates | `t_cs_archive` |

---

## §12 Why this design — load-bearing decisions

**Why "one meeting per turn" and not a long-running session.**
Studio v0.1 has no `inject_human_input` endpoint (per `01-studio-client-spec.md` §11.2). A long-running session would require either pretending the endpoint exists (lying to the UI) OR keeping a single meeting open for the whole conversation and never injecting user turns (impossible). One meeting per turn is the only path that respects the contract AND gives users a real chat experience.
*Considered and rejected.* **Defer chathub to v0.2** — leaves users with no chat for the entire v0.1 lifetime; chat is a high-frequency UX. **Pretend `inject_human_input` exists with a stub** — violates the explicit "no v0.2 stub methods" decision (1A from 01 rewrite session).

**Why the chat project naming convention `chat-<name>` (not vertical-manifest declaration).**
Vertical manifest is a frozen interface (per `02-platform-shell-spec.md` §3.1); adding a `chat_projects` field is a v0.x minor bump that propagates through every vertical. A naming convention requires zero shell change and works on day 1. v0.2 can promote to an explicit field additively when the convention proves out.
*Considered and rejected.* **Add `chat_projects` to VerticalManifest now** — couples the convention to a manifest interface change before we know if it's right.

**Why we concatenate ALL `MessageEmitted` events (not just the final).**
React paradigm emits multiple intermediate "thinking" + a final answer. Identifying "the final" requires either a meta-event from studio (doesn't exist) or pattern matching (fragile). Concatenation is honest about what the agent said. v0.2 may add a "Hide reasoning" toggle.
*Considered and rejected.* **Show only last MessageEmitted** — drops legitimate content for paradigms that emit intermediate user-facing replies.

**Why per-session SQLite (not in-memory / not on agora's `meeting_metadata` table).**
Sessions persist across page reloads and across sign-in sessions. In-memory loses state. Reusing `meeting_metadata` (from `05-feature-agora-spec.md` §7) would conflate two concepts (chat sessions are not "meetings" from product's perspective; they're conversations that happen to use meetings underneath). Separate table = clear semantics + independent cap policies.
*Considered and rejected.* **In-memory** — UX regression. **Reuse meeting_metadata** — semantic confusion + cap conflicts.

**Why 60s server timeout + 90s client fetch timeout + 100 messages per session cap.**
Server: 60s budget for agent reasoning; longer suggests stuck meeting. Client: 90s gives 30s buffer beyond server timeout for network jitter (server should respond with 504 first; client only fires if response itself is hung). Cap 100 msg / session: bounds topic-prepending cost; beyond 100 msg, response quality degrades anyway because context is overwhelmed.
*Considered and rejected.* **Equal client+server timeouts** — race condition (client could abort while server is responding). **No client timeout** — UI hangs forever on network black hole.

**Why request/response per turn (no SSE streaming) in v0.1.**
SSE-streaming agent tokens to the frontend requires either (a) studio supports token-level streaming (it emits per-`MessageEmitted` events, not per-token) or (b) apps/api fakes streaming by buffering. Either way: complexity vs. v0.1 typing-indicator UX is a tossup. Request/response is simpler + works. v0.2 can stream when long-running sessions land.
*Considered and rejected.* **SSE per turn** — apps/api needs a streaming endpoint; frontend needs an EventSource hookup; for ~10s turns the typing indicator is good enough.

**Why session is bound to vertical at create time, not re-evaluated per turn.**
A session started in vertical A continues to work after the user switches verticals. Otherwise switching breaks open chats — bad UX. The vertical_id is a snapshot for filtering display, not a runtime gate.
*Considered and rejected.* **Re-validate vertical per turn** — surprising failures after switching.

**Why messages stored plaintext.**
Internal product, single-tenant, same DB as auth (which stores password hashes — also sensitive). Adding column-level encryption requires KMS / key rotation procedures that are out of v0.1 scope. Documented as a v0.2 deferral.
*Considered and rejected.* **Encrypt-at-rest in v0.1** — pulls in key management complexity disproportionate to v0.1 scope.

**Why 404 (not 403) when user doesn't own a session.**
Avoids leaking session existence. Standard practice for user-scoped resources.
*Considered and rejected.* **403** — implies the resource exists; informational leak.

**Why DELETE is hard delete, not soft delete.**
Chat is ephemeral by design (per scope). Soft delete adds operational complexity (cleanup script, "deleted but visible to admin" UX) for a feature that has no audit-trail value at the message level. Studio retains the underlying meetings forever per studio §9.2; if audit ever matters, it's there.
*Considered and rejected.* **Soft delete** — unjustified complexity.

**Why `<NewChatModal>` uses native `<dialog>` + focus-trap-react (vs. Radix UI / Headless UI).**
Same rationale as `05-feature-agora-spec.md` §10's `<ProvenanceModal>` decision — narrow modal need + native browser focus management + minimal dep cost. Reuses focus-trap-react which is already a shared dep with spec 05. No new bundle cost.
*Considered and rejected.* **Radix UI Dialog** — over-engineered for a single modal in chathub. **Hand-rolled focus trap** — focus management is non-trivial; focus-trap-react has it.

**Why `useChatSession` uses `AbortController + setTimeout` for client-side timeout (vs. `fetch` natural timeout).**
`fetch()` has no built-in timeout in React/browser. AbortController + 90s setTimeout is the canonical pattern. Server's 60s timeout responds with 504 first under normal conditions; the client 90s is a safety net for network black holes (which shouldn't happen but do).
*Considered and rejected.* **No client timeout** — UI hangs forever if network drops mid-response. **Client < server timeout** — race; client aborts while server is mid-response.

---

## §13 v0.2 migration path

When studio adds `inject_human_input` (per `01` §11.2):

1. apps/api `chathub/turn.py` switches strategy: per session, maintain ONE long-running meeting (started on `POST /sessions`, terminated on archive / delete / cap-reach).
2. `POST /messages` calls `inject_human_input(meeting_id, content)` instead of `run_meeting`.
3. Apps/api opens an SSE proxy from studio's `subscribe_meeting` to the frontend; tokens stream live.
4. Frontend's `useChatSession.sendMessage` switches to read SSE; assistant bubble fills as tokens arrive.
5. The product-side `chat_messages` table stays — used as cache / search / audit; meetings become the live source.
6. Topic-prepending in `turn.py` becomes obsolete — studio retains conversation history within the live meeting.

Frontend contract (component props, hook signatures, route paths) is **unchanged**. UI rendering, session list, archive, delete: all the same. The change is invisible to the user except for "chat now streams live."

This migration path is a hard requirement that v0.1 must not foreclose. None of the v0.1 design choices block it.

---

## §14 Downstream impact

| Spec | Adjustment |
|---|---|
| `02-platform-shell-spec.md` | No change. `useStudio()` + `useActiveVertical()` consumed unchanged. `makePermissionsLoader([...])` already added in spec 07 §1.2. |
| `03-auth-service-spec.md` | New permission `platform:chathub` registered at boot via `apps/api/main.py`. |
| `13-vertical-template-spec.md` | Vertical's `default_project_filter.project_id_in` MAY include `chat-*` projects to surface them in chathub. v0.2 may add an explicit `chat_projects` field (see §12). |
| `15-apps-api-spec.md` | Mounts `/api/chathub/*` router; runs Alembic migrations for `chathub.db`; declares `CHATHUB_*` env vars. |
| `16-apps-frontend-spec.md` | `react-markdown` + `remark-gfm` + `focus-trap-react` already declared as deps for spec 05; reused — no new dep. |
| `17-substitution-tests-spec.md` | The per-turn workflow (§3) test suite runs against PseudoStudioClient; v0.2 adds HttpStudioClient runs. |

---

## §15 Pre-merge checklist

- [ ] Mission + Scope present; out-of-scope listed (long-running, SSE streaming, file attachments, voice, group chat, search, encryption-at-rest, cross-tab sync)
- [ ] Module layout (§1) covers frontend feature (.tsx) + apps/api router (Python; unchanged)
- [ ] Permissions (§1.3) declared (`platform:chathub`); list_projects + run_meeting noted as required dependencies
- [ ] Routes (§1.4) cover list / session detail / new modal; React Router v6 RouteObject + lazy() + makePermissionsLoader; /new route uses handle.open_new_modal consumed by useMatches()
- [ ] SQLite schema (§2.1) has 2 tables with FK + indexes; cap documented (UNCHANGED)
- [ ] Pydantic models (§2.2) typed with constraints (UNCHANGED)
- [ ] Per-turn workflow (§3) documented step-by-step including failure modes; topic format pinned (UNCHANGED — backend logic)
- [ ] Agent picker convention (§4) explained including the misconfigured-project defensive log (UNCHANGED)
- [ ] All 8 frontend components (§5) with full TS Props interface + onXxx callback props + render rules + accessibility; ChatInput's onKeyDown handler explicit; NewChatModal uses native dialog + focus-trap-react
- [ ] All 7 API endpoints (§6) with method + path + body + auth + status + error mapping (UNCHANGED)
- [ ] All 3 hooks (§7) with signatures + behavior contract; useChatSession.sendMessage uses AbortController + 90s setTimeout for client timeout
- [ ] Sealed error taxonomy (§8): 6 leaves owned by chathub; relayed leaves enumerated (UNCHANGED)
- [ ] Configuration (§9): every env var declared with default (UNCHANGED)
- [ ] i18n keys (§10) for every user-visible string with `{{var}}` interpolation
- [ ] Test matrix (§11): turn workflow (~13, UNCHANGED), API (~12, UNCHANGED), components (~17 with new client-timeout + dialog tests); ≥ 40 rows
- [ ] Why-this / why-not (§12) for ≥ 8 load-bearing decisions including React-specific ones (native dialog + focus-trap-react reuse from 05; AbortController+setTimeout client timeout)
- [ ] v0.2 migration path (§13) explicit; v0.1 design choices verified non-blocking; frontend contract preserved
- [ ] Downstream impact (§14) lists every spec affected; notes shared deps (react-markdown / focus-trap-react) with 05
- [ ] No business / domain / product / agent-role string literals (uses neutral `chat-coach`, `Coach`, `agent-X`, etc.)
- [ ] No `from entelecheia` / `import entelecheia`
- [ ] No `try: ... except Exception: pass` patterns
- [ ] No pretense of `inject_human_input` existing in v0.1
- [ ] `bash scripts/check-purity.sh` exits 0
- [ ] File path matches `docs/specs/v0.1/08-feature-chathub-spec.md`
