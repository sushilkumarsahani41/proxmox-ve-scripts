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
  `dpkg --print-architecture`, so arm64 hosts work.
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
# AdGuard Home, DHCP address, all defaults
bash <(curl -fsSL https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/ct-lxc/adguardhome-lxc.sh)
```

Or download it once, which makes the management commands nicer to use:

```bash
curl -fsSL https://raw.githubusercontent.com/sushilkumarsahani41/proxmox-ve-scripts/main/ct-lxc/adguardhome-lxc.sh -o adguardhome-lxc.sh
chmod +x adguardhome-lxc.sh

./adguardhome-lxc.sh create --static 192.168.1.53/24 --gateway 192.168.1.1
./adguardhome-lxc.sh status 101
./adguardhome-lxc.sh update 101
./adguardhome-lxc.sh uninstall 101 --purge
```

Every script takes `--help`.

## Available scripts

### LXC containers — [`ct-lxc/`](ct-lxc/)

| Service | Script | Notes |
|---|---|---|
| AdGuard Home | [`adguardhome-lxc.sh`](ct-lxc/adguardhome-lxc.sh) | Network-wide DNS ad blocking. `--channel release\|beta\|edge`. Use `--static` — every client will point at this IP. |

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
| `-s, --storage <name>` | `local-lvm` | Storage for the rootfs |
| `-t, --template-storage <name>` | `local` | Where CT templates live |
| `-b, --bridge <name>` | `vmbr0` | Network bridge |
| `-d, --disk <GB>` | per service | Disk size |
| `-c, --cores <n>` | per service | CPU cores |
| `-m, --memory <MB>` | per service | RAM |
| `--static <cidr>` | dhcp | Static IP, e.g. `192.168.1.53/24` |
| `--gateway <ip>` | — | Required with `--static` |
| `--template <spec>` | auto | Bypass template detection entirely |

`--template` is the escape hatch for hosts whose `pveam available` list is
broken or incomplete (common on some ARM/Pi Proxmox builds). Pass a template
you already have: `--template local:vztmpl/debian-12-standard_12.7-1_arm64.tar.zst`

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
