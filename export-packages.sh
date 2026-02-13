#!/usr/bin/env bash
set -euo pipefail

# export-packages.sh — Capture package lists, enabled services, and modified configs
# Run this on the SOURCE machine before migration.

EXPORT_DIR="arch-migrate-$(date +%Y%m%d-%H%M%S)"

echo "==> Creating export directory: $EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

# Native (repo) packages — explicitly installed
echo "==> Exporting native package list..."
pacman -Qqen > "$EXPORT_DIR/pkglist-native.txt"
native_count=$(wc -l < "$EXPORT_DIR/pkglist-native.txt")
echo "    $native_count native packages"

# Foreign (AUR) packages — explicitly installed
echo "==> Exporting AUR/foreign package list..."
pacman -Qqem > "$EXPORT_DIR/pkglist-aur.txt"
aur_count=$(wc -l < "$EXPORT_DIR/pkglist-aur.txt")
echo "    $aur_count AUR/foreign packages"

# Enabled system services
echo "==> Exporting enabled system services..."
systemctl list-unit-files --state=enabled --no-legend | awk '{print $1}' > "$EXPORT_DIR/services-system.txt"
sys_svc_count=$(wc -l < "$EXPORT_DIR/services-system.txt")
echo "    $sys_svc_count system services"

# Enabled user services
echo "==> Exporting enabled user services..."
systemctl --user list-unit-files --state=enabled --no-legend | awk '{print $1}' > "$EXPORT_DIR/services-user.txt"
user_svc_count=$(wc -l < "$EXPORT_DIR/services-user.txt")
echo "    $user_svc_count user services"

# User groups
echo "==> Exporting user groups..."
groups > "$EXPORT_DIR/user-groups.txt"
echo "    Groups: $(cat "$EXPORT_DIR/user-groups.txt")"

# Modified config files (tracked by pacman)
echo "==> Detecting modified config files..."
pacman -Qii 2>/dev/null | grep '^MODIFIED' | awk '{print $2}' > "$EXPORT_DIR/modified-configs.txt" || true
mod_count=$(wc -l < "$EXPORT_DIR/modified-configs.txt")
echo "    $mod_count modified config files"

# Archive modified configs
if [[ $mod_count -gt 0 ]]; then
    echo "==> Archiving modified config files..."
    tar czf "$EXPORT_DIR/modified-configs.tar.gz" -T "$EXPORT_DIR/modified-configs.txt" 2>/dev/null || {
        echo "    Warning: Some config files could not be archived (may need root)"
        echo "    Try running with sudo for complete config backup"
    }
fi

# Pacman configuration
echo "==> Copying pacman configuration..."
cp /etc/pacman.conf "$EXPORT_DIR/pacman.conf"
if [[ -d /etc/pacman.d ]]; then
    mkdir -p "$EXPORT_DIR/pacman.d"
    cp -r /etc/pacman.d/* "$EXPORT_DIR/pacman.d/" 2>/dev/null || true
fi

echo ""
echo "=== Export complete ==="
echo "Directory: $EXPORT_DIR/"
echo ""
echo "Contents:"
ls -lh "$EXPORT_DIR/"
echo ""
echo "Next steps:"
echo "  1. Copy this directory to the destination machine"
echo "  2. Do a base Arch install on the destination"
echo "  3. Run: ./restore-packages.sh $EXPORT_DIR"
echo "  4. rsync your home directory across"
