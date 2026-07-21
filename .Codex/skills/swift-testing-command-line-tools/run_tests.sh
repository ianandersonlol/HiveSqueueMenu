#!/bin/bash
set -euo pipefail

TEST_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
TEST_LIBS="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [ ! -d "$TEST_FRAMEWORKS/Testing.framework" ]; then
  echo "error: Testing.framework not found under Command Line Tools" >&2
  exit 1
fi

if [ ! -f "$TEST_LIBS/lib_TestingInterop.dylib" ]; then
  echo "error: lib_TestingInterop.dylib not found under Command Line Tools" >&2
  exit 1
fi

swift test \
  -Xswiftc -F \
  -Xswiftc "$TEST_FRAMEWORKS" \
  -Xlinker -F \
  -Xlinker "$TEST_FRAMEWORKS" \
  -Xlinker -rpath \
  -Xlinker "$TEST_FRAMEWORKS" \
  -Xlinker -rpath \
  -Xlinker "$TEST_LIBS" \
  "$@"
