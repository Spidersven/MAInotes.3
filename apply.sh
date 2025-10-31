#!/usr/bin/env bash
set -euo pipefail

# apply.sh — scaffold, branch, install, commit & push for feature/perfect-mixnote
# Usage: chmod +x apply.sh && ./apply.sh
# This script will:
#  - create branch feature/perfect-mixnote
#  - install dependencies (root + renderer if present)
#  - create initial scaffold files (if not present) for MixNote feature set
#  - run tsc build (best-effort)
#  - commit and push branch to origin
#
# IMPORTANT: review changes before pushing to remote. Backup your vault before running any encryption or sync.

BRANCH="feature/perfect-mixnote"
echo "==> Running apply.sh (feature/perfect-mixnote)"
echo "Make sure you are in the repository root (pycodecloud-ui/projectlol)."
read -p "Proceed? (y/N) " PROCEED
if [[ "${PROCEED:-n}" != "y" && "${PROCEED:-n}" != "Y" ]]; then
  echo "Aborted by user."
  exit 1
fi

# create branch
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  echo "Branch $BRANCH already exists, checking it out..."
  git checkout "$BRANCH"
else
  echo "Creating branch $BRANCH..."
  git checkout -b "$BRANCH"
fi

echo "==> Installing root dependencies (npm ci preferred)..."
if command -v npm >/dev/null 2>&1; then
  npm install
else
  echo "npm not found. Install Node.js/npm first."
  exit 1
fi

# install renderer deps if folder exists
if [ -d "files/src/renderer" ]; then
  echo "==> Installing renderer deps..."
  (cd files/src/renderer && npm install)
fi

# create scaffolding files if they don't exist (non-destructive)
mkdir -p files/src/renderer/src/e2ee
mkdir -p files/src/renderer/src/editor
mkdir -p files/src/renderer/src/graph
mkdir -p files/src/renderer/src
mkdir -p files/src/vault
mkdir -p config
mkdir -p .github/workflows
mkdir -p files/src/shared

# minimal safe .mixnote ignore (local-only metadata)
if [ ! -f ".gitignore" ]; then
  cat > .gitignore <<'EOF'
node_modules
dist
release
.env
.MixNoteCredentials
*.log
EOF
  git add .gitignore
fi

# add a safe README if not exists or append a note
if [ ! -f "README.md" ]; then
  cat > README.md <<'EOF'
# MixNote (projectlol) — feature/perfect-mixnote

This branch contains a large feature set: editor UX, E2EE, AI assistant plumbing, Google Drive scaffold, indexer, graph, and packaging scaffolding.

Run apply.sh to scaffold files, then inspect, test, and push.

Important: Backup your vault directory before using encryption or sync features.
EOF
  git add README.md
fi

# Create placeholder config/electron-builder.json if missing
if [ ! -f "config/electron-builder.json" ]; then
  cat > config/electron-builder.json <<'EOF'
{
  "appId": "com.pycodecloud.mixnote",
  "productName": "MixNote",
  "files": [
    "dist/**/*",
    "files/src/renderer/dist/**/*",
    "public/**/*"
  ]
}
EOF
  git add config/electron-builder.json
fi

# minimal CI workflow to run build
if [ ! -f ".github/workflows/ci.yml" ]; then
  mkdir -p .github/workflows
  cat > .github/workflows/ci.yml <<'EOF'
name: CI

on:
  push:
    branches:
      - main
      - feature/*
  pull_request:
    branches:
      - main

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Use Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20
      - name: Install root deps
        run: npm ci
      - name: Build TypeScript & renderer
        run: npm run build
EOF
  git add .github/workflows/ci.yml
fi

# create basic apply metadata/notes
mkdir -p .mixnote
if [ ! -f ".mixnote/NOTES.txt" ]; then
  cat > .mixnote/NOTES.txt <<'EOF'
MixNote scaffold: branch feature/perfect-mixnote
Backups stored under ~/.mixnote/backups
EOF
fi

# Stage changes
git add -A

# Commit
if git diff --staged --quiet; then
  echo "No staged changes to commit."
else
  git commit -m "chore: scaffold feature/perfect-mixnote (initial files & config)"
  echo "Committed scaffold changes."
fi

# Build (best-effort)
echo "==> Attempting build (tsc)..."
if npm run build >/dev/null 2>&1; then
  echo "Build succeeded."
else
  echo "Build failed (this is non-fatal for scaffold). Continue after fixing build locally."
fi

# Push branch
echo "==> Pushing branch to origin..."
git push -u origin "$BRANCH"

echo "Done. Open a PR from $BRANCH -> main and inspect files. I will deliver the full feature files in the chat next."