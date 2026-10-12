#!/bin/bash
# One-time move from bundle id com.bitofant.pa → com.riuna.pa (2026-10-12). Safe to re-run.
# osx/migrate-bundle-id.sh [signing identity]. bash 3.2 (stock macOS).
# Stops old agents, moves data/caches/logs, copies the Keychain token (no re-pair), resets old TCC grants,
# asks for the new grants, installs the new agents.
set -euo pipefail

old=com.bitofant.pa
new=com.riuna.pa
here=$(cd "$(dirname "$0")" && pwd)
app="$here/build/PA.app"
bin="$app/Contents/MacOS/pa"
domain="gui/$(id -u)"
lib="$HOME/Library"

[ "$(uname)" = Darwin ] || { echo "Run this on the Mac." >&2; exit 1; }
[ "$(id -u)" != 0 ] || { echo "Don't run as root (per-user agents/Keychain)." >&2; exit 1; }

ask() { # ask <question> → 0 = yes (default yes)
  local a
  read -r -p "$1 [Y/n] " a
  case "$a" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

# move_dir <from> <to>: never overwrites; both exist → leave old, say so.
move_dir() {
  [ -e "$1" ] || return 0
  if [ -e "$2" ]; then
    echo "  ! both exist, kept old: $1 (merge by hand into $2)"
  else
    mkdir -p "$(dirname "$2")"
    mv "$1" "$2"
    echo "  moved $1 → $2"
  fi
}

echo "== 1. Stop old agents"
for l in "$old" "$old.menu" "$new" "$new.menu"; do
  launchctl bootout "$domain/$l" 2>/dev/null && echo "  stopped $l" || true
done
for l in "$old" "$old.menu"; do
  p="$lib/LaunchAgents/$l.plist"
  [ -e "$p" ] && rm -f "$p" && echo "  removed $p"
done
# Interactive `osx/pa run` (not a LaunchAgent) would keep recording under the old id.
if pgrep -f "/MacOS/pa run" >/dev/null 2>&1; then
  echo "  ! a 'pa run' is still running (pid $(pgrep -f "/MacOS/pa run" | tr '\n' ' ')): stop it (Ctrl-C) and re-run this script." >&2
  exit 1
fi

echo "== 2. Build PA.app as $new"
# Keychain ACL (-T) + TCC need the new signed app → build first.
if ! codesign -dv "$app" 2>&1 | grep -q "^Identifier=$new\$"; then
  "$here/build.sh" "$@"
fi
codesign -dv "$app" 2>&1 | grep -q "^Identifier=$new\$" || { echo "PA.app not signed as $new." >&2; exit 1; }

echo "== 3. Move data, caches, logs"
move_dir "$lib/Application Support/$old" "$lib/Application Support/$new"
move_dir "$lib/Caches/$old" "$lib/Caches/$new"
for f in "$old" "$old.menu"; do
  move_dir "$lib/Logs/$f.log" "$lib/Logs/${f/$old/$new}.log"
done
for d in "$lib/HTTPStorages/$old" "$lib/HTTPStorages/$old.binarycookies" "$lib/Caches/$old.menu" "$lib/Preferences/$old.plist" "$lib/Preferences/$old.menu.plist"; do
  [ -e "$d" ] && rm -rf "$d" && echo "  removed $d"
done

echo "== 4. Keychain token"
# Old item's ACL trusts only the old pa → macOS asks once; "Allow" is enough.
if security find-generic-password -s "$new" -a device-token >/dev/null 2>&1; then
  echo "  $new token already present"
  security delete-generic-password -s "$old" -a device-token >/dev/null 2>&1 && echo "  deleted old item" || true
elif token=$(security find-generic-password -s "$old" -a device-token -w 2>/dev/null); then
  # Via `security -i` stdin: token never in argv (ps). -T: new pa reads it without a dialog.
  printf 'add-generic-password -s %s -a device-token -T "%s" -w %s\n' "$new" "$bin" "$token" | security -i >/dev/null
  unset token
  security find-generic-password -s "$new" -a device-token >/dev/null
  security delete-generic-password -s "$old" -a device-token >/dev/null
  echo "  copied token → $new (same device, no re-pair), deleted old item"
else
  echo "  no old token (or access denied) → pair again later: osx/pa pair <server> <account>"
fi

echo "== 5. Reset old permission grants"
for id in "$old" "$old.menu"; do tccutil reset All "$id" >/dev/null 2>&1 || true; done
echo "  done (old entries vanish from System Settings → Privacy)"

echo "== 6. Grant permissions to $new"
echo "  Prompts appear only for an interactive launch. Click Allow on each."
if ask "  Calendar access now (osx/pa calendars)?"; then "$here/pa" calendars || true; fi
if ask "  Mic + system audio now (5 s test recording)?"; then "$here/pa" test-capture --seconds 5 || true; fi

echo "== 7. Install LaunchAgents"
"$here/install.sh"

echo "== 8. Check"
"$bin" status || true
cat <<EOF

Done. If 'pa status' isn't active: osx/pa pair <server> <account>, then revoke the old device in the web UI.
Old leftovers to check by hand: System Settings → General → Login Items (stale "PA" entries).
EOF
