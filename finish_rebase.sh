#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Ensure no conflict markers remain before staging.
if grep -R -l '<<<<<<<\|=======\|>>>>>>>' maki-ui/src Cargo.toml; then
    echo 'conflict markers remain; resolve before running this script' >&2
    exit 1
fi

git add -A Cargo.toml maki-ui/src
git rm -f Cargo.lock || true
rm -f Cargo.lock

cargo check --workspace

git add Cargo.lock
git commit -m "feat(ui): render inline images in supported terminals (rebased onto main)"

git push --force-with-lease fork feat/upstream-inline-images
