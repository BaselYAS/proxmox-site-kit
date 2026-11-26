#!/bin/bash
# Run ON a Proxmox box: put the host (vmbr0) on a static IPv4. Args: <ip/prefix> <gateway> [dns]. Idempotent.
# Safe: rollback copy of interfaces + /etc/hosts + resolv.conf first; the switch runs detached (a dropped session can't
# stop it halfway); if the box can't ping its gateway within 60 s, the old files are put back by itself.
# Removes the DHCP bench hook and stops a bench-mode dhclient. Log: /root/site-kit-static.log
#   SK_WAIT=1  wait for the result (prints OK / ROLLED BACK; exit 0 = new address up, 3 = rolled back)
#   SK_TEST_FAIL_GW=1  test only: pretend the gateway never answers (exercises the rollback)
set -u
CIDR=${1:?ip/prefix}; GW=${2:?gateway}; DNS=${3:-}
IFS_FILE=/etc/network/interfaces; HOOK=/etc/dhcp/dhclient-exit-hooks.d/site-kit-hosts; LOGF=/root/site-kit-static.log
cur(){ ip -4 -br a show vmbr0 2>/dev/null | awk '{print $3}' | head -1; }
gw_ok(){ [ "${SK_TEST_FAIL_GW:-0}" = 1 ] && return 1; ping -c1 -W2 "$1" >/dev/null 2>&1; }

if [ "${CIDR}" = --apply ]; then   # detached part: $2 = backup dir
  B=$2; NEWGW=$(cat "$B/gw"); sleep 3; echo "$(date '+%F %T') vmbr0 -> $(cat "$B/cidr") gw $NEWGW"
  pkill -f 'dhclient.*vmbr0' >/dev/null 2>&1; dhclient -x vmbr0 >/dev/null 2>&1
  ip -4 addr flush dev vmbr0 >/dev/null 2>&1; ifreload -a
  ok=0; for _ in $(seq 30); do gw_ok "$NEWGW" && { ok=1; break; }; sleep 2; done
  if [ $ok = 1 ]; then echo "OK host $(cur) reaches gateway $NEWGW"; rc=0
  else
    echo "!! ROLLED BACK: gateway $NEWGW not reachable within 60 s, old network config restored"
    cp -p "$B/interfaces" "$IFS_FILE"; cp -p "$B/hosts" /etc/hosts; cp -p "$B/resolv.conf" /etc/resolv.conf 2>/dev/null
    [ -f "$B/hook" ] && { mkdir -p "$(dirname "$HOOK")"; cp -p "$B/hook" "$HOOK"; }
    ip -4 addr flush dev vmbr0 >/dev/null 2>&1; ifreload -a; sleep 5
    grep -qE '^iface vmbr0 inet dhcp' "$IFS_FILE" && ! pgrep -f 'dhclient.*vmbr0' >/dev/null && dhclient vmbr0 >/dev/null 2>&1
    rc=3
  fi
  sync; systemctl restart pve-cluster pveproxy; sleep 3
  echo "$(date '+%F %T') vmbr0 now $(cur) rc=$rc"; echo "$rc" > "$B/rc"; exit 0
fi

python3 -c "import ipaddress,sys;i=ipaddress.ip_interface(sys.argv[1]);g=ipaddress.ip_address(sys.argv[2]);sys.exit(0 if g in i.network and g!=i.ip else 1)" "$CIDR" "$GW" \
  || { echo "!! gateway $GW is not in $CIDR: nothing changed"; exit 1; }
if grep -qE '^iface vmbr0 inet static' "$IFS_FILE" && [ "$(cur)" = "$CIDR" ] && [ "$(ip route | awk '/^default/{print $3; exit}')" = "$GW" ] \
   && grep -qE "^[[:space:]]+address $CIDR\b" "$IFS_FILE" && [ ! -e "$HOOK" ]; then
  echo "host: already static $CIDR gw $GW, no change"; exit 0; fi

B="/root/site-kit-rollback.$(date +%s)"; mkdir -p "$B"; chmod 700 "$B"
cp -p "$IFS_FILE" "$B/interfaces"; cp -p /etc/hosts "$B/hosts"; cp -p /etc/resolv.conf "$B/resolv.conf" 2>/dev/null
[ -f "$HOOK" ] && cp -p "$HOOK" "$B/hook"; echo "$CIDR" > "$B/cidr"; echo "$GW" > "$B/gw"
python3 - "$IFS_FILE" "$CIDR" "$GW" <<'PY' || { echo "!! could not edit $IFS_FILE (no 'iface vmbr0'?): unchanged"; exit 1; }
import re,sys;p,a,g=sys.argv[1:4];out=[];inb=False;done=False
for l in open(p).read().splitlines(True):
    if re.match(r'iface vmbr0 inet (static|manual|dhcp)\b',l) and not done:
        out.append('iface vmbr0 inet static\n\taddress %s\n\tgateway %s\n'%(a,g)); inb=True; done=True; continue
    if inb:
        if l.strip()=='' or not l[0].isspace(): inb=False
        elif re.match(r'\s+(address|gateway|netmask)\s',l): continue
    out.append(l)
if not done: sys.exit(1)
open(p,'w').write(''.join(out))
PY
h=$(hostname -s)
if grep -vE '^(127\.|#|::|[[:space:]]*$)' /etc/hosts | grep -qE "[[:space:]]$h([[:space:]]|$)"; then
  sed -i -E "/^(127\.|#|::)/!{/[[:space:]]$h([[:space:]]|$)/s/^[0-9.]+/${CIDR%/*}/}" /etc/hosts
else printf '%s %s %s\n' "${CIDR%/*}" "$(hostname -f 2>/dev/null || echo "$h.local")" "$h" >> /etc/hosts; fi
rm -f "$HOOK"
[ -n "$DNS" ] && printf 'search %s\nnameserver %s\n' "$(hostname -d 2>/dev/null || echo local)" "$DNS" > /etc/resolv.conf
sync
echo "host: $(cur) -> static $CIDR gw $GW${DNS:+ dns $DNS}"
echo "rollback copy: $B (manual undo: cp $B/interfaces $IFS_FILE; cp $B/hosts /etc/hosts; ifreload -a)"
setsid nohup bash "${BASH_SOURCE[0]}" --apply "$B" >> "$LOGF" 2>&1 < /dev/null &
P=$!
if [ "${SK_WAIT:-0}" = 1 ]; then while kill -0 "$P" 2>/dev/null; do sleep 2; done; tail -n 3 "$LOGF"; exit "$(cat "$B/rc" 2>/dev/null || echo 1)"
else echo "switching in 3 s (detached, log $LOGF): reconnect at https://${CIDR%/*}:8006"; fi
