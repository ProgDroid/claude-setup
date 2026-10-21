---
name: rust-standards
description: Use when writing, reviewing or testing Rust code, or setting up a Rust project - tooling, the canonical clippy lint table, errors and conventions.
---

# Rust Environment Standards

## Runtime & Tooling

- **Edition**: Always use `edition = "2024"` in `Cargo.toml`
- **Workspace**: Use Cargo workspaces for multi-crate projects (`resolver = "3"`)
- **Windows builds (Windows only)**: If using `aws-lc-sys` (e.g. for JWT), set `AWS_LC_SYS_PREBUILT_NASM=1` before building

### Common Commands
```bash
# Build
cargo build                          # Debug build
cargo build --release                # Optimized build
AWS_LC_SYS_PREBUILT_NASM=1 cargo build  # Windows + aws-lc-sys

# Check (faster than build — no codegen)
cargo check --workspace              # Check all crates
cargo check --package <crate>        # Check one crate

# Testing
cargo test --workspace               # Run all tests
cargo test --workspace -- --nocapture  # Show stdout
cargo test <test_name>               # Run specific test

# Offline query cache (sqlx)
DATABASE_URL=postgres://... cargo sqlx prepare --workspace
# Commit .sqlx/ so CI doesn't need a live DB

# Linting — the lint POLICY lives in Cargo.toml `[lints.clippy]` (see below),
# so the command itself is bare. Run at warn locally, deny in CI.
cargo clippy --all-targets                 # local (warns)
cargo clippy --all-targets -- -D warnings  # CI gate (warnings → errors)

# In a CI workflow, pass -D warnings ON THIS COMMAND, never as a job-wide
# `env: RUSTFLAGS: -D warnings`. RUSTFLAGS applies to rustc for every step, so
# it also denies plain rustc warnings during build and test — a stricter,
# different rule than the project's, which fails the pipeline on warnings
# clippy never flagged. It also changes the flag hash, busting the cargo cache.

# Auto-fix everything clippy can fix mechanically, then hand-fix the rest:
cargo clippy --fix --allow-dirty --all-targets

# Formatting
cargo fmt --all

# Dependency audit
cargo audit                          # Requires: cargo install cargo-audit
```

## Clippy Lint Policy — `[lints.clippy]` in Cargo.toml (single source of truth)

Lint configuration lives in **`Cargo.toml`**, not in CLI flags. This is the one
place CI and any manual `cargo clippy` both read, so the layers
cannot drift. **Add this block to every Rust project when you start working on it**
(for a workspace, use `[workspace.lints.clippy]` in the root + `[lints] workspace = true`
in each member crate):

```toml
# Groups get priority -1 so the individual `allow`s (priority 0) override them.
[lints.clippy]
all = { level = "warn", priority = -1 }
pedantic = { level = "warn", priority = -1 }
nursery = { level = "warn", priority = -1 }
missing_docs_in_private_items = "allow"
separated_literal_suffix = "allow"
implicit_return = "allow"
print_stderr = "allow"
exhaustive_enums = "allow"
exhaustive_structs = "allow"
single_char_lifetime_names = "allow"
missing_inline_in_public_items = "allow"
self_named_module_files = "allow"
wildcard_enum_match_arm = "allow"
pattern_type_mismatch = "allow"
std_instead_of_core = "allow"
```

- **Local:** lints are `warn` (non-blocking); run bare `cargo clippy` so it honours this
  config. There is no edit-time clippy hook any more (removed 2026-10-18: in 1,202 runs its
  output, raw cargo JSON, never reached the model). Compile errors arrive after each edit
  from `rust-analyzer-lsp` instead; clippy's lints surface only when clippy runs.
- **CI:** runs `cargo clippy --all-targets -- -D warnings`, which promotes the
  warn-level lints to hard errors. `allow`ed lints stay quiet.
- **Starting a Rust project:** ensure `Cargo.toml` has the block above (pedantic + nursery). It is
  the single source of truth read by CI and manual runs, so add it rather than passing clippy
  flags on the command line. Remediate with `cargo clippy --fix --allow-dirty --all-targets`;
  enforce with `cargo clippy --all-targets -- -D warnings`.
- **Per-item exceptions:** use a local `#[allow(clippy::lint_name)]` with a one-line
  reason, not a new entry in the global table.

## Code Quality — Mandatory Checks

Always run **in this order** after any code change:

1. `cargo fmt --all` — format
2. `cargo check --workspace` — fast type-check (catches most errors)
3. `cargo clippy --fix --allow-dirty --all-targets` then `cargo clippy --all-targets -- -D warnings` — auto-fix, then enforce zero warnings (config from `[lints.clippy]`)
4. `cargo test --workspace` — run tests

**Never push code that fails `cargo check` or `cargo clippy -- -D warnings`.**

## IDE / LSP Diagnostics — Trust Cargo, Not Inline Diagnostics

If the session pushes `<new-diagnostics>` reminders (tagged `(rust-analyzer)`/`(rustc)`), they can
arrive right after each edit and snapshot an invalid intermediate state during multi-edit work, so
they can show **false** "cannot find / never used / type mismatch" errors that the real toolchain
contradicts.
- **Source of truth = `cargo check`/`clippy`/`test`.** Read the actual output; grep
  for `error[`/`FAILED`. Never infer success from a piped exit code.
- Treat auto-pushed diagnostics as advisory and confirm with cargo before acting. If the session has
  an on-demand LSP or diagnostics tool, call it at a settled point, after the edits land.

## Error Handling

### Never Use `unwrap()` or `expect()`

`unwrap()` and `expect()` panic at runtime. Prefer:

```rust
// BAD
let val = some_option.unwrap();
let val = result.expect("it should work");

// GOOD — propagate with ?
fn my_fn() -> Result<Foo, Error> {
    let val = some_result?;          // propagates the error
    let inner = option.ok_or(Error::NotFound)?;  // convert Option → Result
    Ok(val)
}

// GOOD — handle explicitly when you genuinely control the branch
if let Some(val) = some_option {
    // use val
}

// ACCEPTABLE in tests or truly unreachable code
let val = some_option.unwrap_or_default();
let val = some_option.unwrap_or_else(|| fallback());
```

The only acceptable uses of `unwrap()`/`expect()`:
- In `#[test]` functions (never in production paths)
- On truly infallible operations where the type system cannot prove it (document why)

### Domain Error Enum with `thiserror`

Use `thiserror` to define a single typed error enum per crate. Use `#[from]` for automatic conversion.

```rust
use actix_web::{http::StatusCode, HttpResponse, ResponseError};

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("Requested resource not found")]
    NotFound,
    #[error("Unauthorized")]
    Unauthorised,
    #[error("Invalid request data")]
    InvalidRequest,
    #[error("Database error")]
    Database(#[from] sqlx::Error),
    #[error("IO error")]
    Io(#[from] std::io::Error),
}

// Type alias so you don't repeat Result<T, Error> everywhere
pub type ServerResult<T> = Result<T, Error>;
```

### `/// # Errors` Doc Comments

Every fallible public function must document its error conditions:

```rust
/// # Errors
/// Returns `Error::NotFound` if no record matches the given ID.
/// Returns `Error::Database` if the query fails.
pub async fn get_by_id(&self, id: i32) -> ServerResult<Calendar> {
    // ...
}
```

### Option → Result Conversions

```rust
// Prefer ok_or / ok_or_else over match on Option
let user = db.find(id).await?.ok_or(Error::NotFound)?;

// For owned errors (cheap to construct)
.ok_or(Error::NotFound)?

// For expensive/complex errors (lazy)
.ok_or_else(|| Error::Custom(format!("not found: {id}")))?
```

### Auth Failures — Never Leak User Existence

Always return the same error regardless of whether the user exists or the password is wrong:

```rust
// BAD — leaks whether the email exists
let user = db.get_user_by_email(email).await.map_err(|_| Error::UserNotFound)?;
if !check_password(password, &user.hash) {
    return Err(Error::WrongPassword);
}

// GOOD — uniform error regardless of failure mode
let Ok(user) = db.get_user_by_email(email).await else {
    return Err(Error::Unauthorised);
};
if !check_password(password, &user.hash) {
    return Err(Error::Unauthorised);
}
```

## Logging

Use the `log` crate macros. Never `eprintln!` or `println!` in production paths — they bypass the logging infrastructure.

```rust
use log::{debug, error, info, warn};

// GOOD
log::error!("Failed to connect to Redis: {err}");
log::info!("User {} authenticated", user.id);
log::debug!("Cache miss for key: {key}");

// BAD
eprintln!("error: {err}");   // bypasses log filtering/formatting
println!("ok");               // not structured, not filterable
```

## Code Annotations

### `#[must_use]` on Pure Functions

```rust
// Mark pure/builder functions that should not be silently discarded
#[must_use]
pub fn build(self) -> Config { ... }

#[must_use]
pub const fn is_empty(&self) -> bool { self.items.is_empty() }
```

### `const fn` Where Possible

```rust
// Prefer const fn for compile-time computable logic
#[must_use]
pub const fn max_retries() -> u32 { 3 }
```

## Database (sqlx)

### Offline Query Cache

sqlx verifies queries at compile time. Keep `.sqlx/` committed so builds work without a live DB:

```bash
DATABASE_URL=postgres://user:pass@host:port/db cargo sqlx prepare --workspace
# → generates .sqlx/ — commit this to the repo
```

### Transactions for Multi-Table Mutations

Any operation that writes to more than one table must use a transaction:

```rust
let mut tx = pool.begin().await?;

sqlx::query!("INSERT INTO orders ...").execute(&mut *tx).await?;
sqlx::query!("UPDATE inventory ...").execute(&mut *tx).await?;

tx.commit().await?;
// If any step fails, ? propagates the error and the transaction is rolled back
```

## Caching / Redis

### Never Use `KEYS` — Always `SCAN`

`KEYS` is O(N) and blocks Redis on large keyspaces. Use `SCAN` with a cursor loop:

```rust
// BAD
let keys: Vec<String> = redis::cmd("KEYS").arg("prefix:*").query_async(&mut conn).await?;

// GOOD
let mut cursor = 0u64;
let mut all_keys = Vec::new();
loop {
    let (next_cursor, keys): (u64, Vec<String>) = redis::cmd("SCAN")
        .arg(cursor)
        .arg("MATCH").arg("prefix:*")
        .arg("COUNT").arg(100)
        .query_async(&mut conn)
        .await?;
    all_keys.extend(keys);
    cursor = next_cursor;
    if cursor == 0 { break; }
}
```

### Cache TTL Constants

Define TTL constants as `const u64` (seconds) at the module level:

```rust
pub const CACHE_TTL_ITEM: u64 = 3600;    // 1 hour
pub const CACHE_TTL_SEARCH: u64 = 1800;  // 30 minutes
pub const CACHE_TTL_CALENDAR: u64 = 7200; // 2 hours
```

## Testing

Tests live in the **same file** as the code under test, in a `#[cfg(test)] mod tests` block:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_email_validation() {
        assert!(is_valid_email("user@example.com"));
        assert!(!is_valid_email("notanemail"));
    }

    #[tokio::test]
    async fn test_async_operation() {
        // async tests need #[tokio::test]
    }
}
```

## API Responses

All error responses must return `{"error":"..."}` JSON — never plain text:

```rust
// Implement ResponseError for the domain error type
impl ResponseError for Error {
    fn error_response(&self) -> HttpResponse {
        HttpResponse::build(self.status_code())
            .json(serde_json::json!({ "error": self.to_string() }))
    }

    fn status_code(&self) -> StatusCode {
        match self {
            Self::NotFound => StatusCode::NOT_FOUND,
            Self::Unauthorised => StatusCode::UNAUTHORIZED,
            Self::InvalidRequest => StatusCode::BAD_REQUEST,
            Self::Database(_) | Self::Io(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }
}
```

## Dependency Injection (Actix-Web)

Inject dependencies via `web::Data<T>`. Construct all state **before** `HttpServer::new` — closures passed to `HttpServer::new` cannot borrow from outer scope safely:

```rust
// Build state before HttpServer::new
let db = web::Data::new(UserMapper::new(db_config).await?);
let cache = web::Data::new(Cache::new(...).await?);

HttpServer::new(move || {
    App::new()
        .app_data(db.clone())
        .app_data(cache.clone())
        .service(auth_routes())
})
.bind(addr)?
.run()
.await
```

## Project Layout (Workspace)
```
project-root/
├── Cargo.toml           # workspace manifest
├── Cargo.lock           # always commit for binaries
├── .sqlx/               # sqlx offline query cache — commit this
├── server/
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs
│       ├── server.rs        # App factory + route registration
│       ├── error.rs         # Domain error enum
│       ├── config/          # Config structs
│       ├── controllers/     # HTTP handlers
│       ├── entity/          # Domain structs
│       ├── mappers/         # DB ↔ domain layer (repository pattern)
│       ├── middleware/       # Auth middleware, etc.
│       └── services/        # Business logic
├── common/              # Shared types crate
└── <other-crates>/
```
