#!/bin/sh
set -eu
set +x

safari_resources="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
safari_output="$safari_resources/SafariVMRun.json"
case "$safari_resources" in /*) ;; *) echo 'error: Safari fixture resource path must be absolute' >&2; exit 1 ;; esac
case "${BW_SAFARI_VM_TESTING:-NO}" in YES|NO) ;; *) echo 'error: invalid Safari VM build mode' >&2; exit 1 ;; esac
safari_compiled=NO
case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in *' BW_SAFARI_VM_TESTING '*) safari_compiled=YES ;; esac
[ "$safari_compiled" = "${BW_SAFARI_VM_TESTING:-NO}" ] || {
    echo 'error: Safari VM compilation and resource modes must agree' >&2
    exit 1
}
if [ "$safari_compiled" = NO ]; then
    /bin/rm -f "$safari_output"
    if [ -f "$safari_resources/popup.js" ]; then
        /usr/bin/python3 "${SRCROOT:?}/Scripts/safari/instrument_popup.py" \
            "$SRCROOT/Safari Shared/Resources/popup.js" "$safari_resources/popup.js" ordinary
    fi
    if [ -f "$safari_resources/content.js" ]; then
        /usr/bin/python3 "${SRCROOT:?}/Scripts/safari/instrument_content.py" \
            "$SRCROOT/Safari Shared/Resources/content.js" "$safari_resources/content.js" ordinary
    fi
    if [ -f "$safari_resources/service_worker.js" ]; then
        /usr/bin/python3 "${SRCROOT:?}/Scripts/safari/instrument_worker.py" \
            "$SRCROOT/Safari Shared/Resources/service_worker.js" "$safari_resources/service_worker.js" ordinary
    fi
    exit 0
fi
[ "${ACTION:-build}" = build ] && [ "${DEPLOYMENT_LOCATION:-NO}" = NO ] && [ -z "${ARCHIVE_PATH:-}" ] || {
    echo 'error: Safari VM products cannot be archived or installed for distribution' >&2
    exit 1
}
. "${SRCROOT:?}/Scripts/vm/guest_session.sh"
test_vm_require_guest_session
/usr/bin/python3 "${SRCROOT}/Scripts/safari/verify_configuration.py" "${BW_SAFARI_VM_CONFIGURATION:?}" "${BW_TEST_VM_RUN_ID:?}"
/bin/mkdir -p "$safari_resources"
/bin/cp "$BW_SAFARI_VM_CONFIGURATION" "$safari_output"
if [ -f "$safari_resources/popup.js" ]; then
    /usr/bin/python3 "$SRCROOT/Scripts/safari/instrument_popup.py" \
        "$SRCROOT/Safari Shared/Resources/popup.js" "$safari_resources/popup.js" fixture
fi
if [ -f "$safari_resources/content.js" ]; then
    /usr/bin/python3 "$SRCROOT/Scripts/safari/instrument_content.py" \
        "$SRCROOT/Safari Shared/Resources/content.js" "$safari_resources/content.js" fixture
fi
if [ -f "$safari_resources/service_worker.js" ]; then
    /usr/bin/python3 "$SRCROOT/Scripts/safari/instrument_worker.py" \
        "$SRCROOT/Safari Shared/Resources/service_worker.js" "$safari_resources/service_worker.js" fixture
fi
