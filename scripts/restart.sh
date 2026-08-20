#!/bin/bash
set -euo pipefail

# スクリプト自身の位置からリポジトリルートを求めて移動する。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APP_BIN=".build/ClipHistory.app/Contents/MacOS/ClipHistory"

echo "==> 既存プロセスを終了します"
PIDS="$(pgrep -f "$APP_BIN" || true)"
if [ -z "$PIDS" ]; then
  echo "ClipHistory は起動していません"
else
  kill $PIDS
  for _ in $(seq 1 5); do
    sleep 1
    PIDS="$(pgrep -f "$APP_BIN" || true)"
    if [ -z "$PIDS" ]; then
      break
    fi
  done
  PIDS="$(pgrep -f "$APP_BIN" || true)"
  if [ -n "$PIDS" ]; then
    echo "終了しなかったため強制終了します"
    kill -9 $PIDS
  fi
fi

echo "==> ビルドします"
if ! make app; then
  echo "ビルドに失敗しました" >&2
  exit 1
fi

echo "==> 起動します"
open ".build/ClipHistory.app"

echo "==> 起動確認をします"
sleep 2
# LSUIElement のアクセサリアプリのため、Dock やウィンドウの出現では起動確認ができない。
# メニューバー常駐プロセスとして起動しているかを pgrep で確認する。
PIDS="$(pgrep -f "$APP_BIN" || true)"
if [ -z "$PIDS" ]; then
  echo "ClipHistory の起動を確認できませんでした" >&2
  exit 1
fi
echo "ClipHistory が起動しました (PID: $PIDS)"
