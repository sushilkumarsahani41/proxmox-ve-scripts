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
— container ID, hostname, storage pool (only pools this host actually has),
disk size, cores, memory, network bridge, and static-IP/gateway if you want
one — with Enter accepting the default and a plan shown before anything is
touched:

```
  Container ID [100]:
  Hostname [adguardhome]:
  Storage pool [local-lvm]:

    1) local-lvm  (recommended)
    2) local-zfs
  Storage pool: 2
  Disk size (GB) [4]:
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
| AdGuard Home | [`adguard-home-lxc.sh`](ct-lxc/adguard-home-lxc.sh) | Network-wide DNS ad blocking. `--channel release\|beta\|edge`. Use `--static` — every client will point at this IP. |

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
| `-s, --storage <name>` | auto-detected | Storage for the rootfs |
| `-t, --template-storage <name>` | auto-detected | Where CT templates live |
| `-b, --bridge <name>` | `vmbr0` | Network bridge |
| `-d, --disk <GB>` | per service | Disk size |
| `-c, --cores <n>` | per service | CPU cores |
| `-m, --memory <MB>` | per service | RAM |
| `--static <cidr>` | dhcp | Static IP, e.g. `192.168.1.53/24` |
| `--gateway <ip>` | — | Required with `--static` |
| `--template <spec>` | auto | Bypass template detection entirely |

`--template` is the escape hatch if detection still picks wrong. Pass a
template you already have:
`--template local:vztmpl/debian-13-standard_13.6-1_arm64.tar.zst`

## Tested on

`ct-lxc/adguard-home-lxc.sh` was verified end-to-end — create, status, update,
uninstall, uninstall --purge, and the failure paths — on:

| | |
|---|---|
| Host | Raspberry Pi 5, Proxmox VE 9.0.10, arm64 |
| Storage | single `local` dir storage (no `local-lvm`) |
| Template | `debian-13-standard_13.6-1_arm64` |
| Networking | both DHCP and `--static` |

That host has a broken appliance mirror, which is how the cached-template
fallback earned its place.

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
