# <app-name>

_What this app is, why you run it, and any quirks worth remembering. Free-form notes live here._

- **URL:** https://<hostname>.<your-domain>
- **VM / static IP:** <vm-name> / 10.0.0.42
- **Upstream:** <link to the app's project / image docs>

## Deploy
```bash
# on the app VM (sparse-checkout this app dir)
cp .env.example .env                     # fill in real values
echo -n '<db-password>' > secrets/db_password.txt
docker compose up -d
```

## Notes
- Egress: <needs internet? why>
- Hardening deviations: <anything flipped off read_only, extra caps, and why>
- Backups: `volumes/` holds all state — snapshot/tar it.
