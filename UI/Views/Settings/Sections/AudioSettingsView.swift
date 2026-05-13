import SwiftUI
import Shared
import Capture
import App

extension SettingsView {
    @ViewBuilder
    var audioCaptureCard: some View {
        ModernSettingsCard(title: "Audio", icon: "waveform") {
            VStack(alignment: .leading, spacing: 16) {
                ModernToggleRow(
                    title: "Microphone audio",
                    subtitle: "Record microphone audio while recording is active.",
                    isOn: $audioMicrophoneEnabled
                )
                .onChange(of: audioMicrophoneEnabled) { _ in
                    applyAudioCaptureSettings()
                }

                audioInputDevicePickerRow
                    .opacity(audioMicrophoneEnabled ? 1.0 : 0.6)
                    .disabled(!audioMicrophoneEnabled)

                Divider()
                    .background(Color.white.opacity(0.1))

                ModernToggleRow(
                    title: "System audio",
                    subtitle: "Record Mac audio output with ScreenCaptureKit.",
                    isOn: $audioSystemAudioEnabled
                )
                .onChange(of: audioSystemAudioEnabled) { _ in
                    applyAudioCaptureSettings()
                }

                audioSystemAudioExcludedAppsRow
                    .opacity(audioSystemAudioEnabled ? 1.0 : 0.6)
                    .disabled(!audioSystemAudioEnabled)
                    .zIndex(audioExcludedAppsPopoverShown ? 80 : 0)

                ModernToggleRow(
                    title: "Allow system audio during calls",
                    subtitle: "Keep system audio recording on when meeting apps are detected.",
                    isOn: $audioMeetingRecordingConsent,
                    disabled: !audioSystemAudioEnabled
                )
                .opacity(audioSystemAudioEnabled ? 1.0 : 0.6)
                .onChange(of: audioMeetingRecordingConsent) { _ in
                    applyAudioCaptureSettings()
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                whisperModelRow
            }
        }
        .onAppear {
            refreshAudioInputDevices()
            loadAudioFilterApps()
            refreshWhisperModelStatus()
        }
    }

    @ViewBuilder
    var audioInputDevicePickerRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Input device")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                Text("Use a built-in or USB mic instead of a Bluetooth headset mic.")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            Picker("", selection: $audioMicrophoneDeviceUID) {
                Text("System Default").tag("")

                ForEach(availableAudioInputDevices) { device in
                    Text(device.displayName).tag(device.id)
                }

                if selectedAudioInputDeviceIsUnavailable {
                    Text("Unavailable device").tag(audioMicrophoneDeviceUID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
            .onChange(of: audioMicrophoneDeviceUID) { _ in
                applyAudioCaptureSettings()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    var audioSystemAudioExcludedAppsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exclude system audio from")
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ExcludedAppsAddButton(isOpen: audioExcludedAppsPopoverShown) {
                    audioExcludedAppsPopoverShown.toggle()
                }

                ForEach(audioSystemAudioExcludedApps) { app in
                    ExcludedAppChip(app: app) {
                        removeAudioExcludedApp(app)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if audioExcludedAppsPopoverShown {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                audioExcludedAppsPopoverShown = false
                            }

                        AppsFilterPopover(
                            apps: installedAppsForAudioFilter,
                            otherApps: otherAppsForAudioFilter,
                            selectedApps: Set(audioSystemAudioExcludedApps.map(\.bundleID)),
                            filterMode: .include,
                            allowMultiSelect: true,
                            showAllOption: false,
                            onSelectApp: { bundleID in
                                toggleAudioExcludedApp(bundleID)
                            },
                            onFilterModeChange: nil,
                            onDismiss: {
                                audioExcludedAppsPopoverShown = false
                            }
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: 42)
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
                    }
                    .zIndex(120)
                }
            }
            .onExitCommand {
                if audioExcludedAppsPopoverShown {
                    audioExcludedAppsPopoverShown = false
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    var whisperModelRow: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: whisperModelIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(whisperModelIconColor)
                .frame(width: 28, height: 28)
                .background(whisperModelIconColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("Whisper transcription model")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                Text(whisperModelStatusText)
                    .font(.retraceCaption2)
                    .foregroundColor(whisperModelError == nil ? .retraceSecondary : .retraceWarning)
            }

            Spacer()

            if isDownloadingWhisperModel || isRefreshingWhisperModelStatus {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 26, height: 26)
            }

            ModernButton(
                title: whisperModelButtonTitle,
                icon: whisperModelButtonIcon,
                style: whisperModelButtonStyle
            ) {
                if whisperModelStatus?.isValid == true {
                    refreshWhisperModelStatus()
                } else {
                    downloadWhisperModel()
                }
            }
            .disabled(isDownloadingWhisperModel || isRefreshingWhisperModelStatus)
            .opacity((isDownloadingWhisperModel || isRefreshingWhisperModelStatus) ? 0.55 : 1.0)
        }
    }
}

private extension SettingsView {
    var audioSystemAudioExcludedApps: [ExcludedAppInfo] {
        guard let data = audioSystemAudioExcludedAppsRaw.data(using: .utf8),
              let apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) else {
            return []
        }
        return apps
    }

    var selectedAudioInputDeviceIsUnavailable: Bool {
        !audioMicrophoneDeviceUID.isEmpty
            && !availableAudioInputDevices.contains { $0.id == audioMicrophoneDeviceUID }
    }

    var whisperModelStatusText: String {
        if let whisperModelError {
            return whisperModelError
        }

        guard let status = whisperModelStatus else {
            return "Checking local model state..."
        }

        if status.isValid {
            return "Downloaded. Restart Retrace to switch existing mock transcription to Whisper."
        }

        if status.isDownloaded {
            return "Local file is incomplete or invalid. Download again."
        }

        return "\(ModelManager.whisperModel.sizeMB) MB download required for local transcription."
    }

    var whisperModelButtonTitle: String {
        if whisperModelStatus?.isValid == true {
            return "Refresh"
        }
        return isDownloadingWhisperModel ? "Downloading" : "Download"
    }

    var whisperModelButtonIcon: String {
        if whisperModelStatus?.isValid == true {
            return "arrow.clockwise"
        }
        return "arrow.down.circle"
    }

    var whisperModelButtonStyle: ModernButton.ButtonStyleType {
        whisperModelStatus?.isValid == true ? .secondary : .primary
    }

    var whisperModelIcon: String {
        if whisperModelStatus?.isValid == true {
            return "checkmark.circle.fill"
        }
        return "waveform.badge.magnifyingglass"
    }

    var whisperModelIconColor: Color {
        if whisperModelStatus?.isValid == true {
            return .retraceSuccess
        }
        return .retraceAccent
    }

    func applyAudioCaptureSettings() {
        let config = AudioCaptureSettings.config(from: settingsStore)

        Task {
            do {
                try await coordinatorWrapper.coordinator.updateAudioCaptureConfig(config)
                await MainActor.run {
                    showSettingsToast(
                        config.hasEnabledSources ? "Audio settings updated" : "Audio capture disabled"
                    )
                }
            } catch {
                await MainActor.run {
                    showSettingsToast("Audio settings failed: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    func refreshAudioInputDevices() {
        availableAudioInputDevices = AudioInputDeviceProvider.availableInputDevices()
    }

    func loadAudioFilterApps() {
        Task {
            let installed = await Task.detached(priority: .utility) {
                AppNameResolver.shared.getInstalledApps()
                    .map { (bundleID: $0.bundleID, name: $0.name) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }.value

            let installedBundleIDs = Set(installed.map(\.bundleID))
            await MainActor.run {
                installedAppsForAudioFilter = installed
            }

            do {
                let historyBundleIDs = try await coordinatorWrapper.coordinator.getDistinctAppBundleIDs()
                let otherBundleIDs = historyBundleIDs.filter { !installedBundleIDs.contains($0) }
                let resolvedApps = await Task.detached(priority: .utility) {
                    AppNameResolver.shared.resolveAll(bundleIDs: otherBundleIDs)
                        .map { (bundleID: $0.bundleID, name: $0.name) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }.value

                await MainActor.run {
                    otherAppsForAudioFilter = resolvedApps
                }
            } catch {
                Log.error("[SettingsView] Failed to load apps for audio filtering: \(error)", category: .ui)
            }
        }
    }

    func toggleAudioExcludedApp(_ bundleID: String?) {
        guard let bundleID else { return }

        var apps = audioSystemAudioExcludedApps
        if let index = apps.firstIndex(where: { $0.bundleID == bundleID }) {
            apps.remove(at: index)
        } else {
            let name =
                installedAppsForAudioFilter.first(where: { $0.bundleID == bundleID })?.name ??
                otherAppsForAudioFilter.first(where: { $0.bundleID == bundleID })?.name ??
                bundleID
            apps.append(ExcludedAppInfo(bundleID: bundleID, name: name, iconPath: nil))
        }

        saveAudioExcludedApps(apps)
    }

    func removeAudioExcludedApp(_ app: ExcludedAppInfo) {
        var apps = audioSystemAudioExcludedApps
        apps.removeAll { $0.bundleID == app.bundleID }
        saveAudioExcludedApps(apps)
        showSettingsToast("\(app.name) removed")
    }

    func saveAudioExcludedApps(_ apps: [ExcludedAppInfo]) {
        if let data = try? JSONEncoder().encode(apps),
           let string = String(data: data, encoding: .utf8) {
            audioSystemAudioExcludedAppsRaw = string
        } else {
            audioSystemAudioExcludedAppsRaw = SettingsDefaults.audioSystemAudioExcludedApps
        }
        applyAudioCaptureSettings()
        showSettingsToast("Audio app filter updated")
    }

    func refreshWhisperModelStatus() {
        guard !isRefreshingWhisperModelStatus else { return }
        isRefreshingWhisperModelStatus = true

        Task {
            let status = await coordinatorWrapper.coordinator.modelManager.getModelStatus(ModelManager.whisperModel)
            await MainActor.run {
                whisperModelStatus = status
                whisperModelError = nil
                isRefreshingWhisperModelStatus = false
            }
        }
    }

    func downloadWhisperModel() {
        guard !isDownloadingWhisperModel else { return }
        isDownloadingWhisperModel = true
        whisperModelError = nil

        Task {
            do {
                _ = try await coordinatorWrapper.coordinator.modelManager.downloadModel(ModelManager.whisperModel)
                let status = await coordinatorWrapper.coordinator.modelManager.getModelStatus(ModelManager.whisperModel)
                await MainActor.run {
                    whisperModelStatus = status
                    isDownloadingWhisperModel = false
                    showSettingsToast("Whisper model downloaded. Restart Retrace to transcribe new audio.")
                }
            } catch {
                await MainActor.run {
                    whisperModelError = error.localizedDescription
                    isDownloadingWhisperModel = false
                    showSettingsToast("Whisper download failed", isError: true)
                }
            }
        }
    }
}
