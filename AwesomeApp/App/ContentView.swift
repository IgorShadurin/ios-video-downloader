import AVKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = VideoDownloaderViewModel()
    @State private var selectedVideo: PlayableVideo?
    @State private var renameTitle: String = ""
    @State private var renamingVideo: StoredVideo?
    @State private var showRenameSheet = false
    @State private var selectedPurchasePlan: PurchasePlan = .monthly
    @State private var paywallStatus: String?
    @State private var isPurchasing = false
    @State private var showVaultSheet = false
    @State private var vaultPassword = ""
    @State private var showHidden = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ZStack {
                background

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        inputCard

                        if let errorMessage = viewModel.errorMessage {
                            statusBanner(text: errorMessage, tone: .red)
                        } else {
                            statusBanner(text: viewModel.statusMessage, tone: Color.accentColor)
                        }

                        actionCard

                        if !viewModel.visibleVideos.isEmpty {
                            libraryCard(
                                title: "My Downloads",
                                videos: viewModel.visibleVideos,
                                locked: false
                            )
                        }

                        if viewModel.hasVaultPasscode {
                            vaultControlCard
                        }

                        if showHidden && !viewModel.hiddenVideos.isEmpty {
                            libraryCard(
                                title: "Hidden Videos",
                                videos: viewModel.hiddenVideos,
                                locked: true
                            )
                        }

                        Spacer(minLength: 28)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Video Downloader")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .sheet(item: $selectedVideo) { item in
            VideoPlayer(player: item.player)
                .ignoresSafeArea()
                .onAppear {
                    item.player.play()
                }
                .onDisappear {
                    item.player.pause()
                    item.player.seek(to: .zero)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            selectedVideo = nil
                        }
                    }
                }
        }
        .sheet(isPresented: $showVaultSheet) {
            vaultSheet
        }
        .sheet(isPresented: Binding(
            get: { viewModel.isPaywallPresented },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissPaywall()
                }
            }
        )) {
            paywallSheet
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [surfaceTone(0.95), surfaceTone(0.80)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Video Downloader")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(viewModel.subscriptionText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(secondaryText)
            }
            Spacer()
            Button {
                viewModel.openPaywall()
            } label: {
                Label(viewModel.hasPaidAccess ? "Unlocked" : "Go Pro", systemImage: "crown")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        Capsule().fill(viewModel.hasPaidAccess ? Color.green.opacity(0.22) : accent.opacity(0.18))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Direct Link")
                .font(.headline)

            TextField("https://example.com/video.mp4", text: $viewModel.sourceURLText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .onSubmit {
                    if viewModel.canDownload {
                        Task {
                            await viewModel.downloadVideo()
                        }
                    }
                }

            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(accent)
                Text("Supported: \(viewModel.supportedFormatsText)")
                    .font(.footnote)
                    .foregroundStyle(secondaryText)
                Spacer()
            }

            HStack(spacing: 12) {
                Button {
                    Task {
                        await viewModel.downloadVideo()
                    }
                } label: {
                    Label(viewModel.state == .downloading(progress: 0) ? "Downloading" : "Download", systemImage: "arrow.down.circle.fill")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(accent)
                        )
                        .foregroundStyle(.white)
                }
                .disabled(!viewModel.canDownload || viewModel.isDownloading)

                if viewModel.isDownloading {
                    Button(role: .destructive) {
                        viewModel.cancelDownload()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                            .frame(width: 98, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.red.opacity(0.6))
                            )
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .downloading(let progress) = viewModel.state {
                HStack {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.callout.weight(.semibold))
                }
                .padding(.bottom, 4)

                Text("Downloading directly to local storage.")
                    .font(.footnote)
                    .foregroundStyle(secondaryText)
            } else if case .validating = viewModel.state {
                ProgressView("Validating source")
            } else if case .saving = viewModel.state {
                ProgressView("Finalizing video")
            } else {
                Text("Ready")
                    .font(.callout)
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func libraryCard(title: String, videos: [StoredVideo], locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if locked {
                    Button {
                        showHidden.toggle()
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(videos) { video in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(secondaryBackground)
                            .frame(width: 62, height: 42)
                            .overlay(
                                Image(systemName: "play.rectangle.fill")
                                    .foregroundStyle(.secondary)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(video.title)
                                .font(.subheadline.weight(.bold))
                                .lineLimit(1)
                            Text("\(video.formatLabel) • \(video.resolutionText) • \(video.durationText)")
                                .font(.caption)
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                            Text(video.sizeText)
                                .font(.caption)
                                .foregroundStyle(secondaryText)
                        }

                        Spacer()

                        HStack(spacing: 10) {
                            Button {
                                selectedVideo = PlayableVideo(url: video.localURL)
                            } label: {
                                Image(systemName: "play.circle")
                                    .font(.title2)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                if !locked {
                                    Button("Hide") {
                                        viewModel.hide(video)
                                    }
                                    Button("Rename") {
                                        renamingVideo = video
                                        renameTitle = video.title
                                        showRenameSheet = true
                                    }
                                } else {
                                    Button("Unhide") {
                                        viewModel.unhide(video)
                                    }
                                }
                                Button("Delete", role: .destructive) {
                                    viewModel.delete(video)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title2)
                            }
                        }
                    }

                    Divider()
                        .padding(.leading, 74)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var vaultControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hidden Vault")
                    .font(.headline)
                Spacer()
                Button(viewModel.isVaultUnlocked ? "Lock" : "Open") {
                    if viewModel.isVaultUnlocked {
                        viewModel.lockVault()
                        showHidden = false
                    } else {
                        viewModel.requestUnlockVault()
                        showVaultSheet = true
                    }
                }
                .font(.callout.weight(.semibold))
            }

            if let vaultStatusMessage = viewModel.vaultStatusMessage {
                Text(vaultStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.hiddenVideos.isEmpty {
                Toggle(isOn: $showHidden) {
                    Text("Show hidden videos")
                }
                .onChange(of: showHidden) { _, newValue in
                    if newValue && !viewModel.canShowHidden {
                        showVaultSheet = true
                        showHidden = false
                    }
                }
                .toggleStyle(.switch)
            } else {
                Text("No hidden videos yet.")
                    .font(.footnote)
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var vaultSheet: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(viewModel.hasVaultPasscode ? "Unlock Vault" : "Create Passcode")
                    .font(.headline)
                Text(viewModel.hasVaultPasscode ? "Use your passcode to access hidden videos." : "Set a passcode to protect hidden videos.")
                    .font(.callout)
                    .foregroundStyle(secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                SecureField("Passcode", text: $vaultPassword)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button {
                    viewModel.vaultPasscodeInput = vaultPassword
                    vaultPassword = ""
                    viewModel.submitVaultPasscode()
                    showVaultSheet = false
                } label: {
                    Text(viewModel.hasVaultPasscode ? "Unlock" : "Set Passcode")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Capsule().fill(accent))
                        .foregroundStyle(.white)
                }
                .disabled(vaultPassword.trimmed().isEmpty)
                .padding(.horizontal, 24)

                if viewModel.hasVaultPasscode {
                    Button("Forget Passcode", role: .destructive) {
                        viewModel.clearVaultPasscode()
                        showVaultSheet = false
                    }
                    .font(.callout)
                }

                Spacer()
            }
            .padding(.top, 24)
            .navigationBarTitle("Vault", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        vaultPassword = ""
                        showVaultSheet = false
                    }
                }
            }
        }
    }

    private var renameSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Rename Download")
                    .font(.headline)
                TextField("New name", text: $renameTitle)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                Button("Save") {
                    if let video = renamingVideo {
                        viewModel.rename(video, to: renameTitle)
                    }
                    showRenameSheet = false
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Capsule().fill(accent))
                .foregroundStyle(.white)
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showRenameSheet = false }
                }
            }
        }
    }

    private var paywallSheet: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Upgrade to Remove Limits")
                    .font(.headline)
                Text("Download unlimited videos and keep your vault secure.")
                    .font(.callout)
                    .foregroundStyle(secondaryText)
                    .multilineTextAlignment(.center)

                if viewModel.isProductsLoading {
                    ProgressView("Loading plans")
                } else {
                    ForEach(viewModel.plans) { item in
                        Button {
                            selectedPurchasePlan = item.plan
                        } label: {
                            HStack {
                                Text(item.plan.title)
                                    .font(.headline)
                                Spacer()
                                Text(item.displayPrice)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(selectedPurchasePlan == item.plan ? accent : secondaryText.opacity(0.4))
                            )
                        }
                        .foregroundStyle(selectedPurchasePlan == item.plan ? accent : .primary)
                    }

                    Button {
                        Task {
                            isPurchasing = true
                            let status = await viewModel.purchase(plan: selectedPurchasePlan)
                            paywallStatus = status
                            isPurchasing = false
                        }
                    } label: {
                        HStack {
                            if isPurchasing {
                                ProgressView()
                            }
                            Text("Continue with \(selectedPurchasePlan.title)")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(accent)
                        )
                        .foregroundStyle(.white)
                    }
                    .disabled(viewModel.products[selectedPurchasePlan] == nil || isPurchasing)

                    Button {
                        Task {
                            paywallStatus = await viewModel.restorePurchases()
                        }
                    } label: {
                        Text("Restore Purchases")
                            .font(.callout)
                    }
                    .disabled(isPurchasing || viewModel.isRestoringPurchases)

                    if let status = paywallStatus, !status.isEmpty {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                }

                Spacer()
            }
            .padding(.top, 20)
            .padding(.horizontal, 16)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        viewModel.dismissPaywall()
                        paywallStatus = nil
                    }
                }
            }
        }
    }

    private func statusBanner(text: String, tone: Color) -> some View {
        HStack {
            Image(systemName: "info.circle")
            Text(text)
                .font(.subheadline.weight(.medium))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tone.opacity(0.12))
        )
    }

    private var accent: Color {
        colorScheme == .dark ? .orange : .blue
    }

    private var secondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.72) : .black.opacity(0.64)
    }

    private var secondaryBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var cardBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.55)
    }

    private func surfaceTone(_ opacity: Double) -> Color {
        colorScheme == .dark ? Color(red: 0.08, green: 0.11, blue: 0.18) : Color(red: 0.95, green: 0.96, blue: 1.0)
    }
}

private struct PlayableVideo: Identifiable {
    let id = UUID()
    let player: AVPlayer
    let url: URL

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
    }
}

#Preview {
    ContentView()
}
