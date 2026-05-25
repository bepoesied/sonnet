# Sonnet

Sonnet is a Phoenix-based web application.

## Community

Join our Matrix space: [#sonnetaudiobookserver:matrix.org](https://matrix.to/#/#sonnetaudiobookserver:matrix.org)

## Deployment

The application is containerized and hosted at `quay.io/drangon/sonnet`.

> [!IMPORTANT]
> For security, the application must be served over HTTPS and should be deployed
> behind a reverse proxy like Traefik or Nginx.

### Environment Variables

The following environment variables must be configured in your production
environment.

#### Phoenix & Endpoint

- `PHX_HOST`: The public domain name of your application (e.g.,
  `sonnet.example.com`).
- `PORT`: The internal port the application listens on (default: `4000`).
- `SECRET_KEY_BASE`: A secret key used to sign and encrypt cookies. You can
  generate one using:

  ```bash
  openssl rand -base64 64 | paste --delimiters '' --serial
  ```

- `DNS_CLUSTER_QUERY`: (Optional) Used for service discovery in clustered
  environments.

#### Database

- `DATABASE_URL`: The Ecto connection string (e.g.,
  `ecto://user:pass@host/database`).
- `POOL_SIZE`: (Optional) The database pool size (default: `10`).
- `ECTO_IPV6`: (Optional) Set to `true` if your database requires IPv6.

#### OIDC Authentication

- `SONNET_OIDCC_ISSUER`: The OIDC issuer URL (e.g.,
  `https://accounts.google.com`).
- `SONNET_OIDCC_CLIENT_ID`: Your confidential web OIDC client ID.
- `SONNET_OIDCC_CLIENT_SECRET`: Your confidential web OIDC client secret.
- `SONNET_MOBILE_OIDCC_CLIENT_ID`: (Optional) A separate public/native OIDC
  client ID for mobile PKCE login. If omitted, Sonnet falls back to
  `SONNET_OIDCC_CLIENT_ID`.

Sonnet exposes `GET /api/mobile-config` so a native mobile app can discover the
issuer, client ID, authorization endpoint, and other OIDC metadata from the API
server alone. The advertised mobile scopes are fixed by the server.

If you configure a separate mobile OIDC client for PKCE login, register it as a
public/native client with Authorization Code flow enabled and PKCE set to
`S256`. Set the mobile redirect URI to `sonnet://auth/callback`.

#### S3 Storage

- `SONNET_S3_ACCESS_KEY_ID`: Your S3 access key.
- `SONNET_S3_ACCESS_KEY_SECRET`: Your S3 secret key.
- `SONNET_S3_BUCKET`: The name of the S3 bucket.
- `SONNET_S3_HOST`: The S3 endpoint host (e.g., `s3.amazonaws.com`).
- `SONNET_S3_REGION`: (Optional) The S3 region (default: `us-east-1`).
- `SONNET_S3_SCHEME`: (Optional) The S3 scheme, e.g., `https://` (default:
  `https://`).
- `SONNET_S3_PORT`: (Optional) The S3 port (default: `443`).
- `SONNET_S3_PREFIX`: (Optional) A prefix for stored objects.

### Running the Application

You can pull and run the image from [quay.io](https://quay.io/drangon/sonnet).

#### 1. Run Migrations

Before starting the server, run the database migrations:

```bash
docker run --rm \
  -e DATABASE_URL=... \
  quay.io/drangon/sonnet /app/bin/migrate
```

#### 2. Start the Server

```bash
docker run -p 4000:4000 \
  -e PHX_HOST=sonnet.example.com \
  -e DATABASE_URL=... \
  -e SECRET_KEY_BASE=... \
  -e SONNET_OIDCC_ISSUER=... \
  -e SONNET_OIDCC_CLIENT_ID=... \
  -e SONNET_OIDCC_CLIENT_SECRET=... \
  -e SONNET_MOBILE_OIDCC_CLIENT_ID=... \
  -e SONNET_S3_ACCESS_KEY_ID=... \
  -e SONNET_S3_ACCESS_KEY_SECRET=... \
  -e SONNET_S3_BUCKET=... \
  -e SONNET_S3_HOST=... \
  quay.io/drangon/sonnet
```

### Health Check

The application provides a health check endpoint at `/health` which returns a
simple `ok` response. This can be used for container health checks or load
balancer probes.

```bash
curl http://localhost:4000/health
```

## Development

This project uses [devenv](https://devenv.sh/) to manage local development
dependencies and tools.

1. Run `devenv up` to start the required background services (PostgreSQL, etc.).
1. In a new terminal, run `mix setup` to install dependencies and setup the
   database.
1. Start the Phoenix server with `mix phx.server` or inside IEx with `iex -S mix
phx.server`.

Now you can visit [`localhost:4001`](https://localhost:4001) from your browser.

There are 2 debug consoles available:

1. The Phoenix LiveDashboard
   [`localhost:4001/dev/dashboard`](https://localhost:4001/dev/dashboard)
1. The Oban Dashboard
   [`localhost:4001/dev/oban`](https://localhost:4001/dev/oban)
