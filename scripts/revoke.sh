#!/bin/bash

################################################################################
# Setup Script Environment                                                     #
################################################################################

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

source "${SCRIPT_DIR}/_common.sh"

export CADATAPATH=$(realpath "${SCRIPT_DIR}/../")
_print_info_dialog "\$CADATAPATH" $CADATAPATH

################################################################################
# Parse Script Arguments                                                       #
################################################################################

function _usage() {
    cat <<EOF
usage:  revoke.sh -in <CRT> [ARGUMENTS]
        revoke.sh -serial <SERIAL> [ARGUMENTS]

ARGUMENTS:
    -reason <REASON>        (default: unspecified)
    -date [ <YYYYMMDDhhmmssZ> | now ]
    -instruction <INSTRUCTION>

REASON:
    unspecified
    keyCompromise           (requires '-date')
    CACompromise            (requires '-date')
    affiliationChanged
    superseded
    cessationOfOperation
    certificateHold         (requires '-instruction')
    removeFromCRL

INSTRUCTION:
    none
    callIssuer
    reject
EOF
}

if [ $# -eq 0 ]; then
    _usage
    exit 1
fi

declare C_IN C_SER R_DATE R_INST
REASON="unspecified"
while [ "$#" -ne 0 ]; do
    case $1 in
        "-in")
            shift
            C_IN=$(realpath $1)
        ;;
        "-serial")
            shift
            C_SER=$1
        ;;
        "-reason")
            shift
            REASON=$1
        ;;
        "-date")
            shift
            R_DATE=$1
        ;;
        "-instruction")
            shift
            R_INST=$1``
        ;;
        *)
            _print_error_dialog "Unknown argument '$1'"
            exit 1
        ;;
    esac
    shift
done

################################################################################
# Validate Input                                                               #
################################################################################

function _build_valid_inputs() {
    printf '^('
    printf '%s' "${1-}"
    shift
    printf '%s' "${@/#/|}"
    printf ')'
}

# Ensure only file or serial is specified

if [[ ! -z ${C_IN+x} ]] && [[ ! -z ${C_SER} ]]; then
    _print_error_dialog "Only specify a certificate file OR serial number"
    _usage
    exit 1
fi

# Validate revoke reason

VALID_REASON=(
    "unspecified"
    "keyCompromise"
    "CACompromise"
    "affiliationChanged"
    "superseded"
    "cessationOfOperation"
    "certificateHold"
    "removeFromCRL"
)
if [[ ! $REASON =~ $(_build_valid_inputs ${VALID_REASON[@]}) ]]; then
    _print_error_dialog "'$REASON' is not a valid reason"
    _usage
    exit 1
fi

# Validate if date is required and format is conformant

VALID_DATE_REASON=(
    "keyCompromise"
    "CACompromise"
)
VALID_DATE_REASON_MATCH=$(_build_valid_inputs ${VALID_DATE_REASON[@]})
if  [[ $REASON =~ $VALID_DATE_REASON_MATCH ]] && \
    [[ -z ${R_DATE+x} ]]
then
    # If date is required but not set
    _print_error_dialog "'-date' is required for reason '$REASON'"
    _usage
    exit 1
elif    [[ ! $REASON =~ $VALID_DATE_REASON_MATCH ]] && \
        [[ ! -z ${R_DATE+x} ]]
then
    # If date is set and not required
    _print_error_dialog "'-date' is not a valid argument for the reason '$REASON'"
    _usage
    exit 1
fi


if  [[ ! -z ${R_DATE+x} ]] && \
    [[ ! $R_DATE =~ ^[0-9]{14}Z$ ]] && \
    [[ ! $R_DATE == "now" ]]
then
    # Ensure date conforms to `YYYYMMDDhhmmssZ` format
    _print_error_dialog "'-date' is not in the correct format" \
        'must be formatted as `YYYYMMDDhhmmssZ`, or the keywork `now`.'
    _usage
    exit 1
fi

if [[ $R_DATE == "now" ]]; then
    R_DATE=$(date -u +%Y%m%d%H%M%SZ)
fi

# Validate hold instructions
VALID_HOLD_INST=(
    "none"
    "callIssuer"
    "reject"
)
if [[ -z ${R_INST+x} ]] && [[ $REASON == "certificateHold" ]]; then
    # Ensure `-instruction` is set if `certificateHold` is the reason
    _print_error_dialog "'-instruction' is required for reason '$REASON'"
    _usage
    exit 1
elif    [[ ! -z ${R_INST} ]] && \
        [[ ! $R_INST =~ $(_build_valid_inputs ${VALID_HOLD_INST[@]}) ]]
then
    # Ensure `-instruction` is a valid option
    _print_error_dialog "'$R_INST' is not a valid argument for '-instruction'"
    _usage
    exit 1
fi

# Ensure serial is uppercase
if [[ ! -z ${C_SER+x} ]]; then
    upper=$(echo $C_SER | tr '[:lower:]' '[:upper:]')
    C_IN="${CADATAPATH}/certs/${upper}.pem"
fi

# If certificate file not found, exit
if [[ ! -f $C_IN ]]; then
    _print_error_dialog "CERTIFICATE NOT FOUND" "$C_IN"
    exit 1
fi

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
# Revoke Certificate                                                           #
################################################################################

function _convert_instruction() {
    case $1 in
        "none")
        printf "holdInstructionNone"
        ;;
        "callIssuer")
        printf "holdInstructionCallIssuer"
        ;;
        "reject")
        printf "holdInstructionReject"
        ;;
    esac
}

function _compile_openssl_revoke() {
    local serial=$1
    local cmd=(
        "openssl"
        "ca"
        "-config ${CADATAPATH}/openssl.cnf"
        "-engine pkcs11"
        "-keyform engine"
        "-passin file:<(keyctl pipe $KID_YK_PIN)"
        "-crl_reason $REASON"
        "-revoke $C_IN"
    )
    case $REASON in
        "keyCompromise")
            cmd+=("-crl_compromise $R_DATE")
        ;;
        "CACompromise")
            cmd+=("-crl_CA_compromise $R_DATE")
        ;;
        "certificateHold")
            cmd+=("-crl_hold $(_convert_instruction $R_INST)")
        ;;
    esac
    echo -n "${cmd[@]}"
}

_print_header_dialog "Revoking Certificate"

_print_step_dialog "Revoking '$C_IN'"

eval $(_compile_openssl_revoke)
_should_exit $?

_print_info_dialog "Certificate Revoked!"

_print_step_dialog "Updating CRL"

_generate_crl
_should_exit $?

_print_step_dialog "Converting CRL to DER format"
_convert_crl_to_der
_should_exit $?

################################################################################
# Cleanup                                                                      #
################################################################################

_destroy_keyring

################################################################################
# DONE!!!                                                                      #
################################################################################

_print_complete "Certificate revoked and CRL updated!" \
    "" \
    "Be sure to distribute these changes using the 'deploy.sh' script!" \
    "" \
    "Also, don't forget to run the 'archive.sh' script to generate a new" \
    "archive of your Root CA containing the updated database."
