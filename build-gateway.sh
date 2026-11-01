#!/bin/bash
# Build the Go gateway for macOS/arm64 and place it in the app bundle's
# Resources, so GatewayManager finds it as Bundle.main "m365hub".
# Run from the m365hub Go source checkout (the directory containing go.mod).
set -e
if [ ! -f go.mod ]; then echo "run this from the m365hub source dir (has go.mod)"; exit 1; fi
GOOS=darwin GOARCH=arm64 go build -o /tmp/m365hub-mac-binary ./cmd/hub
cp /tmp/m365hub-mac-binary ~/workspace/m365hub-mac-swiftui/M365HubApp/Resources/m365hub
chmod +x ~/workspace/m365hub-mac-swiftui/M365HubApp/Resources/m365hub
ls -la ~/workspace/m365hub-mac-swiftui/M365HubApp/Resources/m365hub
