init:
	@echo You probably want to run "zig build" instead.
.PHONY: init

# glad updates the GLAD loader. To use this, place the generated glad.zip
# in this directory next to the Makefile, remove vendor/glad and run this target.
#
# Generator: https://gen.glad.sh/
glad: vendor/glad
.PHONY: glad

vendor/glad: vendor/glad/include/glad/gl.h vendor/glad/include/glad/glad.h

vendor/glad/include/glad/gl.h: glad.zip
	rm -rf vendor/glad
	mkdir -p vendor/glad
	unzip glad.zip -dvendor/glad
	find vendor/glad -type f -exec touch '{}' +

vendor/glad/include/glad/glad.h: vendor/glad/include/glad/gl.h
	@echo "#include <glad/gl.h>" > $@

clean:
	rm -rf \
		zig-out .zig-cache \
		macos/build \
		macos/GhosttyKit.xcframework
.PHONY: clean

# install builds the same optimized release artifact as CI
# (.github/workflows/release.yml) and installs it as Ghostty Custom.
APP_NAME ?= Ghostty Custom
BUNDLE_ID ?= com.joshuarli.ghostty-custom
APPLICATIONS_DIR ?= $(HOME)/Applications

install:
	@if [ "$$(uname -s)" != Darwin ]; then echo "make install is macOS only" >&2; exit 1; fi
	@if [ "$$(uname -m)" != arm64 ]; then echo "make install builds arm64 only, same as CI" >&2; exit 1; fi
	zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos -Dxcframework-target=native -Demit-macos-app=false -Dsentry=false
	cd macos && xcodebuild -target Ghostty -configuration ReleaseLocal -arch arm64 PRODUCT_BUNDLE_IDENTIFIER="$(BUNDLE_ID)" INFOPLIST_KEY_CFBundleDisplayName="$(APP_NAME)"
	app="macos/build/ReleaseLocal/Ghostty.app"; \
	test -x "$$app/Contents/MacOS/ghostty"; \
	test "$$(lipo -archs "$$app/Contents/MacOS/ghostty")" = arm64; \
	test "$$(plutil -extract CFBundleIdentifier raw "$$app/Contents/Info.plist")" = "$(BUNDLE_ID)"; \
	test "$$(plutil -extract CFBundleDisplayName raw "$$app/Contents/Info.plist")" = "$(APP_NAME)"; \
	codesign -dv --strict "$$app" 2>&1 | grep -q "adhoc"
	mkdir -p "$(APPLICATIONS_DIR)"
	rm -rf "$(APPLICATIONS_DIR)/$(APP_NAME).app"
	ditto "macos/build/ReleaseLocal/Ghostty.app" "$(APPLICATIONS_DIR)/$(APP_NAME).app"
	@echo "Installed $(APPLICATIONS_DIR)/$(APP_NAME).app"
.PHONY: install
