#!/bin/bash
# Start a disposable SSH "remote host" in Docker for trying remote hosts
# locally. Generates a throwaway key under ./.dev-remote/ (gitignored) and
# prints a Host block to add to ~/.ssh/config yourself.
#
#   scripts/dev-remote-container.sh          build + start (port 2222)
#   scripts/dev-remote-container.sh stop     remove the container
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$DIR/.dev-remote"
NAME="navi-dev-remote"
PORT="${NAVI_DEV_PORT:-2222}"

if [ "${1:-}" = "stop" ]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo "stopped $NAME"
    exit 0
fi

mkdir -p "$STATE/keys"
chmod 700 "$STATE"
[ -f "$STATE/id_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C navi-dev-remote -f "$STATE/id_ed25519"
cp "$STATE/id_ed25519.pub" "$STATE/keys/authorized_keys"

docker build -q -t navi-dev-remote "$DIR/scripts/dev-remote" >/dev/null
docker rm -f "$NAME" >/dev/null 2>&1 || true
# A new container has new host keys; the throwaway known_hosts is only for it.
rm -f "$STATE/known_hosts"
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:22" \
    -v "$DIR/hooks:/plugin/hooks:ro" \
    -v "$STATE/keys:/keys:ro" \
    navi-dev-remote >/dev/null

cat > "$STATE/ssh_config" <<CFG
Host navi-dev
  HostName 127.0.0.1
  Port $PORT
  User dev
  IdentityFile $STATE/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $STATE/known_hosts
CFG

echo "Container $NAME is up on 127.0.0.1:$PORT."
echo
echo "Add this to ~/.ssh/config (or Include $STATE/ssh_config), then add 'navi-dev' in Navi:"
echo
cat "$STATE/ssh_config"
echo
echo "Simulate a session on it:"
echo "  ssh -F $STATE/ssh_config navi-dev navi-fake-session start"
echo "  ssh -F $STATE/ssh_config navi-dev navi-fake-session permission"
