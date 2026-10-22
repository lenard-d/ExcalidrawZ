#!/bin/zsh

bash "$(dirname "$0")/check-drawing-settings-bridge.sh" || exit $?

defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
