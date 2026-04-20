#!/bin/bash
# Lightweight hook that captures tool_use_id before PermissionRequest fires.
# PermissionRequest payloads lack tool_use_id, but PreToolUse has it.
# Gated behind the auto-dismiss feature flag.
set -euo pipefail
[ -f /tmp/navi/features/auto-dismiss ] || exit 0
mkdir -p /tmp/navi/pretooluse || true
python3 -c "
import sys, json, os, re, tempfile
d = json.load(sys.stdin)
sid = d.get('session_id', '')
tuid = d.get('tool_use_id', '')
if sid and tuid and '/' not in sid and '..' not in sid and re.match(r'^[0-9a-f-]+$', tuid):
    target = '/tmp/navi/pretooluse/' + sid + '.latest'
    fd, tmp = tempfile.mkstemp(dir='/tmp/navi/pretooluse')
    with os.fdopen(fd, 'w') as f:
        f.write(tuid)
    os.rename(tmp, target)
" || true
