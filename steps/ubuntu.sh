# shellcheck shell=bash
set -e
if qm status 103 >/dev/null 2>&1; then echo "103 exists"; exit 0; fi
cd /var/lib/vz/template
IMG=noble-server-cloudimg-amd64.img
[ -s $IMG ] || curl -fsSL -o $IMG https://cloud-images.ubuntu.com/noble/current/$IMG
[ -s $IMG ] || { echo "download failed"; exit 1; }
mkdir -p /var/lib/vz/snippets
pw=$(openssl rand -base64 15); printf 'user __U__ / %s\n' "$pw" > /root/__N__-secrets/vm103-__N__-Ubuntu.login; chmod 600 /root/__N__-secrets/vm103-__N__-Ubuntu.login
H=$(openssl passwd -6 "$pw"); unset pw
cat > /var/lib/vz/snippets/__n__-ubuntu-user.yml <<Y
#cloud-config
hostname: __N__-Ubuntu
timezone: __TZ__
users:
  - name: __U__
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    passwd: "$H"
    ssh_authorized_keys:
$(sed 's/^/      - /' /root/__N__-secrets/ct-keys.pub)
ssh_pwauth: false
package_update: true
packages: [qemu-guest-agent, ubuntu-desktop-minimal, unattended-upgrades]
runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl set-default graphical.target
  # cloud-init off after first boot, or it re-runs and resets the user/password
  - touch /etc/cloud/cloud-init.disabled
  - sysctl -w net.ipv6.conf.all.disable_ipv6=1
  - echo net.ipv6.conf.all.disable_ipv6=1 > /etc/sysctl.d/90-no-ipv6.conf
  - reboot
Y
chmod 600 /var/lib/vz/snippets/__n__-ubuntu-user.yml
qm create 103 --name __N__-Ubuntu --machine q35 --cores 2 --memory 3072 --ostype l26 --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci --agent enabled=1 --onboot 1 --startup order=3 --vga virtio --serial0 socket \
  --description "Ubuntu 24.04 LTS desktop (cloud image + ubuntu-desktop-minimal), __N__"
qm importdisk 103 $IMG local-lvm >/dev/null
qm set 103 --scsi0 local-lvm:vm-103-disk-0,discard=on,ssd=1 --boot order=scsi0 --ide2 local-lvm:cloudinit \
  --ipconfig0 ip=dhcp --cicustom user=local:snippets/__n__-ubuntu-user.yml >/dev/null
qm resize 103 scsi0 40G >/dev/null
qm start 103; echo "Ubuntu VM started (desktop installs on first boot, ~15-30 min)"
