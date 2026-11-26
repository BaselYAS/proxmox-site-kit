# shellcheck shell=bash
set -e
type note >/dev/null 2>&1 || { note(){ echo "      $*"; }; skipped(){ note "$*"; }; }   # site-kit.sh exports these (screen lines)
V=18.4
if qm status 102 >/dev/null 2>&1; then skipped "VM 102 exists: left alone"; exit 0; fi
cd /var/lib/vz/template; [ -f haos_ova-$V.qcow2 ] || { note "downloading Home Assistant OS $V disk (~0.5 GB)"; curl -fsSL -o haos.qcow2.xz https://github.com/home-assistant/operating-system/releases/download/$V/haos_ova-$V.qcow2.xz; note "downloaded $(du -h haos.qcow2.xz | cut -f1), unpacking"; xz -d haos.qcow2.xz; mv haos.qcow2 haos_ova-$V.qcow2; }
[ -s haos_ova-$V.qcow2 ] || { echo "download failed"; exit 1; }
note "creating VM 102 __N__-HA (2 cores, 3 GB RAM, 32 GB disk)"
qm create 102 --name __N__-HA --machine q35 --bios ovmf --cores 2 --memory 3072 --balloon 0 --ostype l26   --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --agent enabled=1 --onboot 1 --startup order=2 --tablet 0   --description "Home Assistant OS $V (pinned, __N__)"
qm set 102 --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 >/dev/null
note "importing the HA disk ($(du -h haos_ova-$V.qcow2 | cut -f1))"; qm importdisk 102 haos_ova-$V.qcow2 local-lvm >/dev/null
qm set 102 --scsi0 local-lvm:vm-102-disk-1,discard=on,ssd=1 --boot order=scsi0 >/dev/null
qm resize 102 scsi0 32G >/dev/null
qm start 102
note "VM 102 started, waiting for the guest agent"; rm -f haos_ova-$V.qcow2

for i in $(seq 60); do qm agent 102 ping 2>/dev/null && break; sleep 10; done
note "guest agent up; HA first start (90 s)"; sleep 90
IF=$(qm guest exec 102 -- sh -c "ha network info --raw-json 2>/dev/null" | python3 -c "import json,sys;d=json.loads(json.load(sys.stdin).get('out-data','{}'));print([i['interface'] for i in d['data']['interfaces'] if i.get('primary')][0])" 2>/dev/null)
[ -n "$IF" ] && qm guest exec 102 -- sh -c "ha network update $IF --ipv6-method disabled" >/dev/null 2>&1 && note "HA IPv6 disabled on $IF" || note "HA IPv6: do it in Settings > Network"
