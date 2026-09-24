import AlulaMigrate

/// The job queue's table (alula-data's `PostgresQueueStore`). The SQL is
/// written out here rather than taken from `PostgresQueueStore.schema()`:
/// a migration is recorded by checksum, so it must not change when a
/// library does.
struct CreateJobs: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.raw(
            """
            CREATE TABLE alula_jobs (
                id uuid PRIMARY KEY,
                kind text NOT NULL,
                queue text NOT NULL,
                payload jsonb NOT NULL,
                state text NOT NULL
                    CHECK (state IN ('available', 'running', 'completed', 'discarded')),
                priority integer NOT NULL DEFAULT 0,
                attempt integer NOT NULL DEFAULT 0,
                max_attempts integer NOT NULL,
                run_at timestamptz NOT NULL,
                lease_until timestamptz,
                unique_key text,
                last_error text,
                inserted_at timestamptz NOT NULL,
                finished_at timestamptz
            )
            """)
        schema.raw(
            """
            CREATE INDEX alula_jobs_claim_idx ON alula_jobs (queue, priority, run_at, id)
            WHERE state IN ('available', 'running')
            """)
        schema.raw(
            """
            CREATE UNIQUE INDEX alula_jobs_unique_idx ON alula_jobs (kind, unique_key)
            WHERE unique_key IS NOT NULL AND state IN ('available', 'running')
            """)
        schema.raw(
            """
            CREATE INDEX alula_jobs_finished_idx ON alula_jobs (finished_at)
            WHERE state IN ('completed', 'discarded')
            """)
    }

    func down(_ schema: SchemaBuilder) {
        schema.raw("DROP TABLE alula_jobs")
    }
}
