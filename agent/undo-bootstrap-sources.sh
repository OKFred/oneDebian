#!/bin/sh
# Preserve source settings before Python exists; never print backed-up contents.
set -eu
state=/var/lib/onedebian-agent
store=$state/cleanup-bootstrap-sources
owner=oneDebian-agent-v1
[ "$(id -u)" = 0 ] || exit 1
for directory in /var /var/lib "$state"; do [ ! -L "$directory" ] || exit 1; done
[ -d "$state" ] && [ "$(stat -c %u "$state")" = 0 ] || exit 1
[ "$((0$(stat -c %a "$state") & 022))" = 0 ] || exit 1
[ -f "$state/.owner" ] && [ ! -L "$state/.owner" ] && [ "$(cat "$state/.owner")" = "$owner" ] || exit 1
umask 077
case "${1:-}" in
  reset)
    receipt=$state/cleanup-completed.json
    [ -e "$receipt" ] || exit 0
    [ -f "$receipt" ] && [ ! -L "$receipt" ] && [ "$(stat -c %u "$receipt")" = 0 ] || exit 1
    [ "$((0$(stat -c %a "$receipt") & 077))" = 0 ] || exit 1
    [ "$(wc -c < "$receipt")" -le 4096 ] || exit 1
    [ "$(sed -n 's/.*"owner"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$receipt")" = "$owner" ] || exit 1
    grep -Eq '"state"[[:space:]]*:[[:space:]]*"CLEANED(_PARTIAL)?"' "$receipt" || exit 1
    archive=
    if [ -f "$state/cleanup-bootstrap-reset" ]; then
      [ ! -L "$state/cleanup-bootstrap-reset" ] && [ "$(stat -c %u "$state/cleanup-bootstrap-reset")" = 0 ] || exit 1
      [ "$((0$(stat -c %a "$state/cleanup-bootstrap-reset") & 077))" = 0 ] || exit 1
      previous=$(cat "$state/cleanup-bootstrap-reset")
      case "$previous" in cleanup-bootstrap-history.*) ;; *) exit 1 ;; esac
      case "$previous" in *[!a-zA-Z0-9_.-]*) exit 1 ;; esac
      archive=$state/$previous
      [ -d "$archive" ] && [ ! -L "$archive" ] && [ -f "$archive/.owner" ] && [ "$(cat "$archive/.owner")" = "$owner" ] || exit 1
    fi
    ledger=$state/cleanup-before.json
    if [ ! -f "$ledger" ] && [ -n "$archive" ]; then ledger=$archive/cleanup-before.json; fi
    [ -f "$ledger" ] && [ ! -L "$ledger" ] && [ "$(stat -c %u "$ledger")" = 0 ] || exit 1
    [ "$((0$(stat -c %a "$ledger") & 077))" = 0 ] || exit 1
    grep -Eq '"applied"[[:space:]]*:[[:space:]]*true' "$ledger" || exit 1
    names='cleanup-before.json package-undo.json package-undo-baseline.tsv package-undo-manual.before package-undo-held.before package-undo-architecture.before package-undo-legacy package-undo-bootstrap-actions.log package-undo-approved.json package-undo-reset-pending cleanup-bootstrap-sources installed.json gpu.json cleanup-completed.json'
    for name in $names cleanup-reset package-undo-reset cleanup-bootstrap-reset; do
      [ ! -L "$state/$name" ] || exit 1
      if [ -e "$state/$name" ]; then
        [ "$(stat -c %u "$state/$name")" = 0 ] && [ "$((0$(stat -c %a "$state/$name") & 022))" = 0 ] || exit 1
      fi
    done
    if [ -z "$archive" ]; then
      archive=$(mktemp -d "$state/cleanup-bootstrap-history.XXXXXXXXXX")
      printf %s "$owner" > "$archive/.owner"
    fi
    # These fixed markers make a later Python prepare capture the retained environment anew.
    printf %s "$owner" > "$state/cleanup-reset"
    printf '%s\n' "$(basename "$archive")" > "$state/package-undo-reset"
    printf '%s\n' "$(basename "$archive")" > "$state/cleanup-bootstrap-reset"
    for name in $names; do
      if [ -e "$state/$name" ]; then
        [ ! -L "$state/$name" ] || exit 1
        if [ ! -e "$archive/$name" ]; then mv -- "$state/$name" "$archive/$name"; fi
      fi
    done
    rm -f -- "$state/cleanup-bootstrap-reset"
    ;;
  before)
    [ ! -L "$store" ] || exit 1
    if [ -d "$store" ]; then
      [ -f "$store/.owner" ] && [ "$(cat "$store/.owner")" = "$owner" ] || exit 1
      exit 0
    fi
    [ ! -L /etc/apt ] && [ ! -L /etc/apt/sources.list.d ] || exit 1
    temporary=$(mktemp -d "$state/.cleanup-bootstrap.XXXXXXXXXX")
    trap 'rmdir "$temporary" 2>/dev/null || true' EXIT
    printf %s "$owner" > "$temporary/.owner"
    for path in /etc/apt/sources.list /etc/apt/sources.list.d/onedebian-security.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
      case "$path" in *'*'*) continue ;; esac
      case "$(basename "$path")" in *[!a-zA-Z0-9_.-]*) continue ;; esac
      [ ! -L "$path" ] || exit 1
      key=$(printf %s "$path" | sha256sum | cut -d ' ' -f 1)
      [ ! -e "$temporary/$key.path" ] || continue
      printf '%s\n' "$path" > "$temporary/$key.path"
      if [ -e "$path" ]; then
        [ -f "$path" ] && [ "$(stat -c %u "$path")" = 0 ] || exit 1
        [ "$((0$(stat -c %a "$path") & 022))" = 0 ] || exit 1
        [ "$(wc -c < "$path")" -le 1048576 ] || exit 1
        cat "$path" > "$temporary/$key.before"
        stat -c '%a %u %g' "$path" > "$temporary/$key.before.meta"
      else
        printf 'missing\n' > "$temporary/$key.before.meta"
      fi
    done
    mv -- "$temporary" "$store"
    trap - EXIT
    ;;
  seal)
    [ -d "$store" ] && [ ! -L "$store" ] || exit 1
    [ ! -e "$store/sealed" ] || exit 0
    for entry in "$store/"*.path; do
      path=$(cat "$entry")
      case "$path" in /etc/apt/sources.list|/etc/apt/sources.list.d/*.list|/etc/apt/sources.list.d/*.sources) ;; *) exit 1 ;; esac
      [ ! -L "$path" ] || exit 1
      if [ -e "$path" ]; then
        [ -f "$path" ] || exit 1
        printf '%s ' "$(sha256sum "$path" | cut -d ' ' -f 1)" > "${entry%.path}.after.meta"
        stat -c '%a %u %g' "$path" >> "${entry%.path}.after.meta"
      else
        printf 'missing\n' > "${entry%.path}.after.meta"
      fi
    done
    printf 'sealed\n' > "$store/sealed"
    ;;
  *) exit 1 ;;
esac
