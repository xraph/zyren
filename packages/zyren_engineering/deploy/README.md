# Self-hosted reviews

Set `REVIEW_DOMAIN` to your public hostname and `REVIEW_ACCESS_FILE` to an
absolute path outside the repository. Point the hostname at your server and make
ports 80 and 443 available, then run from this directory:

```sh
docker compose up --build -d
```

Caddy provisions HTTPS for the configured hostname and forwards requests to the
private review container. Only Caddy publishes ports. The service runs as UID
65532, stores the session on `review_data`, and reads its access configuration
from a mounted secret. See [Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https)
for certificate issuance requirements.

Your access file has this shape:

```json
{
  "schemaVersion": 1,
  "documentId": "review",
  "grants": [
    {"tokenSha256": "<SHA-256 of your reader token>", "role": "reader"},
    {"tokenSha256": "<SHA-256 of your writer token>", "role": "writer"}
  ]
}
```

Use high-entropy tokens of at least 32 characters from your secret manager.
Distribute raw tokens to clients through that manager. The server configuration
contains their SHA-256 digests. Readers can GET the configured document; writers
can also PUT with its current ETag. Each service instance owns one document.
Changing `documentId` does not grant access to a different existing session file.
Restart the review container after updating grants to revoke or rotate access.

Connect the review app to `https://your-hostname/review`. Enter the raw token in
the session dialog; the app keeps it in memory. The example does not provide an
identity provider or a credential issuer.

For direct TLS without Caddy, run `example/hosted_review_service.dart` with the
access file and session file as arguments. Set `ZYREN_REVIEW_CERT` and
`ZYREN_REVIEW_KEY` to the certificate chain and private key paths, and optionally
set `ZYREN_REVIEW_BIND` and `ZYREN_REVIEW_PORT`. Public cleartext binding is
rejected unless the explicit Caddy proxy configuration is selected.

Back up the data volume while writes are stopped. Restore the complete session
envelope to preserve revision tokens. Retain the sibling lock file while any
process is running and use one owning isolate per process. Do not attach a plain
`FileEngineeringStore` writer to a session file.

## Local verification

From the repository root:

```sh
docker build -f packages/zyren_engineering/deploy/Dockerfile -t zyren-review:local .
python3 packages/zyren_engineering/deploy/smoke_test.py
```

The smoke test creates disposable containers, a private network and volumes. It
uses Caddy's local CA for `localhost`, verifies that CA in the client, exercises
reader and writer grants, rejects a stale write, and checks data after restarting
the Linux service container. It removes its containers and volumes on exit.
The Dart tests also exercise direct TLS with a test CA and reject an untrusted
certificate. These checks do not configure your public DNS or issue your domain's
certificate.
