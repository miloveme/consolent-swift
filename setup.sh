#!/bin/bash
set -e

echo "=== Consolent Project Setup ==="

# Check Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "ERROR: Xcode command line tools not found."
    echo "Install with: xcode-select --install"
    exit 1
fi

# Install xcodegen if not present
if ! command -v xcodegen &> /dev/null; then
    echo "Installing XcodeGen..."
    if command -v brew &> /dev/null; then
        brew install xcodegen
    else
        echo "ERROR: Homebrew not found. Install XcodeGen manually:"
        echo "  brew install xcodegen"
        echo "  or: mint install yonaskolb/XcodeGen"
        exit 1
    fi
fi

# Generate Xcode project
echo "Generating Xcode project..."
xcodegen generate

echo ""
echo "=== Setup Complete ==="
echo "Open Consolent.xcodeproj in Xcode and build (Cmd+B)"
echo ""
echo "  open Consolent.xcodeproj"
echo ""
