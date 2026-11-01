import express from 'express';
import { OIDCConfig } from '../oidc/oidcConfig.js';
import userRepository from '../repositories/userRepository.js';
import { JWT_SECRET, TOKEN_EXPIRY } from '../middleware/auth.js';
import appSettingsRepository from '../repositories/appSettingsRepository.js';
import groupRepository from '../repositories/groupRepository.js';
import jwt from 'jsonwebtoken';
import Logger from '../logger.js';
import { getDb } from '../config/database.js';
import { up_v1_5_0_snippets } from '../config/migrations/20241117-migration.js';
import { isAdmin } from '../middleware/adminAuth.js';

const router = express.Router();

// The macOS app signs in through ASWebAuthenticationSession, which only hands the final
// redirect back to the app when it uses the app's URL scheme.
export const DESKTOP_CALLBACK_URL = 'bytestash://auth/callback';

export function desktopRedirect(params) {
  return `${DESKTOP_CALLBACK_URL}?${new URLSearchParams(params).toString()}`;
}

function getBaseUrl(req) {
  const forwardedProto = req.get('X-Forwarded-Proto');

  const isSecure = req.secure ||
    forwardedProto === 'https' ||
    req.get('X-Forwarded-SSL') === 'on';

  const protocol = isSecure ? 'https' : 'http';

  const host = req.get('X-Forwarded-Host') || req.get('Host');

  Logger.debug('Protocol detection:', {
    secure: req.secure,
    forwardedProto,
    resultingProtocol: protocol,
    host
  });

  const baseUrl = `${protocol}://${host}${process.env.BASE_PATH || ''}`;
  return baseUrl.endsWith('/') ? baseUrl.slice(0, -1) : baseUrl;
}

router.get('/config', async (req, res) => {
  try {
    const oidc = await OIDCConfig.getInstance();
    res.json(oidc.getConfig());
  } catch (error) {
    Logger.error('OIDC config fetch error:', error);
    res.status(500).json({ error: 'Failed to fetch OIDC configuration' });
  }
});

router.get('/auth', async (req, res) => {
  try {
    const oidc = await OIDCConfig.getInstance();
    if (!oidc.isEnabled()) {
      return res.redirect('/login?error=config_error');
    }

    const baseUrl = getBaseUrl(req);
    const clientType = req.query.client === 'desktop' ? 'desktop' : 'web';
    const authUrl = await oidc.getAuthorizationUrl(
      baseUrl,
      oidc.getScopes().join(' '),
      clientType
    );

    Logger.debug('Generated auth URL:', authUrl);
    res.redirect(authUrl);
  } catch (error) {
    Logger.error('OIDC auth error:', error);
    const errorMessage = encodeURIComponent(error.message || 'Unknown error');
    res.redirect(`/login?error=provider_error&message=${errorMessage}`);
  }
});

router.get('/logout', async (req, res) => {
  try {
    const oidc = await OIDCConfig.getInstance();
    if (!oidc.isEnabled()) {
      return res.redirect('/');
    }

    const authHeader = req.headers.cookie;
    const token = authHeader && authHeader.split('=')[1];

    // Clear the auth cookie
    res.clearCookie('bytestash_token', { path: '/' });

    // Reset logged_in state
    oidc.loggedIn = false;

    if (!token) {
      return res.redirect(`${process.env.BASE_PATH || ''}/auth/logout_callback`);
    }

    const baseUrl = getBaseUrl(req);
    const logoutUrl = await oidc.getLogoutUrl(baseUrl, token);

    if (logoutUrl) {
      Logger.debug('Generated Logout URL:', logoutUrl);
      res.redirect(logoutUrl);
    } else {
      // Provider doesn't support end_session_endpoint (e.g., Google)
      // Perform local-only logout
      const logoutCallbackUrl = `${process.env.BASE_PATH || ''}/auth/logout_callback`;
      res.redirect(logoutCallbackUrl);
    }
  } catch (error) {
    Logger.error('OIDC logout error:', error);
    res.clearCookie('bytestash_token', { path: '/' });
    res.redirect(`${process.env.BASE_PATH || ''}/auth/logout_callback`);
  }
});

router.get('/callback', async (req, res) => {
  let clientType = 'web';
  // Sends a login result to whichever client started the flow.
  const redirectLogin = (error, message) => {
    if (clientType === 'desktop') {
      return res.redirect(desktopRedirect(message ? { error, message } : { error }));
    }
    const messageParam = message ? `&message=${encodeURIComponent(message)}` : '';
    return res.redirect(`${process.env.BASE_PATH || ''}/login?error=${error}${messageParam}`);
  };

  try {
    const oidc = await OIDCConfig.getInstance();
    clientType = oidc.getStateClientType(req.query.state);
    if (!oidc.isEnabled()) {
      return res.status(404).json({ error: 'OIDC not enabled' });
    }

    const db = getDb();
    const userCount = db.prepare('SELECT COUNT(*) as count FROM users').get().count;
    const hasUsers = userCount > 0;

    const baseUrl = getBaseUrl(req);
    const callbackUrl = oidc.getCallbackUrl(baseUrl);
    const queryString = new URLSearchParams(req.query).toString();
    const currentUrl = queryString ? `${callbackUrl}?${queryString}` : callbackUrl;

    Logger.debug('Full callback URL:', currentUrl);

    const { tokens, userInfo } = await oidc.handleCallback(currentUrl, callbackUrl);
    Logger.debug('Authentication successful');

    const existingUser = await userRepository.findByOIDCId(
      userInfo.sub,
      oidc.config.serverMetadata().issuer
    );

    // Only trust the email for invites when the provider says it is verified (Google does).
    const verifiedEmail = userInfo.email && userInfo.email_verified !== false ? userInfo.email : null;

    if (hasUsers && !existingUser) {
      const invited = groupRepository.hasInvite(verifiedEmail);
      if (!appSettingsRepository.isRegistrationOpen() && !invited) {
        Logger.info('OIDC registration blocked: New accounts not allowed');
        return redirectLogin('registration_disabled');
      }
    }

    const user = await userRepository.findOrCreateOIDCUser(
      userInfo,
      oidc.config.serverMetadata().issuer
    );

    if (user.is_active === 0 || user.is_active === false) {
      Logger.error('OIDC login blocked: Account deactivated');
      return redirectLogin('account_deactivated', 'Your account has been deactivated');
    }

    await userRepository.updateLastLogin(user.id);

    if (verifiedEmail) {
      groupRepository.acceptInvites(user.id, verifiedEmail);
    }

    if (!hasUsers) {
      await up_v1_5_0_snippets(db, user.id);
    }

    const token = jwt.sign({
      id: user.id,
      username: user.username,
      id_token: tokens.id_token
    }, JWT_SECRET, {
      expiresIn: TOKEN_EXPIRY
    });

    // Set OIDC login config
    oidc.loggedIn = true;

    if (clientType === 'desktop') {
      return res.redirect(desktopRedirect({ token }));
    }
    res.redirect(`${process.env.BASE_PATH || ''}/auth/callback?token=${token}`);
  } catch (error) {
    Logger.error('OIDC callback error:', error);
    let errorType = 'auth_failed';
    let errorDetails = '';

    if (error.message?.includes('state parameter')) {
      errorType = 'auth_failed';
      errorDetails = 'Your authentication session has expired';
    } else if (error.message?.includes('accounts disabled')) {
      errorType = 'registration_disabled';
    } else if (error.message?.includes('OIDC configuration')) {
      errorType = 'config_error';
    } else if (error.response?.status === 401 || error.response?.status === 403) {
      errorType = 'provider_error';
      errorDetails = 'Authorization denied by identity provider';
    }

    redirectLogin(errorType, errorDetails);
  }
});

export default router;