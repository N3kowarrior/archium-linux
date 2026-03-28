#!/bin/bash
set -eEuo pipefail

export DIALOGRC="${DIALOGRC:-/etc/archium-dialogrc}"

TITLE="Archium Linux Installer"
ERROR_TITLE=" Error "
INSTALL_TITLE=" Installing Archium "
SUCCESS_TITLE=" Success "

DIALOG_H=12
DIALOG_W=68

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/archium-setup.sh"
CONFIGURE_SCRIPT="$SCRIPT_DIR/archium-configure.sh"

get_dialog_size() {
    local rows cols

    rows=$(tput lines)
    cols=$(tput cols)

    [[ -z "$rows" || "$rows" -lt 20 ]] && rows=24
    [[ -z "$cols" || "$cols" -lt 60 ]] && cols=80

    DIALOG_H=$((rows * 80 / 100))
    DIALOG_W=$((cols * 80 / 100))

    MENU_H=$((rows * 85 / 100))
    MENU_W=$((cols * 85 / 100))
    MENU_LIST_H=$((MENU_H - 8))
    return 0
}

load_installer_config() {
    if [[ -f /tmp/archium.conf ]]; then
        # shellcheck disable=SC1091
        source /tmp/archium.conf
    else
        dialog --clear --backtitle "$TITLE" --title "$ERROR_TITLE" \
            --msgbox "No configuration found. Returning to setup." 8 50
        exec "$SETUP_SCRIPT"
    fi

    : "${FS_TYPE:=ext4}"
    : "${GPU_STACK:=generic}"
    : "${ENABLE_FSTRIM:=0}"
    : "${EXTRA_MOUNTS:=}"
    : "${SWAP_MOUNTPOINT:=}"
    : "${SWAP_FSTAB_PATH:=}"
    return 0
}
trap 'echo "Installer crashed near line $LINENO while running: $BASH_COMMAND" | tee /tmp/archium-install-error.log' ERR

detect_boot_mode() {
    BOOT_MODE="bios"
    if [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE="uefi"
    fi
    return 0
}

detect_kernel_target() {
    KERNEL="x86-64"

    local cpu_vendor cpu_family cpu_model base_level
    cpu_vendor="$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')"
    cpu_family="$(LANG=C lscpu | awk -F: '/CPU family/ {gsub(/ /,"",$2); print $2}')"
    cpu_model="$(LANG=C lscpu | awk -F: '/Model:/ {gsub(/ /,""); print $2}')"

    if grep -qw avx512 /proc/cpuinfo; then
        base_level="x86-64-v4"
    elif grep -qw avx2 /proc/cpuinfo; then
        base_level="x86-64-v3"
    elif grep -qw sse4_2 /proc/cpuinfo; then
        base_level="x86-64-v2"
    else
        base_level="x86-64"
    fi

    KERNEL="$base_level"

    if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
        case "$cpu_model" in
            78|94|142|158) KERNEL="skylake" ;;
            151|154) KERNEL="alderlake" ;;
        esac
    elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
        case "$cpu_family" in
            23) KERNEL="znver2" ;;
            25) KERNEL="znver3" ;;
            26) KERNEL="znver4" ;;
            27) KERNEL="znver5" ;;
        esac
    fi

    case "$base_level" in
        x86-64-v4)
            if [[ "$KERNEL" == x86-64* ]]; then
                KERNEL="x86-64-v4"
            fi
            ;;
        x86-64-v3)
            if [[ "$KERNEL" == "x86-64" || "$KERNEL" == "x86-64-v2" ]]; then
                KERNEL="x86-64-v3"
            fi
            ;;
        x86-64-v2)
            if [[ "$KERNEL" == "x86-64" ]]; then
                KERNEL="x86-64-v2"
            fi
            ;;
    esac

    return 0
}

get_part_suffix() {
    local dev="$1"
    if [[ "$dev" == *"nvme"* || "$dev" == *"mmcblk"* ]]; then
        printf "p"
    else
        printf ""
    fi
}

get_partition_path() {
    local dev="$1"
    local number="$2"
    local suffix
    suffix="$(get_part_suffix "$dev")"
    printf "%s%s%s" "$dev" "$suffix" "$number"
}

format_linux_partition() {
    local part="$1"

    case "$FS_TYPE" in
        ext4)  mkfs.ext4 -F "$part" ;;
        btrfs) mkfs.btrfs -f "$part" ;;
        *)
            echo "Unsupported filesystem: $FS_TYPE"
            exit 1
            ;;
    esac
}

mount_root_filesystem() {
    local root_part="$1"

    case "$FS_TYPE" in
        ext4)
            mount "$root_part" /mnt
            ;;
        btrfs)
            mount "$root_part" /mnt
            btrfs subvolume create /mnt/@
            btrfs subvolume create /mnt/@home
            btrfs subvolume create /mnt/@swap
            sync
            umount /mnt

            mount -o rw,subvol=@ "$root_part" /mnt
            mkdir -p /mnt/home /mnt/swap
            mount -o rw,subvol=@home "$root_part" /mnt/home
            mount -o rw,subvol=@swap "$root_part" /mnt/swap
            ;;
        *)
            echo "Unsupported filesystem: $FS_TYPE"
            exit 1
            ;;
    esac
}

mount_extra_filesystem() {
    local part="$1"
    local target="$2"

    mkdir -p "/mnt${target}"

    case "$FS_TYPE" in
        ext4|btrfs)
            mount "$part" "/mnt${target}"
            ;;
        *)
            echo "Unsupported filesystem: $FS_TYPE"
            exit 1
            ;;
    esac
}

sanitize_fstab_for_btrfs() {
    [[ "$FS_TYPE" == "btrfs" ]] || return 0
    [[ -f /mnt/etc/fstab ]] || return 0

    sed -Ei '/[[:space:]]btrfs[[:space:]]/ s/(,)?subvolid=[0-9]+//g' /mnt/etc/fstab
    sed -Ei '/[[:space:]]btrfs[[:space:]]/ s/,,+/,/g; /[[:space:]]btrfs[[:space:]]/ s/,([[:space:]])/\1/g' /mnt/etc/fstab
}

partition_main_drive_uefi() {
    local dev="$1"

    sed -e 's/\s*#.*//' <<EOF2 | fdisk "$dev"
g
n
1

+512M
t
1
n
2


w
EOF2
}

partition_main_drive_bios() {
    local dev="$1"

    sed -e 's/\s*#.*//' <<EOF2 | fdisk "$dev"
g
n
1

+2M
t
4
n
2


w
EOF2
}

device_is_ssd() {
    local dev="$1"
    [[ "$(lsblk -dn -o ROTA "$dev" 2>/dev/null | head -n1)" == "0" ]]
}

prepare_main_drive() {
    local dev="$1"
    local root_part efi_part

    echo "STEP 1: Partitioning main drive..."
    wipefs -af "$dev"
    sgdisk --zap-all "$dev" >/dev/null 2>&1 || true
    partprobe "$dev" >/dev/null 2>&1 || true
    udevadm settle
    sleep 1

    if device_is_ssd "$dev"; then
        ENABLE_FSTRIM=1
    fi

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        partition_main_drive_uefi "$dev"
    else
        partition_main_drive_bios "$dev"
    fi

    partprobe "$dev" >/dev/null 2>&1 || true
    udevadm settle
    sleep 1

    root_part="$(get_partition_path "$dev" 2)"

    echo "STEP 2: Formatting main drive..."
    format_linux_partition "$root_part"

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        efi_part="$(get_partition_path "$dev" 1)"
        mkfs.fat -F 32 "$efi_part"
    fi

    echo "STEP 3: Mounting main drive..."
    mount_root_filesystem "$root_part"

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        mkdir -p /mnt/boot
        mount "$efi_part" /mnt/boot
    fi
}

prepare_extra_drives() {
    if [[ -z "${EXTRA_MOUNTS:-}" || -z "${EXTRA_MOUNTS// }" ]]; then
        return 0
    fi

    echo "STEP 3b: Preparing extra drives..."

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue

        local dev target extra_part
        dev="$(printf '%s' "$line" | cut -d: -f1)"
        target="$(printf '%s' "$line" | cut -d: -f2-)"

        [[ -z "$dev" || -z "$target" ]] && continue

        if device_is_ssd "$dev"; then
            ENABLE_FSTRIM=1
        fi

        wipefs -af "$dev"
        sgdisk --zap-all "$dev" >/dev/null 2>&1 || true
        partprobe "$dev" >/dev/null 2>&1 || true
        udevadm settle

        sed -e 's/\s*#.*//' <<EOF2 | fdisk "$dev"
g
n
1


w
EOF2

        partprobe "$dev" >/dev/null 2>&1 || true
        udevadm settle
        sleep 1

        extra_part="$(get_partition_path "$dev" 1)"
        format_linux_partition "$extra_part"
        mount_extra_filesystem "$extra_part" "$target"
    done <<< "$(printf '%b' "$EXTRA_MOUNTS")"
}

get_target_mount_available_mib() {
    local mountpoint="$1"
    local available_kib
    available_kib="$(df -Pk "$mountpoint" 2>/dev/null | awk 'NR==2 {print $4}')"
    [[ -n "$available_kib" ]] || return 1
    printf '%d\n' $((available_kib / 1024))
}

get_desired_swap_size_mib() {
    awk '/MemTotal:/ { printf "%d\n", ($2 + 1023) / 1024 }' /proc/meminfo
}

choose_swap_mountpoint() {
    local line dev target

    if [[ "$FS_TYPE" == "btrfs" ]]; then
        SWAP_MOUNTPOINT="/mnt/swap"
        SWAP_FSTAB_PATH="/swap/.swapfile"
        return 0
    fi

    if device_is_ssd "$REAL_PATH"; then
        SWAP_MOUNTPOINT="/mnt"
        SWAP_FSTAB_PATH="/.swapfile"
        return 0
    fi

    if [[ -n "${EXTRA_MOUNTS:-}" && -n "${EXTRA_MOUNTS// }" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            dev="${line%%:*}"
            target="${line#*:}"

            if device_is_ssd "$dev"; then
                SWAP_MOUNTPOINT="/mnt${target}"
                SWAP_FSTAB_PATH="${target}/.swapfile"
                return 0
            fi
        done <<< "$(printf '%b' "$EXTRA_MOUNTS")"
    fi

    SWAP_MOUNTPOINT="/mnt"
    SWAP_FSTAB_PATH="/.swapfile"
    return 0
}

compute_swap_size_mib() {
    local desired available reserve capped

    desired="$(get_desired_swap_size_mib)"
    available="$(get_target_mount_available_mib "$SWAP_MOUNTPOINT")"

    reserve=2048
    if (( available <= reserve + 512 )); then
        printf '0\n'
        return 0
    fi

    capped=$((available - reserve))
    if (( desired > capped )); then
        desired=$capped
    fi

    if (( desired < 512 )); then
        printf '0\n'
    else
        printf '%d\n' "$desired"
    fi
}

create_swap_if_needed() {
    local swap_size_mib swap_host_path

    choose_swap_mountpoint
    mkdir -p "$SWAP_MOUNTPOINT"

    swap_size_mib="$(compute_swap_size_mib)"
    if (( swap_size_mib <= 0 )); then
        echo "WARNING: Not enough free space for a swap file. Skipping swap creation."
        SWAP_MOUNTPOINT=""
        SWAP_FSTAB_PATH=""
        return 0
    fi

    swap_host_path="${SWAP_MOUNTPOINT}/.swapfile"
    echo "STEP 3c: Creating swap file (${swap_size_mib} MiB) at ${swap_host_path}..."

    if [[ "$FS_TYPE" == "btrfs" ]]; then
        chmod 700 "$SWAP_MOUNTPOINT"
        btrfs filesystem mkswapfile --size "${swap_size_mib}m" --uuid clear "$swap_host_path"
    else
        fallocate -l "${swap_size_mib}M" "$swap_host_path"
        chmod 600 "$swap_host_path"
        mkswap "$swap_host_path"
    fi
}

show_preinstall_space_debug() {
    echo "=== PRE-INSTALL SPACE STATE ==="
    df -h /mnt || true
    if [[ "$FS_TYPE" == "btrfs" ]]; then
        btrfs filesystem df /mnt || true
    fi
}

install_base_system() {
    echo "STEP 4: Installing packages (this takes time)..."
    show_preinstall_space_debug

    pacstrap -K /mnt \
        --noconfirm \
        --needed \
        $ARCH_PACKAGE_LIST \
        "linux-archium-tkg-$KERNEL" \
        "linux-archium-tkg-$KERNEL-headers" \
        linux-archium-tkg-x86-64 \
        linux-archium-tkg-x86-64-headers \
        mkinitcpio \
        qt6-multimedia-ffmpeg
}

generate_fstab() {
    echo "STEP 5: Generating fstab..."
    genfstab -U /mnt > /mnt/etc/fstab
    sanitize_fstab_for_btrfs
}

append_swap_to_fstab() {
    [[ -n "${SWAP_FSTAB_PATH:-}" ]] || return 0
    [[ -f /mnt/etc/fstab ]] || return 1

    if ! grep -Fq "${SWAP_FSTAB_PATH} none swap" /mnt/etc/fstab; then
        printf '%s none swap defaults 0 0\n' "$SWAP_FSTAB_PATH" >> /mnt/etc/fstab
    fi
}

verify_grub_config() {
    local grub_cfg linux_line root_param

    grub_cfg="/mnt/boot/grub/grub.cfg"

    [[ -f "$grub_cfg" ]] || {
        echo "Missing $grub_cfg"
        return 1
    }

    linux_line="$(grep -m1 -E '^[[:space:]]*linux[[:space:]]+/boot/' "$grub_cfg" || true)"

    root_param="$(printf '%s\n' "$linux_line" | grep -o 'root=[^[:space:]]*' || true)"

    if [[ -z "$root_param" ]]; then
        echo "❌ GRUB config does not contain root= parameter!"
        return 1
    fi

    echo "✅ GRUB root parameter detected: $root_param"
    return 0
}

write_postinstall_config() {
    echo "STEP 6: Writing post-install config..."

    {
        printf "SYSTEM_HOSTNAME=%q\n" "$SYSTEM_HOSTNAME"
        printf "USERNAME=%q\n" "$USERNAME"
        printf "ROOT_PASS=%q\n" "$ROOT_PASS"
        printf "USER_PASS=%q\n" "$USER_PASS"
        printf "REAL_PATH=%q\n" "$REAL_PATH"
        printf "SELECTED_KBL=%q\n" "$SELECTED_KBL"
        printf "SELECTED_LOCALE=%q\n" "$SELECTED_LOCALE"
        printf "REGION=%q\n" "$REGION"
        printf "CITY=%q\n" "$CITY"
        printf "AUR_PACKAGE_LIST=%q\n" "$AUR_PACKAGE_LIST"
        printf "NVIDIA_AUR_DRIVER=%q\n" "$NVIDIA_AUR_DRIVER"
        printf "KERNEL=%q\n" "$KERNEL"
        printf "FS_TYPE=%q\n" "$FS_TYPE"
        printf "GPU_VENDOR=%q\n" "$GPU_VENDOR"
        printf "GPU_STACK=%q\n" "$GPU_STACK"
        printf "ENABLE_FSTRIM=%q\n" "$ENABLE_FSTRIM"
        printf "SWAP_FSTAB_PATH=%q\n" "$SWAP_FSTAB_PATH"
    } > /mnt/root/archium-post.conf
    return 0
}

write_persistent_install_config() {
    echo "STEP 6b: Writing persistent Archium config..."

    {
        printf "SYSTEM_HOSTNAME=%q\n" "$SYSTEM_HOSTNAME"
        printf "USERNAME=%q\n" "$USERNAME"
        printf "REAL_PATH=%q\n" "$REAL_PATH"
        printf "EXTRA_MOUNTS=%q\n" "$EXTRA_MOUNTS"
        printf "ARCH_PACKAGE_LIST=%q\n" "$ARCH_PACKAGE_LIST"
        printf "AUR_PACKAGE_LIST=%q\n" "$AUR_PACKAGE_LIST"
        printf "SELECTED_KBL=%q\n" "$SELECTED_KBL"
        printf "SELECTED_LOCALE=%q\n" "$SELECTED_LOCALE"
        printf "REGION=%q\n" "$REGION"
        printf "CITY=%q\n" "$CITY"
        printf "NVIDIA_AUR_DRIVER=%q\n" "$NVIDIA_AUR_DRIVER"
        printf "FS_TYPE=%q\n" "$FS_TYPE"
        printf "GPU_VENDOR=%q\n" "$GPU_VENDOR"
        printf "GPU_STACK=%q\n" "$GPU_STACK"
        printf "ENABLE_FSTRIM=%q\n" "$ENABLE_FSTRIM"
        printf "KERNEL=%q\n" "$KERNEL"
        printf "SWAP_FSTAB_PATH=%q\n" "$SWAP_FSTAB_PATH"
    } > /mnt/etc/archium.conf

    chmod 600 /mnt/etc/archium.conf
    return 0
}

copy_configure_script() {
    echo "STEP 7: Copying configure script..."
    cp "$CONFIGURE_SCRIPT" /mnt/root/archium-configure.sh
    chmod 755 /mnt/root/archium-configure.sh
    return 0
}

run_configure_script() {
    echo "STEP 8: Running configure script inside chroot..."
    arch-chroot /mnt /root/archium-configure.sh
    return 0
}

install_kde_theme_assets() {
    local repo_kde_dir="$SCRIPT_DIR/../theme/KDE/monochrome-kde"

    # Prefer live ISO assets if present, fall back to repo copy
    local live_plasma_theme="/usr/share/plasma/desktoptheme/Monochrome"
    local live_lnf="/usr/share/plasma/look-and-feel/Monochrome"
    local live_aurorae="/usr/share/aurorae/themes/MonochromeBlur"
    local live_colors="/usr/share/color-schemes/Monochrome.colors"
    local live_gtk="/usr/share/themes/Monochrome"
    local live_konsole="/usr/share/konsole/Monochrome.colorscheme"
    local live_sddm="/usr/share/sddm/themes/monochrome"

    echo "Installing KDE theme assets..."

    if [[ -d "$live_plasma_theme" ]]; then
        mkdir -p /mnt/usr/share/plasma/desktoptheme
        cp -a "$live_plasma_theme" /mnt/usr/share/plasma/desktoptheme/
    elif [[ -d "$repo_kde_dir/plasma/desktoptheme/Monochrome" ]]; then
        mkdir -p /mnt/usr/share/plasma/desktoptheme
        cp -a "$repo_kde_dir/plasma/desktoptheme/Monochrome" /mnt/usr/share/plasma/desktoptheme/
    fi

    if [[ -d "$live_lnf" ]]; then
        mkdir -p /mnt/usr/share/plasma/look-and-feel
        cp -a "$live_lnf" /mnt/usr/share/plasma/look-and-feel/
    elif [[ -d "$repo_kde_dir/plasma/look-and-feel/Monochrome" ]]; then
        mkdir -p /mnt/usr/share/plasma/look-and-feel
        cp -a "$repo_kde_dir/plasma/look-and-feel/Monochrome" /mnt/usr/share/plasma/look-and-feel/
    fi

    if [[ -d "$live_aurorae" ]]; then
        mkdir -p /mnt/usr/share/aurorae/themes
        cp -a "$live_aurorae" /mnt/usr/share/aurorae/themes/
    elif [[ -d "$repo_kde_dir/aurorae/themes/MonochromeBlur" ]]; then
        mkdir -p /mnt/usr/share/aurorae/themes
        cp -a "$repo_kde_dir/aurorae/themes/MonochromeBlur" /mnt/usr/share/aurorae/themes/
    fi

    if [[ -f "$live_colors" ]]; then
        mkdir -p /mnt/usr/share/color-schemes
        cp -f "$live_colors" /mnt/usr/share/color-schemes/
    elif [[ -f "$repo_kde_dir/color-schemes/Monochrome.colors" ]]; then
        mkdir -p /mnt/usr/share/color-schemes
        cp -f "$repo_kde_dir/color-schemes/Monochrome.colors" /mnt/usr/share/color-schemes/
    fi

    if [[ -d "$live_gtk" ]]; then
        mkdir -p /mnt/usr/share/themes
        cp -a "$live_gtk" /mnt/usr/share/themes/
    elif [[ -d "$repo_kde_dir/gtk/Monochrome" ]]; then
        mkdir -p /mnt/usr/share/themes
        cp -a "$repo_kde_dir/gtk/Monochrome" /mnt/usr/share/themes/
    fi

    if [[ -f "$live_konsole" ]]; then
        mkdir -p /mnt/usr/share/konsole
        cp -f "$live_konsole" /mnt/usr/share/konsole/
    elif [[ -f "$repo_kde_dir/konsole/Monochrome.colorscheme" ]]; then
        mkdir -p /mnt/usr/share/konsole
        cp -f "$repo_kde_dir/konsole/Monochrome.colorscheme" /mnt/usr/share/konsole/
    fi

    if [[ -d "$live_sddm" ]]; then
        mkdir -p /mnt/usr/share/sddm/themes
        cp -a "$live_sddm" /mnt/usr/share/sddm/themes/
    elif [[ -d "$repo_kde_dir/sddm/themes/monochrome" ]]; then
        mkdir -p /mnt/usr/share/sddm/themes
        cp -a "$repo_kde_dir/sddm/themes/monochrome" /mnt/usr/share/sddm/themes/
    fi

    mkdir -p /mnt/etc/sddm.conf.d
    cat > /mnt/etc/sddm.conf.d/20-archium-theme.conf <<'EOF'
[Theme]
Current=monochrome
EOF

    chmod -R a+rX /mnt/usr/share/plasma/desktoptheme/Monochrome 2>/dev/null || true
    chmod -R a+rX /mnt/usr/share/plasma/look-and-feel/Monochrome 2>/dev/null || true
    chmod -R a+rX /mnt/usr/share/aurorae/themes/MonochromeBlur 2>/dev/null || true
    chmod -R a+rX /mnt/usr/share/themes/Monochrome 2>/dev/null || true
    chmod -R a+rX /mnt/usr/share/sddm/themes/monochrome 2>/dev/null || true
    chmod 644 /mnt/usr/share/color-schemes/Monochrome.colors 2>/dev/null || true
    chmod 644 /mnt/usr/share/konsole/Monochrome.colorscheme 2>/dev/null || true
}

install_archium_branding() {
    echo "STEP 9: Installing Archium branding..."

    local repo_theme_dir="$SCRIPT_DIR/../theme"
    local repo_arts_dir="$repo_theme_dir/arts"
    local repo_fastfetch_ascii="$repo_theme_dir/fastfetch-archium-ascii.txt"
    local repo_fastfetch_config="$repo_theme_dir/config.jsonc"

    local live_wall_dir="/usr/share/wallpapers/Archium"
    local live_logo_icon="/usr/share/icons/hicolor/128x128/apps/archium.png"
    local live_logo_pixmap="/usr/share/pixmaps/archium.png"
    local live_fastfetch_logo="/etc/fastfetch/logo.txt"
    local live_fastfetch_cfg="/etc/fastfetch/config.jsonc"

    local repo_logo="$repo_arts_dir/Logo/logo.png"

    mkdir -p /mnt/usr/share/wallpapers/Archium/contents/images

    if [[ -d "$live_wall_dir/contents/images" ]] && find "$live_wall_dir/contents/images" -mindepth 1 -print -quit | grep -q .; then
        cp -a "$live_wall_dir"/. /mnt/usr/share/wallpapers/Archium/
    elif [[ -d "$repo_arts_dir/Backgrounds" ]]; then
        cp -a "$repo_arts_dir/Backgrounds"/. /mnt/usr/share/wallpapers/Archium/contents/images/
    fi
    cat > /mnt/usr/share/wallpapers/Archium/metadata.json <<'EOF'
{
  "KPlugin": {
    "Authors": [{"Name": "Archium"}],
    "Id": "Archium",
    "License": "CC-BY-SA-4.0",
    "Name": "Archium Wallpapers"
  }
}
EOF
    chmod 644 /mnt/usr/share/wallpapers/Archium/metadata.json || true
    find /mnt/usr/share/wallpapers/Archium -type d -exec chmod 755 {} + 2>/dev/null || true
    find /mnt/usr/share/wallpapers/Archium -type f -exec chmod 644 {} + 2>/dev/null || true
    chmod 755 /mnt/usr/share/wallpapers/Archium || true
    chmod 755 /mnt/usr/share/wallpapers/Archium/contents || true
    chmod 755 /mnt/usr/share/wallpapers/Archium/contents/images || true

    mkdir -p /mnt/usr/share/icons/hicolor/128x128/apps
    mkdir -p /mnt/usr/share/pixmaps

    if [[ -f "$live_logo_icon" ]]; then
        cp -f "$live_logo_icon" /mnt/usr/share/icons/hicolor/128x128/apps/archium.png
        if [[ -f "$live_logo_pixmap" ]]; then
            cp -f "$live_logo_pixmap" /mnt/usr/share/pixmaps/archium.png
        else
            cp -f "$live_logo_icon" /mnt/usr/share/pixmaps/archium.png
        fi
    elif [[ -f "$repo_logo" ]]; then
        cp -f "$repo_logo" /mnt/usr/share/icons/hicolor/128x128/apps/archium.png
        cp -f "$repo_logo" /mnt/usr/share/pixmaps/archium.png
    fi

    chmod 644 /mnt/usr/share/icons/hicolor/128x128/apps/archium.png 2>/dev/null || true
    chmod 644 /mnt/usr/share/pixmaps/archium.png 2>/dev/null || true

    mkdir -p /mnt/etc/fastfetch
    mkdir -p /mnt/etc/skel/.config/fastfetch

    if [[ -f "$live_fastfetch_logo" ]]; then
        cp -f "$live_fastfetch_logo" /mnt/etc/fastfetch/logo.txt
    elif [[ -f "$repo_fastfetch_ascii" ]]; then
        cp -f "$repo_fastfetch_ascii" /mnt/etc/fastfetch/logo.txt
    fi

    if [[ -f "$repo_fastfetch_config" ]]; then
        cp -f "$repo_fastfetch_config" /mnt/etc/fastfetch/config.jsonc
    elif [[ -f "$live_fastfetch_cfg" ]]; then
        cp -f "$live_fastfetch_cfg" /mnt/etc/fastfetch/config.jsonc
    fi

    if [[ -f /mnt/etc/fastfetch/config.jsonc ]]; then
        cp -f /mnt/etc/fastfetch/config.jsonc /mnt/etc/skel/.config/fastfetch/config.jsonc
    fi

    chmod 755 /mnt/etc/fastfetch 2>/dev/null || true
    chmod 644 /mnt/etc/fastfetch/logo.txt 2>/dev/null || true
    chmod 644 /mnt/etc/fastfetch/config.jsonc 2>/dev/null || true
    chmod 755 /mnt/etc/skel/.config 2>/dev/null || true
    chmod 755 /mnt/etc/skel/.config/fastfetch 2>/dev/null || true
    chmod 644 /mnt/etc/skel/.config/fastfetch/config.jsonc 2>/dev/null || true

    if [[ -n "$USERNAME" && -d "/mnt/home/$USERNAME" ]]; then
        mkdir -p "/mnt/home/$USERNAME/.config/fastfetch"

        if [[ -f /mnt/etc/fastfetch/config.jsonc ]]; then
            cp -f /mnt/etc/fastfetch/config.jsonc "/mnt/home/$USERNAME/.config/fastfetch/config.jsonc"
        fi

        arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config/fastfetch"
        chmod 755 "/mnt/home/$USERNAME/.config" 2>/dev/null || true
        chmod 755 "/mnt/home/$USERNAME/.config/fastfetch" 2>/dev/null || true
        chmod 644 "/mnt/home/$USERNAME/.config/fastfetch/config.jsonc" 2>/dev/null || true
    fi
    install_kde_theme_assets
    return 0
}

prepare_temporary_repo_for_chroot() {
    echo "STEP 7b: Preparing temporary Archium repo for chroot..."

    mkdir -p /mnt/opt/archium_repo
    mount --bind /opt/archium_repo /mnt/opt/archium_repo

    rm -f /mnt/etc/resolv.conf
    cp -L /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true
    mount --bind /etc/resolv.conf /mnt/etc/resolv.conf

    if ! grep -q '^\[archium\]$' /mnt/etc/pacman.conf; then
        cat >> /mnt/etc/pacman.conf <<'EOF2'

[archium]
SigLevel = Optional TrustAll
Server = file:///opt/archium_repo
EOF2
    fi

    return 0
}

cleanup_temporary_repo_for_chroot() {
    umount -lf /mnt/etc/resolv.conf 2>/dev/null || true
    umount -lf /mnt/opt/archium_repo 2>/dev/null || true
    rmdir /mnt/opt/archium_repo 2>/dev/null || true
    return 0
}

perform_install() {
    trap 'cleanup_temporary_repo_for_chroot' RETURN

    prepare_main_drive "$REAL_PATH"
    prepare_extra_drives
    install_base_system
    create_swap_if_needed
    generate_fstab
    append_swap_to_fstab
    write_postinstall_config
    write_persistent_install_config
    copy_configure_script
    prepare_temporary_repo_for_chroot
    run_configure_script
    install_archium_branding
    verify_grub_config || echo "⚠️ Skipping GRUB validation"
}

main() {
    get_dialog_size
    load_installer_config
    detect_boot_mode
    detect_kernel_target

    perform_install 2>&1 | dialog --clear --backtitle "$TITLE" --title "$INSTALL_TITLE" --programbox "$DIALOG_H" "$DIALOG_W"

    dialog --clear --backtitle "$TITLE" --title "$SUCCESS_TITLE" \
    --yesno "Archium installation completed successfully!\n\nReboot now?" 10 50

    clear

    if [[ $? -eq 0 ]]; then
        echo "Rebooting system..."
        sync
        umount -R /mnt 2>/dev/null || true
        reboot
    else
        echo "Installation finished. You can reboot manually."
    fi
}

main
