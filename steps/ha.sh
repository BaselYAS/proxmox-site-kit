# shellcheck shell=bash
set -e
V=18.4
if qm status 102 >/dev/null 2>&1; then echo "102 exists"; exit 0; fi
cd /var/lib/vz/template; [ -f haos_ova-$V.qcow2 ] || { curl -fsSL -o haos.qcow2.xz https://github.com/home-assistant/operating-system/releases/download/$V/haos_ova-$V.qcow2.xz; xz -d haos.qcow2.xz; mv haos.qcow2 haos_ova-$V.qcow2; }
[ -s haos_ova-$V.qcow2 ] || { echo "download failed"; exit 1; }
qm create 102 --name __N__-HA --machine q35 --bios ovmf --cores 2 --memory 3072 --balloon 0 --ostype l26   --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --agent enabled=1 --onboot 1 --startup order=2 --tablet 0   --description "Home Assistant OS $V (pinned, __N__)"
qm set 102 --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 >/dev/null
qm importdisk 102 haos_ova-$V.qcow2 local-lvm >/dev/null
qm set 102 --scsi0 local-lvm:vm-102-disk-1,discard=on,ssd=1 --boot order=scsi0 >/dev/null
qm resize 102 scsi0 32G >/dev/null
qm start 102
echo "HA VM started"; rm -f haos_ova-$V.qcow2

for i in $(seq 60); do qm guest ping 102 2>/dev/null && break; sleep 10; done
sleep 90
IF=$(qm guest exec 102 -- sh -c "ha network info --raw-json 2>/dev/null" | python3 -c "import json,sys;d=json.loads(json.load(sys.stdin).get('out-data','{}'));print([i['interface'] for i in d['data']['interfaces'] if i.get('primary')][0])" 2>/dev/null)
[ -n "$IF" ] && qm guest exec 102 -- sh -c "ha network update $IF --ipv6-method disabled" >/dev/null 2>&1 && echo "HA IPv6 disabled on $IF" || echo "HA IPv6: do it in Settings > Network"
