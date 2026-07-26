# Upload to PixelDrain Folder…

A macOS Finder **Quick Action** that uploads any selected files or folders into
a directory of your choice in the [PixelDrain Filesystem](https://pixeldrain.com/d/me).
Right-click → **Quick Actions → Upload to PixelDrain Folder…**, browse to a
destination folder (Finder-style), and the files stream up with a floating
progress window. The destination folder's share link is copied to your
clipboard when the upload finishes.

Local folders are zipped (`ditto`) before upload. When a name already exists in
the destination you're asked to Overwrite or Skip. The progress window has a
**Cancel** button that aborts an in-flight upload and removes the partial file
from PixelDrain.

## Requirements

- macOS (Apple Silicon — the progress UI is an arm64 binary).
- An **active PixelDrain Pro subscription** — the Filesystem feature it uploads
  into is Pro-only.
- A PixelDrain **API key** saved at `~/.pixeldrain_api_key`.
- **Command Line Tools** (`python3`). If missing, run `xcode-select --install`.
  The action checks for this up front and tells you if it's needed.

## Install

```sh
./install.sh
```

This copies three helpers into `~/.local/bin` and installs the workflow into
`~/Library/Services`. It's idempotent — re-run it to update.

Then save your API key (get one at
<https://pixeldrain.com/user/api_keys>):

```sh
printf '%s' 'YOUR_KEY_HERE' > ~/.pixeldrain_api_key
chmod 600 ~/.pixeldrain_api_key
```

If the action doesn't show up in the right-click menu, log out and back in, or
enable it under **System Settings → Keyboard → Keyboard Shortcuts → Services →
Files and Folders**.

## Usage

1. Select one or more files/folders in Finder.
2. Right-click → **Quick Actions → Upload to PixelDrain Folder…**
3. Navigate to a destination:
   - a **folder/** row opens that folder,
   - **Go Up One Level** goes back,
   - **＋ New Folder Here…** creates a subfolder,
   - **Upload to This Folder** picks the current one.
4. Watch the progress window. On success the folder link is on your clipboard.
   Click **Cancel** any time to abort — the current upload is stopped and its
   partial file is removed from PixelDrain.

## How it works

| Component | Role |
|---|---|
| `Upload to PixelDrain Folder….workflow` | Automator service; runs `pixeldrain-upload-fs "$@"` |
| `bin/pixeldrain-upload-fs` | zsh orchestrator: auth, folder navigation, zipping, retries, progress plumbing, cancel handling |
| `bin/pixeldrain-put` | Python helper: streaming upload (`fs`/`file`) and directory listing (`list`) |
| `bin/pixeldrain-progress` | floating progress window (Swift/AppKit), built from `src/pixeldrain-progress.swift` |

The API key is read from `~/.pixeldrain_api_key` and passed to the helpers via
the `PD_AUTH_KEY` environment variable — never on a command line, so it can't
leak through `ps`.

### Progress window & Cancel

`bin/pixeldrain-progress` is compiled from `src/pixeldrain-progress.swift` with:

```sh
./build.sh          # xcrun swiftc -O -o bin/pixeldrain-progress src/…
```

The orchestrator drives it over a one-line-per-message stdin protocol:
`TITLE <t>`, `STATUS <s>`, `PROGRESS <0-100>` / `PROGRESS ind`, `DONE <msg>`;
closing the stream closes the window.

**Cancel back-channel:** the orchestrator passes its PID to the window
(`pixeldrain-progress <pid>`). Clicking Cancel (or the window's close button)
sends `SIGTERM` to that PID. The orchestrator traps it, kills the in-flight
`pixeldrain-put`/`ditto`, `DELETE`s the partially-uploaded remote file, cleans
up temp files, and exits — the window then closes when its stdin reaches EOF.

## Troubleshooting

- **"No API key found"** — create `~/.pixeldrain_api_key` as shown above.
- **"API key rejected"** — generate a fresh key at
  <https://pixeldrain.com/user/api_keys>.
- **"requires an active Pro subscription"** — the Filesystem feature needs Pro.
- **"needs the macOS Command Line Tools"** — run `xcode-select --install`.
- **"Unable to reach pixeldrain.com"** — check your network / try again later.
