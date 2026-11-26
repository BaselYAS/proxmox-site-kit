#!/bin/bash
# Run ON a Proxmox box: put the host (vmbr0) on DHCP, for bench prep only. Idempotent (already DHCP = no change).
# Safe: rollback copy of /etc/network/interfaces first; a dhclient hook keeps the /etc/hosts line for the hostname on the
# current IP (Proxmox needs it); if vmbr0 has no IPv4 60 s after the switch, the old config is put back by itself.
# The switch runs detached (a dropped SSH session can't stop it halfway). Log: /root/site-kit-dhcp.log
# Back to static at the site: site-kit-relocate.sh, or site-kit.sh with "static" (both remove the hook).
#   SK_WAIT=1  wait for the switch to finish (site-kit.sh does)
set -u
IFS_FILE=/etc/network/interfaces; HOOK=/etc/dhcp/dhclient-exit-hooks.d/site-kit-hosts; LOGF=/root/site-kit-dhcp.log
cur(){ ip -4 -br a show vmbr0 2>/dev/null | awk '{print $3}' | head -1; }
find_me(){
  local t; t=$(tailscale ip -4 2>/dev/null | head -1)
  echo "find the box afterwards: ${t:+Tailscale $t (https://$t:8006), or }the router's DHCP list: hostname $(hostname), MAC $(cat /sys/class/net/vmbr0/address 2>/dev/null)"; }

write_hook(){ mkdir -p "$(dirname "$HOOK")"; cat > "$HOOK.new" <<'H'
# site-kit: keep the /etc/hosts line for this host on its DHCP address (Proxmox needs it). Sourced by dhclient-script.
sk_hosts(){
  [ "${interface:-}" = vmbr0 ] || return 0
  case "${reason:-}" in BOUND|RENEW|REBIND|REBOOT) ;; *) return 0 ;; esac
  [ -n "${new_ip_address:-}" ] || return 0
  h=$(hostname -s); f=$(hostname -f 2>/dev/null); [ -n "$f" ] && [ "$f" != "$h" ] || f="$h.local"
  grep -qE "^$new_ip_address[[:space:]]([^#]*[[:space:]])?$h([[:space:]]|$)" /etc/hosts && return 0
  if grep -vE '^(127\.|#|::|[[:space:]]*$)' /etc/hosts | grep -qE "[[:space:]]$h([[:space:]]|$)"; then
    sed -i -E "/^(127\.|#|::)/!{/[[:space:]]$h([[:space:]]|$)/s/^[0-9.]+/$new_ip_address/}" /etc/hosts
  else printf '%s %s %s\n' "$new_ip_address" "$f" "$h" >> /etc/hosts; fi
  logger -t site-kit "dhcp: /etc/hosts $h -> $new_ip_address"
  if systemctl is-active -q pve-cluster; then (sleep 2; systemctl restart pve-cluster pveproxy) >/dev/null 2>&1 & fi
}
sk_hosts
H
  if cmp -s "$HOOK.new" "$HOOK"; then rm -f "$HOOK.new"; return 1; fi
  mv "$HOOK.new" "$HOOK"; sync; return 0; }   # sync: a power cut right after left it 0 bytes in testing

# ---- detached part: reload, check, roll back if the box got no address ----
if [ "${1:-}" = --apply ]; then
  B=$2; sleep 3; echo "$(date '+%F %T') ifreload -a (vmbr0 -> dhcp)"; ifreload -a
  for _ in $(seq 30); do [ -n "$(cur)" ] && break; sleep 2; done
  if [ -z "$(cur)" ]; then
    echo "!! no DHCP address after 60 s: rolling back to $B"; cp -p "$B" "$IFS_FILE"; rm -f "$HOOK"; ifreload -a
  fi
  systemctl restart pve-cluster pveproxy; sleep 3
  echo "$(date '+%F %T') vmbr0 $(cur)  /etc/hosts: $(grep -E "[[:space:]]$(hostname -s)([[:space:]]|$)" /etc/hosts | grep -v '^127\.' | head -1)"
  exit 0
fi

write_hook; HOOKCHG=$?
if grep -qE '^iface vmbr0 inet dhcp' "$IFS_FILE"; then
  [ $HOOKCHG = 0 ] && echo "host: already DHCP (hosts hook updated)" || echo "host: already DHCP ($(cur)), no change"
  exit 0
fi
command -v dhclient >/dev/null || { echo "dhclient missing: installing isc-dhcp-client"; DEBIAN_FRONTEND=noninteractive apt-get install -y -q isc-dhcp-client >/dev/null 2>&1; }
command -v dhclient >/dev/null || { rm -f "$HOOK"; echo "!! no dhclient (isc-dhcp-client) and it could not be installed: host left static"; exit 1; }
B="/root/interfaces.before-dhcp.$(date +%s)"; cp -p "$IFS_FILE" "$B"
python3 - "$IFS_FILE" <<'PY' || { cp -p "$B" "$IFS_FILE"; rm -f "$HOOK"; echo "!! could not edit $IFS_FILE: unchanged"; exit 1; }
import re,sys;p=sys.argv[1];out=[];inb=False;done=False
for l in open(p).read().splitlines(True):
    if re.match(r'iface vmbr0 inet (static|manual)\b',l) and not done:
        out.append('iface vmbr0 inet dhcp\n'); inb=True; done=True; continue
    if inb:
        if l.strip()=='' or not l[0].isspace(): inb=False
        elif re.match(r'\s+(address|gateway|netmask)\s',l): continue
    out.append(l)
if not done: sys.exit(1)
open(p,'w').write(''.join(out))
PY
sync
echo "host: static $(cur) -> DHCP (bench prep only). rollback: cp $B $IFS_FILE; rm -f $HOOK; ifreload -a"
find_me
setsid nohup bash "${BASH_SOURCE[0]}" --apply "$B" >> "$LOGF" 2>&1 < /dev/null &
P=$!
if [ "${SK_WAIT:-0}" = 1 ]; then while kill -0 "$P" 2>/dev/null; do sleep 2; done; tail -n 2 "$LOGF"
else echo "switching in 3 s (detached, log $LOGF): the IP may change, reconnect via the address above"; fi
