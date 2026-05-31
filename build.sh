#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# NOTE: `~/jai/jai/bin/jai-linux` is just where I unpacked the Jai compiler
# (beta 0.2.029, built 25 April 2026). Change this path to match the location
# of `jai-linux` on your machine.
~/jai/jai/bin/jai-linux first.jai "$@"
