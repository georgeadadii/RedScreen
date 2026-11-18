import Foundation

// SYNTHETIC TEST DATA. NOT REAL CREDENTIALS.
//
// Every sensitive or ambiguous value below is invented for RedScreen tests and carries one of the
// reserved markers `RSFAKE`, `rsfake`, or `EXAMPLE` (the latter only for AWS's published
// documentation examples). Hosts use reserved names (`localhost`, `*.test`, `example.com`/`.org`)
// and IPv4 addresses use loopback or RFC 5737 documentation ranges. `SyntheticValuePolicy`
// enforces these rules in CI; see docs/TEST_FIXTURES.md before adding a scenario.

struct FixtureSpanMark: Equatable, Sendable {
    let id: String
    let family: FixtureSecretFamily
    let expectation: FixtureExpectation
    let note: String
}

struct FixtureRun: Sendable {
    let text: String
    let mark: FixtureSpanMark?
}

/// One text box: a full line, or a table cell when `x` is non-zero.
struct FixtureBlock: Sendable {
    let row: Int
    /// Horizontal offset in points from the left content edge.
    let x: Double
    let runs: [FixtureRun]
}

struct FixtureScenario: Sendable {
    let name: String
    let description: String
    let category: FixtureCategory
    let theme: FixtureTheme
    let fontStyle: FixtureFontStyle
    /// Canvas width in points. Rendering fails rather than clipping if text does not fit.
    let canvasWidth: Double
    let difficulties: [FixtureDifficulty]
    let blocks: [FixtureBlock]
    /// Rows drawn with a subtle background band, for table and dashboard realism.
    let stripedRows: [Int]

    init(
        name: String,
        description: String,
        category: FixtureCategory,
        theme: FixtureTheme,
        fontStyle: FixtureFontStyle,
        canvasWidth: Double,
        difficulties: [FixtureDifficulty],
        blocks: [FixtureBlock],
        stripedRows: [Int] = []
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.theme = theme
        self.fontStyle = fontStyle
        self.canvasWidth = canvasWidth
        self.difficulties = difficulties
        self.blocks = blocks
        self.stripedRows = stripedRows
    }

    var rowCount: Int { (blocks.map(\.row).max() ?? -1) + 1 }
}

// MARK: - Authoring helpers

private func plain(_ text: String) -> FixtureRun {
    FixtureRun(text: text, mark: nil)
}

private func span(
    _ text: String,
    _ mark: FixtureSpanMark
) -> FixtureRun {
    FixtureRun(text: text, mark: mark)
}

private func mark(
    _ id: String,
    _ family: FixtureSecretFamily,
    _ expectation: FixtureExpectation,
    _ note: String
) -> FixtureSpanMark {
    FixtureSpanMark(id: id, family: family, expectation: expectation, note: note)
}

/// Lays out consecutive single-column lines starting at `firstRow`.
private func lines(_ rows: [[FixtureRun]], firstRow: Int = 0) -> [FixtureBlock] {
    rows.enumerated().map { offset, runs in
        FixtureBlock(row: firstRow + offset, x: 0, runs: runs)
    }
}

private func cell(_ row: Int, _ x: Double, _ runs: FixtureRun...) -> FixtureBlock {
    FixtureBlock(row: row, x: x, runs: runs)
}

// MARK: - Corpus

enum FixtureScenarios {
    static let scales = [1, 2]

    static let all: [FixtureScenario] = [
        envFileLight,
        envFileDark,
        terminalSessionDark,
        terminalWrappedURLDark,
        jsonConfigLight,
        yamlConfigLowContrast,
        ciLogDark,
        privateKeyBlockLight,
        dashboardCloudLight,
        dashboardAPIKeysDark,
        benignCodeLight,
        benignTerminalDark,
        envDiffColumnsLight,
        supportTicketLowContrast,
    ]

    static let envFileLight: FixtureScenario = {
        let salt = mark(
            "session-salt", .envAssignment, .ambiguous,
            "Salt-like value; sensitivity depends on deployment"
        )
        return FixtureScenario(
            name: "env-file-light",
            description: "A .env file in a light editor theme mixing one secret assignment with "
                + "nearby benign settings, a port, and a credential-free localhost URL.",
            category: .envFile,
            theme: .light,
            fontStyle: .monospace,
            canvasWidth: 560,
            difficulties: [.nearbyBenign, .punctuation],
            blocks: lines([
                [plain("# Synthetic RedScreen test data - not real credentials")],
                [plain("NODE_ENV="), span("production", mark(
                    "node-env", .envAssignment, .benign, "Non-secret environment name"))],
                [plain("PORT="), span("3000", mark(
                    "port", .envAssignment, .benign, "Port number"))],
                [plain("DATABASE_PASSWORD="), span("RSFAKE-pg-7d1c9a42", mark(
                    "database-password", .envAssignment, .sensitive, "Password assignment value"))],
                [plain("API_BASE_URL="), span("http://localhost:8080/api", mark(
                    "api-base-url", .connectionString, .benign, "Credential-free localhost URL"))],
                [plain("WEBHOOK_SIGNING_SECRET="), span("RSFAKE_whsec_5Tq8Lm2Vx9", mark(
                    "webhook-secret", .envAssignment, .sensitive, "Signing secret assignment"))],
                [plain("SESSION_SALT="), span("RSFAKEa1b2c3", salt)],
                [plain("LOG_LEVEL=debug")],
                [plain("FEATURE_FLAGS=search,exports")],
            ])
        )
    }()

    static let envFileDark = FixtureScenario(
        name: "env-file-dark",
        description: "A shell profile in a dark theme exporting AWS documentation example keys, "
            + "a quoted secret, a Redis URL with a password, a commit SHA, and a placeholder.",
        category: .envFile,
        theme: .dark,
        fontStyle: .monospace,
        canvasWidth: 640,
        difficulties: [.quotedValue, .punctuation],
        blocks: lines([
            [plain("# RedScreen synthetic fixture (fake values only)")],
            [plain("export AWS_ACCESS_KEY_ID="), span("AKIAIOSFODNN7EXAMPLE", mark(
                "aws-access-key-id", .providerKeyShape, .sensitive,
                "Access key ID exported beside its secret"))],
            [
                plain("export AWS_SECRET_ACCESS_KEY=\""),
                span("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", mark(
                    "aws-secret-access-key", .envAssignment, .sensitive,
                    "Quoted secret key; quotes are not part of the value")),
                plain("\""),
            ],
            [plain("export AWS_REGION="), span("us-east-1", mark(
                "aws-region", .envAssignment, .benign, "Region name"))],
            [
                plain("REDIS_URL='redis://:"),
                span("RSFAKE-redis-77", mark(
                    "redis-password", .connectionString, .sensitive,
                    "Password component of a connection URL")),
                plain("@cache.internal.test:6379/0'"),
            ],
            [plain("GIT_SHA="), span("3f869f9c2b7e4d1a0f5e6c8b9a7d3e2f1c0b4a59", mark(
                "git-sha", .highEntropyContextual, .benign, "Commit SHA"))],
            [plain("JWT_SECRET="), span("changeme", mark(
                "jwt-placeholder", .credentialKeyword, .benign, "Placeholder value"))],
            [plain("INTERNAL_ID="), span("RSFAKE7f3a9c2e1b5d", mark(
                "internal-id", .highEntropyContextual, .ambiguous,
                "Random-looking identifier without secret context"))],
        ])
    )

    static let terminalSessionDark = FixtureScenario(
        name: "terminal-session-dark",
        description: "A dark terminal session exporting a GitHub-style token, sending a bearer "
            + "header with curl, printing a UUID request ID, and showing a masked token.",
        category: .terminal,
        theme: .dark,
        fontStyle: .monospace,
        canvasWidth: 620,
        difficulties: [.punctuation, .quotedValue],
        blocks: lines([
            [plain("demo % # RedScreen synthetic fixture - fake tokens")],
            [plain("demo % export GITHUB_TOKEN="), span("ghp_RSFAKE0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c",
                mark("github-token", .providerKeyShape, .sensitive, "GitHub-style token shape"))],
            [
                plain("demo % curl -H \"Authorization: Bearer "),
                span("RSFAKE-tok-9Qw2Ex7Rt5", mark(
                    "curl-bearer", .bearerToken, .sensitive, "Bearer credential in a header")),
                plain("\" \\"),
            ],
            [plain(">   https://api.example.test/v1/projects")],
            [
                plain("{\"projects\":[],\"request_id\":\""),
                span("c0ffee00-1234-4abc-8def-000000000001", mark(
                    "request-uuid", .highEntropyContextual, .benign, "Request UUID")),
                plain("\"}"),
            ],
            [plain("demo % gh auth status")],
            [plain("  Token: "), span("ghp_************************************", mark(
                "masked-token", .providerKeyShape, .benign, "Already-masked token"))],
            [plain("  Token scopes: 'repo', 'read:org'")],
        ])
    )

    static let terminalWrappedURLDark: FixtureScenario = {
        let password = mark(
            "wrapped-db-password", .connectionString, .sensitive,
            "Connection password wrapped across two terminal lines"
        )
        let replica = mark(
            "wrapped-replica-url", .connectionString, .benign,
            "Credential-free localhost URL wrapped across two lines"
        )
        return FixtureScenario(
            name: "terminal-wrapped-url-dark",
            description: "A narrow dark terminal where a database URL's password and a benign "
                + "localhost URL both wrap onto the following line.",
            category: .terminal,
            theme: .dark,
            fontStyle: .monospace,
            canvasWidth: 400,
            difficulties: [.wrappedValue, .nearbyBenign],
            blocks: lines([
                [plain("demo % grep URL .env  # synthetic")],
                [plain("DATABASE_URL=postgres://app_user:"), span("RSFAKE-", password)],
                [span("Pg-9f8e7d", password), plain("@db.internal.test:5432/orders")],
                [plain("READ_REPLICA_URL="), span("postgres://localhost:5432/", replica)],
                [span("orders_replica", replica)],
                [plain("demo % psql \"$DATABASE_URL\" -c 'select 1'")],
            ])
        )
    }()

    static let jsonConfigLight = FixtureScenario(
        name: "json-config-light",
        description: "A JSON config in a light editor with quoted API key and client secret, a "
            + "token TTL, a public client ID, a password hint, and a package checksum.",
        category: .jsonConfig,
        theme: .light,
        fontStyle: .monospace,
        canvasWidth: 600,
        difficulties: [.quotedValue, .nearbyBenign, .punctuation],
        blocks: lines([
            [plain("// RedScreen synthetic fixture: config.json (fake values)")],
            [plain("{")],
            [plain("  \"service\": \"billing-demo\",")],
            [plain("  \"endpoint\": \"http://localhost:8080\",")],
            [plain("  \"apiKey\": \""), span("RSFAKE-api-3e7b91c4d2", mark(
                "json-api-key", .credentialKeyword, .sensitive, "Quoted API key value")),
                plain("\",")],
            [plain("  \"tokenTTL\": "), span("3600", mark(
                "token-ttl", .credentialKeyword, .benign, "Numeric TTL beside a token keyword")),
                plain(",")],
            [plain("  \"clientId\": \""), span("web-dashboard-client", mark(
                "client-id", .credentialKeyword, .benign, "Public client identifier")),
                plain("\",")],
            [plain("  \"clientSecret\": \""), span("RSFAKE-cs-81fa22b0e9", mark(
                "client-secret", .credentialKeyword, .sensitive, "Quoted client secret")),
                plain("\",")],
            [plain("  \"passwordHint\": \""), span("RSFAKE-hint-blue42", mark(
                "password-hint", .credentialKeyword, .ambiguous, "Hint that may reveal a password")),
                plain("\",")],
            [plain("  \"checksum\": \""), span("sha256-9b74c9897bac770ffc029102a200c5de", mark(
                "checksum", .highEntropyContextual, .benign, "Package checksum")),
                plain("\"")],
            [plain("}")],
        ])
    )

    static let yamlConfigLowContrast = FixtureScenario(
        name: "yaml-config-low-contrast",
        description: "A low-contrast docker-compose YAML file with a password, a MySQL URL with "
            + "credentials, a loopback Redis URL, a username-only Mongo URL, and a length policy.",
        category: .yamlConfig,
        theme: .lowContrast,
        fontStyle: .monospace,
        canvasWidth: 620,
        difficulties: [.nearbyBenign, .punctuation],
        blocks: lines([
            [plain("# RedScreen synthetic fixture: docker-compose.yml (fake values)")],
            [plain("services:")],
            [plain("  api:")],
            [plain("    image: demo/api:1.4")],
            [plain("    ports: [\"8080:8080\"]")],
            [plain("    environment:")],
            [plain("      POSTGRES_PASSWORD: "), span("RSFAKE-compose-pw-55", mark(
                "compose-password", .credentialKeyword, .sensitive, "YAML password value"))],
            [
                plain("      DATABASE_URL: mysql://svc:"),
                span("RSFAKE-my-31", mark(
                    "mysql-password", .connectionString, .sensitive,
                    "Password component of a connection URL")),
                plain("@mysql.internal.test/app"),
            ],
            [plain("      CACHE_URL: "), span("redis://127.0.0.1:6379", mark(
                "cache-url", .connectionString, .benign, "Credential-free loopback URL"))],
            [
                plain("      MONGO_URL: mongodb://"),
                span("rsfake_reporter", mark(
                    "mongo-user", .connectionString, .ambiguous,
                    "Username without a password")),
                plain("@mongo.internal.test/db"),
            ],
            [plain("      PASSWORD_MIN_LENGTH: \""), span("12", mark(
                "password-min-length", .credentialKeyword, .benign,
                "Numeric policy beside a password keyword")),
                plain("\"")],
        ])
    )

    static let ciLogDark = FixtureScenario(
        name: "ci-log-dark",
        description: "A dark CI log with an abbreviated commit SHA, an already-masked token, an "
            + "integrity hash, a leaked signing secret and bearer token, a truncated bearer "
            + "value, and a bearer variable reference.",
        category: .ciLog,
        theme: .dark,
        fontStyle: .monospace,
        canvasWidth: 640,
        difficulties: [.punctuation, .nearbyBenign],
        blocks: lines([
            [plain("[ci] RedScreen synthetic CI log - fake values only")],
            [plain("12:00:01 Run actions/checkout@v4 (ref "), span("63c2d54687ed", mark(
                "ci-commit", .highEntropyContextual, .benign, "Abbreviated commit SHA")),
                plain(")")],
            [plain("12:00:04 Using registry token "), span("***", mark(
                "ci-masked", .credentialKeyword, .benign, "CI-masked value"))],
            [plain("12:00:09 integrity "), span("sha512-Zm9vYmFyYmF6cXV4cXV1eA==", mark(
                "ci-integrity", .highEntropyContextual, .benign, "Package integrity hash"))],
            [plain("12:00:12 DEBUG webhook signing secret="), span("7Hq2RSFAKEz9Lp4Wm8Xc3Vb6Nf1Kd5Tg",
                mark("ci-signing-secret", .highEntropyContextual, .sensitive,
                    "High-entropy value with secret context"))],
            [plain("12:00:15 DEBUG Authorization: Bearer "),
                span("RSFAKE.eyJhbGciOiJIUzI1NiJ9.RSFAKEsig", mark(
                    "ci-bearer", .bearerToken, .sensitive, "JWT-shaped bearer credential"))],
            [plain("12:00:18 deploy nonce "), span("rsfake9c1f2e7a4b8d6c", mark(
                "ci-nonce", .highEntropyContextual, .ambiguous, "Nonce with weak secret context"))],
            [plain("12:00:20 Retrying with Bearer "), span("RSFAKE-tr...", mark(
                "ci-truncated-bearer", .bearerToken, .ambiguous, "Truncated bearer value"))],
            [plain("12:00:22 Authorization: Bearer "), span("$DEPLOY_TOKEN", mark(
                "ci-bearer-variable", .bearerToken, .benign, "Variable reference, not a value"))],
            [plain("12:00:25 Job succeeded")],
        ])
    )

    static let privateKeyBlockLight: FixtureScenario = {
        let rsa = mark(
            "rsa-private-key", .privateKeyHeader, .sensitive,
            "Complete private key block including armor lines"
        )
        let certificate = mark(
            "certificate", .privateKeyHeader, .benign, "Public certificate block"
        )
        let encrypted = mark(
            "encrypted-private-key", .privateKeyHeader, .ambiguous,
            "Passphrase-encrypted private key block"
        )
        return FixtureScenario(
            name: "private-key-block-light",
            description: "A light terminal printing a synthetic RSA private key block, a public "
                + "certificate block, and an encrypted private key block.",
            category: .terminal,
            theme: .light,
            fontStyle: .monospace,
            canvasWidth: 560,
            difficulties: [.multilineBlock, .nearbyBenign],
            blocks: lines([
                [plain("demo % cat synthetic-keys.pem  # fake, not a usable key")],
                [span("-----BEGIN RSA PRIVATE KEY-----", rsa)],
                [span("RSFAKEsyntheticKeyBodyLine0001NotARealKeyAAAA", rsa)],
                [span("RSFAKEsyntheticKeyBodyLine0002NotARealKeyBBBB", rsa)],
                [span("RSFAKEsyntheticKeyBodyLine0003NotARealKeyCC==", rsa)],
                [span("-----END RSA PRIVATE KEY-----", rsa)],
                [span("-----BEGIN CERTIFICATE-----", certificate)],
                [span("MIIBsyntheticPublicCertificateBodyLine0001", certificate)],
                [span("-----END CERTIFICATE-----", certificate)],
                [span("-----BEGIN ENCRYPTED PRIVATE KEY-----", encrypted)],
                [span("RSFAKEsyntheticEncryptedKeyBodyLine0001DDDD", encrypted)],
                [span("-----END ENCRYPTED PRIVATE KEY-----", encrypted)],
            ])
        )
    }()

    static let dashboardCloudLight = FixtureScenario(
        name: "dashboard-cloud-light",
        description: "A light, proportional-font cloud console table with an access key ID, "
            + "its secret access key, and nearby benign region, date, and address cells.",
        category: .dashboard,
        theme: .light,
        fontStyle: .proportional,
        canvasWidth: 600,
        difficulties: [.multiColumn, .nearbyBenign],
        blocks: [
            cell(0, 0, plain("Cloud console - RedScreen synthetic fixture (fake data)")),
            cell(1, 0, plain("Access key ID")),
            cell(1, 190, span("AKIAI44QH8DHBEXAMPLE", mark(
                "console-access-key-id", .providerKeyShape, .ambiguous,
                "Access key ID shown without its secret"))),
            cell(2, 0, plain("Secret access key")),
            cell(2, 190, span("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", mark(
                "console-secret-key", .credentialKeyword, .sensitive,
                "Secret key in a labelled table cell"))),
            cell(3, 0, plain("Region")),
            cell(3, 190, plain("us-west-2")),
            cell(4, 0, plain("Created")),
            cell(4, 190, plain("2026-01-15 09:30 UTC")),
            cell(5, 0, plain("Last used from")),
            cell(5, 190, plain("api.example.test via 203.0.113.10")),
            cell(6, 0, plain("Status")),
            cell(6, 190, plain("Active")),
        ],
        stripedRows: [1, 3, 5]
    )

    static let dashboardAPIKeysDark = FixtureScenario(
        name: "dashboard-api-keys-dark",
        description: "A dark, proportional-font API key dashboard with a full secret key, a "
            + "partially masked key, a publishable key, a webhook secret, and usage counts.",
        category: .dashboard,
        theme: .dark,
        fontStyle: .proportional,
        canvasWidth: 620,
        difficulties: [.multiColumn, .nearbyBenign],
        blocks: [
            cell(0, 0, plain("API keys - RedScreen synthetic fixture")),
            cell(1, 0, plain("Name")),
            cell(1, 160, plain("Key")),
            cell(1, 460, plain("Requests (24h)")),
            cell(2, 0, plain("Production secret")),
            cell(2, 160, span("svc_live_RSFAKE4f8a2c9e7b1d", mark(
                "dashboard-live-key", .credentialKeyword, .sensitive,
                "Full secret key in a key column"))),
            cell(2, 460, plain("48,213")),
            cell(3, 0, plain("Staging secret")),
            cell(3, 160, span("svc_test_RSFAKE\u{2022}\u{2022}\u{2022}\u{2022}3c1d", mark(
                "dashboard-masked-key", .providerKeyShape, .ambiguous,
                "Partially masked key"))),
            cell(3, 460, plain("1,024")),
            cell(4, 0, plain("Publishable")),
            cell(4, 160, span("pk_pub_RSFAKE9a8b7c6d", mark(
                "dashboard-publishable-key", .providerKeyShape, .benign,
                "Publishable client-side key"))),
            cell(4, 460, plain("310,577")),
            cell(5, 0, plain("Webhook secret")),
            cell(5, 160, span("whsec_RSFAKE2Lm8Qx4Tz6Wv", mark(
                "dashboard-webhook-secret", .highEntropyContextual, .sensitive,
                "High-entropy value labelled as a secret"))),
            cell(5, 460, plain("0")),
        ],
        stripedRows: [2, 4]
    )

    static let benignCodeLight = FixtureScenario(
        name: "benign-code-light",
        description: "Light-theme Swift source with credential keywords, a UUID literal, a "
            + "reserved test URL, a commit SHA, and an interpolated bearer header but no secrets.",
        category: .benignCode,
        theme: .light,
        fontStyle: .monospace,
        canvasWidth: 640,
        difficulties: [.nearbyBenign, .punctuation],
        blocks: lines([
            [plain("// RedScreen synthetic fixture: benign source code")],
            [plain("let password = "), span("try keychain.read(account: user)", mark(
                "keychain-read", .credentialKeyword, .benign, "Keyword without a literal value"))],
            [plain("let requestID = UUID(uuidString: \""),
                span("123e4567-e89b-12d3-a456-426614174000", mark(
                    "uuid-literal", .highEntropyContextual, .benign, "UUID literal")),
                plain("\")")],
            [plain("let port = 8080")],
            [plain("let endpoint = URL(string: \""), span("https://api.example.test/v1", mark(
                "endpoint-url", .connectionString, .benign, "Credential-free URL")),
                plain("\")!")],
            [plain("// TODO: rotate the token before release")],
            [plain("let commit = \""), span("d7ff0b2693f9daac91b2338d2eb5dd02568a19a9", mark(
                "commit-literal", .highEntropyContextual, .benign, "Commit SHA literal")),
                plain("\"")],
            [plain("let header = \"Authorization: Bearer "), span("\\(token)", mark(
                "bearer-interpolation", .bearerToken, .benign, "String interpolation")),
                plain("\"")],
        ])
    )

    static let benignTerminalDark = FixtureScenario(
        name: "benign-terminal-dark",
        description: "A dark terminal with git log SHAs, an npm integrity hash, a loopback dev "
            + "server URL, and a public SSH key fingerprint; nothing should be redacted.",
        category: .terminal,
        theme: .dark,
        fontStyle: .monospace,
        canvasWidth: 640,
        difficulties: [.nearbyBenign],
        blocks: lines([
            [plain("demo % git log --oneline -3  # RedScreen synthetic fixture")],
            [span("d7ff0b2", mark(
                "log-sha-1", .highEntropyContextual, .benign, "Abbreviated commit SHA")),
                plain(" feat: define redaction document and geometry")],
            [span("63c2d54", mark(
                "log-sha-2", .highEntropyContextual, .benign, "Abbreviated commit SHA")),
                plain(" feat: implement secure image lifecycle")],
            [plain("81985d5 Merge pull request from feature branch")],
            [plain("demo % npm ci")],
            [plain("added 214 packages, integrity "), span("sha512-Zm9vYmFyYmF6cXV4cXV1eA==", mark(
                "npm-integrity", .highEntropyContextual, .benign, "Package integrity hash"))],
            [plain("demo % open "), span("http://127.0.0.1:5173/", mark(
                "dev-server-url", .connectionString, .benign, "Loopback dev server URL"))],
            [plain("demo % ssh-keygen -lf ~/.ssh/id_ed25519.pub")],
            [plain("256 SHA256:"), span("RSFAKEfingerprintAbCdEf0123456789", mark(
                "ssh-fingerprint", .highEntropyContextual, .benign, "Public key fingerprint")),
                plain(" dev@workstation (ED25519)")],
        ])
    )

    static let envDiffColumnsLight = FixtureScenario(
        name: "env-diff-columns-light",
        description: "A light side-by-side diff of .env.example placeholders against .env.local "
            + "values, so benign placeholders sit directly beside real-looking secrets.",
        category: .envFile,
        theme: .light,
        fontStyle: .monospace,
        canvasWidth: 640,
        difficulties: [.multiColumn, .nearbyBenign],
        blocks: [
            cell(0, 0, plain(".env.example")),
            cell(0, 300, plain(".env.local  # synthetic")),
            cell(1, 0, plain("API_KEY="), span("your-api-key-here", mark(
                "example-api-key", .envAssignment, .benign, "Placeholder value"))),
            cell(1, 300, plain("API_KEY="), span("RSFAKE-key-6b2d91", mark(
                "local-api-key", .envAssignment, .sensitive, "API key assignment value"))),
            cell(2, 0, plain("DB_PASS="), span("<password>", mark(
                "example-db-pass", .credentialKeyword, .benign, "Placeholder value"))),
            cell(2, 300, plain("DB_PASS="), span("RSFAKE-db-0c7e", mark(
                "local-db-pass", .credentialKeyword, .sensitive, "Password assignment value"))),
            cell(3, 0, plain("SMTP_USER=mailer@example.com")),
            cell(3, 300, plain("SMTP_USER=mailer@example.com")),
            cell(4, 0, plain("SIGNING_KEY=")),
            cell(4, 300, plain("SIGNING_KEY="), span("RSFAKEq9W3e7R1t5Y8u2I6", mark(
                "local-signing-key", .highEntropyContextual, .sensitive,
                "High-entropy value with key context"))),
            cell(5, 0, plain("DEBUG=false")),
            cell(5, 300, plain("DEBUG=true")),
            cell(6, 300, plain("TRACE_TOKEN="), span("rsfake-ambig-01", mark(
                "local-trace-token", .credentialKeyword, .ambiguous,
                "Token keyword with a short value"))),
        ],
        stripedRows: [0]
    )

    static let supportTicketLowContrast = FixtureScenario(
        name: "support-ticket-low-contrast",
        description: "A low-contrast, proportional-font support ticket where passwords appear in "
            + "punctuated prose, beside a reserved support address and a reference ID.",
        category: .dashboard,
        theme: .lowContrast,
        fontStyle: .proportional,
        canvasWidth: 620,
        difficulties: [.punctuation, .quotedValue],
        blocks: lines([
            [plain("Support ticket #4821 (RedScreen synthetic fixture - fake data)")],
            [plain("Customer: I reset it to '"), span("RSFAKE-Temp!Pass#2026", mark(
                "ticket-reset-value", .credentialKeyword, .ambiguous,
                "Password-like value in prose without a key label")),
                plain("' but login fails.")],
            [plain("Agent: Please never share your password; use the reset link.")],
            [plain("Customer: OK - the new password is: "), span("RSFAKE-n3w.P@ss_77", mark(
                "ticket-new-password", .credentialKeyword, .sensitive,
                "Password after an explicit label")),
                plain(" (temporary).")],
            [plain("Agent: Thanks! Ticket mailbox: support@example.org, ref "),
                span("0x7F3A-22", mark(
                    "ticket-ref", .highEntropyContextual, .benign, "Ticket reference ID"))],
        ])
    )
}
