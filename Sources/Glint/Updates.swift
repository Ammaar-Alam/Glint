import AppKit
import Sparkle
import SwiftUI

// checks the appcast published with each release and installs updates signed with the release key,
// Sparkle does the downloading and installing while Glint draws every screen
@MainActor
enum Updates {
    static let driver = UpdateDriver()
    static let updater: SPUUpdater = {
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do { try updater.start() } catch { NSLog("Updates could not start: %@", error.localizedDescription) }
        return updater
    }()

    static func check() { updater.checkForUpdates() }

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    // the What's Changed part of a release body, headings and bullets without the trailing pull request numbers
    static func notes(fromReleaseBody body: String) -> [(heading: String, items: [String])] {
        var sections: [(heading: String, items: [String])] = []
        var inChanges = false
        for line in body.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("## ") { inChanges = line == "## What's Changed"; continue }
            guard inChanges else { continue }
            if line.hasPrefix("### ") { sections.append((String(line.dropFirst(4)), [])) }
            else if line.hasPrefix("- "), !sections.isEmpty {
                let item = line.dropFirst(2).replacingOccurrences(of: #"(\s+#\d+)+$"#, with: "", options: .regularExpression)
                sections[sections.count - 1].items.append(item)
            }
        }
        return sections.filter { !$0.items.isEmpty }
    }
}

@MainActor
final class UpdateDriver: NSObject, ObservableObject, SPUUserDriver {
    enum Phase: Equatable {
        case checking
        case available(version: String)
        case downloading(progress: Double?)
        case installing
        case upToDate
        case failed(String)
    }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var notes: [(heading: String, items: [String])] = []
    private var window: NSWindow?
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var acknowledgement: (() -> Void)?
    private var cancellation: (() -> Void)?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    // MARK: actions from the window

    func install() {
        choice?(.install)
        choice = nil
    }

    func later() {
        choice?(.dismiss)
        choice = nil
        close()
    }

    func skip() {
        choice?(.skip)
        choice = nil
        close()
    }

    func done() {
        acknowledgement?()
        acknowledgement = nil
        close()
    }

    func cancel() {
        cancellation?()
        cancellation = nil
        close()
    }

    // closing the window answers whatever Sparkle is waiting on
    fileprivate func windowClosed() {
        window = nil
        choice?(.dismiss); choice = nil
        acknowledgement?(); acknowledgement = nil
        cancellation?(); cancellation = nil
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        present(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        choice = reply
        notes = []
        let version = appcastItem.displayVersionString
        present(.available(version: version))
        Task { await loadNotes(for: version) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        self.acknowledgement = acknowledgement
        present(.upToDate)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        self.acknowledgement = acknowledgement
        present(.failed(error.localizedDescription))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        present(.downloading(progress: nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0 else { return }
        phase = .downloading(progress: min(1, Double(receivedLength) / Double(expectedLength)))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        phase = .downloading(progress: 1)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    // only reached after Install and Relaunch, so nobody is asked twice
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        close()
    }

    func showUpdateInFocus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissUpdateInstallation() {
        choice = nil
        acknowledgement = nil
        cancellation = nil
        close()
    }

    // MARK: window

    private func present(_ next: Phase) {
        phase = next
        if window == nil {
            let window = UpdateWindow(driver: self)
            self.window = window
            window.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        let window = self.window
        self.window = nil
        window?.close()
    }

    private func loadNotes(for version: String) async {
        guard let url = URL(string: "https://api.github.com/repos/Ammaar-Alam/Glint/releases/tags/\(version)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["body"] as? String else { return }
        guard case .available(let shown) = phase, shown == version else { return }
        notes = Updates.notes(fromReleaseBody: body)
    }
}

private final class UpdateWindow: NSWindow, NSWindowDelegate {
    private weak var driver: UpdateDriver?

    init(driver: UpdateDriver) {
        self.driver = driver
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "Glint Updates"
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .white
        appearance = NSAppearance(named: .aqua)
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        delegate = self
        // the hosting controller resizes the window as the notes arrive or the phase changes
        let host = NSHostingController(rootView: UpdateView(driver: driver).environment(\.colorScheme, .light))
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { driver?.windowClosed() }
    }
}

private struct UpdateView: View {
    @ObservedObject var driver: UpdateDriver

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(white: 0.1))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Color(white: 0.45))
                }
                Spacer(minLength: 0)
            }
            content
            HStack(spacing: 8) {
                if case .available = driver.phase {
                    Button("Skip This Version", action: driver.skip).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color(white: 0.45))
                }
                Spacer(minLength: 0)
                buttons
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(width: 440)
        .background(Color.white)
        .animation(.easeOut(duration: 0.2), value: driver.phase)
        .animation(.easeOut(duration: 0.2), value: driver.notes.count)
    }

    private var title: String {
        switch driver.phase {
        case .checking: return "Checking for Updates"
        case .available(let version): return "Glint \(version) is available"
        case .downloading: return "Downloading Update"
        case .installing: return "Installing Update"
        case .upToDate: return "You're up to date"
        case .failed: return "Couldn't check for updates"
        }
    }

    private var subtitle: String {
        switch driver.phase {
        case .available: return "You have \(Updates.currentVersion)"
        case .upToDate: return "Glint \(Updates.currentVersion) is the latest version."
        case .failed(let message): return message
        case .installing: return "Glint will reopen in a moment."
        default: return "Glint \(Updates.currentVersion)"
        }
    }

    @ViewBuilder private var content: some View {
        switch driver.phase {
        case .available where !driver.notes.isEmpty:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(driver.notes.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.heading).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(white: 0.1))
                            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Circle().fill(Color.glint).frame(width: 4, height: 4).offset(y: -2)
                                    Text(item).font(.system(size: 12)).foregroundStyle(Color(white: 0.3)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(maxHeight: 260)
            .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 18)
            .transition(.opacity)
        case .downloading(let progress):
            UpdateProgress(value: progress).padding(.top, 18)
        case .checking, .installing:
            UpdateProgress(value: nil).padding(.top, 18)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch driver.phase {
        case .available:
            Button("Later", action: driver.later).buttonStyle(SecondaryButtonStyle())
            Button("Install and Relaunch", action: driver.install).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        case .checking, .downloading:
            Button("Cancel", action: driver.cancel).buttonStyle(SecondaryButtonStyle())
        case .installing:
            EmptyView()
        case .upToDate, .failed:
            Button("OK", action: driver.done).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }
}

// a thin glint bar, a sliding segment while the length is unknown
private struct UpdateProgress: View {
    let value: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.92))
                if let value {
                    Capsule().fill(Color.glint).frame(width: max(6, proxy.size.width * value))
                        .animation(.easeOut(duration: 0.25), value: value)
                } else {
                    Capsule().fill(Color.glint).frame(width: proxy.size.width * 0.3)
                        .offset(x: sweep ? proxy.size.width * 0.7 : 0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: sweep)
                        .onAppear { sweep = true }
                }
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }
}
