# Local Redis TLS Setup (for `rediss://`)

This project supports Redis over TLS for Upstash (`rediss://`) and local development.

## 1) Generate local CA + server cert

```bash
mkdir -p docker/redis/tls

# 1. Local CA
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout docker/redis/tls/ca.key \
  -out docker/redis/tls/ca.crt \
  -days 3650 \
  -subj "/CN=usezombie-local-ca"

# 2. Server key + CSR (SAN includes redis + localhost)
openssl req -nodes -newkey rsa:2048 \
  -keyout docker/redis/tls/server.key \
  -out docker/redis/tls/server.csr \
  -subj "/CN=redis" \
  -addext "subjectAltName=DNS:redis,DNS:localhost,IP:127.0.0.1"

# 3. Sign server cert with local CA
openssl x509 -req \
  -in docker/redis/tls/server.csr \
  -CA docker/redis/tls/ca.crt \
  -CAkey docker/redis/tls/ca.key \
  -CAcreateserial \
  -out docker/redis/tls/server.crt \
  -days 365 \
  -copy_extensions copy
```

## 2) Configure environment

For local host runs:

```dotenv
REDIS_URL=rediss://localhost:6379
REDIS_TLS_CA_CERT_FILE=/absolute/path/to/usezombie/docker/redis/tls/ca.crt
```

For Docker Compose service-to-service (`zombied -> redis`), compose already sets:

- `REDIS_URL=rediss://redis:6379`
- `REDIS_TLS_CA_CERT_FILE=/app/docker/redis/tls/ca.crt`

## 3) Start services

```bash
docker compose up -d redis
# or full stack
docker compose up -d
```

## 4) Verify

```bash
# App-side verification
REDIS_URL=rediss://localhost:6379 REDIS_TLS_CA_CERT_FILE=$PWD/docker/redis/tls/ca.crt zig build run -- doctor
```

## Notes

- `tls-auth-clients no` is correct for this setup because we are not doing mTLS client-certificate auth.
- Upstash uses server-auth TLS with password auth in URL (for example `rediss://default:<password>@...:6379`).
