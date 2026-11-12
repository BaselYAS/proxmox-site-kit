#!/bin/bash
# Run ON a Proxmox box: lock host + guests to their CURRENT IPv4 (static), keep MACs. Args: none. Idempotent.
set -u
GW=$(ip route | awk '/default/{print $3; exit}'); HIP=$(ip -4 -br a show vmbr0 | awk '{print $3}'); N=$(hostname)
echo "box $N host $HIP gw $GW"
if grep -q "iface vmbr0 inet dhcp" /etc/network/interfaces; then
  cp -p /etc/network/interfaces /root/interfaces.before-static
  sed -i "s#iface vmbr0 inet dhcp#iface vmbr0 inet static\n\taddress $HIP\n\tgateway $GW#" /etc/network/interfaces
  echo "host: dhcp -> static $HIP"; NEEDRELOAD=1
else echo "host: already static"; NEEDRELOAD=0; fi
sed -i -E "s/^[0-9.]+ ($N\.\S*) $N\b.*/${HIP%/*} \1 $N   # static/" /etc/hosts; grep " $N" /etc/hosts | head -1
for id in $(pct list | tail -n +2 | awk '{print $1}'); do
  net=$(pct config $id | grep ^net0: | cut -d' ' -f2)
  if echo "$net" | grep -q "ip=dhcp"; then
    ip=$(pct exec $id -- sh -c "ip -4 -br a show eth0 | awk '{print \$3}'")
    new=$(echo "$net" | sed -E "s#ip=dhcp#ip=$ip,gw=$GW#; s#,ip6=[^,]*##")
    pct set $id --net0 "$new" && echo "CT$id -> $ip"
  else echo "CT$id already static ($(echo $net | grep -o 'ip=[^,]*'))"; fi
done
# container DNS = site router + 1.1.1.1, never Tailscale's 100.100.100.100 (containers can't reach it; it breaks cloudflared)
for id in $(pct list | tail -n +2 | awk '{print $1}'); do
  pct set $id --nameserver "$GW 1.1.1.1" >/dev/null 2>&1
  pct exec $id -- sh -c "rm -f /etc/.pve-ignore.resolv.conf; printf 'nameserver $GW\nnameserver 1.1.1.1\n' > /etc/resolv.conf" 2>/dev/null && echo "CT$id dns $GW + 1.1.1.1"
done
# HA (HAOS) via its own CLI
for id in $(qm list | tail -n +2 | awk '{print $1}'); do
  name=$(qm config $id | awk '/^name:/{print $2}')
  case "$name" in *HA*)
    j=$(qm guest exec $id -- sh -c "ha network info --raw-json" | python3 -c "import json,sys;print(json.load(sys.stdin).get('out-data',''))")
    read IF METHOD ADDR <<< $(echo "$j" | python3 -c "
import json,sys;d=json.load(sys.stdin)['data']; i=[x for x in d['interfaces'] if x.get('primary')][0]
print(i['interface'], i['ipv4']['method'], (i['ipv4'].get('address') or [''])[0])")
    if [ "$METHOD" != "static" ]; then
      qm guest exec $id -- sh -c "ha network update $IF --ipv4-method static --ipv4-address $ADDR --ipv4-gateway $GW --ipv4-nameserver $GW" >/dev/null && echo "VM$id $name -> static $ADDR"
    else echo "VM$id $name already static $ADDR"; fi ;;
  *Ubuntu*)
    cur=$(qm guest exec $id -- sh -c "ip -4 -br a show eth0 | awk '{print \$3}'; ls /etc/netplan/" | python3 -c "import json,sys;print(json.load(sys.stdin).get('out-data','').replace(chr(10),' '))")
    ip=${cur%% *}
    if echo "$cur" | grep -q "99-static.yaml"; then echo "VM$id $name already static"; else
      qm guest exec $id -- sh -c "printf 'network:\n  version: 2\n  ethernets:\n    eth0:\n      dhcp4: false\n      addresses: [$ip]\n      routes: [{to: default, via: $GW}]\n      nameservers: {addresses: [$GW]}\n' > /etc/netplan/99-static.yaml; chmod 600 /etc/netplan/99-static.yaml; for f in /etc/netplan/*.yaml; do [ \$f = /etc/netplan/99-static.yaml ] || mv \$f \$f.disabled; done; netplan apply" >/dev/null 2>&1; echo "VM$id $name -> static $ip"; fi ;;
  esac
done
[ "$NEEDRELOAD" = 1 ] && { (sleep 2; ifreload -a; systemctl restart pve-cluster pveproxy) >/dev/null 2>&1 & echo "host network reload scheduled"; }
