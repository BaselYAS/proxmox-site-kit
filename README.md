# proxmox-site-kit

One command, pasted on a fresh **Proxmox VE 9** box, turns it into a ready site box: an NVR (Frigate), Home Assistant,
remote access (Tailscale), and optionally an Ubuntu desktop and a Cloudflare tunnel.

**Status: beta.** Read the script before you run it on a box you care about.

## What you get
- CT 101 `<NAME>-Frigate` — Frigate 0.17.2 NVR (Docker). Intel/AMD iGPU used when there is one, OpenVINO detector
- VM 102 `<NAME>-HA` — Home Assistant OS 18.4 (web UI on port 80, or 8123 on older HA; the checks print the right link)
- VM 103 `<NAME>-Ubuntu` — Ubuntu 24.04 desktop (optional)
- CT 105 `<NAME>-Cloudflare` — Cloudflare tunnel connector (optional)
- Host: no-subscription repos, full upgrade, timezone + NTP, smartmontools, subscription nag off, Tailscale
- Static IPs for the host (if you want) and the guests — no DHCP reservations needed

## The command
On the box, as root (Proxmox web UI → the node → **Shell**, or SSH):

    bash <(curl -fsSL https://raw.githubusercontent.com/BaselYAS/proxmox-site-kit/main/site-kit.sh)

## What it asks (Enter = default)
- Site / box name · timezone (`Asia/Riyadh`)
- Host IP: keep, static (IP/prefix, gateway, DNS), or dhcp (bench prep only: at the branch run the relocate command below)
- Frigate [y] · Home Assistant [y] · Ubuntu desktop [n] · Cloudflare tunnel [n] (then the tunnel token) · Tailscale [y]
- Lock the guests to static IPs [y]

Then it shows a summary, asks "Go?", and runs (~20-40 min). You can close the window: it keeps going.
Watch for the **Tailscale approval link**, open it and log in. Log: `/root/site-kit.log`.
Safe to re-run: anything that already exists is skipped.

## After it finishes
It checks each part (Frigate API, HA port, Tailscale IP, free CPU/RAM) and prints what's left by hand:
- Home Assistant: create the owner account
- BIOS: "power on after AC loss" = On
- Frigate: add the cameras
- Tailscale: ask your network admin for this box's access rule; approve the HA route if asked

Then it offers to run the **pw-detect installer**: paste the command from the hub (**Add site → copy**), or skip and paste it later.
Re-check any time: `bash /root/proxmox-site-kit/site-kit.sh --check`

## Moving a box to its branch
Prepared it at the office on DHCP? Plug it into the branch LAN, open its Shell (find it via Tailscale or the router's
DHCP list) and run:

    bash <(curl -fsSL https://raw.githubusercontent.com/BaselYAS/proxmox-site-kit/main/site-kit-relocate.sh)

It asks: host IP (keep what it has now, or a static IP you give: checked free first), lock guests static [y],
container DNS = gateway + 1.1.1.1 [y], HA trusted proxy [y], pw-detect → Frigate's new IP + relays [y if installed],
HA over Tailscale [n], Cloudflare hostnames [n]. Summary, Go. The host IP is changed last and comes back by itself if
the box can't reach its gateway within 60 s. It ends with checks and the new address. Safe to re-run.

## More
Details, gotchas, the internals and the older remote style (`site-kit-prep.sh`, deprecated) and `site-kit-relocate.sh`:
[docs/DETAILS.md](docs/DETAILS.md).

## License
MIT — see LICENSE.
