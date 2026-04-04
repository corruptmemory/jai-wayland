#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
~/jai/jai/bin/jai-linux first.jai "$@"
