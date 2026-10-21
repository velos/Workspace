#!/bin/sh
# Creates and removes a private parity tree on an already-mounted writable volume.
set -eu
if [ "$#" -ne 2 ] || [ "$1" != "--volume" ] || [ ! -d "$2" ]; then
    echo "Usage: $0 --volume /Volumes/TestVolume" >&2
    exit 2
fi
WORKSPACE_TEST_VOLUME=$(cd "$2" && pwd)
export WORKSPACE_TEST_VOLUME
printf 'Bulk attribute parity volume: %s\n' "$WORKSPACE_TEST_VOLUME"
printf '%s\n' 'CASE lines report exercised/skipped features; RAW lines diagnose kernel modes independently of the production route.'
cd "$(dirname "$0")/.."
swift test --disable-sandbox --filter DarwinBulkAttributesTests.metadataAndStoredNamesMatchStat
