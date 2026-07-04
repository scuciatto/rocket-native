# This machine has Command Line Tools only (no full Xcode), so `swift test`
# needs explicit search paths for Testing.framework and its interop dylib.
CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS := -Xswiftc -F$(CLT_DEV)/Frameworks \
              -Xlinker -F$(CLT_DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib

.PHONY: build test cli clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

cli:
	swift run rc-cli $(ARGS)

clean:
	swift package clean
