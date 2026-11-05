#!/bin/bash
set -euo pipefail
exec bash "$(cd "$(dirname "$0")" && pwd)/build_depthline.sh" "$@"
