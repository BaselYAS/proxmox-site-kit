# shellcheck shell=bash
set -e
umask 022
# Runs ON the Proxmox host (templated by site-kit.sh / site-kit-prep.sh: box name and timezone are filled in).
N=__N__
type note >/dev/null 2>&1 || { note(){ echo "      $*"; }; skipped(){ note "$*"; }; }   # site-kit.sh exports these (screen lines)
# containers to create (site-kit.sh sets SK_CTS; the old remote prep default keeps 101 104 105)
SK_CTS=${SK_CTS:-101 104 105}
note "repos (no-subscription), timezone __TZ__, NTP"
for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do [ -f "$f" ] && { grep -q '^Enabled: no' $f || echo 'Enabled: no' >> $f; }; done
printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' > /etc/apt/sources.list.d/proxmox.sources
timedatectl set-timezone __TZ__; timedatectl set-ntp true
export DEBIAN_FRONTEND=noninteractive
note "apt update"; apt-get update -q
UP=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true); note "upgrading $UP packages"
apt-get -y -q -o Dpkg::Options::=--force-confold dist-upgrade; note "installing smartmontools"; apt-get -y -q install smartmontools
f=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; grep -q NoMoreNagging $f || { sed -i.bak "s/res === null || res === undefined || \!res || res\s*\.data\.status\.toLowerCase() !== 'active'/false/" $f; echo "// NoMoreNagging" >> $f; systemctl reload pveproxy; }   # only when patched, and reload (graceful) not restart: a restart cut the web console the kit runs in
pveversion; for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do R=$(smartctl -H /dev/$d 2>/dev/null | grep -i result | sed "s/.*: *//"); note "SMART $d: ${R:-no SMART data (virtual disk or USB bridge?)}"; done
# newest Debian 13 template already on the box, else the newest one pveam offers
TF=$(ls /var/lib/vz/template/cache/ 2>/dev/null | grep '^debian-13-standard_.*_amd64.tar.zst$' | sort -V | tail -1)
if [ -z "$TF" ]; then pveam update >/dev/null 2>&1; TF=$(pveam available --section system | awk '{print $2}' | grep '^debian-13-standard_.*_amd64.tar.zst$' | sort -V | tail -1)
  [ -n "$TF" ] && { note "downloading CT template $TF"; pveam download local "$TF"; }; fi
[ -n "$TF" ] && [ -f /var/lib/vz/template/cache/$TF ] || { echo "!! no Debian 13 CT template (pveam download failed?)"; exit 1; }
T=local:vztmpl/$TF; note "CT template $TF ($(du -h /var/lib/vz/template/cache/$TF | cut -f1))"
mkdir -p -m 700 /root/$N-secrets; cat /root/.ssh/authorized_keys > /root/$N-secrets/ct-keys.pub 2>/dev/null || true
KEYS=""; [ -s /root/$N-secrets/ct-keys.pub ] && KEYS="--ssh-public-keys /root/$N-secrets/ct-keys.pub"
GPUDEV=""; if [ -e /dev/dri/renderD128 ]; then ls -l /dev/dri; CARD=$(ls /dev/dri/card* 2>/dev/null | head -1)
  GPUDEV="--dev0 /dev/dri/renderD128,gid=104"; [ -n "$CARD" ] && GPUDEV="$GPUDEV --dev1 $CARD,gid=44"
else echo "no /dev/dri/renderD128: Frigate gets no GPU (CPU detector)"; fi
NEW=0; mk(){ id=$1; name=$2; cores=$3; mem=$4; disk=$5; order=$6; shift 6
  pct status $id >/dev/null 2>&1 && { note "CT $id exists: left alone"; return; }
  NEW=$((NEW+1))
  note "creating CT $id $name ($cores cores, $((mem/1024)) GB RAM, $disk GB disk)"
  pct create $id $T --hostname $name --cores $cores --memory $mem --swap 512 --rootfs local-lvm:$disk \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 1 --features nesting=1,keyctl=1 \
    --onboot 1 --startup order=$order --timezone __TZ__ $KEYS "$@" >/dev/null
  note "created CT $id $name"; }
for id in $SK_CTS; do case $id in
  101) mk 101 $N-Frigate 4 4096 40 1 $GPUDEV ;;
  104) mk 104 $N-Debian 1 512 8 4 ;;
  105) mk 105 $N-Cloudflare 1 256 2 5 ;;
esac; done
[ -n "$SK_CTS" ] || { note "no containers asked for"; [ "$UP" = 0 ] && skipped "host already up to date, no containers asked for"; exit 0; }
note "starting CT(s) $SK_CTS"
for id in $SK_CTS; do pct start $id 2>/dev/null || true; done; sleep 12
for id in $SK_CTS; do pct exec $id -- bash -c '
passwd -l root >/dev/null 2>&1
for u in container-getty@1 console-getty; do mkdir -p /etc/systemd/system/$u.service.d; done
printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%%I 115200,38400,9600 \$TERM\n" > /etc/systemd/system/container-getty@1.service.d/autologin.conf
printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear --keep-baud console 115200,38400,9600 \$TERM\n" > /etc/systemd/system/console-getty.service.d/autologin.conf
# IPv6 off: some site routers hand out broken IPv6, which makes image/apt pulls crawl
echo "net.ipv6.conf.all.disable_ipv6=1" > /etc/sysctl.d/90-no-ipv6.conf; sysctl -q -p /etc/sysctl.d/90-no-ipv6.conf 2>/dev/null || true
systemctl daemon-reload; systemctl restart container-getty@1 2>/dev/null || true'
note "CT $id $(pct exec $id -- hostname) up, IP $(pct exec $id -- sh -c "ip -4 -br a show eth0 | awk '{print \$3}'")"; done
[ "$UP" = 0 ] && [ "$NEW" = 0 ] && skipped "host already up to date; CT(s) $SK_CTS already there"
exit 0
