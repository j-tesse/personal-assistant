#!/bin/bash
# Mac setup, safe to re-run: unit tests → build → `pa` alias → optionally (re)start the daemon + menu bar app.
# osx/setup.sh [signing identity]. bash 3.2 (stock macOS).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "Prerequisites"
[ "$(uname -m)" = arm64 ] || { echo "Apple Silicon only." >&2; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Install Command Line Tools first: xcode-select --install" >&2; exit 1; }
echo "OK"

step "Unit tests (swift test)"
# CLT-only toolchains may lack the swift-testing macro plugin → try the native build system, else skip (Linux: test-linux.sh).
log=$(mktemp)
tests=skipped
for args in "" "--build-system native"; do
  # shellcheck disable=SC2086 # word-split args on purpose
  if swift test $args >"$log" 2>&1; then tests="passed${args:+ ($args)}"; break; fi
  if ! grep -q TestingMacros "$log"; then tail -30 "$log"; echo "Unit tests failed (full log: $log)." >&2; exit 1; fi
done
echo "Tests: $tests"
[ "$tests" = skipped ] && echo "  (TestingMacros plugin missing in this toolchain; run osx/test-linux.sh on the dev box)"

step "Build"
./build.sh "$@"

step "Shell alias"
rc="$HOME/.zshrc"
line="alias pa='$here/pa'  # personal-assistant"
touch "$rc"
if grep -qxF "$line" "$rc"; then
  echo "Already in $rc"
else
  # Replace an older line (repo moved) instead of adding a second one.
  tmp=$(mktemp)
  grep -vF "# personal-assistant" "$rc" > "$tmp" || true
  echo "$line" >> "$tmp"
  cat "$tmp" > "$rc" && rm -f "$tmp"
  echo "Added to $rc (open a new terminal, or: source $rc)"
fi

step "Daemon"
answer=n
if [ -t 0 ]; then read -r -p "Start the pa daemon + menu bar app now (and at every login)? [y/N] " answer || true; fi
case "$answer" in
  y|Y|yes)
    # Permission prompts only show for an interactive launch, not under launchd → trigger them now (no-op once granted).
    echo "Checking permissions: click Allow on any Calendar / Microphone / System Audio prompt."
    ./pa calendars >/dev/null
    cap=$(mktemp -d)
    ./pa test-capture --seconds 5 --out "$cap" >/dev/null
    rm -rf "$cap"
    ./install.sh
    ;;
  *) echo "Not started. Later: osx/install.sh" ;;
esac

echo
echo "Done. Not paired yet? pa pair https://assistant.riuna.com <account>   (check: pa status)"
