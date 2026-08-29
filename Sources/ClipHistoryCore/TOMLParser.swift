import Foundation

/// TOML パースエラー。設定ファイルの記述ミスを利用者に伝えられるよう、
/// 日本語のメッセージに行番号を含める。
public enum TOMLParseError: Error, LocalizedError {
    /// 行の構文自体を解釈できなかった（テーブルヘッダでも `key = value` でもない）
    case syntaxError(line: Int)
    /// `key = value` の値部分がサポート対象外（数値・真偽値・配列など）
    case unsupportedValue(line: Int)
    /// 文字列リテラルの閉じクォートが無い、あるいは不正なエスケープを含む
    case invalidString(line: Int)
    /// テーブルヘッダの構文が不正
    case invalidTableHeader(line: Int)
    /// 同一テーブル内でキーが重複している
    case duplicateKey(line: Int, key: String)

    public var errorDescription: String? {
        switch self {
        case .syntaxError(let line):
            return "\(line)行目: 構文を解釈できません"
        case .unsupportedValue(let line):
            return "\(line)行目: サポートしていない値です（ダブルクォート文字列・数値・真偽値のみ対応しています）"
        case .invalidString(let line):
            return "\(line)行目: 文字列リテラルが不正です"
        case .invalidTableHeader(let line):
            return "\(line)行目: テーブルヘッダが不正です"
        case .duplicateKey(let line, let key):
            return "\(line)行目: キー「\(key)」が同一テーブル内で重複しています"
        }
    }
}

/// TOML の最小サブセットをパースする。外部依存を増やさない方針（design 13.1）のため
/// 自前実装とし、サポート範囲は設定ファイルに必要なものだけに絞る
/// （テーブルヘッダ・ダブルクォート文字列またはクォート無し数値リテラル・真偽値の `key = value` のみ）。
public enum TOMLParser {
    /// 「テーブル名 → （キー → 文字列値）」の2階層辞書を返す。
    /// テーブル名はドット区切りをそのまま連結した文字列（`[nvim.env]` → `"nvim.env"`）。
    /// テーブルヘッダの外に書かれたキーはルートテーブルとして `""` に入れる。
    public static func parse(_ text: String) throws -> [String: [String: String]] {
        var tables: [String: [String: String]] = [:]
        var currentTable = ""

        // `text.split` だと末尾の空行の扱いなどで行番号がずれうるため、改行で単純に分ける。
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                continue
            }

            if line.hasPrefix("[") {
                currentTable = try parseTableHeader(line, lineNumber: lineNumber)
                if tables[currentTable] == nil {
                    tables[currentTable] = [:]
                }
                continue
            }

            let (key, value) = try parseKeyValue(line, lineNumber: lineNumber)
            var table = tables[currentTable] ?? [:]
            guard table[key] == nil else {
                throw TOMLParseError.duplicateKey(line: lineNumber, key: key)
            }
            table[key] = value
            tables[currentTable] = table
        }

        return tables
    }

    /// 行コメント（`#` から行末まで）を取り除く。文字列リテラルの内側の `#` は
    /// コメントではないため、ダブルクォートの開閉状態を見ながら走査する。
    private static func stripComment(_ line: String) -> String {
        var result = ""
        var insideString = false
        var escaped = false

        for char in line {
            if insideString {
                result.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    insideString = false
                }
                continue
            }

            if char == "\"" {
                insideString = true
                result.append(char)
                continue
            }

            if char == "#" {
                break
            }

            result.append(char)
        }

        return result
    }

    /// `[name]` / `[a.b]` を解析し、ドット区切りをそのまま連結した文字列を返す。
    private static func parseTableHeader(_ line: String, lineNumber: Int) throws -> String {
        guard line.hasSuffix("]") else {
            throw TOMLParseError.invalidTableHeader(line: lineNumber)
        }
        let inner = line.dropFirst().dropLast()
        let parts = inner.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            throw TOMLParseError.invalidTableHeader(line: lineNumber)
        }

        var names: [String] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard isBareKey(trimmed) else {
                throw TOMLParseError.invalidTableHeader(line: lineNumber)
            }
            names.append(trimmed)
        }
        return names.joined(separator: ".")
    }

    /// `key = "value"` を解析する。キーはベアキーまたはダブルクォート文字列を許容する。
    private static func parseKeyValue(_ line: String, lineNumber: Int) throws -> (key: String, value: String) {
        guard let equalsIndex = findTopLevelEquals(line) else {
            throw TOMLParseError.syntaxError(line: lineNumber)
        }

        let keyPart = line[line.startIndex..<equalsIndex].trimmingCharacters(in: .whitespaces)
        let valuePart = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)

        let key: String
        if isBareKey(keyPart) {
            key = keyPart
        } else if keyPart.hasPrefix("\"") {
            key = try parseBasicString(keyPart, lineNumber: lineNumber)
        } else {
            throw TOMLParseError.syntaxError(line: lineNumber)
        }

        if valuePart.hasPrefix("\"") {
            let value = try parseBasicString(valuePart, lineNumber: lineNumber)
            return (key, value)
        }

        if valuePart == "true" || valuePart == "false" {
            return (key, valuePart)
        }

        guard isNumberLiteral(valuePart) else {
            throw TOMLParseError.unsupportedValue(line: lineNumber)
        }

        return (key, valuePart)
    }

    /// クォート無しの数値リテラル（整数・小数）かどうかを判定する。
    /// 先頭符号 `+`/`-` は任意、1個以上の数字、任意で `.` + 1個以上の数字のみを許容する
    /// （`1_000` や `0x1F`、`1e3` などはサポートしない）。
    private static func isNumberLiteral(_ s: String) -> Bool {
        let chars = Array(s)
        var i = 0

        if i < chars.count, chars[i] == "+" || chars[i] == "-" {
            i += 1
        }

        let integerStart = i
        while i < chars.count, chars[i].isASCII, chars[i].isNumber {
            i += 1
        }
        guard i > integerStart else { return false }

        if i < chars.count, chars[i] == "." {
            i += 1
            let fractionStart = i
            while i < chars.count, chars[i].isASCII, chars[i].isNumber {
                i += 1
            }
            guard i > fractionStart else { return false }
        }

        return i == chars.count
    }

    /// 文字列リテラルの外側にある最初の `=` の位置を探す。
    private static func findTopLevelEquals(_ line: String) -> String.Index? {
        var insideString = false
        var escaped = false

        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if insideString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    insideString = false
                }
            } else if char == "\"" {
                insideString = true
            } else if char == "=" {
                return index
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// ベアキー（英数字・`_`・`-`）かどうかを判定する。
    private static func isBareKey(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// ダブルクォートで囲まれた基本文字列をパースし、エスケープを展開する。
    /// `s` は前後の空白を除いた文字列全体（`"..."` の前後に他のトークンが無い状態）を想定する。
    private static func parseBasicString(_ s: String, lineNumber: Int) throws -> String {
        guard s.hasPrefix("\"") else {
            throw TOMLParseError.invalidString(line: lineNumber)
        }

        var result = ""
        let chars = Array(s)
        var i = 1 // 先頭の `"` を読み飛ばす
        var closed = false

        while i < chars.count {
            let char = chars[i]
            if char == "\"" {
                closed = true
                i += 1
                break
            }
            if char == "\\" {
                i += 1
                guard i < chars.count else {
                    throw TOMLParseError.invalidString(line: lineNumber)
                }
                let escapeChar = chars[i]
                switch escapeChar {
                case "\"":
                    result.append("\"")
                case "\\":
                    result.append("\\")
                case "n":
                    result.append("\n")
                case "t":
                    result.append("\t")
                case "r":
                    result.append("\r")
                case "0":
                    result.append("\0")
                case "u":
                    let (scalarString, consumed) = try parseUnicodeEscape(
                        chars, startIndex: i + 1, digitCount: 4, lineNumber: lineNumber
                    )
                    result.append(scalarString)
                    i += consumed
                case "U":
                    let (scalarString, consumed) = try parseUnicodeEscape(
                        chars, startIndex: i + 1, digitCount: 8, lineNumber: lineNumber
                    )
                    result.append(scalarString)
                    i += consumed
                default:
                    throw TOMLParseError.invalidString(line: lineNumber)
                }
                i += 1
                continue
            }
            result.append(char)
            i += 1
        }

        guard closed, i == chars.count else {
            throw TOMLParseError.invalidString(line: lineNumber)
        }

        return result
    }

    /// `\uXXXX` / `\UXXXXXXXX` の16進数部分を読み取り、対応する文字を返す。
    /// 戻り値の `consumed` は読み取った16進数の桁数（呼び出し側のインデックス前進量）。
    private static func parseUnicodeEscape(
        _ chars: [Character], startIndex: Int, digitCount: Int, lineNumber: Int
    ) throws -> (String, Int) {
        guard startIndex + digitCount <= chars.count else {
            throw TOMLParseError.invalidString(line: lineNumber)
        }
        let hex = String(chars[startIndex..<(startIndex + digitCount)])
        guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw TOMLParseError.invalidString(line: lineNumber)
        }
        return (String(Character(scalar)), digitCount)
    }
}
