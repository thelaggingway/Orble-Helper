#!/usr/bin/env bash
# Run every test. Needs bash, python3 and node; uses a fake orble CLI, never your account.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$DIR/source-test.sh"
"$DIR/helper-test.sh"
node "$DIR/model-test.mjs"
