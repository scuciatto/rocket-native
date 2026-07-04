# This machine has Command Line Tools only (no full Xcode), so `swift test`
# needs explicit search paths for Testing.framework and its interop dylib.
CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS := -Xswiftc -F$(CLT_DEV)/Frameworks \
              -Xlinker -F$(CLT_DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib

APP_BUNDLE := .build/RocketNative.app

.PHONY: build test cli app run-app clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

cli:
	swift run rc-cli $(ARGS)

# Assemble the .app bundle without Xcode (release build, ad-hoc signed).
app:
	swift build -c release --product RocketNative
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp App/Info.plist $(APP_BUNDLE)/Contents/
	cp .build/release/RocketNative $(APP_BUNDLE)/Contents/MacOS/
	codesign --force -s - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE) — run with: open $(APP_BUNDLE)"

run-app: app
	open $(APP_BUNDLE)

clean:
	swift package clean
