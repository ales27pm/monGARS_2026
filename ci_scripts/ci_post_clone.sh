#!/bin/sh
set -eu

# MLX Swift LM uses Swift macros. Xcode Cloud starts from a fresh trust store,
# so accept package macros non-interactively for command-line archive builds.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
