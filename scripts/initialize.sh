#!/bin/bash

################################################################################
# Setup Script Environment                                                     #
################################################################################

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

source "${SCRIPT_DIR}/_common.sh"

export CADATAPATH=$(realpath "${SCRIPT_DIR}/../")
_print_info_dialog "\$CADATAPATH" $CADATAPATH

source "${CADATAPATH}/ca.env"

################################################################################
# Check Required Commands                                                      #
################################################################################

_print_header_dialog "Checking for required commands and components"

{
    CHECK_COMMAND_ERROR=0

    _check_command "openssl"                command -v openssl
    _check_command "openssl-pkcs11 engine"  openssl engine -t pkcs11
    _check_command "keyutils (keyctl)"      command -v keyctl
    _check_command "ykman"                  command -v ykman
    _check_command "yubico-piv-tool"        command -v yubico-piv-tool
    _check_command "jq"                     command -v jq
    _check_command "keepassxc-cli"          command -v keepassxc-cli

    _check_command_finalize
}
_should_exit $?

################################################################################
# Check that YubiKey is connected and ready                                    #
################################################################################

function _check_for_yubikey_devices() {
    local devices=$(ykman list)
    if [ "${#devices}" -eq 0 ]; then
        _print_error_dialog "No YubiKey devices detected" "Exiting..."
        return 1
    fi
    local device_count=$(echo $devices | wc -l)
    if [ $device_count -ne 1 ]; then
        _print_error_dialog "Multiple YubiKey devices detected." \
            "Ensure only one YubiKey is inserted and that it is the device" \
            "intended to store the Root CA"
        return 1
    fi
    _print_ok_ln >&2
    return 0
}

function _check_for_yubikey_default_secrets() {
    local info=$(ykman piv info)
    for secret in PIN PUK "Management Key"; do
        local status=""
        echo $info | grep default | grep -i "$secret" &> /dev/null
        if [ $? -eq 0 ]; then
            _print_ok
            status="DEFAULT"
        else
            _print_error
            status="NON-DEFAULT"
            CHECK_YUBIKEY_ERROR=1
        fi
        printf "%s\t%s\n" "$secret" "$status"
    done
}

function _check_for_existing_yubikey_certificates() {
    local cert_slots=
    cert_slots=$(ykman piv info | grep -i slot)
    if [ $? -eq 0 ]; then
        _print_error_dialog "Certificates Found!" \
            "Slot(s) with existing certificates:" \
            "$(echo "${cert_slots[@]}" | awk '{print $2}' | awk -v RS= '{$1=$1}1')"
        CHECK_YUBIKEY_ERROR=1
    else
        _print_ok_ln
    fi
}

function _check_for_existing_yubikey_private_keys() {
    local keys_found=()
    for slot in 9A 9C 9D 9E; do
        ykman piv keys info $slot &> /dev/null
        if [ $? -eq 0 ]; then
            keys_found+=($slot)
        fi
    done
    if [ "${#keys_found}" -gt 0 ]; then
        _print_error_dialog "Private keys found on the YubiKey" \
            "Slot(s) with existing private keys:" \
            "${keys_found[*]}"
        CHECK_YUBIKEY_ERROR=1
    else
        _print_ok_ln
    fi
}

function _check_yubikey_finalize() {
    if [ "$CHECK_YUBIKEY_ERROR" -ne 0 ]; then
        _print_error_dialog "The inserted YubiKey device is not currently usable" \
            'Run the command `ykman piv reset` to prepare the YubiKey for use.' \
            "The YubiKey must be in a factory-default state."
        return 1
    else
        _print_info_dialog "The following YubiKey is ready for Root CA use." \
            "$(ykman list)"
        return 0
    fi
}

_print_header_dialog "Checking that the YubiKey is connected and ready"

{
    CHECK_YUBIKEY_ERROR=0

    _print_step_dialog "Checking for YubiKey devices"
    _check_for_yubikey_devices
    _should_exit $?

    _print_step_dialog "Checking that YubiKey secrets are default"
    _check_for_yubikey_default_secrets

    _print_step_dialog "Checking for existing YubiKey certificates"
    _check_for_existing_yubikey_certificates

    _print_step_dialog "Checking for existing YubiKey private keys"
    _check_for_existing_yubikey_private_keys

    _check_yubikey_finalize
}
_should_exit $?

################################################################################
# Verify that CA directories are empty                                         #
################################################################################

function _check_ca_directory() {
    local dir=$1
    count=$(ls -I '.gitignore' $dir | wc -l)
    if [ "$count" -eq 0 ]; then
        _print_ok
    else
        _print_error
        CHECK_CA_DIRECTORY_ERROR=1
    fi
    printf "%s\n" "${dir/#$CADATAPATH}"
}

function _check_ca_directory_finalize() {
    if [ "$CHECK_CA_DIRECTORY_ERROR" -ne 0 ]; then
        _print_error_dialog "CA directories contain files and are not ready!" \
            "An existing CA, or stray files, may exist in directories" \
            "required to initialize a new CA. If you're ABSOLUTELY POSITIVE" \
            "that you do not want to keep the existing files, run the" \
            "'scripts/purge.sh' script to clean the CA directories"
        return 1
    else
        _print_info_dialog "CA directories are ready"
        return 0
    fi
}

_print_header_dialog "Verifying that CA directories are empty and ready"

{
    CHECK_CA_DIRECTORY_ERROR=0

    _check_ca_directory ${CADATAPATH}/ca
    _check_ca_directory ${CADATAPATH}/certs
    _check_ca_directory ${CADATAPATH}/crl
    _check_ca_directory ${CADATAPATH}/db
    _check_ca_directory ${CADATAPATH}/kdbx

    _check_ca_directory_finalize
}
_should_exit $?

################################################################################
# Validate ca.env file variables                                               #
################################################################################

function _get_ca_url() {
    echo ${DEPLOY_PAGES_CUSTOM_DOMAIN:-"${DEPLOY_REPO_OWNER}.github.io/${DEPLOY_REPO_NAME}"}
}

function _check_ca_env_CA_KEY_SPEC() {
    local message=""
    local upper=$(awk '{ print toupper($0) }' <<< $CA_KEY_SPEC)
    if [[ -z $CA_KEY_SPEC ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Error / Null"
    elif ! [[ $upper =~ ^(RSA-3072|RSA-4096|P-384)$ ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Unsupported key type: $upper"
    else
        _print_ok
    fi
    printf "CA_KEY_SPEC"
    _print_additional_line_info "${message:-$upper}"
}

function _check_ca_env_CA_YEARS() {
    local message=""
    if [[ -z $CA_YEARS ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Empty / Null"
    elif ! [[ $CA_YEARS =~ ^[0-9]+$ ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Not a number"
    else
        _print_ok
    fi
    printf "CA_YEARS"
    _print_additional_line_info "${message:-$CA_YEARS}"
}

function _check_ca_env_CA_SUBJECT() {
    local message=""
    if [[ -z $CA_SUBJECT ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Empty / Null"
    elif [[ "${CA_SUBJECT:0:1}" != "/" ]] && [[ "${CA_SUBJECT: -1}" != "/" ]]
    then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Must begin and end with '/'"
    elif [[ "${CA_SUBJECT:0:1}" != "/" ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Must begin with '/'"
    elif [[ "${CA_SUBJECT: -1}" != "/" ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Must end with '/'"
    else
        _print_ok
    fi
    printf "CA_SUBJECT"
    _print_additional_line_info "${message:-$CA_SUBJECT}"
}

function _check_ca_env_DEPLOY_APP_ID() {
    local message=""
    if [[ -z $DEPLOY_APP_ID ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Empty / Null"
    else
        _print_ok
    fi
    printf "DEPLOY_APP_ID"
    _print_additional_line_info "${message:-$DEPLOY_APP_ID}"
}

function _check_ca_env_DEPLOY_APP_KEY() {
    local message=""
    if [[ -z $DEPLOY_APP_KEY ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Empty / Null"
    elif [[ ! -f "${CADATAPATH}/secrets/${DEPLOY_APP_KEY}" ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="File not found"
    elif ! openssl pkey -text -noout -in "${CADATAPATH}/secrets/${DEPLOY_APP_KEY}" &> /dev/null
    then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Not a valid private key"
    else
        _print_ok
    fi
    printf "DEPLOY_APP_KEY"
    _print_additional_line_info "${message:-$DEPLOY_APP_KEY}"
}

function _check_ca_env_DEPLOY_REPO_OWNER() {
    local message=""
    if [[ -z $DEPLOY_REPO_OWNER ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Empty / Null"
    else
        _print_ok
    fi
    printf "DEPLOY_REPO_OWNER"
    _print_additional_line_info "${message:-$DEPLOY_REPO_OWNER}"
}

function _check_ca_env_DEPLOY_REPO_NAME() {
    local message=""
    if [[ -z $DEPLOY_REPO_NAME ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Empty / Null"
    else
        _print_ok
    fi
    printf "DEPLOY_REPO_NAME"
    _print_additional_line_info "${message:-$DEPLOY_REPO_NAME}"
}

function _check_ca_env_DEPLOY_REPO_BRANCH() {
    local message=""
    if [[ -z $DEPLOY_REPO_BRANCH ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Empty / Null"
    else
        _print_ok
    fi
    printf "DEPLOY_REPO_BRANCH"
    _print_additional_line_info "${message:-$DEPLOY_REPO_BRANCH}"
}

function _check_ca_env_DEPLOY_PAGES_CUSTOM_DOMAIN() {
    local message=""
    _print_ok
    printf "DEPLOY_PAGES_CUSTOM_DOMAIN"
    if [[ -z $DEPLOY_PAGES_CUSTOM_DOMAIN ]]; then
        message="Default: "
    else
        message="Custom: "
    fi
    message+="$(_get_ca_url)"
    _print_additional_line_info "$message"
}

function _check_ca_env_DEPLOY_AIA_FILE() {
    local message=""
    if [[ -z $DEPLOY_AIA_FILE ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Empty / Null"
    else
        _print_ok
    fi
    printf "DEPLOY_AIA_FILE"
    _print_additional_line_info "${message:-$DEPLOY_AIA_FILE}"
}

function _check_ca_env_DEPLOY_CDP_FILE() {
    local message=""
    if [[ -z $DEPLOY_CDP_FILE ]]; then
        _print_error
        CHECK_CA_ENV_ERROR=1
        message="Empty / Null"
    else
        _print_ok
    fi
    printf "DEPLOY_CDP_FILE"
    _print_additional_line_info "${message:-$DEPLOY_CDP_FILE}"
}

function _check_ca_env_finalize() {
    if [ "$CHECK_CA_ENV_ERROR" -ne 0 ]; then
        _print_error_dialog "Some values in ca.env are invalid!" \
            "Any variables marked with 'ERROR' did not pass validation" \
            "checks. Refer to the variable in 'ca.env' for documentation of" \
            "valid values."
        return 1
    else
        _print_info_dialog "ca.env validated"
        return 0
    fi
}

_print_header_dialog "Validating ca.env"

{
    CHECK_CA_ENV_ERROR=0

    _check_ca_env_CA_KEY_SPEC
    _check_ca_env_CA_YEARS
    _check_ca_env_CA_SUBJECT
    _check_ca_env_DEPLOY_APP_ID
    _check_ca_env_DEPLOY_APP_KEY
    _check_ca_env_DEPLOY_REPO_OWNER
    _check_ca_env_DEPLOY_REPO_NAME
    _check_ca_env_DEPLOY_REPO_BRANCH
    _check_ca_env_DEPLOY_PAGES_CUSTOM_DOMAIN
    _check_ca_env_DEPLOY_AIA_FILE
    _check_ca_env_DEPLOY_CDP_FILE

    _check_ca_env_finalize
}
_should_exit $?

################################################################################
# Verify Github App Access                                                     #
################################################################################

function _ghapp_verify_new_jwt_from_file() {
    local key_file=$1
    if [[ ! -f $key_file ]]; then
        _print_error_dialog "Key file not found" "$key_file" >&2
        return 1
    fi
    header_payload=$(_ghapp_get_jwt_header_payload)
    signature=$(
        openssl dgst -sha256 -sign "${key_file}" \
        <(echo -n "${header_payload}") | _b64enc
    )
    printf "${header_payload}"."${signature}"
    _print_ok_ln >&2
}

function _ghapp_verify_check_can_authorize() {
    curl -f -s -X GET -H "Authorization: Bearer $JWT" https://api.github.com/app \
    &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "Github App can not authenticate!" \
            "Is the 'DEPLOY_APP_ID' correct?" \
            "Is the 'DEPLOY_APP_KEY' valid for the App?" >&2
        return $rc
    fi
}

function _ghapp_verify_get_installation_info() {
    info=$(_ghapp_get_installation)
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
        printf $info
    else
        _print_error_dialog "Github App failed to get installation information" >&2
    fi
    return $rc
}

function _ghapp_verify_permissions() {
    local installation_info="$1"
    jq -e '.permissions | .contents == "write" and .pull_requests == "write"' \
    <<< $INSTALLATION_INFO &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "Github App must have 'contents:write' and" \
            "'pull_requests:write' permissions to publish files to the" \
            "repository." >&2
    fi
    return $rc
}

_print_header_dialog "Verifying Github App Access"

{
    _print_step_dialog "Generating Github App JWT"
    JWT=$(_ghapp_verify_new_jwt_from_file "${CADATAPATH}/secrets/${DEPLOY_APP_KEY}")
    _should_exit $?

    _print_step_dialog "Verifying that Github App is valid"
    _ghapp_verify_check_can_authorize
    _should_exit $?

    _print_step_dialog "Gathering Github App Installation Information"
    INSTALLATION_INFO=$(_ghapp_verify_get_installation_info)
    _should_exit $?

    _print_step_dialog "Verifying that Github App as correct permissions"
    _ghapp_verify_permissions $INSTALLATION_INFO
    _should_exit $?
}

_print_info_dialog "Github App access has been verified"

################################################################################
# Confirm CA Attributes and Deployment Environment                             #
################################################################################

function _get_start_date_readable() {
    date -d $(date +'%Y0101') +'%d %B %Y @ %H:%M:%S'
}

function _get_end_date_readable() {
    local YEARS=$1
    date -d "$(($(date +'%Y') + $YEARS))0101" +'%d %B %Y @ %H:%M:%S'
}

function _format_asset_url() {
    printf "http://%s/%s\n" \
        "${DEPLOY_PAGES_CUSTOM_DOMAIN:-"${DEPLOY_REPO_OWNER}.github.io/${DEPLOY_REPO_NAME}"}" \
        "$1"
}

export AIAURL=$(_format_asset_url $DEPLOY_AIA_FILE)
export CDPURL=$(_format_asset_url $DEPLOY_CDP_FILE)

readarray -t formatted_ca_subject < <(
    grep -oP '(([\w]+)=([\w ]+))' <<< $CA_SUBJECT | while read line; do
        sed 's/^/\\t/; s/=/:\\t/' <<< $line
    done
)

_print_header_dialog "Ready to initialize!"

_print_confirmation_dialog $GREEN \
    "Confirm CA Attributes and Deployment Environment!" \
    "Your new Root Certificate Authority (CA) is ready to be created." \
    "Subject:" \
    "${formatted_ca_subject[@]}" \
    "Key:\t$(awk '{print toupper($0)}' <<< $CA_KEY_SPEC)" \
    "Valid from:\t$(_get_start_date_readable)" \
    "Valid to:\t$(_get_end_date_readable $CA_YEARS)" \
    "AIA URL:\t$AIAURL" \
    "CDP URL:\t$CDPURL"

_should_exit $?

_print_info_dialog "CREATING"

################################################################################
# Initialize KDBX Databases                                                    #
################################################################################

KDBXPATH="${CADATAPATH}/kdbx"

KDBX_ROOTCA_NAME="root-ca"
KDBX_ROOTCA_PATH="${KDBXPATH}/${KDBX_ROOTCA_NAME}.kdbx"
KDBX_ROOTCA_KEYFILE="${KDBXPATH}/${KDBX_ROOTCA_NAME}.key"

KDBX_YKPIN_NAME="yk-pin"
KDBX_YKPIN_PATH="${KDBXPATH}/${KDBX_YKPIN_NAME}.kdbx"
KDBX_YKPIN_KEYFILE="${KDBXPATH}/${KDBX_YKPIN_NAME}.key"

function _create_keyfile() {
    local filepath=$1
    # Exponential arithmetic is used here instead of a bitwise operator because
    #   the left-shift breaks syntax highlighting. The highlighter thinks it's
    #   a heredoc.
    #   $(( 1 << 20 )) == $(( 1 *(2**20) ))
    head -c $(( 1 *(2**20) )) /dev/urandom > "${filepath}"
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error creating the keyfile!" >&2
    fi
    return $rc
}

function _create_kdbx() {
    local keyfile=$1
    local dbpath=$2
    keepassxc-cli db-create \
        --set-key-file="${keyfile}" \
        --decryption-time 1000 \
        "${dbpath}" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error creating the database!" >&2
    fi
    return $rc
}

function _add_kdbx_entries() {
    local rc=0
    local database=$1
    shift
    local keyfile=$1
    shift
    local add_entry_error=0
    for i in "$@"; do
        keepassxc-cli add --no-password --key-file \
            "${keyfile}" "${database}" "${i}" &> /dev/null
        rc=$?
        if [ "$rc" -eq 0 ]; then
            _print_ok >&2
        else
            _print_error >&2
        fi
        printf '%s\n' "$i" >&2
    done
    return $rc
}

_print_header_dialog "Creating Root CA Secret Databases"

_print_step_dialog "Creating 1MiB KeyFile for the ${KDBX_ROOTCA_NAME} database"
_create_keyfile $KDBX_ROOTCA_KEYFILE
_should_exit $?

_print_step_dialog "Creating '${KDBX_ROOTCA_NAME}.kdbx'"
_create_kdbx $KDBX_ROOTCA_KEYFILE $KDBX_ROOTCA_PATH
_should_exit $?

_print_step_dialog "Adding entries to ${KDBX_ROOTCA_NAME} database"
_add_kdbx_entries $KDBX_ROOTCA_PATH $KDBX_ROOTCA_KEYFILE \
    "github" "rootca" "yubikey"
_should_exit $?

_print_step_dialog "Creating 1MiB KeyFile for the ${KDBX_YKPIN_NAME} database"
_create_keyfile $KDBX_YKPIN_KEYFILE
_should_exit $?

_print_step_dialog "Creating '${KDBX_YKPIN_NAME}.kdbx'"
_create_kdbx $KDBX_YKPIN_KEYFILE $KDBX_YKPIN_PATH
_should_exit $?

_print_step_dialog "Adding entries to ${KDBX_YKPIN_NAME} database"
_add_kdbx_entries $KDBX_YKPIN_PATH $KDBX_YKPIN_KEYFILE "yubikey"
_should_exit $?

################################################################################
# Generate YubiKey Secrets                                                     #
################################################################################

export LC_CTYPE=C
KID_YK_MGMT=
KID_YK_PUK=
KID_YK_PIN=

function _new_hex_secret() {
    out=$(< /dev/urandom tr -d '[:lower:]' | tr -cd '[:xdigit:]' | head -c$1)
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
        echo -n $out
    else
        _print_error_dialog "There was an error generating a new hex secret" >&2
    fi
    return $rc
}

function _new_num_secret() {
    out=$(< /dev/urandom tr -cd '[:digit:]' | head -c$1)
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
        echo -n $out
    else
        _print_error_dialog "There was an error generating a YubiKey Management Key" >&2
    fi
    return $rc
}

function _new_yk_mgmt_key() {
    KID_YK_MGMT=$(_new_hex_secret 48 | keyctl padd user yk-mgmtkey $ROOTCA_KEYRING)
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error generating a YubiKey Management Key" >&2
    fi
    return $rc
}

function _new_yk_puk() {
    KID_YK_PUK=$(_new_num_secret 8 | keyctl padd user yk-puk $ROOTCA_KEYRING)
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error generating a YubiKey PIN Unlock Key" >&2
    fi
    return $rc
}

function _new_yk_pin() {
    KID_YK_PIN=$(_new_num_secret 6 | keyctl padd user yk-pin $ROOTCA_KEYRING)
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error generating a YubiKey PIN" >&2
    fi
    return $rc
}

function _set_yubikey_management_key() {
    yubico-piv-tool \
        --action=set-mgm-key \
        --new-key=$(keyctl pipe $KID_YK_MGMT) &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error installing the YubiKey Management Key" >&2
    fi
    return $rc
}

function _set_yubikey_puk() {
    yubico-piv-tool \
        --action=change-puk \
        --pin=12345678 \
        --key=$(keyctl pipe $KID_YK_MGMT) \
        --new-pin=$(keyctl pipe $KID_YK_PUK) &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error installing the YubiKey PIN Unlock Key" >&2
    fi
    return $rc
}

function _set_yubikey_pin() {
    yubico-piv-tool \
        --action=change-pin \
        --pin=123456 \
        --key=$(keyctl pipe $KID_YK_MGMT) \
        --new-pin=$(keyctl pipe $KID_YK_PIN) &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error installing the YubiKey PIN" >&2
    fi
    return $rc
}

function _add_kdbx_attachment_from_keyring() {
    local database=$1
    local keyfile=$2
    local entry=$3
    local name=$4
    local keyid=$5
    keepassxc-cli attachment-import --no-password --key-file "${keyfile}" \
        "${database}" "${entry}" "${name}" <(keyctl pipe $keyid) &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error storing the secret" >&2
    fi
    return $rc
}


_print_header_dialog "Generating and installing YubiKey secrets"

_print_step_dialog "Creating Root CA Keyring"
_create_keyring
_should_exit $?

_print_step_dialog "Generating YubiKey Management Key"
_new_yk_mgmt_key
_should_exit $?

_print_step_dialog "Generating YubiKey PIN Unlock Key"
_new_yk_puk
_should_exit $?

_print_step_dialog "Generating YubiKey PIN"
_new_yk_pin
_should_exit $?

_print_step_dialog "Installing YubiKey Management Key"
_set_yubikey_management_key
_should_exit $?

_print_step_dialog "Installing YubiKey PIN Unlock Key"
_set_yubikey_puk
_should_exit $?

_print_step_dialog "Installing YubiKey PIN"
_set_yubikey_pin
_should_exit $?

_print_step_dialog "Storing YubiKey Management Key in the '${KDBX_ROOTCA_NAME} database"
_add_kdbx_attachment_from_keyring "${KDBX_ROOTCA_PATH}" "${KDBX_ROOTCA_KEYFILE}" \
    "yubikey" "ManagementKey" "${KID_YK_MGMT}"
_should_exit $?

_print_step_dialog "Storing YubiKey PIN Unlock Key in the '${KDBX_ROOTCA_NAME} database"
_add_kdbx_attachment_from_keyring "${KDBX_ROOTCA_PATH}" "${KDBX_ROOTCA_KEYFILE}" \
    "yubikey" "PINUnlockKey" "${KID_YK_PUK}"
_should_exit $?

_print_step_dialog "Storing YubiKey PIN in the '${KDBX_ROOTCA_NAME} database"
_add_kdbx_attachment_from_keyring "${KDBX_ROOTCA_PATH}" "${KDBX_ROOTCA_KEYFILE}" \
    "yubikey" "PIN" "${KID_YK_PIN}"
_should_exit $?

_print_step_dialog "Storing YubiKey PIN in the '${KDBX_YKPIN_NAME} database"
_add_kdbx_attachment_from_keyring "${KDBX_YKPIN_PATH}" "${KDBX_YKPIN_KEYFILE}" \
    "yubikey" "PIN" "${KID_YK_PIN}"
_should_exit $?

################################################################################
# Create Required CA Files                                                     #
################################################################################

function _render_openssl_cnf_template() {
    envsubst '$AIAURL $CDPURL' \
    < "${CADATAPATH}/openssl.template.cnf" \
    > "${CADATAPATH}/openssl.cnf"
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error rendering the OpenSSL" \
            "configuration file template" >&2
    fi
    return $rc
}

function _generate_new_crl_serial() {
    echo 1000 > "${CADATAPATH}/db/ca.crl.serial"
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error creating the CRL serial file" >&2
    fi
    return $rc
}

function _init_ca_db() {
    touch "${CADATAPATH}/db/ca.db"
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error initializing the CA database" >&2
    fi
    return $rc
}

_print_header_dialog "Generating CA files"

_print_step_dialog "Generating Root CA Certificate Serial"
_new_hex_secret 40 > "${CADATAPATH}/db/ca.crt.serial"
_should_exit $?

_print_step_dialog "Generating Root CA CRL Serial"
_generate_new_crl_serial
_should_exit $?

_print_step_dialog "Creating Root CA database file"
_init_ca_db
_should_exit $?

_print_step_dialog "Generating OpenSSL Configuration from template"
_render_openssl_cnf_template
_should_exit $?

################################################################################
# Create CA                                                                    #
################################################################################

KEY_ALGO=$(awk '{print toupper($0)}' <<< "${CA_KEY_SPEC%-*}")
_should_exit $?
KEY_SIZE="${CA_KEY_SPEC#*-}"
_should_exit $?
KID_CA_PVTKEY=""
KID_CA_PUBKEY=""
KID_CA_CSR=""

function _compile_openssl_pkey_cmd() {
    local cmd=("openssl" "genpkey")
    case $KEY_ALGO in
        "P")
            cmd+=(
                "-algorithm ec"
                "-pkeyopt ec_paramgen_curve:${KEY_ALGO}-${KEY_SIZE}"
                "-pkeyopt ec_param_enc:named_curve"
            )
        ;;
        "RSA")
            cmd+=(
                "-algorithm rsa"
                "-pkeyopt rsa_keygen_bits:${KEY_SIZE}"
            )
        ;;
        *)
            _print_error_dialog "There was an unexpected error!" \
                "For some reason, an unsupported key algorithm passed" \
                "previous validation checks." "Aborting..."
            exit 1
        ;;
    esac
    echo -n "${cmd[@]}"
}

function _generate_ca_private_key() {
    KID_CA_PVTKEY=$(
        eval $(_compile_openssl_pkey_cmd) | \
        keyctl padd user ca-privatekey $ROOTCA_KEYRING
    )
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error generating the CA private key" >&2
    fi
    return $rc
}

function _import_yubikey_ca_private_key() {
    yubico-piv-tool \
        --action=import-key \
        --slot=9a \
        --key-format=PEM \
        --key=$(keyctl pipe $KID_YK_MGMT) \
        --input=<(keyctl pipe $KID_CA_PVTKEY) &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error importing the private key" \
            "into the YubiKey slot 9A." >&2
    fi
    return $rc
}

function _import_yubikey_ca_certificate() {
    yubico-piv-tool \
        --action=import-certificate \
        --slot=9a \
        --key=$(keyctl pipe $KID_YK_MGMT) \
        --input="${CADATAPATH}/ca/ca.crt.pem" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error importing the certificate" \
            "into the YubiKey slot 9A." >&2
    fi
    return $rc
}

function _generate_public_key() {
    KID_CA_PUBKEY=$(
        openssl pkey -pubout -in <(keyctl pipe $KID_CA_PVTKEY) | \
        keyctl padd user ca-publickey $ROOTCA_KEYRING
    )
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error generating the CA public key" >&2
    fi
    return $rc
}

function _generate_ca_csr() {
    yubico-piv-tool \
        --action=verify-pin \
        --action=request-certificate \
        --slot=9a \
        --subject="${CA_SUBJECT}" \
        --pin=$(keyctl pipe $KID_YK_PIN) \
        --input=<(keyctl pipe $KID_CA_PUBKEY) \
        --output="${CADATAPATH}/ca/ca.csr.pem" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error generating the CA CSR" >&2
    fi
    return $rc
}

function _add_kdbx_attachment_from_file() {
    local database=$1
    local keyfile=$2
    local entry=$3
    local name=$4
    local file=$5
    keepassxc-cli attachment-import --no-password --key-file "${keyfile}" \
        "${database}" "${entry}" "${name}" "${file}" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error storing the secret" >&2
    fi
    return $rc
}

function _get_start_date() {
    date -d $(date +'%Y0101') +'%Y%m%d%H%M%SZ'
}

function _get_end_date() {
    local YEARS=$1
    date -d "$(($(date +'%Y') + $YEARS))0101" +'%Y%m%d%H%M%SZ'
}

function _self_sign_root_ca() {
    openssl ca \
        -config "${CADATAPATH}/openssl.cnf" \
        -engine pkcs11 \
        -keyform engine \
        -selfsign \
        -batch \
        -notext \
        -passin file:<(keyctl pipe $KID_YK_PIN) \
        -extensions root_ca_ext \
        -startdate $(_get_start_date) \
        -enddate $(_get_end_date $CA_YEARS) \
        -in "${CADATAPATH}/ca/ca.csr.pem" \
        -out "${CADATAPATH}/ca/ca.crt.pem" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error self-signing the Root CA" >&2
    fi
    return $rc
}

function _convert_ca_cert_to_der() {
    openssl x509 \
        -outform der \
        -in "${CADATAPATH}/ca/ca.crt.pem" \
        -out "${CADATAPATH}/ca/ca.crt" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error converting the certificate format" >&2
    fi
    return $rc
}

_print_header_dialog "Creating Certificate Authority"

_print_step_dialog "Generating CA Private key"
_generate_ca_private_key
_should_exit $?

_print_step_dialog "Storing CA Private Key in the '${KDBX_ROOTCA_NAME} database"
_add_kdbx_attachment_from_keyring "${KDBX_ROOTCA_PATH}" "${KDBX_ROOTCA_KEYFILE}" \
    "rootca" "ca.key.pem" "${KID_CA_PVTKEY}"
_should_exit $?

_print_step_dialog "Import CA Private Key to Yubikey"
_import_yubikey_ca_private_key
_should_exit $?

_print_step_dialog "Generating CA Public Key"
_generate_public_key
_should_exit $?

_print_step_dialog "Storing CA Public Key in the '${KDBX_ROOTCA_NAME} database"
_add_kdbx_attachment_from_keyring "${KDBX_ROOTCA_PATH}" "${KDBX_ROOTCA_KEYFILE}" \
    "rootca" "ca.pub.pem" "${KID_CA_PUBKEY}"
_should_exit $?

_print_step_dialog "Generating CA Certificate Signing Request (CSR)"
_generate_ca_csr
_should_exit $?

_print_step_dialog "Storing CA CSR in the '${KDBX_ROOTCA_NAME} database"
_add_kdbx_attachment_from_file "${KDBX_ROOTCA_PATH}" "${KDBX_ROOTCA_KEYFILE}" \
    "rootca" "ca.csr.pem" "${CADATAPATH}/ca/ca.csr.pem"

_print_step_dialog "Self-Signing the Root CA"
_self_sign_root_ca
_should_exit $?

_print_step_dialog "Storing CA Certificate in the '${KDBX_ROOTCA_NAME} database"
_add_kdbx_attachment_from_file "${KDBX_ROOTCA_PATH}" "${KDBX_ROOTCA_KEYFILE}" \
    "rootca" "ca.crt.pem" "${CADATAPATH}/ca/ca.crt.pem"
_should_exit $?

_print_step_dialog "Importing CA Certificate to YubiKey"
_import_yubikey_ca_certificate
_should_exit $?

_print_step_dialog "Converting PEM Certificate to DER format"
_convert_ca_cert_to_der
_should_exit $?

_print_step_dialog "Create initial Certificate Revocation List (CRL)"
_generate_crl
_should_exit $?

_print_step_dialog "Convert initial CRL to DER format"
_convert_crl_to_der
_should_exit $?

_print_info_dialog "Root CA Created!"

################################################################################
# Prepare Github App                                                           #
################################################################################

function _import_yubikey_app_private_key() {
    yubico-piv-tool \
        --action=import-key \
        --slot=9d \
        --key-format=PEM \
        --key=$(keyctl pipe $KID_YK_MGMT) \
        --input="${CADATAPATH}/secrets/${DEPLOY_APP_KEY}" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error importing the private key" \
            "into the YubiKey slot 9D." >&2
    fi
    return $rc
}

function _generate_yubikey_app_dummy_certificate() {
    openssl x509 \
        -new \
        -subj "/O=Github/OU=${DEPLOY_APP_ID}/CN=${DEPLOY_REPO_OWNER} Root CA Deployment" \
        -days "$(( $CA_YEARS * 365 ))" \
        -key "${CADATAPATH}/secrets/${DEPLOY_APP_KEY}" \
        -out "${CADATAPATH}/secrets/app_dummy.crt" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error generating the Github App's" \
            "dummy certificate" >&2
    fi
    return $rc
}

function _import_yubikey_app_certificate() {
    yubico-piv-tool \
        --action=import-certificate \
        --slot=9d \
        --key=$(keyctl pipe $KID_YK_MGMT) \
        --input="${CADATAPATH}/secrets/app_dummy.crt" &> /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error importing the certificate" \
            "into the YubiKey slot 9D." >&2
    fi
    return $rc
}

_print_header_dialog "Installing Github App to Yubikey"

_print_step_dialog "Installing App Private Key to YubiKey"
_import_yubikey_app_private_key
_should_exit $?

_print_step_dialog "Storing Github App Private Key in the '${KDBX_ROOTCA_NAME} database"
_add_kdbx_attachment_from_file "${KDBX_ROOTCA_PATH}" "${KDBX_ROOTCA_KEYFILE}" \
    "github" "AppKey" "${CADATAPATH}/secrets/${DEPLOY_APP_KEY}"
_should_exit $?

_print_step_dialog "Generate a Github App dummy certificate"
_print_info_dialog "This certificate serves no functional purpose." \
    "It only exists to fully populate the YubiKey's PIV slot and show that" \
    "the slot is occupied when viewing YubiKey PIV information."
_generate_yubikey_app_dummy_certificate
_should_exit $?

_print_step_dialog "Storing Github App Dummy Certificate in the '${KDBX_ROOTCA_NAME} database"
_add_kdbx_attachment_from_file "${KDBX_ROOTCA_PATH}" "${KDBX_ROOTCA_KEYFILE}" \
    "github" "AppCert" "${CADATAPATH}/secrets/app_dummy.crt"
_should_exit $?

_print_step_dialog "Installing App Dummy Certificate to YubiKey"
_import_yubikey_app_certificate
_should_exit $?

_print_info_dialog "Github App installed to YubiKey"

################################################################################
# Cleanup                                                                      #
################################################################################

_print_header_dialog "Cleanup"

_destroy_keyring

################################################################################
# DONE!!!                                                                      #
################################################################################

_print_complete "Your new Root Certificate Authority is now initialized!" \
    "" \
    "IMPORTANT!: The databases stored in the 'kdbx' directory are NOT in a" \
    "secure state! To secure them, you MUST open them in the KeePassXC GUI" \
    "application and modify the encryption settings under 'Database Security'." \
    "" \
    "Ensure that you are using the KDBX 4 format so that you have access to" \
    "modern encryption functions. Adjust the encryption settings to suite your" \
    "desired security level." \
    "" \
    "I recommend that you use the 'Argon2id' KDF with a VERY large amount of" \
    "memory for the '${KDBX_ROOTCA_NAME}' database as it should not be needed" \
    "unless you are performing disaster recovery. I would recommend a _minimum_" \
    "of 8192 MiB (1 GiB). Using a high amout of memory will likely necessitate" \
    "a low number of Iterations (ie. 1-2)." \
    "" \
    "The '${KDBX_YKPIN_NAME}' database should be configured more for speed" \
    "since this is what will be used to perform 'day-to-day' CA operations." \
    "" \
    "Finally, set an INCREDIBLY strong password for the '${KDBX_ROOTCA_NAME}'" \
    "database, and a strong but memorable one for the '${KDBX_YKPIN_NAME}'" \
    "database." \
    "" \
    "When this is done, remove the generated keyfile credential from both and" \
    "save. Store the '${KDBX_ROOTCA_NAME}' database some place secure!" \
    "" \
    "Use the 'archive' script to package your new Root CA into a portable format."