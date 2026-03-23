#!/bin/bash

#Get the lastest tkg repo
if [ -d "linux-tkg" ]; then
    echo "Updating linux-tkg..."
    cd linux-tkg
    git fetch origin
    git reset --hard origin/master
    cd ..
else
    git clone https://github.com/frogging-family/linux-tkg
fi
rm -rf archium-linux-iso
mkdir -p archium-linux-iso
cp -r /usr/share/archiso/configs/releng/* archium-linux-iso/
