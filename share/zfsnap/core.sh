#!/bin/sh

# This file is licensed under the BSD-3-Clause license.
# See the AUTHORS and LICENSE files for more information.
#
# wiki:             https://github.com/zfsnap/zfsnap/wiki
# repository:       https://github.com/zfsnap/zfsnap
# Bug tracking:     https://github.com/zfsnap/zfsnap/issues

readonly VERSION=2.0.0.pre

# COMMANDS
ESED='sed -E'
ZFS_CMD='/sbin/zfs'
ZPOOL_CMD='/sbin/zpool'

# VARIABLES
TTL='1m'                            # default snapshot ttl
VERBOSE="false"                     # Verbose output?
DRY_RUN="false"                     # Dry run?
POOLS=""                            # List of pools
FS_LIST=''                          # List of all ZFS filesystems
SKIP_POOLS=""                       # List of pools to skip

readonly OS=`uname`
readonly TTL_PATTERN="([0-9]+y)?([0-9]+m)?([0-9]+w)?([0-9]+d)?([0-9]+h)?([0-9]+M)?([0-9]+[s])?"
readonly DATE_PATTERN='20[0-9][0-9]-[01][0-9]-[0-3][0-9]_[0-2][0-9]\.[0-5][0-9]\.[0-5][0-9]'
TEST_MODE="${TEST_MODE:-false}"     # When set to "true", Exit won't really exit
TIME_FORMAT='%Y-%m-%d_%H.%M.%S'     # format for snapshot creation
RETVAL=''                           # used by functions so we can avoid spawning subshells

## FUNCTIONS

Err() {
    printf '%s\n' "ERROR: $*" > /dev/stderr
}
Exit() {
    IsTrue $TEST_MODE || exit $1
}
Fatal() {
    printf '%s\n' "FATAL: $*" > /dev/stderr
    exit 1
}
Note() {
    printf '%s\n' "NOTE: $*" > /dev/stderr
}
Warn() {
    printf '%s\n' "WARNING: $*" > /dev/stderr
}

# Converts datetime to seconds
Date2Timestamp() {
    case $OS in
    'FreeBSD' | 'Darwin' )
        date -j -f '%Y-%m-%d_%H.%M.%S' "$1" '+%s'
        ;;
    *)
        date_normal="`echo $1 | $ESED -e 's/\./:/g; s/(20[0-9][0-9]-[01][0-9]-[0-3][0-9])_([0-2][0-9]:[0-5][0-9]:[0-5][0-9])/\1 \2/'`"
        date --date "$date_normal" '+%s'
        ;;
    esac
}

# Returns 0 if filesystem exists
FSExists() {
    FS_LIST="${FS_LIST:-`$ZFS_CMD list -H -o name`}"

    for i in $FS_LIST; do
        [ "$1" = "$i" ] && return 0
    done

    return 1
}

# Returns 0 if argument is "false"
IsFalse() {
    IsTrue "$1" && return 1 || return 0
}

# Returns 0 if it looks like a snapshot
IsSnapshot() {
    case "$1" in
        [!@]*@*[!@])
            return 0;;
        *)
            return 1;;
    esac
}

# Returns 0 if argument is "true"
IsTrue() {
    case "$1" in
        true)
            return 0
            ;;
        false)
            return 1
            ;;
        *)
            Fatal "must be true or false"
            ;;
    esac
}

# Populates the $SKIP_POOLS global variable; does not return anything
PopulateSkipPools() {
    [ "$1" ] || Fatal "PopulateSkipPools requires an argument!"
    POOLS="${POOLS:-`$ZPOOL_CMD list -H -o name`}"

    for i in $POOLS; do
        $ZPOOL_CMD status $i | grep -q -e "$1 in progress" && SKIP_POOLS="$SKIP_POOLS $i"
    done
}

# Removes zfs snapshot
RmZfsSnapshot() {
    SkipPool $1 || return 1

    zfs_destroy="$ZFS_CMD destroy $*"

    # hardening: make really, really sure we are deleting snapshot
    if IsSnapshot "$1"; then
        if IsFalse $DRY_RUN; then
            if $zfs_destroy > /dev/stderr; then
                IsTrue $VERBOSE && echo "$zfs_destroy  ... DONE"
            else
                IsTrue $VERBOSE && echo "$zfs_destroy  ... FAIL"
            fi
        else
            echo "$zfs_destroy"
        fi
    else
        echo "FATAL: trying to delete zfs pool or filesystem? WTF?" > /dev/stderr
        echo "  This is bug, we definitely don't want that." > /dev/stderr
        echo "  Please report it to https://github.com/zfsnap/zfsnap/issues" > /dev/stderr
        echo "  Don't panic, nothing was deleted :)" > /dev/stderr
        Exit 1
    fi
}

# Converts seconds to TTL
Seconds2TTL() {
    # convert seconds to human readable time
    xtime=$1

    years=$(($xtime / 31536000))
    xtime=$(($xtime % 31536000))
    [ ${years:-0} -gt 0 ] && years="${years}y" || years=""

    months=$(($xtime / 2592000))
    xtime=$(($xtime % 2592000))
    [ ${months:-0} -gt 0 ] && months="${months}m" || months=""

    days=$(($xtime / 86400))
    xtime=$(($xtime % 86400))
    [ ${days:-0} -gt 0 ] && days="${days}d" || days=""

    hours=$(($xtime / 3600))
    xtime=$(($xtime % 3600))
    [ ${hours:-0} -gt 0 ] && hours="${hours}h" || hours=""

    minutes=$(($xtime / 60))
    [ ${minutes:-0} -gt 0 ] && minutes="${minutes}M" || minutes=""

    seconds=$(($xtime % 60))
    [ ${seconds:-0} -gt 0 ] && seconds="${seconds}s" || seconds=""

    RETVAL="${years}${months}${days}${hours}${minutes}${seconds}"
}

# Returns 1 if ZFS operations on given pool should be skipped
# This function's name implies the opposite of what it does. It
# should be renamed, but I can't come up with anything intuitive and short.
SkipPool() {
    for i in $SKIP_POOLS; do
        TrimToPool "$1"
        if [ "$RETVAL" = "$i" ]; then
            IsTrue $VERBOSE && Note "No actions will be performed on '$1'. Resilver or Scrub is running on pool."
            return 1
        fi
    done
    return 0
}

# Return the date (anything that matches the "date pattern")
# If no "date pattern" is found, an empty string will be returned.
TrimToDate() {
    snapshot_name="$1"

    # make sure it contains a date
    [ "${snapshot_name##*$DATE_PATTERN*}" ] && RETVAL='' && return 1

    pre_date="${snapshot_name%$DATE_PATTERN*}"
    post_date="${snapshot_name##*$DATE_PATTERN}"

    snapshot_date="${snapshot_name##$pre_date}"
    snapshot_date="${snapshot_date%%$post_date}"

    if [ -z "${snapshot_date##$DATE_PATTERN}" ]; then
        RETVAL="$snapshot_date" && return 0
    else
        RETVAL='' && return 1
    fi
}

# Return the file system name (everything before the '@')
# ZFS reserves '@' to deliminate snapshots. At max, there will be one per dataset.
# If no valid file system is found, an empty string will be returned.
TrimToFileSystem() {
    snapshot="$1"
    file_system="${snapshot%%@*}"

    if FSExists "$file_system"; then
        RETVAL="$file_system" && return 0
    else
        RETVAL='' && return 1
    fi
}

# Return the pool name (anything before the first '/' or '@')
# If no '/' or '@' is found, the submitted string will be returned.
TrimToPool() {
    RETVAL="${1%%[/@]*}"
}

# Return the prefix in a snapshot name (anything prior to the "snapshot date")
# If no valid "snapshot date" or prefix is found, an empty string will be returned.
TrimToPrefix() {
    snapshot_name="$1"
    TrimToDate "$snapshot_name" && snapshot_date="$RETVAL"
    snapshot_prefix="${snapshot_name%%$snapshot_date*}"

    if ValidPrefix "$snapshot_prefix"; then
        RETVAL="$snapshot_prefix" && return 0
    else
        RETVAL='' && return 1
    fi
}

# Return the snapshot name (everything after the '@')
# ZFS reserves '@' to deliminate snapshots. At max, there will be one per dataset.
# If no valid snapshot name is found, an empty string will be returned
TrimToSnapshotName() {
    snapshot="$1"
    snapshot_name="${snapshot##*@}"

    if ValidSnapshotName "$snapshot_name"; then
        RETVAL="$snapshot_name" && return 0
    else
        RETVAL='' && return 1
    fi
}

# Return the TTL (anything after the last '--')
# If no valid TTL is found, an empty string will be returned.
TrimToTTL() {
    snapshot="$1"
    ttl="${snapshot##*--}"

    if ValidTTL "$ttl"; then
        RETVAL="$ttl" && return 0
    else
        RETVAL='' && return 1
    fi
}

# Converts TTL to seconds
TTL2Seconds() {
    ttl="$1"
    seconds=0
    while [ "$ttl" ]; do
        case "$ttl" in
            *y*) seconds=$(($seconds + (${ttl%%y*} * 31536000))); ttl=${ttl##*y} ;;
            *m*) seconds=$(($seconds + (${ttl%%m*} * 2592000))); ttl=${ttl##*m} ;;
            *w*) seconds=$(($seconds + (${ttl%%w*} * 604800))); ttl=${ttl##*w} ;;
            *d*) seconds=$(($seconds + (${ttl%%d*} * 86400))); ttl=${ttl##*d} ;;
            *h*) seconds=$(($seconds + (${ttl%%h*} * 3600))); ttl=${ttl##*h} ;;
            *M*) seconds=$(($seconds + (${ttl%%M*} * 60))); ttl=${ttl##*M} ;;
             *s) seconds=$(($seconds + ${ttl%%s*})); ttl=${ttl##*s} ;;
              *) Fatal "TTL2Seconds could not convert '$1'!" ;;
        esac
    done

    RETVAL="$seconds"
}

# Check validity of a prefix
ValidPrefix() {
    snapshot_prefix="$1"

    [ -z "$PREFIXES" ] && [ -z "$snapshot_prefix" ] && return 0

    for i in $PREFIXES; do
        [ "$snapshot_prefix" = "$i" ] && return 0
    done

    return 1
}

# Returns 0 if it's a snapshot name that matches zfsnap's name pattern
# This also filters for any prefixes in effect
ValidSnapshotName() {
    IsSnapshot "$1" && return 1
    snapshot_name="$1"

    TrimToPrefix "$snapshot_name" && snapshot_prefix="$RETVAL" || return 1
    TrimToDate "$snapshot_name" && snapshot_date="$RETVAL" || return 1
    TrimToTTL "$snapshot_name" && snapshot_ttl="$RETVAL" || return 1

    rebuilt_name="${snapshot_prefix}${snapshot_date}--${snapshot_ttl}"
    [ "$rebuilt_name" = "$snapshot_name" ] && return 0 || return 1
}

# Check validity of TTL
ValidTTL() {
    ttl="$1"

    [ "$ttl" = '' ] && return 1

    while [ "$ttl" ]; do
        case "$ttl" in
            *y*) [ ${ttl%y*} -gt 0 2> /dev/null ] && ttl=${ttl##*y} || return 1 ;;
            *m*) [ ${ttl%m*} -gt 0 2> /dev/null ] && ttl=${ttl##*m} || return 1 ;;
            *w*) [ ${ttl%w*} -gt 0 2> /dev/null ] && ttl=${ttl##*w} || return 1 ;;
            *d*) [ ${ttl%d*} -gt 0 2> /dev/null ] && ttl=${ttl##*d} || return 1 ;;
            *h*) [ ${ttl%h*} -gt 0 2> /dev/null ] && ttl=${ttl##*h} || return 1 ;;
            *M*) [ ${ttl%M*} -gt 0 2> /dev/null ] && ttl=${ttl##*M} || return 1 ;;
             *s) [ ${ttl%s*} -gt 0 2> /dev/null ] && ttl=${ttl##*s} || return 1 ;;
              *) return 1 ;;
        esac
    done

    return 0
}

## MAIN
case $OS in
    'FreeBSD')
        ;;
    'SunOS')
        ESED='sed -r'
        if [ -d "/usr/gnu/bin" ]; then
            export PATH="/usr/gnu/bin:$PATH"
        else
            Fatal "GNU bin directory not found."
        fi
        ;;
    'Linux')
        ESED='sed -r'
        ;;
    'Darwin')
        ZFS_CMD='/usr/sbin/zfs'
        ZPOOL_CMD='/usr/sbin/zpool'
        ;;
    *)
        Fatal "Your OS isn't supported"
        ;;
esac
