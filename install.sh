#!/bin/zsh
# Installer for the "Upload to PixelDrain Folder…" Finder Quick Action.
# Copies the helper programs into ~/.local/bin and installs the workflow into
# ~/Library/Services. Idempotent — safe to re-run to update an existing install.
set -eu

here="${0:A:h}"
bin_dir="$here/bin"
workflow="Upload to PixelDrain Folder….workflow"

dest_bin="$HOME/.local/bin"
dest_services="$HOME/Library/Services"
key_file="$HOME/.pixeldrain_api_key"

print -- "Installing PixelDrain Quick Action…"

# 0. Rebuild the progress window from source when the Swift toolchain is present,
#    so the installed binary matches src/. Falls back to the committed binary.
if [[ -f "$here/src/pixeldrain-progress.swift" ]] && xcrun --find swiftc >/dev/null 2>&1; then
  print -- "  · building pixeldrain-progress from source…"
  "$here/build.sh" >/dev/null && print -- "  ✓ built bin/pixeldrain-progress" \
    || print -u2 -- "  ! build failed — using the committed binary"
fi

# 1. Helper programs -> ~/.local/bin
mkdir -p "$dest_bin"
for f in pixeldrain-upload-fs pixeldrain-put pixeldrain-progress; do
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
rm -rf "$dest_services/$workflow"
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
