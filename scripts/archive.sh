#!/bin/bash

################################################################################
# Setup Script Environment                                                     #
################################################################################

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

source "${SCRIPT_DIR}/_common.sh"

export CADATAPATH=$(realpath "${SCRIPT_DIR}/../")
_print_info_dialog "\$CADATAPATH" $CADATAPATH

################################################################################
# Archive Root CA                                                              #
################################################################################

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
FILENAME="rootca_${TIMESTAMP}.tar"
FILEPATH="${CADATAPATH}/${FILENAME}"

function _create_empty_archive() {
    tar --create --file=$FILEPATH --files-from=/dev/null &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error creating the archive" >&2
    fi
    return $rc
}

function _append_to_archive() {
    tar --append --exclude=.gitignore \
        --directory=$CADATAPATH --file=$FILEPATH $1 &> /dev/null
    if [ $? -eq 0 ]; then
        _print_ok
    else
        _print_error
        APPEND_ERROR=1
    fi
    printf "%s\n" "$1"
}

function _archive_finalizer() {
    if [ $APPEND_ERROR -eq 0 ]; then
        _print_info_dialog "Archive '${FILEPATH}' created"
    else
        _print_error_dialog "There was an error archiving the Root CA" \
            "The word 'FAILED' will be appended to the file name for clarity."
        mv $FILEPATH "$(echo $FILEPATH | sed -E 's/(.*)\.tar/\1_FAILED.tar/')"
    fi
}

_print_header_dialog "Archiving the Root CA"

_print_step_dialog "Creating empty archive file"
_create_empty_archive
_should_exit $?

{
    APPEND_ERROR=0
    _print_step_dialog "Appending files to archive"
    
    _append_to_archive "ca/"
    _append_to_archive "certs/"
    _append_to_archive "crl/"
    _append_to_archive "db/"
    _append_to_archive "kdbx/yk-pin.kdbx"
    _append_to_archive "scripts/_common.sh"
    _append_to_archive "scripts/archive.sh"
    _append_to_archive "scripts/deploy.sh"
    _append_to_archive "scripts/revoke.sh"
    _append_to_archive "scripts/sign.sh"
    _append_to_archive "scripts/update_crl.sh"
    _append_to_archive "ca.env"
    _append_to_archive "openssl.cnf"
    _append_to_archive "pkcs11.cnf"

    _archive_finalizer
}