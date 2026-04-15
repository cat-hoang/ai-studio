# VPN Preflight Check

## Purpose

Verify VPN connectivity to `wtg.zone` resources before any skill that accesses internal WTG services. This skill MUST pass before proceeding with Crikey API calls, internal Git operations, or any other wtg.zone-dependent work.

## Configuration

Read base URL from config files:
- `config.yaml`
- `config.local.yaml` (overrides)

The relevant config key is `crikey_base_url` (e.g., `https://crikey.wtg.zone`).

## Execution Steps

### Step 1: DNS Resolution

Run DNS resolution against `crikey.wtg.zone`:

```bash
powershell -NoProfile -Command "try { Resolve-DnsName -Name 'crikey.wtg.zone' -ErrorAction Stop | Select-Object -First 1 -ExpandProperty IPAddress; Write-Output 'DNS_OK' } catch { Write-Output 'DNS_FAIL'; exit 1 }"
```

- If the output contains `DNS_FAIL` or the command exits non-zero, the VPN is not connected. Skip Step 2 and go directly to the failure output.
- If the output contains `DNS_OK`, proceed to Step 2.

### Step 2: HTTPS Connectivity

Attempt an HTTPS connection with a 3-second timeout:

```bash
powershell -NoProfile -Command "try { $resp = Invoke-WebRequest -Uri 'https://crikey.wtg.zone' -UseDefaultCredentials -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop; Write-Output 'HTTPS_OK' } catch { Write-Output 'HTTPS_FAIL'; exit 1 }"
```

- If the output contains `HTTPS_FAIL` or the command exits non-zero, the VPN may be connected but HTTPS is blocked or the service is down. Go to failure output.
- If the output contains `HTTPS_OK`, go to success output.

### Success Output

Print exactly:

```
VPN OK
```

Then allow the calling skill/workflow to continue.

### Failure Output

Print exactly:

```
VPN not connected. Connect to WTG VPN before proceeding.
```

Then STOP. Do not proceed with any subsequent steps in the calling skill or workflow. Report the failure to the user and suggest they connect to the WTG VPN.

## Parameters

None. This skill is a dependency invoked by other skills.

## Notes

- This skill is idempotent and safe to run multiple times.
- If both DNS and HTTPS checks pass, the VPN is confirmed connected.
- Some transient failures may occur; if the user confirms VPN is connected, retry once before giving up.

