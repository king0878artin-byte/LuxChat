# LuxChat

Responsive web messaging MVP. GitHub Pages hosts the frontend; Supabase provides phone/password authentication, PostgreSQL, realtime messages, and private file storage.

## Implemented in this MVP
- Phone number + password registration and sign-in
- Persistent Supabase Auth session in the same browser/device
- Direct conversations created by exact phone lookup
- Groups and channels with phone-number invitations
- Realtime text messages
- Edit and delete your own messages
- Private file attachments up to 25 MB
- Responsive layout and PWA manifest

This is not yet a complete Bale feature clone. Voice/video calls, push notifications, contact-book sync, forwarding, reactions, message search, moderation and advanced privacy controls remain future work.

## Backend setup
1. Create a project at https://supabase.com/.
2. Open SQL Editor and run all of supabase/schema.sql.
3. In Authentication > Providers > Phone, enable phone/password authentication.
4. Configure SMS verification if required. If phone confirmation is disabled, understand the reduced account-verification protection.
5. In Project Settings > API, copy the Project URL and public anon/publishable key.
6. Open LuxChat, choose Backend configuration, and enter those two public values.

Never place the Supabase service-role key, database password, or SMS provider secret in the browser or GitHub repository. The public anon/publishable key is designed for frontend use; Row Level Security protects database access.

Each new browser/device needs the public project configuration once. Supabase Auth persists the signed-in session on that browser. Logging out or clearing browser data requires signing in again.

## GitHub Pages deployment
In repository Settings > Pages, choose GitHub Actions as the source. The workflow in .github/workflows/deploy.yml deploys the root folder on pushes to main. Expected URL:
https://king0878artin-byte.github.io/LuxChat/

## Local preview
Serve the folder over HTTP (not file://), for example: python -m http.server 8000.

## Production readiness
Before inviting real users, configure verified phone sign-up, abuse/rate limits, account recovery, moderation/reporting, backup and retention policies, attachment scanning, and audit the RLS policies. Do not treat this MVP as a fully production-hardened messenger.
