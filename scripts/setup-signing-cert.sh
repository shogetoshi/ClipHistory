#!/bin/bash
set -euo pipefail

# ad-hoc 署名（codesign -s -）はバイナリの cdhash に署名要件が紐づくため、
# 再ビルドするたびに cdhash が変わり、アクセシビリティ権限が失効してしまう
# （Issue 0022）。署名要件を「バンドルID＋証明書」に固定するため、
# 安定した自己署名のコード署名証明書を作成し、ログインキーチェーンに登録する。

# スクリプト自身の位置からリポジトリルートを求めて移動する。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CERT_NAME="ClipHistory Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "==> 証明書の存在を確認します"
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" > /dev/null 2>&1; then
  echo "証明書 \"$CERT_NAME\" は既に存在します"
  exit 0
fi

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

echo "==> 自己署名のコード署名証明書を作成します"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -subj "/CN=$CERT_NAME" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$TMPDIR_LOCAL/key.pem" -out "$TMPDIR_LOCAL/cert.pem"

echo "==> PKCS#12 にまとめます"
openssl pkcs12 -export -out "$TMPDIR_LOCAL/identity.p12" \
  -inkey "$TMPDIR_LOCAL/key.pem" -in "$TMPDIR_LOCAL/cert.pem" \
  -name "$CERT_NAME" -passout pass:

echo "==> ログインキーチェーンへ取り込みます（キーチェーンのパスワード入力を求められることがあります）"
security import "$TMPDIR_LOCAL/identity.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign -A

echo "==> コード署名用途で信頼します（確認ダイアログが表示されることがあります）"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMPDIR_LOCAL/cert.pem"

echo "==> 証明書が利用可能か確認します"
if ! security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "証明書 \"$CERT_NAME\" が見つかりませんでした" >&2
  exit 1
fi

echo "==> 完了しました"
echo "この後 make app でこの証明書を使って署名するようにすれば、アクセシビリティ権限は一度許可すれば再ビルドしても維持されます。"
echo "ただし、この証明書に切り替えた直後は一度だけアクセシビリティ権限を許可し直す必要があります。"
