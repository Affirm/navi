#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
APP="$PLUGIN_ROOT/Navi.app"
APP_BINARY="$APP/Contents/MacOS/Navi"
EVENTS_DIR="/tmp/navi/events"
RESPONSES_DIR="/tmp/navi/responses"
mkdir -p "$EVENTS_DIR" "$RESPONSES_DIR"

# Clean up stale event/response files older than 5 minutes
find "$EVENTS_DIR" "$RESPONSES_DIR" -type f -mmin +5 -delete 2>/dev/null || true

# Build if needed (build.sh compares plugin.json version to built-version marker)
bash "$PLUGIN_ROOT/build.sh" >&2

# Launch the monitor app if not running (skip if NAVI_NO_AUTO_LAUNCH is set).
if [ -z "${NAVI_NO_AUTO_LAUNCH:-}" ] && [ ! -f "/tmp/navi/no-auto-launch" ] && ! pgrep -x Navi > /dev/null 2>&1; then
    open "$APP" &
    sleep 0.5
fi

# Feature flags: hooks check /tmp/navi/features/<name> to skip work for
# disabled experimental features.  Flag files can be empty (boolean) or
# contain JSON config readable with feature_config().
FEATURES_DIR="/tmp/navi/features"

# Read a JSON value from a feature flag file.  No current features use this
# yet — it's infrastructure for future configurable experimental features.
# Callers must use hardcoded flag names — no user input or dynamic values.
# Usage: feature_config <flag-name> <json-key> [default]
feature_config() {
    [[ "$1" =~ ^[a-z0-9-]+$ ]] || { echo "${3:-}"; return; }
    local file="$FEATURES_DIR/$1"
    [ -f "$file" ] && [ -s "$file" ] || { echo "${3:-}"; return; }
    python3 - "$file" "$2" "${3:-}" <<'PYEOF' 2>/dev/null || echo "${3:-}"
import json, sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
print(d.get(key, default))
PYEOF
}

# Capture the TTY of the Claude Code process so Navi can focus the right
# terminal tab.  The hook shell's own TTY shows "??" because stdin is piped,
# so we read the controlling terminal of the parent (Claude Code) process.
if [ -f "$FEATURES_DIR/terminal-focus" ]; then
    NAVI_TTY=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ' || echo "")
    if [ -n "$NAVI_TTY" ] && [ "$NAVI_TTY" != "??" ]; then
        export NAVI_TTY="/dev/$NAVI_TTY"
    else
        export NAVI_TTY=""
    fi
fi

# Export the Claude Code PID so parse_event.py can look up the session name
# from ~/.claude/sessions/<pid>.json.
if [ -f "$FEATURES_DIR/session-names" ]; then
    export NAVI_PPID="$PPID"
fi

# Timeout for PermissionRequest polling (seconds).  Also used by
# parse_event.py to set an "expires" timestamp on permission events
# so Navi knows when the buttons go stale.
export NAVI_HOOK_TIMEOUT=120

# Parse hook payload and write event file.
# Outputs: event_name<TAB>event_id
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export EVENTS_DIR
READ_RESULT=$(cat | python3 "$SCRIPT_DIR/parse_event.py")

EVENT=$(echo "$READ_RESULT" | cut -f1)
EVENT_ID=$(echo "$READ_RESULT" | cut -f2)

# Track whether Navi responded so we can set NAVI_RESPONDED for potential
# future use.  We intentionally do NOT write a cancel file on exit — instead
# the card stays visible showing "Respond in terminal" and is dismissed by
# PostToolUse (approve) or Stop events (deny/move on).
NAVI_RESPONDED=false

case "$EVENT" in
    PermissionRequest)
        # Poll for response using wall clock time
        DEADLINE=$(($(date +%s) + NAVI_HOOK_TIMEOUT))
        while [ "$(date +%s)" -lt "$DEADLINE" ]; do
            if [ -f "$RESPONSES_DIR/$EVENT_ID" ]; then
                RESPONSE=$(cat "$RESPONSES_DIR/$EVENT_ID")
                rm -f "$RESPONSES_DIR/$EVENT_ID"
                case "$RESPONSE" in
                    approve)
                        NAVI_RESPONDED=true
                        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
                        exit 0
                        ;;
                    deny)
                        NAVI_RESPONDED=true
                        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}'
                        exit 0
                        ;;
                esac
            fi
            sleep 0.3
        done

        # Timeout — fall back to terminal prompt
        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"ask"}}}'
        ;;

    *)
        ;;
esac
