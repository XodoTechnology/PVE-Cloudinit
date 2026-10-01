#!/usr/bin/env bash
#
# Proxmox cloud-image template builder.
#
# Usage:
#   ./build.sh list                          show all defined images + VMIDs
#   ./build.sh <key> [key ...]               build specific template(s)
#   ./build.sh all                           build every template
#   ./build.sh <key> --refresh               force re-download of the source image
#   ./build.sh <key> --storage X --base-vmid N   skip the prompts
#   ./build.sh <key> --dry-run               print the qm commands, change nothing
#   ./build.sh <key> --force                 allow replacing a non-template VMID
#   ./build.sh <key> --sshkeys FILE          bake an SSH public-key file in
#   ./build.sh all --jobs 4                  build up to 4 templates in parallel
#
# VMIDs are base + offset; each OS family owns a block of 10
# (ubuntu=+0x, centos=+1x, rocky=+2x, debian=+3x, almalinux=+4x, fedora=+5x,
#  arch=+6x, opensuse=+7x, alpine=+8x, freebsd=+9x, kali=+10x, openwrt=+11x).
#
# Image definitions live in images.conf (see comments there for the format).
# Per-distro directories contain thin wrappers that call this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG="$SCRIPT_DIR/images.conf"
CACHE_DIR=/var/lib/vz/template/cache
SNIPPET_NAME=base-cloudinit-user.yml

# --- global defaults (prompted at build time; env/flags/images.conf win) -----
RAM=512
CORES=1
BRIDGE=vmbr0
DISKIMAGE_SIZE=10G
STORAGE=${PVE_STORAGE:-local}
BASE_VMID=${BASE_VMID:-9000}
DNS=9.9.9.9
CIUSER=root
OSTYPE=l26
CPUTYPE=host
SSHKEYS=${SSHKEYS:-}

REFRESH=0
DRYRUN=0
FORCE=0
JOBS=1
PARTIAL=""        # VMID of a half-built VM, cleaned up by the EXIT trap
BUILT_FILE=$(mktemp)

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# run <cmd...> — execute, or echo when dry-running
run() { if (( DRYRUN )); then echo "  + $*"; else "$@"; fi }

cleanup() {
    [[ -z $PARTIAL ]] && return 0
    echo "!! build failed — removing partial VM $PARTIAL" >&2
    (( DRYRUN )) || sudo qm destroy "$PARTIAL" --destroy-unreferenced-disks 1 --purge 1 || true
}
trap cleanup EXIT

has_flag() { [[ ",${FLAGS}," == *",$1,"* ]]; }

#-----------------------------------------------------------------------------
load_entry() {
    local want=$1 line
    while IFS='|' read -r KEY OFFSET TEMPLATE_NAME URL TAGS FLAGS PATTERN; do
        [[ -z ${KEY:-} || $KEY == \#* ]] && continue
        [[ $KEY == "$want" ]] || continue
        VMID=$(( BASE_VMID + 10#$OFFSET ))

        # per-image overrides from flags like storage=X / bridge=X / ram=X ...
        local f
        IFS=',' read -ra _fl <<< "${FLAGS:-}"
        for f in "${_fl[@]:-}"; do
            case $f in
                storage=*)  STORAGE=${f#storage=} ;;
                bridge=*)   BRIDGE=${f#bridge=} ;;
                ram=*)      RAM=${f#ram=} ;;
                cores=*)    CORES=${f#cores=} ;;
                disksize=*) DISKIMAGE_SIZE=${f#disksize=} ;;
                ostype=*)   OSTYPE=${f#ostype=} ;;
                cputype=*)  CPUTYPE=${f#cputype=} ;;
            esac
        done

        # {VER} token -> latest upstream release (used by OpenWrt)
        if [[ $URL == *'{VER}'* || $TEMPLATE_NAME == *'{VER}'* ]]; then
            local ver
            ver=$(curl -sf "https://api.github.com/repos/openwrt/openwrt/releases/latest" \
                  | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/') \
                  || die "could not resolve latest OpenWrt release"
            URL=${URL//\{VER\}/$ver}
            TEMPLATE_NAME=${TEMPLATE_NAME//\{VER\}/$ver}
            TAGS=${TAGS//\{VER\}/$ver}
            info "Resolved {VER} -> $ver"
        fi

        # index flag -> scrape the directory listing for the newest matching file
        if has_flag index; then
            local file
            file=$(curl -sfL "$URL" | grep -oE "$PATTERN" | sort -Vu | tail -1) \
                  || die "no file matching '$PATTERN' found in $URL"
            [[ -n $file ]] || die "no file matching '$PATTERN' found in $URL"
            URL="${URL%/}/$file"
            info "Resolved index -> $file"
        fi

        local raw_name final_name
        raw_name=$(basename "$URL")
        final_name=$raw_name
        final_name=${final_name%.tar.xz}
        final_name=${final_name%.gz}
        final_name=${final_name%.xz}
        has_flag tarxz && final_name+=.qcow2

        RAW_NAME=$raw_name
        IMAGE_PATH="$CACHE_DIR/$final_name"
        return 0
    done < "$CONFIG"
    return 1
}

#-----------------------------------------------------------------------------
# Returns 0 if the cached image is missing or older than the remote file.
image_is_stale() {
    [[ ! -f $IMAGE_PATH ]] && return 0
    local lm epoch local_epoch
    lm=$(curl -sfIL "$URL" | awk 'BEGIN{IGNORECASE=1} /^last-modified:/{sub(/\r$/,""); print substr($0, index($0,":")+2)}' | tail -1 || true)
    [[ -z $lm ]] && return 1   # can't tell -> assume fresh
    epoch=$(date -d "$lm" +%s 2>/dev/null) || return 1
    local_epoch=$(stat -c %Y "$IMAGE_PATH")
    (( epoch > local_epoch ))
}

download_image() {
    local dl="$IMAGE_PATH.dl"
    info "Downloading $URL"
    sudo wget -q --show-progress -O "$dl" "$URL"
    if has_flag gz; then
        sudo gunzip -c "$dl" | sudo tee "$IMAGE_PATH" >/dev/null
    elif has_flag xz; then
        sudo xz -dc "$dl" | sudo tee "$IMAGE_PATH" >/dev/null
    elif has_flag tarxz; then
        local tmp
        tmp=$(mktemp -d)
        sudo tar -xJf "$dl" -C "$tmp"
        sudo mv "$(sudo find "$tmp" -name '*.qcow2' | head -1)" "$IMAGE_PATH"
        sudo rm -rf "$tmp"
    else
        sudo mv "$dl" "$IMAGE_PATH"
    fi
    sudo rm -f "$dl" "$IMAGE_PATH.customized"
    sudo qemu-img resize "$IMAGE_PATH" "$DISKIMAGE_SIZE"
    info "Cached image: $(sudo qemu-img info "$IMAGE_PATH" | grep -E 'file format|virtual size')"
}

# Best-effort sha256 check against SHA256SUMS / CHECKSUM files next to the image.
verify_checksum() {
    local dir=${URL%/*} sums hash actual
    for f in SHA256SUMS CHECKSUM; do
        sums=$(curl -sfL "$dir/$f" 2>/dev/null | grep -F "$RAW_NAME") && break || sums=""
    done
    hash=$(grep -oE '[0-9a-f]{64}' <<< "${sums:-}" | head -1 || true)
    if [[ -z $hash ]]; then
        echo "    (no checksum found for $RAW_NAME — skipping verification)"
        return 0
    fi
    actual=$(sudo sha256sum "$IMAGE_PATH" | awk '{print $1}')
    [[ $actual == "$hash" ]] || die "checksum mismatch for $RAW_NAME"
    info "Checksum OK"
}

customize_image() {
    has_flag no-customize && return 0
    [[ -f $IMAGE_PATH.customized ]] && { echo "    image already customized, skipping"; return 0; }
    local sedexpr="-e s/^#?[[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin\ yes/ -e s/^#?[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication\ yes/"
    info "Customizing image (qemu-guest-agent + sshd settings)"
    sudo virt-customize -a "$IMAGE_PATH" \
        --install qemu-guest-agent \
        --run-command "sed -i -E $sedexpr /etc/ssh/sshd_config 2>/dev/null || true" \
        --run-command "sed -i -E $sedexpr /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true" \
        --run-command "systemctl enable qemu-guest-agent 2>/dev/null || true"
    sudo touch "$IMAGE_PATH.customized"
}

#-----------------------------------------------------------------------------
# Ensure a shared cloud-init user-data snippet exists; prints its volume ref.
ensure_snippet() {
    local sinfo sdir
    sinfo=$(sudo pvesh get "/storage/$STORAGE" --output-format json 2>/dev/null) || return 1
    if ! grep -q snippets <<< "$sinfo"; then
        local cur
        cur=$(grep -oE '"content"[^,}]*' <<< "$sinfo" | cut -d'"' -f4)
        echo "    (snippets not enabled on '$STORAGE'; enable with:" \
             "pvesm set $STORAGE --content ${cur:-iso,vztmpl,backup},snippets)" >&2
        return 1
    fi
    sdir=$(grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$sinfo" | cut -d'"' -f4)
    [[ -n ${sdir:-} ]] || return 1
    sudo mkdir -p "$sdir/snippets"
    sudo tee "$sdir/snippets/$SNIPPET_NAME" >/dev/null <<'EOF'
#cloud-config
ssh_pwauth: true
disable_root: false
EOF
    echo "$STORAGE:snippets/$SNIPPET_NAME"
}

build_template() {
    local key=$1
    RAM=512; CORES=1; BRIDGE=vmbr0; DISKIMAGE_SIZE=10G
    DNS=9.9.9.9; CIUSER=root; OSTYPE=l26; CPUTYPE=host

    load_entry "$key" || die "no entry for '$key' in $CONFIG"

    info "[$key] building $TEMPLATE_NAME (VMID $VMID)"
    echo "    image: $URL"

    # don't let the rebuild nuke a VM that isn't the expected template
    if sudo qm status "$VMID" &>/dev/null; then
        local existing
        existing=$(sudo qm config "$VMID" 2>/dev/null || true)
        if grep -q '^template: 1' <<< "$existing" && (( ! FORCE )); then
            info "Replacing existing template on VMID $VMID"
        elif (( FORCE )); then
            echo "    WARNING: --force: destroying non-template VM $VMID"
        else
            die "VMID $VMID is used by a non-template VM — refusing to destroy (use --force)"
        fi
        run sudo qm stop "$VMID" 2>/dev/null || true
        run sudo qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1
    fi

    ip link show "$BRIDGE" &>/dev/null \
        || echo "    WARNING: bridge '$BRIDGE' does not exist on this host"

    if (( DRYRUN )); then
        echo "  + download: $URL -> $IMAGE_PATH (resize $DISKIMAGE_SIZE)"
        has_flag no-customize || echo "  + virt-customize -a $IMAGE_PATH --install qemu-guest-agent ..."
    else
        if [[ $REFRESH == 1 ]] || image_is_stale; then
            download_image
            verify_checksum
        else
            info "Cached image is up to date ($IMAGE_PATH)"
        fi
        customize_image
    fi

    info "Creating VM $VMID"
    run sudo qm create "$VMID" --name "$TEMPLATE_NAME" --net0 "virtio,bridge=$BRIDGE" --memory "$RAM"
    PARTIAL=$VMID
    if has_flag bios; then
        run sudo qm set "$VMID" --machine q35 --bios seabios
    else
        run sudo qm set "$VMID" --machine q35 --bios ovmf --efidisk0 "$STORAGE:0,pre-enrolled-keys=0"
    fi
    run sudo qm set "$VMID" --numa 1 --ostype "$OSTYPE" --cores "$CORES" --cpu "cputype=$CPUTYPE"
    run sudo qm set "$VMID" --scsihw virtio-scsi-single

    info "Importing disk"
    local vol
    if (( DRYRUN )); then
        echo "  + sudo qm importdisk $VMID $IMAGE_PATH $STORAGE"
        vol="$STORAGE:vm-$VMID-disk-0"
    else
        vol=$(sudo qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE" \
            | sed -n "s/.*'\(unused[0-9]*:[^']*\)'.*/\1/p" | cut -d: -f2-)
        [[ -n $vol ]] || die "could not determine imported volume name"
    fi
    run sudo qm set "$VMID" --scsi0 "$vol,aio=io_uring,discard=on,iothread=1,ssd=1"

    run sudo qm set "$VMID" --boot order=scsi0 --tablet 0 --serial0 socket --vga serial0
    has_flag no-agent || run sudo qm set "$VMID" --agent enabled=1,fstrim_cloned_disks=1
    run sudo qm set "$VMID" --tags "$TAGS;built_$(date +%m_%Y)" \
        --description "Built $(date +%Y-%m-%d) from $URL"
    run sudo qm set "$VMID" --onboot 1

    if ! has_flag no-cloudinit; then
        local ci_args=(--ide2 "$STORAGE:cloudinit" --ciuser "$CIUSER" --ciupgrade 1
                       --ipconfig0 ip=dhcp,ip6=auto --nameserver "$DNS")
        [[ -n $SSHKEYS ]] && ci_args+=(--sshkeys "$SSHKEYS")
        run sudo qm set "$VMID" "${ci_args[@]}"
        local snippet
        if snippet=$(ensure_snippet); then
            run sudo qm set "$VMID" --cicustom "user=$snippet"
        fi
    fi

    run sudo qm template "$VMID"
    PARTIAL=""
    echo "$VMID  $TEMPLATE_NAME" >> "$BUILT_FILE"
    info "$TEMPLATE_NAME complete (VMID $VMID)"
}

#-----------------------------------------------------------------------------
[[ -f $CONFIG ]] || die "missing $CONFIG"

mapfile -t ALL_KEYS < <(awk -F'|' '!/^[[:space:]]*(#|$)/{print $1}' "$CONFIG")

usage() {
    cat <<EOF
usage: $0 list | all | <key> [key ...] [options]

options:
  --refresh          force re-download of the source image(s)
  --dry-run          print the qm commands without changing anything
  --force            allow replacing a VMID that is NOT a template
  --storage NAME     target storage (default: $STORAGE, env: PVE_STORAGE)
  --base-vmid N      first template VMID block (default: $BASE_VMID, env: BASE_VMID)
  --sshkeys FILE     bake an SSH public-key file into every template
                     (env: SSHKEYS)
  --jobs N           build up to N templates in parallel (default: 1)

available keys: ${ALL_KEYS[*]}
EOF
}

list() {
    printf '%-20s %-8s %s\n' KEY VMID NAME
    local key offset name
    while IFS='|' read -r key offset name _; do
        [[ -z ${key:-} || $key == \#* ]] && continue
        printf '%-20s %-8s %s\n' "$key" "$(( BASE_VMID + 10#$offset ))" "$name"
    done < "$CONFIG"
}

[[ $# -lt 1 ]] && { usage; exit 1; }

keys=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --refresh)    REFRESH=1 ;;
        --dry-run)    DRYRUN=1 ;;
        --force)      FORCE=1 ;;
        --storage)    STORAGE=$2; shift ;;
        --base-vmid)  BASE_VMID=$2; shift ;;
        --sshkeys)    SSHKEYS=$2; shift ;;
        --jobs)       JOBS=$2; shift ;;
        list)         list; exit 0 ;;
        all)          keys=("${ALL_KEYS[@]}") ;;
        -h|--help)    usage; exit 0 ;;
        *)            keys+=("$1") ;;
    esac
    shift
done

preflight() {
    # catch config mistakes before we start destroying/building anything
    local dup
    dup=$(awk -F'|' '!/^[[:space:]]*(#|$)/{
            if (seen[$1]++) printf "duplicate key: %s\n", $1;
            if (off[$2]++)  printf "duplicate offset: %s\n", $2;
        }' "$CONFIG")
    [[ -z $dup ]] || die "images.conf errors:"$'\n'"$dup"

    (( DRYRUN )) && return 0
    local c
    for c in qm virt-customize qemu-img wget curl pvesh; do
        command -v "$c" >/dev/null || die "missing command: $c (run this on the PVE host)"
    done
    sudo mkdir -p "$CACHE_DIR"
    sudo pvesm status &>/dev/null || die "pvesm failed — is this a Proxmox host?"
}
preflight

# Ask for storage + base VMID (skipped when non-interactive or fully overridden)
if [[ -t 0 ]]; then
    read -rp "Target storage [$STORAGE]: " _ans
    [[ -n ${_ans:-} ]] && STORAGE=$_ans
    read -rp "Base template VMID [$BASE_VMID]: " _ans
    [[ -n ${_ans:-} ]] && BASE_VMID=$_ans

    # offer to bake in an SSH key if we can find one
    if [[ -z $SSHKEYS ]]; then
        for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/authorized_keys; do
            [[ -f $f ]] || continue
            read -rp "Bake SSH key $f into templates? [Y/n] " _ans
            if [[ -z ${_ans:-} || $_ans =~ ^[Yy] ]]; then SSHKEYS=$f; fi
            break
        done
    fi
fi
[[ $BASE_VMID =~ ^[0-9]+$ ]] || die "base VMID must be numeric"
[[ -z $SSHKEYS || -f $SSHKEYS ]] || die "sshkeys file not found: $SSHKEYS"
info "storage=$STORAGE base-vmid=$BASE_VMID${SSHKEYS:+ sshkeys=$SSHKEYS}"

[[ $JOBS =~ ^[0-9]+$ && $JOBS -ge 1 ]] || die "--jobs must be a positive integer"

# Each build runs in a subshell so one failure doesn't kill the rest and the
# EXIT trap (which is NOT inherited by & subshells) gets re-armed per worker.
declare -a FAILED=()
if (( JOBS > 1 )); then
    LOGDIR=$(mktemp -d)
    declare -A PIDMAP=()
    for k in "${keys[@]}"; do
        ( trap cleanup EXIT; build_template "$k" ) &>"$LOGDIR/$k.log" &
        PIDMAP[$!]=$k
        while (( $(jobs -rp | wc -l) >= JOBS )); do sleep 0.5; done
    done
    for p in "${!PIDMAP[@]}"; do
        wait "$p" || FAILED+=("${PIDMAP[$p]}")
    done
    for k in "${keys[@]}"; do cat "$LOGDIR/$k.log"; done
else
    for k in "${keys[@]}"; do
        ( trap cleanup EXIT; build_template "$k" ) || FAILED+=("$k")
    done
fi

if [[ -s $BUILT_FILE ]]; then
    info "summary"
    sort -n "$BUILT_FILE" | sed 's/^/    /'
fi
if (( ${#FAILED[@]} )); then
    echo "FAILED: ${FAILED[*]}" >&2
    exit 1
fi
