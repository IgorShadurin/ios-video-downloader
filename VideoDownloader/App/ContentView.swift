import AVKit
import SwiftUI
import UIKit

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
#if DEBUG
    @State private var isDebugResetDialogPresented = false
#endif
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

                        if viewModel.state != .idle {
                            actionCard
                        }

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
#if DEBUG
        .background(
            DebugShakeDetector {
                if !isDebugResetDialogPresented {
                    isDebugResetDialogPresented = true
                }
            }
        )
        .confirmationDialog(
            "Debug: reset limits?",
            isPresented: $isDebugResetDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                viewModel.debugResetLimitsForTesting()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is available only in Debug builds.")
        }
#endif
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
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
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

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
            ZStack {
                LinearGradient(
                    colors: paywallBackgroundGradientColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 10) {
                            Text("Unlock Unlimited Downloads")
                                .font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(paywallPrimaryTextColor)
                            Text("Get unlimited direct downloads and full hidden vault access.")
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(paywallSecondaryTextColor)
                        }
                        .padding(.top, 8)

                        VStack(spacing: 14) {
                            ForEach(viewModel.plans) { item in
                                paywallPlanCard(
                                    item: item,
                                    isSelected: item.plan == selectedPurchasePlan
                                )
                            }

                            if viewModel.isProductsLoading || viewModel.plans.isEmpty {
                                ProgressView("Loading plans")
                                    .tint(paywallPrimaryTextColor)
                                    .padding(.vertical, 8)
                            }
                        }

                        Button {
                            guard let selectedPaywallOption else {
                                paywallStatus = "No available plans right now."
                                return
                            }

                            Task {
                                isPurchasing = true
                                paywallStatus = await viewModel.purchase(plan: selectedPaywallOption.plan)
                                isPurchasing = false
                            }
                        } label: {
                            HStack(spacing: 12) {
                                if isPurchasing {
                                    ProgressView()
                                        .tint(.white)
                                        .frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                }

                                Text(isPurchasing ? "Processing..." : continueButtonTitle)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)

                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .padding(.horizontal, 18)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0xFE / 255, green: 0x68 / 255, blue: 0x71 / 255),
                                        Color(red: 0xFF / 255, green: 0xA3 / 255, blue: 0x6B / 255)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(paywallCTAStrokeColor, lineWidth: 1)
                            )
                            .shadow(color: paywallCTAShadowColor, radius: 14, x: 0, y: 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            isPurchasing ||
                            selectedPaywallOption == nil
                        )

                        Button {
                            Task {
                                isPurchasing = true
                                paywallStatus = await viewModel.restorePurchases()
                                isPurchasing = false
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.clockwise.circle")
                                    .font(.headline)
                                    .foregroundStyle(paywallPrimaryTextColor)
                                Text("Restore Purchases")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(paywallPrimaryTextColor)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(paywallRestoreFillColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(paywallRestoreStrokeColor, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isPurchasing || viewModel.isRestoringPurchases)

                        if let status = paywallStatus, !status.isEmpty {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(paywallSecondaryTextColor)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }

                        VStack(spacing: 6) {
                            Text("Auto-renewable plans renew unless canceled at least 24 hours before renewal.")
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(paywallTertiaryTextColor)

                            if let manageSubscriptionsURL {
                                Link("You can manage subscriptions in Apple ID settings.", destination: manageSubscriptionsURL)
                                    .font(.caption2.weight(.semibold))
                                    .underline()
                                    .multilineTextAlignment(.center)
                                    .tint(paywallPrimaryTextColor)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 30)
                }
            }
            .onAppear {
                normalizeSelectedPaywallSelection()
            }
            .onChange(of: availablePaywallPlans) { _, _ in
                normalizeSelectedPaywallSelection()
            }
            .navigationTitle("Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.dismissPaywall()
                        paywallStatus = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(paywallSecondaryTextColor)
                    }
                }
            }
        }
    }

    private func normalizeSelectedPaywallSelection() {
        if selectedPaywallOption?.isAvailable == true {
            return
        }
        if let preferredPaywallPlan = preferredPaywallPlan() {
            selectedPurchasePlan = preferredPaywallPlan
        } else if let first = viewModel.plans.first?.plan {
            selectedPurchasePlan = first
        }
    }

    private func preferredPaywallPlan() -> PurchasePlan? {
        if viewModel.plans.first(where: { $0.plan == .monthly })?.isAvailable == true {
            return .monthly
        }
        if viewModel.plans.first(where: { $0.plan == .lifetime })?.isAvailable == true {
            return .lifetime
        }
        if viewModel.plans.first(where: { $0.plan == .weekly })?.isAvailable == true {
            return .weekly
        }

        if viewModel.plans.contains(where: { $0.plan == .monthly }) {
            return .monthly
        }
        if viewModel.plans.contains(where: { $0.plan == .lifetime }) {
            return .lifetime
        }
        if viewModel.plans.contains(where: { $0.plan == .weekly }) {
            return .weekly
        }
        return viewModel.plans.first?.plan
    }

    private var continueButtonTitle: String {
        guard let selectedPaywallOption else {
            return "Continue"
        }
        let price = selectedPaywallOption.displayPrice
        if price.isEmpty || price == "—" {
            return "Continue"
        }
        return "Continue • \(price)"
    }

    private var selectedPaywallOption: PurchasePlanPresentation? {
        viewModel.plans.first(where: { $0.plan == selectedPurchasePlan })
    }

    private var availablePaywallPlans: [PurchasePlan] {
        viewModel.plans.compactMap { $0.isAvailable ? $0.plan : nil }
    }

    private func paywallPlanCard(item: PurchasePlanPresentation, isSelected: Bool) -> some View {
        let accent = paywallAccent(for: item.plan)
        let isAvailable = item.isAvailable
        return Button {
            selectedPurchasePlan = item.plan
            paywallStatus = nil
        } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.plan.title)
                            .font(.headline)
                            .foregroundStyle(paywallPrimaryTextColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .layoutPriority(1)
                        if let badge = paywallBadge(for: item.plan) {
                            paywallBadgeChip(
                                title: badge,
                                fill: accent.opacity(0.9),
                                stroke: Color.white.opacity(0.35),
                                textColor: .white,
                                showsStroke: true
                            )
                        }
                    }

                    Text(item.plan.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(paywallSecondaryTextColor)

                    if !item.displayPrice.isEmpty {
                        Text(item.displayPrice)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(paywallPrimaryTextColor)
                    }
                }

                Spacer()

                if !isAvailable {
                    Text("Unavailable")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(paywallTertiaryTextColor)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(accent)
                } else {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundStyle(paywallSecondaryTextColor.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        isSelected
                            ? accent.opacity(colorScheme == .dark ? 0.2 : 0.16)
                            : paywallCardFillColor
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? accent : paywallCardStrokeColor,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .opacity(isAvailable ? 1 : 0.78)
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
    }

    private func paywallAccent(for plan: PurchasePlan) -> Color {
        switch plan {
        case .weekly:
            return Color(red: 0.27, green: 0.52, blue: 0.98)
        case .monthly:
            return Color(red: 0.62, green: 0.38, blue: 0.96)
        case .lifetime:
            return Color(red: 0.96, green: 0.56, blue: 0.22)
        }
    }

    private func paywallBadge(for plan: PurchasePlan) -> String? {
        switch plan {
        case .monthly:
            return "Most popular"
        case .lifetime:
            return "Best value"
        case .weekly:
            return nil
        }
    }

    private func paywallBadgeChip(
        title: String,
        fill: Color,
        stroke: Color,
        textColor: Color,
        showsStroke: Bool
    ) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(textColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(fill)
            )
            .overlay(
                Capsule()
                    .stroke(stroke, lineWidth: showsStroke ? 1 : 0)
            )
            .fixedSize(horizontal: true, vertical: false)
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

    private var manageSubscriptionsURL: URL? {
        URL(string: "https://apps.apple.com/account/subscriptions")
    }

    private var paywallBackgroundGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.11, green: 0.12, blue: 0.22),
                Color(red: 0.11, green: 0.17, blue: 0.33)
            ]
        }
        return [
            Color(red: 0.96, green: 0.98, blue: 1.0),
            Color(red: 0.90, green: 0.94, blue: 1.0)
        ]
    }

    private var paywallPrimaryTextColor: Color {
        colorScheme == .dark ? .white : Color(uiColor: .label)
    }

    private var paywallSecondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.82) : Color(uiColor: .secondaryLabel)
    }

    private var paywallTertiaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.68) : Color(uiColor: .tertiaryLabel)
    }

    private var paywallCardFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.8)
    }

    private var paywallCardStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
    }

    private var paywallRestoreFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.88)
    }

    private var paywallRestoreStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.12)
    }

    private var paywallCTAStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.1)
    }

    private var paywallCTAShadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.28) : .black.opacity(0.14)
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

#if DEBUG
private struct DebugShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> DebugShakeViewController {
        let controller = DebugShakeViewController()
        controller.onShake = onShake
        return controller
    }

    func updateUIViewController(_ uiViewController: DebugShakeViewController, context: Context) {
        uiViewController.onShake = onShake
    }
}

private final class DebugShakeViewController: UIViewController {
    var onShake: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        resignFirstResponder()
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake else { return }
        onShake?()
    }
}
#endif
