#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
~/jai/jai/bin/jai-linux src/main.jai -exe main -output_path "$(pwd)"
