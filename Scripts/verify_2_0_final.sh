#!/bin/zsh
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$script_dir/verify_2_0_final.py" "$@"
