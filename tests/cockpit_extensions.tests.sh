#!/usr/bin/env bash
# Offline regression checks. All privileged/network commands are shell stubs.
# Run from any directory: bash /path/to/oneDebian/tests/cockpit_extensions.tests.sh

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
PRODUCT="$TEST_DIR/../components/the_cockpit_extensions_installation.sh"
TEST_ROOT=$(command mktemp -d "${TMPDIR:-/tmp}/onedebian-cockpit-tests.XXXXXXXX") || exit 1
trap 'command rm -rf -- "$TEST_ROOT"' EXIT
TEST_COUNT=0
FAIL_COUNT=0

record() { printf '%s\n' "$*" >>"$CASE_ROOT/commands"; }
fail() { printf '    %s\n' "$*" >&2; return 1; }
contains() {
  local line
  while IFS= read -r line; do
    case "$line" in *"$2"*) return 0 ;; esac
  done <"$1"
  return 1
}
assert_called() { contains "$CASE_ROOT/commands" "$1" || fail "Missing command: $1"; }
assert_not_called() { ! contains "$CASE_ROOT/commands" "$1" || fail "Unexpected command: $1"; }
assert_output() { contains "$CASE_ROOT/output" "$1" || fail "Missing output: $1"; }
invoke() { "$@" >"$CASE_ROOT/output" 2>&1; }
expect_failure() { if invoke "$@"; then fail "Expected nonzero status: $*"; else return 0; fi; }
expect_success() { invoke "$@" || fail "Expected zero status: $*"; }

setup_stubs() {
  STUB_UID=0
  STUB_PLATFORM=debian:bookworm
  STUB_SYSTEMD=0
  STUB_CANDIDATE=45-1~bpo13+1
  STUB_FILES_VERSION_OK=0
  STUB_UPDATE=0
  STUB_INSTALL=0
  STUB_CURL=0
  STUB_INSTALLED=
  STUB_INSTALLED_VERSION_OK=0
  STUB_METADATA_PACKAGE=cockpit-file-sharing
  STUB_METADATA_VERSION=4.6.3-1bookworm
  STUB_METADATA_ARCH=all
  STUB_TESTPARM=0
  STUB_ROLE='standalone server'
  STUB_ACTIVE=0
  STUB_ENABLE=0
  STUB_SMB_CONF=1
  STUB_REQUIRE_UCF=0
  unset UCF_FORCE_CONFFOLD

  # Model absolute-path existence without consulting or changing host state.
  function [ {
    case "$1:$2" in
    -e:/usr/share/cockpit/navigator | -L:/usr/share/cockpit/navigator) return 1 ;;
    -f:/etc/samba/smb.conf) return "$STUB_SMB_CONF" ;;
    esac
    builtin [ "$@"
  }

  id() { if [ "$*" = '-u' ]; then printf '%s\n' "$STUB_UID"; else return 97; fi; }
  systemctl() {
    record "systemctl $*"
    case "$1" in
    show-environment) return "$STUB_SYSTEMD" ;;
    enable) return "$STUB_ENABLE" ;;
    is-active) return "$STUB_ACTIVE" ;;
    *) return 97 ;;
    esac
  }
  apt-get() {
    record "apt-get $*"
    if [ "$STUB_REQUIRE_UCF" = 1 ] && [ "$(command printenv UCF_FORCE_CONFFOLD)" != 1 ]; then
      record 'MISSING UCF_FORCE_CONFFOLD=1'
      return 96
    fi
    case "$1" in update) return "$STUB_UPDATE" ;; esac
    return "$STUB_INSTALL"
  }
  apt-cache() { record "apt-cache $*"; printf '  Candidate: %s\n' "$STUB_CANDIDATE"; }
  dpkg() {
    record "dpkg $*"
    [ "$1" = --compare-versions ] && [ "$3" = ge ] || return 97
    if [ "$4" = 45 ]; then return "$STUB_FILES_VERSION_OK"; fi
    [ "$4" = 4.6.3-1bookworm ] || return 97
    return "$STUB_INSTALLED_VERSION_OK"
  }
  dpkg-query() {
    record "dpkg-query $*"
    [ -n "$STUB_INSTALLED" ] || return 1
    case "$*" in
    *'${db:Status-Status}'*) printf installed ;;
    *'${Version}'*) printf '%s' "$STUB_INSTALLED" ;;
    *) return 97 ;;
    esac
  }
  dpkg-deb() {
    record "dpkg-deb $*"
    case "$3" in
    Package) printf '%s\n' "$STUB_METADATA_PACKAGE" ;;
    Version) printf '%s\n' "$STUB_METADATA_VERSION" ;;
    Architecture) printf '%s\n' "$STUB_METADATA_ARCH" ;;
    *) return 97 ;;
    esac
  }
  curl() {
    record "curl $*"
    [ "$STUB_CURL" = 0 ] || return "$STUB_CURL"
    local target
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --output ]; then shift; target=$1; break; fi
      shift
    done
    case "$target" in "$CASE_ROOT"/*) printf fixture >"$target" ;; *) return 97 ;; esac
  }
  mktemp() {
    record "mktemp $*"
    # Even smb.conf backups must stay in this test's private fixture directory.
    if [ "$1" = -d ]; then
      command mktemp -d "$CASE_ROOT/work.XXXXXXXX"
    else
      command mktemp "$CASE_ROOT/backup.XXXXXXXX"
    fi
  }
  rm() {
    record "rm $*"
    local target=${!#}
    case "$target" in "$CASE_ROOT"/*) command rm "$@" ;; *) return 97 ;; esac
  }
  # Any accidental fall-through into a real install is both blocked and logged.
  tar() { record "FORBIDDEN tar $*"; return 97; }
  install() { record "FORBIDDEN install $*"; return 97; }
  mv() { record "FORBIDDEN mv $*"; return 97; }
  cp() { record "cp $*"; return 0; }
  chmod() { record "chmod $*"; return 0; }
  testparm() {
    record "testparm $*"
    [ "$STUB_TESTPARM" = 0 ] || return "$STUB_TESTPARM"
    case "$*" in *'server role'*) printf '%s\n' "$STUB_ROLE" ;; esac
  }
}

run_test() {
  TEST_COUNT=$((TEST_COUNT + 1))
  CASE_ROOT="$TEST_ROOT/case-$TEST_COUNT"
  command mkdir "$CASE_ROOT" || exit 1
  : >"$CASE_ROOT/commands"
  if (
    setup_stubs
    # Source under stubs so unexpected top-level side effects are also contained.
    . "$PRODUCT" || exit 1
    the_cockpit_extensions_platform() { printf '%s\n' "$STUB_PLATFORM"; }
    "$2"
  ); then
    printf 'ok %d - %s\n' "$TEST_COUNT" "$1"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'not ok %d - %s\n' "$TEST_COUNT" "$1"
    [ ! -f "$CASE_ROOT/output" ] || command cat "$CASE_ROOT/output"
    command cat "$CASE_ROOT/commands"
  fi
}

source_is_inert() { [ ! -s "$CASE_ROOT/commands" ]; }
cancel_files() {
  expect_success the_cockpit_file_browser_installation <<<'n' &&
    assert_not_called 'apt-get' && assert_not_called 'systemctl enable'
}
cancel_smb() {
  expect_success the_cockpit_smb_installation <<<'n' &&
    assert_not_called 'apt-get' && assert_not_called 'systemctl enable'
}
reject_nonroot() {
  STUB_UID=1000
  expect_failure the_cockpit_file_browser_installation <<<'y' &&
    assert_not_called 'apt-get' && assert_not_called 'systemctl'
}
reject_nonsystemd() {
  STUB_SYSTEMD=1
  expect_failure the_cockpit_smb_installation <<<'y' &&
    assert_not_called 'apt-get' && assert_not_called 'systemctl enable'
}
reject_os() {
  STUB_PLATFORM=fedora:44
  expect_failure the_cockpit_file_browser_installation <<<'y' && assert_not_called 'apt-get'
}
reject_smb_suite() {
  STUB_PLATFORM=ubuntu:noble
  expect_failure the_cockpit_smb_installation <<<'y' &&
    assert_not_called 'apt-get' && assert_not_called 'curl'
}
download_checksum_success() {
  local checksum
  checksum=$(printf fixture | command sha256sum)
  checksum=${checksum%% *}
  expect_success the_cockpit_extensions_download https://example.invalid/file "$checksum" "$CASE_ROOT/download" &&
    assert_called "--proto =https --proto-redir =https" && [ -f "$CASE_ROOT/download" ]
}
download_network_failure() {
  STUB_CURL=22
  expect_failure the_cockpit_extensions_download https://example.invalid/file unused "$CASE_ROOT/download" &&
    [ ! -e "$CASE_ROOT/download" ]
}
download_checksum_failure() {
  expect_failure the_cockpit_extensions_download https://example.invalid/file \
    0000000000000000000000000000000000000000000000000000000000000000 "$CASE_ROOT/download"
}
files_update_failure() {
  STUB_UPDATE=1
  expect_failure the_cockpit_file_browser_installation <<<'y' &&
    assert_not_called 'apt-cache' && assert_not_called 'systemctl enable'
}
files_current_candidate() {
  expect_success the_cockpit_file_browser_installation <<<'y' &&
    assert_called 'dpkg --compare-versions 45-1~bpo13+1 ge 45' &&
    assert_called 'install -y --no-install-recommends cockpit cockpit-files' &&
    assert_called 'systemctl enable --now cockpit.socket' && assert_not_called 'curl'
}
files_old_candidate() {
  STUB_CANDIDATE=39-1~bpo24.04.1
  STUB_FILES_VERSION_OK=1
  STUB_CURL=22
  expect_failure the_cockpit_file_browser_installation <<<'y' &&
    assert_called 'dpkg --compare-versions 39-1~bpo24.04.1 ge 45' &&
    assert_called 'cockpit python3 rsync zip file coreutils inotify-tools' &&
    assert_called 'cockpit-navigator/archive/refs/tags/v0.5.14-1.tar.gz' &&
    assert_not_called 'FORBIDDEN' && assert_not_called 'systemctl enable'
}
files_no_candidate() {
  STUB_CANDIDATE='(none)'
  STUB_CURL=22
  expect_failure the_cockpit_file_browser_installation <<<'y' &&
    assert_not_called 'dpkg --compare-versions' &&
    assert_called 'cockpit-navigator/archive/refs/tags/v0.5.14-1.tar.gz' &&
    assert_not_called 'FORBIDDEN' && assert_not_called 'systemctl enable'
}
files_install_failure() {
  STUB_INSTALL=100
  expect_failure the_cockpit_file_browser_installation <<<'y' &&
    assert_not_called 'systemctl enable'
}
smb_download_failure() {
  STUB_CURL=22
  expect_failure the_cockpit_smb_installation <<<'y' &&
    assert_not_called 'dpkg-deb' && assert_not_called 'cockpit samba samba-common-bin' &&
    assert_not_called 'systemctl enable'
}
smb_checksum_failure() {
  expect_failure the_cockpit_smb_installation <<<'y' &&
    assert_not_called 'dpkg-deb' && assert_not_called 'cockpit samba samba-common-bin' &&
    assert_not_called 'systemctl enable'
}
stub_valid_package_download() {
  the_cockpit_extensions_download() { record "verified-download $*"; printf fixture >"$3"; }
}
smb_wrong_name() {
  stub_valid_package_download
  STUB_METADATA_PACKAGE=unrelated-package
  expect_failure the_cockpit_smb_installation <<<'y' &&
    assert_not_called 'cockpit samba samba-common-bin' && assert_not_called 'systemctl enable'
}
smb_wrong_version() {
  stub_valid_package_download
  STUB_METADATA_VERSION=4.6.3-1trixie
  expect_failure the_cockpit_smb_installation <<<'y' &&
    assert_called 'dpkg-deb' && assert_not_called 'cockpit samba samba-common-bin' &&
    assert_not_called 'systemctl enable'
}
smb_wrong_arch() {
  stub_valid_package_download
  STUB_METADATA_ARCH=amd64
  expect_failure the_cockpit_smb_installation <<<'y' &&
    assert_not_called 'cockpit samba samba-common-bin' && assert_not_called 'systemctl enable'
}
smb_newer_preserved() {
  STUB_INSTALLED=4.7.0-1bookworm
  expect_success the_cockpit_smb_installation <<<'y' &&
    assert_called 'dpkg --compare-versions 4.7.0-1bookworm ge 4.6.3-1bookworm' &&
    assert_not_called 'curl --fail' && assert_not_called 'verified-download' && assert_not_called 'dpkg-deb' &&
    assert_called 'systemctl enable --now cockpit.socket' && assert_called 'systemctl enable --now smbd'
}
smb_same_preserved() {
  STUB_INSTALLED=4.6.3-1bookworm
  expect_success the_cockpit_smb_installation <<<'y' &&
    assert_not_called 'curl --fail' && assert_called 'systemctl enable --now smbd'
}
smb_fresh_package() {
  stub_valid_package_download
  STUB_REQUIRE_UCF=1
  expect_success the_cockpit_smb_installation <<<'y' &&
    assert_called 'verified-download https://github.com/45Drives/cockpit-file-sharing/releases/download/v4.6.3/' &&
    assert_called 'dpkg-deb' &&
    assert_called "install -y --no-install-recommends cockpit samba samba-common-bin $CASE_ROOT/work." &&
    assert_not_called 'MISSING UCF_FORCE_CONFFOLD=1' &&
    assert_called 'systemctl enable --now cockpit.socket' && assert_called 'systemctl enable --now smbd'
}
smb_backup_isolated() {
  STUB_SMB_CONF=0
  STUB_UPDATE=1
  expect_failure the_cockpit_smb_installation <<<'y' &&
    assert_called 'mktemp /etc/samba/smb.conf.onedebian.XXXXXXXX.bak' &&
    assert_called "cp -pL -- /etc/samba/smb.conf $CASE_ROOT/backup." &&
    assert_not_called 'systemctl enable'
}
smb_final_apt_failure() {
  STUB_INSTALLED=4.7.0-1bookworm
  apt-get() {
    record "apt-get $*"
    case "$*" in *'cockpit samba samba-common-bin'*) return 100 ;; esac
  }
  expect_failure the_cockpit_smb_installation <<<'y' &&
    assert_not_called 'testparm' && assert_not_called 'systemctl enable'
}
smb_bad_config() {
  STUB_INSTALLED=4.7.0-1bookworm
  STUB_TESTPARM=1
  expect_failure the_cockpit_smb_installation <<<'y' && assert_not_called 'systemctl enable'
}
smb_ad_controller() {
  STUB_INSTALLED=4.7.0-1bookworm
  STUB_ROLE='active directory domain controller'
  expect_failure the_cockpit_smb_installation <<<'y' && assert_not_called 'systemctl enable'
}
inactive_is_failure() {
  STUB_ACTIVE=1
  expect_failure the_cockpit_file_browser_installation <<<'y' &&
    assert_called 'systemctl is-active --quiet cockpit.socket'
}

run_test 'sourcing performs no installation' source_is_inert
run_test 'file browser cancellation has no APT or service mutation' cancel_files
run_test 'SMB cancellation has no APT or service mutation' cancel_smb
run_test 'non-root is rejected before mutations' reject_nonroot
run_test 'missing running systemd is rejected' reject_nonsystemd
run_test 'unsupported OS is rejected' reject_os
run_test 'SMB unsupported package suite is rejected' reject_smb_suite
run_test 'download verifies a real matching SHA256' download_checksum_success
run_test 'network failure aborts download' download_network_failure
run_test 'real checksum mismatch is rejected' download_checksum_failure
run_test 'APT update failure cannot enable services' files_update_failure
run_test 'Files 45 or newer candidate follows APT branch' files_current_candidate
run_test 'Files 39 follows Navigator fallback and failed download stops it' files_old_candidate
run_test 'missing Files candidate follows Navigator fallback' files_no_candidate
run_test 'Files APT install failure cannot enable services' files_install_failure
run_test 'SMB failed download cannot install or enable services' smb_download_failure
run_test 'SMB checksum mismatch cannot install or enable services' smb_checksum_failure
run_test 'SMB package name metadata must match' smb_wrong_name
run_test 'SMB package version metadata must match its suite' smb_wrong_version
run_test 'SMB package architecture metadata must match' smb_wrong_arch
run_test 'SMB newer installed plugin is preserved' smb_newer_preserved
run_test 'SMB same installed plugin is preserved' smb_same_preserved
run_test 'fresh SMB package installs with verified metadata and preserves UCF config' smb_fresh_package
run_test 'existing Samba config backup is redirected into private fixture' smb_backup_isolated
run_test 'SMB final APT failure cannot enable services' smb_final_apt_failure
run_test 'invalid Samba config cannot enable services' smb_bad_config
run_test 'AD domain controller cannot enable standalone smbd' smb_ad_controller
run_test 'inactive service is reported as failure' inactive_is_failure
printf '\n%d tests, %d failures\n' "$TEST_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
