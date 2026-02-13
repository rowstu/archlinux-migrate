# archlinux-migrate

Scripts for migrating an Arch Linux install to a different disk, especially when the destination is smaller than the source.

Two approaches:

## Option A: Package list (clean install)

Best when you want a fresh system with the same packages.

**On the source machine:**

```bash
./export-packages.sh
```

This creates an `arch-migrate-<timestamp>/` directory containing package lists, enabled services, user groups, modified configs, and pacman configuration.

**On the destination machine** (after a base Arch install):

```bash
# Copy the export directory to the destination, then:
sudo ./restore-packages.sh arch-migrate-<timestamp>
```

This installs all packages (native + AUR via paru), re-enables services, restores groups, and offers to restore modified configs with diffs.

**Then rsync your home directory:**

```bash
rsync -aAXHv --progress source:/home/user/ /home/user/
```

## Option B: Full filesystem rsync

Best when you want an exact clone. Run from a **live USB** or the running system with both disks attached.

```bash
sudo ./rsync-migrate.sh                          # full interactive run
sudo ./rsync-migrate.sh --dry-run                 # preview only
sudo ./rsync-migrate.sh --resume                  # skip discovery/partitioning, re-mount and re-rsync
sudo ./rsync-migrate.sh --resume --exclude='*.qcow2'  # resume with extra excludes
```

**Flags:**

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview mode — no changes are made |
| `--resume` | Skip partition discovery and formatting. Re-mounts source/destination and re-runs rsync from where you left off. Requires a previous successful run that saved state. |
| `--exclude=PATTERN` | Additional rsync exclude pattern. Can be specified multiple times. Useful for skipping large files that don't fit on the destination. |

**What it does:**

1. Discovers all source partitions and auto-detects their roles (EFI, root, home, swap)
2. Handles LUKS-encrypted partitions (detects already-open containers or prompts to unlock)
3. Calculates destination partition sizes proportionally based on actual usage with 20% headroom
4. Lets you adjust sizes interactively before committing
5. Partitions and formats the destination (GPT: EFI + root + home/LUKS as needed)
6. Rsyncs the entire filesystem
7. Generates new fstab and crypttab (if LUKS)
8. Reinstalls GRUB and regenerates initramfs via chroot

State is saved to `/tmp/rsync-migrate-state.sh` after partitioning, enabling `--resume` if rsync fails (e.g. disk full). On resume you can add `--exclude` patterns to skip large files and retry.

## Requirements

- **Option A**: `pacman`, `paru` (installed automatically if needed), `systemctl`
- **Option B**: `rsync`, `sgdisk` (gptfdisk), `cryptsetup`, `partprobe` (parted), `genfstab` (arch-install-scripts), `grub`. Missing dependencies are installed automatically.
