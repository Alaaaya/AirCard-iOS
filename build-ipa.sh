#!/bin/bash
set -euo pipefail

CONFIG="${1:-Release}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> Building Mirsa ($CONFIG)..."
rm -rf build/DerivedData build/Payload build/*.app build/*.ipa
mkdir -p build

xcodebuild -project Mirsa.xcodeproj \
    -scheme Mirsa \
    -configuration "$CONFIG" \
    -derivedDataPath build/DerivedData \
    -destination 'generic/platform=iOS' \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

APP_PATH="$(find build/DerivedData/Build/Products -name "Mirsa.app" -type d | head -n 1)"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: Mirsa.app not found in DerivedData"
    exit 1
fi

echo "==> Packaging IPA..."
cp -R "$APP_PATH" build/Mirsa.app

# Clean any existing signature
rm -rf build/Mirsa.app/_CodeSignature
rm -rf build/Mirsa.app/embedded.mobileprovision

# Control library for the container signer self-test.
mkdir -p build/Mirsa.app/Frameworks
xcrun -sdk iphoneos clang -arch arm64 -dynamiclib -miphoneos-version-min=16.0 \
    -install_name @rpath/MirsaProbe.dylib -o build/Mirsa.app/Frameworks/MirsaProbe.dylib ios-app/Probe/probe.c

mkdir -p build/Payload
cp -R build/Mirsa.app build/Payload/Mirsa.app

cd build
zip -qr "Mirsa.ipa" Payload
rm -rf Payload Mirsa.app

echo "==> Done! IPA generated at: $ROOT/build/Mirsa.ipa"
ls -lh "$ROOT/build/Mirsa.ipa"
