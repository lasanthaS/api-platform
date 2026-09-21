# WSO2 API Platform — API Control Plane

A standalone distribution of the API Control Plane and Platform API, orchestrated with Docker Compose. The API Control Plane is a React SPA served by a Go BFF (Backend-for-Frontend) that proxies all browser traffic same-origin and owns authentication — tokens live in a server-side session (HttpOnly cookie) and never reach the browser.

## Contents

```
wso2apip-api-control-plane-<version>/
├── README.md
├── docker-compose.yaml                          # API Control Plane + Platform API
├── scripts/
│   ├── setup.sh                                 # One-time TLS + secrets provisioning
│   └── setup.ps1                                # Same, for Windows (PowerShell)
├── configs/
│   ├── config.toml                              # Active configuration for BOTH services —
│   │                                             #   [platform_api.*] and [api_control_plane.*]
│   │                                             #   tables side by side in one file
│   └── config-template.toml                     # Full configuration reference for both
└── resources/
    ├── role-to-scope-mapping.yaml                # Platform API role-to-scope mapping (edit to change what a role grants)
    └── platform-api/
        └── db-scripts/                          # Platform API schema scripts (schema.*.sql)
```

## Prerequisites

- Docker Engine 24+
- Docker Compose v2
- `openssl`, and either `htpasswd` or Docker (used by `setup.sh` to bcrypt-hash the admin password)

## Quick Start

Run the setup script once, from the distribution root, before the first start:

```bash
./scripts/setup.sh
docker compose up
```

On **Windows**, use the PowerShell script instead — same flags, same generated files
(Git for Windows and Docker Desktop both ship the `openssl` it needs):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1
# PowerShell 7+ is also fine:  pwsh -File .\scripts\setup.ps1
docker compose up
```

`docker compose up` runs in the foreground — leave it running and use a second terminal for anything else, or press `Ctrl+C` to stop the stack. Which components it starts comes entirely from the `COMPOSE_PROFILES` line `setup.sh` wrote into `.env`; add profiles to that line (`api-control-plane`, `platform-api`) to run more of them.

`setup.sh` generates everything the stack needs — nothing is auto-generated at runtime:

| Output | Contents |
|---|---|
| `api-platform.env` (git-ignored) | `APIP_CP_ADMIN_USERNAME`, `APIP_CP_ADMIN_PASSWORD_HASH` (bcrypt) |
| `resources/keys/encryption.key` (git-ignored) | Platform API at-rest encryption key (32 bytes, 64 hex chars); read by `config.toml` via `{{ file }}`. **Retain it** — losing or changing it makes previously-encrypted secrets unreadable. |
| `resources/keys/jwt_private.pem` + `jwt_public.pem` (git-ignored) | RS256 keypair signing/verifying login JWTs; read by `config.toml` via `{{ file }}` |
| `resources/certificates/cert.pem` + `key.pem` | Self-signed TLS pair used by Platform API (SAN includes `platform-api`, `api-control-plane`, `localhost`) |
| `.env` | `COMPOSE_PROFILES` and `COMPOSE_PROJECT_NAME` — read by the `docker compose` CLI from this directory |

The admin password is generated and printed once by `setup.sh` — it is not stored anywhere; only its bcrypt hash lands in `api-platform.env`. Re-running `setup.sh` keeps existing files; pass `--force` to rotate keys and credentials, or `--certs-only` to (re)generate just the TLS pair. `ADMIN_USERNAME` / `ADMIN_PASSWORD` environment variables skip the interactive prompts (used by CI to pin known test credentials).

For production, prefer mounting secret files and referencing them from the config TOMLs with `{{ file "..." }}` instead of `api-platform.env` — see [Configuration](#configuration) below.

Verify both services are healthy:

```bash
curl -fk https://localhost:9243/health    # Platform API
curl -fk https://localhost:9743/healthz   # API Control Plane
```

Open the API Control Plane in a browser at `https://localhost:9743` and log in with the admin credentials printed by `setup.sh`.

> **Browser trust warning?** Both services use a self-signed TLS certificate by default. Click **Advanced → Proceed** to continue. See [Custom TLS Certificates](#custom-tls-certificates) to remove the warning permanently.

## Exposed Ports

| Port | Service | Description |
|------|---------|-------------|
| `9743` | API Control Plane (BFF) | HTTPS — browser entry point |
| `9243` | Platform API | HTTPS — backend REST API |

## Configuration

Both services read their settings from the single `configs/config.toml` — Platform API's `[platform_api.*]` tables and API Control Plane's `[api_control_plane.*]` tables live side by side in the same file (each service reads only its own top-level table and ignores the other's), and `docker-compose.yaml` mounts that one file into both containers. Edit it and restart the affected service — no rebuild required.

Each config key writes its value as a `'{{ env "..." }}'` token, so it can be set from the environment without editing the file — the token names the variable, by convention the key's path uppercased and prefixed `APIP_ACP_` (API Control Plane) or `APIP_CP_` (Platform API), e.g. `APIP_ACP_LOGGING_LEVEL`, `APIP_CP_DATABASE_HOST`. A key with no token is not settable from the environment: uncomment or add it in the TOML first. To source a value from a mounted file instead — the right choice for secrets — swap the token for `'{{ file "/secrets/..." }}'`. Never write a secret as a raw literal.

Environment overrides go in `api-platform.env` (git-ignored; loaded into both containers via `env_file`, format `raw`, since the bcrypt password hash contains `$`, which must not be treated as a compose interpolation variable). This is also where OIDC mode's `APIP_ACP_AUTH_OIDC_CLIENT_SECRET` belongs — it's the only file compose passes into the containers, so a separate `.env` alongside it would never reach the app.

### API Control Plane (`[api_control_plane.*]`)

| Setting | Description |
|---------|-------------|
| `[api_control_plane] domain` | Public hostname:port the console is served at |
| `[api_control_plane.server.https].cert_file` / `key_file` | HTTPS listener certificate pair. Fixed to the mounted path — not env-overridable; edit the TOML if you change the volume mount in `docker-compose.yaml` |
| `[api_control_plane.auth] mode` | `basic` (file-based quickstart) or `oidc` (external IDP) |
| `[api_control_plane.control_plane].url` | Base URL of the upstream Platform API hop |
| `[api_control_plane.control_plane].ca_file` | PEM bundle trusted for the upstream's TLS cert (appended to system roots) — the same mounted certificate as the listener above. Fixed to the mounted path, same as `cert_file`/`key_file` |
| `[api_control_plane.control_plane].tls_skip_verify` | Skip upstream cert verification — local dev only |
| `[api_control_plane.session.cookie].secure` | `true` by default, matching the console's own HTTPS listener |
| `[api_control_plane.auth.oidc].*` | Used only when `[api_control_plane.auth] mode = "oidc"` — see [OIDC](#oidc-production) below |

### Platform API (`[platform_api.*]`)

| Setting | Description |
|---------|-------------|
| `[platform_api.logging].level` | Log level (`debug`, `info`, `warn`, `error`; matched case-insensitively) |
| `[platform_api.security].encryption_key` | Single 32-byte key (64 hex chars or base64) used for all at-rest encryption (secrets, subscription tokens, WebSub HMAC secrets). Generate with `openssl rand -hex 32` |
| `[platform_api.database].driver` | `sqlite3` or `postgres` |
| `[platform_api.auth].mode` | `file` (quickstart default), `internal_token`, or `idp` — selects exactly one auth mode |
| `[platform_api.auth.jwt].public_key_file` / `private_key_file` | RS256 (asymmetric) PEM keys; `public_key_file` verifies every token, `private_key_file` signs login JWTs in `file` mode. Read via `{{ file }}` — HMAC and unsigned tokens are rejected |
| `[platform_api.auth.idp]` | JWKS-based IDP auth — active when `mode = "idp"`; configure for Asgardeo, Keycloak, Auth0, etc. |
| `[platform_api.auth.file.users]` | Local user credentials, active when `mode = "file"` (change the password hash before sharing). Each user names one or more `roles` from `resources/role-to-scope-mapping.yaml` — those roles are the whole grant, unioned |
| `[platform_api.auth.authorization].role_to_scope_mapping` | Path to the mounted `resources/role-to-scope-mapping.yaml` — edit that file to change what a role grants |
| `[platform_api.server.https]` | Listener on `:9243`; `cert_file`/`key_file` point at `cert.pem`/`key.pem` |

Each key's default value is written inline in `configs/config-template.toml` — a fully-commented reference of every available setting and its default for both components, so defaults are not restated here.

## Authentication Modes

### File-based (default)

The admin user is generated by `setup.sh` (see [Quick Start](#quick-start)). To set your own password instead, generate a new bcrypt hash:

```bash
htpasswd -bnBC 10 "" NEW_PASSWORD | tr -d ':\n'
```

Replace the `password_hash` value under `[platform_api.auth.file.users]` in `configs/config.toml` before starting.

### OIDC (production)

To delegate login to an external OIDC-compliant provider (Asgardeo, Keycloak, Auth0, etc.) instead of file-based auth, both services need to be reconfigured — the API Control Plane to send users to the IDP, and the Platform API to trust the tokens it issues.

1. Register a **confidential** OIDC application in your IDP with redirect URL `https://<your-domain>/api/auth/callback` (use `https://localhost:9743/api/auth/callback` for local development), a post-logout redirect URL, and enable the **Authorization Code** and **Refresh Token** grants.
2. **API Control Plane** (`configs/config.toml`): set `[api_control_plane.auth] mode = "oidc"`. Every `[api_control_plane.auth.oidc]` key except `scope` defaults to empty and the server refuses to start in OIDC mode until each is set — either directly in the TOML or via its `APIP_ACP_AUTH_OIDC_*` token in `api-platform.env`:

   ```bash
   APIP_ACP_AUTH_OIDC_AUTHORITY=https://idp.example.com
   APIP_ACP_AUTH_OIDC_CLIENT_ID=<your-client-id>
   APIP_ACP_AUTH_OIDC_CLIENT_SECRET=<your-client-secret>
   APIP_ACP_AUTH_OIDC_REDIRECT_URL=https://<your-domain>/api/auth/callback
   APIP_ACP_AUTH_OIDC_POST_LOGOUT_REDIRECT_URL=https://<your-domain>/login
   ```

   Leaving `APIP_ACP_AUTH_OIDC_SCOPE` unset requests the full `ap:*` scope set.

3. **Platform API** (`[platform_api.*]` tables in `configs/config.toml`): the `[platform_api.auth.idp]` fields have no env-var tokens in the quickstart file, so edit the TOML directly — set `[platform_api.auth] mode = "idp"` and fill in `jwks_url` and `issuer` for your IDP. `mode` selects exactly one auth mode, so switching to `"idp"` stops the file-based login endpoint from being used. Align `[platform_api.auth.claim_mappings]` with `[api_control_plane.auth.claim_mappings]` — both services must read the same claims out of the same token.

See `configs/config-template.toml` for the full, per-field reference of both components, and the [WSO2 API Platform documentation](https://wso2.com/api-platform/docs/) for a full OIDC setup walkthrough including Asgardeo scope registration.

## Custom TLS Certificates

`resources/certificates/` holds the TLS pair shared by both services — `cert.pem` (certificate or full chain) and `key.pem` (private key), generated by `setup.sh`. This one directory is mounted read-only into both containers, at Platform API's `/app/data/certs` and the API Control Plane's `/etc/api-control-plane/tls`. To remove the browser trust warning, replace both files with a certificate from your own CA (same file names) whose SAN list covers both hostnames (`platform-api`, `api-control-plane`, `localhost`), then restart:

```bash
docker compose up --force-recreate
```

## Compose project name

`setup.sh` pins `COMPOSE_PROJECT_NAME=wso2apip-api-control-plane-<version>-<6 hex>` in `.env` on its first run and never changes it. Compose prefixes this stack's containers, network, and volumes with it, so unpacking this zip again elsewhere on the host gets its own volumes instead of adopting this copy's data. Don't edit that line or delete `.env` — the data lives in `<project>_platform-api-data`, and a different name starts the stack empty. `down` keeps that volume; only `down -v` deletes it. To choose the name yourself — including adopting an earlier release's volumes, whose prefix `docker volume ls` shows — set it for the first run only: `COMPOSE_PROJECT_NAME=<name> ./scripts/setup.sh` (PowerShell: `$env:COMPOSE_PROJECT_NAME = '<name>'; .\scripts\setup.ps1`). It must match `^[a-z0-9][a-z0-9_-]*$`. Two API Control Plane stacks still can't run at once: both bind ports `9743` and `9243`.

## Database

The Platform API uses **SQLite** by default (data persisted in a Docker volume). To switch to PostgreSQL, update `[platform_api.database]` in `configs/config.toml`:

```toml
[platform_api.database]
driver = "postgres"
host   = "your-db-host"
port   = 5432
name   = "platform_api"
user   = "platform_api"
password = '{{ file "/secrets/platform-api/postgres_password" }}'
ssl_mode = "disable"
```

The `resources/platform-api/db-scripts/` directory contains the schema scripts (`schema.postgres.sql`, `schema.sqlite.sql`, `schema.sqlserver.sql`). The Platform API applies the appropriate schema automatically on startup — no manual SQL execution is required.

## License

Copyright (c) 2026, WSO2 LLC. (https://wso2.com)

Licensed under the Apache License, Version 2.0. You may obtain a copy of the License at
http://www.apache.org/licenses/LICENSE-2.0
