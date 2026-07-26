import Foundation
import XCTest

final class ProfileTriggerTests: XCTestCase {
    func testOvernightTimeRangeIncludesStartAndExcludesEnd() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let trigger = TimeOfDayTrigger(
            id: "overnight",
            startMinuteOfDay: 22 * 60,
            endMinuteOfDay: 6 * 60,
            weekdays: [2, 3]
        )

        XCTAssertFalse(trigger.matches(date: date(2024, 1, 1, 21, 59, calendar: calendar), calendar: calendar))
        XCTAssertTrue(trigger.matches(date: date(2024, 1, 1, 22, 0, calendar: calendar), calendar: calendar))
        XCTAssertTrue(trigger.matches(date: date(2024, 1, 2, 5, 59, calendar: calendar), calendar: calendar))
        XCTAssertFalse(trigger.matches(date: date(2024, 1, 2, 6, 0, calendar: calendar), calendar: calendar))
    }

    func testCodableRoundTripPreservesEveryTriggerKindAndSpecificity() throws {
        let triggers: [ProfileTrigger] = [
            .timeOfDay(
                TimeOfDayTrigger(
                    id: "work-hours",
                    startMinuteOfDay: 9 * 60,
                    endMinuteOfDay: 17 * 60,
                    weekdays: [2, 3, 4, 5, 6]
                )
            ),
            .frontmostApp(
                FrontmostAppTrigger(id: "frontmost", bundleIdentifier: "com.example.editor")
            ),
            .space(
                SpaceTrigger(id: "space", bundleIdentifier: "com.example.browser")
            ),
            .exactSpace(
                ExactSpaceTrigger(id: "exact-space", spaceID: 42)
            ),
        ]

        let encoded = try JSONEncoder().encode(triggers)
        let decoded = try JSONDecoder().decode([ProfileTrigger].self, from: encoded)

        XCTAssertEqual(decoded, triggers)
        XCTAssertEqual(decoded.map(\.id), ["work-hours", "frontmost", "space", "exact-space"])
        XCTAssertEqual(decoded.map(\.specificity), [1, 2, 3, 4])
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return calendar.date(from: components)!
    }
}
