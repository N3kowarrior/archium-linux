#!/bin/bash
set -e
echo "1) Downloading and extracting clean sources ..."
./preapareUpdate.sh
echo "2) Building necessary kernels ..."
./buildKernels.sh
echo "3) Building AUR packages for Archium repo ..."
./buildAurPackages.sh
echo "4) Patching installer files ..."
./patchArchInstaller.sh
echo "5) Making the final ISO ..."
./buildImage.sh
echo "✅ All steps completed successfully!"
