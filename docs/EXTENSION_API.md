# Navi Extension API

Navi supports a simple file-drop extension point: any process can write an event JSON file to `/tmp/navi/events/` and Navi will render it as a card in the floating window.

This lets private or internal tooling surface information in Navi without any code living in this repository.

## The `info` event type

Navi defines one external event type: **`info`**. It is a passive, non-interactive status card — no approve/deny buttons, no permission semantics.

### Schema

Write a JSON file to `/tmp/navi/events/<id>.json` using an atomic temp-then-rename to avoid partial reads:

```json
{
  "id":         "1749571200-a3f8c2d1e4b56789abcdef0123456789",
  "timestamp":  1749571200.0,
  "type":       "info",
  "title":      "Monthly spend",
  "body":       "$56.96 / $1,000.00  ░░░░░░░░░░ 5%",
  "description": "",
  "session_id": "abc12345-...",
  "session_name": "",
  "pid":        0,
  "cwd":        "",
  "tty":        "",
  "tool_use_id": "",
  "expires":    0
}
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | `<epoch_seconds>-<32_hex_chars>`. Use `openssl rand -hex 16` for the nonce. |
| `timestamp` | yes | Unix timestamp (float seconds). |
| `type` | yes | Must be `"info"`. |
| `title` | yes | Short card header. Keep under ~40 chars. |
| `body` | yes | Main content. Plain text; multi-line supported. Keep under ~200 chars. |
| `description` | no | Reserved for AI-generated or untrusted text. Rendered with a distinct italic style. Leave empty if unused. |
| `session_id` | no | Binds the card to a specific session. If the session is no longer tracked, the card renders sessionless. |
| `session_name` | no | Human-readable session name override. Leave empty to inherit from session state. |
| `pid`, `cwd`, `tty` | no | Leave `0`/`""` for external producers. Used internally by Navi's own hooks. |
| `tool_use_id`, `expires` | no | Leave `""` / `0`. Only meaningful for `permission` events. |

### Bash example

```bash
NAVI_EVENTS="/tmp/navi/events"
if [ -d "$NAVI_EVENTS" ]; then
  ID="$(date +%s)-$(openssl rand -hex 16)"
  printf '{"id":"%s","timestamp":%s,"type":"info","title":"Monthly spend","body":"%s","description":"","session_id":"%s","session_name":"","pid":0,"cwd":"","tty":"","tool_use_id":"","expires":0}\n' \
    "$ID" "$(date +%s)" "$DISPLAY_LINE" "$SESSION_ID" \
    > "$NAVI_EVENTS/.${ID}.tmp" \
  && mv "$NAVI_EVENTS/.${ID}.tmp" "$NAVI_EVENTS/${ID}.json"
fi
```

The `if [ -d "$NAVI_EVENTS" ]` guard makes the integration a no-op when Navi isn't installed.

## Behaviour guarantees

- `info` cards are **non-interactive**: no approve/deny, no `responses/` channel. They cannot be used to influence permission decisions.
- `info` cards do **not displace** the current stop/notification card for a session — they are additive.
- `info` cards do **not suppress** pending permission cards and do not dismiss them.
- Non-info events (Stop, Notification, etc.) arriving for the same session do **not** remove existing info cards.
- Cards are **sticky** — they do not auto-expire. They stay until the user dismisses them (the X button) or the producer resolves them (see below).
- Navi uses the blue `info.circle.fill` icon and plays the "Info" sound (off by default, configurable in Settings).

## Removing a card (producer-side resolve)

To remove your card programmatically, atomically write a `resolve-<nonce>.json` file to `/tmp/navi/events/`:

```json
{ "id": "<the-card-id-you-originally-wrote>" }
```

```bash
NAVI_EVENTS="/tmp/navi/events"
if [ -d "$NAVI_EVENTS" ]; then
  RESOLVE_NONCE="$(date +%s)-$(openssl rand -hex 8)"
  printf '{"id":"%s"}\n' "$YOUR_CARD_ID" \
    > "$NAVI_EVENTS/.resolve-${RESOLVE_NONCE}.tmp" \
  && mv "$NAVI_EVENTS/.resolve-${RESOLVE_NONCE}.tmp" \
        "$NAVI_EVENTS/resolve-${RESOLVE_NONCE}.json"
fi
```

The file must be named `resolve-<anything>.json` (Navi matches the `resolve-` prefix). Use a fresh nonce; never reuse resolve file names. The file is consumed immediately — you don't need to clean it up.

If the card has already been dismissed by the user, the resolve file is silently ignored (no error).

## Security

- The `id` nonce must be at least 16 random bytes (128 bits). Do not reuse ids.
- Content in `body` is rendered as trusted display text (same visual weight as tool args). Keep it short and controlled. Put AI-generated or user-derived freeform text in `description` instead.
- Validate `session_id` against `^[A-Za-z0-9_-]+$` before using it in any file path on the producer side.
- Write atomically: write to a `.tmp` file then `mv`/`os.rename` to the final `.json` name. Navi only reads `.json` files.
- `/tmp/navi/events/` is created with mode `0700` (owner-only) by Navi. Your producer runs as the same user, so writes succeed.

## Built-in `info` producer: context window alerts

Navi ships a built-in `info` producer for context window alerts. When enabled (Settings → Experimental → Context window alerts), `EnrichmentService` polls session transcripts on a timer and injects an `info` card directly into `EventMonitor` when a session's input token count crosses the configured warning or critical threshold (defaults: 200K / 400K).

The feature is gated behind the `context-alerts` feature flag (`/tmp/navi/features/context-alerts`), which the Settings toggle manages. Per-session crossing state is tracked in memory. When context drops back below 140K (e.g. after `/compact`), all stored alert event IDs for that session are resolved and their cards disappear automatically.
