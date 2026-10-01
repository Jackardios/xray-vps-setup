#!/usr/bin/env bash
# SSH changes retain old listeners/authentication until a real new login is confirmed.
uses_ssh_socket() {
  systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket
}

restart_ssh() {
  systemctl daemon-reload || return 1
  if uses_ssh_socket; then
    # One transaction stops the service before reopening its socket.
    systemctl restart ssh.socket ssh.service || return 1
  else
    systemctl restart ssh.service || return 1
  fi
}

write_socket_ports() {
  local port
  if uses_ssh_socket; then
    install -d -m 0755 /etc/systemd/system/ssh.socket.d
    {
      echo '[Socket]'
      echo 'ListenStream='
      echo 'BindIPv6Only=ipv6-only'
      for port in "$@"; do
        echo "ListenStream=0.0.0.0:$port"
        if [[ -e /proc/net/if_inet6 ]]; then echo "ListenStream=[::]:$port"; fi
      done
    } > /etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf
    chmod 0644 /etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf
  fi
}

existing_ssh_ports() {
  local config sockets listeners
  config=$(sshd -T) || return 1
  listeners=$(ss -H -ltnp) || return 1
  sockets=''
  if uses_ssh_socket; then sockets=$(systemctl show ssh.socket --property=Listen --value) || return 1; fi
  {
    awk '$1=="port" {print $2}' <<< "$config"
    awk '/"sshd"/ {port=$4; sub(/^.*:/,"",port); print port}' <<< "$listeners"
    python3 -c 'import re,sys; print("\n".join(re.findall(r":([0-9]+)\s+\(Stream\)",sys.argv[1])))' "$sockets"
  } | awk 'NF' | sort -nu
}

check_ssh_listener() {
  # An IPv6-only socket must never satisfy the IPv4 readiness check.
  ss -4 -H -ltn "sport = :$SSH_NEW_PORT" | grep -q .
}

check_ssh_policy() {
  local effective user context client_address client_host policy
  python3 "$LIB/ssh_policy.py" /etc/ssh/sshd_config || return 1
  effective=$(sshd -T) || return 1
  for user in passwordauthentication kbdinteractiveauthentication permitrootlogin; do
    grep -qx "$user no" <<< "$effective" || return 1
  done
  read -r client_address _ _ _ <<< "${SSH_CONNECTION:-}"
  client_address=${client_address:-127.0.0.1}
  client_host=$client_address
  for user in root "$SSH_USER"; do
    context="user=$user,host=$client_host,addr=$client_address,laddr=${connected_address:-127.0.0.1},lport=$SSH_NEW_PORT"
    effective=$(sshd -T -C "$context") || return 1
    for policy in passwordauthentication kbdinteractiveauthentication permitrootlogin; do
      grep -qx "$policy no" <<< "$effective" || return 1
    done
    if [[ "$user" == "$SSH_USER" ]]; then
      grep -qx 'pubkeyauthentication yes' <<< "$effective" || return 1
      grep -Eq '^authenticationmethods (any|publickey)$' <<< "$effective" || return 1
    fi
  done
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
  effective_ports=$(existing_ssh_ports)
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
    write_socket_ports "$SSH_NEW_PORT"
    restart_ssh
    check_ssh_listener || die 'SSH has no IPv4 listener on the saved port'
    return 0
  fi
  # Preparation adds ports only. Root/password settings stay as they were.
  local listener_ports=("${SSH_OLD_PORTS[@]}")
  [[ "$port_known" == y ]] || listener_ports+=("$SSH_NEW_PORT")
  local auth_settings=''
  if [[ -f /etc/ssh/sshd_config.d/00-xray-vps-setup.conf ]]; then
    auth_settings=$(awk 'tolower($1) ~ /^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)$/ {print}' /etc/ssh/sshd_config.d/00-xray-vps-setup.conf)
  fi
  {
    for port in "${listener_ports[@]}"; do echo "Port $port"; done
    [[ -z "$auth_settings" ]] || printf '%s\n' "$auth_settings"
  } > /etc/ssh/sshd_config.d/00-xray-vps-setup.conf
  chmod 0600 /etc/ssh/sshd_config.d/00-xray-vps-setup.conf
  sshd -t
  write_socket_ports "${listener_ports[@]}"
  restart_ssh
  check_ssh_listener || die 'New IPv4 SSH listener did not start'
  {
    printf 'INSTALL_ROOT=%q\n' "$INSTALL_ROOT"
    printf 'INSTALL_MODE=%q\n' "$INSTALL_MODE"
    printf 'INGRESS_IP=%q\nEGRESS_IP=%q\n' "$INGRESS_IP" "$EGRESS_IP"
    printf 'SSH_NEW_PORT=%q\nSSH_USER=%q\n' "$SSH_NEW_PORT" "$user"
    printf 'SSH_OLD_PORTS=('; printf '%q ' "${SSH_OLD_PORTS[@]}"; printf ')\n'
  } > "$INSTALL_ROOT/ssh-transition.env"
  chmod 0600 "$INSTALL_ROOT/ssh-transition.env"
}
