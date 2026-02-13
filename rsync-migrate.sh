#!/usr/bin/env bash
set -euo pipefail

# rsync-migrate.sh — Full filesystem clone via rsync
# Run from a LIVE USB with both source and destination disks attached.
# Handles: multiple partitions, LUKS-encrypted /home, usage-based sizing,
# partitioning, rsync, fstab, crypttab, GRUB, and initramfs.

STATE_FILE="/tmp/rsync-migrate-state.sh"
DRY_RUN=false
RESUME=false
EXTRA_EXCLUDES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            echo "*** DRY RUN MODE — no changes will be made ***"
            echo ""
            ;;
        --resume)
            RESUME=true
            ;;
        --exclude=*)
            EXTRA_EXCLUDES+=("${1#--exclude=}")
            ;;
        --exclude)
            shift
            EXTRA_EXCLUDES+=("$1")
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--resume] [--exclude=PATTERN]..."
            exit 1
            ;;
    esac
    shift
done

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# ── Dependency check ─────────────────────────────────────────────────────────
# command → package mapping for Arch
declare -A DEPS=(
    [sgdisk]=gptfdisk
    [rsync]=rsync
    [cryptsetup]=cryptsetup
    [partprobe]=parted
)

missing=()
for cmd in "${!DEPS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("${DEPS[$cmd]}")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    # Deduplicate
    mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
    echo "==> Missing dependencies: ${missing[*]}"
    echo "    Installing..."
    pacman -Sy --needed --noconfirm "${missing[@]}"
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

confirm() {
    local prompt="$1"
    read -rp "$prompt [y/N] " answer
    [[ "${answer,,}" == "y" ]]
}

# Given a disk like /dev/sda or /dev/nvme0n1, return partition device for number N
part_dev() {
    local disk="$1" num="$2"
    if [[ "$disk" =~ nvme|mmcblk|loop ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# Bytes to human-readable
human() {
    numfmt --to=iec "$1"
}

# Human-readable to bytes (accepts values like 512M, 20G, 1.5T)
to_bytes() {
    numfmt --from=iec "$1"
}

LUKS_WE_OPENED=""  # track mapper names we opened (so cleanup doesn't close pre-existing ones)

cleanup() {
    echo ""
    echo "==> Cleaning up mounts..."
    # Unmount destination bind mounts (chroot)
    for mp in sys/firmware/efi/efivars sys proc dev/pts dev; do
        umount "/mnt/dest/$mp" 2>/dev/null || true
    done
    umount -R /mnt/dest 2>/dev/null || true
    umount -R /mnt/source 2>/dev/null || true
    # Only close LUKS containers that WE opened (not pre-existing ones)
    cryptsetup close dest_home 2>/dev/null || true
    if [[ -n "$LUKS_WE_OPENED" ]]; then
        cryptsetup close "$LUKS_WE_OPENED" 2>/dev/null || true
    fi
    rmdir /mnt/dest 2>/dev/null || true
    rmdir /mnt/source 2>/dev/null || true
}
trap cleanup EXIT

# ── Arrays to track partition layout ─────────────────────────────────────────
# Each index represents a partition. We build these up during discovery.
declare -a PART_ROLE=()       # efi, root, home, swap, other
declare -a PART_DEV=()        # /dev/sda1, etc.
declare -a PART_FSTYPE=()     # vfat, ext4, crypto_LUKS, swap, etc.
declare -a PART_INNER_FS=()   # for LUKS: the filesystem inside (ext4, etc.)
declare -a PART_MOUNT=()      # mount point: /boot/efi, /, /home, [SWAP], etc.
declare -a PART_USED_B=()     # used bytes
declare -a PART_SIZE_B=()     # source partition size in bytes
declare -a DEST_SIZE_B=()     # proposed destination size in bytes
declare -a PART_LUKS_NAME=()  # LUKS mapper name if applicable

LUKS_HOME=false
SOURCE_HOME_LUKS_DEV=""
declare -a DEST_PART_DEV=()

# ── State save/restore ───────────────────────────────────────────────────────

save_state() {
    {
        echo "# rsync-migrate state — saved $(date)"
        echo "SOURCE_DISK=$(printf '%q' "$SOURCE_DISK")"
        echo "DEST_DISK=$(printf '%q' "$DEST_DISK")"
        echo "LUKS_HOME=$LUKS_HOME"
        echo "SOURCE_HOME_LUKS_DEV=$(printf '%q' "$SOURCE_HOME_LUKS_DEV")"

        for i in "${!PART_DEV[@]}"; do
            echo "PART_DEV[$i]=$(printf '%q' "${PART_DEV[$i]}")"
            echo "PART_ROLE[$i]=$(printf '%q' "${PART_ROLE[$i]}")"
            echo "PART_FSTYPE[$i]=$(printf '%q' "${PART_FSTYPE[$i]}")"
            echo "PART_INNER_FS[$i]=$(printf '%q' "${PART_INNER_FS[$i]}")"
            echo "PART_MOUNT[$i]=$(printf '%q' "${PART_MOUNT[$i]}")"
            echo "PART_LUKS_NAME[$i]=$(printf '%q' "${PART_LUKS_NAME[$i]}")"
            echo "DEST_PART_DEV[$i]=$(printf '%q' "${DEST_PART_DEV[$i]}")"
        done
    } > "$STATE_FILE"
    echo "    State saved to $STATE_FILE"
}

restore_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Error: No state file found at $STATE_FILE"
        echo "Run without --resume first."
        exit 1
    fi
    echo "==> Restoring state from $STATE_FILE"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    echo "    Source: $SOURCE_DISK"
    echo "    Dest:   $DEST_DISK"
    echo "    Partitions: ${#PART_DEV[@]}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# Resume path — skip discovery and partitioning, go straight to mount + rsync
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$RESUME" == true ]]; then
    restore_state

    # Re-open source LUKS if needed
    for i in "${!PART_DEV[@]}"; do
        if [[ "${PART_FSTYPE[$i]}" == "crypto_LUKS" ]]; then
            luks_name="${PART_LUKS_NAME[$i]}"
            if [[ -b "/dev/mapper/$luks_name" ]]; then
                echo "    Source LUKS already open as /dev/mapper/$luks_name"
            else
                echo "    Unlocking source LUKS partition..."
                cryptsetup luksOpen "${PART_DEV[$i]}" "$luks_name"
                LUKS_WE_OPENED="$luks_name"
            fi
        fi
    done

    # Re-open destination LUKS if needed
    for i in "${!PART_DEV[@]}"; do
        if [[ "${PART_FSTYPE[$i]}" == "crypto_LUKS" ]]; then
            dest_part="${DEST_PART_DEV[$i]}"
            if [[ -b /dev/mapper/dest_home ]]; then
                echo "    Dest LUKS already open as /dev/mapper/dest_home"
            else
                echo "    Unlocking destination LUKS partition ($dest_part)..."
                cryptsetup luksOpen "$dest_part" dest_home
            fi
        fi
    done

    echo ""
    # Jump to mount + rsync (Step 7 onward)
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Select source disk and discover partitions
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$RESUME" == true ]]; then
    echo "==> Skipping discovery and partitioning (resume mode)"
    echo ""
else # ── begin full run ──

echo "==> Available block devices:"
echo ""
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS -d | grep -E 'disk'
echo ""

read -rp "Source disk (e.g. sda): " src_input
SOURCE_DISK="/dev/$src_input"

if [[ ! -b "$SOURCE_DISK" ]]; then
    echo "Error: $SOURCE_DISK is not a valid block device"
    exit 1
fi

echo ""
echo "Source disk layout:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$SOURCE_DISK"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Identify each partition's role
# ═══════════════════════════════════════════════════════════════════════════════

echo "==> Identifying partitions on $SOURCE_DISK"
echo ""

# Get partition devices (children of the disk)
mapfile -t src_parts < <(lsblk -lnpo NAME,TYPE "$SOURCE_DISK" | awk '$2=="part"{print $1}')

if [[ ${#src_parts[@]} -eq 0 ]]; then
    echo "Error: No partitions found on $SOURCE_DISK"
    exit 1
fi

idx=0
for part in "${src_parts[@]}"; do
    # -d prevents lsblk from showing child devices (e.g. LUKS mapper under partition)
    fstype=$(lsblk -dno FSTYPE "$part" | xargs)

    echo "  Partition: $part"
    echo "  Filesystem: ${fstype:-unknown}"
    echo "  Size: $(lsblk -dno SIZE "$part" | xargs)"
    echo ""

    # Guess role
    guessed_role=""
    if [[ "$fstype" == "vfat" ]]; then
        guessed_role="efi"
    elif [[ "$fstype" == "swap" ]]; then
        guessed_role="swap"
    elif [[ "$fstype" == "crypto_LUKS" ]]; then
        guessed_role="home"
        echo "    (Detected LUKS-encrypted partition)"
    else
        # If we haven't assigned root yet, guess root; otherwise guess home/other
        has_root=false
        for r in "${PART_ROLE[@]}"; do
            [[ "$r" == "root" ]] && has_root=true
        done
        if [[ "$has_root" == false ]]; then
            guessed_role="root"
        else
            guessed_role="home"
        fi
    fi

    read -rp "    Role? [efi/root/home/swap/other] (detected: $guessed_role): " role_input
    role="${role_input:-$guessed_role}"

    PART_DEV[$idx]="$part"
    PART_FSTYPE[$idx]="$fstype"
    PART_ROLE[$idx]="$role"
    PART_INNER_FS[$idx]=""
    PART_LUKS_NAME[$idx]=""
    PART_SIZE_B[$idx]=$(lsblk -dbno SIZE "$part" | xargs)

    # Determine mount point — try to detect from current mounts, fall back to defaults
    detected_mount=$(lsblk -no MOUNTPOINTS "$part" | head -1 | xargs)
    case "$role" in
        efi)
            default_mount="${detected_mount:-/boot/efi}"
            read -rp "    Mount point? [$default_mount]: " mount_input
            PART_MOUNT[$idx]="${mount_input:-$default_mount}"
            ;;
        root) PART_MOUNT[$idx]="/" ;;
        home) PART_MOUNT[$idx]="/home" ;;
        swap) PART_MOUNT[$idx]="[SWAP]" ;;
        *)
            default_mount="${detected_mount:-}"
            read -rp "    Mount point for this partition${default_mount:+ [$default_mount]}: " mount_input
            PART_MOUNT[$idx]="${mount_input:-$default_mount}"
            ;;
    esac

    # Handle LUKS
    if [[ "$fstype" == "crypto_LUKS" ]]; then
        LUKS_HOME=true
        SOURCE_HOME_LUKS_DEV="$part"

        # Check if this LUKS container is already open (e.g. running from installed system)
        existing_mapper=$(lsblk -lno NAME,TYPE "$part" | awk '$2=="crypt"{print $1}' | head -1)

        if [[ -n "$existing_mapper" && -b "/dev/mapper/$existing_mapper" ]]; then
            mapper_name="$existing_mapper"
            echo "    LUKS already unlocked as /dev/mapper/$mapper_name"
        else
            mapper_name="source_home"
            echo "    Unlocking LUKS partition..."
            cryptsetup luksOpen "$part" "$mapper_name"
            LUKS_WE_OPENED="$mapper_name"
        fi

        PART_LUKS_NAME[$idx]="$mapper_name"

        inner_dev="/dev/mapper/$mapper_name"
        inner_fs=$(lsblk -dno FSTYPE "$inner_dev" | xargs)
        PART_INNER_FS[$idx]="$inner_fs"
        echo "    Inner filesystem: $inner_fs"
    fi

    idx=$((idx + 1))
    echo ""
done

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Mount source and measure usage
# ═══════════════════════════════════════════════════════════════════════════════

echo "==> Mounting source partitions and measuring usage..."
mkdir -p /mnt/source

for i in "${!PART_DEV[@]}"; do
    role="${PART_ROLE[$i]}"
    dev="${PART_DEV[$i]}"
    mount_point="${PART_MOUNT[$i]}"
    fstype="${PART_FSTYPE[$i]}"
    luks_name="${PART_LUKS_NAME[$i]}"

    if [[ "$role" == "swap" ]]; then
        PART_USED_B[$i]=0
        continue
    fi

    # Determine what device to mount
    if [[ -n "$luks_name" ]]; then
        mount_dev="/dev/mapper/$luks_name"
    else
        mount_dev="$dev"
    fi

    # Mount
    target="/mnt/source"
    if [[ "$mount_point" != "/" ]]; then
        target="/mnt/source$mount_point"
        mkdir -p "$target"
    fi

    mount "$mount_dev" "$target"

    # Measure used space
    used_kb=$(df -k "$target" | awk 'NR==2{print $3}')
    used_bytes=$((used_kb * 1024))
    PART_USED_B[$i]=$used_bytes

    echo "    $mount_point ($dev): $(human "$used_bytes") used"
done

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Select destination disk
# ═══════════════════════════════════════════════════════════════════════════════

read -rp "Destination disk (e.g. sdb): " dest_input
DEST_DISK="/dev/$dest_input"

if [[ ! -b "$DEST_DISK" ]]; then
    echo "Error: $DEST_DISK is not a valid block device"
    exit 1
fi

if [[ "$DEST_DISK" == "$SOURCE_DISK" ]]; then
    echo "Error: Source and destination cannot be the same disk"
    exit 1
fi

DEST_TOTAL_B=$(lsblk -bno SIZE "$DEST_DISK" | head -1 | xargs)
echo ""
echo "Destination disk: $DEST_DISK ($(human "$DEST_TOTAL_B"))"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Calculate destination partition sizes (usage-based)
# ═══════════════════════════════════════════════════════════════════════════════

echo "==> Calculating destination partition sizes..."
echo ""

# Fixed sizes
EFI_SIZE=$((512 * 1024 * 1024))  # 512 MiB
LUKS_OVERHEAD=$((16 * 1024 * 1024))  # ~16 MiB LUKS header

# Calculate total usage (excluding EFI and swap)
total_used=0
for i in "${!PART_DEV[@]}"; do
    role="${PART_ROLE[$i]}"
    [[ "$role" == "efi" || "$role" == "swap" ]] && continue
    total_used=$((total_used + PART_USED_B[i]))
done

# Available space on destination after EFI
available=$((DEST_TOTAL_B - EFI_SIZE))

# Check if data fits at all (need at least 20% headroom)
min_needed=$(( (total_used * 120) / 100 ))
if [[ $available -lt $min_needed ]]; then
    echo "WARNING: Destination may be tight."
    echo "  Total data: $(human "$total_used")"
    echo "  Available:  $(human "$available") (after EFI)"
    echo "  Suggested:  $(human "$min_needed") (data + 20% headroom)"
    echo ""
    if ! confirm "Continue anyway?"; then
        exit 1
    fi
fi

# Assign sizes proportional to usage, with a minimum 20% headroom per partition
# EFI is always 512M. Swap is excluded for now (user can choose).
echo "Proposed partition layout for $DEST_DISK:"
echo ""
printf "  %-6s  %-10s  %-12s  %-12s  %-12s  %s\n" "#" "Role" "Source Size" "Used" "Dest Size" "Notes"
echo "  $(printf '%.0s─' {1..75})"

part_num=1
for i in "${!PART_DEV[@]}"; do
    role="${PART_ROLE[$i]}"
    used="${PART_USED_B[$i]}"
    src_size="${PART_SIZE_B[$i]}"
    notes=""

    if [[ "$role" == "efi" ]]; then
        DEST_SIZE_B[$i]=$EFI_SIZE
        notes="fixed"
    elif [[ "$role" == "swap" ]]; then
        # Offer same swap size or skip
        DEST_SIZE_B[$i]="${PART_SIZE_B[$i]}"
        notes="same as source"
    else
        # Proportional: this partition's share of the available space
        if [[ $total_used -gt 0 ]]; then
            proportion=$((used * 1000 / total_used))  # permille
            proposed=$((available * proportion / 1000))
        else
            proposed=$available
        fi

        # Ensure at least 20% headroom over usage
        min_for_this=$(( (used * 120) / 100 ))
        if [[ $proposed -lt $min_for_this ]]; then
            proposed=$min_for_this
        fi

        # Account for LUKS overhead
        if [[ "${PART_FSTYPE[$i]}" == "crypto_LUKS" ]]; then
            proposed=$((proposed + LUKS_OVERHEAD))
            notes="LUKS encrypted"
        fi

        DEST_SIZE_B[$i]=$proposed
    fi

    printf "  %-6s  %-10s  %-12s  %-12s  %-12s  %s\n" \
        "$part_num" "$role" "$(human "$src_size")" "$(human "$used")" "$(human "${DEST_SIZE_B[$i]}")" "$notes"

    part_num=$((part_num + 1))
done

echo ""

# Let user adjust
echo "You can adjust sizes. The last non-swap, non-EFI partition will get any remaining space."
echo ""

for i in "${!PART_DEV[@]}"; do
    role="${PART_ROLE[$i]}"
    [[ "$role" == "efi" ]] && continue  # EFI is fixed

    current_human=$(human "${DEST_SIZE_B[$i]}")
    read -rp "  Size for ${role} (${PART_MOUNT[$i]})? [$current_human]: " new_size
    if [[ -n "$new_size" ]]; then
        DEST_SIZE_B[$i]=$(to_bytes "$new_size")
    fi
done

# Give remaining space to the last data partition
allocated=0
last_data_idx=-1
for i in "${!PART_DEV[@]}"; do
    allocated=$((allocated + DEST_SIZE_B[i]))
    role="${PART_ROLE[$i]}"
    if [[ "$role" != "efi" && "$role" != "swap" ]]; then
        last_data_idx=$i
    fi
done

remaining=$((DEST_TOTAL_B - allocated))
if [[ $remaining -gt 0 && $last_data_idx -ge 0 ]]; then
    DEST_SIZE_B[$last_data_idx]=$((DEST_SIZE_B[last_data_idx] + remaining))
    echo ""
    echo "  Allocating remaining $(human "$remaining") to ${PART_ROLE[$last_data_idx]} (${PART_MOUNT[$last_data_idx]})"
    echo "  Final ${PART_ROLE[$last_data_idx]} size: $(human "${DEST_SIZE_B[$last_data_idx]}")"
fi

echo ""
echo "Final layout:"
printf "  %-6s  %-10s  %-12s\n" "#" "Role" "Size"
echo "  $(printf '%.0s─' {1..35})"
part_num=1
for i in "${!PART_DEV[@]}"; do
    printf "  %-6s  %-10s  %-12s\n" "$part_num" "${PART_ROLE[$i]}" "$(human "${DEST_SIZE_B[$i]}")"
    part_num=$((part_num + 1))
done
echo ""

echo "!!! WARNING: This will ERASE ALL DATA on $DEST_DISK !!!"
echo ""
if ! confirm "Proceed with partitioning $DEST_DISK?"; then
    echo "Aborted."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 6: Partition and format destination
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY RUN] Would partition and format $DEST_DISK"
    echo ""
else
    echo "==> Partitioning $DEST_DISK..."
    sgdisk --zap-all "$DEST_DISK"

    part_num=1
    for i in "${!PART_DEV[@]}"; do
        role="${PART_ROLE[$i]}"
        size_b="${DEST_SIZE_B[$i]}"
        size_mib=$((size_b / 1024 / 1024))

        # Type codes
        case "$role" in
            efi)  typecode="ef00" ;;
            swap) typecode="8200" ;;
            *)    typecode="8300" ;;
        esac

        # Last partition gets remaining space (size 0 = fill)
        if [[ $part_num -eq ${#PART_DEV[@]} ]]; then
            sgdisk -n "${part_num}:0:0" -t "${part_num}:${typecode}" -c "${part_num}:${role}" "$DEST_DISK"
        else
            sgdisk -n "${part_num}:0:+${size_mib}M" -t "${part_num}:${typecode}" -c "${part_num}:${role}" "$DEST_DISK"
        fi

        part_num=$((part_num + 1))
    done

    partprobe "$DEST_DISK"
    sleep 2

    # Format each partition
    echo "==> Formatting partitions..."

    part_num=1

    for i in "${!PART_DEV[@]}"; do
        role="${PART_ROLE[$i]}"
        dest_part=$(part_dev "$DEST_DISK" "$part_num")
        DEST_PART_DEV[$i]="$dest_part"

        case "$role" in
            efi)
                echo "    $dest_part → FAT32 (EFI)"
                mkfs.fat -F32 "$dest_part"
                ;;
            swap)
                echo "    $dest_part → swap"
                mkswap "$dest_part"
                ;;
            *)
                if [[ "${PART_FSTYPE[$i]}" == "crypto_LUKS" ]]; then
                    # Create LUKS container on destination
                    echo "    $dest_part → LUKS + ${PART_INNER_FS[$i]}"
                    echo ""
                    echo "    Set the LUKS passphrase for the destination ${role} partition:"
                    cryptsetup luksFormat "$dest_part"
                    echo "    Opening LUKS container..."
                    cryptsetup luksOpen "$dest_part" dest_home
                    mkfs."${PART_INNER_FS[$i]}" /dev/mapper/dest_home
                else
                    fstype="${PART_FSTYPE[$i]}"
                    echo "    $dest_part → $fstype"
                    mkfs."$fstype" -F "$dest_part" 2>/dev/null || mkfs."$fstype" "$dest_part"
                fi
                ;;
        esac

        part_num=$((part_num + 1))
    done
fi

    # Save state so --resume can skip everything above
    save_state

fi  # ── end full run (skipped on --resume) ──

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7: Mount destination and rsync each partition
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY RUN] Would mount source/destination and rsync all partitions"
    echo ""
else
    # ── Mount source partitions ──────────────────────────────────────────────
    echo "==> Mounting source partitions..."
    mkdir -p /mnt/source

    # Root first
    for i in "${!PART_DEV[@]}"; do
        [[ "${PART_ROLE[$i]}" != "root" ]] && continue
        if mountpoint -q /mnt/source 2>/dev/null; then
            echo "    / already mounted"
        else
            mount "${PART_DEV[$i]}" /mnt/source
            echo "    / mounted"
        fi
    done

    # Then other source partitions
    for i in "${!PART_DEV[@]}"; do
        role="${PART_ROLE[$i]}"
        [[ "$role" == "swap" || "$role" == "root" ]] && continue

        mount_point="${PART_MOUNT[$i]}"
        target="/mnt/source$mount_point"
        mkdir -p "$target"

        if mountpoint -q "$target" 2>/dev/null; then
            echo "    $mount_point already mounted"
            continue
        fi

        if [[ "${PART_FSTYPE[$i]}" == "crypto_LUKS" ]]; then
            mount "/dev/mapper/${PART_LUKS_NAME[$i]}" "$target"
        else
            mount "${PART_DEV[$i]}" "$target"
        fi
        echo "    $mount_point mounted"
    done

    # Sanity check: source should have /etc/fstab
    if [[ ! -f /mnt/source/etc/fstab ]]; then
        echo "ERROR: /mnt/source/etc/fstab not found — source mount looks wrong."
        echo "Check that the source partitions are correct and try again."
        exit 1
    fi

    # ── Mount destination partitions ─────────────────────────────────────────
    echo "==> Mounting destination partitions..."
    mkdir -p /mnt/dest

    # Root first
    for i in "${!PART_DEV[@]}"; do
        [[ "${PART_ROLE[$i]}" != "root" ]] && continue

        if mountpoint -q /mnt/dest 2>/dev/null; then
            echo "    / already mounted"
        else
            dest_part="${DEST_PART_DEV[$i]}"
            if [[ "${PART_FSTYPE[$i]}" == "crypto_LUKS" ]]; then
                mount /dev/mapper/dest_home /mnt/dest
            else
                mount "$dest_part" /mnt/dest
            fi
            echo "    / mounted"
        fi
    done

    # Then other dest partitions
    for i in "${!PART_DEV[@]}"; do
        role="${PART_ROLE[$i]}"
        mount_point="${PART_MOUNT[$i]}"

        [[ "$role" == "swap" || "$role" == "root" ]] && continue

        target="/mnt/dest$mount_point"
        mkdir -p "$target"

        if mountpoint -q "$target" 2>/dev/null; then
            echo "    $mount_point already mounted"
            continue
        fi

        dest_part="${DEST_PART_DEV[$i]}"
        if [[ "${PART_FSTYPE[$i]}" == "crypto_LUKS" ]]; then
            mount /dev/mapper/dest_home "$target"
        else
            mount "$dest_part" "$target"
        fi
        echo "    $mount_point mounted"
    done

    # Rsync each mounted source partition to destination
    RSYNC_EXCLUDES=(
        /dev/*
        /proc/*
        /sys/*
        /tmp/*
        /run/*
        /mnt/*
        /media/*
        /lost+found
        /swapfile
    )

    RSYNC_BASE_ARGS=(-aAXHv --progress --delete)
    for excl in "${RSYNC_EXCLUDES[@]}"; do
        RSYNC_BASE_ARGS+=(--exclude="$excl")
    done

    # Add user-specified excludes (--exclude=PATTERN)
    for excl in "${EXTRA_EXCLUDES[@]}"; do
        RSYNC_BASE_ARGS+=(--exclude="$excl")
        echo "    Extra exclude: $excl"
    done

    echo ""
    echo "==> Rsync: cloning filesystem..."
    echo "    This may take a while."
    echo ""

    rsync "${RSYNC_BASE_ARGS[@]}" /mnt/source/ /mnt/dest/

    # Recreate excluded dirs
    mkdir -p /mnt/dest/{dev,proc,sys,tmp,run,mnt,media}

    echo ""
    echo "==> Rsync complete."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 8: Generate fstab and crypttab
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY RUN] Would generate new fstab and crypttab"
else
    echo "==> Generating new fstab..."

    if ! command -v genfstab &>/dev/null; then
        pacman -Sy --noconfirm arch-install-scripts
    fi

    cp /mnt/dest/etc/fstab /mnt/dest/etc/fstab.bak
    genfstab -U /mnt/dest > /mnt/dest/etc/fstab

    echo "    New fstab:"
    cat /mnt/dest/etc/fstab
    echo ""

    if ! confirm "    Does the fstab look correct?"; then
        echo "    Restoring backup fstab. Edit /mnt/dest/etc/fstab manually before rebooting."
        cp /mnt/dest/etc/fstab.bak /mnt/dest/etc/fstab
    fi

    # Generate crypttab if LUKS is involved
    if [[ "$LUKS_HOME" == true ]]; then
        echo "==> Generating crypttab..."

        # Find the destination LUKS partition
        for i in "${!PART_DEV[@]}"; do
            if [[ "${PART_FSTYPE[$i]}" == "crypto_LUKS" ]]; then
                dest_luks_dev="${DEST_PART_DEV[$i]}"
                dest_luks_uuid=$(blkid -s UUID -o value "$dest_luks_dev")
                luks_mapper_name="home"

                # Read existing crypttab to preserve the mapper name
                if [[ -f /mnt/dest/etc/crypttab ]]; then
                    cp /mnt/dest/etc/crypttab /mnt/dest/etc/crypttab.bak
                    # Try to extract the mapper name from the old crypttab
                    old_name=$(grep -v '^#' /mnt/dest/etc/crypttab.bak | head -1 | awk '{print $1}')
                    if [[ -n "$old_name" ]]; then
                        luks_mapper_name="$old_name"
                    fi
                fi

                echo "# Destination LUKS mapping" > /mnt/dest/etc/crypttab
                echo "$luks_mapper_name  UUID=$dest_luks_uuid  none  luks" >> /mnt/dest/etc/crypttab

                echo "    crypttab:"
                cat /mnt/dest/etc/crypttab
                echo ""

                # Fix fstab to reference the mapper name
                # genfstab may have written /dev/mapper/dest_home — fix it
                sed -i "s|/dev/mapper/dest_home|/dev/mapper/$luks_mapper_name|g" /mnt/dest/etc/fstab

                echo "    Updated fstab LUKS references to /dev/mapper/$luks_mapper_name"
                break
            fi
        done
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 9: Chroot — GRUB + initramfs
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY RUN] Would chroot, reinstall GRUB, regenerate initramfs"
else
    echo "==> Setting up chroot..."

    mount --bind /dev /mnt/dest/dev
    mount --bind /dev/pts /mnt/dest/dev/pts
    mount -t proc proc /mnt/dest/proc
    mount -t sysfs sys /mnt/dest/sys
    mount -t efivarfs efivarfs /mnt/dest/sys/firmware/efi/efivars 2>/dev/null || true

    # Detect EFI mount point
    efi_mount="/boot/efi"
    for i in "${!PART_DEV[@]}"; do
        if [[ "${PART_ROLE[$i]}" == "efi" ]]; then
            efi_mount="${PART_MOUNT[$i]}"
            break
        fi
    done

    # Ensure mkinitcpio includes encrypt hook if LUKS is in use
    if [[ "$LUKS_HOME" == true ]]; then
        echo "==> Checking mkinitcpio HOOKS for encrypt support..."
        if ! grep -q 'encrypt' /mnt/dest/etc/mkinitcpio.conf; then
            echo "    NOTE: 'encrypt' hook not found in mkinitcpio.conf."
            echo "    If /home is unlocked via crypttab (not initramfs), this is fine."
            echo "    If you need early-boot decryption, add 'encrypt' to HOOKS manually."
        fi
    fi

    echo "==> Reinstalling GRUB..."
    chroot /mnt/dest grub-install --target=x86_64-efi --efi-directory="$efi_mount" --bootloader-id=GRUB

    echo "==> Regenerating GRUB config..."
    chroot /mnt/dest grub-mkconfig -o /boot/grub/grub.cfg

    echo "==> Regenerating initramfs..."
    chroot /mnt/dest mkinitcpio -P

    # Unmount bind mounts
    umount /mnt/dest/sys/firmware/efi/efivars 2>/dev/null || true
    umount /mnt/dest/sys
    umount /mnt/dest/proc
    umount /mnt/dest/dev/pts
    umount /mnt/dest/dev
fi

echo ""
echo "=== Migration complete ==="
echo ""
echo "Summary:"
for i in "${!PART_DEV[@]}"; do
    role="${PART_ROLE[$i]}"
    src="${PART_DEV[$i]}"
    dest="${DEST_PART_DEV[$i]:-n/a}"
    echo "  ${PART_MOUNT[$i]}: $src → $dest (${role}$([ "${PART_FSTYPE[$i]}" = "crypto_LUKS" ] && echo ", LUKS"))"
done
echo ""
echo "Next steps:"
echo "  1. Remove source disk or change boot order in BIOS"
echo "  2. Boot from destination disk"
echo "  3. Verify everything works"
if [[ "$LUKS_HOME" == true ]]; then
    echo "  4. You should be prompted for your LUKS passphrase during boot"
fi
