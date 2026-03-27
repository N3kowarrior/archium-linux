#!/bin/bash
set -eEuo pipefail

source /root/archium-post.conf

cleanup_temporary_repo_config() {
    if grep -q '^\[archium\]$' /etc/pacman.conf; then
        sed -i '/^\[archium\]$/,/^$/d' /etc/pacman.conf
    fi
}

enable_multilib_and_pacman_tweaks() {
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
    sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
}

configure_identity() {
    echo "$SYSTEM_HOSTNAME" > /etc/hostname

    ln -sf "/usr/share/zoneinfo/$REGION/$CITY" /etc/localtime
    hwclock --systohc

    SELECTED_LOCALE="$(printf '%s' "$SELECTED_LOCALE" | awk '{print $1}')"
    sed -i "s/^#$SELECTED_LOCALE/$SELECTED_LOCALE/" /etc/locale.gen
    locale-gen
    echo "LANG=$SELECTED_LOCALE" > /etc/locale.conf
}


configure_users() {
    id -u "$USERNAME" >/dev/null 2>&1 || useradd -m -G wheel "$USERNAME"
    echo "root:$ROOT_PASS" | chpasswd
    echo "$USERNAME:$USER_PASS" | chpasswd
}

configure_keyboard() {
    local primary_kbl xkb_layout
    primary_kbl="$(printf '%s' "$SELECTED_KBL" | awk '{print $1}')"
    [[ -n "$primary_kbl" ]] || primary_kbl="us"

    if localectl list-keymaps | grep -Fxq "$primary_kbl"; then
        echo "KEYMAP=$primary_kbl" > /etc/vconsole.conf
        localectl set-keymap "$primary_kbl" || true
    else
        echo "KEYMAP=us" > /etc/vconsole.conf
        localectl set-keymap us || true
        primary_kbl='us'
    fi

    xkb_layout="$(map_console_keymap_to_xkb "$primary_kbl")"
    localectl set-x11-keymap "$xkb_layout" pc105 || true
}

configure_nvidia_graphics() {
    echo "Applying NVIDIA graphics configuration..."

    mkdir -p /etc/modprobe.d /etc/environment.d

    cat > /etc/modprobe.d/nvidia.conf <<'EOF_NVIDIA'
options nvidia_drm modeset=1
EOF_NVIDIA

    cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF_NOUVEAU'
blacklist nouveau
options nouveau modeset=0
EOF_NOUVEAU

    cat > /etc/environment.d/90-archium-nvidia.conf <<'EOF_ENV'
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
LIBVA_DRIVER_NAME=nvidia
EOF_ENV

    if grep -q '^MODULES=' /etc/mkinitcpio.conf; then
        sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    else
        echo 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)' >> /etc/mkinitcpio.conf
    fi
}

configure_amd_graphics() {
    mkdir -p /etc/environment.d
    cat > /etc/environment.d/90-archium-amd.conf <<'EOF_AMD'
AMD_VULKAN_ICD=RADV
EOF_AMD
}

configure_intel_graphics() {
    mkdir -p /etc/environment.d
    cat > /etc/environment.d/90-archium-intel.conf <<'EOF_INTEL'
# Intel graphics uses Mesa defaults on Archium.
EOF_INTEL
}

configure_generic_graphics() {
    true
}


normalize_locale_value() {
    printf '%s' "${1:-en_US.UTF-8}" | awk '{print $1}'
}

locale_to_language_chain() {
    local locale base lang
    locale="$(normalize_locale_value "$1")"
    base="${locale%%.*}"
    lang="${base%%_*}"

    if [[ -n "$lang" && "$lang" != "$base" ]]; then
        printf '%s:%s:en_US' "$base" "$lang"
    elif [[ -n "$base" ]]; then
        printf '%s:en_US' "$base"
    else
        printf 'en_US:en'
    fi
}

infer_xkb_layout_from_locale() {
    local locale base lang
    locale="$(normalize_locale_value "$1")"
    base="${locale%%.*}"
    lang="${base%%_*}"

    case "$base" in
        cs_CZ) printf 'cz' ;;
        en_GB) printf 'gb' ;;
        pt_BR) printf 'br' ;;
        zh_TW) printf 'tw' ;;
        zh_CN) printf 'cn' ;;
        *)
            case "$lang" in
                cs) printf 'cz' ;;
                da) printf 'dk' ;;
                en) printf 'us' ;;
                ja) printf 'jp' ;;
                nb|nn) printf 'no' ;;
                pt) printf 'pt' ;;
                sv) printf 'se' ;;
                zh) printf 'cn' ;;
                *) printf '%s' "${lang:-us}" ;;
            esac
            ;;
    esac
}

map_console_keymap_to_xkb() {
    local keymap guess
    keymap="$(printf '%s' "${1:-us}" | awk '{print $1}')"
    [[ -n "$keymap" ]] || keymap='us'

    if command -v localectl >/dev/null 2>&1 && localectl list-x11-keymap-layouts 2>/dev/null | grep -Fxq "$keymap"; then
        printf '%s' "$keymap"
        return 0
    fi

    case "$keymap" in
        us*|en*) guess='us' ;;
        gb*|uk*) guess='gb' ;;
        cz*|qwertz-cz*|qwerty-cz*) guess='cz' ;;
        sk*) guess='sk' ;;
        de*) guess='de' ;;
        fr*) guess='fr' ;;
        es*) guess='es' ;;
        it*) guess='it' ;;
        pl*) guess='pl' ;;
        pt-br*|br-abnt*|br*) guess='br' ;;
        pt*) guess='pt' ;;
        ru*) guess='ru' ;;
        ua*|uk*ua*) guess='ua' ;;
        jp*) guess='jp' ;;
        tr*) guess='tr' ;;
        hu*) guess='hu' ;;
        ro*) guess='ro' ;;
        fi*) guess='fi' ;;
        se*|sv*) guess='se' ;;
        dk*) guess='dk' ;;
        no*) guess='no' ;;
        nl*) guess='nl' ;;
        be*) guess='be' ;;
        ch*) guess='ch' ;;
        latam*) guess='latam' ;;
        *) guess="$(infer_xkb_layout_from_locale "$SELECTED_LOCALE")" ;;
    esac

    if command -v localectl >/dev/null 2>&1 && localectl list-x11-keymap-layouts 2>/dev/null | grep -Fxq "$guess"; then
        printf '%s' "$guess"
    else
        printf 'us'
    fi
}

configure_plasma_locale_and_keyboard() {
    local locale lang_chain xkb_layout xkb_model
    locale="$(normalize_locale_value "$SELECTED_LOCALE")"
    lang_chain="$(locale_to_language_chain "$locale")"
    xkb_layout="$(map_console_keymap_to_xkb "$SELECTED_KBL")"
    xkb_model='pc105'

    mkdir -p /etc/skel/.config

    cat > /etc/skel/.config/plasma-localerc <<EOF
[Formats]
LANG=$locale

[Translations]
LANGUAGE=$lang_chain
EOF

    cat > /etc/skel/.config/plasma-locale-settings.sh <<EOF
#!/bin/sh
# Generated by Archium installer
export LANG=$locale
export LANGUAGE=$lang_chain
EOF
    chmod 644 /etc/skel/.config/plasma-localerc
    chmod 755 /etc/skel/.config/plasma-locale-settings.sh

    cat > /etc/skel/.config/kxkbrc <<EOF
[Layout]
DisplayNames=$xkb_layout
LayoutList=$xkb_layout
Model=$xkb_model
Options=
ResetOldOptions=true
ShowFlag=true
ShowSingle=false
SwitchMode=Global
Use=true
EOF
    chmod 644 /etc/skel/.config/kxkbrc

    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$xkb_layout"
    Option "XkbModel" "$xkb_model"
EndSection
EOF

    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/10-archium-locale.conf <<EOF
[General]
GreeterEnvironment=LANG=$locale,LANGUAGE=$lang_chain
EOF

    if [[ -n "$USERNAME" && -d "/home/$USERNAME" ]]; then
        install -d -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.config"
        install -o "$USERNAME" -g "$USERNAME" -m 644 /etc/skel/.config/plasma-localerc "/home/$USERNAME/.config/plasma-localerc"
        install -o "$USERNAME" -g "$USERNAME" -m 755 /etc/skel/.config/plasma-locale-settings.sh "/home/$USERNAME/.config/plasma-locale-settings.sh"
        install -o "$USERNAME" -g "$USERNAME" -m 644 /etc/skel/.config/kxkbrc "/home/$USERNAME/.config/kxkbrc"
    fi
}

configure_gpu_stack() {
    case "${GPU_STACK:-generic}" in
        nvidia) configure_nvidia_graphics ;;
        amd)    configure_amd_graphics ;;
        intel)  configure_intel_graphics ;;
        nouveau|generic|*) configure_generic_graphics ;;
    esac
}

configure_system_defaults() {
    echo "vm.swappiness = 10" > /etc/sysctl.d/99-swappiness.conf
    sed -i "s/^#MAKEFLAGS.*/MAKEFLAGS=\"-j\$(nproc)\"/" /etc/makepkg.conf || true
}

configure_steam_tweak() {
    install -d -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.steam/steam"
    printf 'unShaderBackgroundProcessingThreads %s\n' "$(nproc)" > "/home/$USERNAME/.steam/steam/steam_dev.cfg"
    chown "$USERNAME:$USERNAME" "/home/$USERNAME/.steam/steam/steam_dev.cfg"
}

configure_initramfs() {
    mkinitcpio -P
}

configure_bootloader() {
    if grep -q '^GRUB_DISTRIBUTOR=' /etc/default/grub; then
        sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Archium"/' /etc/default/grub
    else
        echo 'GRUB_DISTRIBUTOR="Archium"' >> /etc/default/grub
    fi

    sync
    partprobe || true
    udevadm settle
    sleep 2

    if [[ -d /sys/firmware/efi ]]; then
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Archium
    else
        grub-install --target=i386-pc "$REAL_PATH"
    fi

    grub-mkconfig -o /boot/grub/grub.cfg
}

enable_base_services() {
    systemctl enable sddm
    systemctl enable NetworkManager
    systemctl enable ufw

    if [[ "${ENABLE_FSTRIM:-0}" == "1" ]]; then
        systemctl enable fstrim.timer
    fi
}

wait_for_basic_network() {
    local tries="${1:-12}"
    local delay="${2:-5}"
    local i

    for ((i=1; i<=tries; i++)); do
        echo "Waiting for network... attempt $i/$tries"

        if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && \
           getent hosts archlinux.org >/dev/null 2>&1; then
            return 0
        fi

        sleep "$delay"
    done

    return 1
}

wait_for_aur_rpc() {
    local tries="${1:-12}"
    local delay="${2:-5}"
    local i

    for ((i=1; i<=tries; i++)); do
        echo "Waiting for AUR RPC... attempt $i/$tries"

        if curl -4 -fsS --max-time 10 \
            'https://aur.archlinux.org/rpc?v=5&type=search&arg=paru' \
            >/dev/null 2>&1; then
            return 0
        fi

        sleep "$delay"
    done

    return 1
}

retry_pacman() {
    local max_attempts="${1:-4}"
    shift
    local attempt=1

    while (( attempt <= max_attempts )); do
        echo "Running pacman attempt $attempt/$max_attempts: $*"

        if "$@"; then
            return 0
        fi

        echo "pacman failed."

        if (( attempt == max_attempts )); then
            break
        fi

        echo "Testing network before retry..."
        wait_for_basic_network 12 5 || true
        sleep 3
        ((attempt++))
    done

    return 1
}

retry_paru_as_user() {
    local user="$1"
    local max_attempts="${2:-4}"
    shift 2
    local attempt=1

    while (( attempt <= max_attempts )); do
        echo "Running paru attempt $attempt/$max_attempts: $*"

        if sudo -u "$user" "$@"; then
            return 0
        fi

        echo "paru failed."

        if (( attempt == max_attempts )); then
            break
        fi

        echo "Testing AUR connectivity before retry..."
        wait_for_basic_network 12 5 || true
        wait_for_aur_rpc 12 5 || true
        sleep 3
        ((attempt++))
    done

    return 1
}

install_repo_and_aur_packages() {
    local aur_list pkg
    trap 'rm -f /etc/sudoers.d/10-installer' RETURN

    echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-installer

    if ! wait_for_basic_network 12 5; then
        echo "WARNING: Network is not ready. Skipping repo/AUR packages."
        return 0
    fi

    retry_pacman 4 pacman -Sy --noconfirm || {
        echo "WARNING: pacman sync failed after retries."
        return 0
    }

    retry_pacman 4 pacman -S --noconfirm --needed paru || {
        echo "WARNING: paru installation failed after retries."
        return 0
    }

    aur_list="$(printf '%s' "$AUR_PACKAGE_LIST" | tr -d '"')"
    if [[ -n "${NVIDIA_AUR_DRIVER:-}" ]]; then
        aur_list="$NVIDIA_AUR_DRIVER $aur_list"
    fi

    [[ -n "${aur_list// }" ]] || return 0

    if ! wait_for_aur_rpc 12 5; then
        echo "WARNING: AUR RPC is unreachable. Skipping AUR packages."
        return 0
    fi

    for pkg in $aur_list; do
        echo "Installing package: $pkg"

        if ! retry_paru_as_user "$USERNAME" 4 paru -S --noconfirm --needed "$pkg"; then
            echo "WARNING: Failed to install AUR package: $pkg"
            echo "WARNING: Continuing without it."
        fi
    done
}

configure_package_related_services() {
    local aur_list
    aur_list="$(printf '%s' "$AUR_PACKAGE_LIST" | tr -d '"')"
    if [[ -n "$NVIDIA_AUR_DRIVER" ]]; then
        aur_list="$NVIDIA_AUR_DRIVER $aur_list"
    fi

    if echo "$aur_list" | grep -qw "winboat-bin"; then
        systemctl enable docker.service
        usermod -aG docker "$USERNAME"
    fi

    if echo "$aur_list" | grep -qw "bluez"; then
        systemctl enable bluetooth.service
    fi

    if echo "$aur_list" | grep -qw "cups"; then
        systemctl enable cups.service
    fi

    if echo "$aur_list" | grep -qw "reflector"; then
        reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
        mkdir -p /etc/xdg/reflector
        printf '%s\n' \
            '--save /etc/pacman.d/mirrorlist' \
            '--protocol https' \
            '--latest 10' \
            '--sort rate' > /etc/xdg/reflector/reflector.conf
        systemctl enable reflector.timer
    fi

    if echo "$aur_list" | grep -qw "piper"; then
        pacman -S --noconfirm --needed libratbag
        systemctl enable libratbag.service
    fi

    if echo "$aur_list" | grep -qE '(^|[[:space:]])(lact|lact-git)($|[[:space:]])'; then
        systemctl enable lactd.service

        if [[ -f /etc/default/grub ]] && ! grep -q "amdgpu.ppfeaturemask" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="amdgpu.ppfeaturemask=0xffffffff /' /etc/default/grub
        fi
    fi

    if [[ "${GPU_STACK:-generic}" == "nvidia" ]] && echo "$aur_list" | grep -qE '(^|[[:space:]])(nvidia_oc|gwe)($|[[:space:]])'; then
        command -v nvidia-xconfig >/dev/null 2>&1 && \
            nvidia-xconfig --cool-bits=28 --allow-empty-initial-configuration || true

        if echo "$aur_list" | grep -qw "nvidia_oc"; then
            systemctl enable nvidia_oc.service 2>/dev/null || true
        fi
    fi

    if echo "$aur_list" | grep -qw "amdgpu-fan"; then
        systemctl enable amdgpu-fan.service
    fi
}

write_identity_files() {
    printf 'NAME="Archium Linux"\nPRETTY_NAME="Archium Linux"\nID=archium\nBUILD_ID=rolling\nANSI_COLOR="38;2;23;147;209"\nHOME_URL="https://github.com/N3kowarrior/archium-linux"\nDOCUMENTATION_URL="https://github.com/N3kowarrior/archium-linux"\nSUPPORT_URL="https://github.com/N3kowarrior/archium-linux/issues"\nBUG_REPORT_URL="https://github.com/N3kowarrior/archium-linux/issues"\nLOGO=archium\n' > /etc/os-release
    printf 'DISTRIB_ID=Archium\nDISTRIB_RELEASE=rolling\nDISTRIB_DESCRIPTION="Archium Linux"\n' > /etc/lsb-release
    echo "Archium Linux \\r (\\l)" > /etc/issue
}

cleanup_configure_handoff() {
    rm -f /root/archium-post.conf
}

configure_hibernate_for_swapfile() {
    local swap_abs swap_real swap_source swap_uuid resume_offset first_extent

    swap_abs="${SWAP_FSTAB_PATH:-/.swapfile}"

    # Always install sane sleep defaults, even if hibernate setup fails
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/50-archium-sleep.conf <<'EOF'
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore
HandleSuspendKey=suspend
HandleHibernateKey=hibernate
HandlePowerKey=poweroff
IdleAction=ignore
EOF

    [[ "$swap_abs" == /* ]] || return 0
    [[ -f "$swap_abs" ]] || return 0

    swap_real="$(realpath "$swap_abs")"
    swap_source="$(findmnt -no SOURCE -T "$swap_real" 2>/dev/null || true)"
    swap_uuid="$(blkid -s UUID -o value "$swap_source" 2>/dev/null || true)"

    [[ -n "$swap_source" ]] || return 1
    [[ -n "$swap_uuid" ]] || return 1

    if [[ "$FS_TYPE" == "btrfs" ]]; then
        resume_offset="$(btrfs inspect-internal map-swapfile -r "$swap_real" 2>/dev/null || true)"
    else
        first_extent="$(filefrag -v "$swap_real" 2>/dev/null | awk '$1 ~ /^ *0:$/ {print $4; exit}')"
        resume_offset="$(printf '%s' "$first_extent" | sed 's/\.\.$//; s/\.$//')"
    fi

    [[ -n "$resume_offset" ]] || return 1

    # Ensure resume hook exists exactly once
    if grep -q '^HOOKS=' /etc/mkinitcpio.conf; then
        if ! sed 's/[()]/ /g' /etc/mkinitcpio.conf | grep -Eq '(^|[[:space:]])resume([[:space:]]|$)'; then
            sed -i '/^HOOKS=/ s/)/ resume)/' /etc/mkinitcpio.conf
        fi
    else
        echo 'HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck resume)' >> /etc/mkinitcpio.conf
    fi

    # Normalize GRUB_CMDLINE_LINUX_DEFAULT
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
        sed -i -E 's/[[:space:]]+resume=UUID=[^"[:space:]]*//g; s/[[:space:]]+resume_offset=[^"[:space:]]*//g' /etc/default/grub
        sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"(.*)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 resume=UUID=$swap_uuid resume_offset=$resume_offset\"|" /etc/default/grub
    else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"resume=UUID=$swap_uuid resume_offset=$resume_offset\"" >> /etc/default/grub
    fi

    return 0
}

configure_journald_limits() {
    mkdir -p /etc/systemd/journald.conf.d

    cat > /etc/systemd/journald.conf.d/50-archium-journal-size.conf <<'EOF'
[Journal]
SystemMaxUse=100M
EOF
}

prefer_ipv4_over_ipv6() {
    if ! grep -qxF 'precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null; then
        echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
    fi
}

main() {
    prefer_ipv4_over_ipv6
    enable_multilib_and_pacman_tweaks
    configure_identity
    configure_users
    configure_keyboard
    configure_plasma_locale_and_keyboard
    configure_system_defaults
    configure_journald_limits
    configure_steam_tweak
    install_repo_and_aur_packages
    configure_gpu_stack
    if ! configure_hibernate_for_swapfile; then
    echo "WARNING: Hibernate could not be configured automatically."
    fi
    configure_initramfs
    configure_package_related_services
    configure_bootloader
    enable_base_services
    write_identity_files
    cleanup_configure_handoff
}

main
