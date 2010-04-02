#!/bin/bash

# To restore this backup, use:
#   rdiff-backup -r now /mnt/backup/example root@example-backup::/

source "$(dirname $(dirname $(readlink -f $0)))/functions.sh"

SOURCE_DIR="root@example-backup::/"

rdiff_backup "$SOURCE_DIR" "$DEST_DIR"
