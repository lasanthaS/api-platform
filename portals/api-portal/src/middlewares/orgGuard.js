/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com) All Rights Reserved.
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
'use strict';

/*
 * Resolves the {orgHandle} segment of a page URL against organizations this
 * portal's (portal_id-scoped) database already knows about
 * (src/utils/orgContext.js's requireKnownOrg).
 *
 * The database is shared across organizations, so without this the URL segment is
 * an unauthenticated selector for *any* string: a visitor could otherwise probe
 * arbitrary handles rather than only ones that exist. Requiring the segment to
 * resolve to a real organization closes that; it does NOT by itself decide
 * whether the *caller* may be there — ensureAuthenticated.belongsToTargetOrg is
 * what compares an authenticated session's own org claim against the organization
 * resolved here, the same way authResolver's trusted-claim branches do for the
 * REST API. An org that only exists in a *different* portal_id still doesn't
 * resolve here (requireKnownOrg is portal_id-scoped), and this layer never
 * creates one — provisioning an org from a trusted claim happens at login
 * (passportConfig.js) or a bearer-token call (authMiddleware.js), both of
 * which have a verified identity behind them; a bare URL segment does not.
 *
 * Registered through `router.param()` rather than a path-matching middleware on
 * purpose: the param callback receives the exact value the route handler will go
 * on to use, so there is no second, independent parse of the URL that could
 * disagree with the router's own (the failure mode behind encoded-traversal auth
 * bypasses). Express's router runs param callbacks for every matched layer —
 * `.use()` paths included — and only once per request per param name, so
 * registering the same guard on several routers is safe and doesn't re-run.
 */

const { config } = require('../config/configLoader');
const logger = require('../config/logger');
const orgContext = require('../utils/orgContext');
const { CustomError } = require('../utils/errors/customErrors');

/**
 * Express param callback: 404s unless `value` names an organization already
 * known to this portal, and populates req.orgId with the resolved uuid when it
 * does.
 *
 * @param {(res, err) => void} [onReject] how to answer a rejection. Omitted, the
 *   error goes to `next()` and app.js renders an HTML error page — right for the
 *   page routers, wrong for the JSON endpoints (MCP registry, try-it proxy) whose
 *   callers are programs. Those pass a responder that emits their own error shape.
 */
async function pinOrgParam(req, res, next, value, onReject) {
    // Design mode renders from disk and has no organization to resolve — config
    // validation skips this check there, so there is nothing to look up.
    if (config.designMode?.enabled) return next();

    try {
        req.orgId = await orgContext.requireKnownOrg(value);
        return next();
    } catch (error) {
        if (error instanceof CustomError && error.statusCode === 403) {
            logger.warn('Rejected request for an unknown organization', {
                requested: value,
                operation: 'pinOrgParam',
            });
            const err = new Error('Not Found');
            err.status = 404;
            return onReject ? onReject(res, err) : next(err);
        }
        logger.error('Organization lookup failed', {
            requested: value,
            error: error.message,
            operation: 'pinOrgParam',
        });
        const err = new Error('Internal Server Error');
        err.status = 500;
        return onReject ? onReject(res, err) : next(err);
    }
}

/**
 * Registers the guard for a router's org URL parameter.
 *
 * @param {import('express').Router} router
 * @param {string} [paramName] the router's own org param — 'orgName' for the page
 *   routers, which all spell it that way.
 * @param {(res, err) => void} [onReject] see pinOrgParam.
 */
function attachOrgGuard(router, paramName = 'orgName', onReject) {
    router.param(paramName, (req, res, next, value) => pinOrgParam(req, res, next, value, onReject));
    return router;
}

/**
 * Middleware form, for the one router whose org segment comes from its *mount*
 * path (app.js mounts mcpRegistryRoute under '/registry/:orgHandle' and
 * '/:orgHandle/registry'). Params captured by a mount path belong to the parent
 * router's layer, so a `router.param()` registered on the child never fires for
 * them; this reads the same mergeParams-supplied value the service handlers use.
 *
 * @param {string} [paramName]
 * @param {(res, err) => void} [onReject] see pinOrgParam.
 */
function orgGuardMiddleware(paramName = 'orgHandle', onReject) {
    return (req, res, next) => pinOrgParam(req, res, next, req.params[paramName], onReject);
}

module.exports = { attachOrgGuard, orgGuardMiddleware, pinOrgParam };
