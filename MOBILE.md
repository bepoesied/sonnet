# Mobile API Contract

This is the current mobile contract for Sonnet. It documents the implemented
JSON API, backend-mediated OIDC PKCE handoff expectations, token lifecycle, and
offline playback behavior for a native mobile client.

## Scope

Implemented endpoints:

- `GET /auth/mobile/authorize`
- `POST /api/auth/mobile/exchange`
- `POST /api/auth/token-refresh`
- `POST /api/auth/logout`
- `GET /api/me`
- `GET /api/books`
- `GET /api/books/:id`
- `GET /api/books/:id/progress`
- `PUT /api/books/:id/progress`
- `PUT /api/books/:id/complete`
- `PUT /api/books/:id/incomplete`

Not included in this milestone:

- There is no download-manifest endpoint. `GET /api/books/:id` is the
  download and playback detail contract.
- The full library is not available offline. Only explicitly downloaded books
  are local and playable offline.

## Authentication

Mobile login uses a backend-mediated OIDC handoff protected by PKCE (`S256`) so
Sonnet only requires a single confidential OIDC client for both web and mobile:

1. The mobile app creates a fresh RFC 7636 PKCE `code_verifier` (43–128
   unreserved characters), derives `code_challenge = BASE64URL_NO_PAD(SHA256(code_verifier))`,
   and generates a random CSRF `state` (16–512 unreserved characters).
2. The app opens `GET /auth/mobile/authorize` in the system browser or native
   auth session (`ASWebAuthenticationSession` / Chrome Custom Tabs), not an
   embedded webview.
3. Sonnet validates `redirect_uri`, `code_challenge_method=S256`,
   `code_challenge`, and `state`, then runs standard confidential OIDC
   Authorization Code + PKCE against the identity provider using Sonnet's single
   HTTPS callback (`/auth/callback`).
4. After validating the IdP callback and upserting the local user from OIDC
   userinfo claims, Sonnet creates a short-lived (60s), single-use, PKCE-bound
   handoff `code` (`Phoenix.Token` encrypted, backed by a one-time `UserToken`
   nonce) and redirects to `<redirect_uri>?code=<code>&state=<state>` without
   leaving a web session in the browser.
5. The mobile app verifies `state` matches its login attempt and sends `code`,
   `code_verifier`, and `redirect_uri` to `POST /api/auth/mobile/exchange` to
   receive Sonnet API tokens.

Server configuration:

- `SONNET_OIDC_ISSUER` is the single OIDC issuer URL shared by web and mobile.
- `SONNET_OIDC_CLIENT_ID` and `SONNET_OIDC_CLIENT_SECRET` configure Sonnet's
  single confidential OIDC client.
- `SONNET_MOBILE_REDIRECT_URIS` optionally configures a comma-separated list of
  exact allowlisted mobile redirect URIs (defaults to `sonnet://auth/callback`).
- Register only `https://<PHX_HOST>/auth/callback` as the redirect URI in the
  identity provider.

### `GET /auth/mobile/authorize`

Query parameters (all required):

- `redirect_uri`: Exact match against Sonnet's allowlisted mobile redirect URIs
  (e.g., `sonnet://auth/callback`).
- `code_challenge`: Base64url-encoded (no padding) SHA-256 digest of
  `code_verifier` (43 characters).
- `code_challenge_method`: Must be `S256` (`plain` is rejected).
- `state`: Random opaque URL-safe string (16–512 characters) echoed back on
  redirect.

Invalid parameters return `400 Bad Request` directly without redirecting to the
identity provider or to an unvalidated URI.

On callback success, Sonnet redirects with `302` and `Cache-Control: no-store`,
`Referrer-Policy: no-referrer` to:

```text
sonnet://auth/callback?code=<one-time-handoff-code>&state=<state>
```

On callback failure, Sonnet redirects to:

```text
sonnet://auth/callback?error=authentication_failed&state=<state>
```

### `POST /api/auth/mobile/exchange`

Request:

```json
{
  "code": "one-time-handoff-code",
  "code_verifier": "rfc7636-pkce-code-verifier",
  "redirect_uri": "sonnet://auth/callback"
}
```

Success `200` (with `Cache-Control: no-store`):

```json
{
  "access_token": "base64url-session-token",
  "refresh_token": "base64url-refresh-token",
  "user": {
    "id": 123,
    "name": "Ada Lovelace",
    "avatar_url": "https://example.test/avatar.png"
  }
}
```

Errors use `{"error":"..."}`:

- Missing or non-string fields return `400` with `{"error":"invalid_request"}`.
- Unknown, expired, already-used, PKCE-mismatched, or redirect-URI-mismatched
  codes return `401` with `{"error":"invalid_grant"}`.
- Codes are consumed atomically on the first exchange attempt (even if
  `code_verifier` or `redirect_uri` is wrong) and expire after 60 seconds.

### `POST /api/auth/token-refresh`

Request:

```json
{
  "refresh_token": "base64url-refresh-token"
}
```

Success `200`:

```json
{
  "access_token": "new-base64url-session-token",
  "refresh_token": "new-base64url-refresh-token"
}
```

Refresh tokens rotate on use. The previous refresh token is deleted after a
successful refresh. Invalid or expired refresh tokens return `422` with
`{"error":"Invalid or expired refresh token"}`.

### `POST /api/auth/logout`

Send `Authorization: Bearer <access_token>`. The body may include a refresh
token to revoke it too:

```json
{
  "refresh_token": "base64url-refresh-token"
}
```

Success `200` is `{"ok":true}`. Missing or invalid authorization returns
`401` with an `error` string.

## Token Lifecycle

Authenticated API requests use:

```text
Authorization: Bearer <access_token>
```

Rules:

- The token value is the base64url string returned by Sonnet.
- Access/session tokens are valid for 14 days.
- Refresh tokens are valid for 30 days.
- Refresh tokens rotate on successful refresh.
- Cookie session reissue does not apply to Bearer-token mobile requests.
- Store refresh tokens in secure storage.
- Keep access tokens in the least-persistent storage practical for the app.
- If offline when the access token expires, already downloaded books remain
  playable locally.
- Refresh the token when network returns before syncing progress or downloading
  new content.
- If the refresh token expires while offline, keep downloaded books playable,
  but require login before server sync or new downloads resume.

## Current User

### `GET /api/me`

Requires Bearer auth. Use it at app startup to validate a stored access token
and restore the current profile.

Success `200`:

```json
{
  "id": 123,
  "name": "Ada Lovelace",
  "avatar_url": "https://example.test/avatar.png"
}
```

Missing or invalid Bearer auth returns `401` with `{"error":"Unauthorized"}`.

## Books

### `GET /api/books`

Requires Bearer auth. This powers the online `Library` screen only. It is not
an offline catalog endpoint.

Success `200` is an array:

```json
[
  {
    "id": 1,
    "title": "Book Title",
    "author": "Author Name",
    "narrator": "Narrator Name",
    "description": "Description text",
    "cover_url": "https://storage.test/cover",
    "is_completed": false
  }
]
```

### `GET /api/books/:id`

Requires Bearer auth. This payload is used to open, play, or download one
book.

Success `200`:

```json
{
  "id": 1,
  "title": "Book Title",
  "author": "Author Name",
  "narrator": "Narrator Name",
  "description": "Description text",
  "cover_url": "https://storage.test/cover",
  "is_completed": false,
  "chapters": [
    {
      "id": 10,
      "title": "Chapter 1",
      "position": 1,
      "start_ms": 0,
      "end_ms": 1800000,
      "duration_ms": 1800000,
      "media_asset_id": 99,
      "audio_url": "https://storage.test/audio"
    }
  ],
  "progress": {
    "chapter_id": 10,
    "offset_ms": 42000,
    "updated_at": "2026-05-15T12:00:00Z",
    "is_completed": false
  }
}
```

If no progress exists, `progress` is:

```json
{
  "chapter_id": null,
  "offset_ms": 0,
  "updated_at": null,
  "is_completed": false
}
```

Invalid book IDs return `400`. Missing books return `404`. Auth failures
return `401`.

## Downloads And Offline Playback

`cover_url` and `audio_url` are presigned download URLs. The current server
default expiry is 3600 seconds.

Mobile client rules:

- Do not use the full presigned URL as durable local identity.
- Persist files by stable identifiers such as `book.id`, `chapter.id`, and
  `media_asset_id`.
- If a URL expires before download completes, refetch `GET /api/books/:id`
  while online and retry with the refreshed URL.
- The online `Library` comes from `GET /api/books`.
- `Downloaded Books` is app-owned local state built from saved book detail,
  downloaded cover files, downloaded chapter audio files, and local progress.
- Offline playback must not require `/api/books`, `/api/books/:id`, or fresh
  presigned URLs for books whose files are already downloaded.
- Deleting a local download removes local metadata and files only. It does not
  delete the server book.

## Progress

### `GET /api/books/:id/progress`

Requires Bearer auth. Success `200` has the same shape as the `progress` object
in book detail. Invalid book IDs return `400`. Missing books return `404`.

### `PUT /api/books/:id/progress`

Requires Bearer auth.

Request:

```json
{
  "chapter_id": 10,
  "offset_ms": 42000,
  "updated_at": "2026-05-15T12:00:00Z"
}
```

Rules:

- `chapter_id` is required and must belong to the book.
- `offset_ms` defaults to `0` when omitted and must be non-negative.
- `updated_at` is optional ISO 8601.
- If `updated_at` is omitted, server receive time is used.

Success is `204 No Content`. Invalid IDs return `400`. Invalid payloads or
chapter/book mismatches return `422`. Missing books return `404`.

Offline replay and conflict behavior:

- While offline, queue progress locally and keep the newest state per book.
- On reconnect, send the latest local progress with local `updated_at`.
- Server conflict rule is newest timestamp wins per book.
- Strictly older `updated_at` values are ignored and still return `204`.
- Equal or newer timestamps update the stored progress.
- Progress updates set `is_completed` to `false` unless a completion endpoint
  is used.
- Clients should replay queued events in chronological order or collapse to the
  final desired state before syncing.

### `PUT /api/books/:id/complete`

Requires Bearer auth. Optional body:

```json
{
  "chapter_id": 10
}
```

Marks the book complete for the user and returns `204 No Content`. If
`chapter_id` is omitted, the first chapter is used. Invalid IDs return `400`.
Missing books return `404`. No chapters, invalid chapter, or invalid payload
returns `422`.

### `PUT /api/books/:id/incomplete`

Requires Bearer auth. Marks existing progress incomplete and returns
`204 No Content`. If no progress exists, the endpoint still succeeds with
`204`. Invalid IDs return `400`. Missing books return `404`. Invalid existing
progress returns `422`.

## Error Shape

Controller-handled API errors use a top-level `error` string, for example:

```json
{
  "error": "Unauthorized"
}
```

Framework-level JSON errors may use Phoenix's default shape:

```json
{
  "errors": {
    "detail": "Not Found"
  }
}
```

Mobile clients should branch on HTTP status first and treat the response body
as display or debug detail.

## Optional Later Work

Potential future additions that are not part of this contract:

- Device/session metadata for per-device token revocation.
- Pagination, search, or filtering for large libraries.
- A route to refresh presigned URLs for a single chapter.
- OpenAPI documentation once the mobile API stabilizes further.
