APP_NAME = Hosven
# x-release-please-start-version
VERSION = 1.1.1
# x-release-please-end
BUILD_DIR = build
RELEASE_DIR = release
ARCHIVE_PATH = $(BUILD_DIR)/$(APP_NAME).xcarchive
APP_PATH = $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app
ZIP_NAME = $(APP_NAME)-v$(VERSION).zip
DMG_NAME = $(APP_NAME)-v$(VERSION).dmg

.PHONY: all clean generate build package dmg checksum release install uninstall

all: build

clean:
	rm -rf $(BUILD_DIR) $(RELEASE_DIR) *.xcodeproj DerivedData

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Release \
		-derivedDataPath $(BUILD_DIR) \
		ARCHS="arm64 x86_64" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="-" \
		build

package: build
	mkdir -p $(RELEASE_DIR)
	cd $(APP_PATH)/.. && zip -r $(CURDIR)/$(RELEASE_DIR)/$(ZIP_NAME) $(APP_NAME).app

dmg: build
	mkdir -p $(RELEASE_DIR)
	hdiutil create -volname "$(APP_NAME)" \
		-srcfolder $(APP_PATH) \
		-ov -format UDZO \
		$(RELEASE_DIR)/$(DMG_NAME)

checksum:
	@cd $(RELEASE_DIR) && shasum -a 256 $(ZIP_NAME)

release: clean package checksum dmg
	@echo "Release $(VERSION) ready in $(RELEASE_DIR)/"
	@cd $(RELEASE_DIR) && shasum -a 256 *

install: build
	cp -R $(APP_PATH) /Applications/

uninstall:
	rm -rf /Applications/$(APP_NAME).app
