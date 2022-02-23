#!/usr/bin/env bash

# Start measuring scrip execution time
START_TIME=$(date +%s)

# Install Pods
bundle exec pod install

# Configs
# swiftgen config run --config Modules/NetwroksIntegrations/swiftgen.yml

# End and print scrip execution time
END_TIME=$(date +%s)
ELAPSED_TIME=$(( $END_TIME - $START_TIME ))
echo -e "Install worked for \033[1;32;40m$ELAPSED_TIME\033[0m seconds"