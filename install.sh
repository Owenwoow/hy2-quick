#!/usr/bin/env bash
# Quick launcher for HY2 installer
# This script serves as a convenient entry point to the main installer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/bin/install.sh"

if [[ ! -f "$INSTALLER" ]]; then
    echo "Error: installer script not found at $INSTALLER"
    exit 1
fi

# Pass all arguments to the actual installer
bash "$INSTALLER" "$@"
