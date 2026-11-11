/**
 * Board tables by schema version (T63b). A migration is written once and never changed: a team's board.db
 * at version n runs every migration after n. When core's KINDS change, SCHEMA_VERSION goes up and a new
 * entry is added here. Lists and JSON are stored as JSON text.
 */

export const TABLES = {
    task: 'tasks', landing: 'landings', verdict: 'verdicts', finding: 'findings',
    note: 'notes', announcement: 'announcements',
};

export const MIGRATIONS = [
    {
        to: 1,
        sql: `
CREATE TABLE tasks (
    "id" TEXT PRIMARY KEY, "parent_id" TEXT, "title" TEXT NOT NULL, "ticket_path" TEXT, "state" TEXT NOT NULL,
    "assignee" TEXT, "reviewer" TEXT, "priority" INTEGER NOT NULL, "base_commit" TEXT, "constraints" TEXT,
    "assigned_at" TEXT, "created_at" TEXT NOT NULL, "created_by" TEXT NOT NULL, "updated_at" TEXT, "updated_by" TEXT,
    "version" INTEGER NOT NULL
);
CREATE TABLE landings (
    "id" TEXT PRIMARY KEY, "task_id" TEXT NOT NULL, "repo" TEXT NOT NULL, "commit" TEXT NOT NULL,
    "base_commit" TEXT NOT NULL, "commits" TEXT NOT NULL, "check_cmd" TEXT NOT NULL, "check_result" TEXT NOT NULL,
    "focus" TEXT NOT NULL, "closes" TEXT NOT NULL, "report_path" TEXT NOT NULL, "review_report_path" TEXT NOT NULL,
    "deployed" TEXT, "superseded_by" TEXT, "created_at" TEXT NOT NULL, "created_by" TEXT NOT NULL,
    "updated_at" TEXT, "updated_by" TEXT, "version" INTEGER NOT NULL
);
CREATE TABLE verdicts (
    "id" TEXT PRIMARY KEY, "landing_id" TEXT NOT NULL, "verdict" TEXT NOT NULL, "verified_commit" TEXT NOT NULL,
    "report_path" TEXT NOT NULL, "rerun_cmd" TEXT NOT NULL, "rerun_result" TEXT NOT NULL, "side_notes" TEXT,
    "created_at" TEXT NOT NULL, "created_by" TEXT NOT NULL
);
CREATE TABLE findings (
    "id" TEXT PRIMARY KEY, "verdict_id" TEXT NOT NULL, "task_id" TEXT NOT NULL, "severity" TEXT NOT NULL,
    "summary" TEXT NOT NULL, "repro" TEXT NOT NULL, "state" TEXT NOT NULL, "fixed_in" TEXT,
    "created_at" TEXT NOT NULL, "created_by" TEXT NOT NULL, "updated_at" TEXT, "updated_by" TEXT,
    "version" INTEGER NOT NULL
);
CREATE TABLE notes (
    "seq" INTEGER PRIMARY KEY AUTOINCREMENT, "task_id" TEXT, "body" TEXT NOT NULL, "to" TEXT,
    "created_at" TEXT NOT NULL, "created_by" TEXT NOT NULL
);
CREATE TABLE announcements (
    "seq" INTEGER PRIMARY KEY AUTOINCREMENT, "body" TEXT NOT NULL, "created_at" TEXT NOT NULL, "created_by" TEXT NOT NULL
);
CREATE TABLE log (
    "seq" INTEGER PRIMARY KEY AUTOINCREMENT, "at" TEXT NOT NULL, "actor" TEXT NOT NULL, "action" TEXT NOT NULL,
    "kind" TEXT NOT NULL, "ref" TEXT NOT NULL, "state_from" TEXT, "state_to" TEXT, "detail" TEXT
);
CREATE INDEX tasks_state ON tasks("state");
CREATE INDEX landings_task ON landings("task_id");
CREATE INDEX findings_task ON findings("task_id");
`,
    },
];
