/*
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
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
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
'use strict';

const orgDao = require('../dao/organizationDao');
const labelDao = require('../dao/labelDao');
const viewDao = require('../dao/viewDao');
const subscriptionPlanDao = require('../dao/subscriptionPlanDao');
const { config } = require('../config/configLoader');
const orgContext = require('../utils/orgContext');
const { planIdpOrgIdReconcile } = require('../utils/idpOrgIdPolicy');
const constants = require('../utils/constants');
const logger = require('../config/logger');
const db = require('../db/driver');
const { NotFoundError } = require('../utils/errors/customErrors');

/**
 * Brings the organization's stored idp_ref_id in line with auth.idp_org_id in config.
 *
 * Config is the only writer of this field — the admin API refuses to change it
 * (adminService.updateOrganization) — so there is no operator edit here to clobber,
 * and without this reconcile a value that was wrong on first boot, or an IdP that
 * changed the org claim it asserts, could only be repaired with direct SQL.
 *
 * Sessions already holding the previous org claim stop passing the org check
 * (ensureAuthenticated.belongsToTargetOrg) and their owners have to log in again —
 * hence the warn-level log recording both values.
 */
async function reconcileIdpOrgId(org) {
    const configured = orgContext.getConfiguredIdpOrgId();
    const stored = org.idp_ref_id || '';
    if (planIdpOrgIdReconcile({ configured, stored }).action === 'skip') return;

    const conflict = await orgDao.findOtherOrgClaimingIdentifier(configured, org.uuid);
    const { action } = planIdpOrgIdReconcile({
        configured,
        stored,
        conflictingOrgHandle: conflict?.handle,
    });
    if (action === 'conflict') {
        logger.error('Org: configured auth.idp_org_id is already claimed by another organization — keeping the stored value', {
            handle: org.handle,
            configured,
            stored,
            claimedBy: conflict.handle,
            operation: 'reconcileIdpOrgId',
        });
        return;
    }

    await orgDao.updateIdpRefId(org.uuid, configured, constants.SYSTEM_ACTOR);
    logger.warn('Org: IdP organization id updated from configuration — existing sessions carrying the previous org claim must log in again', {
        handle: org.handle,
        previous: stored,
        current: configured,
        operation: 'reconcileIdpOrgId',
    });
}

/**
 * Seeds an organization and its dependent resources: the org row, a default
 * label, a default view, the label-view link, and default subscription plans.
 * Each resource is checked/created individually so an existing org with
 * missing defaults is repaired without skipping the rest of the seed.
 *
 * Lookup is by exact handle, not orgDao.get()'s handle→display_name→idp_ref_id
 * ladder: in a shared multi-organization database the looser match could resolve
 * to a *different* organization that happens to carry this handle as its display
 * name, and the seed would then adopt that row.
 *
 * An organization that already exists is left as previously configured — this is
 * safe to call repeatedly, including concurrently for the same handle (a racing
 * create is resolved by re-reading rather than failing).
 *
 * Used both for this instance's own organization at startup (seedDefaultOrg
 * below) and, from authMiddleware.js's resolveScopedOrg, to provision an
 * organization named by a trusted token claim the first time it's seen.
 *
 * @param {string} handle
 * @param {{ displayName?: string, idpRefId?: string }} [opts]
 * @returns {Promise<{ org: object, existed: boolean }>}
 */
async function seedOrg(handle, { displayName, idpRefId } = {}) {
    const payload = {
        displayName: displayName || handle,
        handle,
        idpRefId: idpRefId || handle,
        configuration: {},
        createdBy: constants.SYSTEM_ACTOR,
    };

    let org;
    let existed = true;
    try {
        org = await orgDao.getByHandle(handle);
    } catch (notFound) {
        if (!(notFound instanceof NotFoundError)) {
            logger.error('Failed to look up organization', {
                error: notFound.message,
                handle,
                operation: 'seedOrg',
            });
            throw notFound;
        }
        existed = false;
        try {
            org = await orgDao.create(payload);
        } catch (createError) {
            // A concurrent seed of the same handle can race this create — treat the
            // resulting duplicate-key error as success and re-read, rather than fail
            // the request that triggered provisioning.
            if (db.isDuplicateKeyError(createError)) {
                existed = true;
                org = await orgDao.getByHandle(handle);
            } else {
                logger.error('Failed to seed organization', {
                    error: createError.message,
                    stack: createError.stack,
                    handle,
                    operation: 'seedOrg',
                });
                throw createError;
            }
        }
    }

    const orgId = org.uuid;

    let labelId;
    try {
        const label = await labelDao.update(orgId, { handle: 'default', displayName: 'default' }, constants.SYSTEM_ACTOR);
        labelId = label.uuid;
    } catch (error) {
        logger.error('Failed to seed default label', { error: error.message, handle, operation: 'seedOrg' });
        return { org, existed };
    }

    let viewId;
    try {
        const view = await viewDao.update(orgId, 'default', 'default', constants.SYSTEM_ACTOR);
        viewId = view.uuid;
    } catch (error) {
        logger.error('Failed to seed default view', { error: error.message, handle, operation: 'seedOrg' });
        return { org, existed };
    }

    try {
        await labelDao.addToView(orgId, labelId, viewId, constants.SYSTEM_ACTOR);
    } catch (error) {
        if (!db.isDuplicateKeyError(error)) {
            logger.error('Failed to seed label-view link', { error: error.message, handle, operation: 'seedOrg' });
            return { org, existed };
        }
    }

    if (config.organization.autoCreateSubscriptionPlans) {
        for (const plan of constants.DEFAULT_SUBSCRIPTION_PLANS) {
            try {
                await subscriptionPlanDao.createMany(orgId, [plan], constants.SYSTEM_ACTOR);
            } catch (error) {
                if (!db.isDuplicateKeyError(error)) {
                    logger.error('Failed to seed subscription plan', {
                        error: error.message,
                        handle,
                        operation: 'seedOrg',
                        plan: plan.displayName,
                    });
                }
            }
        }
    }

    return { org, existed };
}

/**
 * Seeds this instance's own organization — the one named by
 * config.organization.handle (see src/utils/orgContext.js) — on startup.
 *
 * idp_ref_id is the one field seedOrg() above doesn't fully own for an
 * already-existing row: auth.idp_org_id in config is its sole writer, and
 * reconcileIdpOrgId re-applies it on every boot regardless of what seedOrg saw.
 */
async function seedDefaultOrg() {
    const orgName = orgContext.getHandle();
    if (!orgName) return;

    let org, existed;
    try {
        ({ org, existed } = await seedOrg(orgName, {
            displayName: orgContext.getDisplayName(),
            idpRefId: orgContext.getIdpOrgId(),
        }));
    } catch (error) {
        // Rethrow rather than continue: without this row the portal has no
        // organization to scope anything to, so every request would 500 while the
        // process still reported itself healthy. startServer awaits this before
        // binding the listener, so the failure stops startup instead.
        throw error;
    }

    if (existed) {
        try {
            await reconcileIdpOrgId(org);
        } catch (error) {
            // Non-fatal, unlike a failed lookup or create: the organization exists and
            // the portal can serve it with the previously stored value. Logins whose
            // org claim only matches the newly configured value will fail until the
            // write succeeds, which the operator needs to see rather than have startup
            // aborted underneath a working deployment.
            logger.error('Failed to reconcile organization idp_ref_id from configuration', {
                error: error.message,
                handle: orgName,
                operation: 'seedDefaultOrg',
            });
        }
    }

    // Drop any uuid orgContext resolved before the org row existed, so the first
    // request after startup re-reads it rather than reusing a pre-seed miss.
    orgContext.resetCache();

    logger.info('Org: organization seeded ✓', { handle: orgName });
}

module.exports = { seedDefaultOrg, seedOrg };
