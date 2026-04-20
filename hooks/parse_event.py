"""Parse a Claude Code hook payload and write an event file for Navi.

Reads JSON from stdin, extracts event details, writes to the events directory,
and prints event_name<TAB>event_id to stdout for the shell script to consume.
"""

import sys
import json
import time
import os

EVENTS_DIR = os.environ["EVENTS_DIR"]
FEATURES_DIR = "/tmp/navi/features"


def feature_enabled(name):
    """Check if a feature flag file exists (enabled)."""
    return os.path.exists(os.path.join(FEATURES_DIR, name))


def feature_config(name, default=None):
    """Read JSON config from a feature flag file. Returns default if disabled or empty."""
    path = os.path.join(FEATURES_DIR, name)
    try:
        with open(path) as f:
            content = f.read().strip()
            if not content:
                return default
            return json.loads(content)
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return default

d = json.load(sys.stdin)
event_name = d.get("hook_event_name", "")

# PostToolUse/PostToolUseFailure only exist for auto-dismiss — skip early.
if event_name in ("PostToolUse", "PostToolUseFailure"):
    if not feature_enabled("auto-dismiss"):
        # Empty second field — hook.sh uses cut -f2 to extract event_id,
        # which is unused for skipped PostToolUse events.
        print(event_name + "\t")
        sys.exit(0)

tool = d.get("tool_name", "")
ti = d.get("tool_input", {})
if not isinstance(ti, dict):
    ti = {}

detailed = feature_enabled("detailed-permissions") and d.get("hook_event_name") == "PermissionRequest"

def _trunc(s, n=140):
    return s if detailed or len(s) <= n else s[: n - 3] + "..."

parts = []
if tool:
    parts.append("Tool: " + tool)

cmd = ti.get("command", "")
if cmd:
    parts.append("Command: " + _trunc(cmd))

fp = ti.get("file_path", "")
if fp:
    parts.append("File: " + fp)

prompt = ti.get("prompt", "")
if prompt and not cmd and not fp:
    parts.append(_trunc(prompt))

desc = ti.get("description", "")
if desc and not cmd and not fp and not prompt:
    parts.append(_trunc(desc))

# Detailed mode: append any remaining tool_input fields as JSON so the user
# sees the whole request, not just the primary field.
if detailed:
    shown = {"command", "file_path", "prompt", "description"}
    extras = {k: v for k, v in ti.items() if k not in shown}
    if extras:
        parts.append(json.dumps(extras, indent=2, ensure_ascii=False))

body = "\n".join(parts)
session_id = d.get("session_id", "")
tool_use_id = d.get("tool_use_id", "")

# PermissionRequest payloads lack tool_use_id.  Read it from the file
# written by the PreToolUse hook that fires immediately before.
# Only relevant when auto-dismiss is enabled.
if event_name == "PermissionRequest" and not tool_use_id:
    if feature_enabled("auto-dismiss"):
        if "/" not in session_id and ".." not in session_id:
            try:
                with open("/tmp/navi/pretooluse/" + session_id + ".latest") as f:
                    tool_use_id = f.read().strip()
            except (FileNotFoundError, OSError):
                pass

# Look up the human-readable session name from ~/.claude/sessions/<ppid>.json.
# PPID is the Claude Code process whose PID keys the session file.
# Gated: NAVI_PPID is only exported by hook.sh when session-names is enabled.
session_name = ""
ppid = os.environ.get("NAVI_PPID", "")
if ppid and ppid.isdigit():
    try:
        with open(os.path.expanduser("~/.claude/sessions/" + ppid + ".json")) as sf:
            session_name = json.load(sf).get("name", "")
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        pass

cwd = d.get("cwd", "")
tty = os.environ.get("NAVI_TTY", "")
pid = int(ppid) if ppid and ppid.isdigit() else 0
hook_timeout = int(os.environ.get("NAVI_HOOK_TIMEOUT", "120"))
timestamp = time.time()
event_id = "{}-{}-{}".format(int(timestamp), os.getpid(), os.getpid() % 32768)

# Write event file if recognized
TYPE_MAP = {
    "PermissionRequest": ("permission", "Permission Request"),
    "Stop": ("stop", "Finished Responding"),
    "StopFailure": ("stop", "Stopped (Error)"),
    "Notification": ("notification", "Attention Needed"),
}

if event_name in ("PostToolUse", "PostToolUseFailure"):
    # PostToolUse fires after a tool succeeds — meaning any prior permission
    # for this session was resolved.  Write a resolve signal so Navi can
    # dismiss stale pending permissions without displaying anything.
    # Note: the early exit above already skips if auto-dismiss is disabled.
    resolve = {
        "type": "resolve",
        "session_id": session_id,
        "tool_use_id": tool_use_id,
    }
    tmpfile = os.path.join(EVENTS_DIR, ".resolve-" + event_id + ".tmp")
    target = os.path.join(EVENTS_DIR, "resolve-" + event_id + ".json")
    with open(tmpfile, "w") as f:
        json.dump(resolve, f)
    os.rename(tmpfile, target)
elif event_name in TYPE_MAP:
    etype, title = TYPE_MAP[event_name]
    event = {
        "id": event_id,
        "timestamp": timestamp,
        "type": etype,
        "title": title,
        "body": body,
        "session_id": session_id,
        "session_name": session_name,
        "pid": pid,
        "cwd": cwd,
        "tty": tty,
        "tool_use_id": tool_use_id,
        "expires": timestamp + hook_timeout if etype == "permission" else 0,
    }
    tmpfile = os.path.join(EVENTS_DIR, "." + event_id + ".tmp")
    target = os.path.join(EVENTS_DIR, event_id + ".json")
    with open(tmpfile, "w") as f:
        json.dump(event, f)
    os.rename(tmpfile, target)

print(event_name + "\t" + event_id)
