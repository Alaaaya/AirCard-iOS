#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ "$(uname -s)" = Darwin ]; then
  xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -Os -fno-builtin -fvisibility=hidden -dynamiclib MirsaLoader.c -o MirsaLoader.dylib -Wl,-install_name,@rpath/MirsaLoader.dylib -Wl,-headerpad,4096 -Wl,-no_uuid
else
  clang-21 -target arm64-apple-ios15.0 -Os -fno-builtin -fvisibility=hidden -fno-stack-protector -c MirsaLoader.c -o /tmp/mirsa-loader.o
  ld64.lld-21 -dylib -arch arm64 -platform_version ios 15.0 15.0 -install_name @rpath/MirsaLoader.dylib -headerpad 4096 -no_uuid /tmp/mirsa-loader.o libSystem.tbd -o MirsaLoader.dylib
fi
