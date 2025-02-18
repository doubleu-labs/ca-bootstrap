#!/bin/bash

################################################################################
# Setup Script Environment                                                     #
################################################################################

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

source "${SCRIPT_DIR}/_common.sh"

CADATAPATH=$(realpath "${SCRIPT_DIR}/../")
_print_info_dialog "\$CADATAPATH" $CADATAPATH

################################################################################
# Purge CA Data                                                                #
################################################################################

function _dir_exists() {
    local exists=0
    if [ -d "${1}" ]; then
        _print_error >&2
        DIR_EXISTS=1
        exists=1
    else
        _print_ok >&2
        exists=0
    fi
    printf "${1}\n"
    return $exists
}

function _dir_exists_finalize() {
    if [ $DIR_EXISTS -ne 0 ]; then
        _print_error_dialog "\$CADATAPATH not clean!" \
            "There are some required directories that already exist." \
            "Ensure that the data in them is no longer required and run" \
            "the 'purge.sh' script."
        return 1
    else
        return 0
    fi
}

function _dir_create() {
    mkdir $1 > /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok >&2
    else
        _print_error >&2
        MKDIR_ERROR=1
    fi
    printf "${1}\n"
    return $rc
}

function _dir_create_finalize() {
    if [ $MKDIR_ERROR -ne 0 ]; then
        _print_error_dialog "There was an error creating some directories!" \
            "Do you have permission to write to the \$CADATAPATH?"
        return 1
    else
        return 0
    fi
}

_print_header_dialog "Setup Root CA Structure"

{

    _print_step_dialog "Check for existing directories"

    DIR_EXISTS=0

    _dir_exists "${CADATAPATH}/ca"
    _dir_exists "${CADATAPATH}/certs"
    _dir_exists "${CADATAPATH}/crl"
    _dir_exists "${CADATAPATH}/db"
    _dir_exists "${CADATAPATH}/kdbx"
    _dir_exists "${CADATAPATH}/secrets"

    _dir_exists_finalize
    _should_exit $?

}

{
    _print_step_dialog "Creating directories"

    MKDIR_ERROR=0

    _dir_create "${CADATAPATH}/ca"
    _dir_create "${CADATAPATH}/certs"
    _dir_create "${CADATAPATH}/crl"
    _dir_create "${CADATAPATH}/db"
    _dir_create "${CADATAPATH}/kdbx"
    _dir_create "${CADATAPATH}/secrets"

    _dir_create_finalize
    _should_exit $?
}

_print_step_dialog "Copy env file"

cp "${CADATAPATH}/ca.template.env" "${CADATAPATH}/ca.env"
_print_ok_ln

_print_complete "\$CADATAPATH setup complete!" \
    "" \
    "Next, you'll need to set all of the variables in 'ca.env'." \
    "" \
    "Optionally, edit the '[match_pol]' section of 'openssl.template.cnf'" \
    "to match your desired environment." \
    "" \
    "Finally, run the 'initialize.sh' script to create your new Root CA."
