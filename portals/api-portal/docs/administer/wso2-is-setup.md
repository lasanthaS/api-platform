# WSO2 Identity Server Setup

This guide walks through configuring a self-hosted **WSO2 Identity Server** (7.1+) as the identity provider for a multi-org API Portal deployment, and covers everything else needed to go from "IS and API Portal are both running" to "tenants can be onboarded" (Section 5).

If you're looking for the cloud equivalent, see [Asgardeo Setup](asgardeo-setup.md) — the org model is the same (one shared application, one devportal org per IS sub-organization), but IS is self-hosted and configured entirely through its own REST API/Console rather than a SaaS console.

## Overview

**How it works end-to-end** (identical in shape to the Asgardeo flow):

1. One OIDC application ("API Portal") is registered in IS's **root** organization and shared to every sub-organization (`shareWithAllChildren`). Every sub-org gets its own automatic copy of it (a "fragment application") with its own `client_id`/`client_secret`.
2. A devportal organization maps 1:1 to one IS (sub-)organization, matched by the `org_id` claim in the access/ID token issued for that org.
3. Two **shared application roles** — `dp_admin` and `dp_subscriber` — are created once on the root app and automatically appear on every org's fragment app copy. Assigning a user one of these roles (per-org) is what makes the devportal's role-based authorization (`[api_portal.auth.authorization.portal_roles]`) actually grant them anything.
4. Everything after the root app exists — registering the sub-org, configuring its fragment app, creating the org's users, creating the org's own OAuth2 application (its "key manager" client), seeding its subscription plans and catalog, and creating its portal application(s) — is a per-tenant onboarding flow, covered in Section 5.

This guide covers the one-time root-app setup (sections 1-4) first, then that per-tenant flow (Section 5).

## Prerequisites

- WSO2 IS 7.1+ running and reachable (this guide uses `https://localhost:9443` and the default `admin`/`admin` super-tenant credentials — adjust both for your environment).
- `curl` and `jq` on the machine running these commands.
- The API Portal's expected browser-facing URL already decided (this guide uses `http://localhost:9543`) — the callback URLs below must match exactly.

Every step below is idempotent-*ish* in the sense that re-running a `POST` will 409 on a duplicate — doing these by hand, you'll need to detect and reuse/reconfigure the existing resource rather than erroring out.

---

## 1. Create the root "API Portal" application

```bash
IS_URL="https://localhost:9443"

curl -sk -u admin:admin -X POST "$IS_URL/api/server/v1/applications" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "API Portal",
    "description": "WSO2 API Platform developer portal",
    "templateId": "custom-application",
    "inboundProtocolConfiguration": {
      "oidc": {
        "grantTypes": ["authorization_code", "refresh_token", "organization_switch", "password", "client_credentials"],
        "callbackURLs": ["regexp=(http://localhost:9543/api-portal/default/callback|http://localhost:9543/api-portal/logout)"],
        "publicClient": false
      }
    }
  }'
```

Notes on the fields that aren't obvious:
- `organization_switch` — needed by Section 5's onboarding flow to reach into a sub-org's own admin APIs from this one root app's credentials.
- `password` — needed for each tenant's per-org system-user tokens (Section 5), and for a plain admin/browser-equivalent login.
- **`callbackURLs` uses IS's `regexp=(url1|url2)` syntax**, not a plain multi-value list — IS rejects two distinct callback URLs given any other way. This one entry covers both the OIDC login callback and the post-logout redirect.
- The response's `id` field is `ROOT_APP_ID` (distinct from the OAuth `client_id`) — save it, Section 5 needs it for every tenant.

### 1a. Enable JWT access tokens with roles/groups

```bash
APP_ID="<id from step 1>"
CURRENT_OIDC=$(curl -sk -u admin:admin "$IS_URL/api/server/v1/applications/$APP_ID/inbound-protocols/oidc")
MERGED_OIDC=$(echo "$CURRENT_OIDC" | jq '.accessToken.type = "JWT" | .accessToken.accessTokenAttributes = ["roles", "groups"]')
curl -sk -u admin:admin -X PUT "$IS_URL/api/server/v1/applications/$APP_ID/inbound-protocols/oidc" \
  -H "Content-Type: application/json" -d "$MERGED_OIDC"
```

Then fetch the client credentials (needed for both the portal's own config and `ROOT_APP_CLIENT_ID`/`ROOT_APP_CLIENT_SECRET`):

```bash
curl -sk -u admin:admin "$IS_URL/api/server/v1/applications/$APP_ID/inbound-protocols/oidc" | jq '{clientId, clientSecret}'
```

### 1b. Claim configuration — this is the part that's easy to get wrong

Without this, users show up logged in but nameless (only a UUID `sub`), and role-based authorization silently fails because no `roles` claim reaches the token at all.

```bash
curl -sk -u admin:admin -X PATCH "$IS_URL/api/server/v1/applications/$APP_ID" \
  -H "Content-Type: application/json" \
  -d '{
      "claimConfiguration": {
          "dialect": "CUSTOM",
          "claimMappings": [
              {"applicationClaim": "http://wso2.org/claims/roles", "localClaim": {"uri": "http://wso2.org/claims/roles"}},
              {"applicationClaim": "http://wso2.org/claims/username", "localClaim": {"uri": "http://wso2.org/claims/username"}},
              {"applicationClaim": "http://wso2.org/claims/emailaddress", "localClaim": {"uri": "http://wso2.org/claims/emailaddress"}},
              {"applicationClaim": "http://wso2.org/claims/givenname", "localClaim": {"uri": "http://wso2.org/claims/givenname"}},
              {"applicationClaim": "http://wso2.org/claims/lastname", "localClaim": {"uri": "http://wso2.org/claims/lastname"}}
          ],
          "requestedClaims": [
              {"claim": {"uri": "http://wso2.org/claims/roles"}, "mandatory": false},
              {"claim": {"uri": "http://wso2.org/claims/username"}, "mandatory": false},
              {"claim": {"uri": "http://wso2.org/claims/emailaddress"}, "mandatory": false},
              {"claim": {"uri": "http://wso2.org/claims/givenname"}, "mandatory": false},
              {"claim": {"uri": "http://wso2.org/claims/lastname"}, "mandatory": false}
          ],
          "subject": {"includeUserDomain": false, "includeTenantDomain": false, "useMappedLocalSubject": true, "mappedLocalSubjectMandatory": false},
          "role": {"includeUserDomain": true, "claim": {"uri": "http://wso2.org/claims/roles"}}
      }
  }'
```

**Two non-obvious things here, both found by debugging a broken deployment rather than documented anywhere obvious:**
- `role.claim.uri` is a *separate* field from `claimMappings`/`requestedClaims` — listing `roles` in the mappings alone is not enough for it to actually populate.
- This claim config must be applied to **this root app**, not just each org's fragment app copy — a browser login's token audience is the root app, so the root app's own claim config is what governs what a *browser* session sees. (Section 5 separately configures each fragment app's claim config too, since that governs tokens issued to system users authenticating *directly against* that org — a different audience, same content.)

### 1c. Share to all sub-organizations

```bash
curl -sk -u admin:admin -X POST "$IS_URL/api/server/v1/applications/$APP_ID/share" \
  -H "Content-Type: application/json" -d '{"shareWithAllChildren": true}'
```

This covers every org created *after* this call too — it's a one-time step, not per-tenant.

---

## 2. Authorize the root app for the scopes Section 5 needs

Each scope lives on a specific API resource; look its `id` up first (identifiers are stable across IS versions, but the resource UUIDs are per-instance):

```bash
curl -sk -u admin:admin "$IS_URL/api/server/v1/api-resources?limit=250" | \
  jq '.apiResources[]? | select(.identifier | IN("/o/api/server/v1/applications", "/o/scim2/Users", "/o/scim2/Roles")) | {id, identifier}'
```

Then authorize the app for each, one call per API resource:

```bash
# Application Management API — configures each org's fragment app AND creates
# the org's own OAuth2 application (Section 5, steps 5b/5c).
# internal_org_application_mgt_create is what 5c (creating a NEW
# application inside the sub-org, as opposed to reconfiguring the existing
# fragment app copy) needs — without it, application creation 403s.
curl -sk -u admin:admin -X POST "$IS_URL/api/server/v1/applications/$APP_ID/authorized-apis" \
  -H "Content-Type: application/json" \
  -d '{"id": "<Application Management API id>", "policyIdentifier": "RBAC",
       "scopes": ["internal_org_application_mgt_view", "internal_org_application_mgt_update", "internal_org_application_mgt_create"]}'

# SCIM2 Users API — creates/looks up/resets the org's users (Section 5, step 5d)
curl -sk -u admin:admin -X POST "$IS_URL/api/server/v1/applications/$APP_ID/authorized-apis" \
  -H "Content-Type: application/json" \
  -d '{"id": "<SCIM2 Users API id>", "policyIdentifier": "RBAC",
       "scopes": ["internal_org_user_mgt_create", "internal_org_user_mgt_list", "internal_org_user_mgt_view", "internal_org_user_mgt_update"]}'

# SCIM2 Roles API — assigns each org user to dp_admin/dp_subscriber (Section 5, step 5d)
curl -sk -u admin:admin -X POST "$IS_URL/api/server/v1/applications/$APP_ID/authorized-apis" \
  -H "Content-Type: application/json" \
  -d '{"id": "<SCIM2 Roles API id>", "policyIdentifier": "RBAC",
       "scopes": ["internal_org_role_mgt_view", "internal_org_role_mgt_update"]}'
```

`policyIdentifier` must be exactly `"RBAC"` or `"No Policy"` — anything else 400s.

**Optional but recommended: also authorize `internal_org_user_mgt_delete`** on the SCIM2 Users API. Not needed by Section 5's onboarding flow (it never calls SCIM delete directly), but needed for the common manual operation of deleting one of an org's users directly via SCIM (e.g. to force a fresh-password recreation on next onboarding) without tearing down its whole catalog.

**To add a scope to an API that's already authorized** (rather than authorizing it fresh, as above): `PUT` on the `/authorized-apis/{apiId}` sub-resource 405s — don't bother. The working call is `PATCH` with `addedScopes`/`removedScopes`:

```bash
curl -sk -u admin:admin -X PATCH "$IS_URL/api/server/v1/applications/$APP_ID/authorized-apis/<SCIM2 Users API id>" \
  -H "Content-Type: application/json" \
  -d '{"addedScopes": ["internal_org_user_mgt_delete"], "removedScopes": []}'
```

---

## 3. Create the `dp_admin` / `dp_subscriber` shared roles

These names must match `[api_portal.auth.authorization.portal_roles]` in the portal's `config.toml` (`admin`/`subscriber` keys respectively — see [Section 4](#4-configure-the-developer-portals-config)). Without `dp_subscriber` existing at all, there's no way to demo a subscriber-tier (as opposed to admin) user.

```bash
curl -sk -u admin:admin -X POST "$IS_URL/scim2/v2/Roles" \
  -H "Content-Type: application/json" \
  -d '{"displayName": "dp_admin", "audience": {"value": "'"$APP_ID"'", "type": "application"}}'

curl -sk -u admin:admin -X POST "$IS_URL/scim2/v2/Roles" \
  -H "Content-Type: application/json" \
  -d '{"displayName": "dp_subscriber", "audience": {"value": "'"$APP_ID"'", "type": "application"}}'
```

**One thing that looks like it needs configuring but doesn't:** you'll see an `isSharedRole` property on a role's SCIM representation, and it's tempting to try to set it to `true` at creation — don't bother, IS ignores it there. Sharing isn't a role-level setting at all: because the *application* is already shared (step 1c), **every role bound to it propagates automatically** to every org's fragment app the moment it's created. Confirmed by creating a throwaway test org after creating these two roles and immediately seeing both listed on its fragment app with no further action.

To actually let someone log in with one of these roles, assign a user to it (per org — this is what Section 5's step 5d does for each tenant's own users; for the *root* org's own admin, e.g. for testing, do it once manually):

```bash
ROLE_ID="<dp_admin role id from the create response>"
ADMIN_USER_ID=$(curl -sk -u admin:admin "$IS_URL/scim2/Users?filter=userName+eq+admin" | jq -r '.Resources[0].id')
curl -sk -u admin:admin -X PATCH "$IS_URL/scim2/v2/Roles/$ROLE_ID" \
  -H "Content-Type: application/json" \
  -d "{\"schemas\": [\"urn:ietf:params:scim:api:messages:2.0:PatchOp\"], \"Operations\": [{\"op\": \"add\", \"path\": \"users\", \"value\": [{\"value\": \"$ADMIN_USER_ID\"}]}]}"
```

---

## 4. Configure the Developer Portal's config

Set `[api_portal.auth.idp]` to the root app's own credentials (from step 1a), and `[api_portal.auth.authorization.portal_roles]` to the two role names from step 3:

```toml
[api_portal.auth]
mode = "idp"

[api_portal.auth.idp]
client_id = "<ROOT_APP_CLIENT_ID>"
client_secret = "<ROOT_APP_CLIENT_SECRET>"
authorization_url = "https://localhost:9443/oauth2/authorize"
token_url = "https://host.docker.internal:9443/oauth2/token"
callback_url = "http://localhost:9543/api-portal/default/callback"
jwks_url = "https://host.docker.internal:9443/oauth2/jwks"
logout_url = "https://localhost:9443/oidc/logout"
logout_redirect_uri = "http://localhost:9543/api-portal/logout"

[api_portal.auth.authorization]
enabled = true
mode    = "role"
role_to_scope_mapping = "./resources/role-to-scope-mapping.yaml"
page_role_validation = true

[api_portal.auth.authorization.portal_roles]
admin      = "dp_admin"
subscriber = "dp_subscriber"
```

**The `authorization_url`/`logout_url` vs `token_url`/`jwks_url` hostname split is deliberate, not a typo:** the first two are redirects the *browser* follows (it runs on the host, outside Docker's network, so `host.docker.internal` doesn't resolve for it — use `localhost`); the latter two are called by the *portal container itself* server-to-server (exchanging the auth code, verifying bearer tokens), which is exactly what `host.docker.internal` is for. Getting this backwards produces a browser redirect to an unreachable host, or (more confusingly) a container that can't verify its own tokens while the browser flow looks fine.

> **In this repo:** if you're running from the standalone dist (`make dist` / `target/extracted/.../configs/config.toml`), edit that copy — **not** the source `configs/config.toml` template, unless the change should also apply to every future `make dist` build. This repo's dist copy is the one actually mounted into the running container.

**Running the portal locally without Docker** (e.g. `node src/server.js` directly against the config, for debugging one step at a time): the `host.docker.internal`/`localhost` split above doesn't apply — there's only one network namespace, so use `localhost` for every IS URL (`authorization_url`, `token_url`, `callback_url`, `jwks_url`, `logout_url`). Two other things follow from not being in Docker:
- `[api_portal.server.https]` can be set to `enabled = false` (with `base_url = "http://localhost:9543"`) to skip provisioning a dev TLS cert for the portal's own listener — fine for local iteration, not for anything shared.
- The portal process itself makes outbound HTTPS calls to IS (token exchange, JWKS fetch) that will fail TLS verification against IS's self-signed cert. `curl -k` (used throughout this guide) skips that check per-call; the portal's own Node HTTPS client doesn't have an equivalent per-request flag, so run the process with `NODE_TLS_REJECT_UNAUTHORIZED=0` set instead — a blanket opt-out, so only do this for local testing against a self-signed IS, never in a deployed environment.

---

## 5. Onboard a tenant organization

This is currently a manual flow — there's no onboarding script — so this section documents it in full. Every step below assumes `ROOT_APP_CLIENT_ID`/`ROOT_APP_CLIENT_SECRET`/`ROOT_APP_ID` from section 1, and uses `ORG_NAME=acme` as a running example. Re-running any step against an already-onboarded org is safe as long as you look up and reuse existing resources rather than blindly re-`POST`ing — the notes below call out where that matters most.

### 5a. Register the organization

```bash
ORG_NAME="acme"
curl -sk -u admin:admin -X POST "$IS_URL/api/server/v1/organizations" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"$ORG_NAME\", \"orgHandle\": \"$ORG_NAME\", \"description\": \"Tenant $ORG_NAME\"}"
```

Save the response's `id` as `ORG_ID`.

**Setting `orgHandle` explicitly matters more than it looks.** Leaving it unset doesn't just skip a cosmetic field — IS silently defaults `orgHandle` to the org's own UUID, which breaks org discovery/SSO login entirely: `fidp=OrganizationSSO` (used by the browser Login button — see `src/utils/constants.js`'s `ORGANIZATION_SSO_FIDP`) redirects to a broken `domain.unknown` failure instead of the discovery prompt (`org_handle.do`), and `org=<handle>` on `/oauth2/authorize` doesn't correctly delegate into the sub-org's own login either. Confirmed by testing directly against a running instance — creating one org with an explicit `orgHandle` and one without, side by side, and diffing the resulting `/oauth2/authorize` redirects.

**`orgHandle` is immutable once set** — `PATCH .../organizations/{id}` with path `/orgHandle` 400s ("Provided path :/orgHandle is invalid"), and there is no other update endpoint for it. An organization created without it can't be repaired in place — the only fix is deleting it directly via IS's own API (`DELETE /api/server/v1/organizations/{id}`) and re-registering it.

**A duplicate name comes back as 400, not 409** — IS reports it as error code `ORG-60076`. Don't treat a non-201 as fatal without first checking whether the org already exists:

```bash
curl -sk -u admin:admin "$IS_URL/api/server/v1/organizations?filter=name+eq+$ORG_NAME" | jq -r '.organizations[0].id'
```

### 5b. Configure the organization's fragment application

Every org sharing the root app gets its own copy ("fragment application") the moment it's created — but a freshly shared copy starts with **none** of the root app's OIDC/claim configuration (password grant disabled, opaque access tokens, no claim mappings). Each org needs this applied once.

Get an org-scoped admin token via `organization_switch` (this is what that grant type in step 1 is for):

```bash
ROOT_ORG_ID=$(curl -sk -u admin:admin "$IS_URL/api/server/v1/organizations/$ORG_ID" | jq -r '.parent.id')
APP_MGT_SCOPES="internal_org_application_mgt_view internal_org_application_mgt_update internal_org_application_mgt_create"
CC_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
  -d "grant_type=client_credentials&scope=$APP_MGT_SCOPES" | jq -r '.access_token')
APP_MGT_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
  -d "grant_type=organization_switch&token=$CC_TOKEN&switching_organization=$ORG_ID&scope=$APP_MGT_SCOPES" | jq -r '.access_token')
```

Find this org's fragment application id:

```bash
FRAGMENT_APP_ID=$(curl -sk -u admin:admin "$IS_URL/api/server/v1/organizations/$ROOT_ORG_ID/applications/$ROOT_APP_ID/shared-apps" \
  | jq -r --arg org "$ORG_ID" '.sharedApplications[] | select(.organizationId==$org) | .applicationId')
```

If nothing comes back, the root app wasn't shared with `shareWithAllChildren` (step 1c) — that call covers every org created afterward too, so this should be rare.

Apply grant types + JWT access tokens, **merged onto the existing config** (not replaced) so anything an operator already customized — e.g. `callbackURLs` — survives:

```bash
CURRENT_OIDC=$(curl -sk -H "Authorization: Bearer $APP_MGT_TOKEN" "$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID/inbound-protocols/oidc")
MERGED_OIDC=$(echo "$CURRENT_OIDC" | jq '
    .grantTypes = ((.grantTypes // []) + ["password", "refresh_token"] | unique) |
    .accessToken.type = "JWT" |
    .accessToken.accessTokenAttributes = ["roles", "groups"]
')
curl -sk -H "Authorization: Bearer $APP_MGT_TOKEN" -X PUT "$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID/inbound-protocols/oidc" \
  -H "Content-Type: application/json" -d "$MERGED_OIDC"
```

Then apply the same claim-mapping `PATCH` as step 1b, but against `$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID` — this governs tokens minted for users authenticating *directly against this org* (a different token audience from the root app's browser tokens, same claim content required).

### 5c. Create the organization's own OAuth2 application

This is the org's "key manager" client — what an external caller uses to get a `client_credentials` token, later linked to a portal application (5h).

```bash
curl -sk -D - -o /dev/null -H "Authorization: Bearer $APP_MGT_TOKEN" -X POST "$IS_URL/o/api/server/v1/applications" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${ORG_NAME}-key-manager\", \"templateId\": \"custom-application-oidc\",
       \"inboundProtocolConfiguration\": {\"oidc\": {\"grantTypes\": [\"client_credentials\"], \"publicClient\": false}}}"
```

Two gotchas, both found by direct reproduction rather than documented anywhere obvious:
- `POST /applications` returns **201 with an empty body** — the new app's id is only in the response's `Location` header (`-D -` above prints headers so you can read it), not the JSON.
- Don't include `accessToken` in this create-time body — IS 500s (`APP-65006`). Apply it afterward instead:

```bash
curl -sk -H "Authorization: Bearer $APP_MGT_TOKEN" -X PUT "$IS_URL/o/api/server/v1/applications/$ORG_APP_ID/inbound-protocols/oidc" \
  -H "Content-Type: application/json" -d '{"accessToken": {"type": "JWT"}}'
```

Read back `clientId`/`clientSecret` with a plain `GET` on the same `inbound-protocols/oidc` endpoint (the `PUT` above also returns an empty body).

### 5d. Create the organization's users

Get an org-scoped token for user/role management (same `organization_switch` pattern as 5b, different scopes):

```bash
USER_MGT_SCOPES="internal_org_user_mgt_create internal_org_user_mgt_list internal_org_user_mgt_view internal_org_user_mgt_update internal_org_role_mgt_view internal_org_role_mgt_update"
USER_MGT_CC_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
  -d "grant_type=client_credentials&scope=$USER_MGT_SCOPES" | jq -r '.access_token')
USER_MGT_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
  -d "grant_type=organization_switch&token=$USER_MGT_CC_TOKEN&switching_organization=$ORG_ID&scope=$USER_MGT_SCOPES" | jq -r '.access_token')
```

Create `${ORG_NAME}admin` (role `dp_admin`) — always. Create `${ORG_NAME}user` (role `dp_subscriber`) only if this org will own any applications (skip it otherwise: `dp_subscriber` alone can't do steps 5e-5i).

```bash
curl -sk -X POST "$IS_URL/t/carbon.super/o/scim2/Users" -H "Authorization: Bearer $USER_MGT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"schemas\": [], \"userName\": \"${ORG_NAME}admin\", \"password\": \"<a generated password>\"}"
```

**The literal `carbon.super` in that URL is not a mistake.** The target organization comes from the *token's own org context* (the `organization_switch` grant above), not from any org id/handle in the URL — confirmed against WSO2 IS 7.1's own org-user-mgt SCIM2 API docs (`apis/organization-apis/scim2/scim2-org-user-mgt/`), not just by trial.

Look up the role and assign it:

```bash
ROLE_ID=$(curl -sk "$IS_URL/t/carbon.super/o/scim2/v2/Roles" -H "Authorization: Bearer $USER_MGT_TOKEN" \
  | jq -r --arg app "$FRAGMENT_APP_ID" '.Resources[] | select(.displayName=="dp_admin" and .audience.value==$app) | .id')
curl -sk -X PATCH "$IS_URL/t/carbon.super/o/scim2/v2/Roles/$ROLE_ID" -H "Authorization: Bearer $USER_MGT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"], "Operations": [{"op": "add", "path": "users", "value": [{"value": "<user id from the create response>"}]}]}'
```

Then mint each user's own bearer token via password grant against the fragment app's own `clientId`/`clientSecret` (from 5b) at `$IS_URL/o/$ORG_ID/oauth2/token` — this token is what authenticates every Developer Portal API call in the steps below.

### 5e. Seed subscription plans

Via the Developer Portal's own REST API, not IS — one `PUT` per plan (a bulk array body is silently no-op'd when `organization.autoCreateSubscriptionPlans` is on, the default):

```bash
curl -sk -X PUT "$API_PORTAL_URL/api-portal/api/v0.9/subscription-plans" \
  -H "Authorization: Bearer <\${ORG_NAME}admin's token>" -H "Content-Type: application/json" \
  -d '{"id": "Gold", "displayName": "Gold", "description": "...", "limits": [{"limitType": "REQUEST_COUNT", "timeUnit": "MINUTE", "timeAmount": 1, "limitCount": 1000}]}'
```

An org that needs no custom plans can skip this entirely — it keeps the auto-seeded defaults (Bronze/Silver/Gold/Unlimited/AsyncUnlimited).

### 5f. Seed APIs and MCP servers

This part is still scripted — `scripts/seed-samples.sh` is generic and remains, pointed at whichever directory holds this org's own sample bundle (`apis/`, `mcps/`):

```bash
ACCESS_TOKEN="<\${ORG_NAME}admin's token>" SAMPLES_DIR="<path to this org's samples>" \
PLAN_OVERRIDE="Gold|Silver" API_PORTAL_URL="$API_PORTAL_URL" \
  ./scripts/seed-samples.sh
```

`PLAN_OVERRIDE` (pipe-delimited plan handles) rewrites each sample's `subscriptionPlans:` block to exactly this org's plan set from 5e, so a seeded API never advertises a plan the org doesn't actually have.

### 5g. Configure a Developer Portal key manager for this organization

Each tenant org is its own IS sub-org, so the natural key manager is that org's own token endpoint — no external IDP needed. The portal's key managers are deliberately thin (see [Key Manager Integration](key-manager-integration.md)): just a `displayName` + `tokenEndpoint` it proxies `client_credentials` requests to, no DCR, no stored secret.

```bash
curl -sk -X POST "$API_PORTAL_URL/api-portal/api/v0.9/key-managers" \
  -H "Authorization: Bearer <\${ORG_NAME}admin's token>" -H "Content-Type: application/json" \
  -d "{\"id\": \"wso2-is\", \"displayName\": \"WSO2 IS ($ORG_NAME)\", \"tokenEndpoint\": \"$IS_INTERNAL_URL/o/$ORG_ID/oauth2/token\"}"
```

**Use the container-reachable IS host here** (`host.docker.internal`, or your deployment's equivalent) — `IS_INTERNAL_URL`, not the browser-facing `IS_URL` — since this endpoint is called by the *portal container itself* at proxy time, the same reasoning as `token_url`/`jwks_url` in [Section 4](#4-configure-the-developer-portals-config).

If this org's IS organization is ever deleted and recreated, its UUID changes but this key manager's stored `tokenEndpoint` doesn't update itself — `PUT` the same endpoint (`.../key-managers/wso2-is`) with the new `$ORG_ID` to reconcile it, or every proxied token request fails against a URL that no longer exists.

### 5h. Create applications and link the OAuth2 client

For each application this org owns, created and owned by `${ORG_NAME}user`:

```bash
curl -sk -X POST "$API_PORTAL_URL/api-portal/api/v0.9/applications" \
  -H "Authorization: Bearer <\${ORG_NAME}user's token>" -H "Content-Type: application/json" \
  -d '{"id": "my-app", "displayName": "My App"}'

curl -sk -X POST "$API_PORTAL_URL/api-portal/api/v0.9/applications/my-app/generate-keys" \
  -H "Authorization: Bearer <\${ORG_NAME}user's token>" -H "Content-Type: application/json" \
  -d "{\"keyManager\": \"wso2-is\", \"consumerKey\": \"<5c's client_id>\", \"type\": \"PRODUCTION\"}"
```

`generate-keys` links the org's own OAuth2 client from 5c to this application — 409s if already linked, safe to ignore.

### 5i. Subscribe to APIs

MCP servers aren't subscribable yet (`GET /apis` never returns them — they live under `/mcp-servers`). Subscribe `${ORG_NAME}user` to each deployed REST API at one of the org's own plans:

```bash
curl -sk -X POST "$API_PORTAL_URL/api-portal/api/v0.9/subscriptions" \
  -H "Authorization: Bearer <\${ORG_NAME}user's token>" -H "Content-Type: application/json" \
  -d '{"artifactId": "<api id>", "subscriptionPlanId": "Gold"}'
```

### Getting a token

Directly from IS, using 5c's client:

```bash
curl -k -X POST "$IS_URL/o/$ORG_ID/oauth2/token" \
  -u "<5c's client_id>:<5c's client_secret>" \
  -d 'grant_type=client_credentials'
```

Or, once an application is linked (5h), via the portal itself with no secret on the command line:

```bash
curl -k -X POST "$API_PORTAL_URL/api-portal/api/v0.9/applications/my-app/oauth-keys/<key mapping id from 5h>/generate-token" \
  -H "Authorization: Bearer <user's token>" -H "Content-Type: application/json" \
  -d '{"consumerSecret": "<5c's client_secret>"}'
```

---

## Gaps — what's not scripted

The chicken-and-egg this section used to describe (the app must exist to get its client_id/secret before the portal's config can be written) has no scripted resolution — create and fully configure the app first (sections 1-4 above), then apply the resulting `config.toml` block (and restart the portal) as a manual last step, since that file lives outside IS and how it's managed (by hand, config management, etc.) varies per deployment.

Two things worth calling out, found only through real end-to-end testing:
- **`enhancedOrgAuthenticationEnabled` must be `true`** for a browser login's `roles` claim to populate at all — an org-scoped login succeeds either way, but silently carries no roles when this is left at its default `false`.
- Turning that flag on **resets `authenticationSequence`** to a bare `BasicAuthenticator`-only step, and reaching the "which org?" discovery prompt (`org_handle.do`) *at the same time* as enhanced mode being on requires an **adaptive authentication script** forcing `OrganizationIdentifierHandler` — without it, enhanced mode makes an unknown-org login fail outright instead of prompting. Set both explicitly, in that order, after enabling the flag.
