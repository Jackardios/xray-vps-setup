#!/usr/bin/env bash
# SSH changes retain old listeners/authentication until a real new login is confirmed.
restart_ssh() {
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket; then
    systemctl restart ssh.socket
  fi
  systemctl restart ssh.service
}

write_socket_ports() {
  local port
  if systemctl is-active --quiet ssh.socket; then
    install -d -m 0755 /etc/systemd/system/ssh.socket.d
    {
      echo '[Socket]'
      echo 'ListenStream='
      for port in "$@"; do echo "ListenStream=$port"; done
    } > /etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf
    chmod 0644 /etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf
  fi
}

prepare_ssh() {
  local user public_key password key_file ssh_settings effective_ports port port_known
  ssh_settings=$(python3 - "$STATE_FILE" <<'PY'
import json, shlex, sys
ssh = json.load(open(sys.argv[1])).get('ssh')
if ssh:
    for key, field in [('user','user'),('public_key','public_key'),('SSH_NEW_PORT','port'),('password','password')]:
        print(key + '=' + shlex.quote(str(ssh.get(field, ''))))
PY
)
  eval "$ssh_settings"
  [[ -n "${SSH_NEW_PORT:-}" ]] || return 0
  install -d -m 0755 /run/sshd /etc/ssh/sshd_config.d
  effective_ports=$(sshd -T | awk '$1=="port" && !seen[$2]++ {print $2}')
  mapfile -t SSH_OLD_PORTS <<< "$effective_ports"
  [[ -n "$effective_ports" ]] || die 'Could not determine existing SSH ports'
  port_known=n
  for port in "${SSH_OLD_PORTS[@]}"; do
    python3 "$LIB/setup_config.py" port "$port" >/dev/null || die 'Existing SSH port conflicts with a managed service; migrate SSH first'
    [[ "$port" != "$SSH_NEW_PORT" ]] || port_known=y
  done
  if [[ "$port_known" == n && -n "$(ss -H -ltn "sport = :$SSH_NEW_PORT")" ]]; then
    die 'Selected SSH port is already occupied by another service'
  fi
  key_file=$(mktemp "$RUN_DIR/key.XXXXXX")
  printf '%s\n' "$public_key" > "$key_file"
  ssh-keygen -l -f "$key_file" >/dev/null
  if ! id "$user" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$user"
    printf '%s:%s\n' "$user" "$password" | chpasswd
  fi
  usermod -aG sudo "$user"
  local user_home
  user_home=$(getent passwd "$user" | cut -d: -f6)
  [[ "$user_home" == /home/* && ! -L "$user_home" ]] || die 'Refusing an unsafe SSH home directory'
  install -d -m 0700 -o "$user" -g "$(id -gn "$user")" "$user_home/.ssh"
  touch "$user_home/.ssh/authorized_keys"
  if ! grep -qxF "$public_key" "$user_home/.ssh/authorized_keys"; then
    printf '%s\n' "$public_key" >> "$user_home/.ssh/authorized_keys"
  fi
  chmod 0600 "$user_home/.ssh/authorized_keys"
  chown "$user:$(id -gn "$user")" "$user_home/.ssh/authorized_keys"
  SSH_CONFIRMED=$(python3 - "$STATE_FILE" <<'PY'
import json, sys
print('y' if json.load(open(sys.argv[1])).get('ssh_confirmed') else 'n')
PY
)
  if [[ "$SSH_CONFIRMED" == y ]]; then
    sshd -t
    return 0
  fi
  # Preparation adds ports only. Root/password settings stay as they were.
  local listener_ports=("${SSH_OLD_PORTS[@]}")
  [[ "$port_known" == y ]] || listener_ports+=("$SSH_NEW_PORT")
  {
    for port in "${listener_ports[@]}"; do echo "Port $port"; done
  } > /etc/ssh/sshd_config.d/00-xray-vps-setup.conf
  chmod 0600 /etc/ssh/sshd_config.d/00-xray-vps-setup.conf
  sshd -t
  write_socket_ports "${listener_ports[@]}"
  restart_ssh
  ss -H -ltn "sport = :$SSH_NEW_PORT" | grep -q . || die 'New SSH listener did not start'
  {
    printf 'INSTALL_ROOT=%q\n' "$INSTALL_ROOT"
    printf 'INSTALL_MODE=%q\n' "$INSTALL_MODE"
    printf 'INGRESS_IP=%q\nEGRESS_IP=%q\n' "$INGRESS_IP" "$EGRESS_IP"
    printf 'SSH_NEW_PORT=%q\nSSH_USER=%q\n' "$SSH_NEW_PORT" "$user"
    printf 'SSH_OLD_PORTS=('; printf '%q ' "${SSH_OLD_PORTS[@]}"; printf ')\n'
  } > "$INSTALL_ROOT/ssh-transition.env"
  chmod 0600 "$INSTALL_ROOT/ssh-transition.env"
}
