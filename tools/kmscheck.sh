#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jim Powers
#
# kmscheck.sh: check what the panel ACTUALLY shows while a jai-wayland example runs.
#
# Screenshots and screen recorders (grim, wf-recorder, OBS) go through screencopy: the
# compositor draws them a fresh frame of the clients' current buffers. They cannot see
# a window the compositor has stopped repainting, and on Hyprland a screencopy session
# even repaints everything and hides the bug for a while. This tool reads the
# framebuffer the display is scanning out instead (ffmpeg's kmsgrab, which needs
# CAP_SYS_ADMIN, hence sudo), crops it to the example's windows, and counts distinct
# images. An animating example gives about one distinct image per refresh; a frozen one
# cycles through a handful, one per compositor output buffer. Found the Hyprland 0.57
# viewport-damage freeze on 2026-10-31 (CLAUDE.md Next Steps #2), which every
# screenshot-based check had passed.
#
# Window discovery and closing use hyprctl when Hyprland is running. On any other
# compositor pass --region (the windows' box in scanout pixels); the example is then
# stopped with SIGTERM when the capture ends.
#
# Needs: sudo without a password prompt (sudo -n), ffmpeg built with kmsgrab and Vulkan
# (hwmap=derive_device=vulkan reads tiled scanout buffers, NVIDIA's included), python3,
# and jq for the Hyprland path. Run from anywhere; it builds and runs ./build.sh - <target>.

set -u

usage() {
    cat <<'EOF'
usage: tools/kmscheck.sh [options] <target> [-- NAME=VALUE ...]

Runs ./build.sh - <target>, captures the real scanout over its windows, closes them, and
prints frames / distinct images / a verdict (LIVE, PARTIAL, FROZEN). Anything after --
is set in the example's environment (e.g. JAI_WAYLAND_EXPLICIT_SYNC=0).

options:
  --tag NAME        name for the log and capture files (default: the target)
  --windows N       wait for N new windows before capturing (default: 1)
  --settle SEC      wait this long after the windows appear (default: 0.5)
  --seconds SEC     capture length (default: 4)
  --hook CMD        Hyprland only: shell command run once per new window before the
                    capture, with $addr set to its address (e.g. float and resize it)
  --region X,Y,W,H  the windows' box in scanout pixels; skips hyprctl (any compositor)
  --device PATH     DRM card node to grab from (default: the first one kmsgrab accepts)
  --out DIR         where the log and capture go (default: a new temporary directory)
  -h, --help        this text

examples:
  tools/kmscheck.sh --windows 2 simp_multiple_windows
  tools/kmscheck.sh --windows 2 simp_multiple_windows -- JAI_WAYLAND_EXPLICIT_SYNC=0
  tools/kmscheck.sh --hook 'hyprctl dispatch "hl.dsp.window.float({ action = \"toggle\", window = \"address:$addr\" })"' hello_simp
  tools/kmscheck.sh --region 0,40,1270,1554 hello_simp      # not Hyprland
EOF
}

tag=""; windows=1; settle=0.5; seconds=4; hook=""; region=""; device=""; out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)     tag=$2; shift 2 ;;
        --windows) windows=$2; shift 2 ;;
        --settle)  settle=$2; shift 2 ;;
        --seconds) seconds=$2; shift 2 ;;
        --hook)    hook=$2; shift 2 ;;
        --region)  region=$2; shift 2 ;;
        --device)  device=$2; shift 2 ;;
        --out)     out=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --)        break ;;
        -*)        echo "kmscheck: unknown option $1" >&2; usage >&2; exit 2 ;;
        *)         break ;;
    esac
done
[ $# -ge 1 ] && [ "$1" != "--" ] || { usage >&2; exit 2; }
target=$1; shift
[ "${1:-}" = "--" ] && shift
envs=("$@")
[ -n "$tag" ] || tag=$target

die() { echo "kmscheck: $*" >&2; exit 1; }
command -v ffmpeg  >/dev/null || die "ffmpeg not found"
command -v python3 >/dev/null || die "python3 not found"
sudo -n true 2>/dev/null      || die "sudo needs a password; kmsgrab needs CAP_SYS_ADMIN (run 'sudo -v' first)"

use_hypr=0
if [ -z "$region" ]; then
    if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && hyprctl version >/dev/null 2>&1; then
        command -v jq >/dev/null || die "jq not found (needed for the Hyprland path)"
        use_hypr=1
    else
        die "not on Hyprland: pass --region X,Y,W,H (the windows' box in scanout pixels)"
    fi
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
[ -n "$out" ] || out=$(mktemp -d "${TMPDIR:-/tmp}/kmscheck.XXXXXX")
mkdir -p "$out"
log=$out/$tag.log; mkv=$out/$tag.mkv

# Probe: pick the card node and learn the scanout's software pixel format (NVIDIA's
# block-linear XR24 downloads as bgr0; asking for bgra fails).
probe() { sudo -n ffmpeg -hide_banner -loglevel verbose -device "$1" -f kmsgrab -i - -frames:v 1 -f null - 2>&1; }
fmt=""
for c in ${device:-/dev/dri/card*}; do
    p=$(probe "$c")
    fmt=$(sed -n 's/.*Format is \([a-z0-9]*\), from DRM format.*/\1/p' <<< "$p" | head -1)
    [ -n "$fmt" ] && { device=$c; break; }
done
[ -n "$fmt" ] || die "kmsgrab could not read a framebuffer from ${device:-any /dev/dri/card*}"

desc() { local c; for c in $(pgrep -P "$1"); do echo "$c"; desc "$c"; done; }
addrs() { hyprctl clients -j | jq -r '.[].address' | sort; }

before=""; [ $use_hypr = 1 ] && before=$(addrs)
(cd "$repo" && env "${envs[@]}" ./build.sh - "$target") > "$log" 2>&1 &
bpid=$!

new=""
if [ $use_hypr = 1 ]; then
    for _ in $(seq 1 300); do
        sleep 0.1
        new=$(comm -13 <(echo "$before") <(addrs))
        [ -n "$new" ] && [ "$(grep -c . <<< "$new")" -ge "$windows" ] && break
        kill -0 $bpid 2>/dev/null || break
    done
    [ -n "$new" ] || { wait $bpid; die "no window appeared (rc=$?); see $log"; }
else
    sleep 5   # no window list to watch: give the build and the first frames time
fi
sleep "$settle"
if [ $use_hypr = 1 ] && [ -n "$hook" ]; then
    for addr in $new; do export addr; eval "$hook" >/dev/null; done
    sleep 1
fi

# The capture box in scanout pixels.
if [ $use_hypr = 1 ]; then
    region=$(hyprctl clients -j | jq -r --arg n "$new" --argjson mons "$(hyprctl monitors -j)" '
        [.[] | select(.address as $a | $n | contains($a))] as $w
        | ($mons | map(select(.id == $w[0].monitor))[0]) as $m
        | ($w | map(.at[0]) | min) as $x  | ($w | map(.at[1]) | min) as $y
        | ($w | map(.at[0] + .size[0]) | max) as $x2 | ($w | map(.at[1] + .size[1]) | max) as $y2
        | [(($x - $m.x) * $m.scale + 2), (($y - $m.y) * $m.scale + 2),
           (($x2 - $x) * $m.scale - 4), (($y2 - $y) * $m.scale - 4)]
        | map(floor) | "\(.[0]),\(.[1]),\(.[2]),\(.[3])"')
fi
IFS=, read -r rx ry rw rh <<< "$region"
rw=$(( rw / 2 * 2 )); rh=$(( rh / 2 * 2 ))

sudo -n timeout -s INT $(( ${seconds%.*} + 15 )) ffmpeg -hide_banner -loglevel error -device "$device" \
    -f kmsgrab -framerate 60 -i - -t "$seconds" \
    -vf "hwmap=derive_device=vulkan,hwdownload,format=$fmt,crop=$rw:$rh:$rx:$ry" \
    -c:v libx264rgb -preset ultrafast -crf 0 -y "$mkv" 2>&1 | grep -v '^Authorization required\|^$'
sudo -n chown "$(id -u):$(id -g)" "$mkv" 2>/dev/null

# Stop the example: a compositor close where we can (exit code meaningful), else SIGTERM.
if [ $use_hypr = 1 ]; then
    for a in $new; do hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })" >/dev/null; sleep 0.3; done
fi
for _ in $(seq 1 20); do kill -0 $bpid 2>/dev/null || break; sleep 0.5; done
if kill -0 $bpid 2>/dev/null; then
    [ $use_hypr = 1 ] && echo "kmscheck: $tag still running after the close; terminating it" >&2
    kill $(desc $bpid) 2>/dev/null
    wait $bpid; rc="$? (terminated)"
else
    wait $bpid; rc=$?
fi

python3 -I - "$mkv" "$rw" "$rh" "$tag" "$rc" "$device" "$fmt" "$rx,$ry,$rw,$rh" <<'EOF'
import collections, hashlib, subprocess, sys
mkv, w, h, tag, rc, dev, fmt, box = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), *sys.argv[4:]
raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", mkv, "-fps_mode", "passthrough",
                      "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
size = w * h * 3
n = len(raw) // size
hashes = [hashlib.md5(raw[i * size:(i + 1) * size]).digest() for i in range(n)]
distinct = len(set(hashes))
changes = sum(1 for a, b in zip(hashes, hashes[1:]) if a != b)
if n == 0:
    verdict = "NO FRAMES"
elif distinct >= n // 2:
    verdict = "LIVE"
elif distinct <= 8:
    verdict = "FROZEN (cycling stale images)" if changes > n // 2 else "STATIC"
else:
    verdict = "PARTIAL"
print(f"{tag}: rc={rc} frames={n} distinct={distinct} changes={changes} verdict={verdict}")
print(f"  device {dev}, format {fmt}, box {box} (scanout pixels), capture {mkv}")
EOF
grep -iE 'explicit sync|readback|error' "$log" | grep -v deprecated | head -3 | sed 's/^/  /'
