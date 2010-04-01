#!/bin/bash

# To restore this backup, use:
#   rdiff-backup -r now /mnt/backup/example root@example-backup::/

source "$HOME/cvs/personal/projects/backup/functions.sh"

SOURCE_DIR="root@example-backup::/"

rdiff_backup "$SOURCE_DIR" "$DEST_DIR"
