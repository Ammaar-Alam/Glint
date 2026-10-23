import XCTest
@testable import Glint

final class HistoryTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!

    private func item(_ title: String, daysAgo: Int, kind: CaptureKind = .image, hour: Int = 9) -> CaptureItem {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return CaptureItem(id: UUID(), createdAt: date, title: title, filename: "capture.png", kind: kind)
    }

    func testSectionsGroupByDayNewestFirst() {
        let items = [
            item("Old", daysAgo: 400), item("Morning", daysAgo: 0, hour: 8), item("Noon", daysAgo: 0, hour: 11),
            item("Yesterday", daysAgo: 1), item("Week", daysAgo: 5), item("Month", daysAgo: 20), item("August", daysAgo: 60)
        ]
        let sections = HistorySection.make(items, filter: .all, query: "", now: now, calendar: calendar)
        XCTAssertEqual(Array(sections.map(\.title).prefix(4)), ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days"])
        XCTAssertEqual(sections.count, 6)
        XCTAssertEqual(sections[0].items.map(\.title), ["Noon", "Morning"])
        XCTAssertEqual(sections[5].items.map(\.title), ["Old"])
        XCTAssertNotEqual(sections[4].title, sections[5].title)
    }

    func testFilterAndSearch() {
        let items = [
            item("Bug report", daysAgo: 0), item("Demo", daysAgo: 0, kind: .video),
            item("Demo edit", daysAgo: 0, kind: .videoProject), item("Mockup", daysAgo: 0, kind: .imageProject)
        ]
        func titles(_ filter: HistoryFilter, _ query: String = "") -> Set<String> {
            Set(HistorySection.make(items, filter: filter, query: query, now: now, calendar: calendar).flatMap { $0.items.map(\.title) })
        }
        XCTAssertEqual(titles(.screenshots), ["Bug report", "Mockup"])
        XCTAssertEqual(titles(.recordings), ["Demo", "Demo edit"])
        XCTAssertEqual(titles(.all, "  demo "), ["Demo", "Demo edit"])
        XCTAssertEqual(titles(.screenshots, "demo"), [])
    }

    func testArrowKeysMoveThroughRowsAndSections() {
        let a = (0..<5).map { _ in UUID() }, b = (0..<2).map { _ in UUID() }
        let sections = [a, b]
        func move(_ id: UUID?, _ dx: Int, _ dy: Int) -> UUID? { HistorySection.neighbor(of: id, in: sections, columns: 3, dx: dx, dy: dy) }
        XCTAssertEqual(move(nil, 1, 0), a[0])
        XCTAssertEqual(move(a[1], 0, 1), a[4])
        XCTAssertEqual(move(a[2], 0, 1), a[4])
        XCTAssertEqual(move(a[4], 0, 1), b[1])
        XCTAssertEqual(move(b[1], 0, -1), a[4])
        XCTAssertEqual(move(b[0], 0, -1), a[3])
        XCTAssertEqual(move(a[4], 1, 0), b[0])
        XCTAssertEqual(move(b[1], 1, 0), b[1])
        XCTAssertEqual(move(a[0], 0, -1), a[0])
        XCTAssertNil(HistorySection.neighbor(of: nil, in: [], columns: 3, dx: 1, dy: 0))
    }

    func testMenuRespectsSharingRules() {
        let videoProject = CaptureCommand.sections(for: .videoProject, in: .history).flatMap { $0 }
        XCTAssertFalse(videoProject.contains(.copy))
        XCTAssertFalse(videoProject.contains(.save))
        XCTAssertFalse(videoProject.contains(.pin))
        XCTAssertEqual(CaptureCommand.saveAs.title(for: .videoProject), "Export…")
        XCTAssertFalse(CaptureCommand.sections(for: .video, in: .history).flatMap { $0 }.contains(.pin))
        let popup = CaptureCommand.sections(for: .image, in: .popup)
        XCTAssertEqual(popup.first, [.copy, .save, .saveAs])
        XCTAssertTrue(popup.flatMap { $0 }.contains(.closeAll))
        XCTAssertFalse(popup.flatMap { $0 }.contains(.rename))
        XCTAssertEqual(popup.last, [.trash])
    }
}
