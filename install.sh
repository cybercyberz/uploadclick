#!/bin/zsh
# Installer for the "Upload to PixelDrain Folder…" Finder Quick Action.
# Copies the helper programs into ~/.local/bin and installs the workflow into
# ~/Library/Services. Idempotent — safe to re-run to update an existing install.
#
# Usage:
#   ./install.sh          build (if the Swift toolchain is present) then install
#   ./install.sh build    compile the AppKit windows only, no install
set -eu

here="${0:A:h}"
bin_dir="$here/bin"
workflow="Upload to PixelDrain Folder….workflow"

dest_bin="$HOME/.local/bin"
dest_services="$HOME/Library/Services"
key_file="$HOME/.pixeldrain_api_key"

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
  mkdir -p "$here/bin"
  local name src out
  for name in pixeldrain-progress pixeldrain-picker; do
    src="$here/src/$name.swift"
    out="$here/bin/$name"
    print -- "Compiling $src …"
    xcrun swiftc -O -o "$out" "$src" || return 1
    chmod +x "$out"
    print -- "Built $out"
  done
}

# Subcommand: compile only, no install. Strict — set -e propagates a build
# failure (e.g. a missing toolchain) as a non-zero exit.
if [[ "${1:-}" == build ]]; then
  do_build
  exit 0
fi

print -- "Installing PixelDrain Quick Action…"

# 0. Rebuild the AppKit windows from source so the installed binaries match src/.
#    Tolerant: if the toolchain is missing or the build fails, fall back to the
#    committed binaries instead of aborting. (do_build inside the `if` suspends
#    set -e, so a non-zero return takes the fallback branch.)
if [[ -f "$here/src/pixeldrain-progress.swift" ]]; then
  print -- "  · building AppKit helpers from source…"
  if do_build >/dev/null 2>&1; then
    print -- "  ✓ built bin/pixeldrain-progress, bin/pixeldrain-picker"
  else
    print -u2 -- "  ! build skipped/failed — using the committed binaries"
  fi
fi

# 1. Helper programs -> ~/.local/bin
mkdir -p "$dest_bin"
for f in pixeldrain-upload-fs pixeldrain-put pixeldrain-progress pixeldrain-picker; do
  if [[ ! -f "$bin_dir/$f" ]]; then
    print -u2 -- "  ! missing $bin_dir/$f — aborting."
    exit 1
  fi
  cp "$bin_dir/$f" "$dest_bin/$f"
  chmod +x "$dest_bin/$f"
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
print -- "  ✓ $dest_services/$workflow"

# 3. API key reminder
if [[ ! -s "$key_file" ]]; then
  print -- ""
  print -- "One more step: save your PixelDrain API key so the action can log in."
  print -- "  1. Get a key at https://pixeldrain.com/user/api_keys"
  print -- "  2. Run:  printf '%s' 'YOUR_KEY_HERE' > ~/.pixeldrain_api_key"
  print -- "  3. Run:  chmod 600 ~/.pixeldrain_api_key"
else
  print -- "  ✓ API key already present at $key_file"
fi

print -- ""
print -- "Done. Right-click a file or folder in Finder → Quick Actions →"
print -- "\"Upload to PixelDrain Folder…\". If it doesn't appear yet, log out"
print -- "and back in, or toggle it on under System Settings → Keyboard →"
print -- "Keyboard Shortcuts → Services → Files and Folders."
