# denoiser — 設計ドキュメント（SSoT）

> 自作SaaSポートフォリオ第4弾。Krisp Pro（$8/月）を置き換える。
> Notion俯瞰DB: 「自作SaaSポートフォリオ」配下 denoiser 行。

## 目的と要件

- 自分側（マイク→相手）のノイズ除去 — LINE通話 / Google Meet で使う
- 相手側（受信音声→スピーカー）のノイズ除去
- 発展: AIによるノイズ種別の判別・適応（Phase 2）

## 出自（フォーク）

- フォーク元: [ivalsaraj/NoNoise-Mac](https://github.com/ivalsaraj/NoNoise-Mac)（MIT、MetalVoiceの後継）
- コアモデル: DeepFilterNet3 → CoreML変換済み・Apple Neural Engine実行（リポジトリ同梱 `Resources/DeepFilterNet3_Streaming.mlmodelc`）
- 発信側: 自前HALドライバ `NoNoiseMic.driver`（AudioServerPlugIn）が仮想マイク「NoNoise Mic」を公開
- 受信側: macOS 14.4+ Process Tap（`CATapDescription(stereoGlobalTapButExcludeProcesses:)`）で全システム音声を捕捉→DFN→デフォルト出力へ再生（元音ミュート）。**アプリ側のスピーカー設定は不要**

## このフォークでの変更

| 変更 | 理由 |
|---|---|
| Sparkle自動更新を除去 | SPMのバイナリ取得がハング。git更新のため不要 |
| MenuBarExtra → NSStatusItem直接管理 | macOS 26でFrontBoardがステータスアイテムのシーンにterminateを送りアプリが起動3秒で死ぬ問題の回避 |
| DIAG診断ログ（stderr） | 無音パイプ調査用の一時措置。実運用合格後に削除orフラグ化 |

## 検証結果（2026-07-16 Phase 0）

- ユニットテスト 231件全パス
- 発信NC: 声通過 max -19dB / ピンクノイズ10dB減 / 静寂時ほぼ完全カット
  - 参考: 同条件でKrispは19dB減（定常ノイズはKrisp優位。声質は実通話で判断）
- Clean Incoming: スピーカー出力ノイズを13〜17dB抑制（実効確認済み）
- 負荷: CPU 約0.1%（ANE実行）/ RSS 65MB — Krisp（3〜5%）より軽い

## ⚠️ 運用上の重要ルール

1. **アプリを`pkill`/強制終了しない**。ドライバの共有リング/クロック（`nn_ring`/`nn_clock`、初回StartIOアンカー方式）にゾンビIOが残り、以降「NoNoise Micが無音」になる。
   - 終了は必ず メニューバーQuit または `osascript -e 'quit app "NoNoiseMac"'`
   - 壊れたら `sudo killall coreaudiod` で回復
2. Clean Incoming ONの間はMac上の**全音声**（音楽含む）が清浄化される。通話時以外はOFF推奨。
3. ドライバ更新時は `./build-driver.sh` → `sudo ./install-driver.sh`（coreaudiod再起動で全音声が約3秒断）。

## ビルド・インストール

```bash
swift build                     # debug
swift test                      # 231 tests
./install-app.sh --with-driver  # release build + /Applications へ
sudo ./install-driver.sh        # HALドライバ導入（初回・更新時のみ）
```

## Phase 2 計画: ノイズ種別の自動判別・適応

既存モデルのオンデバイス再学習は非現実的（リサーチ結論）。現実解:

1. **SoundAnalysis framework**（`SNClassifySoundRequest`、300+クラス、オンデバイス）でマイク入力のノイズ種別を分類（キーボード/空調/交通/人声…）
2. 判別結果で `VoicePreset` / `suppressionStrength` を自動切替
   - 接続点: `ControlReducer`（`Sources/Core/ControlLayer.swift`）に `.setPreset(VoicePreset)` 直接指定アクションを追加（現状は next/prev 循環のみ）
3. 環境プロファイルをローカル記録し次回起動時に自動適用（「学習していく」体験）
4. 将来枠: サンプル収集→DFN3オフライン再学習→モデル差し替え

## 状態

- [x] Phase 0: ビルド・ドライバ導入・自動検証（2026-07-16）
- [ ] Phase 0残: LINE/Meet実通話の体感検証（マイク設定は完了、通話待ち）
- [ ] Phase 1: GitHubフォーク作成・push
- [ ] Phase 2: ノイズ種別自動判別
- [ ] Phase 3: 2週間実運用 → Krisp解約 → Notion更新
