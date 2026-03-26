import OmniASRKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var viewModel = TranscriptionViewModel()
    @State private var isErrorBannerVisible = false
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var showCompletionCheckmark = false
    @State private var recordButtonBounce = false
    @State private var completionPulse = false
    @State private var showClearConfirmation = false
    @State private var showCopiedFeedback = false
    @State private var previousState: TranscriptionViewModel.AppState = .idle
    @State private var driftPhase: CGFloat = 0
    @State private var isModelManagerPresented = false

    var body: some View {
        ZStack {
            // Layer 1: Animated radial gradient background
            backgroundGradient
                .ignoresSafeArea()

            // Layer 2: Drifting overlay gradient
            RadialGradient(
                colors: [
                    AppTheme.stateColor(for: viewModel.state).opacity(0.1),
                    .clear
                ],
                center: UnitPoint(
                    x: 0.5 + 0.3 * cos(driftPhase),
                    y: 0.3 + 0.2 * sin(driftPhase * 0.7)
                ),
                startRadius: 50,
                endRadius: 400
            )
            .blendMode(.plusLighter)
            .ignoresSafeArea()

            // Layer 3: Floating particles
            FloatingParticlesView(isActive: viewModel.state == .recording || viewModel.state == .liveRecording || viewModel.state == .transcribing)
                .ignoresSafeArea()

            // Layer 4: Main content
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.top, AppTheme.Spacing.sm)

                // Error banner
                if isErrorBannerVisible, case .error(let msg) = viewModel.state {
                    errorBanner(message: msg)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.top, AppTheme.Spacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                // Transcription or loading or empty state
                transcriptionArea
                    .padding(.horizontal, AppTheme.Spacing.md)

                // Completion toast
                if showCompletionCheckmark {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.indigo)
                        Text("Fertig")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .indigo.opacity(0.2), radius: 4)
                    .shadow(color: .indigo.opacity(0.1), radius: 8)
                    .transition(.scale.combined(with: .opacity))
                    .padding(.top, AppTheme.Spacing.sm)
                }

                Spacer(minLength: 0)

                // Waveform (during recording)
                if viewModel.state == .recording || viewModel.state == .liveRecording {
                    AudioWaveformView(audioLevel: viewModel.audioLevel)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.bottom, AppTheme.Spacing.sm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Control bar
                controlBar
                    .padding(.bottom, AppTheme.Spacing.md)
            }
        }
        .animation(.spring(response: 0.8, dampingFraction: 0.75), value: viewModel.state)
        .sensoryFeedback(.success, trigger: showCompletionCheckmark) { _, newVal in newVal }
        .sensoryFeedback(.warning, trigger: isErrorBannerVisible) { _, newVal in newVal }
        .confirmationDialog("Transkription löschen?", isPresented: $showClearConfirmation) {
            Button("Löschen", role: .destructive) {
                viewModel.clearTranscription()
            }
        }
        .sheet(isPresented: $isModelManagerPresented) {
            ModelManagerSheet(viewModel: viewModel)
        }
        .fileImporter(
            isPresented: $viewModel.isFileImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await viewModel.importAndTranscribe(url: url) }
            case .failure(let error):
                viewModel.state = .error(error.localizedDescription)
            }
        }
        .onChange(of: viewModel.state) { oldState, newState in
            handleStateTransition(from: oldState, to: newState)
        }
        .onAppear {
            // Start drifting animation
            withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                driftPhase = .pi * 2
            }
        }
        .task {
            await viewModel.discoverModels()
            if let selectedId = viewModel.selectedModelId,
               let model = viewModel.availableModels.first(where: { $0.id == selectedId }),
               viewModel.isModelAvailableLocally(model) {
                await viewModel.loadModel()
            }
        }
    }

    // MARK: - State Transitions

    private func handleStateTransition(from oldState: TranscriptionViewModel.AppState, to newState: TranscriptionViewModel.AppState) {
        // Error banner
        if case .error = newState {
            withAnimation { isErrorBannerVisible = true }
            errorDismissTask?.cancel()
            errorDismissTask = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation { isErrorBannerVisible = false }
            }
        } else {
            withAnimation { isErrorBannerVisible = false }
            errorDismissTask?.cancel()
        }

        // Completion checkmark: transcribing → ready
        if oldState == .transcribing && newState == .ready {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                showCompletionCheckmark = true
                completionPulse = true
            }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { showCompletionCheckmark = false }
                completionPulse = false
            }
        }

        // Record button bounce: loadingModel → ready
        if oldState == .loadingModel && newState == .ready {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                recordButtonBounce = true
            }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation { recordButtonBounce = false }
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        let colors = AppTheme.stateGradientColors(for: viewModel.state)
        return RadialGradient(
            colors: colors + [Color(.systemBackground)],
            center: .top,
            startRadius: 100,
            endRadius: 600
        )
    }

    // MARK: - Error Banner

    private func errorBanner(message: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer()
            Button {
                withAnimation { isErrorBannerVisible = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(AppTheme.Spacing.xs)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(.red.gradient, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            modelPicker
            Spacer()
            statusView
            Spacer()
            actionButtons
        }
    }

    private var statusView: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if viewModel.state == .transcribing {
                let progress = viewModel.transcriptionProgress > 0 ? viewModel.transcriptionProgress : nil
                StatusRingView(progress: progress, color: .orange)
            } else if viewModel.state == .liveRecording {
                StatusRingView(progress: nil, color: .teal)
            }

            Text(statusText)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle: "Kein Modell geladen"
        case .loadingModel: ""
        case .ready: "Bereit"
        case .recording: "Aufnahme…"
        case .liveRecording: "Live-Transkription…"
        case .transcribing: "Transkribiere…"
        case .error(let msg): msg
        }
    }

    // MARK: - Model Picker

    private var modelPicker: some View {
        Button {
            isModelManagerPresented = true
        } label: {
            HStack(spacing: 6) {
                // Status dot
                Circle()
                    .fill(modelStatusDotColor)
                    .frame(width: 8, height: 8)
                    .overlay {
                        if viewModel.state == .loadingModel {
                            Circle()
                                .fill(modelStatusDotColor.opacity(0.5))
                                .frame(width: 8, height: 8)
                                .scaleEffect(1.8)
                                .opacity(0.5)
                                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: viewModel.state)
                        }
                    }

                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .medium))
                if let model = viewModel.availableModels.first(where: { $0.id == viewModel.selectedModelId }) {
                    Text(model.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var modelStatusDotColor: Color {
        switch viewModel.state {
        case .idle: .gray
        case .loadingModel: .orange
        case .ready, .recording, .liveRecording, .transcribing: .green
        case .error: .red
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button {
                UIPasteboard.general.string = viewModel.transcription
                withAnimation { showCopiedFeedback = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation { showCopiedFeedback = false }
                }
            } label: {
                Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(showCopiedFeedback ? .green : .primary)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(8)
            }
            .disabled(viewModel.transcription.isEmpty)

            Button {
                showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .padding(8)
            }
            .disabled(viewModel.transcription.isEmpty)
        }
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Transcription Area

    private var transcriptionArea: some View {
        Group {
            if viewModel.state == .loadingModel && viewModel.transcription.isEmpty {
                modelLoadingView
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            } else if viewModel.transcription.isEmpty {
                EmptyStateView()
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            } else {
                TranscriptionCardView(
                    confirmedText: viewModel.state == .liveRecording ? viewModel.frozenTranscription : viewModel.transcription,
                    liveText: viewModel.state == .liveRecording ? viewModel.liveTranscription : "",
                    isTranscribing: viewModel.state == .transcribing || viewModel.state == .liveRecording,
                    accentColor: viewModel.state == .transcribing ? .orange
                               : viewModel.state == .liveRecording ? .teal
                               : .clear,
                    wordCount: viewModel.transcription.split(separator: " ").count,
                    charCount: viewModel.transcription.count
                )
                .scaleEffect(completionPulse ? 1.02 : 1.0)
                .gesture(
                    DragGesture(minimumDistance: 50)
                        .onEnded { value in
                            if value.translation.height > 50 {
                                showClearConfirmation = true
                            }
                        }
                )
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
    }

    // MARK: - Model Loading View

    private var modelLoadingView: some View {
        let isCompiling = viewModel.modelLoadProgress == 0
        let progress = viewModel.modelLoadProgress

        return VStack(spacing: AppTheme.Spacing.lg) {
            // Ring + Icon
            ZStack {
                // Ring background track
                Circle()
                    .stroke(Color.indigo.opacity(0.1), lineWidth: 4)
                    .frame(width: 100, height: 100)

                if isCompiling {
                    // Indeterminate comet-tail ring
                    CometRing(color: .indigo)
                        .frame(width: 100, height: 100)

                    // Orbiting dots
                    OrbitingDots(color: .indigo)
                        .frame(width: 120, height: 120)
                        .transition(.opacity)
                } else {
                    // Determinate progress ring
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            Color.indigo,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }

                // Center: CPU icon + optional percent
                VStack(spacing: 2) {
                    Image(systemName: "cpu")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(.indigo)
                        .symbolEffect(.pulse.byLayer, isActive: isCompiling)

                    if !isCompiling {
                        Text("\(Int(progress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .fontWeight(.medium)
                            .foregroundStyle(.indigo)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .shadow(color: .indigo.opacity(0.25), radius: 16)
            .animation(.spring(response: 0.5), value: isCompiling)

            // Model name + step list
            VStack(spacing: AppTheme.Spacing.sm) {
                if let model = viewModel.availableModels.first(where: { $0.id == viewModel.selectedModelId }) {
                    Text(model.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    loadingStep(
                        "Modell laden",
                        isActive: false,
                        isCompleted: true
                    )
                    loadingStep(
                        "Neural Engine kompilieren",
                        isActive: isCompiling,
                        isCompleted: !isCompiling
                    )
                    loadingStep(
                        "Aufwärmen",
                        isActive: !isCompiling,
                        isCompleted: false
                    )
                }
            }
        }
        .padding(AppTheme.Spacing.xxl)
        .glassCard()
    }

    @ViewBuilder
    private func loadingStep(_ title: String, isActive: Bool, isCompleted: Bool) -> some View {
        HStack(spacing: 8) {
            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if isActive {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            } else {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
            }

            Text(title)
                .font(.caption)
                .foregroundStyle(isActive ? .primary : (isCompleted ? .secondary : .tertiary))
                .fontWeight(isActive ? .medium : .regular)
        }
        .animation(.easeInOut(duration: 0.3), value: isActive)
        .animation(.easeInOut(duration: 0.3), value: isCompleted)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 0) {
            // File import button
            VStack(spacing: AppTheme.Spacing.xs) {
                Button {
                    viewModel.isFileImporterPresented = true
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(viewModel.state != .ready)
                .opacity(viewModel.state == .ready ? 1 : 0.4)

                Text("Import")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Record button
            VStack(spacing: AppTheme.Spacing.xs) {
                RecordButton(
                    isRecording: viewModel.state == .recording,
                    isReady: viewModel.state == .ready,
                    audioLevel: viewModel.audioLevel,
                    isDisabled: !canToggleRecording
                ) {
                    Task { await viewModel.toggleRecording() }
                }
                .scaleEffect(recordButtonBounce ? 1.15 : 1.0)

                Text(viewModel.state == .recording ? "Stop" : "Aufnahme")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Live recording button
            VStack(spacing: AppTheme.Spacing.xs) {
                Button {
                    Task { await viewModel.toggleLiveRecording() }
                } label: {
                    Image(systemName: viewModel.state == .liveRecording ? "waveform.badge.mic" : "waveform")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(viewModel.state == .liveRecording ? .white : .primary)
                        .frame(width: 48, height: 48)
                        .background(
                            viewModel.state == .liveRecording
                                ? AnyShapeStyle(.teal.gradient)
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Circle()
                        )
                }
                .disabled(!canToggleLive)
                .opacity(canToggleLive ? 1 : 0.4)

                Text(viewModel.state == .liveRecording ? "Stop" : "Live")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Compute unit picker
            VStack(spacing: AppTheme.Spacing.xs) {
                computeUnitPicker

                Text("Compute")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 32)
    }

    private var canToggleRecording: Bool {
        viewModel.state == .ready || viewModel.state == .recording
    }

    private var canToggleLive: Bool {
        viewModel.state == .ready || viewModel.state == .liveRecording
    }

    private var computeUnitPicker: some View {
        Menu {
            ForEach(CoreMLASRService.ComputeUnitOption.allCases) { option in
                Button {
                    viewModel.selectedComputeUnits = option
                    Task { await viewModel.loadModel() }
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if option == viewModel.selectedComputeUnits {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "bolt.horizontal")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

// MARK: - Comet Ring (indeterminate spinning arc)

private struct CometRing: View {
    let color: Color
    @State private var rotation: Angle = .zero

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.3)
            .stroke(
                AngularGradient(
                    colors: [color.opacity(0), color],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 4, lineCap: .round)
            )
            .rotationEffect(rotation)
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    rotation = .degrees(360)
                }
            }
    }
}

// MARK: - Orbiting Dots (compilation phase decoration)

private struct OrbitingDots: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2

                for i in 0..<3 {
                    let phase = Double(i) * (.pi * 2 / 3)
                    let speed = 1.2 + Double(i) * 0.15
                    let angle = t * speed + phase
                    let x = center.x + cos(angle) * radius
                    let y = center.y + sin(angle) * radius
                    let opacity = 0.4 + 0.3 * sin(t * 2 + phase)

                    let dotSize: CGFloat = 5 - CGFloat(i)
                    let rect = CGRect(
                        x: x - dotSize / 2,
                        y: y - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(color.opacity(opacity))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
}
