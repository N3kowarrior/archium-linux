#!/bin/bash
set -euo pipefail

GH_REPO="N3kowarrior/archium-repo"
RELEASE_TAG="stable"
REPO_DIR="/mnt/projects/Archium-Linux-Project/archium-repo/x86_64"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cp -a "$REPO_DIR"/. "$WORK_DIR"/
cd "$WORK_DIR"

# vygeneruj/aktualizuj pacman databázi
repo-add archium.db.tar.zst *.pkg.tar.zst

# GitHub Releases neumí symlinky dobře pro pacman use-case,
# tak vytvoříme reálné soubory
rm -f archium.db archium.files
cp -L archium.db.tar.zst archium.db
cp -L archium.files.tar.zst archium.files

# release vytvoř jen pokud neexistuje
if ! gh release view "$RELEASE_TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    gh release create "$RELEASE_TAG" \
      --repo "$GH_REPO" \
      --title "Archium repo" \
      --notes "Pacman repository for Archium"
fi

# nahraj balíčky + db
gh release upload "$RELEASE_TAG" \
  --repo "$GH_REPO" \
  *.pkg.tar.zst archium.db.tar.zst archium.files.tar.zst archium.db archium.files \
  --clobber

echo "✅ GitHub pacman repo synced."
