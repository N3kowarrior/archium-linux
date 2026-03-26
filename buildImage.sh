#!/bin/bash
sudo mkarchiso -v -w workdir -o out archium-linux-iso
sudo rm -rf workdir
sudo chown -R $USER out
