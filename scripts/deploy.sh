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
# Parse Script Arguments                                                       #
################################################################################

function _usage() {
    cat <<EOF
usage: deploy.sh [ARGUMENTS]

ARGUMENTS:
    -cert   Deploy CA Certificate
    -crl    Deploy CRL
    -all    Deploy CA Certificate and CRL
EOF
}

if [ $# -eq 0 ]; then
    _usage
    exit 1
fi

A_CRT=0
A_CRL=0
while [ "$#" -ne 0 ]; do
    case $1 in
        "-cert")
            A_CRT=1
        ;;
        "-crl")
            A_CRL=1
        ;;
        "-all")
            A_CRT=1
            A_CRL=1
        ;;
        *)
            _print_error_dialog "Unknown argument '$1'"
            exit 1
        ;;
    esac
    shift
done

################################################################################
# Check Required Commands                                                      #
################################################################################

_print_header_dialog "Checking for required commands and components"

{
    CHECK_COMMAND_ERROR=0

    _check_command "openssl"                command -v openssl
    _check_command "openssl-pkcs11 engine"  openssl engine -t pkcs11
    _check_command "keyutils (keyctl)"      command -v keyctl
    _check_command "jq"                     command -v jq
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
# Deploy                                                                       #
################################################################################

function _ghapp_new_jwt() {
    header_payload=$(_ghapp_get_jwt_header_payload)
    signature=$(
        OPENSSL_CONF="${CADATAPATH}/pkcs11.cnf" \
        openssl dgst \
        -engine pkcs11 \
        -keyform engine \
        -sha256 \
        -sign "pkcs11:id=%03;type=private" \
        -passin file:<(keyctl pipe $KID_YK_PIN) \
        <(printf $header_payload) | _b64enc
    )
    printf "${header_payload}.${signature}"
    _print_ok_ln >&2
}

function _ghapp_get_access_token() {
    is_ok=0
    installation=$(_ghapp_get_installation)
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error getting the installation" >&2
    fi
    id=$(jq -r '.id' <<< $installation)
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error getting the installation id" >&2
    fi
    req=$(
        curl -f -s -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $JWT" \
        "https://api.github.com/app/installations/${id}/access_tokens"
    )
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error requesting an access token" >&2
    fi
    jq -r '.token' <<< $req
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error parsing the installation id" >&2
    fi
    if [ $is_ok -ne 0 ]; then
        _print_ok_ln >&2
    fi
}

function _ghapp_check_file_exists() {
    code=$(
        curl -f -s -o /dev/null -w "%{http_code}" -X GET \
        -H "Authorization: token $ACCESS_TOKEN" \
        "https://api.github.com/repos/${DEPLOY_REPO}/contents/${1}?ref=$DEPLOY_REPO_BRANCH"
    )
    rc=$?
    if [ $rc -eq 0 ] || [ $rc -eq 22 ]; then
        _print_ok >&2
    else
        _print_error >&2
    fi
    printf "$1" >&2
    echo $code
    return $rc
}

function _should_exit_check_file() {
    local rc=$1
    if [ $rc -ne 0 ] && [ $rc -ne 22 ]; then
        if [[ -n $ROOTCA_KEYRING ]]; then
            _destroy_keyring
        fi
        exit $rc
    fi
}

function _ghapp_get_head_sha() {
    is_ok=0
    req=$(
        curl -f -s -X GET \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: token $ACCESS_TOKEN" \
        "https://api.github.com/repos/${DEPLOY_REPO}/git/ref/heads/${DEPLOY_REPO_BRANCH}"
    )
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error getting the HEAD SHA of the" \
            "target branch" >&2
    fi
    jq -r '.object.sha' <<< $req
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error getting the HEAD SHA" >&2
    fi
    if [ $is_ok -ne 0 ]; then
        _print_ok_ln >&2
    fi
}

function _ghapp_get_slug() {
    is_ok=0
    req=$(
        curl -f -s -X GET \
        -H "Authorization: Bearer $JWT" \
        https://api.github.com/app
    )
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error getting the Github App's SLUG" \
            "name" >&2
    fi
    jq -r '.slug' <<< $req
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error parsing the Github App's SLUG" \
            "name" >&2
    fi
    if [ $is_ok -ne 0 ]; then
        _print_ok_ln >&2
    fi
}

function _ghapp_create_branch() {
    req=$(
        curl -f -s -w "%{http_code}" -X POST \
        -H "Authorization: token $ACCESS_TOKEN" \
        https://api.github.com/repos/${DEPLOY_REPO}/git/refs \
        -d "{\"ref\":\"refs/heads/$PR_BRANCH\",\"sha\":\"$HEAD_SHA\"}"
    )
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error creating branch" \
            "Response: $req" \
            "Reference: https://docs.github.com/en/rest/git/refs#create-a-reference" \
            >&2
    fi
    return $rc
}

function _ghapp_replace_file() {
    is_ok=0
    file=$(
        curl -f -s -X GET \
        -H "Authorization: token $ACCESS_TOKEN" \
        "https://api.github.com/repos/${DEPLOY_REPO}/contents/${2}?ref=$PR_BRANCH"
    )
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error getting remote file" \
            "information for '${2}'" >&2
    fi
    sha=$(jq -r '.sha' <<< $file)
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error parsing the SHA for '${2}'" >&2
    fi
    content=$(base64 -w0 $1)
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error encoding '${1}'" >&2
    fi
    curl -f -s -X PUT \
    -H "Authorization: token $ACCESS_TOKEN" \
    "https://api.github.com/repos/${DEPLOY_REPO}/contents/${2}" \
    -d "{\"message\":\"${3}\",\"branch\":\"${PR_BRANCH}\",\"content\":\"${content}\",\"sha\":\"${sha}\"}" \
    > /dev/null
    if [ $? -eq 0 ]; then
        is_ok=1
    fi
    if [ $is_ok -ne 0 ]; then
        _print_ok_ln >&2
    fi
}

function _ghapp_create_file() {
    is_ok=0
    content=$(base64 -w0 $1)
    if [ $? -eq 0 ]; then
        is_ok=1
    else
        _print_error_dialog "There was an error encoding '${1}'" >&2
    fi
    curl -f -s -X PUT \
    -H "Authorization: token $ACCESS_TOKEN" \
    "https://api.github.com/repos/${DEPLOY_REPO}/contents/${2}" \
    -d "{\"message\":\"${3}\",\"branch\":\"${PR_BRANCH}\",\"content\":\"${content}\"}" \
    > /dev/null
    if [ $? -eq 0 ]; then
        is_ok=1
    fi
    if [ $is_ok -ne 0 ]; then
        _print_ok_ln >&2
    fi
}

function _ghapp_create_pull_request() {
    curl -f -s -X POST \
    -H "Authorization: token $ACCESS_TOKEN" \
    "https://api.github.com/repos/${DEPLOY_REPO}/pulls" \
    -d "{\"title\":\"${PR_TITLE}\",\"body\":\"${PR_BODY}\",\"head\":\"${PR_BRANCH}\",\"base\":\"${DEPLOY_REPO_BRANCH}\"}" \
    > /dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        _print_ok_ln >&2
    else
        _print_error_dialog "There was an error creating the pull request" >&2
    fi
    return $rc
}

_print_header_dialog "Deploy Assets"

{

_print_step_dialog "Generate JWT"
JWT=$(_ghapp_new_jwt)
_should_exit $?

_print_step_dialog "Get Access Token"
ACCESS_TOKEN=$(_ghapp_get_access_token)
_should_exit $?

_print_step_dialog "Checking for existing files in remote"
DEPLOY_REPO="${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}"

declare CRT_STATUS CRL_STATUS SHOULD_EXIT=0
if [ $A_CRT -ne 0 ]; then
    CRT_STATUS=$(_ghapp_check_file_exists $DEPLOY_AIA_FILE)
    _should_exit_check_file $?
    if [ $CRT_STATUS -eq 404 ]; then
        _print_info_dialog "Uploading new CA certificate"
    elif [ $CRT_STATUS -eq 200 ]; then
        _print_confirmation_dialog $RED \
            "Certificate exists in remote!" \
            "" \
            "A certificate with the same file name exists on the remote" \
            "repository. IT WILL BE OVERWRITTEN!" \
            "" \
            "If you are replacing the old CA, it is a best-practice to" \
            "leave it in place, and deploy the new CA under a different name." \
            "If the old CA key was compromised, revoke it. If not, wait to" \
            "revoke it until all descending clients are rotated to the new CA." \
            "" \
            "If the CA private key, subject, issuer, or serial number have" \
            "changed in the new certificate, THIS WILL BREAK ALL DESCENDING"\
            "CERTIFICATES!" \
            "" \
            "ARE YOU ABSOLUTELY SURE THIS IS WHAT YOU WANT TO DO?"
        if [ $? -ne 0 ]; then
            exit 0
        else
            _print_info_dialog "Replacing existing CA certificate"
        fi
    else
        _print_error_dialog "There was an unknown error accesing the remote" \
            "repository. Do you have access?"
        exit 1
    fi
fi

if [ $A_CRL -ne 0 ]; then
    CRL_STATUS=$(_ghapp_check_file_exists $DEPLOY_CDP_FILE)
    _should_exit_check_file $?
    if [ $CRL_STATUS -eq 404 ]; then
        _print_info_dialog "Uploading new CRL"
    elif [ $CRL_STATUS -eq 200 ]; then
        _print_info_dialog "Replacing existing CRL"
    else
        _print_error_dialog "There was an unknown error accesing the remote" \
            "repository. Do you have access?"
        exit 1
    fi
fi

_print_step_dialog "Getting Github App Info"
PR_BRANCH=$(_ghapp_get_slug)
_should_exit $?

_print_step_dialog "Set Pull Request Information"
declare PR_TITLE PR_BODY
if [ $A_CRT -ne 0 ] && [ $A_CRL -ne 0 ]; then
    if [ $CRT_STATUS -eq 200 ] && [ $CRL_STATUS -eq 200 ]; then
        PR_TITLE="[DEPLOY]: Update CA Certificate and CRL"
        PR_BODY="Update existing CA Certificate and Certificate Revocation List (CRL)."
        PR_BRANCH="${PR_BRANCH}/update-crt-crl"
    elif [ $CRT_STATUS -eq 200 ] && [ $CRL_STATUS -eq 404 ]; then
        PR_TITLE="[DEPLOY]: Update CA Certificate and Install CRL"
        PR_BODY="Update existing CA Certificate and install new Certificate Revocation List (CRL)."
        PR_BRANCH="${PR_BRANCH}/update-crt-install-crl"
    elif [ $CRT_STATUS -eq 404 ] && [ $CRL_STATUS -eq 200 ]; then
        # No idea why this option would ever be used, but it's here just in case...
        PR_TITLE="[DEPLOY]: Install New CA Certificate and Update CRL"
        PR_BODY="Install new CA Certificate and Update Certificate Revocation List (CRL)."
        PR_BRANCH="${PR_BRANCH}/install-crt-update-crl"
    elif [ $CRT_STATUS -eq 404 ] && [ $CRL_STATUS -eq 404 ]; then
        PR_TITLE="[DEPLOY]: Install New CA Certificate and CRL"
        PR_BODY="Install new CA Certificate and Certificate Revocation List (CRL)."
        PR_BRANCH="${PR_BRANCH}/install-crt-crl"
    fi
elif [ $A_CRT -ne 0 ] && [ $A_CRL -eq 0 ]; then
    if [ $CRT_STATUS -eq 200 ]; then
        PR_TITLE="[DEPLOY]: Update CA Certificate"
        PR_BODY="Update existing CA Certificate."
        PR_BRANCH="${PR_BRANCH}/update-crt"
    elif [ $CRT_STATUS -eq 404 ]; then
        PR_TITLE="[DEPLOY]: Install CA Certificate"
        PR_BODY="Install new CA Certificate."
        PR_BRANCH="${PR_BRANCH}/install-crt"
    fi
elif [ $A_CRT -eq 0 ] && [ $A_CRL -ne 0 ]; then
    if [ $CRL_STATUS -eq 200 ]; then
        PR_TITLE="[DEPLOY]: Update CRL"
        PR_BODY="Update existing Certificate Revocation List (CRL)."
        PR_BRANCH="${PR_BRANCH}/update-crl"
    elif [ $CRL_STATUS -eq 404 ]; then
        PR_TITLE="[DEPLOY]: Install CRL"
        PR_BODY="Install new Certificate Revocation List (CRL)."
        PR_BRANCH="${PR_BRANCH}/install-crl"
    fi
fi
_print_ok_ln

_print_step_dialog "Create Deploy Branch"
HEAD_SHA=$(_ghapp_get_head_sha)
_should_exit $?

_ghapp_create_branch
_should_exit $?

if [ $A_CRT -ne 0 ]; then
    if [ $CRT_STATUS == 200 ]; then
        _print_step_dialog "Updating Root CA in remote branch"
        _ghapp_replace_file "${CADATAPATH}/ca/ca.crt" "${DEPLOY_AIA_FILE}" \
            "update root certificate"
        _should_exit $?
    else
        _print_step_dialog "Creating Root CA in remote branch"
        _ghapp_create_file "${CADATAPATH}/ca/ca.crt" "${DEPLOY_AIA_FILE}" \
            "create root certificate"
        _should_exit $?
    fi
fi

if [ $A_CRL -ne 0 ]; then
    if [ $CRL_STATUS == 200 ]; then
        _print_step_dialog "Updating CRL in remote branch"
        _ghapp_replace_file "${CADATAPATH}/crl/ca.crl" "${DEPLOY_CDP_FILE}" \
            "update certificate revocation list"
        _should_exit $?
    else
        _print_step_dialog "Creating CRL in remote branch"
        _ghapp_create_file "${CADATAPATH}/crl/ca.crl" "${DEPLOY_CDP_FILE}" \
            "create certiicate revocation list"
        _should_exit $?
    fi
fi

_print_step_dialog "Creating Pull Request"
_ghapp_create_pull_request

}

################################################################################
# Cleanup                                                                      #
################################################################################

_print_header_dialog "Cleanup"

_destroy_keyring
_print_ok_ln
