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

function _purge_directory() {
    rm -rf $1
    _color $RED
    printf "PURGED\t"
    _color $RESET
    printf "%s\n" $1
}

function _purge_file() {
    rm -f $1
    _color $RED
    printf "PURGED\t"
    _color $RESET
    printf "%s\n" $1
}

_print_confirmation_dialog $RED \
    "WARNING" "" \
    "This action will permanently remove ALL Root CA data." \
    "" \
    "This action is NOT reversable!"

_should_exit $?

_print_header_dialog "Sanitizing Root CA Directory Structure"

_purge_directory "${CADATAPATH}/ca"
_purge_directory "${CADATAPATH}/certs"
_purge_directory "${CADATAPATH}/crl"
_purge_directory "${CADATAPATH}/db"
_purge_directory "${CADATAPATH}/kdbx"
_purge_directory "${CADATAPATH}/secrets"
_purge_file "${CADATAPATH}/ca.env"
_purge_file "${CADATAPATH}/openssl.cnf"
_purge_file "${CADATAPATH}/rootca_*"

_print_info_dialog "Complete"
