#!/bin/bash

################################################################################
# Setup Script Environment                                                     #
################################################################################

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

source "${SCRIPT_DIR}/_common.sh"

export CADATAPATH=$(realpath "${SCRIPT_DIR}/../")

################################################################################
# Parse Script Arguments                                                       #
################################################################################

function _usage() {
    cat <<EOF
usage: update_archive_scripts.sh [ -h ] -f <FILE>

ARGUMENTS:
    -f, --file  Archive file, uncompressed tar
    -h, --help  Show this dialog
EOF
}

if [ $# -eq 0 ]; then
    _usage
    exit 1
fi

declare FILE
while [ "$#" -ne 0 ]; do
    case $1 in
        "-f" | "--file")
            shift
            FILE=$1
        ;;
        "-h" | "--help")
            _usage
            exit 0
        ;;
        *)
            _print_error
            printf "unknown argument: %s\n" "$1"
            _usage
            exit 1
        ;;
    esac
    shift
done

if [ -z $FILE ]; then
    _print_error
    echo "file must be specified"
    _usage
    exit 1
fi

FILE=$(realpath $FILE 2>&1)
rc=$?
if [ $rc -ne 0 ]; then
    _print_error
    echo ${FILE#"realpath: "}
    exit $rc
fi

FILETYPE=$(file -E --mime-type -b $FILE)
rc=$?
if [ $rc -ne 0 ]; then
    _print_error
    echo ${FILETYPE#"ERROR: "}
    exit $rc
fi

case $FILETYPE in
    "application/x-tar");;
    *)
        _print_error
        printf "unknown or unsupported file type: %s\n" "$FILETYPE"
        exit 1
    ;;
esac

################################################################################
# Setup Script Environment                                                     #
################################################################################

_print_header_dialog "Replacing scripts in archive"

_print_step_dialog "Creating temporary directory"
mkdir "${CADATAPATH}/.temp"
rc=$?
if [ $rc -eq 0 ]; then
    _print_ok_ln
else
    _print_error
    printf "there was an error creating the temporary directory\n"
    exit $rc
fi

_print_step_dialog "Unpacking archive"
tar -x -C "${CADATAPATH}/.temp" -f $FILE
rc=$?
if [ $rc -eq 0 ]; then
    _print_ok_ln
else
    _print_error
    printf "there was an error unpacking the archive\ncode: %s" "$rc"
    exit $rc
fi

_print_step_dialog "Removing old scripts"
find "${CADATAPATH}/.temp/scripts/" -type f -delete
rc=$?
if [ $rc -eq 0 ]; then
    _print_ok_ln
else
    _print_error
    printf "there was an error removing old scripts\ncode: %s" "$rc"
    exit $rc
fi

_print_step_dialog "Copying new scripts"
cp \
"${CADATAPATH}/scripts/_common.sh" \
"${CADATAPATH}/scripts/archive.sh" \
"${CADATAPATH}/scripts/deploy.sh" \
"${CADATAPATH}/scripts/revoke.sh" \
"${CADATAPATH}/scripts/sign.sh" \
"${CADATAPATH}/scripts/update_crl.sh" \
"${CADATAPATH}/.temp/scripts/"
rc=$?
if [ $rc -eq 0 ]; then
    _print_ok_ln
else
    _print_error
    printf "there was an error copying new scripts\ncode: %s" "$rc"
    exit $rc
fi

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
FILENAME="rootca_${TIMESTAMP}.tar"
FILEPATH="${CADATAPATH}/${FILENAME}"

_print_step_dialog "Repacking CA archive"
tar -c -C "${CADATAPATH}/.temp/" -f $FILEPATH .
rc=$?
if [ $rc -eq 0 ]; then
    _print_ok_ln
else
    _print_error
    printf "there was an error repacking the archive\ncode: %s" "$rc"
    exit $rc
fi

_print_step_dialog "Removing temporary directory"
rm -rf "${CADATAPATH}/.temp"
rc=$?
if [ $rc -eq 0 ]; then
    _print_ok_ln
else
    _print_error
    printf "there was an error removing the temporary directory\ncode: %s" "$rc"
    exit $rc
fi

_print_complete "Archive scripts upgraded" \
    "new archive file is '${FILEPATH}'"
