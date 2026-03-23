#!/bin/bash
PATCH_DIR="patches"
LINUX_TKG_DIR="linux-tkg"
# --- 2. Kernel Config ---
echo "⚙️ Injecting linux TKG configuration file"
if [ -d "$PATCH_DIR" ]; then
    cp -v "$PATCH_DIR/linux-tkg-config/customization.cfg" "$LINUX_TKG_DIR/customization.cfg" 2>/dev/null
fi
cd linux-tkg
set -e

CPUS=(
    x86-64
    x86-64-v4
    x86-64-v3
    x86-64-v2
    alderlake
    skylake
    lunarlake
    arrowlake
    znver3
    znver4
    znver5
)

CONFIG_FILE="./customization.cfg"

for cpu in "${CPUS[@]}"; do
    echo "=============================="
    echo " Building kernel: $cpu"
    echo "=============================="

    # 1. Set CPU optimization
    sed -i "s/^_processor_opt=.*/_processor_opt=\"$cpu\"/" "$CONFIG_FILE"

    # 2. Set kernel package name
    sed -i "s/^_custom_pkgbase=.*/_custom_pkgbase=\"linux-archium-tkg-$cpu\"/" "$CONFIG_FILE"
    if [ "$cpu" == "x86-64" ]; then
        echo "🍎 Feeding the kernel: Setting _kernel_on_diet to false for archiso compatibility..."
        sed -i "s/^_kernel_on_diet=.*/_kernel_on_diet=\"false\"/" "$CONFIG_FILE"
    else
        echo "✂️ Slimming down: Setting _kernel_on_diet to true for $cpu..."
        sed -i "s/^_kernel_on_diet=.*/_kernel_on_diet=\"true\"/" "$CONFIG_FILE"
    fi
    # 3. Build
    makepkg -s --noconfirm

    echo "✔ Done: linux-archium-tkg-$cpu"
done

echo "🎉 ALL KERNELS BUILT!"

