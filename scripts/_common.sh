#!/bin/bash

################################################################################
# Output print functions                                                       #
################################################################################

function _can_color() {
    colors=$(tput colors 2> /dev/null)
    if [ $? -eq 0 ] && [ $colors -gt 2 ]; then
        return 0
    else
        return 1
    fi
}

function _color() {
    echo -en "$1"
}

RESET="\e[0m"
RED="\e[1;31m"
WHITE="\e[1;37m"
BLUE="\e[1;34m"
GREEN="\e[1;32m"

function _print_header_dialog() {
    local text=$(printf "$@")
    local text_len="${#text}"
    local text_len_pad=$(( $text_len + 6 ))
    _color $WHITE
    printf "\n%${text_len_pad}s\n" | tr " " "="
    printf "=  %s  =\n" "${text}"
    printf "%${text_len_pad}s\n" | tr " " "="
    _color $RESET
}

function _print_step_dialog() {
    local text=$1
    shift
    string="\n>>> ${text}...\n"
    _color $WHITE
    printf "${string}" "$@"
    _color $RESET
}

function _print_info_dialog() {
    local text=$1
    shift
    _color $BLUE
    printf "\n!!! INFO: %s\n" "$text"
    if [ "$#" -ne 0 ]; then
        printf "!!! %s\n" "$@"
    fi
    _color $RESET
}

function _print_confirmation_dialog() {
    local color=$1
    shift
    local header=$1
    local is_confirmed=0
    shift
    _color $color
    printf "\n!!! %s\n" "$header"
    if [ "$#" -ne 0 ]; then
        printf "!!! %b\n" "$@"
    fi
    echo ""
    read -p "Do you want to continue? Type 'CONFIRM': " -r
    if [[ $REPLY == "CONFIRM" ]]; then
        is_confirmed=1
    fi
    _color $RESET
    if [ $is_confirmed -eq 1 ]; then
        return 0
    else
        return 1
    fi
}

function _print_error_dialog() {
    local header=$1
    shift
    _color $RED
    printf "\n??? ERROR: %s\n" "${header}" >&2
    if [ "$#" -ne 0 ]; then
        printf "???\t%s\n" "$@" >&2
    fi
    _color $RESET
}

function _print_ok() {
    _color $GREEN
    printf "OK\t"
    echo -en $RESET
}

function _print_ok_ln() {
    _color $GREEN
    printf "OK\n"
    echo -en $RESET
}

function _print_error() {
    _color $RED
    printf "ERROR\t"
    _color $RESET
}

function _print_additional_line_info() {
    printf "\t%s\n" "$@"
}

function _print_complete() {
    local header=$1
    shift
    _color $GREEN
    printf "\n!!! %s\n" "$header"
    if [ "$#" -ne 0 ]; then
        printf "!!! %b\n" "$@"
    fi
    _color $RESET
}

################################################################################
# Required commands functions                                                  #
################################################################################

function _check_command() {
    local text=$1
    shift
    eval $@ &> /dev/null
    if [ $? -eq 0 ]; then
        _print_ok
    else
        _print_error
        CHECK_COMMAND_ERROR=1
    fi
    printf "%s\n" "$text"
}

function _check_command_finalize() {
    if [ "$CHECK_COMMAND_ERROR" -ne 0 ]; then
        _print_error_dialog "The above commands and components are required!" \
            "If any commands or components that are marked 'ERROR', ensure" \
            "that they are installed and/or in your \$PATH before running the" \
            "initialization script."
        return 1
    else
        _print_info_dialog "Required commands and components found"
        return 0
    fi
}

################################################################################
# Keyring Functions                                                            #
################################################################################

export ROOTCA_KEYRING_NAME="rootca"
export ROOTCA_KEYRING=

function _create_keyring() {
    ROOTCA_KEYRING=$(keyctl newring ${ROOTCA_KEYRING_NAME} @s)
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error creating the keyring!" >&2
    fi
    return $rc
}

function _destroy_keyring() {
    keyctl unlink $ROOTCA_KEYRING &> /dev/null
}

function _load_yk_pin() {
    pin=$(keepassxc-cli attachment-export --stdout \
        "${CADATAPATH}/kdbx/yk-pin.kdbx" yubikey PIN)
    rc=$?
    if [ $rc -ne 0 ]; then
        _print_error_dialog "There was an error opening the YubiKey PIN database" >&2
        return $rc
    fi
    keyctl add user yk-pin "$pin" $ROOTCA_KEYRING
    rc=$?
    if [ $rc -ne 0 ]; then
        _print_error_dialog "There was an error storing the PIN in the Keyring" >&2
        return $rc
    fi
    _print_ok_ln >&2
    return 0
}

################################################################################
# CA Functions                                                                 #
################################################################################

function _generate_crl() {
    openssl ca \
        -config "${CADATAPATH}/openssl.cnf" \
        -engine pkcs11 \
        -keyform engine \
        -gencrl \
        -passin file:<(keyctl pipe $KID_YK_PIN) \
        -out "${CADATAPATH}/crl/ca.crl.pem" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error generating the CRL" >&2
    fi
    return $rc
}

function _convert_crl_to_der() {
    openssl crl \
        -outform der \
        -in "${CADATAPATH}/crl/ca.crl.pem" \
        -out "${CADATAPATH}/crl/ca.crl" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error converting the CRL format" >&2
    fi
    return $rc
}

################################################################################
# Github App Functions                                                         #
################################################################################

function _b64enc() {
    openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'
}

function _ghapp_get_jwt_header_payload() {
    header=$( printf '{"typ":"JWT","alg":"RS256"}' | _b64enc )
    now=$(date +%s)
    payload=$(echo -n "{\"iat\":$(( ${now} - 60 )),\"exp\":$(( ${now} + 600 )),\"iss\":\"${DEPLOY_APP_ID}\"}" | _b64enc )
    printf "${header}"."${payload}"
}

function _ghapp_get_installation() {
    curl -s -f -X GET \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $JWT" \
    "https://api.github.com/repos/${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}/installation"
}

################################################################################
# Control Functions                                                            #
################################################################################

function _should_exit() {
    local rc=$1
    if [ $rc -ne 0 ]; then
        if [[ -n $ROOTCA_KEYRING ]]; then
            _destroy_keyring
        fi
        exit $rc
    fi
}
