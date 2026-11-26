# shellcheck shell=bash
set -e
type note >/dev/null 2>&1 || { note(){ echo "      $*"; }; skipped(){ note "$*"; }; }   # site-kit.sh exports these (screen lines)
# Runs ON the Proxmox host. Detector by GPU: Intel iGPU -> OpenVINO on the GPU + VAAPI decode;
# AMD iGPU -> OpenVINO on the CPU + VAAPI decode; no GPU -> OpenVINO on the CPU, software decode.
pct status 101 >/dev/null 2>&1 || { echo "CT 101 missing (host step failed?)"; exit 1; }
VEN=$(cat /sys/class/drm/renderD128/device/vendor 2>/dev/null || true)
case "$VEN" in
  0x8086) GPU=intel; OVDEV=GPU; HW="  hwaccel_args: preset-vaapi" ;;
  0x1002) GPU=amd;   OVDEV=CPU; HW="  hwaccel_args: preset-vaapi" ;;
  *)      GPU=none;  OVDEV=CPU; HW="  hwaccel_args: []" ;;
esac
pct config 101 | grep -q '^dev0:' || { [ "$GPU" = none ] || echo "!! CT 101 has no GPU passed through: CPU detector + software decode"; GPU=none; OVDEV=CPU; HW="  hwaccel_args: []"; }
note "GPU: $GPU (OpenVINO detector on $OVDEV)"
IMG=ghcr.io/blakeblackshear/frigate:0.17.2
if [ "$(pct exec 101 -- sh -c "docker inspect -f '{{.State.Running}} {{.Config.Image}}' frigate 2>/dev/null" 2>/dev/null)" = "true $IMG" ]; then
  skipped "Frigate already running (${IMG##*:}, API $(pct exec 101 -- curl -s -m 5 http://127.0.0.1:5000/api/version || echo 'not answering'))"; exit 0; fi
DEVS=""; [ "$GPU" != none ] && DEVS="    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128"
set -o pipefail
pct exec 101 -- env OVDEV="$OVDEV" HW="$HW" DEVS="$DEVS" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
echo "NOTE: apt update + curl in CT 101"; apt-get update -q && apt-get -y -q install curl ca-certificates
command -v docker >/dev/null || { echo "NOTE: installing Docker in CT 101 (get.docker.com)"; curl -fsSL https://get.docker.com | sh; }
echo "NOTE: $(docker --version)"
mkdir -p /opt/frigate/config /opt/frigate/storage
[ -f /opt/frigate/config/config.yml ] || cat > /opt/frigate/config/config.yml <<C
# __N__ Frigate — cameras get added on site. Camera passwords via {FRIGATE_RTSP_PASSWORD} env substitution only.
auth:
  enabled: false   # no Frigate login: never publish ports 5000/8971 raw (LAN/Tailscale only)
mqtt:
  enabled: false
detectors:
  ov:
    type: openvino
    device: $OVDEV
ffmpeg:
$HW
record:
  enabled: true
  retain:
    days: 3
    mode: motion
model:
  width: 300
  height: 300
  input_tensor: nhwc
  input_pixel_format: bgr
  path: /openvino-model/ssdlite_mobilenet_v2.xml
  labelmap_path: /openvino-model/coco_91cl_bkgr.txt
cameras:
  placeholder:
    enabled: false
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/placeholder
          roles: [detect]
C
cat > /opt/frigate/docker-compose.yml <<C
services:
  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:0.17.2   # pinned: tested version, upgrade on purpose
    restart: unless-stopped
    shm_size: "256mb"
$DEVS
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /opt/frigate/config:/config
      - /opt/frigate/storage:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs: {size: 1000000000}
    ports:
      - "8971:8971"
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
C
cd /opt/frigate; echo "NOTE: pulling $(grep -o "image: [^ ]*" docker-compose.yml | cut -d" " -f2) (about 1.5 GB download)"; docker compose pull -q
echo "NOTE: image pulled ($(docker image inspect -f "{{.Size}}" $(grep -o "image: [^ ]*" docker-compose.yml | cut -d" " -f2) | awk "{printf \"%.1f GB\", \$1/1e9}") on disk)"
echo "NOTE: starting Frigate, health check in 40 s"; docker compose up -d
sleep 40
docker ps --format "{{.Names}} {{.Image}} {{.Status}}"
V=$(curl -s -m 5 http://127.0.0.1:5000/api/version); E=$(docker logs frigate 2>&1 | grep -ciE "traceback|typeerror" || true)
if [ -n "$V" ]; then echo "NOTE: health check OK: Frigate API answers, version $V, $E errors in its log"; else echo "NOTE: !! health check: Frigate API not answering yet ($E errors in its log: pct exec 101 -- docker logs frigate)"; fi
' | while IFS= read -r l; do case $l in "NOTE: "*) note "${l#NOTE: }" ;; *) printf '%s\n' "$l" ;; esac; done
