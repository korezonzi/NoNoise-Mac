import SwiftUI
import CoreAudio
import Core

struct SettingsView: View {
    @ObservedObject var audioModel: AudioModel
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var updaterController: UpdaterController
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager

    var body: some View {
        TabView {
            GeneralSettingsView(audioModel: audioModel, meterModel: audioModel.meterModel, updaterController: updaterController, launchAtLoginManager: launchAtLoginManager)
                .tabItem {
                    Label("全般", systemImage: "slider.horizontal.3")
                }

            HotkeySettingsView(manager: hotkeyManager)
                .tabItem {
                    Label("ホットキー", systemImage: "keyboard")
                }

            GuideView()
                .tabItem {
                    Label("セットアップ", systemImage: "book.pages")
                }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 440)
    }
}

// MARK: - General Tab

struct GeneralSettingsView: View {
    @ObservedObject var audioModel: AudioModel
    // Live diagnostics (clip/ceiling warnings, Smart Level message, integrated LUFS) now live on
    // MeterModel — observe it so the Settings readouts stay live while the popover is closed.
    @ObservedObject var meterModel: MeterModel
    @ObservedObject var updaterController: UpdaterController
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager

    @State private var isShowingSaveSheet = false
    @State private var newProfileName: String = ""
    @State private var renameTargetID: UUID? = nil
    @State private var renameText: String = ""
    @State private var isShowingResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                brandedHeader
                launchAtStartupCard
                suppressionCard
                inputVolumeCard
                profilesCard
                gainCard
                incomingCard
                loudnessCard
                resetCard
                footer
            }
            .padding(.trailing, 2)
        }
        .alert("設定をリセットしますか？", isPresented: $isShowingResetConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("リセット", role: .destructive) {
                withAnimation { audioModel.resetSettingsToDefaults() }
            }
        } message: {
            Text("NoNoise Macの音声・デバイス設定を初期値に戻します。保存済みの設定プロファイルとカスタムホットキーは維持されます。")
        }
    }

    private var brandedHeader: some View {
        HStack(spacing: 12) {
            logo
            VStack(alignment: .leading, spacing: 2) {
                Text("NoNoise Mac")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                Text("macOS向け、リアルタイム・オンデバイスAIノイズ除去")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var logo: some View {
        NoNoiseLogoAsset()
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var launchAtStartupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { launchAtLoginManager.isEnabled },
                set: { launchAtLoginManager.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ログイン時に自動起動")
                        .font(.subheadline)
                    Text("Macにログインすると自動的にNoNoise Macを起動します。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            if launchAtLoginManager.state == .requiresApproval {
                loginItemsGuidance("macOSの承認が必要です。システム設定 > 一般 > ログイン項目で確認してください。")
            } else if launchAtLoginManager.state == .notFound {
                loginItemsGuidance("ログイン時の自動起動は、NoNoise Macがアプリとして実行されている場合に有効です。")
            }
            if let errorMessage = launchAtLoginManager.errorMessage {
                loginItemsGuidance(errorMessage)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func loginItemsGuidance(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
            Button("ログイン項目を開く") {
                launchAtLoginManager.openLoginItems()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Suppression

    private var suppressionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("ノイズ除去", systemImage: "waveform.badge.magnifyingglass")

            Picker("", selection: $audioModel.selectedPreset) {
                ForEach(VoicePreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            sliderRow(
                title: "除去の強さ",
                value: "\(Int(audioModel.suppressionStrength * 100))%",
                help: "ノイズをどれだけ除去するか。低くすると元の音がより残ります。"
            ) {
                Slider(value: $audioModel.suppressionStrength, in: 0...1).tint(.accentColor)
            }

            sliderRow(
                title: "除去量の上限",
                value: audioModel.attenuationLimitDb >= VoicePreset.maxAttenuationDb
                    ? "最大" : "\(Int(audioModel.attenuationLimitDb)) dB",
                help: "背景音の除去量に上限を設け、声の自然さを保ちます。高いほど強くかかります。"
            ) {
                Slider(value: $audioModel.attenuationLimitDb,
                       in: VoicePreset.minAttenuationDb...VoicePreset.maxAttenuationDb).tint(.accentColor)
            }

            Divider()

            Toggle(isOn: $audioModel.voicePolishEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("声の仕上げ").font(.subheadline)
                    Text("ポッドキャストや講座向けのトーン調整とレベリング。モードに関係なく、このスイッチでON/OFFできます。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("声のクリア化").font(.subheadline)
                Picker("", selection: $audioModel.clarityLevel) {
                    ForEach(ClarityLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("自然な声を保ったまま、スタジオ品質の存在感とクリアさを加えます。歯擦音は自動で抑えられるため、クリアさが耳に刺さることはありません。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("リップノイズ除去").font(.subheadline)
                Picker("", selection: $audioModel.mouthNoiseLevel) {
                    ForEach(MouthNoiseLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("破裂音や口の雑音を抑えます。De-plosiveが低音のドスッという音を、De-clickが短いクリック音を抑えます。オフの場合は処理は加わりません。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .nnCard()
    }

    // MARK: Input volume & Smart Level

    private var inputVolumeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("入力音量", systemImage: "mic.fill")
                Spacer()
                Text("\(Int(audioModel.inputVolumeValue * 100))%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "mic.fill").foregroundColor(.secondary).font(.caption)
                Slider(value: $audioModel.inputVolumeValue, in: 0.25...1.0).tint(.accentColor)
                Image(systemName: "mic.fill").foregroundColor(.secondary).font(.caption)
            }

            Text("NoNoiseの処理前にマイクの音量を下げます。普通に話しているのに声が割れる、潰れる、大きすぎると感じる場合に使ってください。")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("80%にリセット") {
                    withAnimation { audioModel.inputVolumeValue = SmartLevelController.defaultInputVolume }
                }
                .controlSize(.small)
            }

            if meterModel.isSourceMicClipping {
                Label("NoNoiseの処理前にマイクの入力がクリップしています。可能ならmacOS/デバイスの入力音量を下げてください。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if meterModel.isInputNearCeiling {
                Label("入力音量が大きすぎます", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Divider()

            Toggle(isOn: $audioModel.smartLevelEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自動レベル調整").font(.subheadline)
                    Text("声が繰り返し上限に達すると、入力音量または出力音量を自動的に下げます。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let msg = meterModel.smartLevelMessage {
                Text(msg).font(.caption).foregroundColor(.secondary)
            }
        }
        .nnCard()
    }

    // MARK: - Voice Profiles

    private var profilesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("設定プロファイル", systemImage: "person.crop.rectangle.stack")
                Spacer()
                Button {
                    newProfileName = ""
                    isShowingSaveSheet = true
                } label: {
                    Label("現在の設定を保存", systemImage: "plus")
                        .font(.caption)
                }
                .controlSize(.small)
            }

            if audioModel.profiles.isEmpty {
                Text("まだプロファイルが保存されていません。設定を調整して「現在の設定を保存」をタップしてください。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(audioModel.profiles) { profile in
                    profileRow(profile)
                    if profile.id != audioModel.profiles.last?.id {
                        Divider()
                    }
                }
            }
        }
        .nnCard()
        // "Save Current" sheet — presented as a SwiftUI sheet over the settings window.
        .sheet(isPresented: $isShowingSaveSheet) {
            saveProfileSheet
        }
    }

    private func profileRow(_ profile: VoiceProfile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(profile.preset.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("呼び出す") {
                audioModel.applyProfile(profile)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            Button {
                renameTargetID = profile.id
                renameText = profile.name
            } label: {
                Image(systemName: "pencil")
            }
            .controlSize(.small)
            .help("このプロファイルの名前を変更")
            .popover(isPresented: Binding(
                get: { renameTargetID == profile.id },
                set: { if !$0 { renameTargetID = nil } }
            )) {
                renamePopover(for: profile)
            }

            Button(role: .destructive) {
                audioModel.deleteProfile(id: profile.id)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("このプロファイルを削除")
        }
    }

    private var saveProfileSheet: some View {
        VStack(spacing: 16) {
            Text("プロファイルを保存")
                .font(.headline)
            Text("現在の設定のスナップショットに名前を付けてください。")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("プロファイル名", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
                .onSubmit { commitSave() }
            HStack {
                Button("キャンセル") { isShowingSaveSheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { commitSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }

    private func renamePopover(for profile: VoiceProfile) -> some View {
        HStack(spacing: 8) {
            TextField("新しい名前", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160)
                .onSubmit { commitRename(id: profile.id) }
            Button("OK") { commitRename(id: profile.id) }
                .controlSize(.small)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    private func commitSave() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        audioModel.saveCurrentAsProfile(name: trimmed)
        isShowingSaveSheet = false
    }

    private func commitRename(id: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        audioModel.renameProfile(id: id, to: trimmed)
        renameTargetID = nil
    }

    // MARK: Output gain

    private var gainCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("出力音量", systemImage: "speaker.wave.2.fill")
                Spacer()
                Text("\(Int(audioModel.outputGainValue * 100))%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundColor(.secondary).font(.caption)
                Slider(value: $audioModel.outputGainValue, in: 0.5...4.0).tint(.accentColor)
                Image(systemName: "speaker.wave.3.fill").foregroundColor(.secondary).font(.caption)
            }

            Text("ノイズ除去で声が小さくなったときに音量を持ち上げます。")
                .font(.caption)
                .foregroundColor(.secondary)

            if meterModel.isOutputClipping {
                Label("出力が音割れしています", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("100%に戻す") {
                    withAnimation { audioModel.outputGainValue = 1.0 }
                }
                .controlSize(.small)
            }
        }
        .nnCard()
    }

    // MARK: Clean Incoming / Guest

    private var incomingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("相手の音声もクリアに（全システム）", systemImage: "person.wave.2.fill")

            Toggle(isOn: $audioModel.incomingCleanupEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("相手側の音声をノイズ除去").font(.subheadline)
                    Text("聞こえてくる音声（通話相手やゲスト）のノイズを除去します。NoNoise以外の全システム音声を取り込んでクリアにし、いまの出力先へ再生します。追加設定は不要です。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!audioModel.isIncomingCleanupAvailable)

            if let caption = incomingStatusCaption {
                Label(caption, systemImage: incomingStatusIcon)
                    .font(.caption).foregroundColor(incomingStatusColor)
            }
        }
        .nnCard()
    }

    /// Status line driven by the never-lying `incomingCleanupStatus` (not the raw persisted flag).
    private var incomingStatusCaption: String? {
        switch audioModel.incomingCleanupStatus {
        case .unavailable: return "macOS 14.4以降が必要です"
        case .off:         return nil
        case .cleaning:    return "受信音声をすべてノイズ除去中"
        case .failed:      return "開始できませんでした — システム設定 ▸ プライバシーとセキュリティ で音声キャプチャを許可してください"
        }
    }

    private var incomingStatusIcon: String {
        switch audioModel.incomingCleanupStatus {
        case .cleaning:    return "checkmark.circle.fill"
        case .failed:      return "exclamationmark.triangle.fill"
        default:           return "info.circle"
        }
    }

    private var incomingStatusColor: Color {
        switch audioModel.incomingCleanupStatus {
        case .failed: return .orange
        default:      return .secondary
        }
    }

    // MARK: Loudness (LUFS) + normalization

    private var loudnessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("ラウドネス", systemImage: "speaker.wave.2.circle.fill")
                Spacer()
                Text(meterModel.integratedLUFS <= LoudnessMeter.silenceLUFS + 1
                     ? "— LUFS" : String(format: "%.1f LUFS", meterModel.integratedLUFS))
                    .font(.callout).monospacedDigit().foregroundColor(.secondary)
            }
            Toggle(isOn: $audioModel.loudnessNormEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("音量の自動統一").font(.subheadline)
                    Text("目標レベルに向けて音量をゆるやかに調整し、通話や録音のたびに音量がばらつくのを防ぎます。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            Picker("目標", selection: $audioModel.loudnessTargetLUFS) {
                Text("−14 LUFS (YouTube / Spotify)").tag(Float(-14))
                Text("−16 LUFS (Apple Podcasts)").tag(Float(-16))
            }
            .pickerStyle(.menu)
            .disabled(!audioModel.loudnessNormEnabled)
            Text("音割れ防止: リミッターが出力をクリップ直前（約 −1 dBFS）で抑えます。ラウドネスはK特性（ITU-R BS.1770）、ピークはサンプルピーク値です。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .nnCard()
    }

    private var resetCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                sectionHeader("設定をリセット", systemImage: "arrow.counterclockwise")
                Text("音声・デバイス設定を初期値に戻します。設定プロファイルとホットキーは残ります。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                isShowingResetConfirmation = true
            } label: {
                Label("リセット", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.small)
        }
        .nnCard()
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundColor(.secondary)
            Text("NoNoise Mac v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") • Built with DeepFilterNet")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Link(destination: SupportLinks.reportIssueOrFeature) {
                Label("不具合を報告", systemImage: "exclamationmark.bubble")
            }
            .controlSize(.small)
            Button {
                updaterController.checkForUpdates()
            } label: {
                Label("アップデートを確認", systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
            .disabled(!updaterController.canCheckForUpdates)
        }
        .padding(.top, 2)
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline)
            .fontWeight(.semibold)
    }

    private func sliderRow<Control: View>(
        title: String, value: String, help: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(value)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            control()
            Text(help).font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - Hotkey Settings

struct HotkeySettingsView: View {
    @ObservedObject var manager: HotkeyManager
    @State private var rebindingAction: HotkeyActionID?

    private let actionLabels: [(HotkeyActionID, String)] = [
        (.toggleAI,        "ノイズ除去のON/OFF"),
        (.bypassMomentary, "A/B聴き比べ（押している間だけ元音声）"),
        (.bypassToggle,    "A/B聴き比べ（切り替え）"),
        (.presetNext,      "モード → 次へ"),
        (.presetPrev,      "モード → 前へ"),
        (.clarityNext,     "声のクリア化 → 次のレベル"),
        (.gainUp,          "出力音量 +"),
        (.gainDown,        "出力音量 −"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("グローバルホットキー")
                .font(.title3).fontWeight(.semibold)
                .padding(.bottom, 12)

            ForEach(actionLabels, id: \.0) { (id, label) in
                hotkeyRow(id: id, label: label)
                Divider()
            }

            if !manager.conflictedActions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("一部のホットキーが他のアプリと競合しています。割り当てを変えるか、競合アプリ側のショートカットを変更してください。")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 10)
            }
        }
        .padding()
        .sheet(item: $rebindingAction) { id in
            RebindSheet(actionID: id, manager: manager)
        }
    }

    private func hotkeyRow(id: HotkeyActionID, label: String) -> some View {
        HStack {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            if manager.conflictedActions.contains(id) {
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                    .help("このキー操作は他のアプリが使用中です")
            }
            if let b = manager.bindings[id] {
                Text(hotkeyDisplayString(b))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("—").foregroundColor(.secondary)
            }
            Button("変更") { rebindingAction = id }
                .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private func hotkeyDisplayString(_ b: HotkeyBinding) -> String {
        var s = ""
        // b.modifiers is a plain UInt32 (Core HotkeyModifier bits) — test bits directly.
        let m = b.modifiers
        if m & HotkeyModifier.control.rawValue != 0 { s += "⌃" }
        if m & HotkeyModifier.option.rawValue  != 0 { s += "⌥" }
        if m & HotkeyModifier.shift.rawValue   != 0 { s += "⇧" }
        if m & HotkeyModifier.command.rawValue != 0 { s += "⌘" }
        // Map common kVK codes to printable glyphs (non-exhaustive — covers the default set).
        let keyGlyphs: [UInt32: String] = [
            0x2D: "N", 0x0B: "B", 0x1E: "]", 0x21: "[", 0x08: "C",
            0x18: "=", 0x1B: "-",
        ]
        s += keyGlyphs[b.keyCode] ?? "?\(b.keyCode)"
        return s
    }
}

// HotkeyActionID is declared in Core; add Identifiable conformance here (App-only, for SwiftUI).
extension HotkeyActionID: Identifiable {
    public var id: String { rawValue }
}

// MARK: - Rebind sheet

/// Key-capture sheet: wait for the user to press a key combo, then commit it.
/// Uses an invisible NSView subclass that overrides keyDown to capture the event.
struct RebindSheet: View {
    let actionID: HotkeyActionID
    @ObservedObject var manager: HotkeyManager
    @Environment(\.dismiss) var dismiss
    @State private var capturedBinding: HotkeyBinding?
    @State private var conflict: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Text("新しいキー操作を押してください:")
            Text(actionID.id.replacingOccurrences(of: "mv.hotkey.", with: ""))
                .font(.headline)
            KeyCaptureView { binding in
                capturedBinding = binding
                conflict = false
            }
            .frame(width: 200, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5))
            if let b = capturedBinding {
                Text("新しい割り当て: \(b.encoded)").font(.caption).foregroundColor(.secondary)
            }
            if conflict {
                Text("そのキー操作は他のアプリが使用中です。").foregroundColor(.orange).font(.caption)
            }
            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("保存") {
                    if let b = capturedBinding {
                        let ok = manager.rebind(action: actionID, to: b)
                        if ok { dismiss() } else { conflict = true }
                    }
                }
                .disabled(capturedBinding == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// NSViewRepresentable that captures the next key-down event and reports it
/// as a `HotkeyBinding` via the callback. The view becomes first responder
/// on appear to receive key events without Accessibility permission.
struct KeyCaptureView: NSViewRepresentable {
    var onCapture: (HotkeyBinding) -> Void

    func makeNSView(context: Context) -> _KeyCaptureNSView {
        let v = _KeyCaptureNSView()
        v.onCapture = onCapture
        return v
    }

    func updateNSView(_ nsView: _KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
    }
}

final class _KeyCaptureNSView: NSView {
    var onCapture: ((HotkeyBinding) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Ignore bare modifiers; wait for a real key code.
        guard event.keyCode != 0xFF else { return }
        // Adapt NSEvent.ModifierFlags → plain UInt32 mask at the App boundary. The relevant bits
        // (command/option/shift/control) share the same raw values as Core's HotkeyModifier, so
        // the masked rawValue maps 1:1.
        let masked = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode),
                                    modifiers: UInt32(masked.rawValue))
        onCapture?(binding)
    }
}

// MARK: - Guide Tab

struct GuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("かんたんセットアップ")
                    .font(.headline)
                    .padding(.bottom, 2)

                StepRow(number: 1, title: "NoNoise Mic をインストール",
                        description: "./build-driver.sh → sudo ./install-driver.sh を一度だけ実行します。どのアプリからも選べる仮想マイク「NoNoise Mic」が追加されます（BlackHole不要）。")
                Divider()
                StepRow(number: 2, title: "入力: 実際のマイクを選ぶ",
                        description: "入力デバイスに物理マイク（内蔵マイクやUSBマイク）を選びます。出力は自動です — 処理済み音声は内部の「NoNoise Mic Engine」へ送られるため、出力デバイスを選ぶ必要はありません。")
                Divider()
                StepRow(number: 3, title: "通話アプリで「NoNoise Mic」を選ぶ",
                        description: "Slack・Zoom・Meet・Discord・OBS などのマイク設定で「NoNoise Mic」を選択します。")
                Divider()
                StepRow(number: 4, title: "これで完了",
                        description: "ノイズ除去は起動時からONです。メニューバーからいつでも切り替えられます。")
                Divider()
                StepRow(number: 5, title: "相手の音声もクリアに（任意）",
                        description: "聞こえてくる側のノイズも消したい場合は、設定で「相手の音声もクリアに」をONにします。追加の配線は不要です（macOS 14.4以降）。")

                HStack {
                    Spacer()
                    Label("ドライバを入れられない場合の代替: 出力デバイスを「BlackHole 2ch」にし、通話アプリのマイクにも「BlackHole 2ch」を選びます。",
                          systemImage: "lightbulb.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
            }
            .padding(.trailing)
        }
    }
}

struct StepRow: View {
    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 26, height: 26)
                Text("\(number)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
