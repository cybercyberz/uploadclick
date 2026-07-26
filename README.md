# Upload to PixelDrain Folder

A macOS Finder **Quick Action** that uploads any selected files or folders into
a directory of your choice in the [PixelDrain Filesystem](https://pixeldrain.com/d/me).
Right-click → **Quick Actions → Upload to PixelDrain Folder…**, browse to a
destination in a native column-view window (like Finder), and the files stream
up with a floating progress window. The destination folder's share link is
copied to your clipboard when the upload finishes.

Folders are uploaded **file-by-file**, recreating the folder tree on PixelDrain,
so the progress window names each file as it goes up. After you pick a
destination you choose **Copy** (keep the originals) or **Move** (delete each
local file once it uploads). In both modes a file that already exists in the
destination with the **same name and size** is skipped — in Move it's left on
disk. The window has a **Pause/Resume** button (pauses at the next file
boundary) and a **Cancel** button that aborts the in-flight upload and removes
its partial file from PixelDrain. Big uploads keep the result window open until
you click **Close**; a quick single small file auto-closes.

> Note: because folders upload file-by-file rather than as one archive, many
> tiny files mean many requests (slower than a single zip would be), macOS
> resource forks aren't preserved, and empty subfolders aren't recreated.

## Requirements

- macOS (Apple Silicon — the picker and progress windows are arm64 binaries).
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
3. A native **column-view window** opens. Navigate to a destination:
   - click a folder and its contents slide in as a new column to the right
     (files show dimmed — only folders can be picked),
   - **New Folder…** opens a sheet to name a new subfolder,
   - **Upload…** confirms the currently selected folder as the destination.
4. In the confirmation sheet choose **Copy** or **Move**. Move deletes each local file after it uploads;
   files already present with the same name and size are skipped and (in Move)
   left on disk.
5. Watch the progress window — it shows the current file, per-file percent, and
   overall progress. Use **Pause/Resume** to hold at the next file boundary, or
   **Cancel** to abort (the in-flight file is stopped and its partial removed).
   On success the folder link is on your clipboard; big uploads stay open until
   you click **Close**.

## How it works

| Component | Role |
|---|---|
| `Upload to PixelDrain Folder….workflow` | Automator service; Finder passes the selection on **stdin** (one path per line) and the action's wrapper rebuilds the argument list before running `pixeldrain-upload-fs`. Using stdin instead of "as arguments" keeps large selections in a single run — "as arguments" batches many items into multiple invocations. |
| `bin/pixeldrain-upload-fs` | zsh orchestrator: auth, directory listing for the picker, copy/move, recursive per-file upload, skip-by-size, retries, progress/pause/cancel plumbing |
| `bin/pixeldrain-picker` | native destination-folder picker — an NSBrowser (Finder column view) window (Swift/AppKit), built from `src/pixeldrain-picker.swift`. Pure view: the orchestrator streams it listings over a coprocess and it returns the chosen folder + Copy/Move |
| `bin/pixeldrain-put` | Python helper: streaming upload (`fs`/`file`) and directory listing (`list`, with sizes) |
| `bin/pixeldrain-progress` | floating progress window (Swift/AppKit), built from `src/pixeldrain-progress.swift` |

The API key is read from `~/.pixeldrain_api_key` and passed to the helpers via
the `PD_AUTH_KEY` environment variable — never on a command line, so it can't
leak through `ps`.

### Picker & progress windows

Both AppKit windows are compiled from `src/` with a single command:

```sh
./install.sh build  # xcrun swiftc -O → bin/pixeldrain-picker and bin/pixeldrain-progress
```

The **picker** (`pixeldrain-picker`) is the destination browser; the orchestrator
drives it over a coprocess, sending `BEGIN`/`DIR`/`FILE`/`END` listings and
receiving `LIST <path>` requests and a final `CHOOSE <copy|move> <path>`.

The orchestrator drives it over a one-line-per-message stdin protocol:
`TITLE <t>`, `STATUS <s>`, `PROGRESS <0-100>` / `PROGRESS ind`,
`DONE <msg>` (auto-close after ~4s) / `DONEHOLD <msg>` (stay open until Close);
closing the stream closes the window unless a completion message is showing.

The window is launched as `pixeldrain-progress <pid> <pause-file>`.

**Cancel back-channel:** clicking Cancel (or the window's close button) sends
`SIGTERM` to `<pid>`. The orchestrator traps it, kills the in-flight
`pixeldrain-put`, `DELETE`s the partially-uploaded remote file, cleans up temp
files, and exits — the window then closes when its stdin reaches EOF.

**Pause back-channel:** the Pause button toggles `<pause-file>` between `1` and
`0`. The orchestrator reads it at each file boundary and holds (or resumes)
there. A file already mid-upload finishes first, so pausing a single large file
takes effect once it ends.

## Troubleshooting

- **"No API key found"** — create `~/.pixeldrain_api_key` as shown above.
- **"API key rejected"** — generate a fresh key at
  <https://pixeldrain.com/user/api_keys>.
- **"requires an active Pro subscription"** — the Filesystem feature needs Pro.
- **"needs the macOS Command Line Tools"** — run `xcode-select --install`.
- **"Unable to reach pixeldrain.com"** — check your network / try again later.
