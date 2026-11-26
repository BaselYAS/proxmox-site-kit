#!/bin/bash
# Run ON a Proxmox box after a move: point an installed pw-detect at the new addresses. Args: <pw-detect CT> <Frigate IP> <host IP>.
# Idempotent (same addresses = no change). Backups next to each file (.before-relocate).
#  in the CT: data/settings.json frigate.host, /etc/pw-detect/hub.conf (frigate=, hub=http://<host>:8150), then the relays
#             (pw-detect-agent re-renders on the settings change; relay-apply.py is run once more with the agent's env)
#  on the host: pw-hub-fwd.service (bind = host IP, only the CT allowed) and tailscale serve :8140 -> CT
set -u
CT=${1:?ct}; FIP=${2:?frigate ip}; HIP=${3:?host ip}
X(){ pct exec "$CT" -- bash -c "$1"; }
CTIP=$(X "ip -4 -br a show eth0 | awk '{print \$3}' | cut -d/ -f1")
chg=$(X "python3 - '$FIP' '$HIP' <<'PY'
import json,re,shutil,sys,os
fip,hip=sys.argv[1],sys.argv[2];out=[]
p='/opt/pw-detect/data/settings.json'
d=json.load(open(p)); f=d.setdefault('frigate',{})
if f.get('host')!=fip:
    shutil.copy2(p,p+'.before-relocate'); old=f.get('host'); f['host']=fip
    t=p+'.tmp'; json.dump(d,open(t,'w'),indent=2); os.replace(t,p); out.append('settings frigate %s -> %s'%(old,fip))
h='/etc/pw-detect/hub.conf'
if os.path.exists(h):
    s=open(h).read(); n=re.sub(r'(?m)^frigate=.*$','frigate='+fip,s); n=re.sub(r'(?m)^hub=http://[0-9.]+:','hub=http://'+hip+':',n)
    if n!=s: shutil.copy2(h,h+'.before-relocate'); open(h,'w').write(n); out.append('hub.conf frigate=%s hub=%s'%(fip,hip))
print('; '.join(out))
PY")
if [ -n "$chg" ]; then echo "pw-detect CT$CT: $chg"
  case "$chg" in *settings*)
    X 'systemctl restart pw-detect-agent'; sleep 20
    # once more by hand, with the agent's environment (PW_BRANCH etc.), so the relays surely use the new Frigate
    X 'set -a; eval "$(systemctl show -p Environment --value pw-detect-agent | tr " " "\n")"; set +a; timeout 300 /usr/bin/python3 /opt/pw-detect/relay-apply.py' >/tmp/sk-relay-apply.log 2>&1 \
      && echo "relay-apply OK" || echo "!! relay-apply failed: /tmp/sk-relay-apply.log (on the host)";;
  esac
else echo "pw-detect CT$CT: settings already Frigate $FIP, hub $HIP (no change)"; fi
U=/etc/systemd/system/pw-hub-fwd.service
if [ -f "$U" ]; then
  n=$(sed -E "s/bind=[0-9.]+/bind=$HIP/; s#range=[0-9.]+/32#range=$CTIP/32#; s/\(only [0-9.]+ allowed\)/(only $CTIP allowed)/" "$U")
  if [ "$n" != "$(cat "$U")" ]; then cp -p "$U" /root/pw-hub-fwd.service.before-relocate; printf '%s\n' "$n" > "$U"
    systemctl daemon-reload; systemctl restart pw-hub-fwd; echo "pw-hub-fwd: bind $HIP, allows CT $CTIP"
  else systemctl is-active -q pw-hub-fwd || systemctl restart pw-hub-fwd; echo "pw-hub-fwd: no change"; fi
fi
if command -v tailscale >/dev/null && tailscale serve status 2>/dev/null | grep -q ':8140'; then
  if tailscale serve status 2>/dev/null | grep -q "tcp://$CTIP:8140"; then echo "tailscale serve :8140 -> $CTIP (no change)"
  else tailscale serve --bg --tcp=8140 "tcp://$CTIP:8140" >/dev/null && echo "tailscale serve :8140 -> $CTIP" || echo "!! tailscale serve update failed"; fi
fi
