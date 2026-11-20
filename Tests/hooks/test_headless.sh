#!/bin/bash
# Headless hook tests. Meant to run as root inside a throwaway Linux container
# (see scripts/test-hooks-linux.sh) because it creates users and writes to
# /tmp/navi. Do NOT run this on your Mac: it would write into the live
# /tmp/navi that Navi.app watches.
#
# Expects the plugin's hooks/ directory at $PLUGIN/hooks (default /plugin).
set -uo pipefail

PLUGIN="${PLUGIN:-/plugin}"
HOOKS="$PLUGIN/hooks"
FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

if [ "$(uname -s)" = "Darwin" ]; then
    echo "refusing to run on macOS (would touch the live /tmp/navi)" >&2
    exit 2
fi
[ "$(id -u)" = 0 ] || { echo "run as root inside a container" >&2; exit 2; }

id tester >/dev/null 2>&1 || useradd -m -u 1000 tester
id other >/dev/null 2>&1 || useradd -m -u 1001 other

# Run a hook as `tester` with a clean env (no CLAUDE_PLUGIN_ROOT pointing at a
# real install; PLUGIN_ROOT resolves from the script path, and there is no
# build.sh next to hooks/, so any attempt to build/launch fails the hook).
as_tester() {
    setpriv --reuid=1000 --regid=1000 --init-groups \
        env -i HOME=/home/tester PATH=/usr/local/bin:/usr/bin:/bin "$@"
}

payload() {
    printf '{"hook_event_name":"%s","session_id":"sess-1234","cwd":"/home/tester/proj","tool_name":"Bash","tool_input":{"command":"ls -la","description":"list files"}}' "$1"
}

reset_tmp() { rm -rf /tmp/navi; }

# --- 1. Stop event: exit 0, event written, no build/launch -----------------
reset_tmp
out=$(payload Stop | as_tester bash "$HOOKS/hook.sh" 2>/tmp/err1); rc=$?
files=$(ls /tmp/navi/events/*.json 2>/dev/null | wc -l)
if [ $rc -eq 0 ] && [ "$files" -eq 1 ] && grep -q '"type": "stop"' /tmp/navi/events/*.json; then
    pass "Stop writes one event and exits 0"
else
    fail "Stop: rc=$rc files=$files stderr=$(cat /tmp/err1)"
fi
if [ "$(stat -c %a /tmp/navi)" = 700 ] && [ "$(stat -c %U /tmp/navi)" = tester ]; then
    pass "/tmp/navi is 0700 and owned by the hook user"
else
    fail "/tmp/navi perms: $(stat -c '%a %U' /tmp/navi)"
fi

# --- 2. PermissionRequest without a relay: no stall, no decision -----------
reset_tmp
start=$(date +%s)
out=$(payload PermissionRequest | as_tester bash "$HOOKS/hook.sh" 2>/tmp/err2); rc=$?
elapsed=$(( $(date +%s) - start ))
if [ $rc -eq 0 ] && [ -z "$out" ] && [ $elapsed -lt 5 ] && grep -q '"type": "permission"' /tmp/navi/events/*.json; then
    pass "PermissionRequest without relay returns immediately with no decision"
else
    fail "PermissionRequest no relay: rc=$rc out='$out' elapsed=${elapsed}s stderr=$(cat /tmp/err2)"
fi

# --- 3. PermissionRequest with a live relay: waits for and honours response -
reset_tmp
as_tester bash -c 'mkdir -p -m 700 /tmp/navi && date +%s > /tmp/navi/relay.alive'
(
    # Stand-in for relay.py: wait for the event, answer it.
    for _ in $(seq 1 50); do
        f=$(ls /tmp/navi/events/*.json 2>/dev/null | head -1)
        if [ -n "$f" ]; then
            id=$(basename "$f" .json)
            as_tester bash -c "printf approve > /tmp/navi/responses/.$id.tmp && mv /tmp/navi/responses/.$id.tmp /tmp/navi/responses/$id"
            exit 0
        fi
        sleep 0.1
    done
) &
out=$(payload PermissionRequest | as_tester bash "$HOOKS/hook.sh" 2>/tmp/err3); rc=$?
wait
if [ $rc -eq 0 ] && echo "$out" | grep -q '"behavior":"allow"'; then
    pass "PermissionRequest with relay returns the relayed approval"
else
    fail "PermissionRequest with relay: rc=$rc out='$out' stderr=$(cat /tmp/err3)"
fi

# --- 4. Stale relay heartbeat is treated as no relay -----------------------
reset_tmp
as_tester bash -c 'mkdir -p -m 700 /tmp/navi && echo $(( $(date +%s) - 60 )) > /tmp/navi/relay.alive'
start=$(date +%s)
out=$(payload PermissionRequest | as_tester bash "$HOOKS/hook.sh" 2>/dev/null); rc=$?
elapsed=$(( $(date +%s) - start ))
if [ $rc -eq 0 ] && [ -z "$out" ] && [ $elapsed -lt 5 ]; then
    pass "stale relay heartbeat does not block"
else
    fail "stale heartbeat: rc=$rc out='$out' elapsed=${elapsed}s"
fi

# --- 5. /tmp/navi owned by another user: hook refuses, writes nothing ------
reset_tmp
mkdir -p /tmp/navi/events /tmp/navi/responses /tmp/navi/features
chmod -R 777 /tmp/navi
chown -R other:other /tmp/navi
touch /tmp/navi/features/auto-dismiss /tmp/navi/features/session-status
chmod 666 /tmp/navi/features/*
out=$(payload PermissionRequest | as_tester bash "$HOOKS/hook.sh" 2>/tmp/err5); rc=$?
files=$(ls /tmp/navi/events/ 2>/dev/null | wc -l)
if [ $rc -eq 0 ] && [ -z "$out" ] && [ "$files" -eq 0 ] && grep -q "not owned" /tmp/err5; then
    pass "hook.sh refuses a /tmp/navi owned by another user"
else
    fail "foreign /tmp/navi (hook.sh): rc=$rc files=$files out='$out'"
fi
payload PreToolUse | as_tester bash "$HOOKS/pretooluse.sh"; rc1=$?
payload UserPromptSubmit | as_tester bash "$HOOKS/userpromptsubmit.sh"; rc2=$?
files=$(find /tmp/navi -type f -newer /tmp/err5 2>/dev/null | wc -l)
if [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ "$files" -eq 0 ] && [ ! -d /tmp/navi/pretooluse ]; then
    pass "pretooluse/userpromptsubmit refuse a foreign /tmp/navi"
else
    fail "foreign /tmp/navi (small hooks): rc1=$rc1 rc2=$rc2 new_files=$files"
fi

# --- 6. Small hooks still work headless when flags are present -------------
reset_tmp
as_tester bash -c 'mkdir -p -m 700 /tmp/navi/features && touch /tmp/navi/features/auto-dismiss /tmp/navi/features/session-status'
printf '{"session_id":"sess-1234","tool_use_id":"toolu_abc"}' | as_tester bash "$HOOKS/pretooluse.sh"; rc1=$?
payload UserPromptSubmit | as_tester bash "$HOOKS/userpromptsubmit.sh"; rc2=$?
if [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] \
   && [ "$(cat /tmp/navi/pretooluse/sess-1234.latest 2>/dev/null)" = toolu_abc ] \
   && ls /tmp/navi/events/working-*.json >/dev/null 2>&1; then
    pass "pretooluse/userpromptsubmit work headless"
else
    fail "small hooks headless: rc1=$rc1 rc2=$rc2"
fi

echo
if [ $FAILS -eq 0 ]; then echo "All headless hook tests passed."; else echo "$FAILS test(s) failed."; fi
exit $FAILS
