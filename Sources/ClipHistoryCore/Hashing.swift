import Foundation
import CryptoKit

/// SHA-256 ハッシュを16進文字列で返す。
/// `content_hash`（items）と BLOB のファイル名の両方で共通利用する。
public func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
