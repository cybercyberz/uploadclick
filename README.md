# Upload to PixelDrain Folder

A macOS Finder **Quick Action** that uploads any selected files or folders into
a directory of your choice in the [PixelDrain Filesystem](https://pixeldrain.com/d/me).
Right-click → **Quick Actions → Upload to PixelDrain Folder…**, browse to a
destination in a native column-view window (like Finder), and the files stream
up with a floating progress window. The destination folder's share link is
copied to your clipboard when the upload finishes.

Folders are uploaded **file-by-file**, recreating the folder tree on PixelDrain,
so the progress window names each file as it goes up. After you pick a
destination you choose **Copy** (keep the originals) or **Move**. In both modes a
file that already exists in the destination with the **same name and size** is
skipped — in Move it's left on disk. The window has a **Pause/Resume** button
(pauses at the next file boundary) and a **Cancel** button that aborts the
in-flight upload and removes its partial file from PixelDrain. Big uploads keep
the result window open until you click **Close**; a quick single small file
auto-closes.

> **Move permanently deletes.** Each local file is removed as soon as it uploads.
> Files do **not** go to the Trash and cannot be recovered, so Move asks for a
> second confirmation before it starts.

Every file's outcome is appended to `~/Library/Logs/pixeldrain-upload.log`, along
with anything the upload helper writes to stderr. The progress window can only
show a summary, so when a run reports more than one failure it points you there.

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

This copies four helpers into `~/.local/bin` and installs the workflow into
`~/Library/Services`. It's idempotent — re-run it to update.

Then save your API key (get one at
<https://pixeldrain.com/user/api_keys>):

```sh
printf '%s' 'YOUR_KEY_HERE' > ~/.pixeldrain_api_key
```

Re-run `./install.sh` afterwards and it will `chmod 600` the key for you — it's a
bearer credential, and the default umask leaves it readable by every account on
the Mac. The Quick Action warns if it finds the key group- or world-readable.

Other subcommands:

| Command | Does |
|---|---|
| `./install.sh build` | compile the AppKit windows into `bin/`, no install |
| `./install.sh check-binaries` | verify the committed binaries match `src/` (used by CI) |
| `./install.sh uninstall` | remove the helpers and the workflow (leaves your key and log) |

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
4. In the confirmation sheet choose **Copy** or **Move**. Move permanently deletes
   each local file after it uploads (no Trash, no undo) and asks again before it
   starts. Files already present with the same name and size are skipped and (in
   Move) left on disk.
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
the `PD_AUTH_KEY` environment variable, set per-invocation on just the commands
that need it — never on a command line (so it can't leak through `ps`) and never
in the environment of unrelated children.

`pixeldrain-put` reports failures in two classes so the orchestrator knows what
is worth repeating: `RESULT 0` is a socket/network error and gets retried, while
`RESULT -1` (missing file, no key) and any 4xx are permanent and fail
immediately. Listings use `HTTPERROR network`/`5xx` versus `HTTPERROR nokey`/`4xx`
the same way.

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

## Tests

No framework to install — `zsh` and the system `python3` are already runtime
dependencies. Neither suite touches the network or needs a PixelDrain account:
the orchestrator is sourced with `PD_LIB_ONLY=1`, which loads its helpers without
running an upload, and `PUT_BIN` is pointed at stubs that replay canned listings.

```sh
./tests/run.sh                          # protocol parsing + retry classification
python3 -m unittest discover -s tests   # listing formatter + path encoder
```

CI (`.github/workflows/ci.yml`) runs both on `macos-latest`, plus `zsh -n`,
`py_compile`, `swiftc -typecheck`, and a check that the committed binaries still
match `src/`.

## Troubleshooting

- **"No API key found"** — create `~/.pixeldrain_api_key` as shown above.
- **A run reported failures** — see `~/Library/Logs/pixeldrain-upload.log`; every
  file's outcome and the helper's stderr are recorded there.
- **"API key rejected"** — generate a fresh key at
  <https://pixeldrain.com/user/api_keys>.
- **"requires an active Pro subscription"** — the Filesystem feature needs Pro.
- **"needs the macOS Command Line Tools"** — run `xcode-select --install`.
- **"Unable to reach pixeldrain.com"** — check your network / try again later.
