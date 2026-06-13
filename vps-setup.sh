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

# Write a per-deploy-unique decoy page to ./index.html (the masking site angie
# serves at /). Brand/tagline/nonce are randomised so every deployment differs
# byte-for-byte, which defeats exact-hash fingerprinting of a shared decoy.
write_decoy() {
  export DECOY_BRAND=$(shuf -n1 -e Northwind Lumira Veltro Caldera Brixton Auralis Meridian Halcyon Everstone Tindle)
  export DECOY_TAGLINE=$(shuf -n1 -e "Authentication required" "Sign in to continue" "Please sign in to continue" "Enter your credentials to continue" "Sign in to your account")
  export DECOY_TITLE="Sign in · $DECOY_BRAND"
  export DECOY_NONCE=$(openssl rand -hex 16)
  fetch "$RAW/decoy" '$DECOY_BRAND $DECOY_TAGLINE $DECOY_TITLE $DECOY_NONCE' > ./index.html
}

# Check if script started as root
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Install idn 
apt-get update
apt-get install idn sudo dnsutils wamerican -y 

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

SERVER_IPS=($(hostname -I))

# Collect every A record, not just the last one (domains may have several).
RESOLVED_IPS=$(dig +short A "$VLESS_DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

if [ -z "$RESOLVED_IPS" ]; then
  echo "Warning: Domain has no DNS record"
  read -ep "Are you sure? That domain has no DNS record. If you didn't add that you will have to restart xray and angie by yourself [y/N]"$'\n' prompt_response
  if [[ "$prompt_response" =~ ^([yY])$ ]]; then
    echo "Ok, proceeding without DNS verification"
  else
    echo "Come back later"
    exit 1
  fi
else
  MATCH_FOUND=false
  for resolved_ip in $RESOLVED_IPS; do
    for server_ip in "${SERVER_IPS[@]}"; do
      if [ "$resolved_ip" == "$server_ip" ]; then
        MATCH_FOUND=true
        break 2
      fi
    done
  done

  if [ "$MATCH_FOUND" = true ]; then
    echo "✓ DNS record points to this server"
  else
    echo "Warning: DNS record exists but points to different IP"
    echo "  Domain resolves to: $(echo $RESOLVED_IPS | tr '\n' ' ')"
    echo "  This server's IPs: ${SERVER_IPS[*]}"
    read -ep "Continue anyway? [y/N]"$'\n' prompt_response
    if [[ "$prompt_response" =~ ^([yY])$ ]]; then
      echo "Ok, proceeding"
    else 
      echo "Come back later"
      exit 1
    fi
  fi
fi

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
    fetch "$RAW/compose-marzban" '' > ./docker-compose.yml
    fetch "$RAW/marzban" '$MARZBAN_USER $MARZBAN_PASS $MARZBAN_PATH $MARZBAN_SUB_PATH $VLESS_DOMAIN' > ./marzban/.env
    fetch "$RAW/angie-marzban" '$VLESS_DOMAIN $MARZBAN_PATH $MARZBAN_SUB_PATH' > ./angie.conf
    fetch "$RAW/xray" '$XRAY_UUID $VLESS_DOMAIN $XRAY_PIK $XRAY_SID $XRAY_SID2 $XRAY_SID3' > ./marzban/xray_config.json
  else
    mkdir -p /opt/xray-vps-setup/xray
    fetch "$RAW/compose-xray" '$XRAY_VERSION' > ./docker-compose.yml
    fetch "$RAW/xray" '$XRAY_UUID $VLESS_DOMAIN $XRAY_PIK $XRAY_SID $XRAY_SID2 $XRAY_SID3' > ./xray/config.json
    fetch "$RAW/angie" '$VLESS_DOMAIN' > ./angie.conf
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
node_domain = os.environ['NODE_DOMAIN']
for inbound in config.get('inbounds', []):
    stream = inbound.get('streamSettings', {})
    reality = stream.get('realitySettings', {})
    if 'serverNames' in reality and node_domain not in reality['serverNames']:
        reality['serverNames'].append(node_domain)
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
node_domain = os.environ['NODE_DOMAIN']
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
    remark = f'{node_name} ({panel_user}) [{protocol} - {transport}]'
    if any(h.get('address') == node_domain and h.get('remark') == remark for h in host_list):
        continue
    host_list.append({
        'remark': remark,
        'address': node_domain,
        'port': None,
        'sni': node_domain,
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
  iptables -A INPUT -p icmp -j ACCEPT
  iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  # Rate-limit new SSH connections: max 5 per 60s per source IP (brute-force guard).
  iptables -A INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --set --name SSH
  iptables -A INPUT -p tcp --dport "$SSH_PORT" -m state --state NEW -m recent --update --seconds 60 --hitcount 5 --name SSH -j DROP
  iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport "$SSH_PORT" -j ACCEPT
  iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
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
  yq eval \
  '.routing.rules += {"outboundTag": "warp", "domain": ["geosite:category-ru", "regexp:.*\\.xn--[a-z0-9]+$", "regexp:.*\\.ru$", "regexp:.*\\.su$"]}' \
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
        export PANEL_HOST_DOMAIN="$VLESS_DOMAIN"
        python3 << 'PYEOF' > /tmp/panel_hosts_updated.json
import json, os
with open('/tmp/panel_hosts.json') as f:
    hosts = json.load(f)
domain = os.environ['PANEL_HOST_DOMAIN']
for host_list in hosts.values():
    for host in host_list:
        host['address'] = domain
        host['sni'] = domain
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
    xray_config=$(fetch "$RAW/xray_outbound" '$VLESS_DOMAIN $XRAY_UUID $XRAY_PBK $XRAY_SID')
    singbox_config=$(fetch "$RAW/sing_box_outbound" '$VLESS_DOMAIN $XRAY_UUID $XRAY_PBK $XRAY_SID')

    final_msg="Clipboard string format:
vless://$XRAY_UUID@$VLESS_DOMAIN:443?type=tcp&security=reality&pbk=$XRAY_PBK&fp=firefox&sni=$VLESS_DOMAIN&sid=$XRAY_SID&spx=%2F&flow=xtls-rprx-vision#Script

XRay outbound config:
$xray_config

Sing-box outbound config:
$singbox_config

Plain data:
PBK: $XRAY_PBK, UUID: $XRAY_UUID
    "
  fi

  clear
  echo "$final_msg"
  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "SSH user: $SSH_USER, SSH password: $SSH_USER_PASS, SSH port: $SSH_PORT"
  fi
}

end_script
