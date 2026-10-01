#!/usr/bin/env bash
# Only XRAY_SETUP is managed. Other chains/policies are never flushed.
apply_family() {
  local tool=$1 restore=$2 version=$3 rules source port ingress_match=() ssh_match=()
  rules=$(mktemp "$RUN_DIR/firewall.XXXXXX")
  if [[ "$version" == 4 && -n "$INGRESS_IP" ]]; then
    ingress_match=(-d "$INGRESS_IP")
    ssh_match=(-d "$EGRESS_IP")
  fi
  {
    echo '*filter'
    echo ':XRAY_SETUP - [0:0]'
    echo '-F XRAY_SETUP'
    echo '-A XRAY_SETUP -i lo -j ACCEPT'
    echo '-A XRAY_SETUP -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'
    if [[ "$version" == 4 ]]; then
      echo '-A XRAY_SETUP -p icmp -j ACCEPT'
    else
      echo '-A XRAY_SETUP -p ipv6-icmp -j ACCEPT'
    fi
    if [[ "$INSTALL_MODE" == node ]]; then
      while IFS= read -r source; do
        [[ -n "$source" ]] || continue
        printf '%s\n' "-A XRAY_SETUP -s $source -p tcp -m multiport --dports 62001,62002 -j ACCEPT"
      done < <(python3 - "$STATE_FILE" "$version" <<'PY'
import ipaddress, json, sys
for source in json.load(open(sys.argv[1]))['management_sources']:
    if ipaddress.ip_network(source, strict=False).version == int(sys.argv[2]):
        print(source)
PY
)
      echo '-A XRAY_SETUP -p tcp -m multiport --dports 62001,62002 -j REJECT --reject-with tcp-reset'
    fi
    if [[ -n "${SSH_NEW_PORT:-}" ]]; then
      # During preparation old listeners remain usable until a verified new login.
      if [[ "${SSH_CONFIRMED:-n}" != y ]]; then
        for port in "${SSH_OLD_PORTS[@]}"; do
          printf '%s\n' "-A XRAY_SETUP -p tcp --dport $port -j ACCEPT"
        done
      fi
      if [[ "$version" == 4 || -z "$INGRESS_IP" ]]; then
        printf '%s\n' "-A XRAY_SETUP -p tcp ${ssh_match[*]} --dport $SSH_NEW_PORT -m conntrack --ctstate NEW -m recent --set --name XRAY_SSH"
        printf '%s\n' "-A XRAY_SETUP -p tcp ${ssh_match[*]} --dport $SSH_NEW_PORT -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 10 --name XRAY_SSH -j DROP"
        printf '%s\n' "-A XRAY_SETUP -p tcp ${ssh_match[*]} --dport $SSH_NEW_PORT -j ACCEPT"
      fi
    fi
    if [[ "$version" == 4 || -z "$INGRESS_IP" ]]; then
      printf '%s\n' "-A XRAY_SETUP -p tcp ${ingress_match[*]} -m multiport --dports 80,443 -j ACCEPT"
    fi
    # Service ports cannot be opened by an earlier broad ACCEPT in a foreign chain.
    echo '-A XRAY_SETUP -p tcp -m multiport --dports 4123,8443,8444,8000,40000 -j REJECT --reject-with tcp-reset'
    if [[ -n "${SSH_NEW_PORT:-}" ]]; then
      echo '-A XRAY_SETUP -j DROP'
    else
      echo '-A XRAY_SETUP -j RETURN'
    fi
    echo COMMIT
  } > "$rules"
  "$restore" --wait 10 --test --noflush < "$rules"
  "$restore" --wait 10 --noflush < "$rules"
  # Keep exactly one jump at the start of INPUT so stale early ACCEPTs cannot bypass it.
  while "$tool" -w 10 -C INPUT -j XRAY_SETUP 2>/dev/null; do
    "$tool" -w 10 -D INPUT -j XRAY_SETUP
  done
  "$tool" -w 10 -I INPUT 1 -j XRAY_SETUP
}

apply_firewall() {
  apply_family iptables iptables-restore 4
  if [[ -e /proc/net/if_inet6 ]]; then
    apply_family ip6tables ip6tables-restore 6
  fi
}

check_firewall() {
  local tool first family dest=()
  for family in 4 6; do
    [[ "$family" == 4 || -e /proc/net/if_inet6 ]] || continue
    tool=iptables
    [[ "$family" == 4 ]] || tool=ip6tables
    first=$("$tool" -w 10 -S INPUT | awk '$1=="-A" && !seen++ {print}') || return 1
    [[ "$first" == '-A INPUT -j XRAY_SETUP' ]] || return 1
    "$tool" -w 10 -C XRAY_SETUP -p tcp -m multiport --dports 4123,8443,8444,8000,40000 -j REJECT --reject-with tcp-reset || return 1
    if [[ "$INSTALL_MODE" == node ]]; then
      "$tool" -w 10 -C XRAY_SETUP -p tcp -m multiport --dports 62001,62002 -j REJECT --reject-with tcp-reset || return 1
    fi
    if [[ -n "${SSH_NEW_PORT:-}" ]]; then
      "$tool" -w 10 -C XRAY_SETUP -j DROP || return 1
      if [[ "$family" == 4 || -z "$INGRESS_IP" ]]; then
        dest=()
        [[ -z "$EGRESS_IP" ]] || dest=(-d "$EGRESS_IP")
        "$tool" -w 10 -C XRAY_SETUP -p tcp "${dest[@]}" --dport "$SSH_NEW_PORT" -j ACCEPT || return 1
      fi
    fi
  done
}
