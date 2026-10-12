# Tests run on the Command Line Tools toolchain with explicit search paths
# for its Testing.framework and interop dylib. DEVELOPER_DIR pins that
# toolchain even when xcode-select points at Xcode: Xcode's compiler can't use
# the CLT Testing macros, and its own `swift test` fails codesigning the
# .xctest here (file-provider xattrs on the repo folder).
CLT := /Library/Developer/CommandLineTools
CLT_DEV := $(CLT)/Library/Developer
TEST_FLAGS := -Xswiftc -F$(CLT_DEV)/Frameworks \
              -Xlinker -F$(CLT_DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib

APP_BUNDLE := .build/RocketNative.app
# Stable self-signed identity (see `make signing-cert`). Ad-hoc signatures
# change every build, so the Keychain re-prompts for each stored token.
SIGN_IDENTITY ?= RocketNative Local Signing

.PHONY: build test cli app run-app signing-cert clean

build:
	swift build

test:
	DEVELOPER_DIR=$(CLT) swift test $(TEST_FLAGS)

cli:
	swift run rc-cli $(ARGS)

# Assemble the .app bundle without Xcode (release build). Signed with
# $(SIGN_IDENTITY) when present, ad-hoc otherwise.
app:
	swift build -c release --product RocketNative
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp App/Info.plist $(APP_BUNDLE)/Contents/
	cp .build/release/RocketNative $(APP_BUNDLE)/Contents/MacOS/
	@if security find-identity -v -p codesigning | grep -q "\"$(SIGN_IDENTITY)\""; then \
		codesign --force -s "$(SIGN_IDENTITY)" $(APP_BUNDLE); \
	else \
		codesign --force -s - $(APP_BUNDLE); \
		echo "Ad-hoc signed — run 'make signing-cert' once to stop Keychain password prompts"; \
	fi
	@echo "Built $(APP_BUNDLE) — run with: open $(APP_BUNDLE)"

run-app: app
	open $(APP_BUNDLE)

# One-time per machine: create the stable signing identity used by `app`.
signing-cert:
	scripts/make-signing-cert.sh "$(SIGN_IDENTITY)"

clean:
	swift package clean
