import Foundation
import AVFoundation
import Shared

/// Main coordinator for audio capture with dual-pipeline architecture
/// Pipeline A: Microphone (with Voice Isolation)
/// Pipeline B: System Audio (privacy-aware, auto-muted during meetings)
public actor AudioCaptureManager: AudioCaptureProtocol {

    // Pipelines
    private let microphoneCapture: MicrophoneAudioCapture
    private let systemAudioCapture: SystemAudioCapture
    private let meetingDetector: MeetingDetector

    // State
    private var config: AudioCaptureConfig
    public private(set) var isCapturing: Bool = false
    private var activeSources: Set<ActiveAudioSource> = []
    private var currentMeetingState: MeetingState = .notInMeeting

    // Statistics
    private var statistics = AudioCaptureStatistics(
        microphoneSamplesRecorded: 0,
        systemAudioSamplesRecorded: 0,
        microphoneDurationSeconds: 0,
        systemAudioDurationSeconds: 0,
        captureStartTime: nil,
        lastSampleTime: nil,
        meetingDetectedCount: 0,
        autoMuteCount: 0
    )

    // Combined audio stream
    private var audioContinuation: AsyncStream<CapturedAudio>.Continuation?
    private var _audioStream: AsyncStream<CapturedAudio>?

    public init(config: AudioCaptureConfig = .default) {
        self.config = config
        self.microphoneCapture = MicrophoneAudioCapture(config: config)
        self.systemAudioCapture = SystemAudioCapture(config: config)
        self.meetingDetector = MeetingDetector()
    }

    // MARK: - AudioCaptureProtocol Implementation

    public func hasMicrophonePermission() async -> Bool {
        return await microphoneCapture.hasPermission()
    }

    public func requestMicrophonePermission() async -> Bool {
        return await microphoneCapture.requestPermission()
    }

    public func startCapture(config: AudioCaptureConfig) async throws {
        guard !isCapturing else { return }

        self.config = config
        activeSources.removeAll()
        try await microphoneCapture.updateConfig(config)
        try await systemAudioCapture.updateConfig(config)

        // Create combined audio stream
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        self._audioStream = stream
        self.audioContinuation = continuation

        // Start meeting detection
        await meetingDetector.startMonitoring(bundleIDs: config.meetingAppBundleIDs)
        await meetingDetector.onStateChange { [weak self] state in
            Task {
                await self?.handleMeetingStateChange(state)
            }
        }

        var startupErrors: [Error] = []

        // Start microphone capture if enabled
        if config.microphoneEnabled {
            do {
                try await microphoneCapture.startCapture()
                activeSources.insert(.microphone)
                Log.info("[AudioCaptureManager] Microphone capture started")
                Task {
                    await streamMicrophoneAudio()
                }
            } catch {
                startupErrors.append(error)
                Log.warning("[AudioCaptureManager] Microphone capture failed to start: \(error)")
            }
        }

        // Start system audio capture if enabled
        if config.systemAudioEnabled {
            do {
                try await systemAudioCapture.startCapture()
                activeSources.insert(.systemAudio)
                Log.info("[AudioCaptureManager] System audio capture started")

                // Apply initial mute state based on current meeting state
                let currentState = await meetingDetector.getCurrentState()
                await updateSystemAudioMuteState(meetingState: currentState)

                Task {
                    await streamSystemAudio()
                }
            } catch {
                startupErrors.append(error)
                Log.warning("[AudioCaptureManager] System audio capture failed to start: \(error)")
            }
        }

        guard !activeSources.isEmpty else {
            await cleanupFailedStartup()
            throw startupErrors.first ?? AudioCaptureError.invalidConfiguration("No audio capture sources are enabled.")
        }

        isCapturing = true
        if !startupErrors.isEmpty {
            Log.warning("[AudioCaptureManager] Audio capture started with one or more disabled sources")
        }
        statistics = AudioCaptureStatistics(
            microphoneSamplesRecorded: 0,
            systemAudioSamplesRecorded: 0,
            microphoneDurationSeconds: 0,
            systemAudioDurationSeconds: 0,
            captureStartTime: Date(),
            lastSampleTime: nil,
            meetingDetectedCount: 0,
            autoMuteCount: 0
        )
    }

    public func stopCapture() async throws {
        guard isCapturing || !activeSources.isEmpty else { return }

        await microphoneCapture.stopCapture()
        try await systemAudioCapture.stopCapture()
        await meetingDetector.stopMonitoring()

        isCapturing = false
        activeSources.removeAll()
        audioContinuation?.finish()
        audioContinuation = nil
        _audioStream = nil
    }

    public var audioStream: AsyncStream<CapturedAudio> {
        if let stream = _audioStream {
            return stream
        }

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        self._audioStream = stream
        self.audioContinuation = continuation
        return stream
    }

    public func updateConfig(_ config: AudioCaptureConfig) async throws {
        let wasCapturing = isCapturing

        if wasCapturing {
            try await stopCapture()
        }

        self.config = config
        try await microphoneCapture.updateConfig(config)
        try await systemAudioCapture.updateConfig(config)

        if wasCapturing {
            try await startCapture(config: config)
        }
    }

    public func getConfig() async -> AudioCaptureConfig {
        return config
    }

    public func getMeetingState() async -> MeetingState {
        return currentMeetingState
    }

    public func setSystemAudioMuted(_ muted: Bool) async {
        await systemAudioCapture.setMuted(muted)
    }

    public func isSystemAudioMuted() async -> Bool {
        return await systemAudioCapture.getMuted()
    }

    public func getStatistics() async -> AudioCaptureStatistics {
        return statistics
    }

    // MARK: - Private Stream Merging

    private func streamMicrophoneAudio() async {
        let stream = await microphoneCapture.audioStream

        for await audio in stream {
            audioContinuation?.yield(audio)

            // Update statistics
            statistics = AudioCaptureStatistics(
                microphoneSamplesRecorded: statistics.microphoneSamplesRecorded + 1,
                systemAudioSamplesRecorded: statistics.systemAudioSamplesRecorded,
                microphoneDurationSeconds: statistics.microphoneDurationSeconds + audio.duration,
                systemAudioDurationSeconds: statistics.systemAudioDurationSeconds,
                captureStartTime: statistics.captureStartTime,
                lastSampleTime: Date(),
                meetingDetectedCount: statistics.meetingDetectedCount,
                autoMuteCount: statistics.autoMuteCount
            )
        }
    }

    private func streamSystemAudio() async {
        let stream = await systemAudioCapture.audioStream

        for await audio in stream {
            audioContinuation?.yield(audio)

            // Update statistics
            statistics = AudioCaptureStatistics(
                microphoneSamplesRecorded: statistics.microphoneSamplesRecorded,
                systemAudioSamplesRecorded: statistics.systemAudioSamplesRecorded + 1,
                microphoneDurationSeconds: statistics.microphoneDurationSeconds,
                systemAudioDurationSeconds: statistics.systemAudioDurationSeconds + audio.duration,
                captureStartTime: statistics.captureStartTime,
                lastSampleTime: Date(),
                meetingDetectedCount: statistics.meetingDetectedCount,
                autoMuteCount: statistics.autoMuteCount
            )
        }
    }

    private func cleanupFailedStartup() async {
        await microphoneCapture.stopCapture()
        try? await systemAudioCapture.stopCapture()
        await meetingDetector.stopMonitoring()
        isCapturing = false
        activeSources.removeAll()
        audioContinuation?.finish()
        audioContinuation = nil
        _audioStream = nil
    }

    // MARK: - Privacy-Aware Muting Logic

    /// Handle meeting state changes and apply automatic muting logic
    private func handleMeetingStateChange(_ state: MeetingState) async {
        currentMeetingState = state

        // Update statistics
        if state.isInMeeting {
            statistics = AudioCaptureStatistics(
                microphoneSamplesRecorded: statistics.microphoneSamplesRecorded,
                systemAudioSamplesRecorded: statistics.systemAudioSamplesRecorded,
                microphoneDurationSeconds: statistics.microphoneDurationSeconds,
                systemAudioDurationSeconds: statistics.systemAudioDurationSeconds,
                captureStartTime: statistics.captureStartTime,
                lastSampleTime: statistics.lastSampleTime,
                meetingDetectedCount: statistics.meetingDetectedCount + 1,
                autoMuteCount: statistics.autoMuteCount
            )
        }

        await updateSystemAudioMuteState(meetingState: state)
    }

    /// Update system audio mute state based on meeting state and user consent
    /// PRIVACY LOGIC:
    /// - IF in meeting AND no consent: MUTE system audio
    /// - IF in meeting AND has consent: ALLOW system audio
    /// - IF not in meeting: ALLOW system audio
    private func updateSystemAudioMuteState(meetingState: MeetingState) async {
        let shouldMute: Bool

        if meetingState.isInMeeting {
            // In a meeting - check consent
            if config.hasConsentedToMeetingRecording {
                // User has explicitly consented to recording during meetings
                shouldMute = false
            } else {
                // No consent - automatically mute to protect privacy
                shouldMute = true

                // Update auto-mute count
                statistics = AudioCaptureStatistics(
                    microphoneSamplesRecorded: statistics.microphoneSamplesRecorded,
                    systemAudioSamplesRecorded: statistics.systemAudioSamplesRecorded,
                    microphoneDurationSeconds: statistics.microphoneDurationSeconds,
                    systemAudioDurationSeconds: statistics.systemAudioDurationSeconds,
                    captureStartTime: statistics.captureStartTime,
                    lastSampleTime: statistics.lastSampleTime,
                    meetingDetectedCount: statistics.meetingDetectedCount,
                    autoMuteCount: statistics.autoMuteCount + 1
                )
            }
        } else {
            // Not in a meeting - allow system audio
            shouldMute = false
        }

        await systemAudioCapture.setMuted(shouldMute)
    }
}

// MARK: - Validation & Debugging

extension AudioCaptureManager {

    /// Verify Voice Processing is enabled on microphone
    public func isVoiceProcessingEnabled() async -> Bool {
        return await microphoneCapture.isVoiceProcessingEnabled()
    }

    /// Get microphone input format
    public func getMicrophoneFormat() async -> (sampleRate: Double, channels: Int) {
        return await microphoneCapture.getInputFormat()
    }

    /// Force a meeting state check (for testing)
    public func checkMeetingStatus() async -> MeetingState {
        return await meetingDetector.getCurrentState()
    }
}

private enum ActiveAudioSource: Hashable, Sendable {
    case microphone
    case systemAudio
}
