#!/usr/bin/env bash
# Install/repair from a complete checkout. A downloaded standalone entry point
# first retrieves one immutable repository snapshot, then executes that snapshot.
set -Eeuo pipefail
umask 077
export LC_ALL=C
INSTALL_ROOT=/opt/xray-vps-setup
XRAY_VERSION=26.3.27
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/lib"
RAW="$SCRIPT_DIR/templates_for_script"
RUN_DIR=''
RELEASE_DIR=''
BACKUP_DIR=''
TRANSACTION_ACTIVE=n
SUCCESS=n
# Shared with lib/ssh.sh and lib/firewall.sh.
# shellcheck disable=SC2034
SSH_NEW_PORT=''
# shellcheck disable=SC2034
SSH_CONFIRMED=n
SSH_OLD_PORTS=()
OLD_CURRENT=''
ACTION=${1:-install}

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
download() {
  curl --fail --location --show-error --silent --connect-timeout 10 --max-time 180 \
    --retry 2 --retry-delay 2 --retry-max-time 360 "$1" -o "$2" || return 1
  [[ -s "$2" ]] || { log "Empty download: $1" >&2; return 1; }
}

bootstrap() {
  [[ -f "$LIB/setup_config.py" && -f "$RAW/xray" ]] && return 0
  command -v curl >/dev/null || die 'Install curl and ca-certificates first'
  command -v python3 >/dev/null || die 'Install python3 first'
  local bundle revision
  BOOTSTRAP_DIR=$(mktemp -d)
  bundle=$BOOTSTRAP_DIR
  trap 'rm -rf "$BOOTSTRAP_DIR"' EXIT
  if [[ -n "${XRAY_SETUP_REVISION:-}" ]]; then
    revision=$XRAY_SETUP_REVISION
  else
    download 'https://api.github.com/repos/Jackardios/xray-vps-setup/commits/main' "$bundle/commit.json"
    revision=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sha"])' "$bundle/commit.json")
  fi
  [[ "$revision" =~ ^[a-f0-9]{40}$ ]] || die 'Repository revision must be a full commit SHA'
  download "https://codeload.github.com/Jackardios/xray-vps-setup/tar.gz/$revision" "$bundle/source.tar.gz"
  tar -xzf "$bundle/source.tar.gz" -C "$bundle"
  [[ -f "$bundle/xray-vps-setup-$revision/lib/setup_config.py" ]] || die 'Selected revision predates the safe installer'
  XRAY_SETUP_REVISION="$revision" bash "$bundle/xray-vps-setup-$revision/vps-setup.sh" "$@"
}

rollback_system() {
  local file failed=n
  log 'Restoring the previous deployment and SSH/firewall settings...' >&2
  if [[ -f "$RELEASE_DIR/api-transaction.json" ]]; then
    python3 "$LIB/panel_api.py" rollback "$RELEASE_DIR/api-transaction.json" || { failed=y; log 'API rollback requires manual recovery; journal retained.' >&2; }
  fi
  docker compose -p xray-vps-setup -f "$INSTALL_ROOT/docker-compose.yml" stop >/dev/null 2>&1 || true
  if [[ -n "$OLD_CURRENT" ]]; then
    ln -sfn "$OLD_CURRENT" "$INSTALL_ROOT/.current-rollback" || failed=y
    mv -Tf "$INSTALL_ROOT/.current-rollback" "$INSTALL_ROOT/current" || failed=y
  else
    rm -f "$INSTALL_ROOT/current" || failed=y
  fi
  rm -f "$INSTALL_ROOT/docker-compose.yml" || failed=y
  if [[ -e "$BACKUP_DIR/docker-compose.yml" || -L "$BACKUP_DIR/docker-compose.yml" ]]; then
    cp -a "$BACKUP_DIR/docker-compose.yml" "$INSTALL_ROOT/docker-compose.yml" || failed=y
  fi
  for file in ssh.conf socket.conf; do
    local destination=/etc/ssh/sshd_config.d/00-xray-vps-setup.conf
    [[ "$file" != socket.conf ]] || destination=/etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf
    rm -f "$destination" || failed=y
    if [[ -f "$BACKUP_DIR/$file" ]]; then cp -a "$BACKUP_DIR/$file" "$destination" || failed=y; fi
  done
  iptables-restore --wait 10 < "$BACKUP_DIR/ipv4" || { failed=y; log 'IPv4 rollback failed' >&2; }
  if [[ -f "$BACKUP_DIR/ipv6" ]]; then ip6tables-restore --wait 10 < "$BACKUP_DIR/ipv6" || { failed=y; log 'IPv6 rollback failed' >&2; }; fi
  if [[ -d "$BACKUP_DIR/lib" ]]; then
    rm -rf "${INSTALL_ROOT:?}/lib" || failed=y
    cp -a "$BACKUP_DIR/lib" "$INSTALL_ROOT/lib" || failed=y
  fi
  rm -f "$INSTALL_ROOT/ssh-transition.env" || failed=y
  [[ ! -f "$BACKUP_DIR/ssh-transition.env" ]] || cp -a "$BACKUP_DIR/ssh-transition.env" "$INSTALL_ROOT/ssh-transition.env" || failed=y
  if [[ -f "$BACKUP_DIR/firewall.service" ]]; then
    cp -a "$BACKUP_DIR/firewall.service" /etc/systemd/system/xray-setup-firewall.service || failed=y
  else
    systemctl disable xray-setup-firewall.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/xray-setup-firewall.service || failed=y
  fi
  source "$LIB/ssh.sh"
  restart_ssh || failed=y
  if [[ -f "$INSTALL_ROOT/docker-compose.yml" ]]; then
    docker compose -p xray-vps-setup -f "$INSTALL_ROOT/docker-compose.yml" up -d || { failed=y; log 'Previous stack did not restart; backup retained.' >&2; }
  fi
  if [[ -f "$RELEASE_DIR/deployment.json" ]]; then
    python3 - "$RELEASE_DIR/deployment.json" "$LIB" "$failed" <<'PYMETA' || failed=y
import json,sys
sys.path.insert(0,sys.argv[2]);from setup_config import save_json
p=sys.argv[1];d=json.load(open(p));d['status']='rollback_failed' if sys.argv[3]=='y' else 'rolled_back';save_json(p,d)
PYMETA
  fi
  [[ "$failed" == n ]]
}

cleanup() {
  local status=$?
  trap - EXIT ERR INT TERM
  if [[ "$TRANSACTION_ACTIVE" == y && "$SUCCESS" != y ]]; then
    set +e
    rollback_system
    [[ $status != 0 ]] || status=1
  fi
  [[ -z "$RUN_DIR" ]] || rm -rf -- "$RUN_DIR"
  if [[ $status != 0 ]]; then log "Setup failed; review $BACKUP_DIR and Docker logs. No successful-install verdict was issued." >&2; fi
  exit "$status"
}

fetch() {
  local name=$1 whitelist=${2:-}
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ && -s "$RAW/$name" ]] || die "Missing bundled template: $name"
  envsubst "$whitelist" < "$RAW/$name"
}

preflight() {
  [[ $EUID == 0 ]] || die 'Run as root'
  [[ "$(uname -s)" == Linux && ${BASH_VERSINFO[0]} -ge 4 ]] || die 'Linux and Bash >=4 are required'
  [[ -r /etc/os-release ]] || die 'Cannot determine OS'
  source /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13) ;;
    *) die 'Supported systems: Ubuntu 22.04/24.04/26.04 and Debian 12/13' ;;
  esac
  for manager in ufw firewalld nftables; do
    if systemctl is-active --quiet "$manager.service"; then
      die "Active $manager detected. Integrate or disable it explicitly before using the managed firewall."
    fi
  done
  command -v flock >/dev/null || die 'Install util-linux first'
  [[ ! -L "$INSTALL_ROOT" ]] || die 'Install directory must not be a symlink'
  install -d -m 0700 "$INSTALL_ROOT"
  exec 9>"$INSTALL_ROOT/install.lock"
  flock -n 9 || die 'Another setup operation is running'
  ARCH=$(dpkg --print-architecture)
  [[ "$ARCH" == amd64 || "$ARCH" == arm64 ]] || die 'Only amd64/arm64 are supported'
  export ARCH
}

install_dependencies() {
  # Repair the two public files affected by an earlier installer under umask 077.
  if [[ -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg ]]; then chmod 0644 /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; fi
  if [[ -f /etc/apt/sources.list.d/cloudflare-client.list ]]; then chmod 0644 /etc/apt/sources.list.d/cloudflare-client.list; fi
  apt-get -o DPkg::Lock::Timeout=120 update
  apt-get -o DPkg::Lock::Timeout=120 install -y ca-certificates curl gettext-base python3 openssl \
    iproute2 dnsutils unzip tar coreutils util-linux iptables openssh-server sudo gnupg
  for command in curl envsubst python3 openssl ip iptables iptables-restore ip6tables ip6tables-restore sshd ssh-keygen systemd-run; do
    command -v "$command" >/dev/null || die "Required command unavailable: $command"
  done
  systemctl is-system-running >/dev/null || [[ "$(systemctl is-system-running)" == degraded ]] || die 'systemd is not available'
}

install_docker() {
  if ! command -v docker >/dev/null; then
    local distro codename
    source /etc/os-release
    distro=$ID
    codename=${UBUNTU_CODENAME:-$VERSION_CODENAME}
    install -d -m 0755 /etc/apt/keyrings
    download "https://download.docker.com/linux/$distro/gpg" "$RUN_DIR/docker.asc"
    install -m 0644 "$RUN_DIR/docker.asc" /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$distro
Suites: $codename
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    chmod 0644 /etc/apt/sources.list.d/docker.sources
    apt-get -o DPkg::Lock::Timeout=120 update
    apt-get -o DPkg::Lock::Timeout=120 install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
  fi
  docker info >/dev/null || die 'Docker CLI exists but daemon is unavailable; fix/start it before setup'
  docker compose version >/dev/null || die 'Docker Compose plugin is missing; install it before setup'
}

download_xray_core() {
  local dest=$1 archive digest
  case "$ARCH" in amd64) archive=Xray-linux-64.zip;; arm64) archive=Xray-linux-arm64-v8a.zip;; esac
  download "https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/$archive" "$RUN_DIR/xray.zip"
  download "https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/$archive.dgst" "$RUN_DIR/xray.dgst"
  digest=$(awk '/^SHA2-256=/ {print $2}' "$RUN_DIR/xray.dgst")
  [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || die 'Release did not publish a valid SHA-256 digest'
  printf '%s  %s\n' "$digest" "$RUN_DIR/xray.zip" | sha256sum -c - >/dev/null
  mkdir -p "$dest"
  unzip -q "$RUN_DIR/xray.zip" -d "$dest"
  chmod 0700 "$dest/xray"
  [[ "$("$dest/xray" version)" == "Xray $XRAY_VERSION "* ]] || die 'Downloaded Xray version differs'
}

check_network() {
  python3 - "$STATE_FILE" "$LIB" <<'PY'
import ipaddress,json,subprocess,sys
sys.path.insert(0,sys.argv[2])
from setup_config import check_dns
s=json.load(open(sys.argv[1]))
interfaces=json.loads(subprocess.check_output(['ip','-j','addr','show']))
local={a['local'] for i in interfaces for a in i.get('addr_info',[])}
for ip in (s['ingress'],s['egress']):
    if ip and ip not in local: raise SystemExit('Split address is not assigned locally: '+ip)
records={}
for name in s['names']['grpc']+s['names']['vision']:
    addresses=[]
    for kind in ['A','AAAA']:
        out=subprocess.check_output(['dig','+short','+time=3','+tries=1',kind,name],text=True,timeout=10)
        for line in out.splitlines():
            try: addresses.append(str(ipaddress.ip_address(line)))
            except ValueError: pass
    records[name]=addresses
check_dns(s,local,records)
if s['ingress'] and not s.get('ssh'):
    raise SystemExit('Split-IP requires managed SSH/firewall settings')
PY
}

resolve_images() {
  python3 - "$STATE_FILE" "$LIB" > "$RUN_DIR/images.list" <<'PY'
import json,sys
sys.path.insert(0,sys.argv[2]);from setup_config import IMAGES
s=json.load(open(sys.argv[1]))
lock=__import__('pathlib').Path(sys.argv[1]).parent.parent.parent/'current/images.lock'
locked={}
if lock.exists():
    for line in lock.read_text().splitlines():
        name,image=line.split('=',1);locked[name]=image
for name in ['angie',s['mode']]: print(name,locked.get(name,IMAGES[name]))
PY
  : > "$RELEASE_DIR/images.lock"
  while read -r name image; do
    docker pull "$image"
    digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image")
    [[ "$digest" == *@sha256:* ]] || die "No immutable image digest for $image"
    printf '%s=%s\n' "$name" "$digest" >> "$RELEASE_DIR/images.lock"
    case "$name" in angie) ANGIE_IMAGE=$digest;; xray) XRAY_IMAGE=$digest;; marzban) MARZBAN_IMAGE=$digest;; node) NODE_IMAGE=$digest;; esac
  done < "$RUN_DIR/images.list"
  export ANGIE_IMAGE XRAY_IMAGE=${XRAY_IMAGE:-} MARZBAN_IMAGE=${MARZBAN_IMAGE:-} NODE_IMAGE=${NODE_IMAGE:-}
}
write_decoy() {
  local out="${1:-./index.html}"
  DECOY_BRAND=$(shuf -n1 -e Northwind Lumira Veltro Caldera Brixton Auralis Meridian Halcyon Everstone Tindle)
  export DECOY_BRAND
  DECOY_TAGLINE=$(shuf -n1 -e "Authentication required" "Sign in to continue" "Please sign in to continue" "Enter your credentials to continue" "Sign in to your account")
  export DECOY_TAGLINE
  export DECOY_TITLE="Sign in · $DECOY_BRAND"
  DECOY_NONCE=$(openssl rand -hex 16)
  export DECOY_NONCE
  # Dynamic year: footer is never stale and varies year-over-year.
  DECOY_YEAR=$(date +%Y)
  export DECOY_YEAR
  # One internally-consistent palette per deploy so the decoy CSS isn't a
  # byte-for-byte constant across servers (defeats palette-hash fingerprinting).
  # shuf gives the randomness (bash, not JS). Each theme keeps bg-vs-fg contrast
  # correct (incl. the light theme) so every variant is a legible sign-in gate.
  case "$(shuf -n1 -e 1 2 3 4)" in
    1) # github-dark (original)
      export DECOY_BG="#0d1117"; export DECOY_PANEL="#161b22"; export DECOY_BORDER="#30363d"
      export DECOY_FG="#e6edf3"; export DECOY_MUTED="#8b949e"
      export DECOY_ACCENT="#2f81f7"; export DECOY_ACCENT2="#1f6feb"
      export DECOY_ACCENT_FG="#ffffff"; export DECOY_INPUT_BG="#0d1117" ;;
    2) # slate / indigo (dark)
      export DECOY_BG="#0f172a"; export DECOY_PANEL="#1e293b"; export DECOY_BORDER="#334155"
      export DECOY_FG="#e2e8f0"; export DECOY_MUTED="#94a3b8"
      export DECOY_ACCENT="#6366f1"; export DECOY_ACCENT2="#4f46e5"
      export DECOY_ACCENT_FG="#ffffff"; export DECOY_INPUT_BG="#0f172a" ;;
    3) # light (dark fg on light bg keeps contrast correct)
      export DECOY_BG="#f6f8fa"; export DECOY_PANEL="#ffffff"; export DECOY_BORDER="#d0d7de"
      export DECOY_FG="#1f2328"; export DECOY_MUTED="#656d76"
      export DECOY_ACCENT="#0969da"; export DECOY_ACCENT2="#0860ca"
      export DECOY_ACCENT_FG="#ffffff"; export DECOY_INPUT_BG="#ffffff" ;;
    4) # midnight / teal (dark)
      export DECOY_BG="#0b1220"; export DECOY_PANEL="#111c2e"; export DECOY_BORDER="#1f2d44"
      export DECOY_FG="#dbe7f0"; export DECOY_MUTED="#7d93a8"
      export DECOY_ACCENT="#14b8a6"; export DECOY_ACCENT2="#0d9488"
      export DECOY_ACCENT_FG="#04201c"; export DECOY_INPUT_BG="#0b1220" ;;
  esac
  mkdir -p "$(dirname "$out")"
  chmod 0755 "$(dirname "$out")"
  fetch "decoy" '$DECOY_BRAND $DECOY_TAGLINE $DECOY_TITLE $DECOY_NONCE $DECOY_YEAR $DECOY_BG $DECOY_PANEL $DECOY_BORDER $DECOY_FG $DECOY_MUTED $DECOY_ACCENT $DECOY_ACCENT2 $DECOY_ACCENT_FG $DECOY_INPUT_BG' > "$out"
  # Angie workers serve this public page as an unprivileged user.
  chmod 0644 "$out"
}

write_extra_decoys() {
  local name
  mkdir -p ./www
  chmod 0755 ./www
  for name in "${VLESS_SNIS[@]:1}"; do
    case "$name" in
      *".$VLESS_DOMAIN") : ;;                       # subdomain of main -> shares /tmp
      *) write_decoy "./www/$name/index.html" ;;    # separate domain -> own decoy
    esac
  done
}

inject_angie_extra_sni() {
  local conf="$1"
  python3 - "$conf" << 'PYEOF'
import os, sys
conf = sys.argv[1]
main = os.environ['VLESS_DOMAIN']
extra = os.environ['VLESS_SNI_EXTRA'].split()
with open(conf) as f:
    text = f.read()

acme_lines = ''.join(
    f"    acme_client vless_s{i} https://acme-v02.api.letsencrypt.org/directory;\n"
    for i, _ in enumerate(extra, 1)
)

def block(i, name):
    root = '/tmp' if name == main or name.endswith('.' + main) else f'/var/www/{name}'
    return f"""
    server {{
        listen                     127.0.0.1:4123 ssl;
        http2                      on;

        set_real_ip_from           127.0.0.1;
        real_ip_header             proxy_protocol;

        server_name                {name};

        acme vless_s{i};
        ssl_certificate $acme_cert_vless_s{i};
        ssl_certificate_key $acme_cert_key_vless_s{i};

        ssl_protocols              TLSv1.2 TLSv1.3;
        ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers  on;

        ssl_stapling               on;
        ssl_stapling_verify        on;
        resolver                   1.1.1.1 valid=60s;
        resolver_timeout           2s;

        location = /robots.txt {{
            default_type text/plain;
            return 200 "User-agent: *\\nDisallow:\\n";
        }}

        location = /favicon.ico {{
            return 204;
        }}

        location / {{
            root {root};
            index index.html;
            try_files $uri $uri/ =404;
        }}

        error_page 404 @notfound;
        location @notfound {{
            default_type text/html;
            return 404 "<!doctype html><title>404 Not Found</title><h1>Not Found</h1>";
        }}
    }}
"""

server_blocks = ''.join(block(i, n) for i, n in enumerate(extra, 1))

anchor = 'acme_client vless https://acme-v02.api.letsencrypt.org/directory;\n'
idx = text.find(anchor)
if idx == -1:
    sys.stderr.write("inject_angie_extra_sni: acme_client anchor not found\n")
    sys.exit(1)
ins = idx + len(anchor)
text = text[:ins] + acme_lines + text[ins:]

close = text.rfind('}')        # final brace closes the http {} block
if close == -1:
    sys.stderr.write("inject_angie_extra_sni: closing brace not found\n")
    sys.exit(1)
text = text[:close] + server_blocks + text[close:]

with open(conf, 'w') as f:
    f.write(text)
PYEOF
}

inject_angie_stream() {
  local conf="$1"
  python3 - "$conf" << 'PYEOF'
import os, sys
conf = sys.argv[1]
grpc = [n for n in os.environ.get('VLESS_SNI_GRPC', '').split(',') if n]
vision = [n for n in os.environ.get('VLESS_SNI_VISION', '').split(',') if n]
listen_addr = os.environ.get('LISTEN_ADDR', '0.0.0.0')
listen = '443' if listen_addr in ('', '0.0.0.0') else f'{listen_addr}:443'

ipv6 = '        listen      [::]:443;\n' if listen_addr in ('', '0.0.0.0') and os.path.exists('/proc/net/if_inet6') else ''

map_lines = ''.join(f'        {n}  127.0.0.1:8443;\n' for n in grpc)
map_lines += ''.join(f'        {n}  127.0.0.1:8444;\n' for n in vision)

block = f"""stream {{
    map $ssl_preread_server_name $xray_backend {{
{map_lines}        default  127.0.0.1:8443;
    }}

    server {{
        listen      {listen};
{ipv6}        ssl_preread on;
        proxy_pass  $xray_backend;
    }}
}}

"""

with open(conf) as f:
    text = f.read()
idx = text.find('http {')
if idx == -1:
    sys.stderr.write('inject_angie_stream: http block not found\n')
    sys.exit(1)
text = text[:idx] + block + text[idx:]
with open(conf, 'w') as f:
    f.write(text)
PYEOF
}

render_deployment() {
  local existing='' env_settings compose_template
  env_settings=$(python3 "$LIB/setup_config.py" export "$STATE_FILE")
  eval "$env_settings"
  export RELEASE_DIR INSTALL_ROOT XRAY_VERSION
  mapfile -t VLESS_SNIS < <(python3 - "$STATE_FILE" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]));print('\n'.join(s['names']['grpc']+s['names']['vision']))
PY
)
  cd "$RELEASE_DIR"
  mkdir -p www marzban xray
  chmod 0755 www
  # Preserve existing decoy pages on repair: no needless branding/nonce churn.
  if [[ -n "$OLD_CURRENT" && -f "$OLD_CURRENT/index.html" ]]; then
    cp "$OLD_CURRENT/index.html" ./index.html
    cp -a "$OLD_CURRENT/www/." ./www/ 2>/dev/null || true
    chmod 0644 ./index.html
  else
    write_decoy
  fi
  write_extra_decoys
  if [[ "$INSTALL_MODE" == node ]]; then
    compose_template=compose-node
    fetch angie '$VLESS_DOMAIN' > ./angie.conf
    python3 "$LIB/panel_api.py" prepare "$STATE_FILE" ./api-transaction.json ./ssl_client_cert.pem "${OLD_CURRENT:+$OLD_CURRENT/state.json}"
  else
    compose_template="compose-$INSTALL_MODE"
    if [[ "$INSTALL_MODE" == marzban ]]; then
      fetch marzban '$MARZBAN_USER $MARZBAN_PASS $MARZBAN_PATH $MARZBAN_SUB_PATH $VLESS_DOMAIN' > ./marzban/.env
      fetch angie-marzban '$VLESS_DOMAIN $MARZBAN_PATH $MARZBAN_SUB_PATH $HAPP_BLOCK' > ./angie.conf
      [[ ! -f "$INSTALL_ROOT/marzban/xray_config.json" ]] || existing="$INSTALL_ROOT/marzban/xray_config.json"
      [[ -z "$OLD_CURRENT" ]] || existing="$OLD_CURRENT/marzban/xray_config.json"
      config_file=./marzban/xray_config.json
    else
      fetch angie '$VLESS_DOMAIN' > ./angie.conf
      [[ ! -f "$INSTALL_ROOT/xray/config.json" ]] || existing="$INSTALL_ROOT/xray/config.json"
      [[ -z "$OLD_CURRENT" ]] || existing="$OLD_CURRENT/xray/config.json"
      config_file=./xray/config.json
    fi
    local args=("$STATE_FILE" "$RAW/xray" "$config_file")
    [[ -z "$existing" ]] || args+=("$existing")
    python3 "$LIB/setup_config.py" render-server "${args[@]}"
    chmod 0600 "$config_file"
  fi
  if [[ -n "$VLESS_SNI_EXTRA" ]]; then inject_angie_extra_sni ./angie.conf; fi
  inject_angie_stream ./angie.conf
  # The HTTP challenge listener follows the same network policy as Reality.
  if [[ -n "$INGRESS_IP" ]]; then
    python3 - ./angie.conf "$INGRESS_IP" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.read_text()
s=s.replace('listen 80;',f'listen {sys.argv[2]}:80;').replace('        listen [::]:80;\n','')
p.write_text(s)
PY
  fi
  chmod 0644 ./angie.conf
  fetch "$compose_template" '$RELEASE_DIR $INSTALL_ROOT $XRAY_IMAGE $MARZBAN_IMAGE $NODE_IMAGE $ANGIE_IMAGE' > ./docker-compose.yml
  chmod 0600 ./docker-compose.yml
  docker compose -p xray-vps-setup -f ./docker-compose.yml config --quiet
}

warp_install() {
  # This function is called in a conditional: every failure must be explicit.
  local key=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  local source=/etc/apt/sources.list.d/cloudflare-client.list
  download 'https://pkg.cloudflareclient.com/pubkey.gpg' "$RUN_DIR/warp-key.asc" || return 1
  gpg --batch --yes --dearmor --output "$RUN_DIR/warp-key.gpg" "$RUN_DIR/warp-key.asc" || return 1
  install -m 0644 "$RUN_DIR/warp-key.gpg" "$key" || return 1
  source /etc/os-release
  printf 'deb [signed-by=%s] https://pkg.cloudflareclient.com/ %s main\n' "$key" "$VERSION_CODENAME" > "$source" || return 1
  chmod 0644 "$source" || return 1
  if ! apt-get -o DPkg::Lock::Timeout=120 update || ! apt-get -o DPkg::Lock::Timeout=120 install -y cloudflare-warp; then
    # A broken optional source must not poison subsequent apt updates.
    rm -f "$source"
    return 1
  fi
  warp-cli --accept-tos registration show >/dev/null 2>&1 || warp-cli --accept-tos registration new || return 1
  warp-cli --accept-tos mode proxy || return 1
  warp-cli --accept-tos proxy port 40000 || return 1
  warp-cli --accept-tos connect || return 1
  for attempt in $(seq 1 8); do
    if curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
      --socks5-hostname 127.0.0.1:40000 https://api.ipify.org > "$RUN_DIR/warp-ip"; then
      python3 -c 'import ipaddress,sys;ipaddress.ip_address(open(sys.argv[1]).read().strip())' "$RUN_DIR/warp-ip" || return 1
      return 0
    fi
    sleep 2
  done
  return 1
}

configure_warp() {
  [[ "$INSTALL_MODE" == xray ]] || return 0
  local ready=n file
  if [[ "$CONFIGURE_WARP" == y ]]; then
    # Preserve an existing repository when an optional installation fails.
    local key=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    local source=/etc/apt/sources.list.d/cloudflare-client.list
    for file in "$key" "$source"; do
      [[ ! -e "$file" ]] || cp -a "$file" "$RUN_DIR/$(basename "$file").before"
    done
    if warp_install; then
      ready=y
    else
      for file in "$key" "$source"; do
        if [[ -e "$RUN_DIR/$(basename "$file").before" ]]; then
          cp -a "$RUN_DIR/$(basename "$file").before" "$file"
        else
          rm -f "$file"
        fi
      done
      log 'WARNING: WARP setup/probe failed; deployment will use direct routing.'
    fi
  fi
  python3 - "$STATE_FILE" "$RELEASE_DIR/xray/config.json" "$ready" "$LIB" <<'PY'
import json,sys
sys.path.insert(0,sys.argv[4]);from setup_config import save_json
state=json.load(open(sys.argv[1]));config=json.load(open(sys.argv[2]));ready=sys.argv[3]=='y'
config['outbounds']=[o for o in config['outbounds'] if o.get('tag')!='warp']
config['routing']['rules']=[r for r in config['routing']['rules'] if r.get('outboundTag')!='warp']
if ready:
    config['outbounds'].append({'tag':'warp','protocol':'socks','settings':{'servers':[{'address':'127.0.0.1','port':40000}]}})
    config['routing']['rules'].append({'type':'field','outboundTag':'warp','domain':['geosite:category-ru','domain:ru','domain:su','domain:xn--p1ai']})
state['warp']=ready
save_json(sys.argv[1],state);save_json(sys.argv[2],config)
PY
}

validate_deployment() {
  if [[ "$INSTALL_MODE" == node ]]; then
    python3 - "$RELEASE_DIR/api-transaction.json" "$RELEASE_DIR/node-config-test.json" "$LIB" <<'PY'
import json,sys
sys.path.insert(0,sys.argv[3]);from setup_config import save_json
save_json(sys.argv[2],json.load(open(sys.argv[1]))['desired_core'])
PY
    "$RELEASE_DIR/xray-core/xray" run -test -config "$RELEASE_DIR/node-config-test.json"
  else
    "$RELEASE_DIR/xray-core/xray" run -test -config "$RELEASE_DIR/$([[ "$INSTALL_MODE" == marzban ]] && echo marzban/xray_config.json || echo xray/config.json)"
  fi
  if [[ -f "$RELEASE_DIR/client.json" ]]; then
    "$RELEASE_DIR/xray-core/xray" run -test -config "$RELEASE_DIR/client.json"
  fi
  # Disposable validator, no host network or service port binding.
  docker run --rm --entrypoint angie -v "$RELEASE_DIR/angie.conf:/etc/angie/angie.conf:ro" \
    "$ANGIE_IMAGE" -t
}

checkpoint() {
  BACKUP_DIR=$(mktemp -d "$INSTALL_ROOT/backups/$(date -u +%Y%m%dT%H%M%S).XXXXXX")
  [[ ! -e "$INSTALL_ROOT/docker-compose.yml" && ! -L "$INSTALL_ROOT/docker-compose.yml" ]] || cp -a "$INSTALL_ROOT/docker-compose.yml" "$BACKUP_DIR/docker-compose.yml"
  [[ ! -f /etc/ssh/sshd_config.d/00-xray-vps-setup.conf ]] || cp -a /etc/ssh/sshd_config.d/00-xray-vps-setup.conf "$BACKUP_DIR/ssh.conf"
  [[ ! -f /etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf ]] || cp -a /etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf "$BACKUP_DIR/socket.conf"
  iptables-save > "$BACKUP_DIR/ipv4"
  if [[ -e /proc/net/if_inet6 ]]; then ip6tables-save > "$BACKUP_DIR/ipv6"; fi
  # Save legacy config files as well; the existing database is never replaced by this installer.
  for item in angie.conf xray marzban; do
    [[ ! -e "$INSTALL_ROOT/$item" ]] || cp -a "$INSTALL_ROOT/$item" "$BACKUP_DIR/"
  done
  [[ ! -d "$INSTALL_ROOT/lib" ]] || cp -a "$INSTALL_ROOT/lib" "$BACKUP_DIR/lib"
  [[ ! -f "$INSTALL_ROOT/ssh-transition.env" ]] || cp -a "$INSTALL_ROOT/ssh-transition.env" "$BACKUP_DIR/ssh-transition.env"
  [[ ! -f /etc/systemd/system/xray-setup-firewall.service ]] || cp -a /etc/systemd/system/xray-setup-firewall.service "$BACKUP_DIR/firewall.service"
  python3 - "$RELEASE_DIR/deployment.json" "$LIB" "$BACKUP_DIR" "$OLD_CURRENT" <<'PYMETA'
import sys
sys.path.insert(0,sys.argv[2]);from setup_config import save_json
save_json(sys.argv[1],{'status':'activating','backup':sys.argv[3],'previous':sys.argv[4]})
PYMETA
  ln -sfn "$RELEASE_DIR" "$INSTALL_ROOT/.last-transaction-next"
  mv -Tf "$INSTALL_ROOT/.last-transaction-next" "$INSTALL_ROOT/last-transaction"
  TRANSACTION_ACTIVE=y
}

publish() {
  if [[ -f "$INSTALL_ROOT/docker-compose.yml" ]]; then
    docker compose -p xray-vps-setup -f "$INSTALL_ROOT/docker-compose.yml" stop
    if [[ -d "$INSTALL_ROOT/marzban_lib" ]]; then cp -a "$INSTALL_ROOT/marzban_lib" "$BACKUP_DIR/database"; fi
  fi
  if [[ -d "$INSTALL_ROOT/marzban/templates" ]]; then
    install -d -m 0700 "$INSTALL_ROOT/marzban_lib/templates"
    cp -an "$INSTALL_ROOT/marzban/templates/." "$INSTALL_ROOT/marzban_lib/templates/"
  fi
  cp -a "$LIB/." "$INSTALL_ROOT/lib/"
  source "$LIB/ssh.sh"
  source "$LIB/firewall.sh"
  prepare_ssh
  python3 - "$STATE_FILE" "$LIB" "${SSH_OLD_PORTS[*]}" <<'PY'
import json,sys
sys.path.insert(0,sys.argv[2]);from setup_config import save_json
s=json.load(open(sys.argv[1]));s['ssh_old_ports']=[int(p) for p in sys.argv[3].split()];save_json(sys.argv[1],s)
PY
  apply_firewall
  ln -sfn "$RELEASE_DIR" "$INSTALL_ROOT/.current-next"
  mv -Tf "$INSTALL_ROOT/.current-next" "$INSTALL_ROOT/current"
  ln -sfn "$INSTALL_ROOT/current/docker-compose.yml" "$INSTALL_ROOT/.compose-next"
  mv -Tf "$INSTALL_ROOT/.compose-next" "$INSTALL_ROOT/docker-compose.yml"
  docker compose -p xray-vps-setup -f "$INSTALL_ROOT/docker-compose.yml" up -d
  if [[ "$INSTALL_MODE" == marzban ]]; then
    local imported=n
    for ((attempt=0; attempt<12; attempt++)); do
      if docker exec marzban marzban-cli admin import-from-env >/dev/null 2>&1; then imported=y; break; fi
      sleep 3
    done
    [[ "$imported" == y ]] || die 'Panel administrator initialization failed'
    python3 "$LIB/panel_api.py" local-hosts "$STATE_FILE" "${OLD_CURRENT:+$OLD_CURRENT/state.json}"
  elif [[ "$INSTALL_MODE" == node ]]; then
    python3 "$LIB/panel_api.py" apply "$RELEASE_DIR/api-transaction.json"
  fi
  python3 "$LIB/health.py" "$STATE_FILE"
  for name in angie "$([[ "$INSTALL_MODE" == node ]] && echo marzban-node || echo "$INSTALL_MODE")"; do
    [[ "$(docker inspect --format '{{.State.Running}} {{.RestartCount}}' "$name")" == 'true 0' ]] || die "$name is stopped/restarting"
  done
  cat > /etc/systemd/system/xray-setup-firewall.service <<'EOF'
[Unit]
Description=Managed xray-vps-setup firewall chain
After=network-pre.target netfilter-persistent.service
Before=docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash /opt/xray-vps-setup/lib/restore-firewall.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/xray-setup-firewall.service
  systemctl daemon-reload
  systemctl enable xray-setup-firewall.service
  python3 - "$RELEASE_DIR/deployment.json" "$LIB" <<'PYMETA'
import json,sys
sys.path.insert(0,sys.argv[2]);from setup_config import save_json
d=json.load(open(sys.argv[1]));d['status']='committed';save_json(sys.argv[1],d)
PYMETA
  if [[ "$INSTALL_MODE" == node ]]; then python3 "$LIB/panel_api.py" commit "$RELEASE_DIR/api-transaction.json"; fi
  SUCCESS=y
  TRANSACTION_ACTIVE=n
}

print_result() {
  python3 - "$STATE_FILE" "$RAW" "$RELEASE_DIR" "$LIB" <<'PY'
import json,pathlib,sys,urllib.parse
sys.path.insert(0,sys.argv[4]);from setup_config import atomic_write,render
s=json.load(open(sys.argv[1]));release=pathlib.Path(sys.argv[3]);text=['Deployment credentials (activation status is recorded in deployment.json).']
if s['mode']=='marzban':
    a=s['admin'];text += [f"Panel: https://{s['domain']}/{a['path']}/",f"User: {a['user']}",f"Password: {a['password']}"]
elif s['mode']=='node':
    text += ['Node connected to panel: '+s['panel_domain']]
else:
    k=s['keys'];values={'VLESS_DOMAIN':s['domain'],'XRAY_UUID':k['uuid'],'XRAY_PBK':k['public'],'XRAY_SID':k['short_ids'][0],
        'XRAY_SERVICE_NAME':k['service'],'CLIENT_SOCKS_PORT':10808,'CLIENT_SOCKS_USER':s['socks']['user'],'CLIENT_SOCKS_PASS':s['socks']['password']}
    full=render((pathlib.Path(sys.argv[2])/'xray_full_client').read_text(),values)
    atomic_write(release/'client.json',full)
    text.append('Client config with SOCKS authentication: '+str(release/'client.json'))
    for transport,names in s['names'].items():
        for number,name in enumerate(names,1):
            params={'type':'grpc' if transport=='grpc' else 'tcp','security':'reality','pbk':k['public'],'fp':'firefox','sni':name,'sid':k['short_ids'][0]}
            if transport=='grpc': params.update(serviceName=k['service'],mode='gun')
            else: params['flow']='xtls-rprx-vision'
            label=f"{s['connection_name']} [{transport}] #{number}" if s.get('connection_name') else transport
            text.append(f"vless://{k['uuid']}@{name}:443?{urllib.parse.urlencode(params)}#{urllib.parse.quote(label, safe='')}")
if s.get('ssh'):
    ssh=s['ssh'];text += [f"SSH: {ssh['user']} port {ssh['port']}", 'Saved sudo password (newly created user only): '+ssh.get('password','')]
    if not s.get('ssh_confirmed'):
        text += ['Old SSH access remains temporarily available. Connect as the new user, then run:',
                 'sudo --preserve-env=SSH_CONNECTION bash /opt/xray-vps-setup/lib/confirm-access.sh']
text += ['Credentials and recovery files contain secrets; keep them private.']
atomic_write(release/'credentials.txt','\n'.join(text)+'\n');print('\n'.join(text))
PY
}

main() {
  case "$ACTION" in install|repair|reconfigure|check|recover) ;; -h|--help)
    log 'Usage: bash vps-setup.sh [install|repair|reconfigure|check|recover]'; return 0;; *) die 'Unknown action';; esac
  if [[ ! -f "$LIB/setup_config.py" ]]; then bootstrap "$@"; return; fi
  preflight
  RUN_DIR=$(mktemp -d "$INSTALL_ROOT/.work.XXXXXX")
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ -f "$INSTALL_ROOT/last-transaction/deployment.json" ]]; then
    local pending
    pending=$(python3 - "$INSTALL_ROOT/last-transaction" <<'PYMETA'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);d=json.loads((p/'deployment.json').read_text())
a=json.loads((p/'api-transaction.json').read_text()) if (p/'api-transaction.json').exists() else {}
print('yes' if d['status'] in ('activating','rollback_failed') or a.get('status') in ('applied','rollback_failed') else 'no')
PYMETA
)
    if [[ "$ACTION" == recover ]]; then
      [[ "$pending" == yes ]] || die 'No interrupted transaction to recover'
      RELEASE_DIR=$(readlink -f "$INSTALL_ROOT/last-transaction")
      local metadata
      metadata=$(python3 - "$RELEASE_DIR/deployment.json" <<'PYMETA'
import json,shlex,sys
d=json.load(open(sys.argv[1]));print('BACKUP_DIR='+shlex.quote(d['backup']));print('OLD_CURRENT='+shlex.quote(d['previous']))
PYMETA
)
      eval "$metadata"
      [[ "$BACKUP_DIR" == "$INSTALL_ROOT"/backups/* && -d "$BACKUP_DIR" ]] || die 'Invalid recovery backup path'
      if [[ -f "$RELEASE_DIR/api-transaction.json" ]]; then
        python3 "$LIB/panel_api.py" recover "$RELEASE_DIR/api-transaction.json" || log 'API recovery failed; attempting local recovery and retaining the API journal.' >&2
      fi
      rollback_system
      SUCCESS=y
      log 'Interrupted transaction recovery completed; verify the previous deployment.'
      return
    fi
    [[ "$pending" == no ]] || die 'Interrupted transaction found. Run recover before changing the installation.'
  elif [[ "$ACTION" == recover ]]; then
    die 'No recovery journal exists'
  fi
  if [[ "$ACTION" != check ]]; then install_dependencies; install_docker; fi
  if [[ -L "$INSTALL_ROOT/current" ]]; then OLD_CURRENT=$(readlink -f "$INSTALL_ROOT/current"); fi
  if [[ "$ACTION" == check ]]; then
    [[ -n "$OLD_CURRENT" ]] || die 'No managed installation to check'
    STATE_FILE="$OLD_CURRENT/state.json"
    python3 "$LIB/setup_config.py" validate "$STATE_FILE"
    local settings
    settings=$(python3 "$LIB/setup_config.py" export "$STATE_FILE")
    eval "$settings"
    settings=$(python3 - "$STATE_FILE" <<'PY'
import json,shlex,sys
s=json.load(open(sys.argv[1]));ssh=s.get('ssh') or {}
for key,value in [('SSH_NEW_PORT',str(ssh.get('port',''))),('SSH_USER',ssh.get('user','')),('SSH_CONFIRMED','y' if s.get('ssh_confirmed') else 'n')]:
    print(key+'='+shlex.quote(value))
PY
)
    eval "$settings"
    source "$LIB/ssh.sh"
    source "$LIB/firewall.sh"
    check_firewall || die 'Managed firewall jump or required rules are missing'
    systemctl is-enabled --quiet xray-setup-firewall.service || die 'Firewall boot restoration is not enabled'
    if [[ -n "$SSH_NEW_PORT" ]]; then
      sshd -t
      check_ssh_listener || die 'Saved SSH port has no IPv4 listener'
      if [[ "$SSH_CONFIRMED" == y ]]; then check_ssh_policy || die 'Confirmed SSH authentication policy has drifted'; fi
    fi
    check_network
    docker compose -p xray-vps-setup -f "$INSTALL_ROOT/docker-compose.yml" config --quiet
    python3 "$LIB/health.py" "$STATE_FILE" --runtime
    log 'Existing deployment container, firewall, SSH and TLS/HTTP checks passed.'
    return
  fi
  install -d -m 0700 "$INSTALL_ROOT/releases" "$INSTALL_ROOT/backups" "$INSTALL_ROOT/lib" "$INSTALL_ROOT/marzban_lib" "$INSTALL_ROOT/node_data"
  RELEASE_DIR=$(mktemp -d "$INSTALL_ROOT/releases/$(date -u +%Y%m%dT%H%M%S).XXXXXX")
  STATE_FILE="$RELEASE_DIR/state.json"
  if [[ -n "$OLD_CURRENT" && -x "$OLD_CURRENT/xray-core/xray" && "$("$OLD_CURRENT/xray-core/xray" version)" == "Xray $XRAY_VERSION "* ]]; then
    cp -a "$OLD_CURRENT/xray-core" "$RELEASE_DIR/xray-core"
  else
    download_xray_core "$RELEASE_DIR/xray-core"
  fi
  if [[ -n "$OLD_CURRENT" ]]; then
    cp "$OLD_CURRENT/state.json" "$STATE_FILE"
    if [[ "$ACTION" == reconfigure ]]; then python3 "$LIB/configure.py" "$STATE_FILE" "$RELEASE_DIR/xray-core/xray" "$OLD_CURRENT/state.json"; fi
    log 'Existing identity and credentials preserved.'
  elif [[ -e "$INSTALL_ROOT/docker-compose.yml" ]]; then
    python3 "$LIB/setup_config.py" import "$INSTALL_ROOT" "$STATE_FILE"
    log 'Legacy settings imported without key/password rotation.'
  else
    [[ "$ACTION" != repair ]] || die 'Nothing to repair'
    python3 "$LIB/configure.py" "$STATE_FILE" "$RELEASE_DIR/xray-core/xray"
  fi
  python3 "$LIB/setup_config.py" validate "$STATE_FILE"
  check_network
  python3 "$LIB/check_ports.py" "$STATE_FILE"
  if [[ -f "$INSTALL_ROOT/docker-compose.yml" ]]; then
    local services
    services=$(docker compose -p xray-vps-setup -f "$INSTALL_ROOT/docker-compose.yml" config --services)
    while IFS= read -r service; do
      case "$service" in angie|xray|marzban|marzban-node) ;; *) die "Existing Compose contains unmanaged service: $service; migrate explicitly";; esac
    done <<< "$services"
  fi
  resolve_images
  render_deployment
  configure_warp
  print_result > "$RUN_DIR/result-output"
  validate_deployment
  checkpoint
  publish
  log "Deployment readiness checks passed."
  cat "$RUN_DIR/result-output"
  log "Backup: $BACKUP_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
