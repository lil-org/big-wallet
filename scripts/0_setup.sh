#!/usr/bin/env bash

# Start measuring scrip execution time
START_TIME=$(date +%s)

# Find and enter directory, where the executing script lies
DIR="$( cd "$( dirname "$( dirname "${BASH_SOURCE[0]}" )" )" && pwd )"
cd "$DIR"

# Install Bundler, if necessary
if hash bundler 2>/dev/null;
then
    echo "Bundler is installed!"
else
    sudo gem install bundler
fi

# Install HomeBrew, if necessary
if hash brew 2>/dev/null;
then
    echo "HomeBrew is installed!"
else
    /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
fi

# Install SwiftLint, if necessary
if hash swiftlint 2>/dev/null;
then
  echo "SwiftLint is installed!"
else 
  brew install swiftlint
fi

# Install SwiftFormat, if necessary
if hash swiftformat 2>/dev/null;
then 
	echo "SwiftFormat is installed!"
else 
	brew install swiftformat
fi

# Install yarn, if necessary
if hash yarn 2>/dev/null;
then 
    echo "yarn is installed!"
else 
    brew install yarn
fi

# Install ComandlineTools, if necessary
if [[ ! "$(xcode-select -p)" =~ "/Library/Developer/CommandLineTools" ]];
then 
    echo "Xcode is correctly configured!"
else 
    echo "Visit https://stackoverflow.com/questions/61501298/xcrun-error-unable-to-find-utility-xctest-not-a-developer-tool-or-in-path"
    exit 1
fi

# Instal ruby deps(Cocoapods, Fastlane, ...)
bundle config set path 'vendor/bundle'
bundle install --gemfile=Gemfile

# Update Pods-Repos
BUNDLE_GEMFILE="Gemfile" bundle exec pod repo update

# End and print scrip execution time
END_TIME=$(date +%s)
ELAPSED_TIME=$(( $END_TIME - $START_TIME ))
echo -e "Setup worked for \033[1;32m$ELAPSED_TIME\033[0m seconds"