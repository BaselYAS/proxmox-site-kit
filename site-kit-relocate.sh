#!/bin/bash
# site-kit-relocate.sh: run ON the Proxmox host once a box prepared at the office (often DHCP bench mode) sits on its
# branch LAN. One command, as root, in the Proxmox shell (or SSH):
#   bash <(curl -fsSL https://raw.githubusercontent.com/BaselYAS/proxmox-site-kit/main/site-kit-relocate.sh)
# A few questions (Enter = default), a summary, Go. Then, in this order (detached: a closed window can't stop it):
#   1 guests: lock each container / HA / Ubuntu to the address it has HERE (static, MACs kept); a guest locked at the
#     bench to an address outside this LAN goes back to DHCP first. Container DNS = gateway + 1.1.1.1
#   2 HA trusted proxy = this LAN + X-Forwarded-For
#   3 host IP LAST: keep the address it has now, or a static IP you give (checked free first). Rollback copy; if the box
#     can't reach its gateway within 60 s the old config comes back by itself
#   4 pw-detect (if installed): Frigate IP, hub address, relays, heartbeat forwarder, tailnet page
#   5 optional, default off: HA as a Tailscale /32 route; Cloudflare public hostnames (HA only; Proxmox only if you
#     type "yes I understand", and then protect it with Cloudflare Access)
#   6 checks + summary
# Safe to re-run: what is already right is left alone. Log: /root/site-kit-relocate.log
#   SK_REF=<branch|tag>   kit version to download (default main)
#   SK_YES=1              no questions (env values or defaults), no Go prompt. Env names: HOST_MODE (keep|static),
#                         HOST_CIDR HOST_GW HOST_DNS LOCK_GUESTS CT_DNS HA_PROXY PW_FIX TS_ROUTE CF CF_PROX CF_ZONE CF_TOKEN_FILE
#   site-kit-relocate.sh --check   only the checks
# Old remote mode (control machine + SSH + site-kit.conf): site-kit-relocate-remote.sh (deprecated).
set -u
REPO=BaselYAS/proxmox-site-kit; SK_REF=${SK_REF:-main}; LOG=/root/site-kit-relocate.log; ANS=/root/.site-kit-relocate.answers
say(){ printf '\n== %s\n' "$*"; }
die(){ printf '!! %s\n' "$*" >&2; exit 1; }
case "${1:-}" in -h|--help) sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}" 2>/dev/null || echo "see README"; exit 0 ;; esac
if [ $# -ge 2 ] && ! command -v pveversion >/dev/null; then   # old call: <NAME> <IP> from a control machine
  echo "remote mode is deprecated: run site-kit-relocate.sh ON the box. Using site-kit-relocate-remote.sh"
  exec bash "$(dirname "${BASH_SOURCE[0]}")/site-kit-relocate-remote.sh" "$@"; fi
[ "$(id -u)" = 0 ] || die "run as root on the Proxmox host"
command -v pveversion >/dev/null || die "this is not a Proxmox VE host (no pveversion)"

# ---- 0. the kit (step scripts) next to us ----
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
if [ -z "${SK_INKIT:-}" ]; then
  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/steps/host_static.sh" ]; then KIT=$SELF_DIR
  else KIT=/root/proxmox-site-kit
    echo "downloading the kit ($REPO@$SK_REF) to $KIT"
    T=$(mktemp -d); curl -fsSL -m 120 "https://codeload.github.com/$REPO/tar.gz/$SK_REF" -o "$T/kit.tgz" || die "download failed (internet? DNS?)"
    rm -rf "$KIT"; mkdir -p "$KIT"; tar -xzf "$T/kit.tgz" -C "$KIT" --strip-components=1 || die "bad download"; rm -rf "$T"
  fi
  exec env SK_INKIT=1 bash "$KIT/site-kit-relocate.sh" "$@"
fi
KIT=$SELF_DIR

# ---- helpers ----
yn(){ case "${1,,}" in y|yes) echo y ;; *) echo n ;; esac; }
ask(){ local v=$1 q=$2 d=${3:-} a; if [ -n "${!v:-}" ]; then return; fi
  if [ -t 0 ] && [ -z "${SK_YES:-}" ]; then read -r -p "$q [${d}]: " a; else a=""; fi
  a=${a//$'\r'/}; a=${a//\\/}; a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
  printf -v "$v" '%s' "${a:-$d}"; }
cidr_ok(){ [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && python3 -c "import ipaddress,sys;ipaddress.ip_interface(sys.argv[1])" "$1" 2>/dev/null; }
ip_ok(){ [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
in_net(){ python3 -c "import ipaddress,sys;i=ipaddress.ip_interface(sys.argv[1]);sys.exit(0 if ipaddress.ip_address(sys.argv[2]) in i.network else 1)" "$1" "$2"; }
net_of(){ python3 -c "import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)" "$1"; }
cur_cidr(){ ip -4 -br a show vmbr0 2>/dev/null | awk '{print $3}' | head -1; }
cur_gw(){ ip route | awk '/^default/{print $3; exit}'; }
guest_ip(){ # $1 = ct|vm, $2 = id → first LAN IPv4
  if [ "$1" = ct ]; then pct exec "$2" -- sh -c "ip -4 -br a show eth0 | awk '{print \$3}' | cut -d/ -f1" 2>/dev/null
  else qm guest cmd "$2" network-get-interfaces 2>/dev/null | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); print([a['ip-address'] for i in d for a in i.get('ip-addresses',[]) if a['ip-address-type']=='ipv4' and not a['ip-address'].startswith(('127.','172.'))][0])
except Exception: pass"; fi; }
ha_port(){ [ -n "$1" ] || return 0; local p; for p in 80 8123; do [ "$(curl -s -o /dev/null -w '%{http_code}' -m 6 "http://$1:$p/")" != 000 ] && { echo $p; return; }; done; }
find_pw(){ local id; for id in $(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}'); do
  pct exec "$id" -- test -f /opt/pw-detect/data/settings.json 2>/dev/null && { echo "$id"; return; }; done; }
ip_free(){ # $1 = IP: nothing answers ping and nothing in the ARP table
  ping -c2 -W1 "$1" >/dev/null 2>&1 && return 1
  ip neigh show "$1" 2>/dev/null | grep -q lladdr && return 1
  local id; for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do pct config "$id" | grep -q "ip=$1/" && return 1; done; return 0; }

checks(){
  local ok=1 h f p id
  say "Checks"
  echo "host       $(cur_cidr) gw $(cur_gw) ($(grep -qE '^iface vmbr0 inet static' /etc/network/interfaces && echo static || echo DHCP))"
  ping -c1 -W2 "$(cur_gw)" >/dev/null 2>&1 && echo "OK   gateway answers" || { echo "FAIL gateway $(cur_gw) does not answer"; ok=0; }
  for id in $(pct list | awk 'NR>1{print $1}'); do
    echo "CT $id  $(pct config "$id" | awk '/^hostname:/{print $2}')  $(guest_ip ct "$id")  ($(pct config "$id" | grep -o 'ip=[^,]*' | head -1))"; done
  for id in $(qm list | awk 'NR>1{print $1}'); do echo "VM $id  $(qm config "$id" | awk '/^name:/{print $2}')  $(guest_ip vm "$id")  $(qm status "$id" | awk '{print $2}')"; done
  if pct status 101 >/dev/null 2>&1; then f=$(guest_ip ct 101)
    curl -fs -m 8 "http://$f:5000/api/version" >/dev/null && echo "OK   Frigate API http://$f:5000" || { echo "FAIL Frigate API on ${f:-no IP}:5000"; ok=0; }; fi
  if qm status 102 >/dev/null 2>&1; then h=$(guest_ip vm 102); p=$(ha_port "$h")
    [ -n "$p" ] && echo "OK   Home Assistant http://$h:$p" || { echo "FAIL Home Assistant on ${h:-no IP} (80/8123)"; ok=0; }; fi
  id=$(find_pw)
  if [ -n "$id" ]; then f=$(pct exec "$id" -- python3 -c "import json;print(json.load(open('/opt/pw-detect/data/settings.json')).get('frigate',{}).get('host',''))" 2>/dev/null)
    h=$(guest_ip ct "$id")
    [ "$f" = "$(guest_ip ct 101 2>/dev/null)" ] && echo "OK   pw-detect Frigate = $f" || { echo "FAIL pw-detect Frigate is $f, Frigate CT 101 is $(guest_ip ct 101 2>/dev/null)"; ok=0; }
    [ "$(curl -s -o /dev/null -w '%{http_code}' -m 6 "http://$h:8140/")" != 000 ] && echo "OK   pw-detect page http://$h:8140" || { echo "FAIL pw-detect page $h:8140"; ok=0; }
    p=$(pct exec "$id" -- sh -c "systemctl list-units 'pwr-*' --no-legend --plain 2>/dev/null | awk '{print \$1\" \"\$4}'" 2>/dev/null | tr '\n' ' ')
    echo "     relays: ${p:-none running (cameras not picked yet?)}"
    if pct exec "$id" -- test -x /opt/pw-detect/tools/hub_heartbeat.py 2>/dev/null; then
      pct exec "$id" -- timeout 30 /usr/bin/python3 -I /opt/pw-detect/tools/hub_heartbeat.py >/dev/null 2>&1 && echo "OK   hub heartbeat sent" || { echo "FAIL hub heartbeat (pw-hub-fwd on the host? Tailscale?)"; ok=0; }; fi
  fi
  if command -v tailscale >/dev/null; then p=$(tailscale ip -4 2>/dev/null | head -1)
    [ -n "$p" ] && echo "OK   Tailscale online $p (https://$p:8006)" || { echo "FAIL Tailscale not online (tailscale status)"; ok=0; }; fi
  [ $ok = 1 ] && echo "ALL OK" || echo "some checks FAILED (above)"; }

if [ "${1:-}" = --check ]; then checks; exit 0; fi

# ---- 1. worker (detached) ----
if [ "${1:-}" = --run ]; then
  umask 022
  # shellcheck source=/dev/null
  . "$ANS"; n=$(hostname -s | tr 'A-Z' 'a-z')
  echo "=== site-kit-relocate $(date '+%F %T') host=$HOST_MODE $HOST_CIDR gw $HOST_GW guests=$LOCK_GUESTS dns=$CT_DNS ha=$HA_PROXY pw=$PW_FIX ts=$TS_ROUTE cf=$CF"
  LAN=$(net_of "$HOST_CIDR")
  if [ "$LOCK_GUESTS" = y ] || [ "$CT_DNS" = y ]; then say "1 guests: static on this LAN ($LAN), container DNS"
    if [ "$LOCK_GUESTS" = y ]; then SK_SKIP_HOST=1 SK_GW="$HOST_GW" SK_NET="$LAN" SK_NO_DNS=$([ "$CT_DNS" = y ] && echo 0 || echo 1) timeout 900 bash "$KIT/steps/static.sh"
    else for id in $(pct list | awk 'NR>1{print $1}'); do pct set "$id" --nameserver "$HOST_GW 1.1.1.1" >/dev/null 2>&1
      pct exec "$id" -- sh -c "rm -f /etc/.pve-ignore.resolv.conf; printf 'nameserver $HOST_GW\nnameserver 1.1.1.1\n' > /etc/resolv.conf" 2>/dev/null && echo "CT$id dns $HOST_GW + 1.1.1.1"; done; fi
  fi
  [ "$HA_PROXY" = y ] && { say "2 HA trusted proxy"; SK_NET="$LAN" timeout 300 bash "$KIT/steps/ha_proxy.sh"; }
  say "3 host IP -> static $HOST_CIDR gw $HOST_GW (last: can drop this session)"
  SK_WAIT=1 timeout 200 bash "$KIT/steps/host_static.sh" "$HOST_CIDR" "$HOST_GW" "$HOST_DNS"; HRC=$?
  [ $HRC = 3 ] && echo "!! host address rolled back: the box is still at $(cur_cidr). Check the gateway/IP and re-run."
  HIP=$(cur_cidr); HIP=${HIP%/*}
  if [ "$PW_FIX" = y ]; then say "4 pw-detect"; PW=$(find_pw); FIP=$(guest_ip ct 101)
    if [ -n "$PW" ] && [ -n "$FIP" ]; then timeout 600 bash "$KIT/steps/pwdetect_fix.sh" "$PW" "$FIP" "$HIP"
    else echo "!! pw-detect CT ${PW:-not found} / Frigate IP ${FIP:-unknown}: skipped"; fi; fi
  if [ "$TS_ROUTE" = y ]; then say "5a HA over Tailscale (/32 route)"; HAIP=$(guest_ip vm 102)
    if [ -n "$HAIP" ] && [ -n "$(tailscale ip -4 2>/dev/null)" ]; then
      printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-tailscale-route.conf; sysctl -q -p /etc/sysctl.d/99-tailscale-route.conf
      tailscale set --advertise-routes="$HAIP/32" && echo "advertised $HAIP/32: approve it in the Tailscale admin console (Machines > $n > Edit route settings)"
    else echo "!! no HA IP or Tailscale offline: skipped"; fi; fi
  if [ "$CF" = y ]; then say "5b Cloudflare public hostnames (tunnel $n)"
    if [ -r "$CF_TOKEN_FILE" ] && [ -n "$CF_ZONE" ]; then
      AH="Authorization: Bearer $(cat "$CF_TOKEN_FILE")"; CFA=https://api.cloudflare.com/client/v4; HAIP=$(guest_ip vm 102)
      ACC=$(curl -s -m 20 -H "$AH" $CFA/accounts | python3 -c "import json,sys;print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
      TID=$(curl -s -m 20 -H "$AH" "$CFA/accounts/$ACC/cfd_tunnel?name=$n&is_deleted=false" | python3 -c "import json,sys;r=json.load(sys.stdin)['result'];print(r[0]['id'] if r else '')" 2>/dev/null)
      if [ -n "$TID" ]; then ING=""; HAP=$(ha_port "$HAIP")
        [ -n "$HAIP" ] && ING="{\"hostname\":\"$n-ha.$CF_ZONE\",\"service\":\"http://$HAIP:${HAP:-80}\"},"
        [ "$CF_PROX" = y ] && { ING="$ING{\"hostname\":\"$n-prox.$CF_ZONE\",\"service\":\"https://$HIP:8006\",\"originRequest\":{\"noTLSVerify\":true}},"
          echo "!! Proxmox is now PUBLIC at https://$n-prox.$CF_ZONE: add a Cloudflare Access policy for it NOW"; }
        curl -s -m 20 -X PUT -H "$AH" -H "Content-Type: application/json" "$CFA/accounts/$ACC/cfd_tunnel/$TID/configurations" \
          -d "{\"config\":{\"ingress\":[$ING{\"service\":\"http_status:404\"}]}}" | python3 -c "import json,sys;print('routes updated:',json.load(sys.stdin)['success'])"
        pct exec 105 -- sh -c 'systemctl restart cloudflared' >/dev/null 2>&1
      else echo "!! no tunnel named $n in Cloudflare: skipped"; fi; unset AH
    else echo "!! token file $CF_TOKEN_FILE / zone missing: skipped"; fi; fi
  checks
  echo "host address: $HIP  (https://$HIP:8006)$( t=$(tailscale ip -4 2>/dev/null | head -1); [ -n "$t" ] && echo "   Tailscale: $t")"
  echo "=== site-kit-relocate done $(date '+%F %T')"; exit 0
fi

# ---- 2. questions ----
say "Move this box to its branch: a few questions (Enter = default)"
CC=$(cur_cidr); CG=$(cur_gw)
[ -n "$CC" ] && [ -n "$CG" ] || die "vmbr0 has no IPv4 or no default route: plug it into the branch LAN first"
echo "now: host $CC gw $CG ($(grep -qE '^iface vmbr0 inet dhcp' /etc/network/interfaces && echo 'DHCP (bench mode)' || echo static))"
ask HOST_MODE "Host IP: keep what it has now ($CC, locked static) or set another static IP (keep/static)" "keep"
case "${HOST_MODE,,}" in keep|k) HOST_MODE=keep; HOST_CIDR=$CC; HOST_GW=$CG ;;
  static|s) HOST_MODE=static; ask HOST_CIDR "  static host IP with /prefix" "$CC"; cidr_ok "$HOST_CIDR" || die "IP must look like 192.168.1.20/24"
    ask HOST_GW "  gateway" "$CG"; ip_ok "$HOST_GW" || die "bad gateway"
    in_net "$HOST_CIDR" "$HOST_GW" && [ "${HOST_CIDR%/*}" != "$HOST_GW" ] || die "gateway $HOST_GW is not in $HOST_CIDR"
    if [ "${HOST_CIDR%/*}" != "${CC%/*}" ]; then echo "  checking ${HOST_CIDR%/*} is free (ping + ARP)…"
      ip_free "${HOST_CIDR%/*}" || die "${HOST_CIDR%/*} is in use on this LAN: pick another (or reserve it on the router)"; echo "  free"; fi ;;
  *) die "keep or static" ;; esac
ask HOST_DNS "  host DNS server" "$HOST_GW"; ip_ok "$HOST_DNS" || die "bad DNS"
ask LOCK_GUESTS "Lock the guests to the address they have here (static)? (y/n)" "y"; LOCK_GUESTS=$(yn "$LOCK_GUESTS")
ask CT_DNS "Container DNS = gateway + 1.1.1.1? (y/n)" "y"; CT_DNS=$(yn "$CT_DNS")
HA_D=n; qm status 102 >/dev/null 2>&1 && HA_D=y
ask HA_PROXY "Home Assistant trusted proxy = this LAN? (y/n)" "$HA_D"; HA_PROXY=$(yn "$HA_PROXY"); [ $HA_D = n ] && HA_PROXY=n
PWID=$(find_pw); PW_D=n; [ -n "$PWID" ] && PW_D=y
[ -n "$PWID" ] && echo "pw-detect found in CT $PWID (Frigate now $(pct exec "$PWID" -- python3 -c "import json;print(json.load(open('/opt/pw-detect/data/settings.json')).get('frigate',{}).get('host','?'))" 2>/dev/null))"
ask PW_FIX "pw-detect: point it at Frigate's new IP + re-apply relays? (y/n)" "$PW_D"; PW_FIX=$(yn "$PW_FIX"); [ $PW_D = n ] && PW_FIX=n
ask TS_ROUTE "Share HA over Tailscale as a /32 route? (the hub does not need it) (y/n)" "n"; TS_ROUTE=$(yn "$TS_ROUTE"); [ $HA_D = n ] && TS_ROUTE=n
ask CF "Cloudflare public hostnames for this box? (y/n)" "n"; CF=$(yn "$CF"); CF_PROX=n
if [ "$CF" = y ]; then
  ask CF_ZONE "  Cloudflare zone (domain)" ""; ask CF_TOKEN_FILE "  file on this box with a Cloudflare API token (Tunnel edit)" "/root/cf-api-token"
  [ -r "$CF_TOKEN_FILE" ] && [ -n "$CF_ZONE" ] || die "token file $CF_TOKEN_FILE not readable or zone empty"
  echo "  HA gets a public hostname. Proxmox (8006) public = anyone on the internet gets its login page."
  echo "  Recommended: leave it off, or protect it with Cloudflare Access (Zero Trust > Access > Applications)."
  P=""; ask P "  Publish Proxmox too? type exactly: yes I understand (Enter = no)" ""; [ "$P" = "yes I understand" ] && CF_PROX=y
fi
cat <<S

== Summary
 host       $CC -> static $HOST_CIDR gw $HOST_GW dns $HOST_DNS (set LAST; auto-rollback if the gateway is unreachable for 60 s)
 guests     lock static $LOCK_GUESTS · container DNS gateway+1.1.1.1 $CT_DNS
 HA proxy   $HA_PROXY
 pw-detect  $PW_FIX${PWID:+ (CT $PWID)}
 Tailscale HA route $TS_ROUTE · Cloudflare $CF$([ "$CF_PROX" = y ] && echo " (PROXMOX PUBLIC: add Cloudflare Access)")
 Log: $LOG
S
if [ -z "${SK_YES:-}" ] && [ -t 0 ]; then read -r -p "Go? (y/n) [y]: " a; [ "$(yn "${a:-y}")" = y ] || { echo "stopped, nothing changed"; exit 0; }; fi
( umask 077
{ for v in HOST_MODE HOST_CIDR HOST_GW HOST_DNS LOCK_GUESTS CT_DNS HA_PROXY PW_FIX TS_ROUTE CF CF_PROX CF_ZONE CF_TOKEN_FILE; do printf "%s=%q\n" "$v" "${!v:-}"; done; } > "$ANS" )

# ---- 3. run detached, follow the log ----
touch "$LOG"; L=$(wc -l < "$LOG")
setsid nohup env SK_INKIT=1 bash "$KIT/site-kit-relocate.sh" --run >> "$LOG" 2>&1 < /dev/null &
PID=$!
[ "${HOST_CIDR%/*}" != "${CC%/*}" ] && echo "the host moves to ${HOST_CIDR%/*} near the end: this window may freeze. Reconnect at https://${HOST_CIDR%/*}:8006 and run: tail $LOG"
echo "running (pid $PID). Closing this window does not stop it. Follow again: tail -f $LOG"
tail -n +$((L+1)) --pid=$PID -f "$LOG"
