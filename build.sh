#!/bin/zsh
# Compile the progress-window helper from source into bin/pixeldrain-progress.
# Requires the Swift toolchain from the macOS Command Line Tools (xcode-select
# --install), the same dependency the Quick Action already needs for python3.
set -eu

here="${0:A:h}"
src="$here/src/pixeldrain-progress.swift"
out="$here/bin/pixeldrain-progress"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 -- "swiftc not found. Install the Command Line Tools: xcode-select --install"
  exit 1
fi

mkdir -p "$here/bin"
print -- "Compiling $src …"
xcrun swiftc -O -o "$out" "$src"
chmod +x "$out"
print -- "Built $out"
