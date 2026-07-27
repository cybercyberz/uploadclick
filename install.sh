#!/bin/zsh
# Installer for the "Upload to PixelDrain Folder…" Finder Quick Action.
# Copies the helper programs into ~/.local/bin and installs the workflow into
# ~/Library/Services. Idempotent — safe to re-run to update an existing install.
#
# Usage:
#   ./install.sh                  build (if the Swift toolchain is present) then install
#   ./install.sh build            compile the AppKit windows only, no install
#   ./install.sh check-binaries   verify the committed binaries match src/ (CI)
#   ./install.sh uninstall        remove everything this script installed
set -eu

here="${0:A:h}"
bin_dir="$here/bin"
workflow="Upload to PixelDrain Folder….workflow"

dest_bin="$HOME/.local/bin"
dest_services="$HOME/Library/Services"
key_file="$HOME/.pixeldrain_api_key"

helpers=(pixeldrain-upload-fs pixeldrain-put pixeldrain-progress pixeldrain-picker)
swift_helpers=(pixeldrain-progress pixeldrain-picker)
manifest="$bin_dir/.build-manifest"

# The compiled binaries are committed so the action installs on a Mac without a
# Swift toolchain. That only works if they match src/, so every build records the
# source hashes it came from and `check-binaries` compares them.
manifest_lines() {
  local name
  local -a srcs
  for name in $swift_helpers; do srcs+=("src/$name.swift"); done
  # Paths stay repo-relative so the manifest is stable across checkout locations.
  ( cd "$here" && /usr/bin/shasum -a 256 $srcs )
}

binaries_are_current() {
  local name
  for name in $swift_helpers; do
    [[ -f "$bin_dir/$name" ]] || return 1
  done
  [[ -f "$manifest" ]] || return 1
  [[ "$(manifest_lines)" == "$(cat "$manifest")" ]]
}

# Compile the AppKit helpers from source into bin/:
#   pixeldrain-progress — the floating upload progress window
#   pixeldrain-picker   — the native NSBrowser destination-folder picker
# Requires the Swift toolchain from the macOS Command Line Tools (xcode-select
# --install), the same dependency the Quick Action already needs for python3.
# Returns non-zero (rather than exiting) so callers can fall back to the
# committed binaries.
do_build() {
  if ! xcrun --find swiftc >/dev/null 2>&1; then
    print -u2 -- "swiftc not found. Install the Command Line Tools: xcode-select --install"
    return 1
  fi
  mkdir -p "$bin_dir"
  local name src out
  for name in $swift_helpers; do
    src="$here/src/$name.swift"
    out="$bin_dir/$name"
    print -- "Compiling $src …"
    xcrun swiftc -O -o "$out" "$src" || return 1
    chmod +x "$out"
    print -- "Built $out"
  done
  manifest_lines > "$manifest"
}

do_uninstall() {
  print -- "Uninstalling PixelDrain Quick Action…"
  local f
  # pixeldrain-upload is the pre-Filesystem helper earlier versions installed.
  for f in $helpers pixeldrain-upload; do
    if [[ -e "$dest_bin/$f" ]]; then
      rm -f "$dest_bin/$f"
      print -- "  ✓ removed $dest_bin/$f"
    fi
  done
  if [[ -d "$dest_services/$workflow" ]]; then
    rm -rf "${dest_services:?}/${workflow:?}"
    print -- "  ✓ removed $dest_services/$workflow"
  fi
  print -- ""
  print -- "Left in place (delete by hand if you want them gone):"
  print -- "  $key_file"
  print -- "  $HOME/Library/Logs/pixeldrain-upload.log"
}

case "${1:-}" in
  build)
    # Strict: set -e propagates a build failure as a non-zero exit.
    do_build
    exit 0
    ;;
  check-binaries)
    if binaries_are_current; then
      print -- "✓ bin/ matches src/"
      exit 0
    fi
    print -u2 -- "✗ the committed binaries are missing or stale."
    print -u2 -- "  Run ./install.sh build and commit bin/ (including .build-manifest)."
    exit 1
    ;;
  uninstall)
    do_uninstall
    exit 0
    ;;
  "") ;;
  *)
    print -u2 -- "Unknown argument: $1"
    print -u2 -- "Usage: ./install.sh [build|check-binaries|uninstall]"
    exit 1
    ;;
esac

print -- "Installing PixelDrain Quick Action…"

# 0. Rebuild the AppKit windows from source so the installed binaries match src/.
#    Tolerant: if the toolchain is missing or the build fails, fall back to the
#    committed binaries instead of aborting. (do_build inside the `if` suspends
#    set -e, so a non-zero return takes the fallback branch.)
built=0
if [[ -f "$here/src/pixeldrain-progress.swift" ]]; then
  print -- "  · building AppKit helpers from source…"
  build_log="$(/usr/bin/mktemp -t pixeldrain-build)"
  if do_build >"$build_log" 2>&1; then
    built=1
    print -- "  ✓ built bin/pixeldrain-progress, bin/pixeldrain-picker"
  else
    # Show the compiler output — "build failed" alone is useless for fixing it.
    print -u2 -- "  ! build failed — falling back to the committed binaries:"
    sed 's/^/      /' "$build_log" >&2
  fi
  rm -f "$build_log"
fi

# When falling back, the committed binaries have to be both present and current,
# and they are arm64-only.
if (( ! built )); then
  if ! binaries_are_current; then
    print -u2 -- "  ! warning: bin/ is stale or unversioned relative to src/ —"
    print -u2 -- "    the installed windows may not match the source in this checkout."
  fi
  if [[ "$(uname -m)" != arm64 ]]; then
    print -u2 -- "  ! the committed binaries are arm64-only and this Mac is $(uname -m)."
    print -u2 -- "    Install the Command Line Tools (xcode-select --install) and re-run."
    exit 1
  fi
fi

# 1. Helper programs -> ~/.local/bin
mkdir -p "$dest_bin"
for f in $helpers; do
  if [[ ! -f "$bin_dir/$f" ]]; then
    print -u2 -- "  ! missing $bin_dir/$f — aborting."
    exit 1
  fi
  cp "$bin_dir/$f" "$dest_bin/$f"
  chmod +x "$dest_bin/$f"
  # Helpers unzipped from a download carry a quarantine flag, which makes them
  # fail to launch from the Quick Action with no visible error.
  xattr -d com.apple.quarantine "$dest_bin/$f" 2>/dev/null || true
  print -- "  ✓ $dest_bin/$f"
done

# 2. Quick Action -> ~/Library/Services
mkdir -p "$dest_services"
if [[ ! -d "$here/$workflow" ]]; then
  print -u2 -- "  ! missing '$here/$workflow' — aborting."
  exit 1
fi
rm -rf "${dest_services:?}/${workflow:?}"
cp -R "$here/$workflow" "$dest_services/$workflow"
xattr -dr com.apple.quarantine "$dest_services/$workflow" 2>/dev/null || true
print -- "  ✓ $dest_services/$workflow"

# 3. API key
if [[ ! -s "$key_file" ]]; then
  print -- ""
  print -- "One more step: save your PixelDrain API key so the action can log in."
  print -- "  1. Get a key at https://pixeldrain.com/user/api_keys"
  print -- "  2. Run:  printf '%s' 'YOUR_KEY_HERE' > ~/.pixeldrain_api_key"
else
  # Tighten it rather than only advising it — the key is a bearer credential and
  # the default umask leaves it readable by every account on the Mac.
  chmod 600 "$key_file"
  print -- "  ✓ API key present at $key_file (mode 600)"
fi

print -- ""
print -- "Done. Right-click a file or folder in Finder → Quick Actions →"
print -- "\"Upload to PixelDrain Folder…\". If it doesn't appear yet, log out"
print -- "and back in, or toggle it on under System Settings → Keyboard →"
print -- "Keyboard Shortcuts → Services → Files and Folders."
