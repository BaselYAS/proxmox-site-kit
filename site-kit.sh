#!/bin/bash
# site-kit.sh: turn a fresh Proxmox VE 9 box into a ready site box. Run it AS ROOT ON THE BOX (console or SSH):
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/BaselYAS/proxmox-site-kit/main/site-kit.sh)
#
# It asks a few questions (Enter = default), shows a summary, then builds:
#   CT 101 Frigate (NVR) · VM 102 Home Assistant OS · optional VM 103 Ubuntu desktop · optional CT 105 Cloudflare tunnel
#   host basics (repos, upgrade, timezone, NTP, smartmontools, nag off) · Tailscale on the host · static IPs
# Safe to re-run: every part that already exists is skipped. The window shows numbered steps (also in
# /root/site-kit.screen); the full detail (apt, downloads) is in /root/site-kit.log
#
#   site-kit.sh --check      only the end-of-run checks (parts up, Tailscale, free CPU/RAM)
#   site-kit.sh --help
# Answers can be given ahead as environment variables (same names as in /root/site-kit.answers), plus SK_YES=1 to skip
# the confirm. SK_REF=<branch|tag> picks the kit version to download (default main).
set -u
LOG=/root/site-kit.log; ANS=/root/site-kit.answers; KIT=/root/proxmox-site-kit
REPO=BaselYAS/proxmox-site-kit; SK_REF=${SK_REF:-main}
say(){ printf '\n== %s\n' "$*"; }
die(){ printf '!! %s\n' "$*" >&2; exit 1; }
case "${1:-}" in -h|--help) sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}" 2>/dev/null || echo "see README"; exit 0 ;; esac
[ "$(id -u)" = 0 ] || die "run as root on the Proxmox host"
command -v pveversion >/dev/null || die "this is not a Proxmox VE host (no pveversion)"

# ---- 0. get the whole kit (step scripts) next to us, unless we already run from a kit folder ----
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
if [ -z "${SK_INKIT:-}" ]; then
  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/steps/host.sh" ]; then KIT=$SELF_DIR
  else
    echo "downloading the kit ($REPO@$SK_REF) to $KIT"
    T=$(mktemp -d); curl -fsSL -m 120 "https://codeload.github.com/$REPO/tar.gz/$SK_REF" -o "$T/kit.tgz" || die "download failed (internet? DNS?)"
    rm -rf "$KIT"; mkdir -p "$KIT"; tar -xzf "$T/kit.tgz" -C "$KIT" --strip-components=1 || die "bad download"; rm -rf "$T"
  fi
  exec env SK_INKIT=1 bash "$KIT/site-kit.sh" "$@"
fi
KIT=$SELF_DIR

# ---- helpers ----
yn(){ case "${1,,}" in y|yes) echo y ;; *) echo n ;; esac; }
# ask VAR "question" "default": keeps an env/answers value, else asks (Enter = default)
ask(){ local v=$1 q=$2 d=${3:-} a; if [ -n "${!v:-}" ]; then return; fi
  if [ -t 0 ]; then read -r -p "$q [${d}]: " a; else a=""; fi
  a=${a//$'\r'/}; a=${a//\\/}; a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"   # web consoles can send CR / stray chars
  printf -v "$v" '%s' "${a:-$d}"; }
DHCP_WARN="DHCP is for bench prep only: run site-kit-relocate.sh ON the box at the site"
cidr_ok(){ [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }
ip_ok(){ [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
cur_cidr(){ ip -4 -br a show vmbr0 2>/dev/null | awk '{print $3}' | head -1; }
cur_gw(){ ip route | awk '/^default/{print $3; exit}'; }
guest_ip(){ # $1 = ct|vm, $2 = id → first LAN IPv4
  if [ "$1" = ct ]; then pct exec "$2" -- sh -c "ip -4 -br a show eth0 | awk '{print \$3}' | cut -d/ -f1" 2>/dev/null
  else qm guest cmd "$2" network-get-interfaces 2>/dev/null | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); print([a['ip-address'] for i in d for a in i.get('ip-addresses',[]) if a['ip-address-type']=='ipv4' and not a['ip-address'].startswith(('127.','172.'))][0])
except Exception: pass"; fi; }
run_step(){ # $1 = step name: templated like the remote prep did, run here, output to the log
  sed -e "s|__N__|$SITE|g; s|__n__|$n|g; s|__U__|$UBUNTU_USER|g; s|__TZ__|$TIMEZONE|g" "$KIT/steps/$1.sh" > "/root/.site-kit-$1.sh"
  echo "--- step $1 ($(date '+%F %T'))"; SK_CTS="$SK_CTS" timeout "${2:-2400}" bash "/root/.site-kit-$1.sh"; local rc=$?
  rm -f "/root/.site-kit-$1.sh"; echo "--- step $1 rc=$rc"; return $rc; }

# HA answers on :80 (recent HA) or :8123 (older): print the one that answers
ha_port(){ [ -n "$1" ] || return 0; local p; for p in 80 8123; do [ "$(curl -s -o /dev/null -w '%{http_code}' -m 6 "http://$1:$p/")" != 000 ] && { echo $p; return; }; done; }
# ---- checks (end of run, or --check) ----
checks(){
  # shellcheck source=/dev/null
  [ -f "$ANS" ] && . "$ANS"
  say "Checks"; local ok=1 fip hip
  if pct status 101 >/dev/null 2>&1; then fip=$(guest_ip ct 101)
    if [ -n "$fip" ] && curl -fsS -m 8 "http://$fip:5000/api/version" >/dev/null 2>&1; then echo "OK   Frigate  http://$fip:5000  (version $(curl -s -m 5 http://$fip:5000/api/version))"
    else echo "FAIL Frigate  CT 101 up? API on ${fip:-no IP}:5000 not answering (pct exec 101 -- docker logs frigate)"; ok=0; fi; fi
  if qm status 102 >/dev/null 2>&1; then hip=$(guest_ip vm 102)
    local hp; hp=$(ha_port "$hip")
    if [ -n "$hp" ]; then echo "OK   Home Assistant  http://$hip:$hp"
    else echo "WAIT Home Assistant  ${hip:-no IP yet} not answering on :80 or :8123 (first boot takes 5-15 min; re-run: site-kit.sh --check)"; ok=0; fi; fi
  if qm status 103 >/dev/null 2>&1; then echo "OK   Ubuntu VM 103 $(qm status 103 | awk '{print $2}') (desktop installs inside for 15-30 min)"; fi
  if pct status 105 >/dev/null 2>&1; then pct exec 105 -- systemctl is-active -q cloudflared 2>/dev/null && echo "OK   Cloudflare tunnel connector running" || { echo "FAIL Cloudflare connector not running (pct exec 105 -- journalctl -u cloudflared)"; ok=0; }; fi
  if command -v tailscale >/dev/null; then local t; t=$(tailscale ip -4 2>/dev/null | head -1)
    [ -n "$t" ] && echo "OK   Tailscale  $t  ($(tailscale status --self --peers=false 2>/dev/null | awk 'NR==1{print $2}'))" || { echo "WAIT Tailscale not online: run  tailscale up  and open the link"; ok=0; }; fi
  echo "     host  $(cur_cidr) gw $(cur_gw)"
  local cores used mem alloc; cores=$(nproc); mem=$(free -m | awk '/^Mem:/{print $2}')
  used=$( { for i in $(pct list | awk 'NR>1{print $1}'); do pct config "$i" | awk '/^cores:/{print $2}'; done; for i in $(qm list | awk 'NR>1{print $1}'); do qm config "$i" | awk '/^cores:/{print $2}'; done; } | awk '{s+=$1} END{print s+0}')
  alloc=$( { for i in $(pct list | awk 'NR>1{print $1}'); do pct config "$i" | awk '/^memory:/{print $2}'; done; for i in $(qm list | awk 'NR>1{print $1}'); do qm config "$i" | awk '/^memory:/{print $2}'; done; } | awk '{s+=$1} END{print s+0}')
  echo "     CPU   $cores threads, ${used:-0} given to guests · RAM ${mem} MB, ${alloc:-0} MB given to guests, $(free -m | awk '/^Mem:/{print $7}') MB free now"
  return $((1-ok)); }
manual_left(){
  say "Left for you (by hand)"
  qm status 102 >/dev/null 2>&1 && { h=$(guest_ip vm 102); p=$(ha_port "$h"); echo " - Home Assistant: open http://${h:-<HA IP>}:${p:-8123} and create the owner account"; }
  echo " - BIOS: set \"power on after AC loss\" (Restore on AC power loss = Power On), so the box comes back after a power cut"
  pct status 101 >/dev/null 2>&1 && echo " - Frigate: add the cameras (http://$(guest_ip ct 101 || echo '<Frigate IP>'):5000 > Settings, or /opt/frigate/config/config.yml in CT 101)"
  qm status 103 >/dev/null 2>&1 && echo " - Ubuntu desktop: password is in /root/$SITE-secrets/ (change it: qm guest passwd 103 $UBUNTU_USER)"
  [ "${P_TS:-n}" = y ] && echo " - Tailscale: approve the box in the admin console if asked. Tagged tag:client = the hub rule applies by itself; untagged = ask your network admin for the box's access rule"
  [ "${P_TS:-n}" = y ] && [ -n "$(tailscale ip -4 2>/dev/null)" ] && qm status 102 >/dev/null 2>&1 && echo " - Tailscale: approve the HA route ($(guest_ip vm 102)/32) in the admin console (Machines > $n > Edit route settings)"
}
handover(){
  say "Next: the pw-detect installer (optional)"
  echo "It needs a one-time command from the hub: open the hub > Add site > copy the command (it has --hub and --token)."
  echo "Frigate for it: $(guest_ip ct 101 2>/dev/null || echo '<Frigate IP>')"
  [ -t 0 ] || { echo "(not interactive: paste the hub command later on this host)"; return; }
  local c; read -r -p "Paste the hub command now to run it, or Enter to skip: " c
  [ -z "$c" ] && { echo "skipped: paste the hub command on this host whenever you are ready"; return; }
  case "$c" in "bash "*|"curl "*) ;; *) echo "that doesn't look like the hub's install command (it starts with bash or curl): skipped"; return ;; esac
  PW_FRIGATE=$(guest_ip ct 101 2>/dev/null) bash -c "$c"; }

if [ "${1:-}" = --check ]; then checks; n=${SITE,,}; manual_left; exit 0; fi

# ---- 1. worker (detached): does the work. stdout = the full log; the window shows $SK_SCREEN (lib/progress.sh) ----
p_tailscale(){
  command -v tailscale >/dev/null || { note "installing Tailscale"; curl -fsSL https://tailscale.com/install.sh | sh >/tmp/ts-install.log 2>&1 || { show "!! Tailscale install failed (/tmp/ts-install.log)"; return 1; }; }
  if [ -n "$(tailscale ip -4 2>/dev/null)" ]; then skipped "Tailscale already online: $(tailscale ip -4 | head -1)"; return 0; fi
  local TAGS="" U i; [ -n "${TS_TAGS:-}" ] && TAGS="--advertise-tags=$TS_TAGS"
  note "joining the tailnet as $n ${TS_TAGS:+(tag $TS_TAGS)}"
  (tailscale up --hostname="$n" $TAGS >/tmp/ts-up.log 2>&1 &); sleep 8
  if [ -n "$TAGS" ] && grep -q -i -E "tag.*(not|invalid|permitted|owner)|requested tags" /tmp/ts-up.log; then
    show "!! Tailscale refused the tag ${TS_TAGS} (it must exist in the tailnet's tagOwners). Joining WITHOUT a tag; ask your admin to tag the box."
    (tailscale up --hostname="$n" --reset >/tmp/ts-up.log 2>&1 &); sleep 8
  fi
  U=$(grep -o 'https://login.tailscale.com[^ ]*' /tmp/ts-up.log | head -1)
  [ -n "$U" ] && { show ">>> APPROVE THIS BOX IN TAILSCALE: open this link and log in:"; show ">>> $U"; }
  note "waiting for approval (up to ${TS_WAIT_MIN:-10} min)"
  for i in $(seq $(( ${TS_WAIT_MIN:-10} * 6 ))); do [ -n "$(tailscale ip -4 2>/dev/null)" ] && break; sleep 10; done
  if [ -n "$(tailscale ip -4 2>/dev/null)" ]; then note "Tailscale online: $(tailscale ip -4 | head -1)"
  else show "!! Tailscale not approved within ${TS_WAIT_MIN:-10} min: carrying on. Later: run  tailscale up  and open the link."; fi
  note "with tag:client the hub access rule applies by itself; untagged: ask your network admin to tag it or add its rule"; }
p_cloudflare(){
  if [ -s /root/.site-kit-cf-token ]; then
    pct push 105 /root/.site-kit-cf-token /root/cf-token >/dev/null && rm -f /root/.site-kit-cf-token
    note "installing cloudflared in CT 105"
    pct exec 105 -- bash -c 'export DEBIAN_FRONTEND=noninteractive; umask 077; mkdir -p /etc/cloudflared; mv /root/cf-token /etc/cloudflared/token
command -v cloudflared >/dev/null || { apt-get update -q; apt-get install -y -q curl gpg; mkdir -p /usr/share/keyrings; curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg; echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" > /etc/apt/sources.list.d/cloudflared.list; apt-get update -q; apt-get install -y -q cloudflared; }
printf "[Unit]\nDescription=Cloudflare tunnel\nAfter=network-online.target\nWants=network-online.target\n[Service]\nExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token\nRestart=on-failure\nRestartSec=5\n[Install]\nWantedBy=multi-user.target\n" > /etc/systemd/system/cloudflared.service
systemctl daemon-reload; systemctl enable --now cloudflared >/dev/null 2>&1; systemctl is-active cloudflared' && note "cloudflared running"
  elif pct exec 105 -- test -s /etc/cloudflared/token 2>/dev/null; then skipped "tunnel token already in CT 105"
  else show "!! no tunnel token given: put it in CT 105 /etc/cloudflared/token and re-run"; return 1; fi; }
p_haproxy(){ local HAIP="" i
  note "waiting for the HA VM's IP (guest agent)"
  for i in $(seq 30); do HAIP=$(guest_ip vm 102); [ -n "$HAIP" ] && break; sleep 20; done
  [ -n "$HAIP" ] || { show "!! HA VM 102 has no IP yet (first boot can be slow): re-run later"; return 1; }
  note "HA IP $HAIP; setting the trusted proxy"
  local out; out=$(timeout 300 bash "$KIT/steps/ha_proxy.sh") || { show "!! $out"; return 1; }
  case "$out" in *already*) skipped "HA at $HAIP, $out" ;; *) note "$out" ;; esac
  if [ "$P_TS" = y ] && [ -n "$(tailscale ip -4 2>/dev/null)" ]; then
    printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-tailscale-route.conf; sysctl -q -p /etc/sysctl.d/99-tailscale-route.conf
    tailscale set --advertise-routes="$HAIP/32" && note "HA route $HAIP/32 advertised on Tailscale: approve it in the admin console"; fi; }
p_static(){ note "locking guests to their current IPs"; SK_SKIP_HOST=1 SK_GW="${HOST_GW:-}" timeout 600 bash "$KIT/steps/static.sh"; }
p_hostip(){
  if [ "$NET_MODE" = dhcp ]; then note "host -> DHCP"
    SK_WAIT=1 timeout 300 bash "$KIT/steps/host_dhcp.sh" | while IFS= read -r l; do case $l in "host: already DHCP"*) skipped "${l#host: }" ;; *) note "$l" ;; esac; done
    return "${PIPESTATUS[0]}"; fi
  if [ "$HOST_CIDR" = "$(cur_cidr)" ] && [ "$HOST_GW" = "$(cur_gw)" ] && ! grep -q "iface vmbr0 inet dhcp" /etc/network/interfaces; then
    skipped "host already at $HOST_CIDR gw $HOST_GW"; return 0; fi
  cp -p /etc/network/interfaces "/root/interfaces.before-site-kit.$(date +%s)"
  python3 - "$HOST_CIDR" "$HOST_GW" <<'PY'
import re,sys;p='/etc/network/interfaces';s=open(p).read();a,g=sys.argv[1],sys.argv[2]
s=re.sub(r'iface vmbr0 inet (dhcp|static|manual)\n((?:[ \t]+(?:address|gateway) [^\n]*\n)*)','iface vmbr0 inet static\n\taddress %s\n\tgateway %s\n'%(a,g),s,count=1);open(p,'w').write(s)
PY
  sed -i -E "s/^[0-9.]+ ($(hostname)\.\S*) $(hostname)\b.*/${HOST_CIDR%/*} \1 $(hostname)   # set by site-kit/" /etc/hosts
  rm -f /etc/dhcp/dhclient-exit-hooks.d/site-kit-hosts   # DHCP bench mode hook, not needed on static
  [ -n "${HOST_DNS:-}" ] && printf 'search %s\nnameserver %s\n' "$(hostname -d 2>/dev/null || echo local)" "$HOST_DNS" > /etc/resolv.conf
  show "      rollback: cp /root/interfaces.before-site-kit.* /etc/network/interfaces; ifreload -a"
  show "      host moves to ${HOST_CIDR%/*} in 5 s: reconnect there (https://${HOST_CIDR%/*}:8006)"
  (sleep 5; dhclient -x vmbr0 >/dev/null 2>&1; ifreload -a; systemctl restart pve-cluster pveproxy) >/dev/null 2>&1 &   # stop a bench-mode dhclient first
  sleep 15; }
if [ "${1:-}" = --run ]; then
  umask 022   # unprivileged CT rootfs must be readable by the mapped root
  # shellcheck source=/dev/null
  . "$ANS"; n=${SITE,,}
  # shellcheck source=lib/progress.sh
  . "$KIT/lib/progress.sh"
  SK_CTS=""; [ "$P_FRIGATE" = y ] && SK_CTS="101"; [ "$P_CF" = y ] && SK_CTS="$SK_CTS 105"; SK_CTS=${SK_CTS# }
  echo "=== site-kit $(date '+%F %T') site=$SITE parts: frigate=$P_FRIGATE ha=$P_HA ubuntu=$P_UBUNTU cloudflare=$P_CF tailscale=$P_TS net=$NET_MODE"
  N=1; for x in "$P_TS" "$P_FRIGATE" "$P_HA" "$P_UBUNTU" "$P_CF" "$P_HA" "$LOCK_STATIC"; do [ "$x" = y ] && N=$((N+1)); done
  [ "$NET_MODE" != keep ] && N=$((N+1)); plan $N
  show "site-kit: $N steps. Full detail: $LOG"
  part "Host basics + containers (${SK_CTS:-none})" run_step host 1800
  [ "$P_TS" = y ] && part "Tailscale on the host" p_tailscale
  [ "$P_FRIGATE" = y ] && part "Frigate (CT 101)" run_step frigate 1800
  [ "$P_HA" = y ] && part "Home Assistant OS (VM 102)" run_step ha 1800
  [ "$P_UBUNTU" = y ] && part "Ubuntu desktop (VM 103)" run_step ubuntu 1800
  [ "$P_CF" = y ] && part "Cloudflare tunnel connector (CT 105)" p_cloudflare
  [ "$P_HA" = y ] && part "HA address + trusted proxy" p_haproxy
  [ "$LOCK_STATIC" = y ] && part "Static IPs for the guests" p_static
  # host network last: it can drop this session
  [ "$NET_MODE" != keep ] && part "Host IP -> $([ "$NET_MODE" = dhcp ] && echo DHCP || echo "$HOST_CIDR gw $HOST_GW")" p_hostip
  recap
  { checks; manual_left; [ "$NET_MODE" = dhcp ] && echo " - !! $DHCP_WARN"; echo "=== site-kit done $(date '+%F %T')"; } 2>&1 | tee -a "$SK_SCREEN"
  exit 0
fi

# ---- 2. questions ----
# shellcheck source=/dev/null
[ -f "$ANS" ] && { echo "earlier answers found ($ANS): they are reused; delete the file to be asked again"; . "$ANS"; }
say "Proxmox site kit: a few questions (Enter = default)"
ask SITE "Site / box name (letters, digits, -)" "$(hostname -s)"
[[ $SITE =~ ^[A-Za-z0-9-]{2,30}$ ]] || die "site name: 2-30 letters, digits or -"
ask TIMEZONE "Timezone" "Asia/Riyadh"; [ -e "/usr/share/zoneinfo/$TIMEZONE" ] || die "unknown timezone $TIMEZONE"
echo "Host network now: $(cur_cidr) gw $(cur_gw) ($(grep -q 'iface vmbr0 inet dhcp' /etc/network/interfaces && echo DHCP || echo static))"
ask NET_MODE "Host IP: keep as it is, set static, or DHCP for bench prep (keep/static/dhcp)" "keep"
NET_MODE=$(printf %s "$NET_MODE" | tr "A-Z" "a-z")
case "$NET_MODE" in keep|k) NET_MODE=keep; HOST_CIDR=""; HOST_GW=""; HOST_DNS="" ;;
  dhcp|d) NET_MODE=dhcp; HOST_CIDR=""; HOST_GW=""; HOST_DNS=""; echo "  $DHCP_WARN" ;;
  static|s) NET_MODE=static; ask HOST_CIDR "  static host IP with /prefix" "$(cur_cidr)"; cidr_ok "$HOST_CIDR" || die "IP must look like 192.168.1.20/24"
          ask HOST_GW "  gateway" "$(cur_gw)"; ip_ok "$HOST_GW" || die "bad gateway"
          ask HOST_DNS "  DNS server" "$HOST_GW"; ip_ok "$HOST_DNS" || die "bad DNS" ;;
  *) die "keep, static or dhcp" ;; esac
ask P_FRIGATE "Frigate NVR (CT 101)? (y/n)" "y"; P_FRIGATE=$(yn "$P_FRIGATE")
ask P_HA "Home Assistant OS (VM 102)? (y/n)" "y"; P_HA=$(yn "$P_HA")
ask P_UBUNTU "Ubuntu desktop (VM 103)? (y/n)" "n"; P_UBUNTU=$(yn "$P_UBUNTU")
[ "$P_UBUNTU" = y ] && ask UBUNTU_USER "  Ubuntu user" "admin"; UBUNTU_USER=${UBUNTU_USER:-admin}
[[ $UBUNTU_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "bad Ubuntu user"
ask P_CF "Cloudflare tunnel connector (CT 105)? (y/n)" "n"; P_CF=$(yn "$P_CF")
if [ "$P_CF" = y ] && ! pct exec 105 -- test -s /etc/cloudflared/token 2>/dev/null && [ ! -s /root/.site-kit-cf-token ]; then
  echo "  Cloudflare dashboard > Zero Trust > Networks > Tunnels > Create (Cloudflared) > copy the token (the long string after --token)."
  echo "  Public hostnames (e.g. Proxmox :8006, HA :8123) are added there too. The token is stored only in CT 105."
  if [ -n "${CF_TOKEN:-}" ]; then t=$CF_TOKEN; elif [ -t 0 ]; then read -r -s -p "  tunnel token (hidden): " t; echo; else t=""; fi
  [ -n "$t" ] && ( umask 077; printf '%s\n' "${t##* }" > /root/.site-kit-cf-token ); unset t CF_TOKEN
fi
ask P_TS "Tailscale on the host (remote access)? (y/n)" "y"; P_TS=$(yn "$P_TS")
[ "$P_TS" = y ] && ask TS_TAGS "Tailscale tag for this box (type none for no tag)" "tag:client"
TS_TAGS=${TS_TAGS:-tag:client}; [ "$TS_TAGS" = none ] && TS_TAGS=""; TS_WAIT_MIN=${TS_WAIT_MIN:-10}
ask LOCK_STATIC "Lock the new guests to the IP they get (static, no DHCP reservations needed)? (y/n)" "$([ "$NET_MODE" = dhcp ] && echo n || echo y)"; LOCK_STATIC=$(yn "$LOCK_STATIC")
n=${SITE,,}
say "Summary"
cat <<S
 box        $SITE   (timezone $TIMEZONE)
 host IP    $(case "$NET_MODE" in static) echo "set static $HOST_CIDR gw $HOST_GW dns $HOST_DNS (done last; reconnect there)" ;; dhcp) echo "DHCP (done last; the IP may change: reconnect via Tailscale)" ;; *) echo "keep $(cur_cidr)" ;; esac)
 Frigate    $P_FRIGATE   CT 101 $SITE-Frigate (4 cores, 4 GB, 40 GB) $( [ -e /dev/dri/renderD128 ] && echo "GPU $(cat /sys/class/drm/renderD128/device/vendor 2>/dev/null)" || echo "no GPU found: CPU detector")
 Home Asst  $P_HA   VM 102 $SITE-HA (2 cores, 3 GB, 32 GB)
 Ubuntu     $P_UBUNTU   VM 103 $SITE-Ubuntu (2 cores, 3 GB, 40 GB)
 Cloudflare $P_CF   CT 105 $SITE-Cloudflare
 Tailscale  $P_TS   host joins as "$n" (you open an approval link)
 static IPs $LOCK_STATIC
 Existing guests with these IDs are left alone (skipped). Log: $LOG
S
[ "$NET_MODE" = dhcp ] && echo " !! $DHCP_WARN"
for id in 101 102 103 105; do { pct status $id >/dev/null 2>&1 || qm status $id >/dev/null 2>&1; } && echo " note: ID $id already exists -> skipped"; done
if [ -z "${SK_YES:-}" ] && [ -t 0 ]; then read -r -p "Go? (y/n) [y]: " a; [ "$(yn "${a:-y}")" = y ] || { echo "stopped, nothing changed"; exit 0; }; fi
( umask 077
{ for v in SITE TIMEZONE NET_MODE HOST_CIDR HOST_GW HOST_DNS P_FRIGATE P_HA P_UBUNTU UBUNTU_USER P_CF P_TS TS_TAGS TS_WAIT_MIN LOCK_STATIC; do printf "%s=%q\n" "$v" "${!v}"; done; } > "$ANS" )

# ---- 3. run detached (a closed window or dropped SSH never kills it), follow the log ----
touch "$LOG"; : > /root/site-kit.screen
setsid nohup env SK_INKIT=1 bash "$KIT/site-kit.sh" --run >> "$LOG" 2>&1 < /dev/null &
PID=$!
echo "running (pid $PID). You can close this window: it keeps going. Follow again with:  tail -f /root/site-kit.screen"
echo "Full detail (apt, downloads): $LOG. Total time: ~20-40 min (downloads). Watch for the Tailscale approval link."
tail -n +1 --pid=$PID -f /root/site-kit.screen
[ -t 0 ] && handover
