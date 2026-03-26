#!/bin/bash
read -p "Commit message: " reason
git add .
git commit -m "$reason"
git push main
