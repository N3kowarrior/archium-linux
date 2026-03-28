#!/bin/bash
set -eEuo pipefail

# =========================================================
# Archium Installer - Setup Phase
# =========================================================

# ---------------------------
# Theming / UI options
# ---------------------------
export DIALOGRC="${DIALOGRC:-/etc/archium-dialogrc}"

TITLE="Archium Linux Installer"
WELCOME_TITLE=" Welcome "
NETWORK_TITLE=" Network Setup "
ERROR_TITLE=" Error "
SUMMARY_TITLE=" Confirm Installation "

# ---------------------------
# Dialog sizing
# ---------------------------
DIALOG_H=12
DIALOG_W=68
MENU_H=18
MENU_W=70
MENU_LIST_H=10

# ---------------------------
# Script self-location
# ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/archium-install.sh"

# ---------------------------
# Global config variables
# ---------------------------
CPU_VENDOR=""
USERNAME=""
PASS1=""
ROOT_PASS1=""
SYSTEM_HOSTNAME=""
SELECTED_LOCALE=""
REGION=""
CITY=""
SELECTED_KBL=""
GPU_VENDOR=""
UCODE=""
VIDEO_PKGS=""
NVIDIA_AUR_DRIVER=""
REAL_PATH=""
EXTRA_MOUNTS=""
FS_TYPE="ext4"
ARCH_PACKAGE_LIST=""
AUR_PACKAGE_LIST=""
SELECTED_PATHS=()
SORTED_SSDS=()
SORTED_HDDS=()
GPU_STACK="generic"

# ---------------------------
# UI helpers
# ---------------------------
safe_exit() {
    clear
    echo "Installer exited before any changes were made."
    exit 0
}
confirm_exit() {
    dialog --clear --backtitle "$TITLE" --title " Exit Installer " \
        --yesno "Exit the installer now?\n\nNo changes have been made yet." 8 60
}
get_dialog_size() {
    local rows cols

    rows=$(tput lines)
    cols=$(tput cols)

    # fallback safety
    [[ -z "$rows" || "$rows" -lt 20 ]] && rows=24
    [[ -z "$cols" || "$cols" -lt 60 ]] && cols=80

    # use ~80% of terminal
    DIALOG_H=$((rows * 80 / 100))
    DIALOG_W=$((cols * 80 / 100))

    MENU_H=$((rows * 85 / 100))
    MENU_W=$((cols * 85 / 100))
    MENU_LIST_H=$((MENU_H - 8))
    return 0
}

show_msg() {
    local title="$1"
    local text="$2"
    dialog --clear --backtitle "$TITLE" --title "$title" \
        --msgbox "$text" "$DIALOG_H" "$DIALOG_W"
    return 0
}

show_error() {
    local text="$1"
    dialog --clear --backtitle "$TITLE" --title "$ERROR_TITLE" \
        --msgbox "$text" "$DIALOG_H" "$DIALOG_W"
}
trap 'show_error "Setup crashed near line $LINENO."' ERR

# ---------------------------
# Basic detection
# ---------------------------
detect_cpu_vendor() {
    CPU_VENDOR="$(LANG=C lscpu | awk -F: '/Vendor ID/ {gsub(/^ +/,"",$2); print $2}')"
}

detect_ucode_package() {
    if [[ "$CPU_VENDOR" == *"Intel"* ]]; then
        UCODE="intel-ucode"
    elif [[ "$CPU_VENDOR" == *"AMD"* ]]; then
        UCODE="amd-ucode"
    else
        UCODE=""
    fi
}

detect_gpu_and_packages() {
    local gpu_lines
    gpu_lines="$(lspci 2>/dev/null | grep -Ei 'VGA|3D' || true)"

    GPU_VENDOR=""
    if grep -qi 'nvidia' <<< "$gpu_lines"; then
        GPU_VENDOR="nvidia"
    elif grep -qi 'amd\|advanced micro devices\|ati' <<< "$gpu_lines"; then
        GPU_VENDOR="amd"
    elif grep -qi 'intel' <<< "$gpu_lines"; then
        GPU_VENDOR="intel"
    fi

    GPU_STACK="generic"
    NVIDIA_AUR_DRIVER=""
    VIDEO_PKGS="mesa lib32-mesa"

    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
        local gpu_driver="" utils_pkg=""
        gpu_driver="$(
            dialog --clear --stdout --backtitle "$TITLE" --title " NVIDIA Selection " \
                --menu "NVIDIA GPU detected. Select driver based on architecture:" 15 75 6 \
                "nvidia-open-dkms" "Blackwell+ & Turing-Ada (Recommended Repo)" \
                "nvidia-580xx-dkms" "Maxwell to Volta (AUR)" \
                "nvidia-470xx-dkms" "Kepler (AUR)" \
                "nvidia-390xx-dkms" "Fermi (AUR)" \
                "mesa" "Nouveau / Mesa"
        )" || gpu_driver="mesa"

        case "$gpu_driver" in
            nvidia-open-dkms)
                GPU_STACK="nvidia"
                VIDEO_PKGS="nvidia-open-dkms nvidia-utils lib32-nvidia-utils"
                ;;
            *xx-dkms)
                GPU_STACK="nvidia"
                utils_pkg="${gpu_driver%-dkms}-utils"
                NVIDIA_AUR_DRIVER="$gpu_driver $utils_pkg lib32-$utils_pkg"
                VIDEO_PKGS=""
                ;;
            mesa|*)
                GPU_STACK="nouveau"
                VIDEO_PKGS="mesa lib32-mesa"
                ;;
        esac

    elif [[ "$GPU_VENDOR" == "amd" ]]; then
        GPU_STACK="amd"
        show_msg " GPU Detected " "AMD Radeon detected.\nInstalling Mesa and RADV drivers."
        VIDEO_PKGS="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon"

    elif [[ "$GPU_VENDOR" == "intel" ]]; then
        GPU_STACK="intel"
        show_msg " GPU Detected " "Intel graphics detected.\nInstalling Mesa and Vulkan Intel drivers."
        VIDEO_PKGS="mesa lib32-mesa vulkan-intel lib32-vulkan-intel"
    fi
}

# ---------------------------
# Welcome / network
# ---------------------------
show_welcome() {
    show_msg "$WELCOME_TITLE" "\nWelcome to Archium Linux.\n\nA minimalist, opinionated Arch-based system.\n\nPress ENTER to configure your system."
}

network_online() {
    timeout 5 curl -I https://archlinux.org >/dev/null 2>&1
}

dns_working() {
    timeout 4 getent hosts archlinux.org >/dev/null 2>&1
}

ensure_network() {
    while true; do
        if network_online; then
            if ! dns_working; then
                show_msg " DNS Warning " "Internet seems to work, but DNS lookup for archlinux.org failed.\n\nThe installer will continue, but package downloads may fail until DNS is fixed."
            fi
            return 0
        fi

        local wifi_iface
        wifi_iface="$(iw dev | awk '$1=="Interface"{print $2; exit}')"

        if ! dialog --clear --backtitle "$TITLE" --title "$NETWORK_TITLE" \
            --yesno "No internet connection detected.\n\nStart Wi-Fi setup (iwctl)?" 8 50
        then
            continue
        fi

        if [[ -n "$wifi_iface" ]]; then
            show_msg " Wi-Fi Help " "Inside iwctl, run:\n\nstation $wifi_iface scan\nstation $wifi_iface get-networks\nstation $wifi_iface connect <SSID>\n\nThen exit with Ctrl+D"
        else
            show_msg " Wi-Fi Help " "No Wi-Fi interface auto-detected.\n\nOpen iwctl and connect manually.\n\nExit with Ctrl+D when done."
        fi

        iwctl || true

        if network_online; then
            if ! dns_working; then
                show_msg " DNS Warning " "Internet seems to work, but DNS lookup for archlinux.org failed.\n\nThe installer will continue, but package downloads may fail until DNS is fixed."
            fi
            return 0
        fi

        show_error "Still no internet connection detected."
    done
}

# ---------------------------
# Locale / timezone / keyboard
# ---------------------------
show_warn() {
    local text="$1"
    dialog --clear --backtitle "$TITLE" --title " Warning " \
        --msgbox "$text" "$DIALOG_H" "$DIALOG_W"
    return 0
}

apply_live_keyboard_layout() {
    local keymap="$1"
    local tty_path=""

    set +e

    if ! command -v loadkeys >/dev/null 2>&1; then
        show_warn "The live environment does not provide 'loadkeys'.\n\nThe selected keyboard layout ('$keymap') will still be saved for the installed system."
        set -e
        return 0
    fi

    tty_path="$(tty 2>/dev/null)"

    if [[ ! "$tty_path" =~ ^/dev/tty[0-9]+$ ]]; then
        show_warn "The installer is not running on a real Linux console.\n\nThe selected keyboard layout ('$keymap') cannot be applied live here, but it will still be saved for the installed system."
        set -e
        return 0
    fi

    if ! loadkeys "$keymap" >/dev/null 2>&1; then
        show_warn "Failed to apply keyboard layout '$keymap' in the live environment.\n\nThe installer will continue and the layout will still be saved for the installed system."
        set -e
        return 0
    fi

    set -e
    return 0
}

select_keyboard_layouts() {
    local items=()
    local fallback_common=(us cz sk de fr es it pl)
    local keymaps=()
    local keymap
    local choice
    local status

    if command -v localectl >/dev/null 2>&1 && localectl list-keymaps >/dev/null 2>&1; then
        mapfile -t keymaps < <(localectl list-keymaps | tr -s '[:space:]' '\n' | sed '/^$/d')
    fi

    [[ ${#keymaps[@]} -gt 0 ]] || keymaps=("${fallback_common[@]}")

    for keymap in "${keymaps[@]}"; do
        items+=("$keymap" "Console keymap")
    done

    while true; do
        if choice="$(
            dialog --clear --stdout --backtitle "$TITLE" --title " Keyboard Configuration " \
                --menu "Select keyboard layout for installer and installed system:" \
                "$MENU_H" "$MENU_W" "$MENU_LIST_H" \
                "${items[@]}"
        )"; then
            status=0
        else
            status=$?
        fi

        case "$status" in
            0)
                [[ -n "$choice" ]] || continue
                SELECTED_KBL="$choice"
                apply_live_keyboard_layout "$SELECTED_KBL"
                return 0
                ;;
            1|255)
                if confirm_exit; then
                    safe_exit
                else
                    continue
                fi
                ;;
            *)
                continue
                ;;
        esac
    done
}

select_timezone() {
    local region_items=()
    local city_items=()
    local region city status

    while read -r region; do
        region_items+=("$region" "Region")
    done < <(timedatectl list-timezones | awk -F/ '{print $1}' | uniq)

    while true; do
        if REGION="$(
            dialog --clear --stdout --backtitle "$TITLE" --title " Timezone " \
                --menu "Select your Region:" "$MENU_H" "$MENU_W" "$MENU_LIST_H" \
                "${region_items[@]}"
        )"; then
            status=0
        else
            status=$?
        fi

        case "$status" in
            0)
                [[ -n "$REGION" ]] || continue
                break
                ;;
            1|255)
                if confirm_exit; then
                    safe_exit
                else
                    continue
                fi
                ;;
            *)
                continue
                ;;
        esac
    done

    while true; do
        city_items=()
        while read -r city; do
            city_items+=("$city" "Timezone")
        done < <(timedatectl list-timezones | awk -F/ -v r="$REGION" '
            $1 == r {
                sub("^[^/]*/", "", $0)
                print
            }
        ')

        if CITY="$(
            dialog --clear --stdout --backtitle "$TITLE" --title " Timezone " \
                --menu "Select your City / Zone:" "$MENU_H" "$MENU_W" "$MENU_LIST_H" \
                "${city_items[@]}"
        )"; then
            status=0
        else
            status=$?
        fi

        case "$status" in
            0)
                [[ -n "$CITY" ]] || continue
                return 0
                ;;
            1|255)
                if confirm_exit; then
                    safe_exit
                else
                    continue
                fi
                ;;
            *)
                continue
                ;;
        esac
    done
}

select_locale() {
    local items=()
    local locale
    local choice
    local status

    while read -r locale _; do
        [[ -n "$locale" ]] && items+=("$locale" "Locale")
    done < <(grep "UTF-8" /etc/locale.gen 2>/dev/null | sed 's/^#//g' || true)

    [[ ${#items[@]} -gt 0 ]] || items=("en_US.UTF-8" "Fallback locale")

    while true; do
        if choice="$(
            dialog --clear --stdout --backtitle "$TITLE" --title " System Locale " \
                --menu "Choose your primary system language:" \
                "$MENU_H" "$MENU_W" "$MENU_LIST_H" \
                "${items[@]}"
        )"; then
            status=0
        else
            status=$?
        fi

        case "$status" in
            0)
                [[ -n "$choice" ]] || continue
                SELECTED_LOCALE="$choice"
                return 0
                ;;
            1|255)
                if confirm_exit; then
                    safe_exit
                else
                    continue
                fi
                ;;
            *)
                continue
                ;;
        esac
    done
}

# ---------------------------
# User / passwords / SYSTEM_HOSTNAME
# ---------------------------
collect_user_info() {
    local pass2 root_pass2 status

    while true; do
        if USERNAME="$(
            dialog --clear --stdout --backtitle "$TITLE" --title " User Account " \
                --inputbox "Enter Username:" 0 0 "${USERNAME:-archiumuser}"
        )"; then
            status=0
        else
            status=$?
        fi

        case "$status" in
            0)
                [[ -n "$USERNAME" ]] || USERNAME="archiumuser"
                ;;
            1|255)
                if confirm_exit; then
                    safe_exit
                else
                    continue
                fi
                ;;
            *)
                continue
                ;;
        esac

        while true; do
            if PASS1="$(
                dialog --clear --stdout --backtitle "$TITLE" --title " Password " \
                    --passwordbox "Enter password for $USERNAME:" 0 0
            )"; then
                status=0
            else
                status=$?
            fi
            [[ "$status" -eq 0 ]] || continue

            if pass2="$(
                dialog --clear --stdout --backtitle "$TITLE" --title " Password Verification " \
                    --passwordbox "Confirm password:" 0 0
            )"; then
                status=0
            else
                status=$?
            fi
            [[ "$status" -eq 0 ]] || continue

            if [[ "$PASS1" == "$pass2" && -n "$PASS1" ]]; then
                break
            fi

            show_error "Passwords do not match or are empty. Try again."
        done

        while true; do
            if dialog --clear --backtitle "$TITLE" --title " Root Security " \
                --yesno "Would you like to set a unique ROOT password?\n\nSelect 'No' to use the user password for root." 8 60
            then
                while true; do
                    if ROOT_PASS1="$(
                        dialog --clear --stdout --backtitle "$TITLE" --title " ROOT Password " \
                            --passwordbox "Enter a strong ROOT password:" 0 0
                    )"; then
                        status=0
                    else
                        status=$?
                    fi
                    [[ "$status" -eq 0 ]] || continue

                    if root_pass2="$(
                        dialog --clear --stdout --backtitle "$TITLE" --title " ROOT Verification " \
                            --passwordbox "Confirm ROOT password:" 0 0
                    )"; then
                        status=0
                    else
                        status=$?
                    fi
                    [[ "$status" -eq 0 ]] || continue

                    if [[ "$ROOT_PASS1" == "$root_pass2" && -n "$ROOT_PASS1" ]]; then
                        break 2
                    fi

                    show_error "Passwords do not match or are empty."
                done
            else
                ROOT_PASS1="$PASS1"
                break
            fi
        done

        while true; do
            if SYSTEM_HOSTNAME="$(
                dialog --clear --stdout --backtitle "$TITLE" --title " Hostname " \
                    --inputbox "Enter Computer Name:" 0 0 "${SYSTEM_HOSTNAME:-archium}"
            )"; then
                status=0
            else
                status=$?
            fi

            case "$status" in
                0)
                    [[ -n "$SYSTEM_HOSTNAME" ]] || SYSTEM_HOSTNAME="archium"
                    return 0
                    ;;
                1|255)
                    if confirm_exit; then
                        safe_exit
                    else
                        continue
                    fi
                    ;;
                *)
                    continue
                    ;;
            esac
        done
    done
}

show_cpu_info() {
    show_msg " CPU Detected " "System detected a $CPU_VENDOR CPU.\n\nThe installer will include the matching microcode."
}

# ---------------------------
# Drive helpers
# ---------------------------
collect_selected_drives() {
    local drive_lines=()
    local menu_items=()
    local boot_src="" boot_disk=""
    local drive_list
    local status

    boot_src="$(findmnt -nro SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
    if [[ -n "$boot_src" ]]; then
        local pkname
        pkname="$(lsblk -ndo PKNAME "$boot_src" 2>/dev/null | head -n1 || true)"
        if [[ -n "$pkname" ]]; then
            boot_disk="/dev/$pkname"
        elif [[ -b "$boot_src" ]]; then
            boot_disk="$boot_src"
        fi
    fi

    while IFS= read -r line; do
        local dev type ro size model

        dev="$(awk '{print $1}' <<< "$line")"
        type="$(awk '{print $2}' <<< "$line")"
        ro="$(awk '{print $3}' <<< "$line")"
        size="$(awk '{print $4}' <<< "$line")"
        model="$(cut -d' ' -f5- <<< "$line")"

        [[ "$type" == "disk" ]] || continue
        [[ "$ro" == "0" ]] || continue
        [[ "$dev" == /dev/loop* || "$dev" == /dev/zram* || "$dev" == /dev/ram* || "$dev" == /dev/sr* ]] && continue
        [[ -n "$boot_disk" && "$dev" == "$boot_disk" ]] && continue

        size="$(printf '%s' "$size" | tr -d '[:space:]')"
        model="$(printf '%s' "$model" | sed 's/^ *//;s/ *$//')"
        [[ -n "$model" ]] || model="Unknown"

        drive_lines+=("$dev|$size|$model")
    done < <(lsblk -dnpo NAME,TYPE,RO,SIZE,MODEL)

    if [[ ${#drive_lines[@]} -eq 0 ]]; then
        show_error "No usable drives were found."
        return 1
    fi

    local entry dev size model
    for entry in "${drive_lines[@]}"; do
        IFS='|' read -r dev size model <<< "$entry"
        menu_items+=("$dev" "[$size] $model" "off")
    done

    while true; do
        if drive_list="$(
            dialog --clear --stdout --backtitle "$TITLE" --title " Drive Selection " \
                --checklist "Space to select ALL drives you want to use:" 15 70 8 \
                "${menu_items[@]}"
        )"; then
            status=0
        else
            status=$?
        fi

        case "$status" in
            0)
                if [[ -z "$drive_list" ]]; then
                    show_error "You must select at least one drive to continue."
                    continue
                fi
                readarray -t SELECTED_PATHS < <(tr -d '"' <<< "$drive_list" | xargs -n1)
                return 0
                ;;
            1|255)
                if confirm_exit; then
                    safe_exit
                else
                    continue
                fi
                ;;
            *)
                continue
                ;;
        esac
    done
}

split_and_sort_drives() {
    SORTED_SSDS=()
    SORTED_HDDS=()

    local ssd_rows=()
    local hdd_rows=()
    local dev rota size

    for dev in "${SELECTED_PATHS[@]}"; do
        [[ -b "$dev" ]] || continue

        rota="$(lsblk -dn -o ROTA "$dev" 2>/dev/null || echo 1)"
        size="$(lsblk -bdn -o SIZE "$dev" 2>/dev/null || echo 0)"
        size="$(printf '%s' "$size" | tr -d '[:space:]')"

        if [[ "$rota" == "0" ]]; then
            ssd_rows+=("$size $dev")
        else
            hdd_rows+=("$size $dev")
        fi
    done

    if [[ ${#ssd_rows[@]} -gt 0 ]]; then
        mapfile -t SORTED_SSDS < <(printf '%s\n' "${ssd_rows[@]}" | sort -n | awk '{print $2}')
    fi

    if [[ ${#hdd_rows[@]} -gt 0 ]]; then
        mapfile -t SORTED_HDDS < <(printf '%s\n' "${hdd_rows[@]}" | sort -n | awk '{print $2}')
    fi

    if [[ ${#SORTED_SSDS[@]} -eq 0 && ${#SORTED_HDDS[@]} -eq 0 ]]; then
        show_error "No usable drives were selected."
        return 1
    fi
}

build_drive_layout() {
    EXTRA_MOUNTS=""

    local root_pool=()
    local extra_pool=()

    if [[ ${#SORTED_SSDS[@]} -gt 0 ]]; then
        root_pool=("${SORTED_SSDS[@]}")
        extra_pool=("${SORTED_HDDS[@]}")
    else
        root_pool=("${SORTED_HDDS[@]}")
        extra_pool=()
    fi

    [[ ${#root_pool[@]} -gt 0 ]] || return 1

    REAL_PATH="${root_pool[0]}"

    # Separate /home only if at least 2 drives exist in the chosen root pool
    if [[ ${#root_pool[@]} -gt 1 ]]; then
        EXTRA_MOUNTS+="${root_pool[1]}:/home\n"
    fi

    # Remaining drives from the chosen root pool become extra mounts
    local i dev model size mount_name
    for ((i=2; i<${#root_pool[@]}; i++)); do
        dev="${root_pool[$i]}"
        size="$(LANG=C lsblk -dn -o SIZE "$dev" | tr -d '[:space:],')"
        [[ -n "$size" ]] || size="Unknown"

        if device_is_ssd "$dev"; then
            mount_name="SSD_${size}"
        else
            model="$(lsblk -dn -o MODEL "$dev" | tr -dc '[:alnum:]')"
            [[ -n "$model" ]] || model="Disk"
            mount_name="${model}_${size}"
        fi

        EXTRA_MOUNTS+="$dev:/mnt/${mount_name}\n"
    done

    # All drives from the other pool become extra mounts
    for dev in "${extra_pool[@]}"; do
        model="$(lsblk -dn -o MODEL "$dev" | tr -dc '[:alnum:]')"
        size="$(LANG=C lsblk -dn -o SIZE "$dev" | tr -d '[:space:],')"

        [[ -n "$model" ]] || model="Disk"
        [[ -n "$size" ]] || size="Unknown"

        if device_is_ssd "$dev"; then
            mount_name="SSD_${size}"
        else
            mount_name="${model}_${size}"
        fi

        EXTRA_MOUNTS+="$dev:/mnt/${mount_name}\n"
    done
}

# ---------------------------
# Filesystem / packages
# ---------------------------
select_filesystem() {
    local choice
    local status

    while true; do
        if choice="$(
            dialog --clear --stdout --backtitle "$TITLE" --title " Filesystem Selection " \
                --menu "Select the filesystem for all formatted Linux drives:" "$MENU_H" "$MENU_W" "$MENU_LIST_H" \
                "ext4"  "Stable default" \
                "btrfs" "Modern copy-on-write filesystem"
        )"; then
            status=0
        else
            status=$?
        fi

        case "$status" in
            0)
                [[ -n "$choice" ]] || continue
                FS_TYPE="$choice"
                return 0
                ;;
            1|255)
                continue
                ;;
            *)
                continue
                ;;
        esac
    done
}
build_software_menu_items() {
    local file="$SCRIPT_DIR/.software-menu-pkgs"
    local items=()
    local type a b c

    [[ -f "$file" ]] || {
        show_error "Software menu file missing: $file"
        return 1
    }

    while IFS='|' read -r type a b c; do
        [[ -n "$type" ]] || continue

        case "$type" in
            SECTION)
                items+=("---" "--- $a ---" "off")
                ;;
            PKG)
                items+=("$a" "$b" "$c")
                ;;
        esac
    done < "$file"

    printf '%s\n' "${items[@]}"
}

select_optional_software() {
    local soft_list=()
    local selected_extras
    local core_pkgs core_syspkgs apps_pkgs
    local status

    mapfile -t soft_list < <(build_software_menu_items) || return 1

    while true; do
        selected_extras="$(
            dialog --clear --stdout --separate-output --backtitle "$TITLE" --title " Package Selection " \
                --checklist "Select the software loadout for Archium:" "$MENU_H" "$MENU_W" "$MENU_LIST_H" \
                "${soft_list[@]}"
        )"
        status=$?

        case "$status" in
            0)
                core_pkgs="base base-devel git sof-firmware linux-firmware $UCODE $VIDEO_PKGS efibootmgr sddm grub sudo dosfstools lsb-release noto-fonts iptables-nft"
                if [[ "$FS_TYPE" == "btrfs" ]]; then
                    core_pkgs="$core_pkgs btrfs-progs"
                fi

                core_syspkgs="plasma-desktop zip unzip p7zip tar unrar plasma-pa plasma-nm ntfs-3g vlc-plugins-all sddm-kcm pipewire pipewire-alsa pipewire-audio pipewire-jack pipewire-pulse os-prober nano plasma5-integration kde-gtk-config breeze-gtk ffmpegthumbs kdegraphics-thumbnailers powerdevil power-profiles-daemon phonon-qt6-vlc xdg-user-dirs ufw qt6-multimedia-ffmpeg mkinitcpio e2fsprogs colord-kde kscreen kgamma lib32-pipewire-jack lib32-pipewire-v4l2 libappindicator papirus-icon-theme"
                apps_pkgs="kate elisa konsole fastfetch kcalc spectacle ark kinfocenter plasma-systemmonitor vlc dolphin gwenview kolourpaint okular"

                ARCH_PACKAGE_LIST="$core_pkgs $core_syspkgs $apps_pkgs"
                AUR_PACKAGE_LIST="$(printf '%s\n' "$selected_extras" | grep -v '^---$' | paste -sd' ' -)"
                return 0
                ;;
            1|255)
                if confirm_exit; then
                    safe_exit
                else
                    continue
                fi
                ;;
            *)
                continue
                ;;
        esac
    done
}

# ---------------------------
# Summary / handoff
# ---------------------------
build_summary_text() {
    local overview
    overview="Device name: $SYSTEM_HOSTNAME\n"
    overview+="Username: $USERNAME\n"
    overview+="Main drive: $REAL_PATH\n"
    overview+="Locale: $SELECTED_LOCALE\n"
    overview+="Zone: $REGION/$CITY\n"
    overview+="CPU: $CPU_VENDOR ($UCODE)\n"
    if [[ -n "$NVIDIA_AUR_DRIVER" ]]; then
        overview+="GPU: $GPU_VENDOR ($NVIDIA_AUR_DRIVER)\n"
    else
        overview+="GPU: $GPU_VENDOR ($VIDEO_PKGS)\n"
    fi

    if [[ -n "${EXTRA_MOUNTS// }" ]]; then
        overview+="Other drives: $(echo -ne "$EXTRA_MOUNTS" | tr '\n' ' ')\n"
    fi

    overview+="Filesystem: $FS_TYPE\n"
    overview+="Selected optional packages: $(echo "$AUR_PACKAGE_LIST" | tr -d '"')"
    printf '%s' "$overview"
}

# ---------------------------
# Validation / Verification
# ---------------------------

sanitize_inputs() {
    # Hostname: lowercase, a-z 0-9 -
    SYSTEM_HOSTNAME="$(printf '%s' "$SYSTEM_HOSTNAME" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cd 'a-z0-9-')"
    [[ -n "$SYSTEM_HOSTNAME" ]] || SYSTEM_HOSTNAME="archium"

    # Username: lowercase, safe linux style
    USERNAME="$(printf '%s' "$USERNAME" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cd 'a-z0-9_-')"
    [[ -n "$USERNAME" ]] || USERNAME="archiumuser"

    # Locale / keymap fallbacks
    SELECTED_LOCALE="$(printf '%s' "$SELECTED_LOCALE" | awk '{print $1}')"
    [[ -n "$SELECTED_LOCALE" ]] || SELECTED_LOCALE="en_US.UTF-8"

    SELECTED_KBL="$(printf '%s' "${SELECTED_KBL:-}" | awk '{print $1}')"
    [[ -n "$SELECTED_KBL" ]] || SELECTED_KBL="us"

    REGION="$(printf '%s' "$REGION" | awk '{print $1}')"
    CITY="$(printf '%s' "$CITY" | sed 's/^ *//;s/ *$//')"

    # Device path
    REAL_PATH="$(printf '%s' "$REAL_PATH" | tr -d '[:space:]')"

    # Normalize package lists
    ARCH_PACKAGE_LIST="$(printf '%s' "$ARCH_PACKAGE_LIST" | tr -s ' ')"
    AUR_PACKAGE_LIST="$(printf '%s' "$AUR_PACKAGE_LIST" | tr -s ' ')"

    # Normalize EXTRA_MOUNTS into clean multi-line text in memory
    if [[ -n "${EXTRA_MOUNTS:-}" ]]; then
        EXTRA_MOUNTS="$(
            printf '%b' "$EXTRA_MOUNTS" \
            | sed 's/\r$//' \
            | sed 's/[[:space:]]*$//' \
            | sed '/^$/d'
        )"
    fi
}

validate_hostname() {
    [[ "$SYSTEM_HOSTNAME" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

validate_username() {
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_main_disk() {
    [[ "$REAL_PATH" == /dev/* ]] && [[ -b "$REAL_PATH" ]]
}

validate_locale() {
    grep -Eq "^#?${SELECTED_LOCALE}[[:space:]]+UTF-8" /etc/locale.gen 2>/dev/null || return 0
}

validate_keymap() {
    if command -v localectl >/dev/null 2>&1; then
        localectl list-keymaps 2>/dev/null | grep -Fxq "$SELECTED_KBL"
    else
        return 0
    fi
}

validate_timezone() {
    [[ -n "$REGION" && -n "$CITY" && -e "/usr/share/zoneinfo/$REGION/$CITY" ]]
}

validate_package_lists() {
    [[ -n "$ARCH_PACKAGE_LIST" ]]
}

validate_extra_mounts() {
    local line dev target
    [[ -z "${EXTRA_MOUNTS:-}" ]] && return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue

        dev="${line%%:*}"
        target="${line#*:}"

        [[ "$dev" == /dev/* ]] || return 1
        [[ -b "$dev" ]] || return 1
        [[ "$target" == /* ]] || return 1
        [[ "$target" != "/" ]] || return 1

        # mountpoint safe-ish chars only
        [[ "$target" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1

        # extra disk must not be the same as main disk
        [[ "$dev" != "$REAL_PATH" ]] || return 1
    done <<< "$EXTRA_MOUNTS"
}

show_validation_errors() {
    local errors="$1"
    dialog --clear --backtitle "$TITLE" --title "$ERROR_TITLE" \
        --msgbox "Configuration validation failed:\n\n$errors" 20 76
}

validate_inputs() {
    local errors=""
    local line dev target

    validate_hostname || errors+="• Invalid hostname: $SYSTEM_HOSTNAME\n"
    validate_username || errors+="• Invalid username: $USERNAME\n"
    validate_main_disk || errors+="• Main disk is invalid or missing: $REAL_PATH\n"
    validate_locale || errors+="• Locale not found in /etc/locale.gen: $SELECTED_LOCALE\n"
    validate_keymap || errors+="• Console keymap is invalid: $SELECTED_KBL\n"
    validate_timezone || errors+="• Timezone is invalid: $REGION/$CITY\n"
    validate_package_lists || errors+="• ARCH package list is empty.\n"
    validate_extra_mounts || errors+="• EXTRA_MOUNTS contains an invalid device or mountpoint.\n"

    # Prevent duplicate extra devices
    if [[ -n "${EXTRA_MOUNTS:-}" ]]; then
        local seen=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            dev="${line%%:*}"
            if grep -Fxq "$dev" <<< "$seen"; then
                errors+="• Duplicate extra device selected: $dev\n"
            fi
            seen+="$dev"$'\n'
        done <<< "$EXTRA_MOUNTS"
    fi

    if [[ -n "$errors" ]]; then
        show_validation_errors "$errors"
        return 1
    fi

    return 0
}

write_setup_config() {
    {
        printf "SYSTEM_HOSTNAME=%q\n" "$SYSTEM_HOSTNAME"
        printf "USERNAME=%q\n" "$USERNAME"
        printf "USER_PASS=%q\n" "$PASS1"
        printf "ROOT_PASS=%q\n" "$ROOT_PASS1"
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
    } > /tmp/archium.conf
}

reconfigure_menu() {
    while true; do
        local choice
        if ! choice="$(
            dialog --clear --stdout --backtitle "$TITLE" --title " Reconfigure " \
                --menu "Select which section you want to change:" 18 70 9 \
                "locale"     "Locale" \
                "timezone"   "Timezone" \
                "keyboard"   "Keyboard layout" \
                "user"       "Username / passwords / hostname" \
                "gpu"        "GPU driver selection" \
                "drives"     "Drive selection" \
                "fs"         "Filesystem" \
                "packages"   "Optional packages" \
                "summary"    "Return to summary"
        )"; then
            return 0
        fi

        case "$choice" in
            locale)   select_locale ;;
            timezone) select_timezone ;;
            keyboard) select_keyboard_layouts ;;
            user)     collect_user_info ;;
            gpu)      detect_gpu_and_packages ;;
            drives)
                while true; do
                    collect_selected_drives || continue
                    split_and_sort_drives || continue
                    build_drive_layout || continue
                    break
                done
                ;;
            fs)       select_filesystem ;;
            packages) select_optional_software ;;
            summary)  return 0 ;;
        esac
    done
}
confirm_and_continue() {
    while true; do
        local overview
        overview="$(build_summary_text)"

        if dialog --clear --backtitle "$TITLE" --title "$SUMMARY_TITLE" \
            --yesno "Configuration Overview:\n\n$overview\n\nWrite to /tmp/archium.conf and proceed?" 18 76
        then
            sanitize_inputs
            if ! validate_inputs; then
                continue
            fi
            write_setup_config
            clear
            exec "$INSTALL_SCRIPT"
        else
            reconfigure_menu
        fi
    done
}

# ---------------------------
# Main flow
# ---------------------------
main() {
    get_dialog_size
    detect_cpu_vendor
    show_welcome

    ensure_network
    select_locale
    select_timezone
    select_keyboard_layouts
    collect_user_info

    while true; do
        collect_selected_drives
        split_and_sort_drives || { show_error "Drive sorting failed."; continue; }
        build_drive_layout || { show_error "Drive layout generation failed."; continue; }
        break
    done

    detect_ucode_package
    show_cpu_info || true
    detect_gpu_and_packages
    select_filesystem
    select_optional_software
    confirm_and_continue
}

main
