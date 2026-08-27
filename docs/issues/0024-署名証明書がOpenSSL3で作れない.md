完了

- `scripts/setup-signing-cert.sh` が OpenSSL 3 系の環境で失敗する
    - PKCS#12 の既定が AES + SHA-256 MAC になるため、macOS の `security import` が
      "MAC verification failed during PKCS12 import" で失敗する
    - macOS 標準の LibreSSL では成功するので、Homebrew で openssl を入れている環境だけが踏む
    - macOS が扱える旧来のアルゴリズム（3DES + SHA-1 MAC）を明示して回避する
- 証明書が作れないと `make app` が ad-hoc 署名にフォールバックする
    - その状態でアクセシビリティ権限を許可した後に証明書署名へ切り替えると、
      macOS が記録した署名要件と一致しなくなり権限が失効する
    - このときシステム設定のスイッチを ON / OFF しても記録は更新されないため復旧しない
    - エントリごと削除して登録し直す必要がある（`tccutil reset Accessibility local.cliphistory.app`）
    - この復旧手順を README に追記する
    - `setup-signing-cert.sh` の完了メッセージにも同じ注意を書く
