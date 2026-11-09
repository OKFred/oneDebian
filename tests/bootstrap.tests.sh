#!/usr/bin/env bash
# Offline checks: fixture directories contain every source change; package commands are stubs.
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/onedebian-bootstrap-tests.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT
source "$TEST_DIR/../components/the_repo_localization.sh" || exit 1
source "$TEST_DIR/../components/the_basic_setup.sh" || exit 1
source "$TEST_DIR/../bootstrap.sh" || exit 1
TEST_COUNT=0
FAIL_COUNT=0

run_test() {
  TEST_COUNT=$((TEST_COUNT + 1))
  CASE_ROOT="$TEST_ROOT/$TEST_COUNT"
  mkdir -p "$CASE_ROOT/sources.list.d" || exit 1
  if ( "$2" ) >"$CASE_ROOT/output" 2>&1; then
    printf 'ok %s - %s\n' "$TEST_COUNT" "$1"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'not ok %s - %s\n' "$TEST_COUNT" "$1"
    cat "$CASE_ROOT/output"
  fi
}

legacy_sources() {
  cat >"$CASE_ROOT/sources.list" <<'EOF'
# deb http://deb.debian.org/debian commented main
deb [signed-by=/fixture/key.gpg] http://deb.debian.org/debian trixie main contrib
deb http://deb.debian.org/debian trixie-updates main contrib
deb http://deb.debian.org/debian-security/ trixie-security main contrib
deb https://vendor.invalid/debian trixie vendor
EOF
  cp "$CASE_ROOT/sources.list" "$CASE_ROOT/original"
  the_localize_apt_sources Debian trixie "$CASE_ROOT" || return 1
  grep -Fx '# deb http://deb.debian.org/debian commented main' "$CASE_ROOT/sources.list" &&
    grep -Fx 'deb [signed-by=/fixture/key.gpg] https://mirrors.ustc.edu.cn/debian trixie main contrib' "$CASE_ROOT/sources.list" &&
    grep -Fx 'deb https://mirrors.ustc.edu.cn/debian-security trixie-security main contrib' "$CASE_ROOT/sources.list" &&
    grep -Fx 'deb https://vendor.invalid/debian trixie vendor' "$CASE_ROOT/sources.list" &&
    cmp "$CASE_ROOT/original" "$CASE_ROOT/sources.list.onedebian.bak" &&
    [ ! -e "$CASE_ROOT/sources.list.d/onedebian-security.list" ] || return 1
  the_localize_apt_sources Debian trixie "$CASE_ROOT" &&
    cmp "$CASE_ROOT/original" "$CASE_ROOT/sources.list.onedebian.bak"
}

deb822_sources() {
  cat >"$CASE_ROOT/sources.list.d/debian.sources" <<'EOF'
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: trixie
 trixie-updates
Components: main contrib
Signed-By: /fixture/debian.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /fixture/debian.gpg

Types: deb
URIs: https://vendor.invalid/packages
Suites: stable
Components: main
Signed-By: /fixture/vendor.gpg
EOF
  the_localize_apt_sources Debian trixie "$CASE_ROOT" || return 1
  grep -Fx 'URIs: https://mirrors.ustc.edu.cn/debian' "$CASE_ROOT/sources.list.d/debian.sources" &&
    grep -Fx 'URIs: https://mirrors.ustc.edu.cn/debian-security' "$CASE_ROOT/sources.list.d/debian.sources" &&
    grep -Fx 'URIs: https://vendor.invalid/packages' "$CASE_ROOT/sources.list.d/debian.sources" &&
    grep -Fx 'Signed-By: /fixture/vendor.gpg' "$CASE_ROOT/sources.list.d/debian.sources" &&
    [ ! -e "$CASE_ROOT/sources.list" ] &&
    [ ! -e "$CASE_ROOT/sources.list.d/onedebian-security.list" ]
}

missing_security() {
  printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: trixie trixie-updates\nComponents: main\nSigned-By: /fixture/key.gpg\n' >"$CASE_ROOT/sources.list.d/debian.sources"
  the_localize_apt_sources Debian trixie "$CASE_ROOT" || return 1
  grep -Fx 'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://mirrors.ustc.edu.cn/debian-security trixie-security main' "$CASE_ROOT/sources.list.d/onedebian-security.list" || return 1
  cp "$CASE_ROOT/sources.list.d/onedebian-security.list" "$CASE_ROOT/security.original"
  the_localize_apt_sources Debian trixie "$CASE_ROOT" &&
    cmp "$CASE_ROOT/security.original" "$CASE_ROOT/sources.list.d/onedebian-security.list" &&
    [ ! -e "$CASE_ROOT/sources.list.d/onedebian-security.list.onedebian.bak" ]
}

disabled_security() {
  printf 'deb http://deb.debian.org/debian trixie main\n# deb http://deb.debian.org/debian-security trixie-security main\n' >"$CASE_ROOT/sources.list"
  printf 'Types: deb\nURIs: http://deb.debian.org/debian-security\nSuites: trixie-security\nEnabled: no\nComponents: main\n' >"$CASE_ROOT/sources.list.d/disabled.sources"
  the_localize_apt_sources Debian trixie "$CASE_ROOT" &&
    [ -f "$CASE_ROOT/sources.list.d/onedebian-security.list" ]
}

unknown_source() {
  printf 'deb https://custom.invalid/debian trixie main\n' >"$CASE_ROOT/sources.list"
  cp "$CASE_ROOT/sources.list" "$CASE_ROOT/original"
  if the_localize_apt_sources Debian trixie "$CASE_ROOT"; then return 1; fi
  cmp "$CASE_ROOT/original" "$CASE_ROOT/sources.list" && [ ! -e "$CASE_ROOT/sources.list.onedebian.bak" ]
}

reject_source_symlink() {
  printf 'deb http://deb.debian.org/debian trixie main\n' >"$CASE_ROOT/original"
  ln -s "$CASE_ROOT/original" "$CASE_ROOT/sources.list" || return 1
  if the_localize_apt_sources Debian trixie "$CASE_ROOT"; then return 1; fi
  grep -Fx 'deb http://deb.debian.org/debian trixie main' "$CASE_ROOT/original"
}

reject_backup_symlink() {
  printf 'deb http://deb.debian.org/debian trixie main\n' >"$CASE_ROOT/sources.list"
  printf 'do not overwrite\n' >"$CASE_ROOT/protected"
  ln -s "$CASE_ROOT/protected" "$CASE_ROOT/sources.list.onedebian.bak" || return 1
  if the_localize_apt_sources Debian trixie "$CASE_ROOT"; then return 1; fi
  grep -Fx 'do not overwrite' "$CASE_ROOT/protected" &&
    grep -Fx 'deb http://deb.debian.org/debian trixie main' "$CASE_ROOT/sources.list"
}

ubuntu_sources() {
  printf 'deb http://us.archive.ubuntu.com/ubuntu noble main universe\ndeb http://security.ubuntu.com/ubuntu noble-security main universe\n' >"$CASE_ROOT/sources.list"
  the_localize_apt_sources Ubuntu noble "$CASE_ROOT" &&
    grep -Fx 'deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu noble main universe' "$CASE_ROOT/sources.list" &&
    grep -Fx 'deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu noble-security main universe' "$CASE_ROOT/sources.list" &&
    [ ! -e "$CASE_ROOT/sources.list.d/onedebian-security.list" ]
}

ubuntu_ports() {
  printf 'deb http://ports.ubuntu.com/ubuntu-ports noble main universe\n' >"$CASE_ROOT/sources.list"
  dpkg() { [ "$1" = --print-architecture ] && printf 'arm64\n'; }
  the_localize_apt_sources Ubuntu noble "$CASE_ROOT" &&
    grep -Fx 'deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports noble main universe' "$CASE_ROOT/sources.list" &&
    grep -Fx 'deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports noble-security main' "$CASE_ROOT/sources.list.d/onedebian-security.list"
}

bootstrap_stubs() {
  id() { printf '0\n'; }
  the_os_release() { printf 'Debian\n'; }
  the_code_name() { printf 'trixie\n'; }
  the_localize_apt_sources() { printf 'sources\n' >>"$CASE_ROOT/calls"; }
  apt-get() {
    printf '%s\n' "$*" >>"$CASE_ROOT/calls"
    case " $* " in *" $FAIL_AT "*) [ -z "$FAIL_AT" ] || return 42 ;; esac
  }
  dpkg-query() { printf '%s' "${PACKAGE_STATUS:-installed}"; }
  dpkg() { [ "$1" = --audit ] || return 91; printf '%s' "${AUDIT:-}"; }
  FAIL_AT=
  : >"$CASE_ROOT/calls"
}

bootstrap_success() {
  bootstrap_stubs
  the_bootstrap || return 1
  grep -F 'APT::Update::Error-Mode=any update' "$CASE_ROOT/calls" &&
    grep -F -- '--force-confold upgrade --with-new-pkgs' "$CASE_ROOT/calls" &&
    grep -F 'install nano net-tools htop wget curl git' "$CASE_ROOT/calls" &&
    [ "$DEBIAN_FRONTEND" = noninteractive ]
}

update_failure_stops() {
  bootstrap_stubs; FAIL_AT=update
  if the_bootstrap; then return 1; fi
  ! grep -Eq 'upgrade|install' "$CASE_ROOT/calls"
}

upgrade_failure_stops() {
  bootstrap_stubs; FAIL_AT=upgrade
  if the_bootstrap; then return 1; fi
  ! grep -F ' install ' "$CASE_ROOT/calls"
}

install_failure_propagates() {
  bootstrap_stubs; FAIL_AT=install
  if the_bootstrap; then return 1; fi
}

verification_failure_propagates() {
  bootstrap_stubs; PACKAGE_STATUS=unpacked
  if the_bootstrap; then return 1; fi
}

audit_failure_propagates() {
  bootstrap_stubs; AUDIT='package needs configuration'
  if the_bootstrap; then return 1; fi
}

interactive_decline() {
  apt-get() { printf 'unexpected apt call\n' >"$CASE_ROOT/unexpected"; return 99; }
  the_basic_setup <<<'n' && [ ! -e "$CASE_ROOT/unexpected" ]
}

direct_entry_from_other_directory() {
  id() { printf '1000\n'; }
  export -f id
  cd "$CASE_ROOT" || return 1
  if bash "$TEST_DIR/../bootstrap.sh" >"$CASE_ROOT/direct.output" 2>&1; then return 1; fi
  grep -Fx 'Root required.' "$CASE_ROOT/direct.output"
}

run_test 'legacy sources preserve options, security, third parties and original backup' legacy_sources
run_test 'deb822 preserves stanzas and signing keys without adding duplicate sources' deb822_sources
run_test 'missing security is added exactly once' missing_security
run_test 'disabled and commented security do not suppress an active security source' disabled_security
run_test 'unrecognized base source fails without modification' unknown_source
run_test 'source symlinks are rejected before changes' reject_source_symlink
run_test 'backup symlink cannot overwrite another file' reject_backup_symlink
run_test 'Ubuntu archive and security sources are localized' ubuntu_sources
run_test 'Ubuntu ARM uses ubuntu-ports' ubuntu_ports
run_test 'bootstrap runs both operations and verifies package state' bootstrap_success
run_test 'update failure stops upgrade and installation' update_failure_stops
run_test 'upgrade failure stops installation' upgrade_failure_stops
run_test 'install failure reaches the caller' install_failure_propagates
run_test 'unconfigured package prevents successful completion' verification_failure_propagates
run_test 'dpkg audit findings prevent successful completion' audit_failure_propagates
run_test 'interactive menu decline performs no installation' interactive_decline
run_test 'direct entry resolves components from any directory and enforces root' direct_entry_from_other_directory
printf 'Bootstrap regressions: %s tests, %s failures.\n' "$TEST_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
