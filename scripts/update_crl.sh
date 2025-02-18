#!/bin/bash

################################################################################
# Setup Script Environment                                                     #
################################################################################

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

source "${SCRIPT_DIR}/_common.sh"

export CADATAPATH=$(realpath "${SCRIPT_DIR}/../")
_print_info_dialog "\$CADATAPATH" $CADATAPATH

################################################################################
# Check Required Commands                                                      #
################################################################################

_print_header_dialog "Checking for required commands and components"

{
    CHECK_COMMAND_ERROR=0

    _check_command "openssl"                command -v openssl
    _check_command "openssl-pkcs11 engine"  openssl engine -t pkcs11
    _check_command "keyutils (keyctl)"      command -v keyctl
    _check_command "keepassxc-cli"          command -v keepassxc-cli

    _check_command_finalize
}
_should_exit $?

################################################################################
# Create Keyring and Load PIN                                                  #
################################################################################

_print_header_dialog "Initializing Root CA Keyring"

_print_step_dialog "Creating Root CA Keyring"
_create_keyring

_print_step_dialog "Loading YubiKey PIN"
KID_YK_PIN=$(_load_yk_pin)
_should_exit $?

################################################################################
# Update CRL                                                                   #
################################################################################

_print_header_dialog "Update CRL"

_print_step_dialog "Generating CRL"
_generate_crl
_should_exit $?

_print_step_dialog "Converting CRL to DER format"
_convert_crl_to_der
_should_exit $?

################################################################################
# Cleanup                                                                      #
################################################################################

_destroy_keyring
