set -e
# Runs ON the Proxmox host (templated by site-kit-prep.sh: box name and timezone are filled in).
N=__N__; T=local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst
echo "== repos+tz+update"
for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do [ -f "$f" ] && { grep -q '^Enabled: no' $f || echo 'Enabled: no' >> $f; }; done
printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' > /etc/apt/sources.list.d/proxmox.sources
timedatectl set-timezone __TZ__; timedatectl set-ntp true
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >/dev/null 2>&1; apt-get -y -q -o Dpkg::Options::=--force-confold dist-upgrade >/dev/null 2>&1; apt-get -y -q install smartmontools >/dev/null 2>&1
f=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; grep -q NoMoreNagging $f || { sed -i.bak "s/res === null || res === undefined || \!res || res\s*\.data\.status\.toLowerCase() !== 'active'/false/" $f; echo "// NoMoreNagging" >> $f; }; systemctl restart pveproxy
pveversion; smartctl -H /dev/nvme0n1 | grep -i result
echo "== template"
pveam update >/dev/null 2>&1; [ -f /var/lib/vz/template/cache/debian-13-standard_13.6-1_amd64.tar.zst ] || pveam download local debian-13-standard_13.6-1_amd64.tar.zst >/dev/null 2>&1; ls /var/lib/vz/template/cache/
echo "== CTs"
mkdir -p -m 700 /root/$N-secrets; cp /root/.ssh/authorized_keys /root/$N-secrets/ct-keys.pub
ls -l /dev/dri
RGID=$(stat -c %g /dev/dri/renderD128); CGID=$(stat -c %g /dev/dri/card* | head -1); CARD=$(ls /dev/dri/card* | head -1)
mk(){ id=$1; name=$2; cores=$3; mem=$4; disk=$5; order=$6; shift 6
  pct status $id >/dev/null 2>&1 && { echo "$id exists"; return; }
  pct create $id $T --hostname $name --cores $cores --memory $mem --swap 512 --rootfs local-lvm:$disk \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 1 --features nesting=1,keyctl=1 \
    --onboot 1 --startup order=$order --timezone __TZ__ --ssh-public-keys /root/$N-secrets/ct-keys.pub "$@" >/dev/null
  echo "created $id $name"; }
mk 101 $N-Frigate 4 4096 40 1 --dev0 /dev/dri/renderD128,gid=104 --dev1 $CARD,gid=44
mk 104 $N-Debian 1 512 8 4
mk 105 $N-Cloudflare 1 256 2 5
for id in 101 104 105; do pct start $id 2>/dev/null || true; done; sleep 12
for id in 101 104 105; do pct exec $id -- bash -c '
passwd -l root >/dev/null 2>&1
for u in container-getty@1 console-getty; do mkdir -p /etc/systemd/system/$u.service.d; done
printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%%I 115200,38400,9600 \$TERM\n" > /etc/systemd/system/container-getty@1.service.d/autologin.conf
printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear --keep-baud console 115200,38400,9600 \$TERM\n" > /etc/systemd/system/console-getty.service.d/autologin.conf
# IPv6 off: some site routers hand out broken IPv6, which makes image/apt pulls crawl
echo "net.ipv6.conf.all.disable_ipv6=1" > /etc/sysctl.d/90-no-ipv6.conf; sysctl -q -p /etc/sysctl.d/90-no-ipv6.conf 2>/dev/null || true
systemctl daemon-reload; systemctl restart container-getty@1 2>/dev/null || true'
echo "$id $(pct exec $id -- hostname) $(pct exec $id -- sh -c "ip -4 -br a show eth0 | awk '{print \$3}'")"; done
