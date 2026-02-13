# arch-migrate

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

Best when you want an exact clone. Run from a **live USB** with both disks attached.

```bash
sudo ./rsync-migrate.sh           # interactive
sudo ./rsync-migrate.sh --dry-run  # preview only
```

This partitions the destination (UEFI GPT: EFI + root), rsyncs the entire filesystem, generates a new fstab, reinstalls GRUB, and regenerates initramfs.

## Requirements

- **Option A**: `pacman`, `paru` (installed automatically if needed), `systemctl`
- **Option B**: `rsync`, `sgdisk`, `genfstab` (from `arch-install-scripts`), `grub`, live USB environment
