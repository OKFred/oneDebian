#!/bin/sh
# APT calls this dedicated executable so other hooks keep their own protocol.
set -eu
state=/var/lib/onedebian-agent
owner=oneDebian-agent-v1
case "${1:-}" in
  bootstrap-init)
    [ "$(id -u)" = 0 ] || { echo 'Package undo needs root' >&2; exit 1; }
    [ ! -L "$state" ] || { echo 'Package undo state symlink' >&2; exit 1; }
    if [ -d "$state" ]; then
      [ "$(stat -c %u "$state")" = 0 ] || exit 1
      permissions=$(stat -c %a "$state")
      [ "$((0$permissions & 022))" = 0 ] || exit 1
      [ ! -L "$state/.owner" ] && [ -f "$state/.owner" ] && [ "$(cat "$state/.owner")" = "$owner" ] || exit 1
      [ "$(stat -c %u "$state/.owner")" = 0 ] || exit 1
      permissions=$(stat -c %a "$state/.owner")
      [ "$((0$permissions & 022))" = 0 ] || exit 1
    else
      umask 077
      mkdir -p "$state"
      printf %s "$owner" > "$state/.owner"
    fi
    umask 077
    fresh=false
    if [ -e "$state/package-undo-reset" ] || [ -L "$state/package-undo-reset" ]; then
      marker=$state/package-undo-reset
      [ -f "$marker" ] && [ ! -L "$marker" ] && [ "$(stat -c %u "$marker")" = 0 ] || exit 1
      [ "$((0$(stat -c %a "$marker") & 077))" = 0 ] || exit 1
      [ "$(wc -c < "$marker")" -le 128 ] || exit 1
      case "$(cat "$marker")" in ''|*[!a-zA-Z0-9_.-]*) exit 1 ;; esac
      fresh=true
    fi
    if [ ! -e "$state/package-undo.json" ] && [ ! -e "$state/package-undo-baseline.tsv" ]; then
      if [ "$fresh" = false ] && { [ -e "$state/state.json" ] || [ -e "$state/installed.json" ] || [ -e "$state/user-owned" ] || [ -e "$state/files.json" ]; }; then
        : > "$state/package-undo-legacy"
      else
        for suffix in baseline.tsv manual.before held.before architecture.before; do
          [ ! -L "$state/package-undo-$suffix" ] || exit 1
          [ ! -L "$state/package-undo-$suffix.new" ] || exit 1
        done
        dpkg-query -W -f='${Package}\t${Architecture}\t${Version}\t${db:Status-Status}\t${Essential}\t${Priority}\n' > "$state/package-undo-baseline.tsv.new"
        apt-mark showmanual > "$state/package-undo-manual.before.new"
        apt-mark showhold > "$state/package-undo-held.before.new"
        dpkg --print-architecture > "$state/package-undo-architecture.before.new"
        for suffix in manual.before held.before architecture.before baseline.tsv; do
          mv "$state/package-undo-$suffix.new" "$state/package-undo-$suffix"
        done
      fi
    fi
    here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    for name in package_undo.py package-undo-hook.sh; do
      [ ! -L "$state/$name" ] || exit 1
      [ ! -L "$state/$name.new" ] || exit 1
      if [ "$here/$name" != "$state/$name" ]; then
        cp "$here/$name" "$state/$name.new"
        chmod 600 "$state/$name.new"
        [ "$name" != package-undo-hook.sh ] || chmod 700 "$state/$name.new"
        mv "$state/$name.new" "$state/$name"
      fi
    done
    ;;
  record)
    if [ -x /usr/bin/python3 ]; then
      exec /usr/bin/python3 "$state/package_undo.py" record
    fi
    [ "$(id -u)" = 0 ] && [ ! -L "$state" ] && [ -f "$state/.owner" ] && [ "$(cat "$state/.owner")" = "$owner" ] || exit 1
    [ ! -L "$state/package-undo-bootstrap-actions.log" ] || exit 1
    umask 077
    cat >> "$state/package-undo-bootstrap-actions.log"
    ;;
  finish|guard)
    exec /usr/bin/python3 "$state/package_undo.py" "$1"
    ;;
  *) echo 'Unknown package undo hook' >&2; exit 1 ;;
esac
