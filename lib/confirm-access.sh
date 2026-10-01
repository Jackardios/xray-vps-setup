#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Run with sudo from the new SSH session' >&2; exit 1; }
INSTALL_ROOT=/opt/xray-vps-setup
# Root-owned file written by the installer, never a user-supplied environment file.
source "$INSTALL_ROOT/ssh-transition.env"
[[ "${SUDO_USER:-}" == "$SSH_USER" ]] || { echo "Connect as $SSH_USER before confirming" >&2; exit 1; }
read -r _ _ connected_address connected_port <<< "${SSH_CONNECTION:-}"
[[ "$connected_port" == "$SSH_NEW_PORT" ]] || { echo 'Confirm from a connection to the new SSH port' >&2; exit 1; }
[[ -z "$EGRESS_IP" || "$connected_address" == "$EGRESS_IP" ]] || { echo 'Connect through the egress IP' >&2; exit 1; }
exec 9>"$INSTALL_ROOT/install.lock"
flock -n 9 || { echo 'Another installer operation is running' >&2; exit 1; }
RUN_DIR=$(mktemp -d "$INSTALL_ROOT/ssh-confirm.XXXXXX")
STATE_FILE="$INSTALL_ROOT/current/state.json"
source "$INSTALL_ROOT/lib/firewall.sh"
source "$INSTALL_ROOT/lib/ssh.sh"
SSH_CONFIRMED=y
cp -a "$STATE_FILE" "$RUN_DIR/state.json"
cp -a /etc/ssh/sshd_config.d/00-xray-vps-setup.conf "$RUN_DIR/ssh.conf"
if [[ -e /etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf ]]; then
  cp -a /etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf "$RUN_DIR/socket.conf"
fi
iptables-save > "$RUN_DIR/ipv4"
ip6tables-save > "$RUN_DIR/ipv6"
cat > "$RUN_DIR/rollback.sh" <<EOF
#!/bin/bash
set -e
cp -a '$RUN_DIR/state.json' '$STATE_FILE'
cp -a '$RUN_DIR/ssh.conf' /etc/ssh/sshd_config.d/00-xray-vps-setup.conf
if [ -e '$RUN_DIR/socket.conf' ]; then
 cp -a '$RUN_DIR/socket.conf' /etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf
else
 rm -f /etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf
fi
iptables-restore < '$RUN_DIR/ipv4'
ip6tables-restore < '$RUN_DIR/ipv6'
systemctl daemon-reload
if systemctl is-active --quiet ssh.socket; then systemctl restart ssh.socket; fi
systemctl restart ssh.service
systemctl enable xray-setup-firewall.service
EOF
chmod 0700 "$RUN_DIR/rollback.sh"
unit="xray-ssh-rollback-$(date +%s)"
systemd-run --quiet --unit="$unit" --on-active=120s "$RUN_DIR/rollback.sh"
rollback() {
  local status=$1
  trap - ERR INT TERM
  set +e
  "$RUN_DIR/rollback.sh"
  systemctl stop "$unit.timer"
  exit "$status"
}
trap 'rollback $?' ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM
printf 'Port %s\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' "$SSH_NEW_PORT" > /etc/ssh/sshd_config.d/00-xray-vps-setup.conf
sshd -t
sshd -T | grep -qx 'passwordauthentication no'
sshd -T | grep -qx 'kbdinteractiveauthentication no'
sshd -T | grep -qx 'permitrootlogin no'
write_socket_ports "$SSH_NEW_PORT"
restart_ssh
ss -H -ltn "sport = :$SSH_NEW_PORT" | grep -q .
apply_firewall
systemctl enable xray-setup-firewall.service
# Confirmation is persisted only while the rollback timer is still armed.
systemctl is-active --quiet "$unit.timer"
python3 - "$STATE_FILE" "$INSTALL_ROOT/lib" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2])
from setup_config import save_json
state=json.load(open(sys.argv[1]));state['ssh_confirmed']=True
save_json(sys.argv[1],state)
PY
systemctl stop "$unit.timer"
trap - ERR INT TERM
rm -rf "$RUN_DIR"
echo 'SSH confirmed: password and root login disabled; old access removed from managed firewall.'
