#!/bin/sh
set -eu

# MLX Swift LM uses Swift macros. Xcode Cloud starts from a fresh trust store,
# so accept package macros non-interactively for command-line archive builds.
if [ -z "${XCODE_CLOUD_WORKFLOW_ID:-}" ] && [ -z "${CI:-}" ] && [ -z "${CI_XCODEBUILD_ACTION:-}" ]; then
  echo "Skipping Xcode macro fingerprint override outside CI."
  exit 0
fi

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
