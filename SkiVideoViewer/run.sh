#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
"$script_dir/build_app.sh" >/dev/null
open -n "$script_dir/SkiVideoViewer.app" --args "$@"
