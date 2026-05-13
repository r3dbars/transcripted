# Support Email Routing Smoke

Use this when support mail looks suspicious:

- `help@transcripted.app` seems quiet when it should not be
- Cloudflare shows an Email Routing DNS warning
- someone reports a bounce or missing support reply

Run the quick public DNS check:

```bash
bash scripts/ops/support-email-routing-smoke.sh
```

Run the deeper Cloudflare check when you have an API token:

```bash
CLOUDFLARE_API_TOKEN="your-token" bash scripts/ops/support-email-routing-smoke.sh --api
```

The token needs:

- `Zone:Read`
- `Email Routing Rules Read`

Optional:

```bash
export CLOUDFLARE_ZONE_ID="your-zone-id"
```

Use `CLOUDFLARE_ZONE_ID` if your token can read the zone but cannot list zones.

## What It Checks

The public check verifies:

- `transcripted.app` has Cloudflare Email Routing MX targets:
  - `route1.mx.cloudflare.net`
  - `route2.mx.cloudflare.net`
  - `route3.mx.cloudflare.net`
- there are no competing non-Cloudflare MX targets
- the SPF TXT record includes `include:_spf.mx.cloudflare.net`
- the domain is still returning Cloudflare nameservers

The API check also verifies:

- Email Routing is enabled for `transcripted.app`
- Cloudflare does not report missing Email Routing DNS records
- `help@transcripted.app` has an enabled routing rule, or an enabled catch-all route covers it

The script does not print forwarding destination addresses.

## How To Read It

`PASS` means that part looks healthy.

`WARN` means the script could not fully prove something, or the setup works but is less explicit than expected. A common warning is no API token, which means only DNS was checked.

`FAIL` means something is likely wrong. Fix the failure before trusting support mail.

## If It Fails

Open Cloudflare, then go to:

```text
transcripted.app -> Email Routing
```

Check:

- Settings: Email DNS records should be configured.
- DNS records: Cloudflare should show the required MX and SPF records.
- Routing rules: `help@transcripted.app` should be enabled.

After the script passes, send one real message from an outside mailbox to
`help@transcripted.app` and confirm it lands in the support inbox. The script is
a routing smoke check, not an end-to-end delivery test.
