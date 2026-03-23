#!/bin/bash
set -e

# --- Configuration ---
ISO_DIR="archium-linux-iso"
PATCH_DIR="patches"
LINUX_TKG_DIR="linux-tkg"
REPO_DIR="archium_repo"
INTERNAL_REPO_DEST="$ISO_DIR/airootfs/opt/archium_repo"

OLD_KERN="vmlinuz-linux"
NEW_KERN="vmlinuz-linux-archium-tkg-x86-64"
OLD_INIT="initramfs-linux.img"
NEW_INIT="initramfs-linux-archium-tkg-x86-64.img"

PRESET_FILE_MK="$ISO_DIR/airootfs/etc/mkinitcpio.d/linux.preset"
INSTALLER_SRC="$PATCH_DIR/InstallerScripts"

# --- Theming ---
THEME_SRC="$PATCH_DIR/theme/archium-dialogrc"
THEME_DEST="$ISO_DIR/airootfs/etc/archium-dialogrc"

# --- 1. Artwork ---
echo "🎨 Injecting Artwork ..."
if [ -d "$PATCH_DIR" ]; then
    cp "$PATCH_DIR/arts/Splash/splash.png" "$ISO_DIR/syslinux/splash.png" 2>/dev/null || echo "⚠️ Splash image not found"

    WP_SRC="$PATCH_DIR/arts/Backgrounds"
    WP_DEST="$ISO_DIR/airootfs/usr/share/wallpapers/Archium/contents/images"
    mkdir -p "$WP_DEST"

    if [ -d "$WP_SRC" ]; then
        shopt -s nullglob
        WALLPAPERS=("$WP_SRC"/*.png)
        shopt -u nullglob

        if [ ${#WALLPAPERS[@]} -gt 0 ]; then
            cp "${WALLPAPERS[@]}" "$WP_DEST/"
        fi

        if [ -f "$WP_DEST/Simple_Dark.png" ]; then
            ln -sf "Simple_Dark.png" "$WP_DEST/default.png"
            echo "✅ Wallpapers injected successfully."
        else
            echo "⚠️ Simple_Dark.png not found; default.png symlink might be broken."
        fi
    else
        echo "❌ ERROR: Wallpaper source not found at $WP_SRC"
    fi
fi

# --- 2. Custom Repository Generation ---
echo "🏗️ Building and injecting custom repo ..."
mkdir -p "$REPO_DIR"

echo "📦 Gathering compiled kernel packages..."
find . -maxdepth 1 -name "linux-archium-tkg-*.pkg.tar.zst" -exec mv -f {} "$REPO_DIR/" \; 2>/dev/null
find "$LINUX_TKG_DIR" -maxdepth 1 -name "linux-archium-tkg-*.pkg.tar.zst" -exec mv -f {} "$REPO_DIR/" \; 2>/dev/null

shopt -s nullglob
KERNEL_PKGS=("$REPO_DIR"/*.pkg.tar.zst)
shopt -u nullglob

if [ ${#KERNEL_PKGS[@]} -gt 0 ]; then
    echo "🗃️ Found ${#KERNEL_PKGS[@]} packages. Generating repository database..."

    rm -f "$REPO_DIR/archium.db" "$REPO_DIR/archium.db.tar.gz" \
          "$REPO_DIR/archium.files" "$REPO_DIR/archium.files.tar.gz"

    repo-add "$REPO_DIR/archium.db.tar.gz" "${KERNEL_PKGS[@]}"

    mkdir -p "$INTERNAL_REPO_DEST"
    cp -r "$REPO_DIR"/. "$INTERNAL_REPO_DEST/"
    echo "✅ Repo created and injected successfully."
else
    echo "⚠️ Warning: No compiled kernels found! Did buildKernels.sh compile them?"
    echo "   (Skipping repo generation and injection)."
fi

# --- 3. Patch pacman.conf ---
echo "🧩 Patching pacman.conf ..."
PACMAN_CONF="$ISO_DIR/pacman.conf"
BUILD_HOST_REPO_PATH="$(pwd)/$REPO_DIR"

if [ -f "$PACMAN_CONF" ]; then
    sed -i '/^\[archium\]$/,/^$/d' "$PACMAN_CONF"

    # Remove any old multilib block, then append a clean one
    sed -i '/^\#\?\[multilib\]$/,/^\s*Include = \/etc\/pacman.d\/mirrorlist\s*$/d' "$PACMAN_CONF"

    cat >> "$PACMAN_CONF" <<EOF

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

    {
        printf '[archium]\n'
        printf 'SigLevel = Optional TrustAll\n'
        printf 'Server = file://%s\n\n' "$BUILD_HOST_REPO_PATH"
        cat "$PACMAN_CONF"
    } > pacman.tmp
    mv pacman.tmp "$PACMAN_CONF"

    mkdir -p "$ISO_DIR/airootfs/etc"
    cp "$PACMAN_CONF" "$ISO_DIR/airootfs/etc/pacman.conf"
    sed -i "s|file://$BUILD_HOST_REPO_PATH|file:///opt/archium_repo|g" "$ISO_DIR/airootfs/etc/pacman.conf"

    echo "✅ pacman.conf patched cleanly."
else
    echo "❌ ERROR: $PACMAN_CONF not found."
fi

# --- 4. Patch Bootloader (Syslinux BIOS menu) ---
SYSLINUX_CFG="$ISO_DIR/syslinux/archiso_sys-linux.cfg"

if [ -f "$SYSLINUX_CFG" ]; then
    echo "📝 Theming BIOS boot menu (Archium branding)..."

    # --- Kernel + initramfs ---
    sed -i "s|$OLD_KERN|$NEW_KERN|g" "$SYSLINUX_CFG"
    sed -i "s|$OLD_INIT|$NEW_INIT|g" "$SYSLINUX_CFG"

    # --- TOP TITLE ---
    sed -i 's|MENU TITLE Arch Linux|MENU TITLE Archium Linux|' "$SYSLINUX_CFG"

    # --- MAIN ENTRIES ---
    sed -i \
        -e 's|Arch Linux install medium (x86_64, BIOS)|Archium Linux install medium (x86_64, BIOS)|' \
        -e 's|Arch Linux install medium (x86_64, BIOS) with speech|Archium Linux install medium (x86_64, BIOS) with speech|' \
        "$SYSLINUX_CFG"

    # --- BOTTOM DESCRIPTION TEXT ---
    sed -i \
        -e 's|Boot the Arch Linux install medium on BIOS.|Boot the Archium Linux install medium on BIOS.|' \
        -e 's|It allows you to install Arch Linux or perform system maintenance.|It allows you to install Archium Linux or perform system maintenance.|' \
        "$SYSLINUX_CFG"
fi

# --- 5. Patch Kernel paths (Preset) ---
if [ -f "$PRESET_FILE_MK" ]; then
    echo "📝 Patching mkinitcpio preset..."
    sed -i "s|$OLD_KERN|$NEW_KERN|g" "$PRESET_FILE_MK"
    sed -i "s|$OLD_INIT|$NEW_INIT|g" "$PRESET_FILE_MK"
    mv "$PRESET_FILE_MK" "$ISO_DIR/airootfs/etc/mkinitcpio.d/linux-archium-tkg-x86-64.preset"
fi

# --- 6. Branding ---
echo "🖋️ Tailoring the profiledef.sh metadata ..."
if [ -f "$ISO_DIR/profiledef.sh" ]; then
    sed -i \
        -e 's|^iso_name=.*|iso_name="archiumlinux"|' \
        -e 's|^iso_label=.*|iso_label="ARCHIUM_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"|' \
        -e 's|^iso_publisher=.*|iso_publisher="Archium Linux Unofficial"|' \
        -e 's|^iso_application=.*|iso_application="Archium Linux Live/Rescue DVD"|' \
        "$ISO_DIR/profiledef.sh"
fi

# --- 7. Installer Scripts & Hook ---
echo "📜 Injecting Scripts and hijacking automated_script hook..."
if [ -d "$INSTALLER_SRC" ]; then
    mkdir -p "$ISO_DIR/airootfs/root"
    cp "$INSTALLER_SRC/archium-setup.sh" "$ISO_DIR/airootfs/root/"
    cp "$INSTALLER_SRC/archium-install.sh" "$ISO_DIR/airootfs/root/"
    chmod +x "$ISO_DIR/airootfs/root/archium-setup.sh"
    chmod +x "$ISO_DIR/airootfs/root/archium-install.sh"
    ln -sf "archium-setup.sh" "$ISO_DIR/airootfs/root/.automated_script.sh"
    echo "  -> Scripts injected to /root/ and hooked to autostart."
fi

# --- 7b. Dialog Theme ---
echo "🎨 Injecting Archium dialog theme..."
if [ -f "$THEME_SRC" ]; then
    mkdir -p "$ISO_DIR/airootfs/etc"
    cp "$THEME_SRC" "$THEME_DEST"
    echo "  -> Theme injected to /etc/archium-dialogrc."
else
    echo "⚠️ Warning: Theme file not found at $THEME_SRC"
fi

# --- 8. Update permissions in profiledef.sh ---
echo "🔐 Setting correct file permissions in profiledef.sh..."
if [ -f "$ISO_DIR/profiledef.sh" ]; then
    PERM_LINES='  ["/root/archium-setup.sh"]="0:0:755"\n  ["/root/archium-install.sh"]="0:0:755"\n  ["/root/.automated_script.sh"]="0:0:755"\n  ["/opt/archium_repo"]="0:0:755"\n  ["/usr/share/wallpapers/Archium"]="0:0:755"\n  ["/etc/archium-dialogrc"]="0:0:644"'
    sed -i "/file_permissions=(/,/)/ s|)|$PERM_LINES\n)|" "$ISO_DIR/profiledef.sh"
fi

# --- 9. Clean up pacnew conflicts ---
find "$ISO_DIR/airootfs/etc/" -name "*.pacnew" -exec rm -f {} + 2>/dev/null

# --- 10. Package list ---
echo "📦 Updating ISO package list (packages.x86_64) ..."

PKGS_LIST="$ISO_DIR/packages.x86_64"
CUSTOM_PKGS_SRC="$PATCH_DIR/packages/pkgs.txt"

if [ -f "$PKGS_LIST" ]; then
    sed -i '/^linux$/d' "$PKGS_LIST"
    echo "  -> Removed stock 'linux' kernel from package list."

    if ! grep -q '^linux-archium-tkg-x86-64$' "$PKGS_LIST"; then
        echo "linux-archium-tkg-x86-64" >> "$PKGS_LIST"
    fi

    if [ -f "$CUSTOM_PKGS_SRC" ]; then
        echo "  -> Injecting additional packages from $CUSTOM_PKGS_SRC..."
        grep -v '^#' "$CUSTOM_PKGS_SRC" | grep -v '^$' >> "$PKGS_LIST"
        sort -u -o "$PKGS_LIST" "$PKGS_LIST"
    else
        echo "⚠️ Warning: $CUSTOM_PKGS_SRC not found!"
    fi
else
    echo "❌ ERROR: $PKGS_LIST not found. Cannot update package list."
fi

echo "✅ Archium Injection Complete!"
