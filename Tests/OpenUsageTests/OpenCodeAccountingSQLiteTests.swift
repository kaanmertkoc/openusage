import XCTest
@testable import OpenUsage

final class OpenCodeAccountingSQLiteTests: XCTestCase {
    func testRealV2DatabaseFiltersPaidAndPreLoginRowsAndDeduplicatesMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("opencode.db").path
        let sqlite = SQLiteCLIAccessor()
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let login = ms - 60_000
        try sqlite.execute(path: path, sql: """
            CREATE TABLE credential (id TEXT, integration_id TEXT, active INTEGER, time_updated INTEGER,
                                     time_created INTEGER, value TEXT);
            INSERT INTO credential VALUES ('auth','openai',1,\(login),\(login),'{}');
            UPDATE credential SET value='{"type":"oauth","access":"fixture"}';
            CREATE TABLE message (id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE session_message (id TEXT, time_created INTEGER, type TEXT, data TEXT);
            """)
        func insert(_ id: String, v2: Bool, completed: Int, cost: Int = 0, compaction: Bool = false) throws {
            var data: [String: Any] = [
                "cost": cost, "time": ["completed": completed],
                "tokens": ["input": 100, "output": 20, "reasoning": 10, "cache": ["read": 30]]
            ]
            if v2 {
                data["model"] = ["providerID": "openai", "id": "gpt-test"]
                if compaction { data["status"] = "completed" }
            } else {
                data["role"] = "assistant"
                data["providerID"] = "openai"
                data["modelID"] = "gpt-test"
            }
            let json = String(data: try JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
                .replacingOccurrences(of: "'", with: "''")
            let table = v2 ? "session_message" : "message"
            let type = v2 ? "'\(compaction ? "compaction" : "assistant")'," : ""
            try sqlite.execute(path: path, sql: "INSERT INTO \(table) VALUES ('\(id)',\(completed),\(type)'\(json)');")
        }
        try insert("migrated", v2: false, completed: ms - 1_000)
        try insert("migrated", v2: true, completed: ms - 1_000)
        try insert("compacted", v2: true, completed: ms - 500, compaction: true)
        try insert("paid", v2: true, completed: ms - 500, cost: 1)
        try insert("before-oauth", v2: true, completed: login - 1)
        let scanner = OpenCodeOpenAIUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"stale"}}"#]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]), sqlite: sqlite
            ),
            sqlite: sqlite, databasePaths: { [path] }
        )
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["gpt-test": ModelRates(
                inputPerMillion: 2, outputPerMillion: 10, cacheWritePerMillion: 2, cacheReadPerMillion: 0.2
            )]), secondary: PricingCatalog(entries: [:])
        )
        let result = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(result?.series.daily.first?.totalTokens, 320)
        XCTAssertEqual(result?.series.daily.first?.costUSD ?? -1, 0.001012, accuracy: 0.00000001)

        // A logout must not revive the stale imported auth file.
        try sqlite.execute(path: path, sql: "DELETE FROM credential;")
        let loggedOut = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(loggedOut)
    }
}
