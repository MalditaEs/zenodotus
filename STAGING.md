# Staging Zenodotus — MV-6 orchestrator cutover test

A second, isolated Zenodotus that routes scraping to the orchestrator, so you can validate
the full loop (archive → orchestrator → Antena → media → callback → ArchiveItem) **without
touching production**. Production keeps running Hypatia the whole time.

## What you need
- A host with Docker (a small VM or a workspace).
- A **staging hostname reachable from the internet** — the orchestrator (in the Hetzner
  cluster) must be able to POST the callback to it. Either a real subdomain with TLS
  (e.g. `vault-staging.factcheckinsights.org` → this host, Caddy gets the cert) or a tunnel
  (Cloudflare Tunnel / Tailscale Funnel).
- This branch (`dfernandez/mv-6-orchestrator-cutover`) and the prod secrets (Bitwarden) for
  the `[FILL]` values.
- The **Keycloak client secret for `zenodotus`** (Bitwarden). The orchestrator refuses any
  request without a Keycloak bearer (401); Zenodotus mints one itself from
  `MITROPOULOS_CLIENT_ID` + `MITROPOULOS_CLIENT_SECRET`. Quick check that the credentials
  work, before bringing anything up:
  ```bash
  curl -s https://sso.botalite.es/realms/botalite/protocol/openid-connect/token \
    -d grant_type=client_credentials -d client_id=zenodotus -d client_secret=$SECRET | jq .expires_in
  # → 300
  ```

## Bring it up
```bash
git checkout dfernandez/mv-6-orchestrator-cutover
cp .env.staging.example .env          # fill [FILL] / [GEN] values
# Point Caddy at your staging host: add a `<your-host> { reverse_proxy web:3000 }` block
#   to ./Caddyfile (Caddy will get the TLS cert automatically), or front it with a tunnel.

docker compose -f docker-compose.yml -f docker-compose.staging.yml \
  -p zenodotus-staging up -d --build
```
`web` runs migrations on first boot (RUN_MIGRATIONS=true), so the fresh DB is set up
automatically. Check it's healthy: `docker compose -p zenodotus-staging ps`.

## Point the orchestrator's callback at staging (the non-obvious step)
The orchestrator is a single shared instance; its `ZENODOTUS_CALLBACK_BASE` targets ONE
Zenodotus. Because **production still uses Hypatia** (`USE_ORCHESTRATOR=false` in prod), the
orchestrator gets no production traffic — so it's safe to repoint its callback at staging
during the test:
```bash
kubectl -n mediavault patch configmap mitropoulos-config \
  --type merge -p '{"data":{"ZENODOTUS_CALLBACK_BASE":"https://vault-staging.factcheckinsights.org"}}'
kubectl -n mediavault rollout restart deploy/mitropoulos-worker deploy/mitropoulos-api
```
**Revert it after testing:**
```bash
kubectl -n mediavault patch configmap mitropoulos-config \
  --type merge -p '{"data":{"ZENODOTUS_CALLBACK_BASE":"https://vault.factcheckinsights.org"}}'
kubectl -n mediavault rollout restart deploy/mitropoulos-worker deploy/mitropoulos-api
```

## Test
1. Open the staging MediaVault site and **archive a URL** (twitter/x, instagram, facebook,
   tiktok).
2. Watch the loop: staging → orchestrator (`/scrape`) → Antena → media to S3 → callback to
   staging → `ArchiveItem` created.
3. Verify the archived item shows the text, author, and **downloadable media**.
4. Optionally diff against Hypatia's output with `python -m mitropoulos.dualrun`.

## Notes
- Isolated: own Postgres (`db`) + Neo4j + Redis, own volumes, own compose project — nothing
  shared with production.
- Media: reuses the same GCS bucket by default (files coexist by basename); use a test
  bucket if you prefer.
- YouTube will error until Antena deploys its YouTube endpoint (known).
