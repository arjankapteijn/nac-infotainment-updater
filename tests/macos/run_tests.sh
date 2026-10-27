#!/usr/bin/env bash
# Tests for the macOS scripts. They source each script (main does not run
# when sourced) and call its functions against small local fixtures and a
# local HTTP server, so nothing is downloaded and no disk is touched.
#
# Usage: bash tests/macos/run_tests.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FIRMWARE="$REPO/macos/prepare_nac_update_mac.sh"
MAP="$REPO/macos/prepare_nac_map_update_mac.sh"

WORK="$(mktemp -d)"
PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    rm -rf "$WORK" "/tmp/license_test_$$.key"
}
trap cleanup EXIT

if command -v gtar &>/dev/null; then TAR=gtar; else TAR=tar; fi
if command -v gstat &>/dev/null; then STAT=gstat; else STAT=bsd_stat; fi

pass=0
fail=0
out=""
rc=0

# Run a snippet in a fresh bash with the given script sourced.
run_in() {
    local script="$1" code="$2"
    out="$(cd "$WORK" && HOME="$WORK/home" bash -c "
        source '$script'
        TAR_CMD=$TAR STAT_CMD=$STAT
        MAX_RETRIES=3 RETRY_DELAY_BASE=0 MIN_DOWNLOAD_SIZE=0
        $code" 2>&1)"
    rc=$?
}

check() {
    local name="$1"; shift
    if "$@"; then
        echo "ok   - $name"
        pass=$((pass + 1))
    else
        echo "FAIL - $name (exit $rc)"
        echo "$out" | tail -15 | sed 's/^/       /'
        fail=$((fail + 1))
    fi
}

exited() { [[ $rc -eq $1 ]]; }
says() { grep -qF -- "$1" <<<"$out"; }
same_file() { cmp -s "$1" "$2"; }

# ── Fixtures ────────────────────────────────────────────────────────────────
mkdir -p "$WORK/home" "$WORK/data/SWL/pkg" "$WORK/other/OTHER" "$WORK/srv"
# Enough entries that `tar tf` output outlives an early-exiting grep -q.
for i in $(seq 1 3000); do echo "$i" > "$WORK/data/SWL/pkg/file$i.bin"; done
echo readme > "$WORK/other/OTHER/readme.txt"
head -c 2000000 /dev/urandom > "$WORK/data/SWL/big.bin"
$TAR -cf "$WORK/good.tar" -C "$WORK/data" SWL/pkg SWL/big.bin
$TAR -cf "$WORK/noswl.tar" -C "$WORK/other" OTHER
# Cut inside the big last member, like a dropped download. (GNU tar seeks
# over member data when listing, so a cut in a tiny member can go unnoticed.)
head -c $(( $(wc -c < "$WORK/good.tar") - 1000000 )) "$WORK/good.tar" > "$WORK/truncated.tar"

head -c 8388608 /dev/urandom > "$WORK/srv/payload.bin"
: > "$WORK/srv/empty.key"
printf '{"errorCode":"404","file":null}' > "$WORK/srv/error.key"
printf 'MIME-Version: 1.0\nContent-Type: multipart/signed\n\nsigned license\n' > "$WORK/srv/valid.key"

start_server() {
    local port="$1"; shift
    python3 "$HERE/test_server.py" "$WORK/srv" "$port" "$@" &
    PIDS+=($!)
    disown $!
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:$port/payload.bin" && return 0
        sleep 0.1
    done
    echo "test server on port $port did not start" >&2
    exit 1
}
PORT_RANGE=$(( 20000 + RANDOM % 20000 ))
PORT_NORANGE=$(( PORT_RANGE + 1 ))
start_server "$PORT_RANGE"
start_server "$PORT_NORANGE" --no-range
URL_RANGE="http://127.0.0.1:$PORT_RANGE"
URL_NORANGE="http://127.0.0.1:$PORT_NORANGE"

# ── Syntax ──────────────────────────────────────────────────────────────────
for script in "$FIRMWARE" "$MAP"; do
    out="$(bash -n "$script" 2>&1)"; rc=$?
    check "$(basename "$script"): parses" exited 0
done

# ── Archive validation ──────────────────────────────────────────────────────
for pair in "$FIRMWARE:validate_firmware" "$MAP:validate_map"; do
    script="${pair%%:*}" fn="${pair##*:}" name="$(basename "${pair%%:*}")"

    run_in "$script" "$fn '$WORK/good.tar'"
    check "$name: $fn accepts a valid archive under pipefail" eval 'exited 0 && says "Contains SWL/"'

    run_in "$script" "$fn '$WORK/truncated.tar'"
    check "$name: $fn rejects a truncated archive" eval 'exited 1 && says "corrupted"'

    run_in "$script" "$fn '$WORK/noswl.tar'"
    check "$name: $fn rejects an archive without SWL/" eval 'exited 1 && says "No SWL/"'
done

# ── Download and resume ─────────────────────────────────────────────────────
for script in "$FIRMWARE" "$MAP"; do
    name="$(basename "$script")"
    dest="$WORK/dl-$name.bin"

    rm -f "$dest"
    run_in "$script" "download_with_resume '$URL_RANGE/payload.bin' '$dest'"
    check "$name: fresh download is complete" eval 'exited 0 && same_file "$dest" "$WORK/srv/payload.bin"'

    head -c 3000000 "$WORK/srv/payload.bin" > "$dest"
    run_in "$script" "download_with_resume '$URL_RANGE/payload.bin' '$dest'"
    check "$name: resumes a partial download" eval 'exited 0 && ! says "rejected" && same_file "$dest" "$WORK/srv/payload.bin"'

    head -c 3000000 "$WORK/srv/payload.bin" > "$dest"
    run_in "$script" "download_with_resume '$URL_NORANGE/payload.bin' '$dest'"
    check "$name: restarts when the server ignores Range" eval 'exited 0 && says "Server rejected resume" && same_file "$dest" "$WORK/srv/payload.bin"'
done

# ── License download (firmware script only) ─────────────────────────────────
for case in empty error valid; do
    rm -rf "$WORK/usb"; mkdir -p "$WORK/usb"
    run_in "$FIRMWARE" "
        LICENSE_FILENAME=license_test_$$.key
        LICENSE_URL='$URL_RANGE/$case.key'
        prepare_license '$WORK/usb'"
    case "$case" in
        empty) check "license: rejects an empty download" eval 'exited 1 && says "empty or invalid" && [[ ! -e $WORK/usb/license ]]' ;;
        error) check "license: rejects a server error response" eval 'exited 1 && says "Server returned an error"' ;;
        valid) check "license: accepts a signed license" eval 'exited 0 && same_file "$WORK/usb/license/license_test_$$.key" "$WORK/srv/valid.key"' ;;
    esac
done

echo ""
echo "$pass passed, $fail failed"
(( fail == 0 ))
