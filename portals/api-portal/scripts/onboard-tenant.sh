#!/bin/bash

# --------------------------------------------------------------------
# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
# --------------------------------------------------------------------

# Onboards one tenant end to end against WSO2 Identity Server + the Developer
# Portal:
#   1. Registers the organization in IS (safe to re-run — an existing org is
#      looked up rather than re-created).
#   2. Configures that organization's own copy ("fragment application") of the
#      API Portal SP — password grant, JWT access tokens with roles/groups,
#      and the profile claim mappings — so it's actually usable. A freshly
#      shared application does NOT inherit this from the root application;
#      every organization's fragment copy starts unconfigured and needs this
#      done once, which is exactly what onboarding a new tenant means here.
#   3. Obtains an access token for a system user in that org, scoped to it,
#      using the fragment application's own (just-fetched) credentials.
#   4. Deploys the bundled sample APIs + MCP server to the Developer Portal
#      with that token, by delegating to seed-samples.sh.
#   5. Creates an application and subscribes it to every deployed API (MCP
#      servers cannot be subscribed to yet, so only /apis entries are used).
#
# Prerequisites — one-time IS setup, done once for the whole deployment, not
# per tenant:
#   - An OIDC application ("API Portal" or similar) registered in the root
#     organization. Its own grant types/claims don't matter for this script
#     (browser login is a separate concern) — what matters here is that it's
#     shared to organizations with shareWithAllChildren
#     (POST /api/server/v1/applications/{appId}/share), which covers every
#     organization created *after* the share call too, so it is not repeated
#     per tenant. That root application's own client_id/client_secret and id
#     are passed as ROOT_APP_CLIENT_ID / ROOT_APP_CLIENT_SECRET / ROOT_APP_ID.
#   - ROOT_APP_CLIENT_ID must be authorized (Console > that application >
#     API Authorization, or POST .../authorized-apis) for the
#     internal_org_application_mgt_view and internal_org_application_mgt_update
#     scopes on the "Application Management API" (ORGANIZATION type,
#     identifier /o/api/server/v1/applications) — needed to configure each
#     organization's fragment application below.
#
# Prerequisite — one-time, per organization, manual step:
#   WSO2 IS does not expose a documented way to create the first user of a
#   freshly created organization purely over its REST API (the calling
#   identity's root-organization permissions do not carry into a new child
#   organization's own permission tree). Create that user once via the IS
#   Console (Organizations > <org> > Users > Add User) and grant it a role
#   whose portal-side mapping (resources/role-to-scope-mapping.yaml) covers
#   the write scopes needed for the deploy/subscribe steps below — then pass
#   its credentials as SYSTEM_USERNAME / SYSTEM_PASSWORD.
#
# Usage:
#   ORG_NAME=org1 SYSTEM_USERNAME=org1admin SYSTEM_PASSWORD=... \
#   ROOT_APP_CLIENT_ID=... ROOT_APP_CLIENT_SECRET=... ROOT_APP_ID=... \
#     ./scripts/onboard-tenant.sh
#
# IS_URL / API_PORTAL_URL / IS_ADMIN_USERNAME / IS_ADMIN_PASSWORD override the
# defaults below. Safe to re-run: an existing organization is reused, its
# fragment application is reconfigured to the same idempotent target state
# every time, and seed-samples.sh / application creation both skip entries
# that already exist.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IS_URL="${IS_URL:-https://localhost:9443}"
IS_ADMIN_USERNAME="${IS_ADMIN_USERNAME:-admin}"
IS_ADMIN_PASSWORD="${IS_ADMIN_PASSWORD:-admin}"
API_PORTAL_URL="${API_PORTAL_URL:-https://localhost:9543}"
API_PORTAL_API_BASE="/api-portal/api/v0.9"
SUBSCRIPTION_PLAN="${SUBSCRIPTION_PLAN:-Bronze}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
    SYM_OK="✓"; SYM_SKIP="•"
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_RESET=""
    SYM_OK="OK"; SYM_SKIP="-"
fi

log() { echo "${C_DIM}[onboard-tenant]${C_RESET} $*"; }
fail() { echo "${C_RED}[onboard-tenant] ERROR:${C_RESET} $*" >&2; exit 1; }
urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

command -v curl >/dev/null 2>&1 || fail "curl is required but not found on PATH."
command -v jq   >/dev/null 2>&1 || fail "jq is required but not found on PATH."

[ -n "${ORG_NAME:-}" ] || fail "ORG_NAME is required — the organization to onboard (e.g. org1)."
[ -n "${ROOT_APP_CLIENT_ID:-}" ] || fail "ROOT_APP_CLIENT_ID is required — the root-org API Portal application's client ID."
[ -n "${ROOT_APP_CLIENT_SECRET:-}" ] || fail "ROOT_APP_CLIENT_SECRET is required."
[ -n "${ROOT_APP_ID:-}" ] || fail "ROOT_APP_ID is required — the root-org API Portal application's id (not its client ID)."

# --- Step 1: register the organization (idempotent) -------------------------

log "Registering organization '$ORG_NAME' in WSO2 IS at $IS_URL ..."
CREATE_STATUS=$(curl -sk -o /tmp/onboard-tenant-org.$$.json -w "%{http_code}" \
    -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" -X POST "$IS_URL/api/server/v1/organizations" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$ORG_NAME\", \"description\": \"Tenant $ORG_NAME\"}")
CREATE_BODY=$(cat /tmp/onboard-tenant-org.$$.json); rm -f /tmp/onboard-tenant-org.$$.json

if [ "$CREATE_STATUS" = "201" ]; then
    ORG_ID=$(echo "$CREATE_BODY" | jq -r '.id')
    log "  ${C_GREEN}${SYM_OK}${C_RESET} created (id: $ORG_ID)"
else
    # IS reports a name already taken by an existing organization as 400
    # ORG-60076, not 409 — so any non-201 falls back to a lookup-by-name rather
    # than matching on a specific status code, and only fails if that also
    # comes up empty.
    ORG_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
        "$IS_URL/api/server/v1/organizations?filter=name+eq+$(urlencode "$ORG_NAME")" \
        | jq -r '.organizations[0].id // empty')
    if [ -n "$ORG_ID" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} already exists (id: $ORG_ID)"
    else
        fail "failed to create organization '$ORG_NAME' (HTTP $CREATE_STATUS): $CREATE_BODY"
    fi
fi

# --- Step 2: configure the organization's fragment application (idempotent) -
# A freshly shared application's per-organization copy starts with none of
# this — password grant disabled, opaque access tokens, no claim mappings —
# so every organization needs it applied once. Re-running always PUTs/PATCHes
# the same target state, so this is safe on an already-configured org too.

log "Locating '$ORG_NAME''s copy of the API Portal application ..."
ROOT_ORG_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    "$IS_URL/api/server/v1/organizations/$ORG_ID" | jq -r '.parent.id // empty')
[ -n "$ROOT_ORG_ID" ] || fail "could not resolve '$ORG_NAME''s parent organization."

FRAGMENT_APP_ID=$(curl -sk -u "$IS_ADMIN_USERNAME:$IS_ADMIN_PASSWORD" \
    "$IS_URL/api/server/v1/organizations/$ROOT_ORG_ID/applications/$ROOT_APP_ID/shared-apps" \
    | jq -r --arg org "$ORG_ID" '.sharedApplications[]? | select(.organizationId==$org) | .applicationId')
[ -n "$FRAGMENT_APP_ID" ] || fail "the API Portal application ($ROOT_APP_ID) is not shared to '$ORG_NAME' — share it first: POST $IS_URL/api/server/v1/applications/$ROOT_APP_ID/share with {\"shareWithAllChildren\": true}."
log "  found (application id: $FRAGMENT_APP_ID)"

log "Obtaining an org-scoped admin token to configure it ..."
CC_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" \
    -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
    -d "grant_type=client_credentials&scope=internal_org_application_mgt_view internal_org_application_mgt_update" \
    | jq -r '.access_token // empty')
[ -n "$CC_TOKEN" ] || fail "failed to obtain a client_credentials token — check ROOT_APP_CLIENT_ID/ROOT_APP_CLIENT_SECRET."
SWITCHED_TOKEN=$(curl -sk -X POST "$IS_URL/oauth2/token" \
    -u "$ROOT_APP_CLIENT_ID:$ROOT_APP_CLIENT_SECRET" \
    -d "grant_type=organization_switch&token=$CC_TOKEN&switching_organization=$ORG_ID&scope=internal_org_application_mgt_view internal_org_application_mgt_update" \
    | jq -r '.access_token // empty')
[ -n "$SWITCHED_TOKEN" ] || fail "failed to switch into '$ORG_NAME' — is ROOT_APP_CLIENT_ID authorized for internal_org_application_mgt_view/update on the Application Management API (/o/api/server/v1/applications)?"

log "Configuring grant types and access token attributes ..."
CURRENT_OIDC=$(curl -sk -H "Authorization: Bearer $SWITCHED_TOKEN" \
    "$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID/inbound-protocols/oidc")
FRAGMENT_CLIENT_ID=$(echo "$CURRENT_OIDC" | jq -r '.clientId // empty')
FRAGMENT_CLIENT_SECRET=$(echo "$CURRENT_OIDC" | jq -r '.clientSecret // empty')
[ -n "$FRAGMENT_CLIENT_ID" ] && [ -n "$FRAGMENT_CLIENT_SECRET" ] || fail "could not read '$ORG_NAME''s fragment application's own OIDC client credentials."

# Merged onto whatever is already configured — preserves callbackURLs and
# anything an operator customized — rather than replaced outright: password
# and refresh_token are added to the existing grant list, not assumed to be
# the only ones.
MERGED_OIDC=$(echo "$CURRENT_OIDC" | jq '
    .grantTypes = ((.grantTypes // []) + ["password", "refresh_token"] | unique) |
    .accessToken.type = "JWT" |
    .accessToken.accessTokenAttributes = ["roles", "groups"]
')
OIDC_STATUS=$(curl -sk -o /tmp/onboard-tenant-oidc.$$.json -w "%{http_code}" \
    -H "Authorization: Bearer $SWITCHED_TOKEN" -X PUT \
    "$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID/inbound-protocols/oidc" \
    -H "Content-Type: application/json" -d "$MERGED_OIDC")
OIDC_BODY=$(cat /tmp/onboard-tenant-oidc.$$.json); rm -f /tmp/onboard-tenant-oidc.$$.json
[ "$OIDC_STATUS" = "200" ] || fail "failed to update OIDC config for '$ORG_NAME' (HTTP $OIDC_STATUS): $OIDC_BODY"
log "  ${C_GREEN}${SYM_OK}${C_RESET} grant types + access token configured"

# The Developer Portal reads firstName/lastName/email/roles out of the token,
# not out of a separate profile lookup — without these mappings the user shows
# up logged in but nameless, and (for "roles") authorization fails outright.
log "Configuring profile claim mappings ..."
CLAIM_STATUS=$(curl -sk -o /tmp/onboard-tenant-claims.$$.json -w "%{http_code}" \
    -H "Authorization: Bearer $SWITCHED_TOKEN" -X PATCH \
    "$IS_URL/o/api/server/v1/applications/$FRAGMENT_APP_ID" \
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
    }')
CLAIM_BODY=$(cat /tmp/onboard-tenant-claims.$$.json); rm -f /tmp/onboard-tenant-claims.$$.json
[ "$CLAIM_STATUS" = "200" ] || fail "failed to update claim configuration for '$ORG_NAME' (HTTP $CLAIM_STATUS): $CLAIM_BODY"
log "  ${C_GREEN}${SYM_OK}${C_RESET} claim mappings configured"

# --- Step 3: system user credentials (manual bootstrap, see header) ---------

if [ -z "${SYSTEM_USERNAME:-}" ] || [ -z "${SYSTEM_PASSWORD:-}" ]; then
    cat >&2 <<EOF

${C_YELLOW}A system user for '$ORG_NAME' is required but SYSTEM_USERNAME/SYSTEM_PASSWORD
were not set.${C_RESET}

WSO2 IS has no documented headless way to create the first user of a freshly
created organization, so this is a one-time manual step per organization:

  1. Open $IS_URL/console
  2. Switch into organization '$ORG_NAME' (org id: $ORG_ID)
  3. Users > Add User — create a user (e.g. '${ORG_NAME}admin')
  4. Assign it a role that maps (via resources/role-to-scope-mapping.yaml on
     the Developer Portal) to the write scopes this script needs.

Then re-run with the same ROOT_APP_CLIENT_ID/ROOT_APP_CLIENT_SECRET/ROOT_APP_ID
plus:
  SYSTEM_USERNAME=<username> SYSTEM_PASSWORD=<password> ORG_NAME=$ORG_NAME
EOF
    exit 1
fi

# --- Step 4: obtain an access token scoped to the organization --------------
# Uses the fragment application's own client credentials (fetched in Step 2),
# not the root application's — the same pairing a browser login or a direct
# API caller would use for this organization.

log "Obtaining an access token for '$SYSTEM_USERNAME' in '$ORG_NAME' ..."
TOKEN_RESP=$(curl -sk -X POST "$IS_URL/o/$ORG_ID/oauth2/token" \
    -u "$FRAGMENT_CLIENT_ID:$FRAGMENT_CLIENT_SECRET" \
    -d "grant_type=password&username=$(urlencode "$SYSTEM_USERNAME")&password=$(urlencode "$SYSTEM_PASSWORD")&scope=openid")
ACCESS_TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token // empty')
[ -n "$ACCESS_TOKEN" ] || fail "failed to obtain an access token: $TOKEN_RESP"
log "  ${C_GREEN}${SYM_OK}${C_RESET} token acquired"

# --- Step 5: deploy sample APIs + MCP server --------------------------------

log "Deploying sample APIs and MCP server to the Developer Portal at $API_PORTAL_URL ..."
ACCESS_TOKEN="$ACCESS_TOKEN" API_PORTAL_URL="$API_PORTAL_URL" "$THIS_DIR/seed-samples.sh"

# --- Step 6: create an application and subscribe it to every deployed API --
# MCP servers are deliberately excluded — GET /apis never returns them
# (they live under /mcp-servers), and subscriptions to MCP servers are not
# supported yet.

AUTH_HEADER="Authorization: Bearer $ACCESS_TOKEN"
APP_ID="${ORG_NAME}-app"

log "Creating application '$APP_ID' ..."
APP_STATUS=$(curl -sk -o /tmp/onboard-tenant-app.$$.json -w "%{http_code}" -X POST \
    "$API_PORTAL_URL$API_PORTAL_API_BASE/applications" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d "{\"displayName\": \"$ORG_NAME app\", \"id\": \"$APP_ID\", \"description\": \"Default application for $ORG_NAME\"}")
APP_BODY=$(cat /tmp/onboard-tenant-app.$$.json); rm -f /tmp/onboard-tenant-app.$$.json

if [ "$APP_STATUS" = "201" ]; then
    log "  ${C_GREEN}${SYM_OK}${C_RESET} created"
elif [ "$APP_STATUS" = "409" ]; then
    log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} already exists"
else
    fail "failed to create application '$APP_ID' (HTTP $APP_STATUS): $APP_BODY"
fi

log "Subscribing '$APP_ID' to deployed APIs (plan: $SUBSCRIPTION_PLAN) ..."
API_IDS=$(curl -sk "$API_PORTAL_URL$API_PORTAL_API_BASE/apis" -H "$AUTH_HEADER" | jq -r '.list[]?.id // empty')
if [ -z "$API_IDS" ]; then
    log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} no APIs found to subscribe to"
fi
while IFS= read -r api_id; do
    [ -n "$api_id" ] || continue

    # createSubscription enforces no api+plan uniqueness of its own, so this
    # script owns idempotency: skip if the authenticated user already has any
    # subscription to this API rather than creating a duplicate on re-run.
    EXISTING=$(curl -sk "$API_PORTAL_URL$API_PORTAL_API_BASE/subscriptions?artifactId=$(urlencode "$api_id")" \
        -H "$AUTH_HEADER" | jq -r '.list[0].subscriptionId // empty')
    if [ -n "$EXISTING" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} $api_id (already subscribed)"
        continue
    fi

    SUB_STATUS=$(curl -sk -o /tmp/onboard-tenant-sub.$$.json -w "%{http_code}" -X POST \
        "$API_PORTAL_URL$API_PORTAL_API_BASE/subscriptions" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "{\"artifactId\": \"$api_id\", \"subscriptionPlanId\": \"$SUBSCRIPTION_PLAN\"}")
    SUB_BODY=$(cat /tmp/onboard-tenant-sub.$$.json); rm -f /tmp/onboard-tenant-sub.$$.json
    if [ "$SUB_STATUS" = "201" ]; then
        log "  ${C_GREEN}${SYM_OK}${C_RESET} $api_id"
    elif [ "$SUB_STATUS" = "409" ]; then
        log "  ${C_YELLOW}${SYM_SKIP}${C_RESET} $api_id (already subscribed)"
    else
        log "  ${C_RED}✗${C_RESET} $api_id (HTTP $SUB_STATUS): $SUB_BODY"
    fi
done <<< "$API_IDS"

log "${C_GREEN}Done.${C_RESET} '$ORG_NAME' is onboarded."
