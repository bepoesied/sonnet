# Mobile API Contract

This is the current mobile contract for Sonnet. It documents the implemented
JSON API, native OIDC PKCE expectations, token lifecycle, and offline playback
behavior for a native mobile client.

## Scope

Implemented endpoints:

- `POST /api/auth/oidc-login`
- `POST /api/auth/token-refresh`
- `POST /api/auth/logout`
- `GET /api/mobile-config`
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

Mobile login uses native OIDC Authorization Code + PKCE:

1. The mobile app creates the temporary PKCE verifier, challenge, state, and
   nonce for each login attempt.
2. The app opens the provider authorization URL in the system browser or native
   auth session, not an embedded webview.
3. The provider redirects back to the app through the app's registered custom
   scheme, universal link, or app link.
4. The app exchanges the OIDC authorization code and PKCE verifier directly
   with the OIDC provider.
5. The app sends the resulting OIDC `id_token` to Sonnet.

Sonnet does not receive or validate the PKCE verifier or challenge. Sonnet
validates the `id_token` issuer, audience, signature/JWKS, expiry, and subject,
then upserts the local user from OIDC claims and issues Sonnet API tokens.

Server configuration:

- `SONNET_OIDCC_ISSUER` is the provider issuer used for web token validation.
- `SONNET_OIDCC_CLIENT_ID` and `SONNET_OIDCC_CLIENT_SECRET` configure the
  confidential web login client.
- `SONNET_MOBILE_OIDCC_ISSUER` optionally configures a separate OIDC issuer URL
  for mobile PKCE login. Some providers (e.g., Authentik) issue different
  issuer URLs per application. If omitted, the mobile client uses the same
  issuer as `SONNET_OIDCC_ISSUER`.
- `SONNET_MOBILE_OIDCC_CLIENT_ID` configures the public/native mobile OIDC
  client ID. Required for mobile authentication; there is no fallback to the
  web client ID.
- Sonnet uses a fixed scope set for mobile discovery and token validation so the
  app contract cannot drift via environment configuration.
- A separate public/native mobile client is preferred because the mobile app uses
  PKCE and cannot hold a client secret.

### `POST /api/auth/oidc-login`

Request:

```json
{
  "id_token": "provider.jwt.id_token"
}
```

Success `200`:

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

Errors use `{"error":"..."}`. Missing or malformed `id_token` returns `400`.
Invalid issuer, audience, signature, expiry, or subject returns `401` with an
error such as `invalid_issuer`, `invalid_audience`, `invalid_signature`,
`expired_token`, `missing_subject`, or `invalid_token`.

### `GET /api/mobile-config`

Returns the OIDC metadata a native client needs to start Authorization Code +
PKCE login when only the Sonnet API base URL is preconfigured.

Success `200`:

```json
{
  "issuer": "https://issuer.example",
  "client_id": "sonnet-mobile",
  "authorization_endpoint": "https://issuer.example/authorize",
  "token_endpoint": "https://issuer.example/token",
  "end_session_endpoint": "https://issuer.example/logout",
  "scopes": ["openid", "profile"],
  "response_type": "code",
  "code_challenge_methods_supported": ["S256"]
}
```

If Sonnet cannot resolve its OIDC provider configuration, it returns `503` with
`{"error":"oidc_unavailable"}`.

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
