/*
 * Copyright (c) 2024, WSO2 LLC. (http://www.wso2.com) All Rights Reserved.
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

const passport = require('passport');
const OAuth2Strategy = require('passport-oauth2');
const { safeDecodeJwt, getNestedClaim } = require('../utils/jwtDecode');
const { config } = require('../config/configLoader');
const { portalRoles } = require('./authorization');
const constants = require('../utils/constants');
const logger = require('../config/logger');
const orgDao = require('../dao/organizationDao');
const { resolveScopedOrg } = require('./authMiddleware');

function configurePassport(SERVER_ID) {
    if (config.auth.mode === 'idp') {
        const idpScope = config.auth.idp.scope;
        const strategy = new OAuth2Strategy({
            issuer: config.auth.idp.issuer,
            authorizationURL: config.auth.idp.authorizationUrl,
            tokenURL: config.auth.idp.tokenUrl,
            userInfoURL: config.auth.idp.userInfoUrl,
            clientID: config.auth.idp.clientId,
            clientSecret: config.auth.idp.clientSecret || undefined,
            callbackURL: config.auth.idp.callbackUrl,
            pkce: true,
            state: true,
            logoutURL: config.auth.idp.logoutUrl,
            logoutRedirectURI: config.auth.idp.logoutRedirectUri,
            certificate: '',
            jwksURL: config.auth.idp.jwksUrl,
            passReqToCallback: true,
            scope: typeof idpScope === 'string'
                ? idpScope.split(/\s+/).filter(Boolean)
                : (Array.isArray(idpScope) ? idpScope : ['openid', 'profile', 'email']),
        }, async (req, accessToken, refreshToken, params, profile, done) => {
            if (!accessToken) {
                return done(new Error('Access token missing'));
            }
            let isAdmin = false;
            const decodedJWT = safeDecodeJwt(params.id_token) || {};
            const decodedAccessToken = safeDecodeJwt(accessToken) || {};
            // Debug-only (auth.logging.level = "debug") — direct way to see which of
            // these two tokens actually carries a given claim for a given IDP/
            // authenticator, since it isn't always the same one (see roles below).
            logger.debug('IDP login: decoded tokens', { idToken: decodedJWT, accessToken: decodedAccessToken });
            // given_name/nickname require the user's profile to have a display name set,
            // which isn't guaranteed — a freshly provisioned B2B user commonly has only a
            // username. Fall back through the standard OIDC username claim, then WSO2's
            // own (always populated, since it's the login identifier itself), then the
            // bare subject — so the header never renders blank next to the avatar.
            const firstName = decodedJWT['given_name'] || decodedJWT['nickname']
                || decodedJWT['preferred_username'] || decodedJWT['username'] || decodedJWT['sub'];
            const lastName = decodedJWT['family_name'];
            const organizationId = getNestedClaim(decodedJWT, config.auth.claimMappings.organization) ?? '';
            // Prefer the ACCESS token for roles/groups, falling back to the ID token:
            // matches authMiddleware.js's bearer-token path (which has only ever read
            // roles from the access token), and WSO2 IS's own role-claim population can
            // land a role assignment in the access token without it also reaching the ID
            // token — an OIDC-authenticator-dependent gap, not something either token's
            // absence should be treated as "no role assigned".
            const rawRoles = getNestedClaim(decodedAccessToken, config.auth.claimMappings.roles)
                ?? getNestedClaim(decodedJWT, config.auth.claimMappings.roles) ?? '';
            const roles = Array.isArray(rawRoles)
                ? rawRoles
                : String(rawRoles).split(/[\s,]+/).filter(Boolean);
            const rawGroups = getNestedClaim(decodedAccessToken, config.auth.claimMappings.groups)
                ?? getNestedClaim(decodedJWT, config.auth.claimMappings.groups) ?? '';
            const groups = Array.isArray(rawGroups)
                ? rawGroups
                : String(rawGroups).split(/[\s,]+/).filter(Boolean);
            const { admin: adminRole } = portalRoles();
            if (roles.includes(adminRole)) {
                isAdmin = true;
            }
            // The IDP is trusted to say who the user is and, via its org claim, which
            // organization this login belongs to — resolved exactly like a bearer
            // token's claim (authMiddleware.resolveScopedOrg), auto-provisioning an
            // organization this portal hasn't seen before rather than rejecting it.
            // Skipped when the claim is absent: that case is already failed closed by
            // authResolver, which needs an organization claim in IDP mode for the
            // REST API this session will go on to call.
            let resolvedOrgHandle = '';
            if (organizationId) {
                const orgErr = await resolveScopedOrg(req, organizationId, 'idp login claim', { fromTrustedClaim: true });
                if (orgErr) return done(orgErr);
                try {
                    resolvedOrgHandle = (await orgDao.getByUuid(req.orgId)).handle;
                } catch (err) {
                    logger.error('Failed to resolve organization handle after login', { error: err.message });
                    return done(err);
                }
            }

            const returnTo = req.session.returnTo;
            let view = '';
            if (returnTo) {
                const startIndex = returnTo.indexOf('/views/') + 7;
                const endIndex = returnTo.indexOf('/', startIndex) !== -1 ? returnTo.indexOf('/', startIndex) : returnTo.length;
                view = returnTo.substring(startIndex, endIndex);
            }
            const imageURL = decodedJWT['google_pic_url'] || decodedJWT['picture'] || constants.DEFAULT_PROFILE_IMAGE_URL;
            // Capture scopes from access token — supports both 'scope' (string) and 'scp' (array) variants
            const rawScope = decodedAccessToken?.scope ?? decodedAccessToken?.scp;
            const grantedScopes = Array.isArray(rawScope)
                ? rawScope.join(' ')
                : (typeof rawScope === 'string' ? rawScope : '');
            profile = {
                firstName: firstName ? (firstName.includes(" ") ? firstName.split(" ")[0] : firstName) : '',
                lastName: lastName ? lastName : (firstName && firstName.includes(" ") ? firstName.split(" ")[1] : ''),
                view,
                idToken: params.id_token,
                email: decodedJWT['email'] || req.session.username,
                [constants.ROLES.ORGANIZATION_CLAIM]: organizationId,
                // The organization the claim actually resolved to — used once, right
                // after login, to redirect into that organization's own view rather
                // than the URL segment the login button happened to be clicked from
                // (authController.handleCallback). Not carried into the session by
                // serializeUser below: nothing after this one redirect needs it.
                resolvedOrgHandle,
                returnTo: req.session.returnTo,
                accessToken,
                refreshToken,
                grantedScopes,
                [constants.ROLES.ROLE_CLAIM]: roles,
                [constants.ROLES.GROUP_CLAIM]: groups,
                isAdmin,
                [constants.USER_ID]: decodedAccessToken?.[constants.USER_ID],
                serverId: SERVER_ID,
                imageURL,
            };
            req.session.regenerate((err) => {
                if (err) {
                    logger.error('Session regeneration failed', {
                        error: err.message,
                        stack: err.stack,
                        operation: 'sessionRegeneration'
                    });
                    return done(err);
                }
                req.login(profile, (err) => {
                    if (err) {
                        logger.error('Login failed after session regeneration', {
                            error: err.message,
                            stack: err.stack,
                            operation: 'loginAfterSessionRegen'
                        });
                        return done(err);
                    }
                    return done(null, profile);
                });
            });
        });

        strategy.authorizationParams = function (options) {
            const params = {};
            if (options.prompt) params.prompt = options.prompt;
            if (options.fidp) params.fidp = options.fidp;
            if (options.username) params.username = options.username;
            if (options.org) params.org = options.org;
            return params;
        };

        passport.use(strategy);
    }

    passport.serializeUser((user, done) => {
        logger.debug('Serializing user', { userId: user.sub });
        const profile = {
            firstName: user.firstName,
            lastName: user.lastName,
            email: user.email,
            imageURL: user.imageURL,
            view: user.view,
            idToken: user.idToken,
            [constants.ROLES.ORGANIZATION_CLAIM]: user[constants.ROLES.ORGANIZATION_CLAIM],
            returnTo: user.returnTo,
            accessToken: user.accessToken,
            refreshToken: user.refreshToken,
            grantedScopes: user.grantedScopes || '',
            [constants.ROLES.ROLE_CLAIM]: user.roles,
            [constants.ROLES.GROUP_CLAIM]: user.groups,
            isAdmin: user.isAdmin,
            [constants.USER_ID]: user[constants.USER_ID],
            isLocalAuth: user.isLocalAuth || false,
            serverId: user.serverId,
        };
        done(null, profile);
    });

    passport.deserializeUser((sessionData, done) => {
        done(null, sessionData);
    });
}

module.exports = { configurePassport };

