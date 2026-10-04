import XCTest
@testable import LotteryWallet

@MainActor
final class HomeDrawCalendarTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func store() -> DrawStore {
        let client = LotteryAPIClient(session: StubURLProtocol.makeSession())
        return DrawStore(repository: LotteryRepository(client: client,
            cache: LotteryCache(folder: "tests/\(UUID().uuidString)")))
    }

    private func loadCalendar(_ store: DrawStore) async {
        // Sunday 10/4 is absent during closure; Friday 10/9 is an explicit DLT
        // date even though the normal weekday schedule says otherwise.
        let payload = Data("""
        {"year":2026,"entries":[
          {"lottery_type":"ssq","issue":"2026113","date":"2026-09-29",
           "draw_time":"21:15:00","sale_close_time":"20:00:00"},
          {"lottery_type":"dlt","issue":"26113","date":"2026-10-09",
           "draw_time":"21:25:00","sale_close_time":"21:00:00"},
          {"lottery_type":"ssq","issue":"2026114","date":"2026-10-11",
           "draw_time":"21:15:00","sale_close_time":"20:00:00"}
        ]}
        """.utf8)
        StubURLProtocol.stub("v2/calendar/2026", body: payload)
        StubURLProtocol.stub("v2/calendar/2026.json", body: payload)
        await store.loadCalendar(year: 2026)
        XCTAssertEqual(store.calendarStates[2026], .loaded)
    }

    func testClosureSuppressesWeekdayBadgeAndPendingUpdate() async {
        let store = store()
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        await store.bootstrap()
        await loadCalendar(store)
        let now = ChinaClock(date: "2026-10-04", clock: "23:00", weekday: 0)
        XCTAssertTrue(store.todayOpenGames(now).isEmpty)
        XCTAssertTrue(store.pendingDrawUpdates(now).isEmpty)
    }

    func testActualCalendarDateOverridesWeekdayAndUsesItsDrawTime() async {
        let store = store()
        await loadCalendar(store)
        let before = ChinaClock(date: "2026-10-09", clock: "21:24", weekday: 5)
        let atDraw = ChinaClock(date: "2026-10-09", clock: "21:25", weekday: 5)
        XCTAssertEqual(store.todayOpenGames(before), [.dlt])
        XCTAssertTrue(store.pendingDrawUpdates(before).isEmpty)
        XCTAssertEqual(store.pendingDrawUpdates(atDraw), [.dlt])
        XCTAssertTrue(store.todayOpenGames(ChinaClock(date: "2027-10-09", clock: "23:00", weekday: 6)).isEmpty)
    }

    func testMissingOrFailedCalendarNeverInventsTodayDraws() async {
        let store = store()
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        await store.bootstrap()
        let now = ChinaClock(date: "2026-10-04", clock: "23:00", weekday: 0)
        XCTAssertTrue(store.todayOpenGames(now).isEmpty)
        await store.loadCalendar(year: 2026)
        XCTAssertTrue(store.calendarStates[2026]?.hasFailed == true)
        XCTAssertTrue(store.todayOpenGames(now).isEmpty)
        XCTAssertTrue(store.pendingDrawUpdates(now).isEmpty)
    }

    func testCalendarArrivalInvalidatesHomeScheduleToken() async {
        let store = store()
        let before = store.scheduleToken
        await loadCalendar(store)
        XCTAssertNotEqual(store.scheduleToken, before)
    }
}
