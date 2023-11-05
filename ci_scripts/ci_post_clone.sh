#!/bin/bash
set -e # Any subsequent(*) commands which fail will cause the shell script to exit immediately

PLIST_PATH="shared.plist"

if [ -z "${INFURA_KEY}" ]; then
    echo "Error: The INFURA_KEY environment variable is not set or empty."
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :InfuraKey ${INFURA_KEY}" "${PLIST_PATH}"

echo "INFURA_KEY has been written to ${PLIST_PATH}"

exit 0
