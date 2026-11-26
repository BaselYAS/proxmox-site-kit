#!/bin/bash
# DEPRECATED (use site-kit-relocate.sh ON the box). Kept for old site-kit-prep.sh boxes.
# site-kit-relocate-remote.sh <NAME> <SSH-IP or Tailscale IP> — run when a box built by site-kit-prep.sh has landed on its
# new site LAN. Safe to re-run. In order:
#   1 lock host + every guest to its CURRENT IPv4 (static, MACs kept), /etc/hosts = real IP
#   2 container DNS = site router + 1.1.1.1 (never Tailscale's 100.100.100.100)
#   3 HA trusted proxy = this LAN /24 + X-Forwarded-For on (HA's .storage/http, clean core stop/start)
#   4 (TAILSCALE=on only, default off) share ONLY HA's IP over Tailscale as a /32 route (ip_forward) and approve it (TS_API_TOKEN_FILE)
#   5 Cloudflare tunnel <NAME>: <name>-ha → HA:80; <name>-prox → host:8006 ONLY with CF_PUBLISH_PROXMOX=yes (public: add Cloudflare Access!), → HA:80 (CF_API_TOKEN_FILE + CF_ZONE)
#   6 test both public links and print a summary
# Settings come from site-kit.conf (same file as site-kit-prep.sh; $SITEKIT_CONF overrides the path).
set -u
usage(){ sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -ge 2 ] || { usage; exit 2; }
N="$1"; IP="$2"; n=$(echo "$N" | tr A-Z a-z); T=$(cd "$(dirname "$0")" && pwd)
TAILSCALE="off"; CF_PUBLISH_PROXMOX="no"; TS_API_TOKEN_FILE=""; CF_API_TOKEN_FILE=""; CF_ZONE=""; CONF="${SITEKIT_CONF:-$T/site-kit.conf}"; [ -f "$CONF" ] && . "$CONF"
S="ssh -o BatchMode=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new root@$IP"
echo "== 1-2 static + DNS"; timeout 300 $S 'bash -s' < "$T/steps/static.sh"
sleep 10
HOSTIP=$($S "ip -4 -br a show vmbr0 | awk '{print \$3}' | cut -d/ -f1")
HAIP=$($S "qm guest cmd 102 network-get-interfaces 2>/dev/null" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); print([a['ip-address'] for i in d for a in i.get('ip-addresses',[]) if a['ip-address-type']=='ipv4' and not a['ip-address'].startswith(('127.','172.'))][0])
except Exception: pass")
echo "host $HOSTIP  HA ${HAIP:-?}"
echo "== 3 HA trusted proxy"; timeout 240 $S 'bash -s' < "$T/steps/ha_proxy.sh"
[ "$TAILSCALE" = off ] && echo "== 4 skipped (TAILSCALE=off)"
if [ -n "$HAIP" ] && [ "$TAILSCALE" != off ]; then
  echo "== 4 HA over Tailscale"
  $S "printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-tailscale-route.conf; sysctl -q -p /etc/sysctl.d/99-tailscale-route.conf; tailscale set --advertise-routes=$HAIP/32" && echo "advertised $HAIP/32"
  if [ -n "$TS_API_TOKEN_FILE" ] && [ -r "$TS_API_TOKEN_FILE" ]; then TT=$(cat "$TS_API_TOKEN_FILE")
    DID=$(curl -s -m 20 -u "$TT:" https://api.tailscale.com/api/v2/tailnet/-/devices | python3 -c "import json,sys;print([d['id'] for d in json.load(sys.stdin)['devices'] if d['hostname'].lower()=='$n' or d['name'].startswith('$n.')][0])" 2>/dev/null)
    [ -n "$DID" ] && curl -s -m 20 -u "$TT:" -X POST "https://api.tailscale.com/api/v2/device/$DID/routes" -H "Content-Type: application/json" -d "{\"routes\":[\"$HAIP/32\"]}" | python3 -c "import json,sys;print('approved:',json.load(sys.stdin).get('enabledRoutes'))"
    unset TT
  else echo "approve $HAIP/32 for $n in the Tailscale console"; fi
fi
if [ -n "$CF_API_TOKEN_FILE" ] && [ -r "$CF_API_TOKEN_FILE" ] && [ -n "$CF_ZONE" ]; then
  echo "== 5 Cloudflare tunnel $N"; CT=$(cat "$CF_API_TOKEN_FILE"); AH="Authorization: Bearer $CT"; unset CT; CF=https://api.cloudflare.com/client/v4
  ACC=$(curl -s -m 20 -H "$AH" $CF/accounts | python3 -c "import json,sys;print(json.load(sys.stdin)['result'][0]['id'])")
  TID=$(curl -s -m 20 -H "$AH" "$CF/accounts/$ACC/cfd_tunnel?name=$N&is_deleted=false" | python3 -c "import json,sys;r=json.load(sys.stdin)['result'];print(r[0]['id'] if r else '')")
  if [ -n "$TID" ]; then
    ING="["; [ "$CF_PUBLISH_PROXMOX" = yes ] && { ING="[{\"hostname\":\"$n-prox.$CF_ZONE\",\"service\":\"https://$HOSTIP:8006\",\"originRequest\":{\"noTLSVerify\":true}},"; echo "!! Proxmox goes public: protect $n-prox.$CF_ZONE with Cloudflare Access"; }
    [ -n "$HAIP" ] && ING="$ING{\"hostname\":\"$n-ha.$CF_ZONE\",\"service\":\"http://$HAIP:80\"},"
    curl -s -m 20 -X PUT -H "$AH" -H "Content-Type: application/json" "$CF/accounts/$ACC/cfd_tunnel/$TID/configurations" -d "{\"config\":{\"ingress\":$ING{\"service\":\"http_status:404\"}]}}" | python3 -c "import json,sys;print('routes updated:',json.load(sys.stdin)['success'])"
    $S "pct exec 105 -- sh -c 'systemctl restart cloudflared-$n 2>/dev/null || systemctl restart cloudflared'" >/dev/null 2>&1
  else echo "no tunnel named $N in Cloudflare"; fi
  unset AH; sleep 15
  echo "== 6 test"; for h in $n-prox $n-ha; do curl -s -m 15 -o /dev/null -w "$h.$CF_ZONE: %{http_code}\n" https://$h.$CF_ZONE/; done
fi
echo "done: $N host $HOSTIP, HA ${HAIP:-?}"
