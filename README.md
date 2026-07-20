# NoNoise Mac（korezonzi fork）

**Krispの置き換え**として使う、Mac用の双方向AIノイズキャンセリングアプリ。
通話中のキーボード音・空調・生活音を、**完全オンデバイス**（Apple Neural Engine上のDeepFilterNet3）で除去します。クラウド送信なし・サブスク費用なし。

> 本リポジトリは [ivalsaraj/NoNoise-Mac](https://github.com/ivalsaraj/NoNoise-Mac)（MIT、MetalVoiceの後継）のフォークです。オリジナル開発者に感謝します 🙏

## できること

| 方向 | 機能 | 仕組み |
|---|---|---|
| 自分 → 相手 | マイクのノイズ除去 | 仮想マイク「**NoNoise Mic**」をLINE/Meet等で選ぶだけ |
| 相手 → 自分 | 受信音声のノイズ除去（Clean Incoming） | システム音声をAIが清浄化してスピーカーへ |

- モード切替（Meeting / Podcast / Tutorial / Custom）・声の明瞭化（Broadcast Voice）・リップノイズ除去
- グローバルホットキー: NCオンオフ **⌃⌥N**、生音と聴き比べ **⌃⌥B**（長押し）ほか
- CPU使用率 約0.1%（Neural Engine実行）・メモリ約65MB — Krisp（3〜5%）より軽い
- 対応: **Apple Silicon Mac（M1以降）+ macOS 13+**。Intel Mac非対応

## このフォークの変更点（vs upstream）

| 変更 | 理由 |
|---|---|
| メニューバーをNSStatusItem直接管理に変更 | macOS 26でMenuBarExtraがシステムに終了させられ、起動3秒で落ちる問題を回避 |
| Sparkle自動更新を除去 | SPMのバイナリ取得ハング回避+git更新のため不要 |
| 診断ログ(stderr)追加 | 無音トラブル調査用（通常利用に影響なし） |

**開発中（v2）**: 仮想スピーカー「**NoNoise Speaker**」— LINE/Meetのスピーカー設定で選んだアプリの音声**だけ**を清浄化（現在のClean Incomingは全システム音声に掛かるため、音楽再生まで加工される課題の解消）。あわせてメニューバー右クリックでの一括ON/OFF、チーム配布用pkgを整備予定。進捗は [docs/DESIGN.md](docs/DESIGN.md) 参照。

## インストール

### チームメンバー向け（pkg・ビルド不要）

配布された `NoNoiseMac-<version>.pkg` をダブルクリック。
未署名のため初回は macOS にブロックされます → **システム設定 > プライバシーとセキュリティ** を開き **「そのまま開く」** をクリックしてから再実行してください（初回のみ）。

インストーラがアプリ（/Applications）と仮想マイクドライバを一括導入します。**導入時に全音声が約3秒途切れます**（オーディオシステム再起動のため・正常です）。

詳細手順・トラブルシュートは `docs/TEAM-SETUP.md`（準備中）へ。

### ソースからビルド（開発者向け）

前提: Apple Silicon / macOS 13+ / Swiftツールチェーン（Xcode）

```bash
git clone https://github.com/korezonzi/NoNoise-Mac.git
cd NoNoise-Mac
./install-app.sh --with-driver   # release build → /Applications
sudo ./install-driver.sh         # 仮想マイクドライバ導入（coreaudiod再起動・音声3秒断）
```

初回起動は右クリック→「開く」（ad-hoc署名のため）。

## 使い方

1. メニューバーの NoNoise アイコンをクリック → **Noise Cancellation** がONであることを確認
2. 通話アプリでマイクを切り替え:
   - **LINE**: 設定 > 通話 > マイク → **NoNoise Mic**
   - **Google Meet**: 設定（歯車）> 音声 > マイク → **NoNoise Mic**
   - Zoom / Slack / Discord なども同様にマイク選択するだけ
3. 相手側の雑音も消したい場合: ポップオーバーの **Clean Incoming** をON
   - ⚠️ 現バージョンでは**Mac上の全音声**（音楽含む）に掛かります。通話時だけONにするのがおすすめ（v2で「通話アプリのみ」に改善予定）
4. スピーカー設定は変更不要（今のところ）

## ⚠️ 運用上の注意

- **アプリを強制終了（`pkill` / アクティビティモニタからの強制終了）しない**こと。仮想マイクドライバの共有バッファが壊れ、以降マイクが無音になります。終了は必ずメニューバーの **Quit** から
  - 壊れてしまったら: ターミナルで `sudo killall coreaudiod` → アプリ再起動で復旧
- アンインストール: `sudo ./uninstall-driver.sh` + /Applications からアプリ削除

## 開発

```bash
swift build      # debug build
swift test       # ユニットテスト（240+件・ヘッドレス）
Driver/tests/run-tests.sh   # ドライバCコードのホストテスト
```

- アーキテクチャ・DSP不変条件・リアルタイム音声の規律: [CLAUDE.md](CLAUDE.md)（AIエージェント/人間共用の開発ガイド）
- フォークの設計判断・検証結果・ロードマップ: [docs/DESIGN.md](docs/DESIGN.md)
- ドメイン用語集: [CONCEPTS.md](CONCEPTS.md)

## ロードマップ

- [x] Phase 0-1: フォーク・実環境検証（LINE/Meet実通話でノイズ減を確認）
- [ ] **v2（進行中）**: NoNoise Speaker（アプリ単位の受信NC）／メニューバー一括ON/OFF／チーム配布pkg
- [ ] ノイズ種別の自動判別→プリセット自動切替（SoundAnalysis）
- 文字起こし+要約は**別アプリ**として検討（NCのリアルタイム処理と性質が異なるため。docs/DESIGN.md参照）

## ライセンス

MIT — original work © [ivalsaraj](https://github.com/ivalsaraj)（NoNoise Mac）/ [Ghostkwebb](https://github.com/Ghostkwebb)（MetalVoice）。fork changes © korezonzi。
