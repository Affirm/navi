#!/bin/bash
# Simulate a Claude Code session on the dev container, without Claude Code.
#   navi-fake-session start [name]   register a live session (prints its id)
#   navi-fake-session permission     fire a PermissionRequest; prints the decision
#   navi-fake-session stop           fire a Stop event
#   navi-fake-session working        fire a UserPromptSubmit (working) signal
#   navi-fake-session end            end the session
set -euo pipefail
STATE="$HOME/.navi-fake-session"
HOOKS="${NAVI_HOOKS:-/plugin/hooks}"
cmd="${1:-}"

sid() { cat "$STATE/sid" 2>/dev/null || { echo "run: navi-fake-session start" >&2; exit 1; }; }

payload() {
    printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"rm -rf build/","description":"Clean the build directory"}}' \
        "$1" "$(sid)" "$HOME/demo-project"
}

case "$cmd" in
    start)
        mkdir -p "$STATE" "$HOME/.claude/sessions" "$HOME/demo-project"
        nohup sleep infinity >/dev/null 2>&1 &
        pid=$!
        id="fake-$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
        echo "$id" > "$STATE/sid"; echo "$pid" > "$STATE/pid"
        now=$(python3 -c 'import time;print(int(time.time()*1000))')
        printf '{"sessionId":"%s","pid":%s,"cwd":"%s","name":"%s","status":"idle","updatedAt":%s}\n' \
            "$id" "$pid" "$HOME/demo-project" "${2:-demo on container}" "$now" > "$HOME/.claude/sessions/$pid.json"
        echo "$id"
        ;;
    permission) payload PermissionRequest | bash "$HOOKS/hook.sh"; echo ;;
    stop)       payload Stop | bash "$HOOKS/hook.sh" ;;
    working)    payload UserPromptSubmit | bash "$HOOKS/userpromptsubmit.sh" ;;
    end)
        pid=$(cat "$STATE/pid" 2>/dev/null || true)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        rm -f "$HOME/.claude/sessions/$pid.json"; rm -rf "$STATE"
        ;;
    *) sed -n '2,8p' "$0"; exit 1 ;;
esac
