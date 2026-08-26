PRODUCT_NAME  := ClipHistory
BUILD_DIR     := .build
CONFIGURATION := release
APP_DIR       := $(BUILD_DIR)/$(PRODUCT_NAME).app
CODESIGN_IDENTITY ?= ClipHistory Dev

.PHONY: build app test run clean

build:
	swift build -c $(CONFIGURATION)

test:
	swift test

# .app バンドルを組み立てて署名する。
# CODESIGN_IDENTITY の証明書がキーチェーンにあればそれで署名し、無ければ ad-hoc 署名にフォールバックする。
# ad-hoc 署名だと Issue 0022 の連続貼り付けに必要なアクセシビリティ権限が再ビルドごとに失効する。
# .xcodeproj は使わず、SwiftPM の実行バイナリを手動でバンドル構造に配置する方式。
app: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	cp "$(BUILD_DIR)/$(CONFIGURATION)/$(PRODUCT_NAME)" "$(APP_DIR)/Contents/MacOS/$(PRODUCT_NAME)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	@if security find-identity -v -p codesigning | grep -q "$(CODESIGN_IDENTITY)"; then \
		echo "codesign -s \"$(CODESIGN_IDENTITY)\""; \
		codesign -s "$(CODESIGN_IDENTITY)" --force --deep "$(APP_DIR)"; \
	else \
		echo "警告: 署名証明書 \"$(CODESIGN_IDENTITY)\" が見つかりません。ad-hoc署名にフォールバックします"; \
		echo "      （この場合、連続貼り付けのアクセシビリティ権限が再ビルドごとに失効します。scripts/setup-signing-cert.sh を実行してください）"; \
		codesign -s - --force --deep "$(APP_DIR)"; \
	fi
	@echo "Built $(APP_DIR)"

run: app
	open "$(APP_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"
