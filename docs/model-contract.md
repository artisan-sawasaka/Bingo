# 3Dモデル受入仕様（Blender → GLB）

現在はプリミティブ製の仮モデル（`scripts/machine/primitive_machine.gd`）で全機能が動きます。下記の契約を満たす GLB を置くと、**コード変更なしで差し替わります**。契約を満たさない場合は警告を出して仮モデルに戻ります（`bingo_machine.gd` の `_validate_contract`）。

## ファイル

| 用途 | 置き場所 | 備考 |
|---|---|---|
| 原本 | `assets/blender/*.blend` | Godot は読み込まない（`.gdignore`） |
| 抽選機 | `assets/models/bingo_machine.glb` | 下記ノード構成 |
| ボール（任意） | `assets/models/bingo_ball.glb` | 無ければ球メッシュを使用 |
| 効果音（任意） | `assets/audio/start|rattle|release|reveal|finish|error.(ogg|wav|mp3)` | 無ければ自動合成音 |

## 座標・単位

- 単位：**メートル**、Blender の Scale は適用済み（Apply Scale）。
- 上方向：+Y（glTF 出力の既定「+Y Up」）。正面（カメラ側）：**+Z**。
- 原点：ステージ床面の中心（Y=0 が床）。
- 目安サイズ：全高 約2.4 m、ステージ直径 約3.5 m（カメラは自動で全体を収めるが、極端に違うと構図が崩れる）。
- ボール半径：**0.085 m**（変える場合は `PrimitiveMachine.BALL_RADIUS` と合わせる）。

## 必須ノード（名前は完全一致・大文字小文字区別）

| ノード名 | 種類 | 意味 |
|---|---|---|
| `Drum` | Empty または Mesh の親 | 回転するドラム一式の親。**ピボット＝回転中心、ローカル +X 軸まわりに回転** |
| `DrumInterior` | Empty | ドラム内のボールが動ける球領域。位置＝中心、**Scale X＝内側の有効半径(m)**（ボール半径を差し引いた値）。`Drum` の子にしない（回転させない） |
| `ExitMarker` | Empty | 当選ボールがドラムから出てくる位置（ボール中心） |
| `ChutePoint_1` … `ChutePoint_N` | Empty | 出口から受け皿までの経路（ボール中心が通る点、番号順、1つ以上） |
| `TrayMarker` | Empty | 受け皿で静止するボールの中心位置 |
| `CameraTarget`（任意） | Empty | カメラの注視点。無ければ (0.25, 1.15, 0.2) |

- ドラム以外（支柱・ステージ・シュート・受け皿）は自由に作ってよい。動かさない。
- **回転するドラム（枠・リングを含む）が通る球の外に、静止部品を置くこと**（台・リング・出口・シュートがめり込まない）。仮モデルではドラム中心 (0, 1.55, 0)、回転球の半径 0.835 m、台の上端 0.6 m、出口はドラム中心から前下方向に 0.955 m。`tests/unit/test_machine_model.gd` が仮モデルで同じ条件を検査している。
- 透明ドラムのマテリアルは glTF の Alpha Blend で出力（Godot 側で透明として読み込まれる）。屈折など重いものは避ける。

## ボール GLB（任意）

- 原点＝球の中心、半径 0.085 m、正面 +Z。
- 色を番号帯（B/I/N/G/O）ごとに変えるため、色を変えたいマテリアル名に **`BallBase`** を含める（Godot 側で albedo を上書き）。
- 番号は**モデルに焼き込まない**。抽選されたボールでは `BallBase` の面が Godot 側のシェーダー（`shaders/ball_label.gdshader`）に置き換わり、白い丸＋番号がローカル ±Z 方向に表面へ印刷される（数字ごとのモデルは作らない）。そのため `BallBase` の面は球の中心を原点とする球面であること。

## マテリアル・負荷の目安

- PBR（Principled BSDF）。テクスチャは 2K 以下、合計 30 MB 以下目安。
- ポリゴン：機械全体 15 万三角形以下、ボール 2,000 三角形以下（ドラム内に最大32個表示）。
- ライト・カメラは GLB に含めない（Godot 側で制御）。

## 差し替え手順

1. `assets/models/bingo_machine.glb`（必要なら `bingo_ball.glb`）を置く。
2. Godot エディタで一度開く（インポート）か `Godot --headless --path . --import`。
3. 起動ログに `does not satisfy docs/model-contract.md` が出ないことを確認。
4. 抽選を数回行い、ボールが `ExitMarker` → `ChutePoint_*` → `TrayMarker` を通ることを確認。
