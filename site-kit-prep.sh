#!/bin/bash
# site-kit-prep.sh — stand up a fresh Proxmox VE box as a standard edge/site box, in one command.
#
#   site-kit-prep.sh <NAME> <LAN-IP> [--net keep|dhcp|static <ADDR/CIDR> <GATEWAY>] [--no-tunnel] [--fg]
#     NAME     box identity, e.g. SITE7 (used for every guest: SITE7-Frigate …, Tailscale site7, hostnames site7-prox/-ha)
#     LAN-IP   where the box answers SSH right now (root key must already be in /root/.ssh/authorized_keys)
#     --net    keep (default): leave the network as configured, only fix /etc/hosts to the real IP
#              dhcp: switch vmbr0 to DHCP · static: set vmbr0 to ADDR/CIDR + GATEWAY
#     --no-tunnel  skip the Cloudflare tunnel step
#     --fg     run in the foreground (default: detached with setsid, so a closed terminal never kills it)
#
# Steps (log: WORK_DIR/<name>/driver.log, one log per step next to it):
#   1 host: no-subscription repos, full update, TIMEZONE + NTP, smartmontools, nag off, Debian 13 template,
#     CTs 101 Frigate / 104 Debian / 105 Cloudflare (DHCP, no root password, console auto-login, IPv6 off)
#   2 Tailscale as <name lowercase>, tag:client (one-way), one-time key from the API
#   3 Frigate 0.17.2 (pinned) in CT 101: Docker, iGPU passed through, OpenVINO detector, no Frigate login
#   4 HA: HAOS 18.4 VM 102 (2 cores, 3 GB, 32 GB), IPv6 disabled via `ha network`
#   5 Ubuntu 24.04 desktop VM 103 (user UBUNTU_USER, cloud-init disabled after first boot, IPv6 off)
#   6 network per --net, /etc/hosts fixed to the real IP; 6b HA's IP shared over Tailscale as a /32 route (required)
#   7 Cloudflare tunnel <NAME>: cloudflared in CT 105 (token file 600), routes <n>-prox → host:8006, <n>-ha → HA:80, DNS
#   8 runs NOTIFY_CMD (if set) so someone verifies and reports
# Left for a human: HA owner account, BIOS "power on after AC loss", Ubuntu password
# (`qm guest passwd 103 <UBUNTU_USER>` on the host). Safe to re-run: every step skips what already exists.
set -u
usage(){ sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -ge 2 ] || { usage; exit 2; }
N="$1"; IP="$2"; shift 2; NET=keep; SADDR=""; SGW=""; TUNNEL=1; FG=0
while [ $# -gt 0 ]; do case "$1" in
  --net) NET="$2"; shift 2; if [ "$NET" = static ]; then SADDR="$1"; SGW="$2"; shift 2; fi ;;
  --no-tunnel) TUNNEL=0; shift ;; --fg) FG=1; shift ;; *) echo "unknown option $1"; exit 2 ;; esac; done
[[ "$N" =~ ^[A-Za-z0-9-]+$ ]] || { echo "bad NAME"; exit 2; }
case "$NET" in keep|dhcp|static) ;; *) echo "--net must be keep|dhcp|static"; exit 2 ;; esac
n=$(echo "$N" | tr 'A-Z' 'a-z'); T=$(cd "$(dirname "$0")" && pwd)
# Settings (all optional) come from site-kit.conf next to this script, or the file in $SITEKIT_CONF (see site-kit.conf.example):
#   TS_AUTHKEY / TS_API_TOKEN_FILE   Tailscale: a ready auth key, or an API token file to mint a one-time tag:client key;
#                                    neither → `tailscale up` prints a login URL in the log for a human to approve
#   CF_API_TOKEN_FILE + CF_ZONE      Cloudflare tunnel step (skipped if either is missing)
#   UBUNTU_USER                      desktop VM user (default admin)
#   TIMEZONE                         host, containers and Ubuntu VM (default Asia/Riyadh)
#   WORK_DIR                         where logs go (default ~/site-kit-work)
#   NOTIFY_CMD                       optional command run at the end with the box name and log dir as arguments
TS_AUTHKEY=""; TS_API_TOKEN_FILE=""; CF_API_TOKEN_FILE=""; CF_ZONE=""; WORK_DIR="$HOME/site-kit-work"; NOTIFY_CMD=""
UBUNTU_USER="admin"; TIMEZONE="Asia/Riyadh"
CONF="${SITEKIT_CONF:-$T/site-kit.conf}"; [ -f "$CONF" ] && . "$CONF"
[[ "$UBUNTU_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "bad UBUNTU_USER"; exit 2; }
[[ "$TIMEZONE" =~ ^[A-Za-z0-9_+/-]+$ ]] || { echo "bad TIMEZONE"; exit 2; }
W="$WORK_DIR/$n"; mkdir -p "$W"
if [ "$FG" = 0 ]; then
  setsid nohup "$0" "$N" "$IP" --net "$NET" $SADDR $SGW $([ $TUNNEL = 0 ] && echo --no-tunnel) --fg >/dev/null 2>&1 < /dev/null &
  echo "started detached: $N ($IP), log $W/driver.log"; exit 0
fi
S="ssh -o BatchMode=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new"
log(){ echo "$(date '+%F %T')  $*" >> "$W/driver.log"; }
tpl(){ sed -e "s|__N__|$N|g; s|__n__|$n|g; s|__U__|$UBUNTU_USER|g; s|__TZ__|$TIMEZONE|g" "$T/steps/$1.sh"; }
log "== $N at $IP, net=$NET tunnel=$TUNNEL"
$S root@$IP true 2>>"$W/driver.log" || { log "cannot SSH root@$IP (is the key added?)"; exit 1; }

log "1 host"; tpl host | timeout 1500 $S root@$IP 'bash -s' >> "$W/host.log" 2>&1; log "  rc=$?"

log "2 tailscale"
K="$TS_AUTHKEY"
if [ -z "$K" ] && [ -n "$TS_API_TOKEN_FILE" ] && [ -r "$TS_API_TOKEN_FILE" ]; then TT=$(cat "$TS_API_TOKEN_FILE")
K=$(curl -s -m 20 -u "$TT:" -X POST https://api.tailscale.com/api/v2/tailnet/-/keys -H "Content-Type: application/json" \
  -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":false,\"preauthorized\":true,\"tags\":[\"tag:client\"]}}},\"expirySeconds\":1800,\"description\":\"$N join\"}" \
  | python3 -c "import json,sys;print(json.load(sys.stdin).get('key',''))"); unset TT; fi
if [ -z "$K" ]; then   # no key: interactive login, URL goes to the log
  $S root@$IP "command -v tailscale >/dev/null || (curl -fsSL https://tailscale.com/install.sh | sh >/tmp/ts-install.log 2>&1); (tailscale up --hostname=$n --advertise-tags=tag:client >/tmp/ts-up.log 2>&1 &) ; sleep 8; grep -o 'https://login.tailscale.com[^ ]*' /tmp/ts-up.log | head -1" | sed 's/^/  APPROVE THIS LOGIN: /' >> "$W/driver.log"
  for i in $(seq 60); do TS=$($S root@$IP "tailscale ip -4 2>/dev/null | head -1"); [ -n "$TS" ] && break; sleep 10; done; echo "$TS" > "$W/ts_ip"
else
printf '%s' "$K" | timeout 300 $S root@$IP "K=\$(cat); command -v tailscale >/dev/null || (curl -fsSL https://tailscale.com/install.sh | sh >/tmp/ts-install.log 2>&1); tailscale up --authkey=\"\$K\" --hostname=$n >/dev/null 2>&1; unset K; tailscale ip -4" > "$W/ts_ip" 2>>"$W/driver.log"; unset K
fi
TS=$(head -1 "$W/ts_ip"); log "  tailscale $n = ${TS:-FAILED}"
[ -n "$TS" ] || { log "stopping: no Tailscale"; exit 1; }
H=root@$TS

for s in frigate ha ubuntu; do log "3-5 $s"; tpl $s | timeout 2400 $S $H 'bash -s' >> "$W/$s.log" 2>&1; log "  rc=$?"; done

log "6 network ($NET)"
case "$NET" in
  dhcp)   $S $H "cp -p /etc/network/interfaces /root/interfaces.before-prep; python3 -c \"
import re;p='/etc/network/interfaces';s=open(p).read()
open(p,'w').write(re.sub(r'iface vmbr0 inet static\n(\s+address [^\n]+\n)(\s+gateway [^\n]+\n)?','iface vmbr0 inet dhcp\n',s))\"; (sleep 2; ifreload -a) >/dev/null 2>&1 &" ; sleep 25 ;;
  static) $S $H "cp -p /etc/network/interfaces /root/interfaces.before-prep; python3 -c \"
import re;p='/etc/network/interfaces';s=open(p).read()
s=re.sub(r'iface vmbr0 inet (dhcp|static)\n(\s+address [^\n]+\n)?(\s+gateway [^\n]+\n)?','iface vmbr0 inet static\n\taddress $SADDR\n\tgateway $SGW\n',s);open(p,'w').write(s)\"; (sleep 2; ifreload -a) >/dev/null 2>&1 &" ; sleep 25 ;;
esac
HOSTIP=$($S $H "ip -4 -br a show vmbr0 | awk '{print \$3}' | cut -d/ -f1")
$S $H "sed -i -E 's/^[0-9.]+ ($N\\.\\S*) $N.*/$HOSTIP \\1 $N   # set by site-kit-prep; update if the IP changes/' /etc/hosts; systemctl restart pve-cluster pveproxy" >> "$W/driver.log" 2>&1
log "  host IP $HOSTIP"
HAIP=""; for i in $(seq 30); do HAIP=$($S $H "qm guest cmd 102 network-get-interfaces 2>/dev/null" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); print([a['ip-address'] for i in d for a in i.get('ip-addresses',[]) if a['ip-address-type']=='ipv4' and not a['ip-address'].startswith(('127.','172.'))][0])
except Exception: pass"); [ -n "$HAIP" ] && break; sleep 20; done
log "  HA IP ${HAIP:-unknown}"
# 6b REQUIRED on every box: share ONLY HA's address over Tailscale (a /32, never the whole site LAN), so HA's own UI
#    stays reachable from anywhere once the box sits on a site LAN. Approved via the API when TS_API_TOKEN_FILE is set.
if [ -n "$HAIP" ]; then
  $S $H "printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-tailscale-route.conf; sysctl -q -p /etc/sysctl.d/99-tailscale-route.conf; tailscale set --advertise-routes=$HAIP/32" >> "$W/driver.log" 2>&1
  if [ -n "$TS_API_TOKEN_FILE" ] && [ -r "$TS_API_TOKEN_FILE" ]; then
    TT=$(cat "$TS_API_TOKEN_FILE")
    DID=$(curl -s -m 20 -u "$TT:" https://api.tailscale.com/api/v2/tailnet/-/devices | python3 -c "import json,sys;print([d['id'] for d in json.load(sys.stdin)['devices'] if d['hostname'].lower()=='$n' or d['name'].startswith('$n.')][0])" 2>/dev/null)
    [ -n "$DID" ] && curl -s -m 20 -u "$TT:" -X POST "https://api.tailscale.com/api/v2/device/$DID/routes" -H "Content-Type: application/json" -d "{\"routes\":[\"$HAIP/32\"]}" >/dev/null && log "  HA route $HAIP/32 shared over Tailscale (approved)"
    unset TT
  else log "  HA route $HAIP/32 advertised; APPROVE it in the Tailscale admin console (Machines > $n > Edit route settings)"; fi
  log "  HA trusted proxy:"; timeout 240 $S $H 'bash -s' < "$T/steps/ha_proxy.sh" >> "$W/driver.log" 2>&1
fi

if [ "$TUNNEL" = 1 ] && { [ -z "$CF_API_TOKEN_FILE" ] || [ ! -r "$CF_API_TOKEN_FILE" ] || [ -z "$CF_ZONE" ]; }; then log "7 tunnel skipped (no CF_API_TOKEN_FILE/CF_ZONE in config)"; TUNNEL=0; fi
if [ "$TUNNEL" = 1 ]; then
  log "7 cloudflare tunnel $N"
  CT=$(cat "$CF_API_TOKEN_FILE"); AH="Authorization: Bearer $CT"; CF=https://api.cloudflare.com/client/v4; unset CT
  ACC=$(curl -s -m 20 -H "$AH" $CF/accounts | python3 -c "import json,sys;print(json.load(sys.stdin)['result'][0]['id'])")
  Z=$(curl -s -m 20 -H "$AH" "$CF/zones?name=$CF_ZONE" | python3 -c "import json,sys;print(json.load(sys.stdin)['result'][0]['id'])")
  TID=$(curl -s -m 20 -H "$AH" "$CF/accounts/$ACC/cfd_tunnel?name=$N&is_deleted=false" | python3 -c "import json,sys;r=json.load(sys.stdin)['result'];print(r[0]['id'] if r else '')")
  [ -z "$TID" ] && TID=$(curl -s -m 20 -X POST -H "$AH" -H "Content-Type: application/json" "$CF/accounts/$ACC/cfd_tunnel" -d "{\"name\":\"$N\",\"config_src\":\"cloudflare\"}" | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['id'])")
  log "  tunnel $TID"
  curl -s -m 20 -H "$AH" "$CF/accounts/$ACC/cfd_tunnel/$TID/token" | python3 -c "import json,sys;print(json.load(sys.stdin)['result'])" \
    | $S $H 'pct exec 105 -- bash -c "umask 077; mkdir -p /etc/cloudflared; cat > /etc/cloudflared/token"'
  $S $H "pct exec 105 -- bash -c \"export DEBIAN_FRONTEND=noninteractive; command -v cloudflared >/dev/null || { apt-get update -q; apt-get install -y -q curl gpg; mkdir -p /usr/share/keyrings; curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg; echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list; apt-get update -q; apt-get install -y -q cloudflared; } >/dev/null 2>&1
printf '[Unit]\nDescription=Cloudflare tunnel $N\nAfter=network-online.target\nWants=network-online.target\n[Service]\nExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token\nRestart=on-failure\nRestartSec=5\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/cloudflared-$n.service
systemctl daemon-reload; systemctl enable --now cloudflared-$n >/dev/null 2>&1; systemctl is-active cloudflared-$n\"" >> "$W/driver.log" 2>&1
  ING="[{\"hostname\":\"$n-prox.$CF_ZONE\",\"service\":\"https://$HOSTIP:8006\",\"originRequest\":{\"noTLSVerify\":true}}"
  [ -n "$HAIP" ] && ING="$ING,{\"hostname\":\"$n-ha.$CF_ZONE\",\"service\":\"http://$HAIP:80\"}"
  curl -s -m 20 -X PUT -H "$AH" -H "Content-Type: application/json" "$CF/accounts/$ACC/cfd_tunnel/$TID/configurations" -d "{\"config\":{\"ingress\":$ING,{\"service\":\"http_status:404\"}]}}" | python3 -c "import json,sys;print('  ingress ok:',json.load(sys.stdin)['success'])" >> "$W/driver.log" 2>&1
  for h in $n-prox $n-ha; do curl -s -m 20 -X POST -H "$AH" -H "Content-Type: application/json" "$CF/zones/$Z/dns_records" -d "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$TID.cfargotunnel.com\",\"proxied\":true,\"comment\":\"$N tunnel (site-kit)\"}" | python3 -c "import json,sys;d=json.load(sys.stdin);print('  $h dns:',d['success'],[e.get('message') for e in d.get('errors',[])])" >> "$W/driver.log" 2>&1; done
  unset AH
fi
log "ALL DONE"
[ -n "$NOTIFY_CMD" ] && $NOTIFY_CMD "$N" "$W" >> "$W/driver.log" 2>&1
