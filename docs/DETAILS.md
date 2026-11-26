# proxmox-site-kit: details

The simple path is `site-kit.sh` on the box (see the README). This page keeps the details, the gotchas, and the
**older remote style** (`site-kit-prep.sh`, run from a control machine over SSH), which still works but is **deprecated**:
it builds the old layout (with CT 104 Debian) and needs config files with API tokens.

One command to turn a fresh Proxmox VE box into a ready edge/site box (NVR + home automation + desktop + remote access),
and one command to re-home it when it moves to a new site LAN.

**Status: beta.** Used on 4 real boxes; not yet run by a third party. Read the scripts before you point them at a box.

## What it builds
- CT 101 `<NAME>-Frigate` — Frigate 0.17.2 NVR in Docker, iGPU passed through, OpenVINO detector (4 cores, 4 GB, 40 GB)
- VM 102 `<NAME>-HA` — Home Assistant OS 18.4 (2 cores, 3 GB, 32 GB, UEFI)
- VM 103 `<NAME>-Ubuntu` — Ubuntu 24.04 desktop (cloud image + ubuntu-desktop-minimal, 2 cores, 3 GB, 40 GB)
- CT 104 `<NAME>-Debian` — plain Debian 13 utility container (1 core, 512 MB)
- CT 105 `<NAME>-Cloudflare` — cloudflared for the tunnel `<NAME>` (1 core, 256 MB)
- Host: no-subscription repos, full upgrade, timezone + NTP, smartmontools, subscription nag off
- Tailscale on the host (`<name>`, `tag:client`), with only HA's IP shared as a /32 route
- Optional Cloudflare tunnel: `<name>-prox.<zone>` → Proxmox UI, `<name>-ha.<zone>` → Home Assistant

Every step skips what already exists, so both commands are safe to re-run.

## Requirements
- Target: Proxmox VE 9 (Debian 13 "trixie" base) on a box with an Intel or AMD integrated GPU (`/dev/dri/renderD128`; tested on Intel N100/N150 and AMD Ryzen 5 3500U), `local-lvm` storage, bridge `vmbr0`, Ethernet plugged in, internet access.
- Your SSH public key in the box's `/root/.ssh/authorized_keys`.
- Control machine: any Linux with `bash`, `ssh`, `curl`, `python3`, `setsid`.
- A Tailscale account (auth key or API token), or run with `--no-tailscale` / `TAILSCALE=off` if you reach your sites another way
  (your own VPN, or the Cloudflare `-prox` link). Without Tailscale, HA isn't shared remotely and `--net dhcp` is refused. Optional: a Cloudflare zone + API token for the tunnel.

## Remote style (deprecated): site-kit-prep.sh
    cp site-kit.conf.example site-kit.conf          # fill in your own keys (never commit it)
    ./site-kit-prep.sh SITE7 192.168.1.50            # keep the box's network as configured
    ./site-kit-prep.sh SITE7 192.168.1.50 --net dhcp # or switch it to DHCP
    ./site-kit-prep.sh SITE7 192.168.1.50 --net static 192.168.5.20/24 192.168.5.1
It runs detached (use `--fg` to stay attached); logs in `WORK_DIR/site7/driver.log`, one log per step next to it.
The Ubuntu desktop keeps installing inside the VM for 15-30 min after its step finishes.

When the box has been moved to its site and is on the new LAN:

    ./site-kit-relocate.sh SITE7 <its LAN or Tailscale IP>
Locks host + guests to their current IPs, sets container DNS to the site router + 1.1.1.1, sets HA's trusted proxy to
the new LAN, re-shares HA's IP over Tailscale (/32), updates the Cloudflare tunnel routes and tests both public links.

`./site-kit-prep.sh --help` and `./site-kit-relocate.sh --help` print the full usage.

## Config reference (`site-kit.conf`, or the file in `$SITEKIT_CONF`)
- `TS_AUTHKEY` — a ready Tailscale auth key (tag it `tag:client`)
- `TS_API_TOKEN_FILE` — file with a Tailscale API token: mints a one-time key per box and approves the HA route.
  Neither set → `tailscale up` prints a login URL into driver.log for you to approve.
- `CF_API_TOKEN_FILE` + `CF_ZONE` — Cloudflare tunnel step (token: Cloudflare Tunnel Edit + Zone DNS Edit). Either missing → skipped.
- `UBUNTU_USER` — desktop VM user (default `admin`)
- `TIMEZONE` — host, containers and Ubuntu VM (default `Asia/Riyadh`)
- `WORK_DIR` — where logs go (default `~/site-kit-work`)
- `NOTIFY_CMD` — optional command run at the end as `$NOTIFY_CMD <NAME> <logdir>`

Secrets never live in this repo. The generated Ubuntu password is stored on the host in `/root/<NAME>-secrets/` (mode 600).

## Left to do by hand
- Home Assistant: create the owner account (trusted proxy is set automatically).
- Ubuntu: set your own password — `qm guest passwd 103 <UBUNTU_USER>` on the host.
- BIOS: "power on after AC loss" = ON, so the box comes back after a power cut.
- Frigate: add cameras (camera passwords via `{FRIGATE_RTSP_PASSWORD}` env substitution only).

## Gotchas (learned on real boxes)
- **IPv6 is disabled** in containers, HA and Ubuntu: some site routers hand out broken IPv6, which made image and apt pulls crawl.
- **Container DNS = site router + 1.1.1.1.** Tailscale's MagicDNS address 100.100.100.100 is not reachable from the
  containers, and a container pointing at it breaks cloudflared.
- **HAOS keeps http / trusted-proxy settings in `.storage/http`.** A YAML `http:` block is ignored, so the kit edits that
  file with a clean `ha core stop` → edit → `ha core start` (backup kept).
- **cloud-init is disabled after the Ubuntu VM's first boot**; otherwise it re-runs and resets the user.
- **Share only HA's IP over Tailscale, as a /32** — never the whole site LAN.
- **Versions are pinned** (Frigate 0.17.2, HAOS 18.4, Ubuntu 24.04, Debian 13). Upgrade on purpose, not by accident.
- **Frigate runs with auth off.** Never publish ports 5000/8971 raw; reach it over the LAN or Tailscale only.
- The host's `/etc/hosts` entry must match its real IP (pve-cluster relies on it); both scripts fix it.

## site-kit.sh internals
- Questions are saved to `/root/site-kit.answers` (no secrets) and reused on a re-run; delete it to be asked again.
  Any answer can be given ahead as an environment variable with the same name (`SITE`, `TIMEZONE`, `NET_MODE`=keep|static,
  `HOST_CIDR`, `HOST_GW`, `HOST_DNS`, `P_FRIGATE`, `P_HA`, `P_UBUNTU`, `UBUNTU_USER`, `P_CF`, `CF_TOKEN`, `P_TS`,
  `TS_TAGS` (default `tag:client`, `none` = no tag; if the tailnet refuses the tag the box joins untagged), `TS_WAIT_MIN` default 10, `LOCK_STATIC`), plus `SK_YES=1` to skip the confirm.
- The work runs detached (`setsid`), so a dropped SSH session doesn't stop it; the window just follows `/root/site-kit.log`.
- Order: host basics + containers → Tailscale (approval link, waits up to `TS_WAIT_MIN`) → Frigate → HA → Ubuntu →
  Cloudflare connector → HA trusted proxy (+ HA /32 route on Tailscale) → static guest IPs → host IP (last, it can drop the session) → checks.
- Frigate detector: Intel iGPU → OpenVINO on the GPU + VAAPI; AMD iGPU → OpenVINO on the CPU + VAAPI; no GPU → OpenVINO on the CPU, software decode.
- Cloudflare: you paste a tunnel token (dashboard → Zero Trust → Networks → Tunnels); public hostnames are set in the dashboard.
  The token only lives in CT 105 `/etc/cloudflared/token` (600).
- Host static IP: the old `/etc/network/interfaces` is kept as `/root/interfaces.before-site-kit.<time>`; roll back with
  `cp` + `ifreload -a` from the console. Guests are locked to the address they got from DHCP, on the same LAN.
- `site-kit.sh --check` re-runs only the checks.

## Layout
- `site-kit.sh` — the one command, runs ON the Proxmox host (downloads the kit to `/root/proxmox-site-kit`)
- `site-kit-prep.sh` — the old remote build driver (deprecated; runs from your machine over SSH)
- `site-kit-relocate.sh` — the re-home driver
- `steps/` — scripts run on the host: `host`, `frigate`, `ha`, `ubuntu` (templated with `__N__` box name, `__n__` lowercase,
  `__U__` Ubuntu user, `__TZ__` timezone), plus `static` and `ha_proxy`

## License
MIT — see LICENSE.
