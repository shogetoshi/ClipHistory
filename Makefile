PRODUCT_NAME  := ClipHistory
BUILD_DIR     := .build
CONFIGURATION := release
APP_DIR       := $(BUILD_DIR)/$(PRODUCT_NAME).app

.PHONY: build app test run clean

build:
	swift build -c $(CONFIGURATION)

test:
	swift test

# .app バンドルを組み立てて ad-hoc 署名する。
# .xcodeproj は使わず、SwiftPM の実行バイナリを手動でバンドル構造に配置する方式。
app: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	cp "$(BUILD_DIR)/$(CONFIGURATION)/$(PRODUCT_NAME)" "$(APP_DIR)/Contents/MacOS/$(PRODUCT_NAME)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	codesign -s - --force --deep "$(APP_DIR)"
	@echo "Built $(APP_DIR)"

run: app
	open "$(APP_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"
