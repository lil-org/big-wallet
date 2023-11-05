#!/bin/bash
set -e # Any subsequent(*) commands which fail will cause the shell script to exit immediately

PLIST_PATH="shared.plist"

if [ -z "${MY_VARIABLE}" ]; then
    echo "Error: The MY_VARIABLE environment variable is not set or empty."
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :MYVARIABLE ${MY_VARIABLE}" "${PLIST_PATH}"

echo "MY_VARIABLE has been written to ${PLIST_PATH}"

exit 0
