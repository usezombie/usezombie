# Clerk Security

## Why This Exists

API identity verification needs a centralized issuer and signed JWT validation to prevent unauthorized control-plane mutation.

## Decisions

1. Clerk JWT verification for API authentication in hardened environments.
2. JWKS endpoint required and validated.
3. Clear error mapping for token expiry, signature, and JWKS failures.

## What This Prevents

1. Unauthenticated API mutations.
2. Acceptance of expired or invalid signatures.
3. Silent auth bypass when identity provider is unavailable.

## Required Configuration

1. `CLERK_SECRET_KEY`
2. `CLERK_JWKS_URL`
3. Optional issuer/audience constraints (`CLERK_ISSUER`, `CLERK_AUDIENCE`)

## Software Setup Steps

1. Configure Clerk application and JWT settings.
2. Set required Clerk env variables in deployment secrets.
3. Validate JWKS reachability during doctor checks.
4. Confirm API endpoints reject invalid/expired tokens.

## Verification

1. Expired token maps to deterministic unauthorized path.
2. JWKS outage maps to auth-unavailable path.
3. Signature failure maps to unauthorized path.
