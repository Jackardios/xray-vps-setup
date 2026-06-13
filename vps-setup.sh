#!/bin/bash

set -e

export GIT_BRANCH="main"
export GIT_REPO="Jackardios/xray-vps-setup"

# Pinned xray-core version, used consistently for keygen, uuid, the downloaded
# binary and the compose image so a deployment is reproducible.
export XRAY_VERSION="26.3.27"
export XRAY_IMAGE="ghcr.io/xtls/xray-core:${XRAY_VERSION}"

# Base URL for the template files shipped in this repo.
RAW="https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script"

# Remove transient files that may contain secrets/certs/tokens on any exit.
cleanup() {
  rm -f /tmp/xray.zip \
        /tmp/node_settings.json /tmp/node_response.json /tmp/nodes_list.json \
        /tmp/xray_config.json /tmp/xray_config_updated.json \
        /tmp/marzban_inbounds.json /tmp/marzban_hosts.json /tmp/marzban_hosts_updated.json \
        /tmp/panel_hosts.json /tmp/panel_hosts_updated.json \
        /tmp/update_servernames.py /tmp/update_hosts.py 2>/dev/null || true
}
trap cleanup EXIT

# Download a template from the repo and substitute ONLY the whitelisted vars.
# Fails loudly on network error or empty response so a broken download never
# silently produces an empty config file. Usage: fetch <url> '<$VAR1 $VAR2 ...>'
fetch() {
  local url="$1"; shift
  local content
  if ! content=$(wget -qO- "$url"); then
    echo "ERROR: failed to download $url" >&2
    exit 1
  fi
  if [ -z "$content" ]; then
    echo "ERROR: empty response from $url" >&2
    exit 1
  fi
  printf '%s' "$content" | envsubst "$@"
}

# Download and extract the xray-core binary for the current architecture.
download_xray_core() {
  local dest="$1"
  local url
  case "$ARCH" in
    amd64) url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip" ;;
    arm64) url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-arm64-v8a.zip" ;;
    *) echo "ERROR: unsupported architecture: $ARCH" >&2; exit 1 ;;
  esac
  wget -O /tmp/xray.zip "$url" || { echo "ERROR: failed to download xray-core from $url" >&2; exit 1; }
  mkdir -p "$dest"
  unzip -qo /tmp/xray.zip -d "$dest"
}

# Signal-1 hosting check (DPI-evasion): subnets of some providers have been
# historically throttled/blocked by Russian DPI regardless of a clean Reality
# config. We query OUR OWN public org via ipinfo.io and WARN (do NOT block) if
# it's on the flagged list, pointing at hyperion-cs/dpi-checkers to verify the
# specific subnet. Advisory only: a match doesn't break the install, and an
# unreachable ipinfo must never abort it.
check_hosting_asn() {
  local org
  # --max-time bounds a hung endpoint; || true keeps set -e from aborting on any
  # curl non-zero (timeout, DNS, no route). The grep below runs in an if-test, so
  # its "no match" non-zero is set -e-safe too.
  org=$(curl -s --max-time 5 https://ipinfo.io/org || true)
  if [ -z "$org" ]; then
    echo "Note: couldn't determine hosting ASN (network/timeout) — skipping hosting check"
    return 0
  fi
  if echo "$org" | grep -qiE 'selectel|yandex|hetzner|digitalocean|digital ocean|ovh'; then
    echo "============================================================"
    echo "WARNING: this server's network looks like a provider whose"
    echo "subnets have been flagged by Russian DPI:"
    echo "  $org"
    echo
    echo "Reality masking still works, but the IP range itself may be"
    echo "throttled/blocked. Verify THIS subnet before relying on it:"
    echo "  https://github.com/hyperion-cs/dpi-checkers"
    echo "Continuing — this is an advisory, not a blocker."
    echo "============================================================"
  fi
}

# Write a per-deploy-unique decoy page to the given file (default ./index.html) —
# the masking site angie serves at /. Brand/tagline/nonce are randomised on EVERY
# call so each file differs byte-for-byte, which defeats exact-hash fingerprinting
# of a shared decoy and lets separate domains in the SNI pool look like unrelated
# sites (see write_extra_decoys).
write_decoy() {
  local out="${1:-./index.html}"
  export DECOY_BRAND=$(shuf -n1 -e Northwind Lumira Veltro Caldera Brixton Auralis Meridian Halcyon Everstone Tindle)
  export DECOY_TAGLINE=$(shuf -n1 -e "Authentication required" "Sign in to continue" "Please sign in to continue" "Enter your credentials to continue" "Sign in to your account")
  export DECOY_TITLE="Sign in · $DECOY_BRAND"
  export DECOY_NONCE=$(openssl rand -hex 16)
  # Dynamic year: footer is never stale and varies year-over-year.
  export DECOY_YEAR=$(date +%Y)
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
  fetch "$RAW/decoy" '$DECOY_BRAND $DECOY_TAGLINE $DECOY_TITLE $DECOY_NONCE $DECOY_YEAR $DECOY_BG $DECOY_PANEL $DECOY_BORDER $DECOY_FG $DECOY_MUTED $DECOY_ACCENT $DECOY_ACCENT2 $DECOY_ACCENT_FG $DECOY_INPUT_BG' > "$out"
}

# Check if script started as root
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Install idn
apt-get update
apt-get install idn sudo dnsutils wamerican curl -y

# Select install mode
echo "What do you want to install?"
echo "  1) xray (standalone)"
echo "  2) marzban (panel)"
echo "  3) marzban-node (node for existing panel)"
read -ep "Enter choice [1/2/3]: "$'\n' install_choice

export INSTALL_MODE="xray"
case "$install_choice" in
  2) export INSTALL_MODE="marzban" ;;
  3) export INSTALL_MODE="node" ;;
esac

# Read domain input
read -ep "Enter your domain:"$'\n' input_domain

export VLESS_DOMAIN=$(echo "$input_domain" | idn)

# Split-IP mode: receive Reality on a hidden ingress IP and exit through a
# different (visible) IP, so a leaked exit IP can never equal the Reality entry
# IP (defeats the ingress==egress correlation attack). Needs a 2nd IPv4 already
# attached to this host by the provider. Default: no split (listen 0.0.0.0).
export LISTEN_ADDR="0.0.0.0"
split_ip_input="n"
if [[ "$INSTALL_MODE" != "node" ]]; then
  read -ep "Split-IP mode? Receive Reality on a hidden ingress IP and exit via a different IP (needs a 2nd IPv4 already attached to this server). [y/N] "$'\n' split_ip_input
  if [[ ${split_ip_input,,} == "y" ]]; then
    read -ep "Ingress IP (clients connect here; your domain's A record must point to it):"$'\n' INGRESS_IP
    read -ep "Egress IP (traffic exits here; this is the IP destinations/spyware will see):"$'\n' EGRESS_IP
    export INGRESS_IP EGRESS_IP
    # Validate format (also rejects an empty answer — an empty grep pattern would
    # otherwise match anything) AND that each IP is already on an interface, else
    # listen/sendThrough/firewall below would silently break connectivity.
    for _ip in "$INGRESS_IP" "$EGRESS_IP"; do
      if ! [[ "$_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        echo "ERROR: '$_ip' is not a valid IPv4 address." >&2
        exit 1
      fi
      if ! ip -4 addr show | grep -qwF "$_ip"; then
        echo "ERROR: $_ip is not present on any interface. Attach it via your provider first." >&2
        exit 1
      fi
    done
    if [ "$INGRESS_IP" = "$EGRESS_IP" ]; then
      echo "ERROR: ingress and egress IP must differ for split-IP mode." >&2
      exit 1
    fi
    # A single subnet ban could take both if they share a /24.
    if [ "${INGRESS_IP%.*}" = "${EGRESS_IP%.*}" ]; then
      echo "WARNING: ingress and egress look like the same /24 — a subnet ban could take both."
    fi
    export LISTEN_ADDR="$INGRESS_IP"
  fi
fi

SERVER_IPS=($(hostname -I))

# When splitting IPs the domain must point specifically at the ingress IP (that is
# where clients and ACME connect); otherwise any of this host's IPs is acceptable.
if [[ ${split_ip_input,,} == "y" ]]; then
  EXPECTED_IPS=("$INGRESS_IP")
else
  EXPECTED_IPS=("${SERVER_IPS[@]}")
fi

# Verify a hostname's A record(s) point at this server (EXPECTED_IPS). Advisory:
# every A record is collected (domains may have several), and a missing/mismatched
# record only warns and asks to continue rather than hard-failing, since DNS may
# still be propagating. Used for the main domain AND every extra SNI name — each
# must resolve here or its ACME HTTP-01 certificate won't be issued.
verify_domain_dns() {
  local host="$1"
  local resolved
  resolved=$(dig +short A "$host" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  if [ -z "$resolved" ]; then
    echo "Warning: '$host' has no DNS record"
    read -ep "Are you sure? '$host' has no DNS record. Without it ACME can't issue its certificate and that SNI won't work [y/N]"$'\n' prompt_response
    if [[ "$prompt_response" =~ ^([yY])$ ]]; then
      echo "Ok, proceeding without DNS verification for '$host'"
      return
    fi
    echo "Come back later"
    exit 1
  fi
  local resolved_ip server_ip
  for resolved_ip in $resolved; do
    for server_ip in "${EXPECTED_IPS[@]}"; do
      if [ "$resolved_ip" == "$server_ip" ]; then
        echo "✓ DNS record for '$host' points to this server"
        return
      fi
    done
  done
  echo "Warning: '$host' resolves but points to a different IP"
  echo "  Resolves to: $(echo $resolved | tr '\n' ' ')"
  echo "  Expected IP(s): ${EXPECTED_IPS[*]}"
  read -ep "Continue anyway? [y/N]"$'\n' prompt_response
  if [[ "$prompt_response" =~ ^([yY])$ ]]; then
    echo "Ok, proceeding"
  else
    echo "Come back later"
    exit 1
  fi
}

verify_domain_dns "$VLESS_DOMAIN"

# Extra SNI names for traffic distribution (June-2026 DPI Signal-3 mitigation: the
# block keys on parallel-connection rate PER SNI, so concentrating every client on
# one name is what trips it). Each extra name becomes an additional Reality
# serverName + Angie vhost + Marzban host, spreading connections across names.
# Names may be subdomains of the main domain OR separate domains; each needs its own
# A record pointing here. Empty input keeps the original single-SNI behaviour.
VLESS_SNIS=("$VLESS_DOMAIN")
echo
echo "Optional: add extra SNI names to spread Reality traffic across several names."
echo "Each may be a subdomain of $VLESS_DOMAIN or a separate domain, and must have an"
echo "A record pointing to this server. Press Enter on an empty line to stop."
for i in 1 2 3 4; do
  read -ep "Extra SNI #$i (blank to skip):"$'\n' extra_sni_input
  [ -z "$extra_sni_input" ] && break
  extra_sni=$(echo "$extra_sni_input" | idn)
  _dup=false
  for _n in "${VLESS_SNIS[@]}"; do [ "$_n" == "$extra_sni" ] && _dup=true; done
  if [ "$_dup" = true ]; then
    echo "  '$extra_sni' already in the pool, skipping"
    continue
  fi
  verify_domain_dns "$extra_sni"
  VLESS_SNIS+=("$extra_sni")
done

# Derived forms reused below: EXTRA = just the additional names (space separated,
# for Angie server_name); ALL = every name comma separated, main domain first
# (for the JSON/API steps). Empty EXTRA => single-SNI, fully backward compatible.
VLESS_SNI_EXTRA="${VLESS_SNIS[*]:1}"
VLESS_SNI_ALL=$(IFS=,; echo "${VLESS_SNIS[*]}")
export VLESS_SNI_EXTRA VLESS_SNI_ALL

# Advisory hosting/ASN check for every install mode (xray/marzban/node): all of
# them terminate Reality on this host's subnet, so the warning is mode-agnostic.
check_hosting_asn

if [[ "$INSTALL_MODE" == "node" ]]; then
  read -ep "Enter marzban panel domain (e.g. panel.example.com):"$'\n' PANEL_DOMAIN
  export PANEL_DOMAIN
  read -ep "Enter panel admin username:"$'\n' PANEL_USER
  export PANEL_USER
  read -s -ep "Enter panel admin password:"$'\n' PANEL_PASS
  export PANEL_PASS
  echo
fi

if [[ "$INSTALL_MODE" == "marzban" ]]; then
  marzban_input="y"
else
  marzban_input="n"
fi

# Happ exposes an unauthenticated xray API on the client's localhost, so a single
# compromised user can dump/alter configs. Optionally refuse it at the subscription
# endpoint. Soft/spoofable nudge (Happ is popular) — default off.
block_happ_input="n"
if [[ "$INSTALL_MODE" == "marzban" ]]; then
  read -ep "Block the Happ client from fetching subscriptions (it exposes an unauthenticated localhost API)? [y/N] "$'\n' block_happ_input
fi

read -ep "Do you want to create a user to connect to server as non-root and forbid root access? Do this on first run only. [y/N] "$'\n' configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  # Read SSH port
  read -ep "Enter SSH port. Default 22, can't use ports: 80, 443 and 4123:"$'\n' input_ssh_port

  while [[ "$input_ssh_port" -eq "80" || "$input_ssh_port" -eq "443" || "$input_ssh_port" -eq "4123" ]]; do
    read -ep "No, ssh can't use $input_ssh_port as port, write again:"$'\n' input_ssh_port
  done
  # Read SSH Pubkey
  read -ep "Enter SSH public key:"$'\n' input_ssh_pbk
  pbk_tmp=$(mktemp)
  printf '%s\n' "$input_ssh_pbk" > "$pbk_tmp"
  if ! ssh-keygen -l -f "$pbk_tmp" >/dev/null 2>&1; then
    rm -f "$pbk_tmp"
    echo "Can't verify the public key. Try again and make sure to include 'ssh-rsa' or 'ssh-ed25519' followed by a comment at the end."
    exit 1
  fi
  rm -f "$pbk_tmp"
fi

configure_warp_input="n"
if [[ "$INSTALL_MODE" != "node" ]]; then
  read -ep "Do you want to install WARP and use it on russian websites? [y/N] "$'\n' configure_warp_input
  if [[ ${configure_warp_input,,} == "y" ]]; then
    if ! curl -I https://api.cloudflareclient.com --connect-timeout 10 > /dev/null 2>&1; then
      echo "Warp can't be used"
      configure_warp_input="n"
    fi
  fi
fi

# Check congestion protocol
if sysctl net.ipv4.tcp_congestion_control | grep bbr; then
    echo "BBR is already used"
else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null
    echo "Enabled BBR"
fi

export ARCH=$(dpkg --print-architecture)

yq_install() {
  wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$ARCH -O /usr/bin/yq && chmod +x /usr/bin/yq
}

yq_install

docker_install() {
  curl -fsSL https://get.docker.com | sh
}

if ! command -v docker 2>&1 >/dev/null; then
    docker_install
fi

# Generate values for XRay
export SSH_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
export SSH_USER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export SSH_PORT=${input_ssh_port:-22}
if [[ "$INSTALL_MODE" != "node" ]]; then
  # Reality shortIds — real (non-empty) ids of varying even length, so a client
  # must present a known id to connect. The first is the one handed to clients;
  # the extras let you issue distinct ids per device later without reconfiguring.
  export XRAY_SID=$(openssl rand -hex 8)
  export XRAY_SID2=$(openssl rand -hex 4)
  export XRAY_SID3=$(openssl rand -hex 2)
  # One x25519 invocation gives both keys. Parse by the last whitespace field so
  # we are robust to xray's changing labels ("Public key" -> "Password" ->
  # "Password (PublicKey)").
  xray_keys=$(docker run --rm "$XRAY_IMAGE" x25519)
  export XRAY_PIK=$(printf '%s\n' "$xray_keys" | grep -iE 'private' | awk '{print $NF}')
  export XRAY_PBK=$(printf '%s\n' "$xray_keys" | grep -iE 'password|public' | awk '{print $NF}')
  export XRAY_UUID=$(docker run --rm "$XRAY_IMAGE" uuid)
  if [[ -z "$XRAY_PIK" || -z "$XRAY_PBK" || -z "$XRAY_UUID" ]]; then
    echo "ERROR: failed to generate xray keys/uuid (image $XRAY_IMAGE)" >&2
    exit 1
  fi
fi

# Write a distinct decoy page for each SEPARATE domain in the SNI pool (a name that
# is NOT a subdomain of the main domain). Subdomains reuse the main decoy (/tmp) —
# natural for one site under several hostnames — while separate domains get their
# own brand/palette/nonce so byte-identical pages can't re-link them by content hash.
write_extra_decoys() {
  local name
  for name in ${VLESS_SNIS[@]:1}; do
    case "$name" in
      *".$VLESS_DOMAIN") : ;;                       # subdomain of main -> shares /tmp
      *) write_decoy "./www/$name/index.html" ;;    # separate domain -> own decoy
    esac
  done
}

# Inject, per extra SNI name, an INDEPENDENT acme_client and a decoy-only vhost into
# the already-rendered angie.conf. Per-name certs (not one shared SAN) because a SAN
# cert would (a) bundle separate domains in a single CT-log entry, defeating their
# unlinkability, and (b) be all-or-nothing if one name fails ACME. proxy_protocol is
# a socket property already set by the main vhost, so new listen lines omit it
# (repeating a socket option risks "duplicate listen options"). Subdomains of the
# main domain reuse its decoy (/tmp); separate domains root at /var/www/<name>.
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

# Apply the multi-SNI pool to a freshly generated install: rewrite Reality
# serverNames in the local xray config (node mode passes "" — the panel owns the
# config and node_api_setup updates it via the API instead), inject the per-name
# Angie acme_client/vhosts, and write per-domain decoys. No-op without extra names.
apply_multi_sni() {
  local xray_cfg="$1" angie_conf="$2"
  [ -z "$VLESS_SNI_EXTRA" ] && return 0

  if [ -n "$xray_cfg" ]; then
    python3 - "$xray_cfg" << 'PYEOF'
import json, os, sys
path = sys.argv[1]
names = os.environ['VLESS_SNI_ALL'].split(',')
with open(path) as f:
    config = json.load(f)
for inbound in config.get('inbounds', []):
    reality = inbound.get('streamSettings', {}).get('realitySettings')
    if isinstance(reality, dict) and 'serverNames' in reality:
        reality['serverNames'] = names
tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(config, f, indent=2)
os.replace(tmp, path)
PYEOF
  fi

  inject_angie_extra_sni "$angie_conf"
  write_extra_decoys
}

# Install marzban
xray_setup() {
  mkdir -p /opt/xray-vps-setup
  cd /opt/xray-vps-setup
  write_decoy
  if [[ "${marzban_input,,}" == "y" ]]; then
    apt install zip unzip -y
    mkdir -p /opt/xray-vps-setup/marzban
    export MARZBAN_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
    export MARZBAN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
    export MARZBAN_PATH=$(openssl rand -hex 8)
    export MARZBAN_SUB_PATH=$(openssl rand -hex 8)
    download_xray_core /opt/xray-vps-setup/xray-core
    # Optional Happ User-Agent 403 in the subscription location (empty = no-op line).
    if [[ ${block_happ_input,,} == "y" ]]; then
      export HAPP_BLOCK='if ($http_user_agent ~* "Happ") { return 403; }'
    else
      export HAPP_BLOCK=''
    fi
    fetch "$RAW/compose-marzban" '' > ./docker-compose.yml
    fetch "$RAW/marzban" '$MARZBAN_USER $MARZBAN_PASS $MARZBAN_PATH $MARZBAN_SUB_PATH $VLESS_DOMAIN' > ./marzban/.env
    fetch "$RAW/angie-marzban" '$VLESS_DOMAIN $MARZBAN_PATH $MARZBAN_SUB_PATH $HAPP_BLOCK' > ./angie.conf
    fetch "$RAW/xray" '$XRAY_UUID $VLESS_DOMAIN $XRAY_PIK $XRAY_PBK $XRAY_SID $XRAY_SID2 $XRAY_SID3 $LISTEN_ADDR' > ./marzban/xray_config.json
  else
    mkdir -p /opt/xray-vps-setup/xray
    fetch "$RAW/compose-xray" '$XRAY_VERSION' > ./docker-compose.yml
    fetch "$RAW/xray" '$XRAY_UUID $VLESS_DOMAIN $XRAY_PIK $XRAY_PBK $XRAY_SID $XRAY_SID2 $XRAY_SID3 $LISTEN_ADDR' > ./xray/config.json
    fetch "$RAW/angie" '$VLESS_DOMAIN' > ./angie.conf
  fi

  # Split-IP: bind the visible egress IP on the direct outbound so tunnelled
  # traffic exits there, not on the hidden ingress IP the inbound listens on.
  # (yq infers JSON from the .json extension, as the WARP edits below do.)
  if [[ ${split_ip_input,,} == "y" ]]; then
    if [[ "${marzban_input,,}" == "y" ]]; then _cfg=./marzban/xray_config.json; else _cfg=./xray/config.json; fi
    yq eval '(.outbounds[] | select(.tag=="direct")).sendThrough = strenv(EGRESS_IP)' -i "$_cfg"
  fi

  if [[ "${marzban_input,,}" == "y" ]]; then
    apply_multi_sni ./marzban/xray_config.json ./angie.conf
  else
    apply_multi_sni ./xray/config.json ./angie.conf
  fi
}

node_setup() {
  mkdir -p /opt/xray-vps-setup
  cd /opt/xray-vps-setup
  write_decoy
  apt install zip unzip -y
  download_xray_core /opt/xray-vps-setup/xray-core
  # Placeholder - will be replaced with panel cert by node_api_setup
  touch ./ssl_client_cert.pem
  fetch "$RAW/compose-node" '' > ./docker-compose.yml
  fetch "$RAW/angie" '$VLESS_DOMAIN' > ./angie.conf
  # Node has no local xray config (the panel owns it); only inject Angie vhosts +
  # per-domain decoys here. The panel's serverNames/hosts are updated in node_api_setup.
  apply_multi_sni "" ./angie.conf
}

node_api_setup() {
  echo "Connecting to panel at https://$PANEL_DOMAIN..."
  TOKEN=$(curl -sf -X POST "https://$PANEL_DOMAIN/api/admin/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=$PANEL_USER" \
    --data-urlencode "password=$PANEL_PASS" \
    | yq '.access_token')

  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "Failed to authenticate with panel. Check credentials and panel availability."
    exit 1
  fi

  echo "Fetching SSL client certificate from panel..."
  CERT_HTTP=$(curl -s -o /tmp/node_settings.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/node/settings" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$CERT_HTTP" != "200" ]]; then
    echo "Failed to fetch node settings (HTTP $CERT_HTTP):"
    cat /tmp/node_settings.json
    exit 1
  fi
  python3 -c "import json,sys; print(json.load(open('/tmp/node_settings.json'))['certificate'], end='')" \
    > /opt/xray-vps-setup/ssl_client_cert.pem

  NODE_IP=$(hostname -I | awk '{print $1}')
  NODE_NAME=$(hostname)

  echo "Creating node '$NODE_NAME' ($NODE_IP) on panel..."
  NODE_HTTP=$(curl -s -o /tmp/node_response.json -w "%{http_code}" \
    -X POST "https://$PANEL_DOMAIN/api/node" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$NODE_NAME\",\"address\":\"$NODE_IP\",\"port\":62001,\"api_port\":62002,\"add_as_new_host\":false}" || echo "000")
  if [[ "$NODE_HTTP" == "200" ]]; then
    NODE_ID=$(cat /tmp/node_response.json | yq '.id')
    echo "Node created with ID: $NODE_ID"
  elif [[ "$NODE_HTTP" == "409" ]]; then
    echo "Node already exists on panel, reusing..."
    NODES_HTTP=$(curl -s -o /tmp/nodes_list.json -w "%{http_code}" \
      "https://$PANEL_DOMAIN/api/nodes" \
      -H "Authorization: Bearer $TOKEN" || echo "000")
    if [[ "$NODES_HTTP" != "200" ]]; then
      echo "Failed to fetch nodes list (HTTP $NODES_HTTP):"
      cat /tmp/nodes_list.json
      exit 1
    fi
    NODE_ID=$(python3 -c "import json,sys; nodes=json.load(open('/tmp/nodes_list.json')); print(next(str(n['id']) for n in nodes if n['address']=='$NODE_IP'))")
    echo "Existing node ID: $NODE_ID"
  else
    echo "Failed to create node (HTTP $NODE_HTTP):"
    cat /tmp/node_response.json
    exit 1
  fi

  echo "Updating xray config serverNames with node domain..."
  CONFIG_HTTP=$(curl -s -o /tmp/xray_config.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/core/config" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$CONFIG_HTTP" != "200" ]]; then
    echo "Failed to fetch xray config (HTTP $CONFIG_HTTP):"
    cat /tmp/xray_config.json
    exit 1
  fi

  export NODE_DOMAIN="$VLESS_DOMAIN"
  cat > /tmp/update_servernames.py << 'PYEOF'
import json, os
with open('/tmp/xray_config.json') as f:
    config = json.load(f)
# Add this node's whole SNI pool (main domain + any extras) to every Reality inbound.
names = os.environ['VLESS_SNI_ALL'].split(',')
for inbound in config.get('inbounds', []):
    stream = inbound.get('streamSettings', {})
    reality = stream.get('realitySettings', {})
    if 'serverNames' in reality:
        for name in names:
            if name not in reality['serverNames']:
                reality['serverNames'].append(name)
print(json.dumps(config))
PYEOF
  python3 /tmp/update_servernames.py > /tmp/xray_config_updated.json \
    || { echo "Failed to process xray config JSON"; exit 1; }
  curl -s -o /dev/null \
    -X PUT "https://$PANEL_DOMAIN/api/core/config" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @/tmp/xray_config_updated.json || true
  echo "serverNames updated."

  echo "Fetching inbounds and current hosts..."
  INBOUNDS_HTTP=$(curl -s -o /tmp/marzban_inbounds.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/inbounds" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$INBOUNDS_HTTP" != "200" ]]; then
    echo "Failed to fetch inbounds (HTTP $INBOUNDS_HTTP):"
    cat /tmp/marzban_inbounds.json
    exit 1
  fi
  HOSTS_HTTP=$(curl -s -o /tmp/marzban_hosts.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/hosts" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$HOSTS_HTTP" != "200" ]]; then
    echo "Failed to fetch hosts (HTTP $HOSTS_HTTP):"
    cat /tmp/marzban_hosts.json
    exit 1
  fi

  export HOST_NODE_NAME="$NODE_NAME"
  export HOST_PANEL_USER="$PANEL_USER"
  cat > /tmp/update_hosts.py << 'PYEOF'
import json, os
with open('/tmp/marzban_hosts.json') as f:
    hosts = json.load(f)
with open('/tmp/marzban_inbounds.json') as f:
    inbounds = json.load(f)
# One host entry per SNI in the pool, so this node's subscription spreads clients
# across all its names. A single name keeps the original (un-suffixed) remark.
names = os.environ['VLESS_SNI_ALL'].split(',')
node_name = os.environ['HOST_NODE_NAME']
panel_user = os.environ['HOST_PANEL_USER']
inbound_info = {}
for protocol, inbound_list in inbounds.items():
    for inbound in inbound_list:
        tag = inbound.get('tag', '')
        network = inbound.get('network', 'tcp')
        inbound_info[tag] = {'protocol': protocol, 'network': network}
for inbound_tag, host_list in hosts.items():
    info = inbound_info.get(inbound_tag, {})
    protocol = info.get('protocol', inbound_tag)
    transport = info.get('network', 'tcp')
    base_remark = f'{node_name} ({panel_user}) [{protocol} - {transport}]'
    for idx, name in enumerate(names, 1):
        remark = base_remark if len(names) == 1 else f'{base_remark} #{idx}'
        if any(h.get('sni') == name and h.get('remark') == remark for h in host_list):
            continue
        host_list.append({
            'remark': remark,
            'address': name,
            'port': None,
            'sni': name,
            'host': None,
            'path': None,
            'security': 'inbound_default',
            'alpn': '',
            'fingerprint': 'firefox',
            'allowinsecure': None,
            'is_disabled': None,
            'mux_enable': None,
            'fragment_setting': None,
            'noise_setting': None,
            'random_user_agent': None,
            'use_sni_as_host': None,
        })
print(json.dumps(hosts))
PYEOF
  python3 /tmp/update_hosts.py > /tmp/marzban_hosts_updated.json \
    || { echo "Failed to process hosts JSON"; exit 1; }
  curl -s -o /dev/null \
    -X PUT "https://$PANEL_DOMAIN/api/hosts" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @/tmp/marzban_hosts_updated.json || true
  echo "Panel hosts updated."

  echo "Panel configuration complete!"
}

if [[ "$INSTALL_MODE" == "node" ]]; then
  node_setup
else
  xray_setup
fi

sshd_edit() {
  fetch "$RAW/00-disable-password" '$SSH_PORT' > /etc/ssh/sshd_config.d/00-disable-password.conf
  # Validate the config before restarting so a typo can never lock us out.
  if ! sshd -t; then
    echo "ERROR: new sshd config is invalid; removing it to avoid lockout." >&2
    rm -f /etc/ssh/sshd_config.d/00-disable-password.conf
    exit 1
  fi
  systemctl daemon-reload
  systemctl restart ssh
}

add_user() {
  useradd "$SSH_USER" -s /bin/bash
  usermod -aG sudo "$SSH_USER"
  echo "$SSH_USER:$SSH_USER_PASS" | chpasswd
  mkdir -p "/home/$SSH_USER/.ssh"
  touch "/home/$SSH_USER/.ssh/authorized_keys"
  printf '%s\n' "$input_ssh_pbk" >> "/home/$SSH_USER/.ssh/authorized_keys"
  chmod 700 "/home/$SSH_USER/.ssh/"
  chmod 600 "/home/$SSH_USER/.ssh/authorized_keys"
  chown "$SSH_USER:$SSH_USER" -R "/home/$SSH_USER"
  usermod -aG docker "$SSH_USER"
}

debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF
apt-get install iptables-persistent netfilter-persistent -y

edit_iptables_node() {
  local panel_ips ip
  panel_ips=$(dig +short A "$PANEL_DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  if [ -z "$panel_ips" ]; then
    echo "ERROR: could not resolve an A record for panel domain $PANEL_DOMAIN" >&2
    exit 1
  fi
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    iptables -A INPUT -s "$ip" -p tcp -m tcp --dport 62001 -j ACCEPT
    iptables -A INPUT -s "$ip" -p tcp -m tcp --dport 62002 -j ACCEPT
  done <<< "$panel_ips"
  iptables -A INPUT -p tcp -m tcp --dport 62001 -j REJECT --reject-with tcp-reset
  iptables -A INPUT -p tcp -m tcp --dport 62002 -j REJECT --reject-with tcp-reset

  if [ -e /proc/net/if_inet6 ] && command -v ip6tables >/dev/null 2>&1; then
    local panel_ips6
    panel_ips6=$(dig +short AAAA "$PANEL_DOMAIN" | grep -E ':' || true)
    while IFS= read -r ip; do
      [ -n "$ip" ] || continue
      ip6tables -A INPUT -s "$ip" -p tcp -m tcp --dport 62001 -j ACCEPT
      ip6tables -A INPUT -s "$ip" -p tcp -m tcp --dport 62002 -j ACCEPT
    done <<< "$panel_ips6"
    ip6tables -A INPUT -p tcp -m tcp --dport 62001 -j REJECT --reject-with tcp-reset
    ip6tables -A INPUT -p tcp -m tcp --dport 62002 -j REJECT --reject-with tcp-reset
  fi
}

# Configure iptables
edit_iptables() {
  # Split-IP: pin 80/443 to the ingress IP and SSH to the egress IP, so the hidden
  # ingress IP only ever answers Reality (443) + ACME (80) and never exposes SSH.
  # Empty in non-split mode → rules apply to all destinations as before. Left
  # UNQUOTED on purpose so an empty value adds no argument.
  local INGRESS_MATCH="" EGRESS_MATCH=""
  if [[ ${split_ip_input,,} == "y" ]]; then
    INGRESS_MATCH="-d $INGRESS_IP"; EGRESS_MATCH="-d $EGRESS_IP"
  fi
  iptables -A INPUT -p icmp -j ACCEPT
  iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  # Rate-limit new SSH connections: max 5 per 60s per source IP (brute-force guard).
  iptables -A INPUT -p tcp $EGRESS_MATCH --dport "$SSH_PORT" -m state --state NEW -m recent --set --name SSH
  iptables -A INPUT -p tcp $EGRESS_MATCH --dport "$SSH_PORT" -m state --state NEW -m recent --update --seconds 60 --hitcount 5 --name SSH -j DROP
  iptables -A INPUT -p tcp $EGRESS_MATCH -m state --state NEW -m tcp --dport "$SSH_PORT" -j ACCEPT
  iptables -A INPUT -p tcp $INGRESS_MATCH -m tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p tcp $INGRESS_MATCH -m tcp --dport 443 -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -P INPUT DROP

  # Mirror the same policy on IPv6 (Angie also listens on [::]:80); otherwise
  # IPv6 INPUT stays wide open. ICMPv6 must be allowed for NDP/PMTUD to work.
  if [ -e /proc/net/if_inet6 ] && command -v ip6tables >/dev/null 2>&1; then
    ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
    ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
    ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --set --name SSH6
    ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --update --seconds 60 --hitcount 5 --name SSH6 -j DROP
    ip6tables -A INPUT -p tcp -m state --state NEW -m tcp --dport "$SSH_PORT" -j ACCEPT
    ip6tables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
    ip6tables -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -P INPUT DROP
  fi
}
if [[ "$INSTALL_MODE" == "node" ]]; then
  edit_iptables_node
fi
if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo "New user for ssh: $SSH_USER, password for user: $SSH_USER_PASS. New port for SSH: $SSH_PORT."
  add_user
  edit_iptables
  sshd_edit
elif [[ ${split_ip_input,,} == "y" ]]; then
  echo "WARNING: split-IP mode was selected but SSH hardening was declined, so the"
  echo "per-IP firewall was NOT applied. The ingress IP may still expose SSH and"
  echo "there is no INPUT lockdown. Re-run with SSH hardening enabled, or apply the"
  echo "ingress/egress iptables rules manually."
fi
netfilter-persistent save

# WARP Install function
warp_install() {
  apt install gpg -y
  echo "If this fails then warp won't be added to routing and everything will work without it"
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
  apt update
  apt install cloudflare-warp -y

  # If registration fails, skip WARP but let the rest of the setup finish
  # (return, NOT exit, so docker compose still starts and the final output prints).
  if ! echo "y" | warp-cli registration new; then
    echo "Couldn't connect to WARP, continuing without it"
    return 0
  fi
  warp-cli mode proxy
  warp-cli proxy port 40000
  warp-cli connect
  if [[ "${marzban_input,,}" == "y" ]]; then
    export XRAY_CONFIG_WARP="/opt/xray-vps-setup/marzban/xray_config.json"
  else
    export XRAY_CONFIG_WARP="/opt/xray-vps-setup/xray/config.json"
  fi
  yq eval \
  '.outbounds += {"tag": "warp","protocol": "socks","settings": {"servers": [{"address": "127.0.0.1","port": 40000}]}}' \
  -i "$XRAY_CONFIG_WARP"
  # Route RU sites through WARP, AND the well-known IP-echo / "what's my IP"
  # endpoints: a co-resident app abusing an unauthenticated localhost SOCKS proxy
  # on the client discovers the exit IP via these services — sending them through
  # WARP makes that probe see a Cloudflare IP, not this server's. Cheap (only these
  # lookups + RU traffic divert); a custom IP-echo host bypasses it (split-IP is the
  # complete fix). Matching works on the sniffed SNI/Host (inbound sniffing is on).
  yq eval \
  '.routing.rules += {"outboundTag": "warp", "domain": ["geosite:category-ru", "regexp:.*\\.xn--[a-z0-9]+$", "regexp:.*\\.ru$", "regexp:.*\\.su$", "domain:api.ipify.org", "domain:api4.ipify.org", "domain:api6.ipify.org", "domain:api64.ipify.org", "domain:checkip.amazonaws.com", "domain:ifconfig.me", "domain:ifconfig.co", "domain:icanhazip.com", "domain:ident.me", "domain:ipinfo.io", "domain:api.myip.com", "domain:ip.seeip.org", "domain:ipecho.net", "domain:wgetip.com", "domain:ip-api.com", "domain:ip.sb", "domain:api.ip.sb", "domain:whatismyip.akamai.com", "domain:yandex.net", "domain:avito.st"]}' \
  -i "$XRAY_CONFIG_WARP"
}

end_script() {
  if [[ ${configure_warp_input,,} == "y" ]]; then
    warp_install
  fi

  if [[ "$INSTALL_MODE" == "node" ]]; then
    node_api_setup
  fi

  docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

  if [[ "$INSTALL_MODE" == "marzban" ]]; then
    # Configure marzban over its local port — no public cert/DNS needed yet,
    # which avoids the ACME race entirely.
    MARZBAN_API="http://127.0.0.1:8000"
    echo "Waiting for marzban to start..."
    # Retry the admin import: the container needs a moment to initialise its DB.
    for attempt in $(seq 1 12); do
      if docker exec marzban marzban-cli admin import-from-env 2>/dev/null; then
        break
      fi
      if [[ "$attempt" -eq 12 ]]; then
        echo "Warning: admin import failed - run 'docker exec marzban marzban-cli admin import-from-env' manually"
      fi
      sleep 5
    done

    echo "Updating panel default host with domain $VLESS_DOMAIN..."
    # Retry while marzban finishes starting (local API, no certificate dependency).
    PANEL_TOKEN=""
    for attempt in $(seq 1 30); do
      PANEL_TOKEN=$(curl -sf -X POST "$MARZBAN_API/api/admin/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "username=$MARZBAN_USER" \
        --data-urlencode "password=$MARZBAN_PASS" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")
      if [[ -n "$PANEL_TOKEN" && "$PANEL_TOKEN" != "null" ]]; then
        break
      fi
      sleep 2
    done
    if [[ -n "$PANEL_TOKEN" && "$PANEL_TOKEN" != "null" ]]; then
      PHOSTS_HTTP=$(curl -s -o /tmp/panel_hosts.json -w "%{http_code}" \
        "$MARZBAN_API/api/hosts" \
        -H "Authorization: Bearer $PANEL_TOKEN" || echo "000")
      if [[ "$PHOSTS_HTTP" == "200" ]]; then
        python3 << 'PYEOF' > /tmp/panel_hosts_updated.json
import json, os, re
with open('/tmp/panel_hosts.json') as f:
    hosts = json.load(f)
names = os.environ['VLESS_SNI_ALL'].split(',')

# Field template for a host built from scratch (when an inbound has no default host).
TEMPLATE = {
    'remark': '', 'address': '', 'port': None, 'sni': '', 'host': None, 'path': None,
    'security': 'inbound_default', 'alpn': '', 'fingerprint': 'firefox',
    'allowinsecure': None, 'is_disabled': None, 'mux_enable': None,
    'fragment_setting': None, 'noise_setting': None, 'random_user_agent': None,
    'use_sni_as_host': None,
}

for inbound_tag, host_list in hosts.items():
    base = dict(host_list[0]) if host_list else dict(TEMPLATE, remark=inbound_tag)
    if len(names) == 1:
        # Single SNI: preserve original behaviour — point existing host(s) (or one
        # default) at the domain, leave remark untouched.
        if host_list:
            for host in host_list:
                host['address'] = host['sni'] = names[0]
        else:
            host_list.append(dict(base, address=names[0], sni=names[0]))
        continue
    # Multi-SNI: rebuild the inbound's host list to exactly one entry per name, so
    # every user's subscription spreads across all SNIs. Strip any prior " #N" so
    # re-runs stay deterministic instead of accreting suffixes.
    base_remark = re.sub(r' #\d+$', '', base.get('remark') or inbound_tag)
    hosts[inbound_tag] = [
        dict(base, address=name, sni=name, remark=f'{base_remark} #{idx}')
        for idx, name in enumerate(names, 1)
    ]
print(json.dumps(hosts))
PYEOF
        curl -s -o /dev/null \
          -X PUT "$MARZBAN_API/api/hosts" \
          -H "Authorization: Bearer $PANEL_TOKEN" \
          -H "Content-Type: application/json" \
          -d @/tmp/panel_hosts_updated.json || true
        echo "Panel host updated."
      else
        echo "Warning: could not fetch panel hosts (HTTP $PHOSTS_HTTP) - update address/SNI manually"
      fi
    else
      echo "Warning: could not authenticate to panel API - update default host address/SNI to $VLESS_DOMAIN manually"
    fi
  fi

  if [[ "$INSTALL_MODE" == "node" ]]; then
    final_msg="Marzban node installed!
Node: $(hostname)
Node domain: $VLESS_DOMAIN
Panel: https://$PANEL_DOMAIN
Node service port: 62001
    "
  elif [[ "${marzban_input,,}" == "y" ]]; then
    final_msg="Marzban panel location: https://$VLESS_DOMAIN/$MARZBAN_PATH
User: $MARZBAN_USER
Password: $MARZBAN_PASS
    "
  else
    # Random per-install credentials for the hardened client's localhost SOCKS proxy.
    export CLIENT_SOCKS_PORT=10808
    export CLIENT_SOCKS_USER=$(tr -dc a-z0-9 </dev/urandom | head -c 8)
    export CLIENT_SOCKS_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    xray_config=$(fetch "$RAW/xray_outbound" '$VLESS_DOMAIN $XRAY_UUID $XRAY_PBK $XRAY_SID')
    singbox_config=$(fetch "$RAW/sing_box_outbound" '$VLESS_DOMAIN $XRAY_UUID $XRAY_PBK $XRAY_SID')
    xray_full=$(fetch "$RAW/xray_full_client" '$VLESS_DOMAIN $XRAY_UUID $XRAY_PBK $XRAY_SID $CLIENT_SOCKS_PORT $CLIENT_SOCKS_USER $CLIENT_SOCKS_PASS')

    final_msg="Clipboard string format:
vless://$XRAY_UUID@$VLESS_DOMAIN:443?type=tcp&security=reality&pbk=$XRAY_PBK&fp=firefox&sni=$VLESS_DOMAIN&sid=$XRAY_SID&spx=%2F&flow=xtls-rprx-vision#Script

XRay outbound config:
$xray_config

Sing-box outbound config:
$singbox_config

Hardened full XRay client config (authenticated localhost SOCKS — point your apps at
socks5://$CLIENT_SOCKS_USER:$CLIENT_SOCKS_PASS@127.0.0.1:$CLIENT_SOCKS_PORT ; UDP is off,
set \"udp\": true only if you accept the leak risk). Protects against co-resident apps
abusing an unauthenticated localhost proxy to discover the server IP:
$xray_full

Plain data:
PBK: $XRAY_PBK, UUID: $XRAY_UUID
    "
  fi

  clear
  echo "$final_msg"
  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "SSH user: $SSH_USER, SSH password: $SSH_USER_PASS, SSH port: $SSH_PORT"
    if [[ ${split_ip_input,,} == "y" ]]; then
      echo "NOTE: split-IP active — SSH is now reachable ONLY via the egress IP $EGRESS_IP (your current session stays up; reconnect there)."
    fi
  fi
}

end_script
