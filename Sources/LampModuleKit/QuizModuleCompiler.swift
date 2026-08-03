import Foundation
import GRDB

extension LampModuleCompiler {
    func compileQuiz(
        root: [String: Any],
        databaseURL: URL,
        moduleID: String
    ) throws -> [String: Int] {
        let meta = try JSONSupport.requiredObject(root["meta"], path: "/meta")
        let days = try JSONSupport.requiredArray(root["days"], path: "/days")
        let ageGroups = try JSONSupport.requiredArray(meta["ageGroups"], path: "/meta/ageGroups")
        let queue = try makeDatabaseQueue(at: databaseURL)
        var questionCount = 0

        try queue.write { db in
            try createQuizSchema(in: db)
            try createFormatMetadata(in: db, kind: .quiz, moduleID: moduleID)
            try db.execute(sql: """
                INSERT INTO quiz_modules (
                    id, plan_id, name, description, questions_per_reading, age_groups_json
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    moduleID,
                    try JSONSupport.requiredString(meta["planId"], path: "/meta/planId"),
                    try JSONSupport.requiredString(meta["name"], path: "/meta/name"),
                    JSONSupport.string(meta["description"]),
                    JSONSupport.integer(meta["questionsPerReading"]),
                    try JSONSupport.jsonString(ageGroups) ?? "[]",
                ])

            for (dayIndex, dayValue) in days.enumerated() {
                let dayPath = "/days/\(dayIndex)"
                let day = try JSONSupport.requiredObject(dayValue, path: dayPath)
                let dayNumber = try JSONSupport.requiredInteger(day["day"], path: "\(dayPath)/day")
                let readings = try JSONSupport.requiredArray(day["readings"], path: "\(dayPath)/readings")
                for (readingIndex, readingValue) in readings.enumerated() {
                    let readingPath = "\(dayPath)/readings/\(readingIndex)"
                    let reading = try JSONSupport.requiredObject(readingValue, path: readingPath)
                    let start = try JSONSupport.requiredInteger(reading["sv"], path: "\(readingPath)/sv")
                    let end = try JSONSupport.requiredInteger(reading["ev"], path: "\(readingPath)/ev")
                    let quizzes = try JSONSupport.requiredObject(reading["quizzes"], path: "\(readingPath)/quizzes")

                    for ageGroupID in quizzes.keys.sorted() {
                        let questionsPath = "\(readingPath)/quizzes/\(ageGroupID)"
                        let questions = try JSONSupport.requiredArray(quizzes[ageGroupID], path: questionsPath)
                        for (questionIndex, questionValue) in questions.enumerated() {
                            let questionPath = "\(questionsPath)/\(questionIndex)"
                            let question = try JSONSupport.requiredObject(questionValue, path: questionPath)
                            guard let questionValue = question["question"] else {
                                throw ModuleCompilationError.missingValue(path: "\(questionPath)/question")
                            }
                            guard let answerValue = question["answer"] else {
                                throw ModuleCompilationError.missingValue(path: "\(questionPath)/answer")
                            }
                            try db.execute(sql: """
                                INSERT INTO quiz_questions (
                                    quiz_module_id, day, sv, ev, age_group, question_index,
                                    question_json, answer_json, theme, christ_focused,
                                    references_json, cross_references_json
                                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                """, arguments: [
                                    moduleID,
                                    dayNumber,
                                    start,
                                    end,
                                    ageGroupID,
                                    questionIndex,
                                    try JSONSupport.jsonFragmentString(questionValue),
                                    try JSONSupport.jsonFragmentString(answerValue),
                                    try JSONSupport.requiredString(question["theme"], path: "\(questionPath)/theme"),
                                    JSONSupport.bool(question["christFocused"]) == true ? 1 : 0,
                                    try JSONSupport.jsonString(question["references"]),
                                    try JSONSupport.jsonString(question["crossReferences"]),
                                ])
                            questionCount += 1
                        }
                    }
                }
            }
        }

        try optimize(queue)
        return ["quiz_modules": 1, "quiz_questions": questionCount]
    }

    private func createQuizSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE quiz_modules (
                id TEXT PRIMARY KEY,
                plan_id TEXT NOT NULL,
                name TEXT NOT NULL,
                description TEXT,
                questions_per_reading INTEGER,
                age_groups_json TEXT NOT NULL
            );
            CREATE TABLE quiz_questions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                quiz_module_id TEXT NOT NULL REFERENCES quiz_modules(id) ON DELETE CASCADE,
                day INTEGER NOT NULL,
                sv INTEGER NOT NULL,
                ev INTEGER NOT NULL,
                age_group TEXT NOT NULL,
                question_index INTEGER NOT NULL,
                question_json TEXT NOT NULL,
                answer_json TEXT NOT NULL,
                theme TEXT NOT NULL,
                christ_focused INTEGER NOT NULL DEFAULT 0,
                references_json TEXT,
                cross_references_json TEXT,
                UNIQUE(quiz_module_id, day, sv, ev, age_group, question_index)
            );
            CREATE INDEX idx_quiz_questions_module_day
                ON quiz_questions(quiz_module_id, day);
            CREATE INDEX idx_quiz_questions_module_age
                ON quiz_questions(quiz_module_id, age_group);
            CREATE INDEX idx_quiz_questions_reading
                ON quiz_questions(quiz_module_id, day, sv, ev, age_group);
            """)
    }
}
