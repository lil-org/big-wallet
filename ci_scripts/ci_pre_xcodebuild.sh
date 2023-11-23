#!/bin/bash
set -e

if [ "$CI_PRODUCT_PLATFORM" = 'macOS' ] && [ "$CI_XCODEBUILD_ACTION" = 'build-for-testing' ]; then
    sed -i'~' 's/ENABLE_HARDENED_RUNTIME = YES;/ENABLE_HARDENED_RUNTIME = NO;/g' \
        "$CI_PROJECT_FILE_PATH/project.pbxproj"
fi
