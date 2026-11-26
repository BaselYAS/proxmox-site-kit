# shellcheck shell=bash
# Runs ON the Proxmox host: set HA (VM 102) trusted proxy = this LAN /24 + X-Forwarded-For on, in HA's own storage
# (.storage/http; HAOS ignores a YAML http: block for these). Edited only while HA core is stopped (clean
# `ha core stop` / edit / `ha core start`), backup kept. Idempotent.
NET=$(ip -4 -br a show vmbr0 | awk '{print $3}' | python3 -c "import ipaddress,sys;print(ipaddress.ip_interface(sys.stdin.read().strip()).network)")
qm guest exec 102 --timeout 180 -- sh -c "
F=/mnt/data/supervisor/homeassistant/.storage/http
[ -f \$F ] || { echo 'HA http storage not there yet (HA not started once?)'; exit 0; }
grep -q '\"$NET\"' \$F && grep -q '\"use_x_forwarded_for\": true' \$F && { echo 'HA proxy already $NET'; exit 0; }
ha core stop >/dev/null 2>&1; cp -p \$F \$F.bak-prep
if grep -q '\"trusted_proxies\"' \$F; then
  sed -i -E '/\"trusted_proxies\": \[/,/\]/c\      \"trusted_proxies\": [\n        \"$NET\"\n      ],' \$F
else
  sed -i 's#      \"server_port\": \([0-9]*\),#      \"server_port\": \1,\n      \"trusted_proxies\": [\n        \"$NET\"\n      ],#' \$F
fi
if grep -q '\"use_x_forwarded_for\"' \$F; then sed -i 's/\"use_x_forwarded_for\": false/\"use_x_forwarded_for\": true/' \$F
else sed -i 's#      \"server_port\": \([0-9]*\),#      \"server_port\": \1,\n      \"use_x_forwarded_for\": true,#' \$F; fi
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do ha core start >/dev/null 2>&1; sleep 5; docker ps --format '{{.Names}}' | grep -qx homeassistant && break; sleep 10; done; docker ps --format '{{.Names}}' | grep -qx homeassistant && echo 'HA proxy set to $NET (HA running)' || echo 'HA proxy set to $NET but HA did NOT start: run ha core start'" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('out-data','').strip())"
