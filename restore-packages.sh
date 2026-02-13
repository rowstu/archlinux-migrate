#!/usr/bin/env bash
set -euo pipefail

# restore-packages.sh — Restore packages, services, and configs from an export
# Run this on the DESTINATION machine after a base Arch install.
# Usage: sudo ./restore-packages.sh <export-directory>

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <export-directory>"
    echo "Example: $0 arch-migrate-20260213-143000"
    exit 1
fi

EXPORT_DIR="$1"

if [[ ! -d "$EXPORT_DIR" ]]; then
    echo "Error: Directory '$EXPORT_DIR' not found"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

# Detect the regular user (who invoked sudo)
REGULAR_USER="${SUDO_USER:-}"
if [[ -z "$REGULAR_USER" ]]; then
    echo "Error: Could not detect the regular user. Run with sudo, not as root directly."
    exit 1
fi

confirm() {
    local prompt="$1"
    read -rp "$prompt [y/N] " answer
    [[ "${answer,,}" == "y" ]]
}

# --- Step 1: Pacman configuration ---
if [[ -f "$EXPORT_DIR/pacman.conf" ]]; then
    echo "==> Pacman configuration"
    if confirm "    Replace /etc/pacman.conf with exported version?"; then
        cp /etc/pacman.conf /etc/pacman.conf.bak
        cp "$EXPORT_DIR/pacman.conf" /etc/pacman.conf
        echo "    Backed up original to /etc/pacman.conf.bak"
    fi
fi

if [[ -d "$EXPORT_DIR/pacman.d" ]]; then
    echo "==> Pacman mirror/repo configs"
    if confirm "    Copy exported pacman.d configs to /etc/pacman.d/?"; then
        cp -r "$EXPORT_DIR/pacman.d/"* /etc/pacman.d/
    fi
fi

# --- Step 2: System update ---
echo "==> Syncing package databases and updating system..."
pacman -Syu --noconfirm

# --- Step 3: Install native packages ---
if [[ -f "$EXPORT_DIR/pkglist-native.txt" ]]; then
    native_count=$(wc -l < "$EXPORT_DIR/pkglist-native.txt")
    echo "==> Installing $native_count native packages..."
    # --needed skips already-installed packages
    pacman -S --needed --noconfirm - < "$EXPORT_DIR/pkglist-native.txt" || {
        echo ""
        echo "    Warning: Some packages failed to install."
        echo "    This can happen if packages were removed from the repos."
        echo "    Review the output above and install missing packages manually."
        echo ""
        if ! confirm "    Continue anyway?"; then
            exit 1
        fi
    }
fi

# --- Step 4: Install paru (AUR helper) ---
if [[ -f "$EXPORT_DIR/pkglist-aur.txt" ]] && [[ -s "$EXPORT_DIR/pkglist-aur.txt" ]]; then
    aur_count=$(wc -l < "$EXPORT_DIR/pkglist-aur.txt")
    echo "==> $aur_count AUR packages to install"

    if ! command -v paru &>/dev/null; then
        echo "==> paru not found, installing..."
        # Install build dependencies
        pacman -S --needed --noconfirm base-devel git

        # Build paru as the regular user
        PARU_BUILD=$(mktemp -d)
        git clone https://aur.archlinux.org/paru-bin.git "$PARU_BUILD/paru-bin"
        chown -R "$REGULAR_USER:$REGULAR_USER" "$PARU_BUILD"
        su -c "cd '$PARU_BUILD/paru-bin' && makepkg -si --noconfirm" "$REGULAR_USER"
        rm -rf "$PARU_BUILD"
    fi

    # Install AUR packages as the regular user
    echo "==> Installing AUR packages..."
    su -c "paru -S --needed --noconfirm - < '$EXPORT_DIR/pkglist-aur.txt'" "$REGULAR_USER" || {
        echo ""
        echo "    Warning: Some AUR packages failed to install."
        echo "    Review the output above and install manually with:"
        echo "    paru -S <package-name>"
        echo ""
    }
fi

# --- Step 5: Enable system services ---
if [[ -f "$EXPORT_DIR/services-system.txt" ]]; then
    echo "==> Enabling system services..."
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        if systemctl enable "$service" 2>/dev/null; then
            echo "    Enabled: $service"
        else
            echo "    Skipped (not found): $service"
        fi
    done < "$EXPORT_DIR/services-system.txt"
fi

# --- Step 6: Enable user services ---
if [[ -f "$EXPORT_DIR/services-user.txt" ]] && [[ -s "$EXPORT_DIR/services-user.txt" ]]; then
    echo "==> Enabling user services for $REGULAR_USER..."
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        if su -c "systemctl --user enable '$service'" "$REGULAR_USER" 2>/dev/null; then
            echo "    Enabled: $service"
        else
            echo "    Skipped (not found): $service"
        fi
    done < "$EXPORT_DIR/services-user.txt"
fi

# --- Step 7: User groups ---
if [[ -f "$EXPORT_DIR/user-groups.txt" ]]; then
    echo "==> Adding $REGULAR_USER to groups..."
    exported_groups=$(cat "$EXPORT_DIR/user-groups.txt")
    for group in $exported_groups; do
        # Skip the user's primary group (same as username)
        [[ "$group" == "$REGULAR_USER" ]] && continue
        if getent group "$group" &>/dev/null; then
            usermod -aG "$group" "$REGULAR_USER"
            echo "    Added to: $group"
        else
            echo "    Skipped (group doesn't exist): $group"
        fi
    done
fi

# --- Step 8: Modified config files ---
if [[ -f "$EXPORT_DIR/modified-configs.tar.gz" ]] && [[ -f "$EXPORT_DIR/modified-configs.txt" ]]; then
    mod_count=$(wc -l < "$EXPORT_DIR/modified-configs.txt")
    echo "==> $mod_count modified config files available"

    if confirm "    Review and restore modified configs?"; then
        # Extract to a temp dir for comparison
        TEMP_CONFIGS=$(mktemp -d)
        tar xzf "$EXPORT_DIR/modified-configs.tar.gz" -C "$TEMP_CONFIGS"

        while IFS= read -r config_file; do
            [[ -z "$config_file" ]] && continue
            local_file="$TEMP_CONFIGS$config_file"

            if [[ ! -f "$local_file" ]]; then
                echo "    Skipping (not in archive): $config_file"
                continue
            fi

            echo ""
            echo "--- $config_file ---"
            if [[ -f "$config_file" ]]; then
                # Show diff between current and exported
                diff --color=auto "$config_file" "$local_file" || true
            else
                echo "    (file does not exist on destination)"
            fi

            if confirm "    Replace $config_file with exported version?"; then
                mkdir -p "$(dirname "$config_file")"
                cp "$local_file" "$config_file"
                echo "    Restored: $config_file"
            else
                echo "    Skipped: $config_file"
            fi
        done < "$EXPORT_DIR/modified-configs.txt"

        rm -rf "$TEMP_CONFIGS"
    fi
fi

echo ""
echo "=== Restore complete ==="
echo ""
echo "Remaining steps:"
echo "  1. rsync your home directory from the source machine:"
echo "     rsync -aAXHv --progress source:/home/$REGULAR_USER/ /home/$REGULAR_USER/"
echo "  2. Reboot and verify everything works"
echo "  3. Check for any services that need manual configuration"
