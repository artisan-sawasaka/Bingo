# Bingo Drum 3D — テレビ用3Dビンゴ抽選機 ＋ スマホレバーリモコン

紙のビンゴカードで遊ぶための抽選アプリです。PCをテレビにつなぎ、**3Dの抽選機と今出た番号をフルスクリーン表示**。司会者は **iPad（横向き）や iPhone の Safari に表示したレバーを指で引いて**抽選します。オフライン・同一LAN内だけで動作し、アカウント・課金・クラウド・ネイティブアプリは不要です。

- エンジン：**Godot Engine 4.7.2 stable（Standard／非.NET）**、言語は **GDScript** のみ（C#/.NET 不要）
- 対象：Windows 10/11 x64（テレビは 1920×1080 想定）、リモコンは iPad / iPhone の Safari（横向き・縦向き両対応、Android Chrome も対応見込み）
- 状態：**Phase 1（動作する縦切りMVP）実装済み**。3D はプリミティブの仮モデル。テスト結果は [docs/test-plan.md](docs/test-plan.md)

## テレビの画面

| 画面 | 内容 | 切り替え |
|---|---|---|
| **メイン画面** | 3D抽選機と**今出た番号だけ**（何球目かを小さく表示） | 既定。一覧画面からは `H`／`Esc`、またはリモコンの「メイン画面に戻す」 |
| **番号一覧画面** | 1〜N を 10 個ずつの行で並べ、出た番号を色付け（最大番号が大きい時は左右に分割） | `H`、またはリモコンの「番号一覧を表示」 |
| **最大番号の設定・リセット画面** | 最大番号の入力、ゲーム開始／リセット | `M`、またはリモコンの「最大数・リセット」。初回起動時は自動で表示 |

番号一覧画面を表示したままレバーを引くと、自動でメイン画面に戻ってから抽選します。最大番号の設定画面・設定画面を開いている間は抽選できません。

## 使い方

### 1. 起動と最大番号
1. `BingoDrum3D.exe` を起動（開発中は Godot で `project.godot` を開いて実行）。
2. 最大番号を入力（既定 **75**、範囲 **1〜999**）→ `Enter`（またはリモコンで入力して「ゲーム開始」）。抽選対象は 1〜N。

### 2. iPad / スマホを接続
1. PC と iPad/スマホを**同じ Wi-Fi / LAN** に接続。
2. テレビ画面で **`Q` キー** → QR コードを表示。
3. iPad/iPhone のカメラで QR を読み取り、リンクを開く → 「抽選できます」と表示されれば完了。
   - 初回起動時に **Windows ファイアウォール**の確認が出たら「**プライベート ネットワーク**」を許可。
   - つながらない時：ゲストWi-Fi（端末間通信が遮断される）・VPN・テザリングを避ける／接続画面で `I`（別のIP）を試す。
   - 一度つながった端末は、PCアプリを再起動しても自動で再接続します（QR の再発行をしない限り）。

### 3. リモコン（iPad 横向き推奨）でできること
- **レバーを下まで引いて離す** → 抽選。途中で離すと戻るだけで抽選されません。約 2.4 秒でテレビに番号が出ます。
- **「番号一覧を表示」／「メイン画面に戻す」** → テレビの画面を切り替え。
- **「最大数・リセット」** → テレビが最大番号の画面になり、iPad の画面内テンキーで数字を入力（−／＋、75・90・100 のボタンも可。テレビにも入力中の数字が映る）→「この番号でリセット…」→「リセットして開始」の**二段階確認**で新しいゲーム。キャンセルでメイン画面に戻ります。
- **「全画面」ボタン**（右上）→ Safari のタブやアドレスバーを隠して表示（iPad の Safari・Android の Chrome）。もう一度押すと戻ります。
  - iPad の全画面は「下スワイプで閉じる」操作があるため、レバー部分では触れた瞬間に Safari の操作を止めています。それでもレバー操作で解除された場合は「全画面に戻す」「ホーム画面に追加する方法」が出ます。**確実なのはホーム画面に追加したアイコンから開く方法**（下スワイプで解除されません）。
  - **iPhone の Safari は全画面表示に対応していない**ため、ボタンを押すと「ホーム画面に追加」の手順が出ます。追加したアイコンから開くと、タブ・アドレスバーなしで使えます（ホーム画面のアイコンには接続コードが入るので、PC の IP が変わった時や QR を再発行した時は追加し直し）。
- 演出中・接続切れ・全番号終了・設定中のときはレバーが無効になり、理由が表示されます。番号が出たら次に引くまで表示を維持します（自動連続抽選はしません）。

### PC のキー操作（すべての操作をキーボードで可能）
| キー | 動作 |
|---|---|
| `Space` / `Enter` | 抽選（番号一覧画面からでも可） |
| `H` | 番号一覧画面 ⇔ メイン画面 |
| `M` | 最大番号の設定・リセット画面（数字キーで入力 → `Enter` → 確認で `←`/`→` と `Enter`、`Esc` でキャンセル） |
| `Q` | iPad/スマホ接続画面（QR）。表示中は `I`：別のIP、`R`：QR再発行 |
| `S` | 設定（音量・演出の長さ〔短い／標準／長い／ランダム＝毎回この3種のどれか〕・フルスクリーン・画面の余白・アプリ終了。`↑↓`/`Tab` で移動、`←→` で値変更） |
| `Esc` | 開いている画面を閉じる・戻る（メイン画面では設定を開く） |
| `F11` | フルスクリーン切替 |
| `L` | ライセンス表記（設定画面の「ライセンス」ボタンからも。`↑↓`/`PageUp`/`PageDown`/`Home`/`End` でスクロール） |
| `F1` / `?` | キー一覧 |

### 新しいゲーム（リセット）
`M`（またはリモコンの「最大数・リセット」）→ 最大番号を入力 →「リセットして開始…」→ 最終確認で「リセットして開始」の**二段階**。前のゲームの記録は保存フォルダの `archive/` に残ります（退避できなかった場合はリセットせずエラー表示）。

### 途中再開
アプリが落ちても、再起動すると「前回のゲームを復元しました」と表示され、そのまま続けられます。

## 抽選の公平性と保存

- 番号は **GDScript の抽選ロジックが先に決定**し、3D 演出はその結果を見せるだけです（物理演算で番号を決めない）。
- 未抽選の番号から OS の暗号論的乱数（`Crypto.generate_random_bytes` ＋棄却サンプリング）で**一様に1つ選択**。出た番号は二度と出ません。
- **抽選番号は演出開始前に保存**します。手順は「一時ファイルに書く → 読み戻して検証 → 旧ファイルを `.bak` へ → 置換」。読み込み時は main / tmp / bak のうちチェックサム（SHA-256。どれが最新かを決める世代番号 seq も対象）と整合性検証に通った最新のものを採用。tmp だけに最新が残っている場合は、次の保存の前に main へ昇格させてから書き込むため、保存中に落ちても確定済みの番号は失われません。**保存に失敗した場合は演出を始めず**エラー表示します。
- 保存内容：ゲームID・最大番号・抽選順・残り番号・最新番号・状態バージョン・直近の request_id。
- 保存場所：`%APPDATA%\BingoDrum3D\`（`game_state.json`、`.bak`、`archive\`、`settings.json`、`remote_secret.json`、`logs\`）。

## セキュリティと通信の注意

- スマホとは PC 上の**ローカル HTTP ＋ WebSocket**（ポート 8765）で通信します。インターネットには接続しません。
- QR コードの URL に**操作用の秘密トークン**（144bit 乱数）が入っています。トークンのない端末・LAN 内の他の人は抽選できません。トークンは URL のフラグメント（`#k=`）で渡すので HTTP リクエストやログに残らず、スマホ側でもアドレスバーから消去します。
- `Origin`・`Host` 検査、メッセージサイズ制限、レート制限、認証失敗時の一時ブロックを実装しています（詳細 [docs/protocol.md](docs/protocol.md)）。
- **LAN 内の HTTP は暗号化されません。** 自宅など信頼できるネットワークで使い、**公共 Wi-Fi では使わないでください**。
- QR を他人に撮られた場合は、接続画面の「QRを再発行」で古い接続を無効化できます。

## 開発

### 必要なもの
- Godot 4.7.2 stable（Standard）：`C:\tools\Godot\Godot_v4.7.2-stable_win64.exe`（コンソール版 `_console.exe` も同梱）
- テスト補助に Node.js（任意）

### 実行
```powershell
& "C:\tools\Godot\Godot_v4.7.2-stable_win64.exe" --path .
```
開発用オプション（`--` の後ろ）：`--profile=NAME`（データを `profiles\NAME\` に分離）、`--port=N`、`--windowed`、`--auto-start=75`、`--demo-draws=N`、`--demo-spin=1.0`、`--show=connect|settings|history|setup|help`、`--capture=PATH --capture-delay=SEC --quit-after-capture`。

### テスト
```powershell
powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1
node --test tests/web/lever_math.test.cjs
```

### フォルダ構成
```text
project.godot / export_presets.cfg   Godot プロジェクト（リポジトリ直下 = res://）
scenes/main.tscn                     起動シーン（UI はコードで構築）
scripts/core/    抽選ロジック・保存・状態遷移（GameState / SaveStore / GameController）
scripts/net/     HTTP+WebSocket サーバー、フレーム処理、LAN IP、トークン
scripts/machine/ 3D 抽選機（仮モデル生成・演出・カメラ）
scripts/ui/      テレビ画面 UI（メイン hud.gd・番号一覧 history_screen.gd・最大番号/設定など overlays.gd）
scripts/audio/   効果音（実行時に合成）
scripts/util/    QR コード生成・番号の色
web-remote/      スマホ用リモコン（index.html / styles.css / app.js）
assets/models/   GLB（Blender 納品物）  assets/blender/ 原本（Godot 対象外）  assets/audio/ 任意の差し替え音
tests/           GDScript テスト（unit / integration）と Node テスト（web）
docs/            protocol.md / model-contract.md / test-plan.md
tools/           テスト・ビルド・ライセンス生成スクリプト（Godot 対象外）
build/           エクスポート出力（Godot 対象外）
```
推奨構成（`godot/` サブフォルダ）から、**Godot プロジェクトをリポジトリ直下に置く**形に変更しました。`web-remote/` と `assets/models/` を他担当者向けの指示書どおりのパスに保ったまま、Godot から直接 `res://web-remote/`・`res://assets/models/` として参照・同梱でき、コピー手順による同期漏れが起きないためです。

## ビルド方法（Windows x64 配布物）

1. **エクスポートテンプレートを導入**（約1.3GB、初回のみ）：Godot エディタ → 「エディター」→「エクスポートテンプレートの管理」→ 4.7.2 をダウンロード。または公式リリース `https://github.com/godotengine/godot/releases/tag/4.7.2-stable` の `Godot_v4.7.2-stable_export_templates.tpz` を `SHA512-SUMS.txt` で照合し、中の `templates\` を `%APPDATA%\Godot\export_templates\4.7.2.stable\` として配置。
2. ビルドとスモークテスト：
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1
   ```
3. `build\windows\` に `BingoDrum3D.exe`（pck 埋め込みの単一 exe、約110MB。**これ単体で動作・配布可能**、ライセンス表記もアプリ内に収録）、`BingoDrum3D.console.exe`（ログを黒い窓に表示して起動する補助 exe。同じフォルダに置いて使う）、`THIRD_PARTY_LICENSES.txt`、`README.md`、`protocol.md` ができます。フォルダごと配布してください。ログは `%APPDATA%\BingoDrum3D\logs\godot.log` にも残ります。

Web リモコンのファイルは `export_presets.cfg` の `include_filter="web-remote/*"` で exe 内の pck に同梱され、実行時に `res://web-remote/` から読み込まれます（ビルドスクリプトのスモークテストで `/`・`/app.js`・`/styles.css` の配信を確認）。

## 技術的な判断

| 論点 | 決定 | 理由 |
|---|---|---|
| HTTP/WebSocket サーバー | `TCPServer` 上に HTTP と WebSocket（RFC 6455）を **GDScript で自前実装**、1 ポート | 外部プロセス・依存なしで exe 単体配布できる。Godot 標準の `WebSocketPeer.accept_stream` では Origin ヘッダを検査できず、要件の Origin 検査・サイズ制限・レート制限を確実に掛けられないため。Godot 標準クライアントで相互接続テスト済み |
| QR コード | GDScript で QR エンコーダを実装（Project Nayuki の MIT 実装を移植） | Godot に QR 生成機能がないため。独立デコーダ jsQR で全マスク復号を検証 |
| 認証 | 起動時（初回）にトークン生成・保存、QR の `#k=` で配布、WebSocket 最初の `hello` で照合 | 再起動しても再スキャン不要（復旧性を優先）。漏れたら「QRを再発行」で即無効化 |
| 演出 | ボールのドラム内の動きは見た目専用の簡易シミュレーション、当選球はスクリプト経路 | 結果を物理演算に依存させず、排出タイミングと到達位置を制御するため |
| 時間設定 | 起動0.2s／回転〜1.4s／排出〜1.85s／確定〜2.4s（設定で×0.75/×1.3、「ランダム」は抽選ごとに3種から均等に選ぶ。演出が止まった時の保険は最長3.12秒＋3秒） | 指示書の暫定シーケンス |
| レンダラー | Forward+（D3D12・OpenGL へのフォールバック有効） | 見栄えと Phase 2 の品質向上の余地。非対応 GPU では自動フォールバック |
| フォント・音 | Windows のシステムフォント（BIZ UDPゴシック/游ゴシック等）、効果音は実行時合成 | 外部素材のライセンス問題を避ける |

## 分業メモ

- `web-remote/` のレバー UI は [docs/protocol.md](docs/protocol.md) に従えば差し替え可能です。`requestSpin()` がレバーから分離されているので、1タップボタン等の代替操作も追加できます。テスト：`tests/web/`。
- 3D モデルは [docs/model-contract.md](docs/model-contract.md) のノード名・座標系で GLB を `assets/models/` に置けば差し替わります。

## ライセンス

- Godot Engine（MIT）および同梱サードパーティの表記は**アプリ内（設定 →「ライセンス」または `L` キー）で全文を表示**するため、exe 単体で配布しても表記条件を満たします。同じ内容を `tools/gen_licenses.gd` が `THIRD_PARTY_LICENSES.txt` にも出力します（文面は `scripts/util/licenses.gd` で共通）。
- QR 生成アルゴリズム：Project Nayuki「QR Code generator library」（MIT）を移植。
- 3D モデル・効果音・UI はすべて本プロジェクトで作成（プリミティブ形状・合成音）。外部の有料素材・ライセンス不明素材は使用していません。
- テスト専用ツール jsQR（Apache-2.0）は開発時のみ使用し、配布物には含みません。

## 既知の制限・未確認事項

- iPhone / Android 実機、テレビ実機、GPU の fps 計測は**未確認**（[docs/test-plan.md](docs/test-plan.md) の NOT RUN）。エクスポート版は開発PC上でのスモークテストとブラウザ操作のみ確認済み。
- exe はコード署名していないため、別のPCで初回起動時に Windows SmartScreen の警告が出ることがあります（「詳細情報」→「実行」）。
- 3D は仮モデル（Phase 2 で Blender モデルに差し替え予定）。
- 最大番号 999 の番号一覧は文字が小さくなります（75 前後を想定した画面設計）。
- リモコンからのリセットは iPad 側の二段階確認のみで実行します（テレビ側の確認ダイアログは出ません）。
