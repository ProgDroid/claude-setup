#!/usr/bin/env bash
# Build (or tear down) a scratch home for live OpenCode tests of the CC parity adapter.
#
#   make-scratch-home.sh <dir> [--no-plugins]   build
#   make-scratch-home.sh --teardown <dir>        unlink the junctions, delete the auth copy and <dir>
#
# The scratch home gives OpenCode real config and a real plugin cache, but its own HOME, so a
# failed deny in a permission test can only ever touch files under <dir>:
#
#   <dir>/.local/share/opencode/auth.json  copy of the real one (delete it after the run)
#   <dir>/.config/opencode                 link -> the real ~/.config/opencode (the loader)
#   <dir>/.claude/plugins                  link -> the real ~/.claude/plugins (omitted by --no-plugins)
#   <dir>/.claude/settings.json            a test settings file (empty permission lists, no hooks)
#
# Spawn OpenCode with the env this script prints. Pass env explicitly: `setx` and profile edits
# never reach processes that are already running.
#
# On Windows the links are directory junctions (no admin or developer mode needed).
#
# --teardown sits beside live user state, so it is defensive:
#   - it refuses any dir without the .cc-parity-scratch-home marker that the build writes;
#   - it unlinks both links without recursing;
#   - then, before any recursive delete, it refuses if either link path still exists or still
#     resolves to the real config or plugin cache.
# A junction that MSYS fails to report as a link therefore stops the teardown instead of being
# traversed.
set -euo pipefail

die() { printf 'make-scratch-home: %s\n' "$*" >&2; exit 1; }

is_windows() {
  case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; *) return 1 ;; esac
}

# link <target> <linkpath>
link_dir() {
  local target=$1 linkpath=$2
  [ -e "$linkpath" ] || [ -L "$linkpath" ] && die "refusing to overwrite existing $linkpath"
  if is_windows; then
    cmd //c mklink //J "$(cygpath -w "$linkpath")" "$(cygpath -w "$target")" >/dev/null ||
      die "mklink /J failed for $linkpath"
  else
    ln -s "$target" "$linkpath"
  fi
}

present() { [ -e "$1" ] || [ -L "$1" ]; }

# Canonical path with every link and junction resolved; empty if it cannot be resolved.
canon() { readlink -f -- "$1" 2>/dev/null || true; }

# A second junction detector that does not rely on MSYS reporting the junction to `[ -L ]`:
# ask Windows itself for reparse points (attribute L) in the parent directory.
is_reparse_point() {
  is_windows || return 1
  local parent name
  parent=$(dirname -- "$1") name=$(basename -- "$1")
  cmd //c dir //AL //B "$(cygpath -w "$parent")" 2>/dev/null | tr -d '\r' | grep -qxF -- "$name"
}

# Remove a link without ever recursing into it. Windows `rmdir` (no /S) removes a junction or an
# EMPTY directory and fails on anything else; elsewhere `rm` removes a symlink and `rmdir` an empty
# directory. A real, non-empty directory therefore survives every branch.
unlink_dir() {
  local linkpath=$1
  present "$linkpath" || return 0
  if is_windows; then
    cmd //c rmdir "$(cygpath -w "$linkpath")" >/dev/null 2>&1 || true
  elif [ -L "$linkpath" ]; then
    rm -- "$linkpath"
  else
    rmdir -- "$linkpath" 2>/dev/null || true
  fi
}

MARKER=.cc-parity-scratch-home
real_home=${HOME:?HOME is not set}

if [ "${1:-}" = "--teardown" ]; then
  dir=${2:?usage: make-scratch-home.sh --teardown <dir>}
  [ -d "$dir" ] || die "no such dir: $dir"
  dir=$(cd "$dir" && pwd -P)
  [ "$dir" = "$(cd "$real_home" && pwd -P)" ] && die "refusing to tear down the real home"
  [ -f "$dir/$MARKER" ] || die "refusing: $dir has no $MARKER marker, so this script did not build it"

  links=("$dir/.config/opencode" "$dir/.claude/plugins")
  reals=("$(canon "$real_home/.config/opencode")" "$(canon "$real_home/.claude/plugins")")
  for l in "${links[@]}"; do
    if present "$l" && ! [ -L "$l" ] && is_reparse_point "$l"; then
      printf 'make-scratch-home: note: %s is a junction that [ -L ] did not report\n' "$l" >&2
    fi
    unlink_dir "$l"
  done

  # Postconditions, checked before anything recursive runs: both links are gone, and nothing at
  # either path still resolves into the real config or plugin cache.
  for l in "${links[@]}"; do
    present "$l" && die "refusing: $l still exists after unlinking; nothing deleted"
    c=$(canon "$l")
    for r in "${reals[@]}"; do
      [ -n "$r" ] && [ "$c" = "$r" ] && die "refusing: $l resolves to the real $r; nothing deleted"
    done
  done

  rm -f "$dir/.local/share/opencode/auth.json"
  rm -rf "$dir"
  printf 'torn down %s\n' "$dir"
  exit 0
fi

dir=${1:?usage: make-scratch-home.sh <dir> [--no-plugins] | --teardown <dir>}
plugins=1
case "${2:-}" in
  "") ;;
  --no-plugins) plugins=0 ;;
  *) die "unknown option: $2" ;;
esac

src_auth="$real_home/.local/share/opencode/auth.json"
src_config="$real_home/.config/opencode"
src_plugins="$real_home/.claude/plugins"

[ -f "$src_auth" ] || die "missing $src_auth"
[ -d "$src_config" ] || die "missing $src_config"
[ "$plugins" = 0 ] || [ -d "$src_plugins" ] || die "missing $src_plugins"

mkdir -p "$dir"
dir=$(cd "$dir" && pwd -P)
[ "$dir" = "$(cd "$real_home" && pwd -P)" ] && die "refusing to use the real home as a scratch home"
# Only an empty dir, or one this script built, may become a scratch home: the marker written
# below is what licenses --teardown to delete it.
if [ ! -f "$dir/$MARKER" ] && [ -n "$(ls -A "$dir")" ]; then
  die "refusing: $dir is not empty and has no $MARKER marker"
fi
: >"$dir/$MARKER"

for p in "$dir/.config/opencode" "$dir/.claude/plugins"; do
  [ -e "$p" ] || [ -L "$p" ] && die "refusing to overwrite existing $p (tear it down first)"
done
mkdir -p "$dir/.local/share/opencode" "$dir/.config" "$dir/.claude"

(umask 077 && cp "$src_auth" "$dir/.local/share/opencode/auth.json")
link_dir "$src_config" "$dir/.config/opencode"
[ "$plugins" = 0 ] || link_dir "$src_plugins" "$dir/.claude/plugins"

cat >"$dir/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": [],
    "ask": [],
    "deny": []
  }
}
JSON

if is_windows; then win_dir=$(cygpath -w "$dir"); else win_dir=$dir; fi
cat <<EOF
scratch home ready: $dir
spawn OpenCode with:
  HOME='$dir' USERPROFILE='$win_dir' CC_PARITY_STATE='$dir/state.json' <explicit OPENCODE_* vars> opencode ...
when done: $0 --teardown '$dir'
EOF
