#!/bin/bash
set -euo pipefail

REPO_DIR="archium-repo"
BUILD_DIR="aur-build"
PKG_LIST="patches/packages/aur/pkgs.txt"
BUILD_USER="${SUDO_USER:-$USER}"

mkdir -p "$REPO_DIR"
mkdir -p "$BUILD_DIR"

if [[ ! -f "$PKG_LIST" ]]; then
    echo "ERROR: Package list not found: $PKG_LIST"
    exit 1
fi

mapfile -t AUR_PKGS < <(grep -v '^[[:space:]]*#' "$PKG_LIST" | grep -v '^[[:space:]]*$')

if [[ ${#AUR_PKGS[@]} -eq 0 ]]; then
    echo "ERROR: No AUR packages found in $PKG_LIST"
    exit 1
fi

for pkg in "${AUR_PKGS[@]}"; do
    echo "==> Building AUR package: $pkg"
    rm -rf "$BUILD_DIR/$pkg"

    git clone "https://aur.archlinux.org/${pkg}.git" "$BUILD_DIR/$pkg"

    (
        cd "$BUILD_DIR/$pkg"

        # Build as normal user, not root
        if [[ "$EUID" -eq 0 ]]; then
            chown -R "$BUILD_USER:$BUILD_USER" .
            sudo -u "$BUILD_USER" makepkg -sf --noconfirm
        else
            makepkg -sf --noconfirm
        fi

        mv ./*.pkg.tar.zst "../../$REPO_DIR/"
    )

    rm -rf "$BUILD_DIR/$pkg"
done

echo "✅ AUR packages copied to $REPO_DIR"
