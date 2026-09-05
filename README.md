# Proxmox VE Scripts

Single-file scripts that stand up a service on Proxmox VE — and then keep
managing it. Run one command on your PVE host, get a working container.

> A hobby project by [GreatShark Technologies](https://github.com/sushilkumarsahani41).
> Built because I live in Proxmox anyway and got tired of doing the same
> twenty minutes of container setup by hand.

## What makes these different

Most Proxmox helper scripts install and walk away. These cover the whole life
of the thing:

| | |
|---|---|
| `create` | Build the LXC and install the service |
| `update` | Back up config/data, upgrade, verify it came back, **roll back automatically if it didn't** |
| `status` | Version, service state, listening ports |
| `uninstall` | Remove cleanly (`--purge` also wipes data) |

Other things they try to get right:

- **Your architecture, not just amd64.** Templates are resolved against
  `dpkg --print-architecture`, so arm64 hosts work. Developed against a
  Raspberry Pi 5 running PVE 9.
- **Your storage, whatever it's called.** `local-lvm` on a stock install,
  `local-zfs` on ZFS, plain `local` on the Pi image — detected, not assumed.
- **Your templates, whatever's on the mirror.** Any Debian major version is
  accepted, newest wins, and a template already cached on the host is used as-is
  — so a broken or unreachable appliance mirror stops being fatal.
- **No reimplemented vendor logic.** Where upstream ships an installer, these
  call it. Hardcoding `..._linux_amd64.tar.gz` is how "amd64 only" bugs are
  born.
- **Nothing swallowed.** Steps run behind a spinner, but any failure dumps the
  full captured output before exiting.
- **One file.** No library to fetch at runtime, nothing to keep in sync. If it
  works once, it works offline forever.

## Usage

Run on the **Proxmox VE host**, as root.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/install.sh)
```

That's the only URL worth remembering — it lists everything available and lets
you pick. On a real terminal with nothing else specified, `create` then walks
through each setting one at a time, showing the recommended value in brackets
— container ID, hostname, **operating system** (if the service offers more
than one), storage pool (only pools this host actually has), disk size,
cores, memory, network bridge, and static-IP/gateway if you want one — with
Enter accepting the default and a plan shown before anything is touched:

```
  Container ID [100]:
  Hostname [adguardhome]:

    1) debian    Debian 13  (recommended)
    2) alpine    Alpine 3.24
  Operating system [debian]: 2
  Storage pool [local-lvm]:

    1) local-lvm  (recommended)
    2) local-zfs
  Storage pool: 2
  Disk size (GB) [2]:
  ...

+-----------------------------------------------------------------+
| AdGuard Home - about to create                                  |
|                                                                  |
| Container ID  : 100                                             |
| Storage pool  : local-zfs                                       |
| Disk size     : 4 GB                                            |
...
| Create with these settings? [Y/n]:
```

A root password is always set — auto-generated and shown once in the closing
box if you don't provide `--password`, since it's otherwise unset entirely and
console/SSH password login won't work. `pct enter <ctid>` from the Proxmox host
always works with no password needed, if you'd rather skip this altogether.

Pass any option at all — or `-y`/`--defaults` — and it skips every question and
runs straight through, so a scripted or piped invocation never blocks waiting
on a terminal that isn't there:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/install.sh) \
  adguard-home --static 192.168.1.53/24 --gateway 192.168.1.1

bash <(curl -fsSL https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/install.sh) \
  adguard-home -y
```

Service names are hyphenated (`adguard-home`). Older joined names
(`adguardhome`) still resolve, so links handed out before a rename keep working.

Each script is also reachable on its own, if you'd rather be explicit:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/ct-lxc/adguard-home-lxc.sh)
```

For the management commands, download it once — then `update` and `status` are
just a local command instead of a URL:

```bash
curl -fsSL https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/ct-lxc/adguard-home-lxc.sh -o adguard-home-lxc.sh
chmod +x adguardhome-lxc.sh

./adguard-home-lxc.sh create --static 192.168.1.53/24 --gateway 192.168.1.1
./adguard-home-lxc.sh status 101
./adguard-home-lxc.sh update 101
./adguard-home-lxc.sh uninstall 101 --purge
```

Every script takes `--help`.

## Available scripts

### LXC containers — [`ct-lxc/`](ct-lxc/)

| Service | Script | Notes |
|---|---|---|
| AdGuard Home | [`adguard-home-lxc.sh`](ct-lxc/adguard-home-lxc.sh) | Network-wide DNS ad blocking. `--channel release\|beta\|edge`. `--os debian\|alpine`. Use `--static` — every client will point at this IP. |
| Pi-hole | [`pi-hole-lxc.sh`](ct-lxc/pi-hole-lxc.sh) | Network-wide DNS ad blocking. `--upstream cloudflare\|google\|quad9\|opendns`. `--os debian\|alpine`. Sets its own admin web password too (`--webpassword`, separate from the container root password) — auto-generated and shown once, same as root. Use `--static`. |
| Floci | [`floci-lxc.sh`](ct-lxc/floci-lxc.sh) | Free local AWS/Azure/GCP emulator ([floci-io/floci](https://github.com/floci-io/floci)) + its web console. `--platform aws\|azure\|gcp`. Installs Docker inside the container — see [Floci: Docker-in-LXC](#floci-docker-in-lxc) below before using this one. Debian only, 20GB disk default. |
| SharkShell | [`sharkshell-lxc.sh`](ct-lxc/sharkshell-lxc.sh) | Self-hosted web SSH client with an encrypted keystore, TOTP 2FA, and a built-in MCP server ([sushilkumarsahani41/SharkShell](https://github.com/sushilkumarsahani41/SharkShell)). No Docker — Node.js, nginx, and PostgreSQL built directly on the container via SharkShell's own `deploy.sh`. Debian only, 6GB disk default. First-run admin setup happens through the web UI, not a flag. |

### Virtual machines — [`vm/`](vm/)

Nothing here yet.

### Misc — [`misc/`](misc/)

Nothing here yet.

## Common options

Every `create` accepts these:

| Option | Default | |
|---|---|---|
| `-i, --id <id>` | next free | Container ID |
| `-n, --hostname <name>` | per service | Container hostname |
| `--os <name>` | per service | Guest OS, if the service offers more than one — see its own table row |
| `-s, --storage <name>` | auto-detected | Storage for the rootfs |
| `-t, --template-storage <name>` | auto-detected | Where CT templates live |
| `-b, --bridge <name>` | `vmbr0` | Network bridge |
| `-d, --disk <GB>` | per service | Disk size |
| `-c, --cores <n>` | per service | CPU cores |
| `-m, --memory <MB>` | per service | RAM |
| `--static <cidr>` | dhcp | Static IP, e.g. `192.168.1.53/24` |
| `--gateway <ip>` | — | Required with `--static` |
| `--password <pass>` | random | Container root password (min 8 chars). Shown once after creation if not set. A service may have its own separate app-level password too — see its own row above. |
| `--template <spec>` | auto | Bypass template detection entirely |
| `-y, --defaults` | — | Skip the wizard, use recommended values |

`--template` is the escape hatch if detection still picks wrong. Pass a
template you already have:
`--template local:vztmpl/debian-13-standard_13.6-1_arm64.tar.zst`

## Multiple guest OSes

A service can offer a choice of base OS instead of only Debian. Both AdGuard
Home and Pi-hole offer both:

| OS | Why you'd pick it |
|---|---|
| Debian 13 (default) | Longest track record in this project; `apt` if you ever need to exec in and debug |
| Alpine 3.24 | Smaller footprint, faster boot; musl + OpenRC instead of glibc + systemd |

This works because both services' own installers register themselves with
whatever init system they find and expose identical control commands either
way (AdGuard Home: `-s start|stop|status`; Pi-hole: `pihole status`/`-up`) —
so neither service's `manage.sh` needed OS-specific code. Pi-hole's own
installer supporting Alpine at all (via `apk`, registering under OpenRC) was
a genuine surprise found by reading its source, not assumed from AdGuard's
precedent, and verified the same way: a real throwaway container, not a
guess. That won't be true of every future service; see
`src/ct-lxc/_template/main.sh` for what Alpine support actually requires
before you add it to one.

## Floci: Docker-in-LXC

Floci is a different shape of service from the others here: it's not a
vendor installer this project delegates to, it's a Docker Compose stack
(Floci's chosen cloud emulator + [Floci UI](https://github.com/floci-io/floci-ui),
its official web console). Several of the AWS/Azure/GCP services it emulates
— EC2, RDS, ElastiCache, MSK, EKS, and more — work by spawning further real
Docker containers of their own, so the container this script creates needs
**Docker running inside an LXC container**, which needs both `nesting` and
`keyctl` enabled. This script turns both on for you; it's not a setting you
choose. Verified on a real host before committing to it: Docker install,
`hello-world`, a real `postgres:16-alpine` container with its port reachable
from the Proxmox host itself (not just inside the container) — all worked
cleanly on an unprivileged LXC.

`--platform aws|azure|gcp` picks which cloud to emulate (Floci's own fourth
platform, OCI, isn't offered here — Floci UI has no OCI support yet, checked
directly against its docs rather than assumed). All three were verified
end-to-end through this project's own built script, not just by hand: created
a container, launched a real EC2 instance through the AWS CLI, confirmed it
was backed by a real `amazonlinux` Docker container, then did the same
create/status/update/uninstall cycle for Azure and GCP.

Two real bugs surfaced by that testing, both fixed:

- **Orphaned containers on uninstall.** Floci's own EC2/RDS/etc. containers
  aren't declared in the compose file, so `docker compose down` doesn't know
  about them — one launched during testing was still sitting there, exited,
  after a full uninstall. Every container Floci spawns this way carries a
  `floci=true` Docker label regardless of which service created it (checked
  via `docker inspect`, not assumed), so uninstall now finds and removes them
  by that label, purge or not — they're live emulated infrastructure, not
  data worth preserving.
- **Invalid compose YAML for non-AWS platforms.** The generated compose file
  wrote an `environment:` key with nothing under it for Azure/GCP (only AWS
  needs any env overrides), which Docker Compose rejects outright:
  `services.floci-gcp.environment must be a mapping`. Found by actually
  running the built script against GCP, not by reading the generated file —
  the manual pre-write verification had tested Azure/GCP with a hand-written
  compose file that simply omitted the key, which the generating function
  didn't originally match.

Because this pulls a fresh image every time you use a Docker-backed service
you haven't used before, it needs internet access from the container on an
ongoing basis — unlike AdGuard Home or Pi-hole, this isn't "download once,
run offline."

## SharkShell: a vendor script with real bugs

SharkShell is the one service here where "delegate to the vendor's own
installer" ran into the vendor's installer not actually working. Deploying
it for real (not just reading `deploy.sh`) surfaced seven bugs that meant a
fresh install could not complete on any systemd distro — Debian, Ubuntu,
Fedora, RHEL, Arch — including one, `systemctl reload-or-start nginx`
(not a real systemd verb), that killed the deploy outright before the
service was even installed, and two file-permission bugs (`/etc/sharkshell/env`
and the generated secrets both `root:root mode 600`, while the backend runs
as an unprivileged `sharkshell` user) that crash-looped the backend forever
even past that. Full writeup, and the fix:
[sushilkumarsahani41/SharkShell#6](https://github.com/sushilkumarsahani41/SharkShell/pull/6).

That fix is merged to `main`, but SharkShell's own release-based one-liner
(`curl -fsSL https://sharkshell.in/get | sudo bash`) resolves whatever GitHub
currently calls "latest release" — merging to `main` doesn't reach that path
until a new release is tagged. `manage.sh` here uses SharkShell's *other*
documented deploy method instead — `git clone` then `./deploy.sh` — which
reads `main` directly and sidesteps that entirely. Once a new release ships,
either path resolves to the same fixed code.

There's no `--webpassword`-style flag for this one: SharkShell creates its
admin account through a first-visit web setup screen, not a CLI seed. Open
the URL the summary prints and complete it there.

## Tested on

`ct-lxc/adguard-home-lxc.sh`, `ct-lxc/pi-hole-lxc.sh`, `ct-lxc/floci-lxc.sh`,
and `ct-lxc/sharkshell-lxc.sh` were verified end-to-end — create, status,
update, uninstall, uninstall --purge, and the failure paths — on:

| | |
|---|---|
| Host | Raspberry Pi 5, Proxmox VE 9.0.10, arm64 |
| Storage | single `local` dir storage (no `local-lvm`) |
| Templates | `debian-13-standard_13.6-1_arm64`, `alpine-3.24-default_20260803_arm64` |
| Networking | both DHCP and `--static` |

That host has a broken appliance mirror, which is how the cached-template
fallback earned its place. Its official catalog also carries very few arm64
templates at all — as of writing, exactly two: Debian 13 and Alpine 3.24 —
which is a genuine limit of Proxmox's curated template list, not something a
`pveam` flag unlocks. `pveam available` (no `--section` filter) already
returns everything the mirror has; this project's own `--section system`
filter only excludes irrelevant sections (mail server appliances,
TurnkeyLinux installers), never architectures.

For Pi-hole specifically, the admin web password was checked against the
live Pi-hole v6 REST API (`POST /api/auth`) — not just that `pihole
setpassword` exited 0 — confirming both that the right password authenticates
and a wrong one gets HTTP 401, on both OSes, and that the password survives
`pihole -up`.

## How this repo is built

The scripts in `ct-lxc/`, `vm/` and `misc/` are **generated**. Don't edit them.

```
src/lib/*.sh                     shared Proxmox + UI code
src/ct-lxc/<service>/main.sh     the service: defaults, hooks, help text
src/ct-lxc/<service>/manage.sh   what runs inside the container
        |
        |  ./build.sh
        v
ct-lxc/<service>-lxc.sh          one flat, self-contained script
install.sh                       dispatcher, catalogue baked in at build time
ct-lxc/<old-name>-lxc.sh         shim, if the service was ever renamed
```

Users still get one dependency-free file; bugs in the shared Proxmox logic
still get fixed in one place. See [CONTRIBUTING.md](CONTRIBUTING.md) to add a
script — it's mostly filling in `src/ct-lxc/_template/`.

```bash
./build.sh            # build everything
./build.sh --check    # fail if committed scripts are stale
./tests/smoke.sh      # what can be tested without a PVE host
```

## Warning

These create and delete containers on your Proxmox host. Read the script before
you run it — that's true here and of every `curl | bash` on the internet. Test
on something you don't care about first.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Proxmox Server Solutions
GmbH, or with any of the projects these scripts install.
