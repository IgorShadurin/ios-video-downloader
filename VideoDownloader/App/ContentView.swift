import AVKit
import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    private enum DownloadRightsChoice: Hashable {
        case unanswered
        case yes
        case no
    }

    private struct DownloadRightsFormState {
        var urlText: String = ""
        var requestedURLChoice: DownloadRightsChoice = .unanswered
        var websitePermissionChoice: DownloadRightsChoice = .unanswered
        var ownerApprovalChoice: DownloadRightsChoice = .unanswered

        var hasRejectedAnswer: Bool {
            requestedURLChoice == .no || websitePermissionChoice == .no || ownerApprovalChoice == .no
        }

        var allConfirmed: Bool {
            requestedURLChoice == .yes && websitePermissionChoice == .yes && ownerApprovalChoice == .yes
        }

        var displayURL: String {
            urlText.truncatedForConfirmation(limit: 200)
        }
    }

    private enum LibraryTab {
        case downloads
        case vault
    }

    private enum UIShowcaseStep: String {
        case mainVideos = "main-videos"
        case demoLink = "demo-link"
        case downloadingProcess = "downloading-process"
        case videoMenuOpened = "video-menu-opened"
        case exportMenuOpened = "video-export-opened"
        case renameFile = "rename-file"
        case paywall = "paywall"
        case vaultUnlockModal = "vault-unlock-modal"
        case vaultUnlockedVideos = "vault-unlocked-videos"
    }

    private static let showcaseStepArgument: UIShowcaseStep? = {
        let args = ProcessInfo.processInfo.arguments
        guard let keyIndex = args.firstIndex(of: "-uiShowcaseStep") else {
            return nil
        }
        let valueIndex = args.index(after: keyIndex)
        guard valueIndex < args.endIndex else {
            return nil
        }
        return UIShowcaseStep(rawValue: args[valueIndex].lowercased())
    }()

    @StateObject private var viewModel = VideoDownloaderViewModel()
    @State private var selectedVideo: PlayableVideo?
    @State private var renameTitle: String = ""
    @State private var renamingVideo: StoredVideo?
    @State private var showRenameSheet = false
    @State private var selectedPaywallPlanID: String?
    @State private var isDownloadRightsSheetPresented = false
    @State private var downloadRightsForm = DownloadRightsFormState()
    @State private var showVaultSheet = false
    @State private var showForgetVaultConfirmation = false
    @State private var filesExportURL: URL?
    @State private var exportAlertMessage: String?
    @State private var videoPendingDeletion: StoredVideo?
    @State private var vaultPassword = ""
    @State private var selectedLibraryTab: LibraryTab = .downloads
    @State private var didApplyShowcaseStep = false
    @State private var showcaseStep: UIShowcaseStep? = Self.showcaseStepArgument
#if DEBUG
    @State private var isDebugResetDialogPresented = false
#endif
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                background

                ScrollView {
                    VStack(spacing: 18) {
                        inputCard

                        if let errorMessage = viewModel.errorMessage {
                            statusBanner(text: errorMessage, tone: .red)
                        }

                        if viewModel.state != .idle {
                            actionCard
                        }

                        downloadsSection

                        if viewModel.hasPaidAccess {
                            manageSubscriptionsInlineButton
                        }

                        Spacer(minLength: 28)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                showcaseMenuOverlay
            }
            .navigationTitle(L10n.tr("Download Video"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            applyShowcaseStepIfNeeded()
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .sheet(isPresented: $isDownloadRightsSheetPresented) {
            downloadRightsSheet
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
                        Button(L10n.tr("Done")) {
                            selectedVideo = nil
                        }
                    }
                }
        }
        .sheet(isPresented: $showVaultSheet) {
            vaultSheet
        }
        .sheet(isPresented: Binding(
            get: { filesExportURL != nil },
            set: { isPresented in
                if !isPresented {
                    filesExportURL = nil
                }
            }
        )) {
            if let filesExportURL {
                FilesExportPicker(url: filesExportURL) { result in
                    switch result {
                    case .success:
                        exportAlertMessage = L10n.tr("Video exported to Files.")
                    case .failure(let error as CocoaError) where error.code == .userCancelled:
                        break
                    case .failure(let error):
                        exportAlertMessage = L10n.fmt("Failed to save to Files: %@", error.localizedDescription)
                    }
                    self.filesExportURL = nil
                }
            }
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
        .alert(L10n.tr("Export"), isPresented: Binding(
            get: { exportAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    exportAlertMessage = nil
                }
            }
        )) {
            Button(L10n.tr("OK"), role: .cancel) {
                exportAlertMessage = nil
            }
        } message: {
            Text(exportAlertMessage ?? "")
        }
        .alert(L10n.tr("Reset vault passcode?"), isPresented: $showForgetVaultConfirmation) {
            Button(role: .destructive) {
                viewModel.clearVaultPasscodeAndDeleteHiddenVideos()
                selectedLibraryTab = .downloads
                vaultPassword = ""
                showVaultSheet = false
            } label: {
                Label(L10n.tr("Reset and Delete"), systemImage: "trash")
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("After reset, all hidden videos will be permanently deleted."))
        }
        .alert(L10n.tr("Delete"), isPresented: Binding(
            get: { videoPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    videoPendingDeletion = nil
                }
            }
        )) {
            Button(L10n.tr("Delete"), role: .destructive) {
                if let videoPendingDeletion {
                    viewModel.delete(videoPendingDeletion)
                }
                videoPendingDeletion = nil
            }
            Button(L10n.tr("Cancel"), role: .cancel) {
                videoPendingDeletion = nil
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background, viewModel.isVaultUnlocked {
                lockVaultAndReturnToDownloads()
            }
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
            L10n.tr("Debug: reset limits?"),
            isPresented: $isDebugResetDialogPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Reset"), role: .destructive) {
                viewModel.debugResetLimitsForTesting()
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("This is available only in Debug builds."))
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

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accent.opacity(0.14))
                    )

                Text(L10n.tr("Source"))
                    .font(.headline)

                Spacer(minLength: 0)

                Button {
                    viewModel.openPaywall()
                } label: {
                    Label(
                        viewModel.hasPaidAccess ? L10n.tr("Unlocked") : L10n.tr("Go Pro"),
                        systemImage: "crown"
                    )
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 17)
                        .background(
                            Capsule().fill(viewModel.hasPaidAccess ? Color.green.opacity(0.22) : accent.opacity(0.18))
                        )
                }
                .buttonStyle(.plain)
            }

            TextField(
                "",
                text: $viewModel.sourceURLText,
                prompt: Text(verbatim: "https://example.com/video.mp4")
                    .foregroundStyle(Color(uiColor: .placeholderText))
            )
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .onSubmit {
                    if viewModel.canDownload {
                        presentDownloadRightsSheet()
                    }
                }
                .autocorrectionDisabled()
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

            Button {
                viewModel.sourceURLText = "https://yumcut.com/download-demo/six-seven-demo.MP4"
            } label: {
                Text(L10n.tr("Use Demo Video URL"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)

            HStack {
                Text(L10n.fmt("Detected: %@", viewModel.supportedFormatsText))
                    .font(.footnote)
                    .foregroundStyle(secondaryText)
                Spacer()
            }

            HStack(spacing: 12) {
                if viewModel.isDownloading {
                    Button(role: .destructive) {
                        viewModel.cancelDownload()
                    } label: {
                        Label(L10n.tr("Cancel"), systemImage: "xmark.circle.fill")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.red.opacity(0.6))
                            )
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        presentDownloadRightsSheet()
                    } label: {
                        Label(L10n.tr("Download"), systemImage: "arrow.down.circle.fill")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(accent)
                            )
                            .foregroundStyle(.white)
                    }
                    .disabled(!viewModel.canDownload)
                }
            }

            Text(L10n.tr("Paste a direct video link and tap Download."))
                .font(.caption)
                .foregroundStyle(secondaryText.opacity(0.88))
                .padding(.leading, 2)
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

                Text(L10n.tr("Processed locally on this device."))
                    .font(.footnote)
                    .foregroundStyle(secondaryText)
            } else if case .validating = viewModel.state {
                ProgressView(L10n.tr("Checking format compatibility..."))
            } else if case .saving = viewModel.state {
                ProgressView(L10n.tr("Converting video..."))
            } else {
                Text(L10n.tr("Ready"))
                    .font(.callout)
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var downloadRightsSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("Before downloading, confirm that you requested this file and have permission to save it from this source."))
                    .font(.footnote)
                    .foregroundStyle(secondaryText)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Requested URL"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)

                    Text(downloadRightsForm.displayURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(secondaryBackground)
                        )
                }

                downloadRightsQuestionRow(
                    title: L10n.tr("You requested this exact URL yourself."),
                    selection: $downloadRightsForm.requestedURLChoice
                )

                downloadRightsQuestionRow(
                    title: L10n.tr("This website allows you to download this file."),
                    selection: $downloadRightsForm.websitePermissionChoice
                )

                downloadRightsQuestionRow(
                    title: L10n.tr("You received approval from the owner of this domain to download this file."),
                    selection: $downloadRightsForm.ownerApprovalChoice
                )

                if downloadRightsForm.hasRejectedAnswer {
                    Text(L10n.tr("You do not have permission to download this file."))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !downloadRightsForm.allConfirmed {
                    Text(L10n.tr("All answers must be Yes to continue."))
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                Button {
                    confirmDownloadRights()
                } label: {
                    Label(L10n.tr("Confirm and Download"), systemImage: "checkmark.shield.fill")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(downloadRightsForm.allConfirmed ? accent : Color.gray.opacity(0.25))
                        )
                        .foregroundStyle(downloadRightsForm.allConfirmed ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!downloadRightsForm.allConfirmed)
            }
            .padding(16)
            .background(background.ignoresSafeArea())
            .navigationTitle(L10n.tr("Confirm Download Rights"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("Cancel")) {
                        isDownloadRightsSheetPresented = false
                    }
                }
            }
        }
        .presentationDetents([.height(500)])
        .presentationDragIndicator(.visible)
    }

    private func downloadRightsQuestionRow(
        title: String,
        selection: Binding<DownloadRightsChoice>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(title, selection: selection) {
                Text(L10n.tr("Yes")).tag(DownloadRightsChoice.yes)
                Text(L10n.tr("No")).tag(DownloadRightsChoice.no)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .tint(accent)
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                libraryTabButton(
                    tab: .downloads,
                    title: L10n.tr("My Downloads"),
                    systemImage: "tray.full.fill"
                )

                libraryTabButton(
                    tab: .vault,
                    title: L10n.tr("Vault"),
                    systemImage: selectedLibraryTab == .vault ? "lock.open.fill" : "lock.fill"
                )
            }

            if selectedLibraryTab == .downloads {
                videoList(videos: viewModel.visibleVideos, isVaultList: false)
            } else if viewModel.canShowHidden {
                vaultTabContent
            }
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func libraryTabButton(tab: LibraryTab, title: String, systemImage: String) -> some View {
        let isSelected = selectedLibraryTab == tab
        return Button {
            if tab == .vault {
                openVaultTab()
            } else {
                selectedLibraryTab = .downloads
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? accent : secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.14) : secondaryBackground.opacity(0.66))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var vaultTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button {
                    lockVaultAndReturnToDownloads()
                } label: {
                    Label(L10n.tr("Lock Vault"), systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(secondaryBackground)
                        )
                        .foregroundStyle(secondaryText)
                }
                .buttonStyle(.plain)
            }

            videoList(videos: viewModel.hiddenVideos, isVaultList: true)
        }
    }

    @ViewBuilder
    private func videoList(videos: [StoredVideo], isVaultList: Bool) -> some View {
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Button {
                                selectedVideo = PlayableVideo(url: video.localURL)
                            } label: {
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
                                }
                            }
                            .buttonStyle(.plain)

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
                                    if !isVaultList {
                                        Button {
                                            viewModel.hide(video)
                                        } label: {
                                            Label(L10n.tr("Hide"), systemImage: "eye.slash")
                                        }
                                        Button {
                                            renamingVideo = video
                                            renameTitle = video.title
                                            showRenameSheet = true
                                        } label: {
                                            Label(L10n.tr("Rename"), systemImage: "pencil")
                                        }
                                    } else {
                                        Button {
                                            viewModel.unhide(video)
                                        } label: {
                                            Label(L10n.tr("Unhide"), systemImage: "eye")
                                        }
                                    }
                                    Menu {
                                        Button {
                                            exportToGallery(video)
                                        } label: {
                                            Label(L10n.tr("Save to Gallery"), systemImage: "photo.on.rectangle")
                                        }

                                        Button {
                                            exportToFiles(video)
                                        } label: {
                                            Label(L10n.tr("Save to Files"), systemImage: "folder")
                                        }
                                    } label: {
                                        Label(L10n.tr("Export"), systemImage: "square.and.arrow.up")
                                    }
                                    Button(role: .destructive) {
                                        videoPendingDeletion = video
                                    } label: {
                                        Label(L10n.tr("Delete"), systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title2)
                                }
                            }
                        }

                        if index < videos.count - 1 {
                            Divider()
                                .padding(.leading, 74)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: isVaultList ? "lock.doc" : "tray")
                    .font(.title3)
                    .foregroundStyle(secondaryText.opacity(0.8))

                Text(L10n.tr("No videos selected yet."))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(secondaryText)

                Text(
                    isVaultList
                        ? L10n.tr("Pick a video from your gallery to start.")
                        : L10n.tr("Paste a direct video link and tap Download.")
                )
                    .font(.footnote)
                    .foregroundStyle(secondaryText.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        }
    }

    @ViewBuilder
    private var showcaseMenuOverlay: some View {
        if let showcaseStep {
            switch showcaseStep {
            case .videoMenuOpened:
                VStack {
                    showcasePrimaryMenuCard(exportExpanded: false)
                        .frame(width: 238)
                    Spacer()
                }
                .padding(.top, 312)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
            case .exportMenuOpened:
                VStack {
                    showcasePrimaryMenuCard(exportExpanded: true)
                        .frame(width: 238)
                    Spacer()
                }
                .padding(.top, 312)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
            default:
                EmptyView()
            }
        }
    }

    private func showcasePrimaryMenuCard(exportExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            showcaseMenuRow(icon: "eye.slash", title: L10n.tr("Hide"))
            showcaseMenuDivider
            showcaseMenuRow(icon: "pencil", title: L10n.tr("Rename"))
            showcaseMenuDivider
            showcaseMenuRow(icon: "arrow.up.right.square", title: L10n.tr("Compress"))
            showcaseMenuDivider
            showcaseMenuRow(
                icon: "square.and.arrow.up",
                title: L10n.tr("Export"),
                trailingSystemImage: exportExpanded ? "chevron.down" : "chevron.right",
                isHighlighted: exportExpanded
            )
            if exportExpanded {
                showcaseMenuDivider
                showcaseMenuRow(
                    icon: "photo.on.rectangle",
                    title: L10n.tr("Save to Gallery"),
                    leadingInset: 18
                )
                showcaseMenuDivider
                showcaseMenuRow(
                    icon: "folder",
                    title: L10n.tr("Save to Files"),
                    leadingInset: 18
                )
            }
            showcaseMenuDivider
            showcaseMenuRow(icon: "trash", title: L10n.tr("Delete"), isDestructive: true)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.16), radius: 12, x: 0, y: 6)
    }

    private func showcaseMenuRow(
        icon: String,
        title: String,
        trailingSystemImage: String? = nil,
        isDestructive: Bool = false,
        isHighlighted: Bool = false,
        leadingInset: CGFloat = 0
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .font(.subheadline.weight(.semibold))

            Text(title)
                .font(.subheadline)

            Spacer(minLength: 8)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
        .foregroundStyle(isDestructive ? Color.red : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .padding(.leading, leadingInset)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHighlighted ? accent.opacity(colorScheme == .dark ? 0.20 : 0.12) : Color.clear)
        )
    }

    private var showcaseMenuDivider: some View {
        Divider()
            .padding(.horizontal, 8)
    }

    private func applyShowcaseStepIfNeeded() {
        guard !didApplyShowcaseStep else { return }
        didApplyShowcaseStep = true
        guard let showcaseStep else { return }

#if DEBUG
        let regularVideos = viewModel.debugMakeShowcaseVideos(totalCount: 5, hiddenCount: 0)
        let mixedVideos = viewModel.debugMakeShowcaseVideos(totalCount: 6, hiddenCount: 3)

        showRenameSheet = false
        showVaultSheet = false
        selectedLibraryTab = .downloads
        vaultPassword = ""

        switch showcaseStep {
        case .mainVideos:
            viewModel.debugApplyShowcase(
                sourceURL: "",
                state: .idle,
                videos: regularVideos,
                hasVaultPasscode: false,
                isVaultUnlocked: false
            )
        case .demoLink:
            viewModel.debugApplyShowcase(
                sourceURL: "https://yumcut.com/download-demo/six-seven-demo.MP4",
                state: .idle,
                videos: regularVideos,
                hasVaultPasscode: false,
                isVaultUnlocked: false
            )
        case .downloadingProcess:
            viewModel.debugApplyShowcase(
                sourceURL: "https://yumcut.com/download-demo/six-seven-demo.MP4",
                state: .downloading(progress: 0.42),
                videos: regularVideos,
                hasVaultPasscode: false,
                isVaultUnlocked: false
            )
        case .videoMenuOpened:
            viewModel.debugApplyShowcase(
                sourceURL: "",
                state: .idle,
                videos: regularVideos,
                hasVaultPasscode: false,
                isVaultUnlocked: false
            )
        case .exportMenuOpened:
            viewModel.debugApplyShowcase(
                sourceURL: "",
                state: .idle,
                videos: regularVideos,
                hasVaultPasscode: false,
                isVaultUnlocked: false
            )
        case .renameFile:
            viewModel.debugApplyShowcase(
                sourceURL: "",
                state: .idle,
                videos: regularVideos,
                hasVaultPasscode: false,
                isVaultUnlocked: false
            )
            if let first = viewModel.visibleVideos.first {
                renamingVideo = first
                renameTitle = first.title
                showRenameSheet = true
            }
        case .paywall:
            viewModel.debugApplyShowcase(
                sourceURL: "",
                state: .idle,
                videos: regularVideos,
                hasVaultPasscode: false,
                isVaultUnlocked: false
            )
            viewModel.debugPresentShowcasePaywall()
            selectedPaywallPlanID = PurchaseManager.monthlyProductID
        case .vaultUnlockModal:
            viewModel.debugApplyShowcase(
                sourceURL: "",
                state: .idle,
                videos: mixedVideos,
                hasVaultPasscode: true,
                isVaultUnlocked: false
            )
            showVaultSheet = true
        case .vaultUnlockedVideos:
            viewModel.debugApplyShowcase(
                sourceURL: "",
                state: .idle,
                videos: mixedVideos,
                hasVaultPasscode: true,
                isVaultUnlocked: true
            )
            selectedLibraryTab = .vault
        }
#else
        self.showcaseStep = nil
#endif
    }

    private func openVaultTab() {
        if viewModel.canShowHidden {
            selectedLibraryTab = .vault
            return
        }

        viewModel.requestUnlockVault()
        showVaultSheet = true
    }

    private func lockVaultAndReturnToDownloads() {
        viewModel.lockVault()
        selectedLibraryTab = .downloads
    }

    private var vaultSheet: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: vaultBackgroundGradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(vaultIconBackground)
                                    .frame(width: 84, height: 84)
                                Image(systemName: viewModel.hasVaultPasscode ? "lock.shield.fill" : "shield.lefthalf.filled.badge.checkmark")
                                    .font(.system(size: 34, weight: .semibold))
                                    .foregroundStyle(vaultIconForeground)
                            }

                            Text(viewModel.hasVaultPasscode ? L10n.tr("Unlock Hidden Vault") : L10n.tr("Create Vault Passcode"))
                                .font(.title3.weight(.bold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(vaultPrimaryText)

                            Text(
                                viewModel.hasVaultPasscode
                                    ? L10n.tr("Enter your passcode to view hidden videos.")
                                    : L10n.tr("Create a passcode to protect hidden videos and unlock private access.")
                            )
                                .font(.subheadline)
                                .foregroundStyle(vaultSecondaryText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }
                        .padding(.top, 8)

                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.tr("Password"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(vaultPrimaryText)

                            HStack(spacing: 10) {
                                Image(systemName: "key.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(vaultSecondaryText)

                                SecureField(L10n.tr("Password"), text: $vaultPassword)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
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

                            if let vaultStatusMessage = viewModel.vaultStatusMessage, !vaultStatusMessage.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text(vaultStatusMessage)
                                }
                                .font(.footnote)
                                .foregroundStyle(Color.red.opacity(0.88))
                            }

                            Button {
                                viewModel.vaultPasscodeInput = vaultPassword
                                viewModel.submitVaultPasscode()

                                if viewModel.canShowHidden {
                                    vaultPassword = ""
                                    selectedLibraryTab = .vault
                                    showVaultSheet = false
                                }
                            } label: {
                                Label(
                                    viewModel.hasVaultPasscode ? L10n.tr("Unlock Vault") : L10n.tr("Set Passcode"),
                                    systemImage: viewModel.hasVaultPasscode ? "lock.open.fill" : "lock.badge.plus"
                                )
                                    .font(.headline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 46)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(accent)
                                    )
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .disabled(vaultPassword.trimmed().count < 4)

                            if viewModel.hasVaultPasscode {
                                Button(role: .destructive) {
                                    showForgetVaultConfirmation = true
                                } label: {
                                    Label(L10n.tr("Reset and Delete"), systemImage: "trash")
                                }
                                .font(.callout)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(vaultCardFillColor)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(vaultCardStrokeColor, lineWidth: 1)
                        )
                        .shadow(color: vaultCardShadowColor, radius: 16, x: 0, y: 10)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle(L10n.tr("Hidden Vault"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("Done")) {
                        vaultPassword = ""
                        showVaultSheet = false
                    }
                }
            }
        }
    }

    private var renameSheet: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        accent.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 18) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(accent)
                        .padding(.top, 6)

                    TextField(
                        "",
                        text: $renameTitle,
                        prompt: Text(L10n.tr("Name"))
                            .foregroundStyle(Color(uiColor: .placeholderText))
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
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

                    Button {
                        if let video = renamingVideo {
                            viewModel.rename(video, to: renameTitle)
                        }
                        showRenameSheet = false
                    } label: {
                        Label(L10n.tr("Save"), systemImage: "checkmark.circle.fill")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(accent)
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(renameTitle.trimmed().isEmpty)
                    .opacity(renameTitle.trimmed().isEmpty ? 0.55 : 1)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            .navigationTitle(L10n.tr("Rename"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("Cancel")) { showRenameSheet = false }
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
                            Text(L10n.tr("Unlock Unlimited Usage"))
                                .font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(paywallPrimaryTextColor)
                        }
                        .padding(.top, 8)

                        VStack(spacing: 14) {
                            ForEach(viewModel.purchaseOptions) { option in
                                paywallPlanCard(
                                    option: option,
                                    isSelected: option.id == selectedPaywallPlanID
                                )
                            }

                            if viewModel.purchaseOptions.isEmpty {
                                ProgressView()
                                    .tint(paywallPrimaryTextColor)
                                    .padding(.vertical, 8)
                            }
                        }

                        Button {
                            guard let selectedPaywallPlanID else { return }
                            Task {
                                await viewModel.purchasePlan(planID: selectedPaywallPlanID)
                            }
                        } label: {
                            Text(viewModel.isPurchasingPlan ? L10n.tr("Processing...") : L10n.tr("Continue"))
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
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
                            viewModel.isPurchasingPlan || selectedPaywallPlanID == nil
                        )

                        Button {
                            Task {
                                await viewModel.restorePurchases()
                            }
                        } label: {
                            Text(L10n.tr("Restore Purchases"))
                                .font(.subheadline.weight(.semibold))
                                .underline()
                                .foregroundStyle(paywallPrimaryTextColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isPurchasingPlan)

                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(Color(uiColor: .systemRed))
                                .multilineTextAlignment(.center)
                        }

                        VStack(spacing: 6) {
                            Text(L10n.tr("Auto-renewable plans renew unless canceled 24 hours before period end."))
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(paywallTertiaryTextColor)
                            HStack(spacing: 14) {
                                if let termsOfUseURL {
                                    Link(L10n.tr("Terms"), destination: termsOfUseURL)
                                }
                                if let privacyPolicyURL {
                                    Link(L10n.tr("Privacy"), destination: privacyPolicyURL)
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .tint(paywallPrimaryTextColor)

                            if let manageSubscriptionsURL {
                                Link(L10n.tr("You can manage subscriptions in Apple ID settings."), destination: manageSubscriptionsURL)
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
            .onChange(of: viewModel.purchaseOptions) { _, _ in
                normalizeSelectedPaywallSelection()
            }
            .navigationTitle(L10n.tr("Premium"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.dismissPaywall()
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
        if let selectedPaywallPlanID,
           viewModel.purchaseOptions.contains(where: { $0.id == selectedPaywallPlanID })
        {
            return
        }
        selectedPaywallPlanID = preferredPaywallPlanID()
    }

    private func preferredPaywallPlanID() -> String? {
        if viewModel.purchaseOptions.contains(where: { $0.id == PurchaseManager.monthlyProductID && $0.isAvailable }) {
            return PurchaseManager.monthlyProductID
        }
        if viewModel.purchaseOptions.contains(where: { $0.id == PurchaseManager.lifetimeProductID && $0.isAvailable }) {
            return PurchaseManager.lifetimeProductID
        }
        if viewModel.purchaseOptions.contains(where: { $0.id == PurchaseManager.weeklyProductID && $0.isAvailable }) {
            return PurchaseManager.weeklyProductID
        }

        if viewModel.purchaseOptions.contains(where: { $0.id == PurchaseManager.monthlyProductID }) {
            return PurchaseManager.monthlyProductID
        }
        if viewModel.purchaseOptions.contains(where: { $0.id == PurchaseManager.lifetimeProductID }) {
            return PurchaseManager.lifetimeProductID
        }
        if viewModel.purchaseOptions.contains(where: { $0.id == PurchaseManager.weeklyProductID }) {
            return PurchaseManager.weeklyProductID
        }

        return viewModel.purchaseOptions.first?.id
    }

    private func paywallPlanCard(option: PurchasePlanOption, isSelected: Bool) -> some View {
        let accent = paywallAccent(for: option.id)
        return Button {
            selectedPaywallPlanID = option.id
        } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(option.title)
                            .font(.headline)
                            .foregroundStyle(paywallPrimaryTextColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .layoutPriority(1)
                        if let badge = paywallBadge(for: option.id) {
                            paywallBadgeChip(
                                title: badge,
                                fill: accent.opacity(0.9),
                                stroke: Color.white.opacity(0.35),
                                textColor: .white,
                                showsStroke: true
                            )
                        }
                        if !option.isAvailable {
                            paywallBadgeChip(
                                title: L10n.tr("Unavailable"),
                                fill: Color(uiColor: .systemGray),
                                stroke: Color.clear,
                                textColor: .white,
                                showsStroke: false
                            )
                        }
                    }

                    Text(option.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(paywallSecondaryTextColor)

                    if !option.priceText.isEmpty {
                        Text(option.priceText)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(paywallPrimaryTextColor)
                    }
                }

                Spacer()

                if isSelected {
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
            .opacity(option.isAvailable ? 1.0 : 0.85)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isPurchasingPlan)
    }

    private func paywallAccent(for planID: String) -> Color {
        switch planID {
        case PurchaseManager.weeklyProductID:
            return Color(red: 0.27, green: 0.52, blue: 0.98)
        case PurchaseManager.monthlyProductID:
            return Color(red: 0.62, green: 0.38, blue: 0.96)
        case PurchaseManager.lifetimeProductID:
            return Color(red: 0.96, green: 0.56, blue: 0.22)
        default:
            return Color(red: 0.40, green: 0.48, blue: 0.72)
        }
    }

    private func paywallBadge(for planID: String) -> String? {
        switch planID {
        case PurchaseManager.monthlyProductID:
            return L10n.tr("Most popular")
        case PurchaseManager.lifetimeProductID:
            return L10n.tr("Best value")
        default:
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

    private var termsOfUseURL: URL? {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "TERMS_OF_USE_URL") as? String,
           let url = URL(string: configured), !configured.isEmpty
        {
            return url
        }
        return URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    }

    private var privacyPolicyURL: URL? {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "PRIVACY_POLICY_URL") as? String,
           let url = URL(string: configured), !configured.isEmpty
        {
            return url
        }
        return nil
    }

    private var manageSubscriptionsURL: URL? {
        URL(string: "https://apps.apple.com/account/subscriptions")
    }

    @ViewBuilder
    private var manageSubscriptionsInlineButton: some View {
        Button {
            openManageSubscriptions()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                Text(L10n.tr("You can manage subscriptions in Apple ID settings."))
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(colorScheme == .dark ? 0.45 : 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func openManageSubscriptions() {
        guard let url = manageSubscriptionsURL else { return }
        UIApplication.shared.open(url)
    }

    private func exportToFiles(_ video: StoredVideo) {
        filesExportURL = video.localURL
    }

    private func exportToGallery(_ video: StoredVideo) {
        Task {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                exportAlertMessage = L10n.tr("Photo Library access is required to save the converted video.")
                return
            }

            let fileManager = FileManager.default
            let fileExtension = video.localURL.pathExtension.isEmpty ? "mp4" : video.localURL.pathExtension
            let temporaryURL = fileManager.temporaryDirectory
                .appendingPathComponent("gallery-export-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)

            do {
                if fileManager.fileExists(atPath: temporaryURL.path) {
                    try fileManager.removeItem(at: temporaryURL)
                }

                try fileManager.copyItem(at: video.localURL, to: temporaryURL)

                try await PHPhotoLibrary.shared().performChanges {
                    if let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: temporaryURL) {
                        request.creationDate = Date()
                    }
                }

                try? fileManager.removeItem(at: temporaryURL)
                exportAlertMessage = L10n.tr("Saved to Photo Library.")
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                exportAlertMessage = L10n.fmt("Failed to save to Photo Library: %@", error.localizedDescription)
            }
        }
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

    private var vaultBackgroundGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.08, green: 0.14, blue: 0.22),
                Color(red: 0.10, green: 0.19, blue: 0.32)
            ]
        }
        return [
            Color(red: 0.95, green: 0.97, blue: 1.0),
            Color(red: 0.88, green: 0.93, blue: 1.0)
        ]
    }

    private var vaultCardFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.84)
    }

    private var vaultCardStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10)
    }

    private var vaultCardShadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.30) : .black.opacity(0.12)
    }

    private var vaultPrimaryText: Color {
        colorScheme == .dark ? .white : Color(uiColor: .label)
    }

    private var vaultSecondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.78) : Color(uiColor: .secondaryLabel)
    }

    private var vaultIconBackground: Color {
        colorScheme == .dark ? accent.opacity(0.24) : accent.opacity(0.16)
    }

    private var vaultIconForeground: Color {
        colorScheme == .dark ? .white : accent
    }

    private func surfaceTone(_ opacity: Double) -> Color {
        colorScheme == .dark ? Color(red: 0.08, green: 0.11, blue: 0.18) : Color(red: 0.95, green: 0.96, blue: 1.0)
    }

    private func presentDownloadRightsSheet() {
        guard viewModel.validateSource() != nil, let sourceURL = viewModel.resolverURL else {
            return
        }

        downloadRightsForm = DownloadRightsFormState(urlText: sourceURL.absoluteString)
        isDownloadRightsSheetPresented = true
    }

    private func confirmDownloadRights() {
        guard downloadRightsForm.allConfirmed else { return }
        isDownloadRightsSheetPresented = false

        Task {
            await viewModel.downloadVideo()
        }
    }
}

private extension String {
    func truncatedForConfirmation(limit: Int) -> String {
        guard count > limit else { return self }
        let prefixCount = max(0, limit - 1)
        return String(prefix(prefixCount)) + "…"
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

private struct FilesExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onComplete: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onComplete: (Result<URL, Error>) -> Void
        private var hasFinished = false

        init(onComplete: @escaping (Result<URL, Error>) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !hasFinished else { return }
            hasFinished = true
            guard let url = urls.first else {
                onComplete(.failure(CocoaError(.fileNoSuchFile)))
                return
            }
            onComplete(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !hasFinished else { return }
            hasFinished = true
            onComplete(.failure(CocoaError(.userCancelled)))
        }
    }
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
