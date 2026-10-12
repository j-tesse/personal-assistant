#!/bin/bash
# One-time, on the Mac (2026-10-12): GitHub bitofant → j-tesse remotes + bundle id com.bitofant.pa → com.riuna.pa.
# ./migrate-rename.sh [signing identity]. Safe to re-run. bash 3.2 (stock macOS).
set -euo pipefail
cd "$(dirname "$0")"

echo "== Git remotes"
# Rewrites only github.com/bitofant/… (ssh or https); other remotes untouched.
for r in $(git remote); do
  url=$(git remote get-url "$r")
  case "$url" in
    *github.com[:/]bitofant/*)
      newurl=$(printf '%s' "$url" | sed -E 's#(github\.com[:/])bitofant/#\1j-tesse/#')
      git remote set-url "$r" "$newurl"
      echo "  $r: $url → $newurl" ;;
    *) echo "  $r: $url (unchanged)" ;;
  esac
done
git fetch --quiet origin && echo "  origin reachable" || echo "  ! git fetch origin failed (check access to the new URL)" >&2

echo
exec osx/migrate-bundle-id.sh "$@"
