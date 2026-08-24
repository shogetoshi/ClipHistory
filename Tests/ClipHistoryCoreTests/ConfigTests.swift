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
}
