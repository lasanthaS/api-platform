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
#   2. Obtains an access token for a system user in that org, scoped to it.
#   3. Deploys the bundled sample APIs + MCP server to the Developer Portal
#      with that token, by delegating to seed-samples.sh.
#   4. Creates an application and subscribes it to every deployed API (MCP
#      servers cannot be subscribed to yet, so only /apis entries are used).
#
# Prerequisites — one-time IS setup, done once for the whole deployment, not
# per tenant:
#   - An OIDC application ("API Portal" or similar) registered in the root
#     organization, with grant types authorization_code, refresh_token,
#     organization_switch and password, and access tokens set to type JWT
#     with "roles" (and "groups", if used) added to accessTokenAttributes —
#     the Developer Portal reads role/org claims out of the access token
#     itself, so an opaque token or one missing those attributes will fail
#     to authenticate against it.
#   - That application shared to organizations with shareWithAllChildren
#     (POST /api/server/v1/applications/{appId}/share) — this also covers
#     every organization created *after* the share call, so it is not
#     repeated here per tenant.
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
#   IS_CLIENT_ID=... IS_CLIENT_SECRET=... \
#     ./scripts/onboard-tenant.sh
#
# IS_URL / API_PORTAL_URL / IS_ADMIN_USERNAME / IS_ADMIN_PASSWORD override the
# defaults below. Safe to re-run: an existing organization is reused, and
# seed-samples.sh / application creation both skip entries that already exist.

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
[ -n "${IS_CLIENT_ID:-}" ] || fail "IS_CLIENT_ID is required — the API Portal application's client ID in IS."
[ -n "${IS_CLIENT_SECRET:-}" ] || fail "IS_CLIENT_SECRET is required."

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

# --- Step 2: system user credentials (manual bootstrap, see header) ---------

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

Then re-run with:
  SYSTEM_USERNAME=<username> SYSTEM_PASSWORD=<password> ORG_NAME=$ORG_NAME \\
  IS_CLIENT_ID=$IS_CLIENT_ID IS_CLIENT_SECRET=*** $0
EOF
    exit 1
fi

# --- Step 3: obtain an access token scoped to the organization --------------

log "Obtaining an access token for '$SYSTEM_USERNAME' in '$ORG_NAME' ..."
TOKEN_RESP=$(curl -sk -X POST "$IS_URL/o/$ORG_ID/oauth2/token" \
    -u "$IS_CLIENT_ID:$IS_CLIENT_SECRET" \
    -d "grant_type=password&username=$(urlencode "$SYSTEM_USERNAME")&password=$(urlencode "$SYSTEM_PASSWORD")&scope=openid")
ACCESS_TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token // empty')
[ -n "$ACCESS_TOKEN" ] || fail "failed to obtain an access token: $TOKEN_RESP"
log "  ${C_GREEN}${SYM_OK}${C_RESET} token acquired"

# --- Step 4: deploy sample APIs + MCP server --------------------------------

log "Deploying sample APIs and MCP server to the Developer Portal at $API_PORTAL_URL ..."
ACCESS_TOKEN="$ACCESS_TOKEN" API_PORTAL_URL="$API_PORTAL_URL" "$THIS_DIR/seed-samples.sh"

# --- Step 5: create an application and subscribe it to every deployed API --
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
