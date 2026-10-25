import XCTest
@testable import Glint

@MainActor
final class UpdatesTests: XCTestCase {
    func testReleaseNotesKeepOnlyWhatChangedWithoutPullRequestNumbers() {
        let body = """
        ## What's Changed

        ### Popup

        - Up to five cards show at a time. #27
        - The History row is gone. #26 #27

        ### Empty

        ## Install

        - Open the DMG. #1
        """
        let notes = Updates.notes(fromReleaseBody: body)
        XCTAssertEqual(notes.map(\.heading), ["Popup"])
        XCTAssertEqual(notes.first?.items, ["Up to five cards show at a time.", "The History row is gone."])
    }
}
