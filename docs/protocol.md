# リモコン通信プロトコル v1

PC（Godotアプリ）とスマホ（`web-remote/`）の間の仕様です。実装：`scripts/net/remote_server.gd`（サーバー）、`web-remote/app.js`（クライアント）。テスト：`tests/integration/test_remote_server.gd`、`tests/unit/test_net_codec.gd`。

## 1. 配信と接続

| 項目 | 値 |
|---|---|
| ポート | 8765（使用中なら 8766〜8774 を順に試す。設定ファイル `settings.json` の `port` で変更可） |
| HTTP | `GET /`・`/index.html`・`/styles.css`・`/app.js`・`/healthz`（`HEAD` も可）。それ以外は 404、GET/HEAD 以外は 405 |
| WebSocket | `ws://<PCのIP>:<port>/ws`（同じポート。RFC 6455、拡張なし、テキストフレームのみ） |
| 配信元 | `res://web-remote/` を起動時にメモリへ読み込む。エクスポート時は `export_presets.cfg` の `include_filter="web-remote/*"` で exe 内の pck に同梱 |
| 接続用URL | `http://<PCのIP>:<port>/#k=<トークン>`（QRコードに入る）。トークンはフラグメントなのでHTTPリクエストやログに載らない。クライアントは**トークンをアドレスに残す**（「ホーム画面に追加」は現在のアドレスを保存し、追加されたアプリは保存領域が空の状態で始まるため。アドレスにトークンが無く保存領域にある場合はアドレスへ書き戻す） |

### セキュリティ規則（サーバーが強制）

1. **Host 検査**：`Host` ヘッダが「このPCのLAN IPv4 / `localhost` / `127.0.0.1` + ポート」以外なら `421`（DNSリバインディング対策）。
2. **Origin 検査**：WebSocket アップグレード時、`Origin` が `http://<Host>` と完全一致しなければ `403`。Origin なしも拒否。
3. **トークン認証**：接続後 5 秒以内に最初のメッセージとして `hello`（正しい `token`）を送らないと切断（close 4001）。`hello` 以外を先に送っても切断。
4. **認証失敗の制限**：同じIPから 60 秒に 5 回失敗すると 60 秒ブロック。
5. **サイズ制限**：HTTP リクエストヘッダ 8 KB、WebSocket メッセージ 4096 バイト（超過は close 1009）。
6. **レート制限**：接続ごとにトークンバケット（容量 20、毎秒 10 回復）。**テキストだけでなく ping/pong などの制御フレームや、分割メッセージの途中フレーム（空の継続フレームを含む）も1フレーム1トークン**。1フレーム処理あたり最大32フレーム。超過は close 1008。`spin_request`・`new_game` は同一接続で 400 ms 以内の再送を拒否。
6b. **受信バッファ**：1フレームあたりソケットから読むのは最大 16 KB、未処理の WebSocket データは最大 16 KB。超過は close 1009。
7. **同時接続**：最大 24。
8. **生存監視**：受信が 30 秒なければ切断。クライアントは 4 秒ごとに `ping`。
9. トークンは画面・ログに出さない（QR の中のみ）。接続画面の「QRを再発行」で新トークンを発行し、既存の接続はすべて `auth_failed` → close 4001。新トークンは一時ファイル→検証→置換で保存し、**保存できなかった場合は成功表示を出さず**、「再起動で古いQRが有効に戻る可能性がある」とテレビにエラー表示する。
10. LAN 内 HTTP は暗号化されない。公共 Wi-Fi では使わない。

## 2. メッセージ（JSON テキスト）

### クライアント → サーバー

| type | フィールド | 説明 |
|---|---|---|
| `hello` | `v:1`, `token`, `client_id`（4〜64文字 `[A-Za-z0-9_-]`） | 最初の1通。成功で `welcome` |
| `spin_request` | `request_id`（8〜64文字 `[A-Za-z0-9_-]`） | 抽選要求。番号はクライアントが決めない |
| `get_state` | — | `state_snapshot` を要求 |
| `ping` | `t`（数値） | `pong` が返る |
| `show_screen` | `screen`: `main` \| `history` \| `setup` | テレビの画面切替。`command_result` が返る。抽選中・PC側で設定/確認画面表示中は拒否。`history`/`main` はゲーム開始前は拒否 |
| `setup_draft` | `max_number`（文字列または数値、4文字以内） | 入力途中の最大番号をテレビの入力欄に表示（検証はしない・返信なし） |
| `new_game` | `request_id`, `max_number` | 最大番号を決めて新しいゲームを開始（＝リセット）。`new_game_result` が返る。**確認はリモコン側で二段階**（ゲームが無い時は確認なし。確認画面の値を固定して送る）。`request_id` は新しいゲームと一緒に保存され（直近16件）、**PC 再起動後の再送も重複**として扱い二度適用しない。`max_number` は文字列のまま PC 側で検証（変換しない）。抽選中・PC側で設定画面／リセット確認画面を表示中は拒否。接続ごとに 400 ms のレート制限 |

### サーバー → クライアント

| type | フィールド | 説明 |
|---|---|---|
| `welcome` | `v`, `state` | 認証成功。全状態スナップショット付き |
| `auth_failed` | `message` | 直後に close 4001（約0.3秒後） |
| `state_snapshot` | `state` | 状態が変わるたびに全認証済みクライアントへ送信 |
| `spin_accepted` | `request_id`, `draw_index`, `duplicate`, `state` | 受理。`duplicate:true` は同じ `request_id` の再送（再抽選しない）。`state` で、再送した抽選が既に確定済み（`phase: ready`）かを判断できる |
| `spin_rejected` | `request_id`, `reason`, `message`, `state?` | 拒否。`reason`: `busy` `finished` `not_started` `paused` `rate_limited` `save_failed` `invalid` |
| `spin_started` | `draw_index` | 演出開始（**番号は含まない**） |
| `animation_finished` | `draw_index`, `number`, `state` | テレビで番号が確定表示された |
| `command_result` | `command`, `screen`, `ok`, `message` | `show_screen` の結果 |
| `new_game_result` | `request_id`, `ok`, `duplicate`, `message` | `new_game` の結果（`message` は失敗理由または「最大 N で開始しました」） |
| `pong` | `t` | |
| `error` | `reason`, `message` | 不正メッセージ等 |

### state（スナップショット）

```json
{
  "game_id": "57da82b3b8d3aac1",
  "version": 3,
  "phase": "ready",          // setup | ready | spinning | finished
  "paused": false,           // PC側で設定/確認画面を表示中
  "max_number": 75,
  "drawn_count": 2,          // 表示確定済みの数（演出中の番号は含まない）
  "remaining": 73,
  "last_number": 66,         // 未抽選なら null
  "recent": [66, 27],        // 新しい順・最大5件
  "can_spin": true,
  "screen": "main",          // テレビの画面: main | history | setup
  "modal": "",               // PC側で開いている画面: "" | setup | confirm_reset | settings | connect | restore
  "default_max": 75,         // 最大番号入力の初期値（現在のゲームの最大番号）
  "min_max": 1,
  "max_max": 999
}
```

`screen` と `modal` はアプリ（`main.gd` の `get_remote_snapshot()`）が付け足す。画面が変わるたびに全クライアントへ `state_snapshot` を送る。

**演出中の番号は、`animation_finished` まで一切クライアントへ送らない**（テストで検証）。

## 3. 状態遷移（サーバー）

```
setup ──(PCでゲーム開始: 保存成功)──▶ ready
ready ──spin_request──▶ [番号決定 → 原子的に保存] ──成功──▶ spinning
                                              └─保存失敗─▶ ready（spin_rejected: save_failed、演出しない）
spinning ──演出完了（またはウォッチドッグ: 演出長+3秒）──▶ ready / finished
ready/finished ──new_game（PC: M→入力→確認 / リモコン: 入力→確認）──▶ ready（新しいゲーム）
```

テレビの画面（`screen`）：

```
main ⇄ history        （H キー / show_screen。history 表示中の抽選は main に戻してから演出）
main/history → setup  （M キー / show_screen setup。表示中は paused=true で抽選不可）
setup → main          （Esc / show_screen main / new_game 成功）
```

- `spinning` 中・`finished`・`setup`・`paused` の `spin_request` は拒否（再抽選しない）。
- 演出完了後 0.3 秒のクールダウン中は `busy`。
- 同じ `request_id` は（直近64件まで、保存ファイルにも記録）常に同じ結果を返し、二重抽選しない。PC再起動後も有効。

## 4. クライアントの再接続方針（web-remote）

- 切断時は 0.5 → 1 → 2 → 4 → 5 秒間隔で再接続。再接続後は `welcome` の全状態で画面を上書き。
- `spin_request` への応答がないまま切断した場合、4 秒以内に再接続できたら**同じ `request_id` で1回だけ再送**（サーバーが重複を判定するので二重抽選にならない）。4 秒を過ぎたら破棄して「もう一度引いてください」。
- `visibilitychange`（画面ロック復帰・アプリ切替）、`pageshow`（bfcache）、`online` で即時再接続または `get_state`。
- close 4001 / `auth_failed` は自動再接続しない（QR を読み直すと `hashchange` で新トークンを取り込み再接続）。
- トークンの優先順位：アドレスの `#k=` → 保存領域（`localStorage`）。採用したトークンは常にアドレスにも保持する（`Protocol.urlWithToken`）。ホーム画面から起動（standalone）していてトークンが無い／古い場合は、「アイコンを削除して QR から開き、追加し直す」案内を表示する（QR を読むとブラウザが開くだけで、ホーム画面のアプリには届かないため）。
- `new_game` も応答前に切断した場合は 6 秒以内の再接続で同じ `request_id` を1回再送する。
- 最大番号シートは、ゲームが無い（`phase: setup`）間は自動で開き、PC側で設定画面が閉じられたら（`screen` が `setup` 以外になったら）自動で閉じる。
- レイアウト：横向き（iPad 想定）は左に情報とボタン、右にレバー。縦向きは上から情報・ボタン・レバー。
