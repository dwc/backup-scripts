#!/bin/bash

# To restore this backup, use:
#   rsync -av example_source example_user@example_host:

source "$(dirname $(dirname $(readlink -f $0)))/functions.sh"

SOURCE_DIR="example_user@example_host:"

rsync_backup --exclude=/logs/ "$SOURCE_DIR" "$DEST_DIR"
