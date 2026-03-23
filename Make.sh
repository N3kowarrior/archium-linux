#!/bin/bash
set -e
echo "1) Downloading and extracting clean sources ..."
./preapareUpdate.sh
echo "2) Building necessary kernels ..."
./buildKernels.sh
echo "3) Patching installer files ..."
./patchArchInstaller.sh
echo "4) Making the final ISO ..."
./buildISO.sh
echo "✅ All steps completed successfully!"
