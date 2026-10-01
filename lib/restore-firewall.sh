#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
INSTALL_ROOT=/opt/xray-vps-setup
LIB="$INSTALL_ROOT/lib"
STATE_FILE="$INSTALL_ROOT/current/state.json"
[[ -f "$STATE_FILE" ]] || exit 0
RUN_DIR=$(mktemp -d)
trap 'rm -rf "$RUN_DIR"' EXIT
settings=$(python3 "$LIB/setup_config.py" export "$STATE_FILE")
eval "$settings"
settings=$(python3 - "$STATE_FILE" <<'PY'
import json, shlex, sys
s=json.load(open(sys.argv[1]))
print('SSH_NEW_PORT='+shlex.quote(str((s.get('ssh') or {}).get('port',''))))
print('SSH_CONFIRMED='+('y' if s.get('ssh_confirmed') else 'n'))
print('SSH_OLD_PORTS=('+ ' '.join(shlex.quote(str(p)) for p in s.get('ssh_old_ports',[]))+')')
PY
)
eval "$settings"
source "$LIB/firewall.sh"
apply_firewall
