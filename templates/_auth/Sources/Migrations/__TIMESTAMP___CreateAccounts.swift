import AlulaMigrate

/// Accounts for first-party sign-in, and the one-time tokens their emails
/// carry. Written by `alula generate auth`.
struct CreateAccounts: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.raw(
            """
            CREATE TABLE accounts (
                id uuid PRIMARY KEY,
                email text NOT NULL,
                name text NOT NULL,
                password_hash text,
                email_verified boolean NOT NULL DEFAULT false,
                disabled boolean NOT NULL DEFAULT false,
                roles text[] NOT NULL DEFAULT '{}',
                created_at timestamptz NOT NULL,
                updated_at timestamptz NOT NULL
            )
            """)
        // Addresses are stored lowercased, so one person is one account
        // however they type it.
        schema.raw("CREATE UNIQUE INDEX accounts_email_idx ON accounts (email)")
        schema.raw(
            """
            CREATE TABLE account_tokens (
                key text PRIMARY KEY,
                record bytea NOT NULL,
                expires_at timestamptz NOT NULL
            )
            """)
        schema.raw("CREATE INDEX account_tokens_expires_idx ON account_tokens (expires_at)")
    }

    func down(_ schema: SchemaBuilder) {
        schema.raw("DROP TABLE account_tokens")
        schema.raw("DROP TABLE accounts")
    }
}
