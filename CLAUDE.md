# CLAUDE.md

## 開発環境

- Godot 実行ファイル: `C:\tools\Godot\Godot_v4.7.2-stable_win64.exe` (Godot 4.7.2 stable, Windows 64bit)
- コンソール版（ログを標準出力に出す。テスト・ヘッドレス実行はこちら）: `C:\tools\Godot\Godot_v4.7.2-stable_win64_console.exe`
- エクスポートテンプレート: 4.7.2 を `%APPDATA%\Godot\export_templates\4.7.2.stable\` に導入済み（2026-11-06、公式 SHA512 照合済み）
- 配布物: `tools\build_windows.ps1` → `build\windows\`（BingoDrum3D.exe ＋ .console.exe ＋ THIRD_PARTY_LICENSES.txt）

## プロジェクト概要

テレビ用3Dビンゴ抽選機（Godot 4.7.2 Standard / GDScript のみ、C#禁止）＋スマホWebリモコン（`web-remote/`）。
Godot プロジェクトはリポジトリ直下（`res://` = ルート）。仕様は README.md と docs/ を参照。

## コマンド

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1          # Godot テスト（SCRIPT ERROR も失敗扱い）
node --test tests/web/lever_math.test.cjs                             # Web リモコンのロジックテスト（ディレクトリ指定は不可、ファイル指定）
& "C:\tools\Godot\Godot_v4.7.2-stable_win64_console.exe" --path . -- --profile=dev --windowed   # 開発実行（本番データと分離）
powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1      # エクスポート＋スモークテスト（要テンプレート）
```

## 規約・注意

- 抽選結果は `GameController.request_spin()` だけが決め、演出前に保存する。3D/UI は結果を表示するだけ。
- 抽選機の表示はゲーム状態の写し：`machine.set_state(max, remaining, drawn)` でドラム（残りの番号の球）・受け皿（最後の球）・外周（それ以前の球）を一括設定する。ドラムの球の動き（`drum_sim.gd`）は見た目専用で、番号の決定には使わない。
- 球はすべて MultiMesh で描く（`ball_visuals.gd`、番号と色はインスタンスデータ）。球ごとに Node やテクスチャを作らない。
- 動きの確認は連続キャプチャ（`--capture=PATH --capture-count=N --capture-interval=SEC`、`--demo-spin=SEC` と併用）。
- `class_name` は使わず `preload()` 定数で参照（ヘッドレス `-s` 実行でグローバルクラスキャッシュに依存しないため）。
- 型推論 `:=` は戻り値が Variant の式（untyped 配列要素、preload したスクリプトの静的関数の戻り値など）で使うとパースエラーになる。明示型を書く。
- 日本語を含むファイルを PowerShell の `Get-Content`/`Set-Content` で書き換えない（文字化けする）。編集は Edit ツールで。
- `tools/*.ps1` は ASCII のみで書く（Windows PowerShell 5.1 は BOM なし UTF-8 の日本語を誤読して構文エラーになる）。
- `build\windows\BingoDrum3D.exe` をユーザーが起動中だとビルドで上書きできない（ビルドスクリプトが検知して停止する）。勝手に終了させず、閉じてもらう。
- スクリーンショット用の起動（`--capture`）はウィンドウがフォーカスを取らない設定。手元のキー入力が紛れ込まないようにするため。
- テストや動作確認でアプリを起動するときは `--profile=<名前>` を付け、`%APPDATA%\BingoDrum3D\` の本番データを汚さない。
- Web ファイル（`web-remote/`）はサーバー起動時にメモリへ読み込むので、変更後はアプリ再起動が必要。
- Godot 4.4+ の LineEdit は focus だけでは入力できない（edit モードが必要）。`grab_focus()` の後に `edit()` を呼ぶ。編集中は Esc を LineEdit が消費するので、画面を閉じる Esc は `_input` で先に処理する。
- 全操作はキーボードでも可能にする方針（キー割当は `main.gd` の `_unhandled_input` と `overlays.open_help()`）。リモコンに機能を足したらキーも足す。
- キー入力のテストは `tree.root.push_input(InputEventKey)` で実イベントを流す（`tests/integration/test_app_acceptance.gd`）。
