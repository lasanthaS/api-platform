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
const { config } = require('../../config/configLoader');
const eventDao = require('../../dao/eventDao');
const orgDao = require('../../dao/organizationDao');
const { matchSubscribers } = require('./subscriberRegistry');
const { onPublished } = require('./eventPublisher');
const db = require('../../db/driver');
const logger = require('../../config/logger');
const orgContext = require('../../utils/orgContext');

// events table name — mirrors eventDao.js's EVENTS_TABLE. Kept as a raw
// db.execute() call here (rather than a new DAO export) because this is the
// only caller that needs a bare status flip outside of any of eventDao's
// existing higher-level operations.
const EVENTS_TABLE = 'events';

let running = false;
let intervalHandle = null;

/**
 * Process one batch of PENDING (non-key) events for each organization this
 * dispatcher is responsible for: resolve subscribers, create delivery rows,
 * mark events as DISPATCHED.
 *
 * Claims are scoped per organization — the events table is shared with every
 * other instance pointed at this database, and by default each instance
 * dispatches only its own (see the config comment below). Only with
 * webhooks.delivery.dispatchAllOrganizations does a single instance claim
 * every organization sharing this portal_id's database, for a deployment
 * that runs one shared container for multiple tenant organizations instead
 * of one container per organization.
 */
async function runBatch() {
    const delivery = config.webhooks && config.webhooks.delivery;
    const batchSize = (delivery && delivery.batchSize) || 50;
    const orgUuids = delivery && delivery.dispatchAllOrganizations
        ? (await orgDao.list()).map((org) => org.uuid)
        : [await orgContext.getOrgUuid()];

    for (const orgUuid of orgUuids) {
        try {
            const events = await eventDao.claimPending(batchSize, orgUuid);
            for (const event of events) {
                try {
                    const subscribers = await matchSubscribers(event.org_uuid, event.type);
                    if (subscribers.length === 0) {
                        // No matching subscribers — mark as delivered immediately.
                        await db.execute(`UPDATE ${EVENTS_TABLE} SET status = ? WHERE uuid = ? AND portal_id = ?`,
                            ['ALL_DELIVERED', event.uuid, orgContext.getPortalId()]);
                        continue;
                    }
                    await eventDao.createDeliveries(event.uuid, subscribers, null, null);
                } catch (err) {
                    logger.error('Failed to create deliveries for event', {
                        eventId: event.uuid, error: err.message
                    });
                    try {
                        await db.execute(`UPDATE ${EVENTS_TABLE} SET status = ? WHERE uuid = ? AND portal_id = ?`,
                            ['PENDING', event.uuid, orgContext.getPortalId()]);
                        logger.info('Restored event eligibility after delivery creation failure', {
                            eventId: event.uuid
                        });
                    } catch (restoreErr) {
                        logger.error('Failed to restore event eligibility', {
                            eventId: event.uuid, error: restoreErr.message
                        });
                    }
                }
            }
        } catch (err) {
            // Isolates one organization's claim failure from the others in the
            // same tick — only relevant when dispatchAllOrganizations is looping
            // more than one org uuid here.
            logger.error('Failed to claim/process events for organization', { orgUuid, error: err.message });
        }
    }
}

function start() {
    if (running) return;
    running = true;

    const delivery = config.webhooks && config.webhooks.delivery;
    const pollMs = (delivery && delivery.pollIntervalMs) || 2000;

    async function tick() {
        try {
            // runDetached() matters here specifically because of the onPublished(tick)
            // registration below: eventPublisher.js's bus.emit('event_published') fires
            // synchronously from inside the *publishing* caller's own db.withTransaction()
            // callback, and without this, runBatch()'s ambient db calls would inherit
            // that (possibly already-committed) transaction instead of the module-level
            // pool — see db.runDetached()'s doc comment in src/db/driver.js.
            await db.runDetached(runBatch);
        } catch (err) {
            logger.error('Batch error', { error: err.message || String(err) });
        }
    }

    intervalHandle = setInterval(tick, pollMs);
    // Also run immediately on event_published signals (no-op if nothing pending).
    onPublished(tick);

    logger.info('Dispatcher started', { pollIntervalMs: pollMs });
}

function stop() {
    running = false;
    if (intervalHandle) {
        clearInterval(intervalHandle);
        intervalHandle = null;
    }
}

module.exports = { start, stop };
