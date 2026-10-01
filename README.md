# PVE-Cloudinit

Builds Proxmox VM templates from upstream cloud images on a Proxmox VE host.

One engine (`build.sh`) + one config table (`images.conf`). Each per-distro
directory contains a thin `build.sh` wrapper, so both of these work:

```bash
./build.sh debian-12          # from the repo root
cd debian-12 && ./build.sh    # from a distro directory
```

## Usage

```
./build.sh list                          show all images and their VMIDs
./build.sh <key> [key ...]               build specific template(s)
./build.sh all                           build every template

options:
  --refresh          force re-download of the source image(s)
  --dry-run          print the qm commands without changing anything
  --force            allow replacing a VMID that is NOT a template
  --storage NAME     target storage (default: local, env: PVE_STORAGE)
  --base-vmid N      first template VMID block (default: 9000, env: BASE_VMID)
  --sshkeys FILE     bake an SSH public-key file into every template (env: SSHKEYS)
  --jobs N           build up to N templates in parallel (default: 1)
```

When run interactively it prompts for the target **storage** and **base VMID**,
and offers to bake in a detected SSH public key. Non-interactive runs use the
defaults/env/flags above (no prompts).

## VMID layout

VMID = base + offset. Each OS family owns a block of 10:

| offset block | family                          |
|--------------|---------------------------------|
| +0x          | Ubuntu                          |
| +1x          | CentOS                          |
| +2x          | Rocky                           |
| +3x          | Debian                          |
| +4x          | AlmaLinux                       |
| +5x          | Fedora                          |
| +6x          | Arch                            |
| +7x          | openSUSE                        |
| +8x          | Alpine                          |
| +9x          | FreeBSD                         |
| +10x         | Kali                            |
| +11x         | OpenWrt                         |

With the default base of 9000, `debian-12` (offset 33) becomes VMID 9033.

## What a build does

1. Resolves the image URL (`{VER}` tokens and `index` listings supported).
2. Downloads to `/var/lib/vz/template/cache/` if missing or older than the
   remote `Last-Modified`; decompresses `.gz`/`.xz`/`.tar.xz`; verifies the
   sha256 against upstream `SHA256SUMS`/`CHECKSUM` when available.
3. Resizes the image and runs `virt-customize` once per image
   (qemu-guest-agent + sshd hardening-to-usable: PermitRootLogin/PasswordAuth),
   tracked by a `.customized` stamp file.
4. Creates the VM: q35 + OVMF (SeaBIOS with the `bios` flag), virtio-scsi-single,
   imported disk on scsi0 (`io_uring`, `discard`, `iothread`, `ssd`),
   serial console, guest agent, tags + `built_MM_YYYY`, description with the
   source URL, onboot.
5. Attaches the cloud-init drive: `ciuser=root`, `ciupgrade`, DHCPv4 + SLAAC
   (auto) on `ipconfig0`, DNS, optional `--sshkeys`, and a shared
   `snippets/base-cloudinit-user.yml` (`ssh_pwauth: true`, `disable_root: false`).
6. Converts to a template.

Safety rails: refuses to destroy a VMID that isn't a template (`--force` to
override), aborts on duplicate keys/offsets in `images.conf`, cleans up a
half-built VM if a build dies, and warns if the target bridge doesn't exist.

## images.conf format

```
key|offset|template-name|image-url|tags|flags|pattern
```

- `flags` (comma-separated): `index`, `gz`, `xz`, `tarxz`, `bios`,
  `no-customize`, `no-cloudinit`, `no-agent`, plus per-image overrides
  `storage=X` `bridge=X` `ram=X` `cores=X` `disksize=X` `ostype=X` `cputype=X`
- `pattern`: `grep -E` regex used with `index` to pick the newest file from a
  directory listing (Alpine, Fedora, Kali).
- `{VER}` in url/name/tags resolves to the latest OpenWrt GitHub release.

Adding a distro: pick a free offset in its family block, add one line, done.

## Notes & caveats

- Requires `libguestfs-tools` (`virt-customize`) and snippets enabled on the
  target storage for `--cicustom` (`pvesm set <storage> --content ...,snippets`).
- `centos-7` and `alpine-current` build with SeaBIOS (`bios` flag) — their
  cloud images aren't reliable UEFI booters.
- `freebsd-15.1` uses `nuageinit` (cloud-init subset) and skips virt-customize;
  `ostype=other`. Password SSH isn't configured — use keys.
- `openwrt-current` has no cloud-init or SSH config baked in (OpenWrt uses
  UCI/Dropbear) — it's just the disk image + serial console, on `temp-store`/
  `vmbr201` per its flags.
- Windows can't be built this way — it has no cloud-init. The equivalent is
  Cloudbase-Init (NoCloud datasource works on Proxmox), but the image must be
  built manually: install Windows + virtio drivers + Cloudbase-Init, sysprep,
  then convert to a template.
