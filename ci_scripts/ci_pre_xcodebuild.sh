#!/bin/bash
set -e

echo "CI_PRODUCT_PLATFORM: $CI_PRODUCT_PLATFORM"
echo "CI_XCODEBUILD_ACTION: $CI_XCODEBUILD_ACTION"
echo "CI_PRIMARY_REPOSITORY_PATH: $CI_PRIMARY_REPOSITORY_PATH"
echo "CI_XCODE_PROJECT: $CI_XCODE_PROJECT"

if [ "$CI_PRODUCT_PLATFORM" = 'macOS' ] && [ "$CI_XCODEBUILD_ACTION" = 'build-for-testing' ]; then
    filePath="$CI_PRIMARY_REPOSITORY_PATH/Tokenary.xcodeproj/project.pbxproj"
    echo "File path: $filePath"
    
    if [ -f "$filePath" ]; then
        echo "Modifying project.pbxproj"
        sed -i'~' 's/ENABLE_HARDENED_RUNTIME = YES;/ENABLE_HARDENED_RUNTIME = NO;/g' "$filePath"
    else
        echo "Error: File not found"
        exit 1
    fi
else
    echo "Conditions not met for script execution"
fi
