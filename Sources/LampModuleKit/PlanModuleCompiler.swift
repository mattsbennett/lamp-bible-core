import Foundation
import GRDB

extension LampModuleCompiler {
    func compilePlan(
        root: [String: Any],
        databaseURL: URL,
        moduleID: String
    ) throws -> [String: Int] {
        let meta = try JSONSupport.requiredObject(root["meta"], path: "/meta")
        let days = try JSONSupport.requiredArray(root["days"], path: "/days")
        let queue = try makeDatabaseQueue(at: databaseURL)

        try queue.write { db in
            try createPlanSchema(in: db)
            try createFormatMetadata(in: db, kind: .plan, moduleID: moduleID)

            let name = try JSONSupport.requiredString(meta["name"], path: "/meta/name")
            let duration = JSONSupport.integer(meta["duration"]) ?? days.count
            let firstDay = days.first.flatMap(JSONSupport.object)
            let readingsPerDay = JSONSupport.integer(meta["readingsPerDay"])
                ?? firstDay.flatMap { JSONSupport.array($0["readings"])?.count }

            try db.execute(
                sql: """
                    INSERT INTO plans (
                        id, name, description, author, full_description,
                        duration, readings_per_day
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    moduleID,
                    name,
                    JSONSupport.string(meta["description"]),
                    JSONSupport.string(meta["author"]),
                    JSONSupport.string(meta["fullDescription"]),
                    duration,
                    readingsPerDay,
                ]
            )

            for (dayIndex, dayValue) in days.enumerated() {
                let dayPath = "/days/\(dayIndex)"
                let day = try JSONSupport.requiredObject(dayValue, path: dayPath)
                let dayNumber = try JSONSupport.requiredInteger(day["day"], path: "\(dayPath)/day")
                let readings = try JSONSupport.requiredArray(day["readings"], path: "\(dayPath)/readings")
                let normalizedReadings = try readings.enumerated().map { readingIndex, value -> [String: Int] in
                    let path = "\(dayPath)/readings/\(readingIndex)"
                    let reading = try JSONSupport.requiredObject(value, path: path)
                    return [
                        "sv": try JSONSupport.requiredInteger(reading["sv"], path: "\(path)/sv"),
                        "ev": try JSONSupport.requiredInteger(reading["ev"], path: "\(path)/ev"),
                    ]
                }
                let readingsJSON = normalizedReadings.isEmpty
                    ? "[]"
                    : try JSONSupport.jsonString(normalizedReadings)
                try db.execute(
                    sql: """
                        INSERT INTO plan_days (plan_id, day, readings_json)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [
                        moduleID,
                        dayNumber,
                        readingsJSON,
                    ]
                )
            }
        }

        try optimize(queue)
        return ["plans": 1, "plan_days": days.count]
    }

    private func createPlanSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE plans (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                author TEXT,
                full_description TEXT,
                duration INTEGER NOT NULL,
                readings_per_day INTEGER
            )
            """)
        try db.execute(sql: """
            CREATE TABLE plan_days (
                plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
                day INTEGER NOT NULL,
                readings_json TEXT NOT NULL,
                PRIMARY KEY (plan_id, day)
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_plan_days_plan ON plan_days(plan_id, day)")
    }
}
