#!/bin/bash
# Shared primitives for deterministic, fail-closed third-party builds.

set -euo pipefail

SP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SP_THIRDPARTY="$SP_ROOT/ThirdParty"
SP_DEPS_LOCK="$SP_THIRDPARTY/deps.lock.json"
SP_DEPS_HELPER="$SP_ROOT/Scripts/lib/deps_lock.py"
SP_DOWNLOADS="$SP_THIRDPARTY/downloads"

sp_die() {
  echo "error: $*" >&2
  exit 1
}

sp_find_tool() {
  local name="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  candidate="$(command -v "$name" 2>/dev/null || true)"
  [ -n "$candidate" ] && [ -x "$candidate" ] || sp_die "required build tool not found: $name"
  printf '%s\n' "$candidate"
}

sp_lock_get() {
  python3 "$SP_DEPS_HELPER" --lock "$SP_DEPS_LOCK" get "$@"
}

sp_reset_build_env() {
  # Do not let shell, Homebrew, Xcode, or a caller inject compilation/search
  # flags. Required dependency paths are added explicitly by each recipe.
  unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH
  unset CFLAGS CXXFLAGS CPPFLAGS OBJCFLAGS LDFLAGS SDKROOT
  unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR PKG_CONFIG
  unset PKG_CONFIG_ALLOW_SYSTEM_CFLAGS PKG_CONFIG_ALLOW_SYSTEM_LIBS
  unset CMAKE_PREFIX_PATH CMAKE_INCLUDE_PATH CMAKE_LIBRARY_PATH
  unset MESON_PACKAGE_CACHE_DIR ACLOCAL_PATH CONFIG_SITE ARCHFLAGS
  unset MAKEFLAGS MFLAGS NINJAFLAGS CCACHE_DIR CCACHE_BASEDIR SCCACHE_DIR
  unset CC CXX CPP LD AR AS NM RANLIB STRIP
  unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH MACOSX_DEPLOYMENT_TARGET
  unset SOURCE_DATE_EPOCH DEVELOPER_DIR
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
  export LC_ALL=C
  export LANG=C
  export TZ=UTC
  export ZERO_AR_DATE=1
  export SOURCE_DATE_EPOCH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target"]["source_date_epoch"])' "$SP_DEPS_LOCK")"
  export DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
  export MACOSX_DEPLOYMENT_TARGET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target"]["macos_min"])' "$SP_DEPS_LOCK")"
  export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  export CC="$(xcrun --sdk macosx --find clang)"
  export CXX="$(xcrun --sdk macosx --find clang++)"
  export AR="$(xcrun --sdk macosx --find ar)"
  export LD="$(xcrun --sdk macosx --find ld)"
  export RANLIB="$(xcrun --sdk macosx --find ranlib)"
  export STRIP="$(xcrun --sdk macosx --find strip)"
  export PKG_CONFIG_PATH=""
  export PKG_CONFIG_LIBDIR=""
  export PKG_CONFIG_SYSROOT_DIR=""
  export SP_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
  umask 022
}

sp_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

sp_verified_download() {
  local url="$1"
  local expected="$2"
  local destination="$3"
  local actual temporary
  mkdir -p "$(dirname "$destination")"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -f "$destination" ] && [ ! -L "$destination" ] || \
      sp_die "download destination is not a regular file: $destination"
    actual="$(sp_sha256 "$destination")"
    if [ "$actual" = "$expected" ]; then
      echo "==> Reusing verified download: $(basename "$destination")"
      return 0
    fi
    echo "==> Cached download failed verification; downloading again: $(basename "$destination")"
  fi
  temporary="$(mktemp "${destination}.tmp.XXXXXX")"
  if ! /usr/bin/curl -fL --retry 3 --connect-timeout 15 --output "$temporary" "$url"; then
    rm -f "$temporary"
    sp_die "download failed: $url"
  fi
  actual="$(sp_sha256 "$temporary")"
  if [ "$actual" != "$expected" ]; then
    rm -f "$temporary"
    sp_die "$(basename "$destination") SHA-256 mismatch: $actual"
  fi
  # `mv -f file existing-directory` succeeds by nesting the download inside
  # that directory. os.replace has the file-to-file semantics needed here and
  # fails instead, so a stale directory can never masquerade as a published
  # archive even if it appears after the check above.
  if ! python3 - "$temporary" "$destination" <<'PY'
import os
import sys

os.replace(sys.argv[1], sys.argv[2])
PY
  then
    rm -f "$temporary"
    sp_die "failed to publish download cache: $destination"
  fi
}

sp_extract_archive() {
  local archive="$1"
  local destination="$2"
  mkdir -p "$destination"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$destination" ;;
    *.tar.xz) tar -xJf "$archive" -C "$destination" ;;
    *) sp_die "unsupported source archive: $archive" ;;
  esac
}

sp_recipe_hash() {
  python3 "$SP_DEPS_HELPER" --lock "$SP_DEPS_LOCK" recipe-hash "$@"
}

sp_stamp_matches() {
  local stamp="$1"
  local recipe_hash="$2"
  [ -f "$stamp" ] && python3 "$SP_DEPS_HELPER" stamp-matches \
    --stamp "$stamp" --recipe-hash "$recipe_hash"
}

sp_all_files_exist() {
  local path
  for path in "$@"; do
    [ -s "$path" ] || return 1
  done
}

sp_write_stamp() {
  local output="$1"
  shift
  python3 "$SP_DEPS_HELPER" --lock "$SP_DEPS_LOCK" write-stamp \
    --output "$output" "$@"
}

sp_paths_are_nested() {
  local first="$1"
  local second="$2"
  case "$first/" in
    "$second/"*) return 0 ;;
  esac
  case "$second/" in
    "$first/"*) return 0 ;;
  esac
  return 1
}

_sp_atomic_directory_transaction() {
  local operation="$1"
  local staged="$2"
  local final="$3"
  local allowed_root="$4"
  local validator="${5:-}"
  local staged_path="" final_parent final_name final_path thirdparty_path allowed_root_path backup
  local staged_device final_device lock_root lock_key lock_file lock_timeout

  case "$operation" in
    replace|recover) ;;
    *) sp_die "unknown directory publication operation: $operation" ;;
  esac
  if [ "$operation" = "replace" ]; then
    [ -d "$staged" ] || sp_die "staged directory does not exist: $staged"
    [ ! -L "$staged" ] || sp_die "staged directory must not be a symbolic link: $staged"
    staged_path="$(cd "$staged" && pwd -P)"
  fi
  [ -d "$SP_THIRDPARTY" ] || sp_die "ThirdParty directory does not exist: $SP_THIRDPARTY"
  [ -d "$allowed_root" ] || sp_die "allowed publication root does not exist: $allowed_root"

  final_parent="$(cd "$(dirname "$final")" && pwd -P)"
  final_name="$(basename "$final")"
  case "$final_name" in
    .|..) sp_die "invalid publication target name: $final" ;;
  esac
  final_path="$final_parent/$final_name"
  thirdparty_path="$(cd "$SP_THIRDPARTY" && pwd -P)"
  allowed_root_path="$(cd "$allowed_root" && pwd -P)"
  backup="${final_path}.publish-backup"
  lock_root="$thirdparty_path/downloads/.publish-locks"

  case "$final_path" in
    "$allowed_root_path"/*) ;;
    *) sp_die "refusing to replace a directory outside the publication root: $final" ;;
  esac
  if sp_paths_are_nested "$final_path" "$lock_root"; then
    sp_die "publication and lock directories must not contain one another"
  fi
  if [ "$operation" = "replace" ] && \
      { sp_paths_are_nested "$staged_path" "$final_path" || \
        sp_paths_are_nested "$staged_path" "$backup" || \
        sp_paths_are_nested "$staged_path" "$lock_root"; }; then
    sp_die "staged, publication, backup, and lock directories must not contain one another"
  fi

  # A cross-device mv copies recursively before deleting the source. Refuse it
  # so every state transition below remains a single filesystem rename.
  if [ "$operation" = "replace" ]; then
    staged_device="$(/usr/bin/stat -f '%d' "$staged_path")"
    final_device="$(/usr/bin/stat -f '%d' "$final_parent")"
    [ "$staged_device" = "$final_device" ] || \
      sp_die "staged and target directories are not on the same filesystem: $staged"
  fi

  # lockf is part of macOS. Holding the lock on an inherited file descriptor
  # avoids stale PID locks: normal exits, signals, and SIGKILL all release it.
  # The file itself deliberately persists to prevent unlink/recreate races.
  [ -x /usr/bin/lockf ] || sp_die "system publication-lock tool not found: /usr/bin/lockf"
  mkdir -p "$lock_root"
  lock_key="$(printf '%s' "$final_path" | shasum -a 256 | awk '{print $1}')"
  lock_file="$lock_root/$lock_key.lock"
  lock_timeout="${SP_PUBLISH_LOCK_TIMEOUT_SECONDS:-120}"
  case "$lock_timeout" in
    ''|*[!0-9]*) sp_die "invalid publication-lock timeout: $lock_timeout" ;;
  esac

  (
    # EXIT runs after Bash has unwound the caller's local scope. Keep the
    # transaction record process-local (this whole block is a subshell) so the
    # rollback trap still has its paths and state under Bash 3.2.
    SP_PUBLISH_TRANSACTION_OPEN=0
    SP_PUBLISH_HAD_FINAL=0
    SP_PUBLISH_INSTALLED_FINAL=0
    SP_PUBLISH_FINAL_PATH="$final_path"
    SP_PUBLISH_BACKUP="$backup"

    sp_publish_rollback() {
      local rollback_failed=0
      trap - HUP INT TERM
      if [ "$SP_PUBLISH_TRANSACTION_OPEN" -eq 1 ] && \
          [ "$SP_PUBLISH_HAD_FINAL" -eq 1 ] && \
          { [ -e "$SP_PUBLISH_BACKUP" ] || [ -L "$SP_PUBLISH_BACKUP" ]; }; then
        if [ -e "$SP_PUBLISH_FINAL_PATH" ] || [ -L "$SP_PUBLISH_FINAL_PATH" ]; then
          rm -rf "$SP_PUBLISH_FINAL_PATH" || rollback_failed=1
        fi
        if [ ! -e "$SP_PUBLISH_FINAL_PATH" ] && \
            [ ! -L "$SP_PUBLISH_FINAL_PATH" ]; then
          mv "$SP_PUBLISH_BACKUP" "$SP_PUBLISH_FINAL_PATH" || rollback_failed=1
        fi
      elif [ "$SP_PUBLISH_TRANSACTION_OPEN" -eq 1 ] && \
          [ "$SP_PUBLISH_HAD_FINAL" -eq 0 ] && \
          [ "$SP_PUBLISH_INSTALLED_FINAL" -eq 1 ]; then
        rm -rf "$SP_PUBLISH_FINAL_PATH" || rollback_failed=1
      fi
      if [ "$rollback_failed" -ne 0 ]; then
        echo "error: publication rollback is incomplete and will be recovered on the next attempt: $SP_PUBLISH_FINAL_PATH" >&2
      fi
    }

    sp_publish_on_exit() {
      local status=$?
      trap - EXIT
      sp_publish_rollback
      exit "$status"
    }

    exec 9>"$lock_file" || sp_die "failed to open publication lock: $lock_file"
    if ! /usr/bin/lockf -s -t "$lock_timeout" 9; then
      sp_die "timed out after ${lock_timeout}s waiting for publication lock: $final_path"
    fi

    trap sp_publish_on_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Recover the only two durable interrupted states. If final is missing,
    # the old prefix was moved aside before the process died. If both exist,
    # the new prefix was already installed and only backup cleanup was lost.
    if [ -e "$backup" ] || [ -L "$backup" ]; then
      [ -d "$backup" ] && [ ! -L "$backup" ] || \
        sp_die "publication backup is not a regular directory: $backup"
      if [ -e "$final_path" ] || [ -L "$final_path" ]; then
        [ -d "$final_path" ] && [ ! -L "$final_path" ] || \
          sp_die "publication target is not a regular directory: $final_path"
        # Retain the previous app until the final-path signature is verified.
        if [ -n "$validator" ] && ! "$validator" "$final_path"; then
          rm -rf "$final_path" || sp_die "failed to remove invalid publication: $final_path"
          mv "$backup" "$final_path" || sp_die "failed to restore previous publication: $final_path"
        else
          rm -rf "$backup" || sp_die "failed to remove a completed publication backup: $backup"
        fi
      else
        mv "$backup" "$final_path" || \
          sp_die "failed to recover an interrupted directory publication: $final_path"
      fi
    fi

    if [ "$operation" = "recover" ]; then
      trap - EXIT HUP INT TERM
      exit 0
    fi

    if [ -e "$final_path" ] || [ -L "$final_path" ]; then
      [ -d "$final_path" ] && [ ! -L "$final_path" ] || \
        sp_die "publication target is not a regular directory: $final_path"
      [ ! -e "$backup" ] && [ ! -L "$backup" ] || \
        sp_die "publication backup still exists: $backup"
      # Record the intent before rename. A signal can be delivered after the
      # child mv changed the filesystem but before Bash executes the following
      # assignment; the rollback therefore uses backup existence as evidence.
      SP_PUBLISH_HAD_FINAL=1
      SP_PUBLISH_TRANSACTION_OPEN=1
      mv "$final_path" "$backup" || \
        sp_die "failed to back up the current installation directory: $final_path"
    fi

    # Never let mv interpret an unexpectedly recreated final as a container;
    # that would silently publish staged as final/<basename(staged)>.
    [ ! -e "$final_path" ] && [ ! -L "$final_path" ] || \
      sp_die "publication target was unexpectedly recreated during the transaction: $final_path"
    SP_PUBLISH_TRANSACTION_OPEN=1
    if ! mv "$staged_path" "$final_path"; then
      sp_die "failed to replace the installation directory atomically: $final_path"
    fi
    SP_PUBLISH_INSTALLED_FINAL=1
    if [ -n "$validator" ] && ! "$validator" "$final_path"; then
      sp_die "final publication validation failed: $final_path"
    fi
    SP_PUBLISH_TRANSACTION_OPEN=0

    if [ -e "$backup" ] || [ -L "$backup" ]; then
      rm -rf "$backup" || sp_die "failed to remove the previous installation directory: $backup"
    fi

    trap - EXIT HUP INT TERM
  )
}

sp_recover_atomic_directory() {
  local final="$1"
  local allowed_root="${2:-$SP_THIRDPARTY}"
  local validator="${3:-}"
  _sp_atomic_directory_transaction recover "" "$final" "$allowed_root" "$validator"
}

sp_atomic_replace_directory() {
  local staged="$1"
  local final="$2"
  local allowed_root="${3:-$SP_THIRDPARTY}"
  local validator="${4:-}"
  _sp_atomic_directory_transaction replace "$staged" "$final" "$allowed_root" "$validator"
}
