#!/bin/zsh
# Unit tests for the protocol-parsing and retry logic in pixeldrain-upload-fs.
#
# The orchestrator is sourced with PD_LIB_ONLY=1, which loads its helpers and
# returns before the upload flow runs. PUT_BIN points at generated stubs that
# replay canned `pixeldrain-put list` output, so nothing here touches the network
# or needs a PixelDrain account.
#
#   ./tests/run.sh
set -u

here="${0:A:h}"
root="${here:h}"
tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pixeldrain-tests.XXXXXX")"
trap '/bin/rm -rf "$tmp"' EXIT

typeset -i pass=0 fail=0

# NB: these must return 0 explicitly. `(( pass++ ))` evaluates to the *old*
# value, so the very first ok() would exit non-zero and trip the `||` branch of
# whatever called it.
ok()  { print -- "  ok    $1"; (( pass++ )); return 0 }
bad() { print -u2 -- "  FAIL  $1"
        print -u2 -- "        expected: [$2]"
        print -u2 -- "        actual:   [$3]"; (( fail++ )); return 0 }
# is <label> <actual> <expected>
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "$3" "$2"; fi }
# yes/no <label> <command...> — assert the command succeeds / fails
yes() { local l="$1"; shift; if "$@"; then ok "$l"; else bad "$l" "success" "failure"; fi }
no()  { local l="$1"; shift; if "$@"; then bad "$l" "failure" "success"; else ok "$l"; fi }

# ---- load the orchestrator as a library ----
export LOG_FILE="$tmp/run.log"
export PUT_BIN="$tmp/put-stub"
export UI_BIN="$tmp/absent-ui"
export PICK_BIN="$tmp/absent-picker"
PD_LIB_ONLY=1 source "$root/bin/pixeldrain-upload-fs"
RETRY_DELAY=0            # don't burn real seconds between retry attempts
counter="$tmp/calls"

# A stub `pixeldrain-put` that prints fixed output for every `list` call.
stub() {
  print -r -- "#!/bin/zsh
print -r -- \$(( \$(cat '$counter' 2>/dev/null || print 0) + 1 )) > '$counter'
cat <<'STUB_EOF'
$1
STUB_EOF" > "$PUT_BIN"
  chmod +x "$PUT_BIN"
  print -rn -- 0 > "$counter"
}

# A stub that fails $1 times with line $2, then succeeds with line $3.
stub_flaky() {
  print -r -- "#!/bin/zsh
n=\$(cat '$counter' 2>/dev/null || print 0)
print -r -- \$(( n + 1 )) > '$counter'
if (( n < $1 )); then print -r -- '$2'; else print -r -- '$3'; fi" > "$PUT_BIN"
  chmod +x "$PUT_BIN"
  print -rn -- 0 > "$counter"
}

calls() { cat "$counter" 2>/dev/null || print 0 }

# ---------------------------------------------------------------- pd_list ----
print -- "pd_list — list protocol parsing"

stub 'DIR photos
DIR Music
FILE 1024 a.txt
FILE 7 two words.txt'
pd_list me
is "directories collected"      "${LIST_DIRS[*]}"            "photos Music"
is "files collected"            "${LIST_FILES[*]}"           "a.txt two words.txt"
is "size mapped by name"        "${LIST_FSIZE[a.txt]}"       "1024"
is "name with spaces intact"    "${LIST_FSIZE[two words.txt]}" "7"
is "no error on success"        "$LIST_ERR"                  ""

stub 'HTTPERROR 503'
pd_list me
is "http error captured"        "$LIST_ERR"                  "503"
is "dirs reset on error"        "${#LIST_DIRS}"              "0"
is "files reset on error"       "${#LIST_FILES}"             "0"

stub 'HTTPERROR nokey'
pd_list me
is "nokey surfaced verbatim"    "$LIST_ERR"                  "nokey"

stub ''
pd_list me
is "empty listing is not an error" "$LIST_ERR"               ""
is "empty listing has no entries"  "${#LIST_FILES}"          "0"

# Stale state from a previous call must not leak into the next one.
stub 'DIR only-dir'
pd_list me
is "previous files cleared"     "${#LIST_FILES}"             "0"
is "new dirs present"           "${LIST_DIRS[*]}"            "only-dir"

# ----------------------------------------------------------- classification ----
print -- "\nis_transient — retry classification (listing)"
for c in network 500 503 599; do
  yes "'$c' is transient" is_transient "$c"
done
for c in 400 401 402 403 404 nokey ""; do
  no  "'$c' is permanent" is_transient "$c"
done

print -- "\nis_transient_upload — retry classification (upload)"
for c in 0 500 503; do
  yes "'$c' is transient" is_transient_upload "$c"
done
# 2xx never reaches the classifier, but -1 and "" are the cases that used to
# burn three attempts each before failing anyway.
for c in 404 401 -1 ""; do
  no  "'$c' is permanent" is_transient_upload "$c"
done

# ----------------------------------------------------------- pd_list_retry ----
print -- "\npd_list_retry — retries transients, gives up on permanents"

stub_flaky 2 'HTTPERROR 503' 'DIR recovered'
pd_list_retry me
is "recovers after 2 transients" "$LIST_ERR"       ""
is "took exactly 3 attempts"     "$(calls)"        "3"
is "success payload parsed"      "${LIST_DIRS[*]}" "recovered"

stub_flaky 99 'HTTPERROR 503' 'DIR never'
pd_list_retry me
is "gives up on the cap"         "$LIST_ERR"       "503"
is "capped at RETRY_ATTEMPTS"    "$(calls)"        "$RETRY_ATTEMPTS"

stub_flaky 99 'HTTPERROR 404' 'DIR never'
pd_list_retry me
is "permanent error preserved"   "$LIST_ERR"       "404"
is "permanent tried exactly once" "$(calls)"       "1"

stub_flaky 99 'HTTPERROR nokey' 'DIR never'
pd_list_retry me
is "nokey not retried"           "$(calls)"        "1"

stub 'DIR fine'
pd_list_retry me
is "success tried exactly once"  "$(calls)"        "1"

# ---------------------------------------------------------- pd_encode_path ----
print -- "\npd_encode_path — clipboard/URL safety"
is "separators preserved"  "$(pd_encode_path 'me/a/b')"       "me/a/b"
is "space encoded"         "$(pd_encode_path 'me/my folder')" "me/my%20folder"
is "hash encoded"          "$(pd_encode_path 'me/a#b')"       "me/a%23b"
is "plain path unchanged"  "$(pd_encode_path 'me')"           "me"

# ------------------------------------------------------------------- log ----
print -- "\nlog — run log"
log "hello world"
yes "log line written" grep -q "hello world" "$LOG_FILE"

# ----------------------------------------------------------------- report ----
print -- ""
if (( fail )); then
  print -u2 -- "$fail failed, $pass passed"
  exit 1
fi
print -- "all $pass tests passed"
