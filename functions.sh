#!/bin/bash

##
## Default options - override by setting them in your script
##

PROJECT_DIR="$(dirname $BASH_SOURCE)"

BACKUP_NAME="$(basename $0)"
BACKUP_NAME="${BACKUP_NAME/.sh/}"

RDIFF_VERBOSITY="5"
RDIFF_TERMINAL_VERBOSITY="3"
DATE_FORMAT="%Y%m%d"
CHECKSUM_FILE="MD5SUM.txt"
DB_USERNAME=""
DB_PASSWORD=""
DB_HOST=""
BASE_DIR="/mnt/backup"
SOURCE_DIR=""
DEST_DIR="$BASE_DIR/$BACKUP_NAME"
CONF_DIR="$PROJECT_DIR/etc"
REMOTE_USER="backup"
REMOTE_HOST="example-backup"

[ -f "$PROJECT_DIR"/config.sh ] && source "$PROJECT_DIR"/config.sh


##
## Functions
##

# Perform a backup by creating a tarball for the specified local directory.
# Usage: tarball_backup_local source_directory destination_filename
function tarball_backup_local() {
    local parent_dir=$(dirname "$1")
    local dir=$(basename "$1")

    cd "$parent_dir" &&
        tar -cp "$dir" | gzip -c > "$2" &&
    cd -

    md5_checksum "$2"
    delete_if_redundant "$2"
}

# Perform a backup by creating a tarball for the specified remote directory.
# Usage: tarball_backup_from_remote remote_username remote_hostname remote_directory destination_filename
function tarball_backup_from_remote() {
    local parent_dir=$(dirname "$3")
    local dir=$(basename "$3")

    local args="-l $1 $2"
    args="${args} cd \"$parent_dir\" && gtar -cp \"$dir\""

    ssh $args | gzip -c > "$4"
    md5_checksum "$4"
    delete_if_redundant "$4"
}

# Perform a backup by creating a tarball for the specified local directory,
# storing it remotely.
# Usage: tarball_backup_to_remote local_directory remote_username remote_hostname destination_filename
function tarball_backup_to_remote() {
    temp_dir=$(mktemp -d)
    temp_filename="$temp_dir"/$(basename $4)
    temp_checksum_file="$temp_dir"/"$CHECKSUM_FILE"
    remote_checksum_file=$(dirname $4)/"$CHECKSUM_FILE"

    tarball_backup_local "$1" "$temp_filename"

    scp "$temp_filename" ${2}@${3}:${4}
    ssh -l $2 $3 "cat >> $remote_checksum_file" < $temp_checksum_file

    rm -r "$temp_dir"
}

# Perform a backup using rsync.
# Usage: rsync_backup [args] source destination
# Note: This method is not supported on Mac OS X due to its problems with
# filenames with capital letters.
function rsync_backup() {
    local args="-aq --delete-after"

    rsync $args $@
}

# Perform a backup using rdiff-backup.
# Usage: rdiff_backup source_directory destination_directory extra_args
function rdiff_backup() {
    local args="--verbosity $RDIFF_VERBOSITY --terminal-verbosity $RDIFF_TERMINAL_VERBOSITY --print-statistics $3"

    local conf="$CONF_DIR/$BACKUP_NAME.conf"
    if [ -f "$conf" ]; then
        args="${args} --include-globbing-filelist $conf"
    fi

    rdiff-backup $args "$1" "$2"
}

# Perform a backup of a Subversion repository using svnadmin dump.
# Usage: svn_repo_backup repo_dir dest_dir
function svn_repo_backup() {
    local repo_dir="$1"
    local dest_dir="$2"
    local dest_file=$dest_dir/$(basename "$repo_dir").dump

    if [ -f "$repo_dir"/format ]; then
        echo "Dumping [$repo_dir]"
        mkdir -p "$dest_dir"
        svnadmin dump -q "$repo_dir" > "$dest_file"
    else
        echo "$repo_dir does not appear to be a Subversion repository" > /dev/stderr
    fi
}

# Perform a backup of the Subversion repositories in the specified directory
# using svnadmin dump.
# Usage: svn_repos_backup repos_dir dest_dir
function svn_repos_backup() {
    local repos_dir="$1"
    local base_dir="$2"

    # Set IFS to newline
    local old_IFS="$IFS"
    IFS=$'\n'

    local dir
    for dir in $(find "$repos_dir" -not -path '*/db/format' -type f -name format -printf '%h\n'); do
        local dest_dir=""
        local parent_dir=$(dirname "$dir")
        while [ "x$parent_dir" != "x$repos_dir" ]; do
            dest_dir=$(basename "$parent_dir")/$dest_dir
            parent_dir=$(dirname "$parent_dir")
        done

        svn_repo_backup "$dir" "$base_dir/$dest_dir"
    done

    # Restore IFS
    IFS="$old_IFS"
}

# Perform a MySQL backup using mysqldump.
# Usage: mysql_backup database_name username password host destination_filename create_info
function mysql_backup() {
    local args="--user=$2 --password=$3 --host=$4"
    if [ "$6" = "0" ]; then
        args="${args} --no-create-info"
    fi
    args="${args} --extended-insert $1"

    mkdir -p "$(dirname $5)"
    mysqldump $args > "$5"
}

# Perform a PostgreSQL backups using pg_dump.
# Usage: postgresql_backup database_name destination_filename
function postgresql_backup() {
    local args="--file=$2 --format=c --clean $1"

    mkdir -p "$(dirname $2)"
    pg_dump $args
}

# Generate the MD5 checksum of the specified file and save it to the
# corresponding checksum file.
# Usage: md5_checksum filename
function md5_checksum() {
    local dir=$(dirname "$1")
    local file=$(basename "$1")

    cd "$dir" &&
        md5sum "$file" >> "$CHECKSUM_FILE" &&
    cd -
}

# Delete the specified file if it has the same checksum as the previous entry in
# the checksum file. Note: A basic check of the input filename and the last
# entry in the checksum file is performed; if the filenames do not match, no
# action is taken.
# Usage: delete_if_redundant filename
function delete_if_redundant() {
    local dir=$(dirname "$1")
    local file=$(basename "$1")

    if [ -d "$dir" ]; then
        cd "$dir"

        # Make sure we have at least one file to compare
        local lines=$(cat "$CHECKSUM_FILE" | wc -l)  # Use cat to avoid filename from wc
        if [ $lines -ge 2 ]; then
            local previous_checksum=$(tail -n 2 $CHECKSUM_FILE | head -n 1 | awk '{print $1}')
            local previous_file=$(tail -n 2 $CHECKSUM_FILE | head -n 1 | awk '{print $2}')
            local current_checksum=$(tail -n 1 $CHECKSUM_FILE | awk '{print $1}')
            local current_file=$(tail -n 1 $CHECKSUM_FILE | awk '{print $2}')

#            echo "$FUNCNAME: previous_file = $previous_file, previous_checksum = $previous_checksum, current_file = $current_file, current_checksum = $current_checksum"
            if [ "$file" = "$current_file" ]; then
                if [ "$previous_checksum" = "$current_checksum" ]; then
                    echo "$FUNCNAME: Deleting $file since checksums match"
                    rm "$file"

                    # Remove the file's entry from the checksum file
                    local temp_checksum_file="${CHECKSUM_FILE}.new"
                    head -n $(($lines - 1)) "$CHECKSUM_FILE" > "$temp_checksum_file"
                    mv "$temp_checksum_file" "$CHECKSUM_FILE"
                else
                    echo "$FUNCNAME: Keeping $file since checksums do not match"
                fi  # if [ "$previous_checksum" = "$current_checksum" ]; then
            else
                echo "$FUNCNAME: Filenames do not match: $file, $current_file"
            fi  # if [ "$file" = "$current_file" ]; then
        else
            echo "$FUNCNAME: Not enough entries for comparison"
        fi  # if [ $lines -ge 2 ]; then

        cd -
    else
        echo "$FUNCNAME: Could not change to directory: $dir"
    fi  # if [ -d "$dir" ]; then
}

function md5sum_args() {
    local ostype=${1:-$OSTYPE}
    local args="-c"

    if echo $ostype | grep -iq darwin; then
        args="$args -v"
    fi

    echo $args
}

# Verify the MD5 checksums given in the specified file.
# Usage: verify_md5_checksums checksum_file
function verify_md5_checksums() {
    local dir=$(dirname "$1")
    local file=$(basename "$1")

    cd "$dir" &&
        md5sum $(md5sum_args) "$file" &&
    cd -
}

# Verify the MD5 checksums given in the specified file on the remote host.
# Usage: verify_md5_checksums remote_username remote_hostname checksum_file
function verify_remote_md5_checksums() {
    local dir=$(dirname "$3")
    local file=$(basename "$3")

    local ostype=$(ssh -l $1 $2 "echo \$OSTYPE")

    ssh -l $1 $2 "cd \"$dir\" && md5sum $(md5sum_args $ostype) \"$file\""
}

# Rotate the specified set of files from one directory to another, verifying
# the checksums on the way.
# Usage: rotate_files source_directory file_pattern destination_directory
function rotate_files() {
    local temp_checksum_file="$3"/"${CHECKSUM_FILE}.new"

    cp "$1"/$2 "$3" &&
        cp "$1"/"$CHECKSUM_FILE" "$temp_checksum_file" &&
        verify_md5_checksums "$temp_checksum_file" &&
        cat "$temp_checksum_file" >> "$3"/"$CHECKSUM_FILE" &&
        rm "$temp_checksum_file" &&
        rm "$1"/$2 &&
        rm "$1"/"$CHECKSUM_FILE"
}

# Remove editor backup files and other crap like .DS_Store.
function remove_crap() {
    find "$1" \( \
        -iname ".DS_Store" \
        -or \
        -iname "._*" \
        -or \
        -iname "*.bak" \
        -or \
        -iname "^#*" \
        -or \
        -iname "*~" \
        -or \
        -iname ".*~" \
    \) \
    -delete
}
