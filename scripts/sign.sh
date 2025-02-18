#!/bin/bash

################################################################################
# Parse Script Arguments                                                       #
################################################################################

function _usage() {
    cat <<EOF
usage: sign.sh -in <CSR> [ -out <CRT> ] [ -chain ] [ -force ]
EOF
}

if [ $# -eq 0 ]; then
    _usage
    exit 1
fi

declare CSR_IN
CRT_OUT="/dev/stdout"
CHAIN=0
FORCE=0
while [ "$#" -ne 0 ]; do
    if [[ $1 == "-in" ]]; then
        shift
        CSR_IN=$(realpath $1)
    elif [[ $1 == "-out" ]]; then
        shift
        CRT_OUT=$(realpath $1)
    elif [[ $1 == "-chain" ]]; then
        CHAIN=1
    elif [[ $1 == "-force" ]]; then
        FORCE=1
    fi
    shift
done

if [ -z $CSR_IN ]; then
    _usage
    exit 1
fi

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
# Sign CSR                                                                     #
################################################################################

function _compile_openssl_sign() {
    local cmd=(
        "openssl" 
        "ca"
        "-notext"
        "-config ${CADATAPATH}/openssl.cnf"
        "-engine pkcs11"
        "-keyform engine"
        "-extensions issuing_ca_ext"
        "-passin file:<(keyctl pipe $KID_YK_PIN)"
        "-in $CSR_IN"
    )
    if [ $FORCE -ne 0 ]; then
        cmd+=("-batch")
    fi
    echo -n "${cmd[@]}"
}

_print_header_dialog "Signing CSR"

crt=$(eval $(_compile_openssl_sign))
if [ $CHAIN -ne 0 ]; then
    crt=$(cat "${CADATAPATH}/ca/ca.crt.pem" <(printf '%s\n' "$crt"))
fi
echo
echo "$crt" > "${CRT_OUT}"

_print_info_dialog "Certificate Signed"

################################################################################
# Cleanup                                                                      #
################################################################################

_destroy_keyring
