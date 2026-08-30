import Foundation
import Testing
@testable import ClipHistoryCore

@Suite("Config")
struct ConfigTests {
    @Test("[nvim.env] の内容が nvimEnvironment に読み込まれる")
    func nvimEnvIsLoadedIntoNvimEnvironment() throws {
        let config = try Config.parse("""
        [nvim.env]
        FOO = "bar"
        BAZ = "qux"
        """)
        #expect(config.nvimEnvironment == ["FOO": "bar", "BAZ": "qux"])
    }

    @Test("[nvim.env] が無い場合は空になる")
    func emptyWhenNvimEnvTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.nvimEnvironment == [:])
    }

    @Test("未知のテーブル・未知のキーが無視される")
    func unknownTablesAndKeysAreIgnored() throws {
        let config = try Config.parse("""
        futureRootKey = "value"

        [unknown]
        key = "value"

        [nvim]
        futureNvimKey = "value"

        [nvim.env]
        FOO = "bar"
        """)
        // ルート直下のキーや、Config が参照しない [unknown] / [nvim] テーブルは
        // エラーにならず単に無視され、[nvim.env] だけが取り込まれる。
        #expect(config.nvimEnvironment == ["FOO": "bar"])
    }

    @Test("[cycle] の timeout が cycleTimeout に読み込まれる")
    func cycleTimeoutIsLoadedFromConfig() throws {
        let config = try Config.parse("""
        [cycle]
        timeout = 30
        """)
        #expect(config.cycleTimeout == 30)
    }

    @Test("[cycle] が無い場合は cycleTimeout が既定値の10になる")
    func cycleTimeoutDefaultsToTenWhenCycleTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.cycleTimeout == 10)
    }

    @Test("[cycle] の timeout が不正な値（0以下・非数値）の場合は既定値の10になる")
    func cycleTimeoutFallsBackToDefaultOnInvalidValue() throws {
        let zero = try Config.parse("""
        [cycle]
        timeout = 0
        """)
        #expect(zero.cycleTimeout == 10)

        let negative = try Config.parse("""
        [cycle]
        timeout = -5
        """)
        #expect(negative.cycleTimeout == 10)

        let nonNumeric = try Config.parse("""
        [cycle]
        timeout = "abc"
        """)
        #expect(nonNumeric.cycleTimeout == 10)
    }

    @Test("[cycle] の timeout に小数を指定できる")
    func cycleTimeoutAcceptsDecimalValue() throws {
        let config = try Config.parse("""
        [cycle]
        timeout = 2.5
        """)
        #expect(config.cycleTimeout == 2.5)
    }

    @Test("[font] の size が fontSize に読み込まれる")
    func fontSizeIsLoadedFromConfig() throws {
        let config = try Config.parse("""
        [font]
        size = 16
        """)
        #expect(config.fontSize == 16)
    }

    @Test("[font] が無い場合は fontSize が既定値の12になる")
    func fontSizeDefaultsToTwelveWhenFontTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.fontSize == 12)
    }

    @Test("[font] の size が不正な値（0以下・非数値）の場合は既定値の12になる")
    func fontSizeFallsBackToDefaultOnInvalidValue() throws {
        let zero = try Config.parse("""
        [font]
        size = 0
        """)
        #expect(zero.fontSize == 12)

        let negative = try Config.parse("""
        [font]
        size = -5
        """)
        #expect(negative.fontSize == 12)

        let nonNumeric = try Config.parse("""
        [font]
        size = "abc"
        """)
        #expect(nonNumeric.fontSize == 12)
    }

    @Test("[font] の size に小数を指定できる")
    func fontSizeAcceptsDecimalValue() throws {
        let config = try Config.parse("""
        [font]
        size = 14.5
        """)
        #expect(config.fontSize == 14.5)
    }

    @Test("[history] の max_item_count が maxItemCount に読み込まれる")
    func maxItemCountIsLoadedFromConfig() throws {
        let config = try Config.parse("""
        [history]
        max_item_count = 500
        """)
        #expect(config.maxItemCount == 500)
    }

    @Test("[history] が無い場合は maxItemCount が既定値の10000になる")
    func maxItemCountDefaultsToTenThousandWhenHistoryTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.maxItemCount == 10_000)
    }

    @Test("[history] の max_item_count が不正な値（範囲外・非数値）の場合は既定値の10000になる")
    func maxItemCountFallsBackToDefaultOnInvalidValue() throws {
        let zero = try Config.parse("""
        [history]
        max_item_count = 0
        """)
        #expect(zero.maxItemCount == 10_000)

        let tooLarge = try Config.parse("""
        [history]
        max_item_count = 100001
        """)
        #expect(tooLarge.maxItemCount == 10_000)

        let nonNumeric = try Config.parse("""
        [history]
        max_item_count = "abc"
        """)
        #expect(nonNumeric.maxItemCount == 10_000)
    }

    @Test("[monitor] の polling_interval が pollingInterval に読み込まれる")
    func pollingIntervalIsLoadedFromConfig() throws {
        let config = try Config.parse("""
        [monitor]
        polling_interval = 0.5
        """)
        #expect(config.pollingInterval == 0.5)
    }

    @Test("[monitor] が無い場合は pollingInterval が既定値の0.3になる")
    func pollingIntervalDefaultsToDefaultWhenMonitorTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.pollingInterval == 0.3)
    }

    @Test("[monitor] の polling_interval が不正な値（0以下・非数値）の場合は既定値の0.3になる")
    func pollingIntervalFallsBackToDefaultOnInvalidValue() throws {
        let zero = try Config.parse("""
        [monitor]
        polling_interval = 0
        """)
        #expect(zero.pollingInterval == 0.3)

        let negative = try Config.parse("""
        [monitor]
        polling_interval = -1
        """)
        #expect(negative.pollingInterval == 0.3)

        let nonNumeric = try Config.parse("""
        [monitor]
        polling_interval = "abc"
        """)
        #expect(nonNumeric.pollingInterval == 0.3)
    }

    @Test("[monitor] の max_text_bytes が maxTextBytes に読み込まれる")
    func maxTextBytesIsLoadedFromConfig() throws {
        let config = try Config.parse("""
        [monitor]
        max_text_bytes = 1024
        """)
        #expect(config.maxTextBytes == 1024)
    }

    @Test("[monitor] が無い場合は maxTextBytes が既定値の5242880になる")
    func maxTextBytesDefaultsToDefaultWhenMonitorTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.maxTextBytes == 5 * 1024 * 1024)
    }

    @Test("[monitor] の max_text_bytes が不正な値（0以下・非数値）の場合は既定値の5242880になる")
    func maxTextBytesFallsBackToDefaultOnInvalidValue() throws {
        let zero = try Config.parse("""
        [monitor]
        max_text_bytes = 0
        """)
        #expect(zero.maxTextBytes == 5 * 1024 * 1024)

        let nonNumeric = try Config.parse("""
        [monitor]
        max_text_bytes = "abc"
        """)
        #expect(nonNumeric.maxTextBytes == 5 * 1024 * 1024)
    }

    @Test("[monitor] の max_image_bytes が maxImageBytes に読み込まれる")
    func maxImageBytesIsLoadedFromConfig() throws {
        let config = try Config.parse("""
        [monitor]
        max_image_bytes = 2048
        """)
        #expect(config.maxImageBytes == 2048)
    }

    @Test("[monitor] が無い場合は maxImageBytes が既定値の20971520になる")
    func maxImageBytesDefaultsToDefaultWhenMonitorTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.maxImageBytes == 20 * 1024 * 1024)
    }

    @Test("[monitor] の max_image_bytes が不正な値（0以下・非数値）の場合は既定値の20971520になる")
    func maxImageBytesFallsBackToDefaultOnInvalidValue() throws {
        let zero = try Config.parse("""
        [monitor]
        max_image_bytes = 0
        """)
        #expect(zero.maxImageBytes == 20 * 1024 * 1024)

        let nonNumeric = try Config.parse("""
        [monitor]
        max_image_bytes = "abc"
        """)
        #expect(nonNumeric.maxImageBytes == 20 * 1024 * 1024)
    }

    @Test("[monitor] の skip_concealed が skipConcealed に読み込まれる")
    func skipConcealedIsLoadedFromConfig() throws {
        let config = try Config.parse("""
        [monitor]
        skip_concealed = false
        """)
        #expect(config.skipConcealed == false)
    }

    @Test("[monitor] が無い場合は skipConcealed が既定値のtrueになる")
    func skipConcealedDefaultsToTrueWhenMonitorTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.skipConcealed == true)
    }

    @Test("[monitor] の skip_concealed が不正な値（\"1\"・\"True\"）の場合は既定値のtrueになる")
    func skipConcealedFallsBackToDefaultOnInvalidValue() throws {
        let numeric = try Config.parse("""
        [monitor]
        skip_concealed = "1"
        """)
        #expect(numeric.skipConcealed == true)

        let capitalized = try Config.parse("""
        [monitor]
        skip_concealed = "True"
        """)
        #expect(capitalized.skipConcealed == true)
    }

    @Test("[list] の result_limit が resultLimit に読み込まれる")
    func resultLimitIsLoadedFromConfig() throws {
        let config = try Config.parse("""
        [list]
        result_limit = 50
        """)
        #expect(config.resultLimit == 50)
    }

    @Test("[list] が無い場合は resultLimit が既定値の200になる")
    func resultLimitDefaultsToDefaultWhenListTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.resultLimit == 200)
    }

    @Test("[list] の result_limit が不正な値（0以下・非数値）の場合は既定値の200になる")
    func resultLimitFallsBackToDefaultOnInvalidValue() throws {
        let zero = try Config.parse("""
        [list]
        result_limit = 0
        """)
        #expect(zero.resultLimit == 200)

        let nonNumeric = try Config.parse("""
        [list]
        result_limit = "abc"
        """)
        #expect(nonNumeric.resultLimit == 200)
    }

    @Test("[storage] の inline_blob_threshold が inlineBlobThreshold に読み込まれる")
    func inlineBlobThresholdIsLoadedFromConfig() throws {
        let config = try Config.parse("""
        [storage]
        inline_blob_threshold = 128
        """)
        #expect(config.inlineBlobThreshold == 128)
    }

    @Test("[storage] が無い場合は inlineBlobThreshold が既定値の65536になる")
    func inlineBlobThresholdDefaultsToDefaultWhenStorageTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.inlineBlobThreshold == 64 * 1024)
    }

    @Test("[storage] の inline_blob_threshold が不正な値（負数・非数値）の場合は既定値の65536になる")
    func inlineBlobThresholdFallsBackToDefaultOnInvalidValue() throws {
        let negative = try Config.parse("""
        [storage]
        inline_blob_threshold = -1
        """)
        #expect(negative.inlineBlobThreshold == 64 * 1024)

        let nonNumeric = try Config.parse("""
        [storage]
        inline_blob_threshold = "abc"
        """)
        #expect(nonNumeric.inlineBlobThreshold == 64 * 1024)
    }

    @Test("存在しないファイルパスを load(from:) に渡すと empty が返る")
    func loadFromNonExistentFileReturnsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-nonexistent-\(UUID().uuidString).toml")
        let config = try Config.load(from: url)
        #expect(config == .empty)
    }

    @Test("実ファイルを一時ディレクトリに書いて load(from:) で読める")
    func loadFromRealFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }

        let text = """
        [nvim.env]
        FOO = "bar"
        """
        try text.write(to: url, atomically: true, encoding: .utf8)

        let config = try Config.load(from: url)
        #expect(config.nvimEnvironment == ["FOO": "bar"])
    }

    @Test("XDG_CONFIG_HOME が絶対パスの場合にその配下を返す")
    func xdgConfigHomeAbsolutePathIsUsed() {
        let environment = ["XDG_CONFIG_HOME": "/tmp/xdg-config"]
        #expect(
            AppPaths.configFileURL(environment: environment).path
                == "/tmp/xdg-config/cliphistory/config.toml"
        )
        #expect(
            AppPaths.nvimInitPreURL(environment: environment).path
                == "/tmp/xdg-config/cliphistory/init-pre.lua"
        )
        #expect(
            AppPaths.nvimInitURL(environment: environment).path
                == "/tmp/xdg-config/cliphistory/init.lua"
        )
    }

    @Test("XDG_CONFIG_HOME が未設定・空文字列・相対パスの場合に ~/.config/cliphistory/config.toml を返す")
    func xdgConfigHomeFallsBackToDotConfig() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cliphistory", isDirectory: true)
            .appendingPathComponent("config.toml")
            .path

        #expect(AppPaths.configFileURL(environment: [:]).path == expected)
        #expect(AppPaths.configFileURL(environment: ["XDG_CONFIG_HOME": ""]).path == expected)
        #expect(AppPaths.configFileURL(environment: ["XDG_CONFIG_HOME": "relative/path"]).path == expected)
    }

    @Test("[hotkey] が無い場合は hotKeyBindings が空になる")
    func hotKeyBindingsIsEmptyWhenHotkeyTableIsAbsent() throws {
        let config = try Config.parse("")
        #expect(config.hotKeyBindings == [:])
    }

    @Test("[hotkey] の値がすべて読み込まれる")
    func hotKeyBindingsAreAllLoadedFromConfig() throws {
        let config = try Config.parse("""
        [hotkey]
        toggle_panel = "ctrl+command+c"
        cycle_previous = "ctrl+command+p"
        cycle_next = "ctrl+command+n"
        direct_vim_edit = "ctrl+command+v"
        paste_and_cycle_previous = "ctrl+command+b"
        """)
        #expect(config.hotKeyBindings[.togglePanel] == HotKeyBindingParser.parse("ctrl+command+c"))
        #expect(config.hotKeyBindings[.cyclePrevious] == HotKeyBindingParser.parse("ctrl+command+p"))
        #expect(config.hotKeyBindings[.cycleNext] == HotKeyBindingParser.parse("ctrl+command+n"))
        #expect(config.hotKeyBindings[.directVimEdit] == HotKeyBindingParser.parse("ctrl+command+v"))
        #expect(config.hotKeyBindings[.pasteAndCyclePrevious] == HotKeyBindingParser.parse("ctrl+command+b"))
    }

    @Test("[hotkey] の値が不正な場合はそのアクションだけ辞書に含まれない")
    func hotKeyBindingsExcludesInvalidValue() throws {
        let config = try Config.parse("""
        [hotkey]
        toggle_panel = "invalid"
        """)
        #expect(config.hotKeyBindings[.togglePanel] == nil)
        #expect(config.hotKeyBindings == [:])
    }

    @Test("[hotkey] の一部だけ設定されている場合はそのアクションだけ辞書に含まれる")
    func hotKeyBindingsIncludesOnlyConfiguredAction() throws {
        let config = try Config.parse("""
        [hotkey]
        toggle_panel = "ctrl+command+c"
        """)
        #expect(config.hotKeyBindings[.togglePanel] == HotKeyBindingParser.parse("ctrl+command+c"))
        #expect(config.hotKeyBindings[.cyclePrevious] == nil)
        #expect(config.hotKeyBindings[.cycleNext] == nil)
        #expect(config.hotKeyBindings[.directVimEdit] == nil)
        #expect(config.hotKeyBindings[.pasteAndCyclePrevious] == nil)
    }
}
