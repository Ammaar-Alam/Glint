import Sparkle

// checks the appcast published with each release and installs updates signed with the release key
@MainActor
enum Updates {
    static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}
