#!/bin/bash
# Lightweight hook that signals Navi the user sent a message (Claude starts working).
# Only runs when session-status feature is enabled.
[ -f /tmp/navi/features/session-status ] || exit 0
set -euo pipefail
mkdir -p /tmp/navi/events
python3 -c "
import sys, json, os, time
d = json.load(sys.stdin)
sid = d.get('session_id', '')
if not sid:
    sys.exit(0)
eid = '{}-{}-{}'.format(int(time.time()), os.getpid(), os.getpid() % 32768)
event = {'type': 'working', 'session_id': sid}
tmp = '/tmp/navi/events/.working-' + eid + '.tmp'
target = '/tmp/navi/events/working-' + eid + '.json'
with open(tmp, 'w') as f:
    json.dump(event, f)
os.rename(tmp, target)
" || true
