# RPKI-Aware RTBH

# An implementation using FORT, SLURM, FRR, and Local RTBH Controllers

**Author:** Nicolas Antoniello, Carlos Martinez  
**Revision:** v4 — architecture plus complete implementation  
**Scope:** IPv4 destination-based RTBH using exact `/32` host routes  
**Document model:** Each functional block is described first, then implemented immediately afterward.

> **Important:** The addresses, ASNs, and peer IPs used in this guide are examples. Replace them with production values. The example `192.0.2.1/32` discard next-hop is from documentation space and should be replaced by an operator-reserved address in production.

---

# Part I — Architecture and Design

## 1. Problem Statement

Assume public RPKI contains:

```text
10.0.0.0/24
Origin AS65000
maxLength 24
```

During a DDoS attack, customer AS65000 wants to request an RTBH for:

```text
10.0.0.5/32
```

Normal public Route Origin Validation correctly classifies this route as:

```text
RPKI Invalid
```

because:

```text
32 > public maxLength 24
```

Changing the public ROA to `maxLength 32` would weaken the customer's Internet routing authorization. The goal is therefore to permit the `/32` **only inside the operator's RTBH control plane**, without weakening normal public ROV.

## 2. Core Separation of Responsibilities

The design separates three independent questions:

```text
PUBLIC RPKI AUTHORIZATION
    May origin ASN X announce prefix P on the Internet?

RTBH SERVICE ENTITLEMENT
    Is origin ASN X enabled to use our RTBH service?

ACTIVE RTBH REQUEST
    Is that customer currently requesting blackholing of this exact /32?
```

They are answered by different components:

```text
FORT-PUBLIC      -> public RPKI authorization
customers.yaml   -> RTBH service entitlement
BGP request      -> active RTBH request
```

An RTBH is active only when all three conditions are true.

## 3. Effective Authorization Rule

For IPv4:

```text
ACTIVE_RTBH(prefix, origin_as) =
    prefix_length == 32
    AND
    route carries RTBH-REQUEST
    AND
    origin_as is explicitly enabled in customers.yaml
    AND
    FORT-RTBH classifies prefix/origin_as as RPKI Valid
```

The customer ASN is derived from the BGP `AS_PATH`. It is **not** encoded in the RTBH Large Community.

## 4. Final Architecture

```text
                              GLOBAL RPKI
                                   |
                                   v
                           +---------------+
                           |  FORT-PUBLIC  |
                           |   no SLURM    |
                           +-------+-------+
                                   |
                              public VRPs
                                   |
                                   v
                         +-------------------+
                         | RTBH Reconciler   |
                         | customers.yaml    |
                         +---------+---------+
                                   |
                           generated SLURM
                                   |
                    +--------------+--------------+
                    |                             |
                    v                             v
              +-----------+                 +-----------+
              | FORT-RTBH |                 | FORT-RTBH |
              |     1     |                 |     2     |
              +-----+-----+                 +-----+-----+
                    | RTR                         | RTR
                    v                             v
             +-------------+               +-------------+
             | FRR-RTBH-1  |               | FRR-RTBH-2  |
             | controller  |               | controller  |
             +------+------+               +------+------+
                    \                             /
                     \                           /
                      +------ iBGP -------------+
                              |
                         Existing RRs
                              |
              +---------------+---------------+
              |               |               |
              v               v               v
           EDGE-1          EDGE-2          EDGE-N
              |               |               |
           customers       customers       customers
```

The existing Route Reflectors remain normal RRs. `FRR-RTBH-1` and `FRR-RTBH-2` are ordinary RR clients, not Route Reflectors.

## 5. Request Flow

```text
CUSTOMER
   |
   | exact /32
   | customer RTBH community 65010:666
   v
FRR-MAIN EDGE
   |
   | generic ingress policy
   | remove customer-facing signal
   | add 65010:9000:0 = RTBH-REQUEST
   | low LOCAL_PREF
   | keep route in BGP
   | keep route out of FIB
   v
EXISTING RR LAYER
   |
   | Add-Path only toward RTBH nodes
   | keep REQUEST visible even when non-best
   v
FRR-RTBH-1 / FRR-RTBH-2
   |
   | exact /32
   | RTBH-REQUEST
   | origin ASN from AS_PATH
   | ASN enabled in customers.yaml
   | FORT-RTBH == Valid
   v
LOCAL RTBH CONTROLLER
   |
   | create ephemeral local BGP network /32
   v
FRR-RTBH
   |
   | outbound policy adds 65010:9001:0
   v
EXISTING RR LAYER
   |
   | set high LOCAL_PREF on approved route
   v
ALL EDGES
   |
   | exact /32 + RTBH-APPROVED
   | set local discard next-hop
   v
Null0
```

## 6. Withdrawal Flow

A customer withdraw, offboarding event, or RPKI authorization change follows the reverse path automatically:

```text
REQUEST or authorization disappears
        |
        v
controller desired state no longer contains /32
        |
        v
no network <prefix>/32 on FRR-RTBH
        |
        v
BGP withdraw
        |
        v
RRs
        |
        v
all edges remove approved /32
        |
        v
blackhole removed
```

## 7. Community Model

The examples use operator ASN `65010`.

### Customer-facing request

```text
65010:666
```

Meaning:

```text
The customer requests RTBH for this route.
```

This is only an ingress signaling mechanism.

### Internal request

```text
65010:9000:0
```

Fields:

```text
65010 -> operator namespace
9000  -> RTBH-REQUEST
0     -> reserved
```

This value is the same for every customer.

### Locally validated request marker

On the FRR-RTBH nodes only:

```text
65010:9010:0
```

Fields:

```text
65010 -> operator namespace
9010  -> RTBH-VALIDATED-REQUEST
0     -> reserved
```

This marker is added by the FRR-RTBH inbound route-map **only after** matching `rpki valid`. It gives the local controller a clean and simple query target. It is not intended to leave the RTBH nodes.

### Approved RTBH route

```text
65010:9001:0
```

Fields:

```text
65010 -> operator namespace
9001  -> RTBH-APPROVED
0     -> reserved
```

This is the signal every edge translates into local discard forwarding.

## 8. What `additive` Means

The edge uses:

```frr
set large-community 65010:9000:0 additive
```

Without `additive`, setting a Large Community can replace the existing Large Community attribute. With `additive`, FRR appends the new value and preserves existing Large Communities.

Example before:

```text
65010:100:1
65010:200:50
```

After:

```frr
set large-community 65010:9000:0 additive
```

result:

```text
65010:100:1
65010:200:50
65010:9000:0
```

## 9. Why Add-Path Is Still Needed — But Only in One Place

Once an approved `/32` is originated with high preference, it becomes the normal best path. Without Add-Path, an RR can stop advertising the original lower-preference REQUEST toward the RTBH validator. The controller would then think the request disappeared and remove the approval, which can create an unstable cycle.

The solution is deliberately narrow:

```text
RR -> FRR-RTBH only:
    addpath-tx-all-paths
```

An outbound route-map restricts this feed to exact `/32` routes carrying `RTBH-REQUEST`.

No Add-Path is required on customer sessions or normal edge sessions.

## 10. Configuration Constants Used in This Guide

| Item | Example |
|---|---|
| Operator AS | `65010` |
| Customer request community | `65010:666` |
| RTBH-REQUEST | `65010:9000:0` |
| RTBH-APPROVED | `65010:9001:0` |
| Local validated-request marker | `65010:9010:0` |
| FORT-PUBLIC RTR | `10.0.1.15:323` |
| FORT-RTBH-1 RTR | `10.0.1.16:323` |
| FORT-RTBH-2 RTR | `10.0.1.17:323` |
| Example local discard next-hop | `192.0.2.1/32` |
| Active RTBH prefix length | exact `/32` |

---

# Part II — Public RPKI Validation Plane

## 11. Block: FORT-PUBLIC

### What it does

`FORT-PUBLIC` is the normal RPKI relying party. It contains no RTBH-specific local exceptions. Edge routers use it for normal ROV.

It also produces the validated VRP file consumed by the RTBH reconciler.

### How it works

```text
Global RPKI repositories
        |
        v
FORT-PUBLIC
        |
        +--> RTR -> normal FRR-MAIN ROV
        |
        +--> validated-roas.csv -> RTBH reconciler
```

The implementation below keeps the existing CSV output model. The reconciler supplied later can parse both FORT's documented CSV and JSON formats.

### Implementation

Assuming FORT is already installed as:

```text
/usr/local/bin/fort
```

use a configuration such as:

```text
/etc/fort/config.json
```

```json
{
  "mode": "server",
  "tal": "/etc/fort/tal",
  "local-repository": "/var/lib/fort/repository",
  "output": {
    "roa": "/var/lib/fort/output/validated-roas.csv",
    "format": "csv"
  },
  "server": {
    "address": [
      "127.0.0.1",
      "10.0.1.15"
    ],
    "port": "323",
    "max-rtr-version": 1,
    "interval": {
      "validation": 3600,
      "refresh": 3600,
      "retry": 600,
      "expire": 7200
    }
  },
  "log": {
    "output": "console",
    "level": "info"
  }
}
```

The existing systemd service can remain in use. To bind TCP/323 without running the validator as root, the service should have:

```ini
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
```

Verify:

```bash
sudo systemctl restart fort
sudo systemctl status fort
sudo ss -lntp | grep ':323'
```

Verify output:

```bash
head -5 /var/lib/fort/output/validated-roas.csv
```

The documented FORT CSV format is:

```text
ASN,Prefix,Max prefix length
AS1000,192.0.2.0/24,24
```

---

# Part III — RTBH Entitlement and SLURM Generation

## 12. Block: Customer Entitlement Database

### What it does

This file answers only one question:

```text
Is this ASN enabled for the RTBH service?
```

It does **not** contain customer prefixes. Prefix authorization comes from public RPKI.

### Offboarding semantics

The model is closed-world:

```text
present + enabled:true  -> enabled
present + enabled:false -> disabled
absent                  -> disabled
```

Therefore deleting a customer entry is a valid and complete offboarding operation.

### Implementation

Install the YAML dependency used by both local programs:

```bash
sudo apt update
sudo apt install python3 python3-yaml
```

Create the directory:

```bash
sudo install -d -m 0755 /etc/rtbh
```

Create:

```text
/etc/rtbh/customers.yaml
```

```yaml
customers:
  - asn: 65000
    enabled: true

  - asn: 65020
    enabled: true

  - asn: 65030
    enabled: false
```

Set conservative permissions:

```bash
sudo chown root:root /etc/rtbh/customers.yaml
sudo chmod 0644 /etc/rtbh/customers.yaml
```

Validate YAML syntax:

```bash
python3 -c 'import yaml; yaml.safe_load(open("/etc/rtbh/customers.yaml")); print("OK")'
```

## 13. Block: RTBH SLURM Reconciler

### What it does

The reconciler combines:

```text
current public VRPs
        +
explicitly enabled ASNs
```

and generates the complete desired RTBH SLURM state.

For each current IPv4 public VRP whose origin ASN is enabled, it creates:

```text
same prefix
same origin ASN
maxPrefixLength 32
```

Example:

```text
PUBLIC:
10.0.0.0/24 AS65000 maxLength 24

LOCAL RTBH ASSERTION:
10.0.0.0/24 AS65000 maxPrefixLength 32
```

The public VRP is never modified.

### Important properties

The reconciler implementation below:

```text
- supports FORT CSV and JSON VRP output
- treats absent ASN as disabled
- treats enabled:false as disabled
- rejects duplicate ASN entries in customers.yaml
- excludes AS0
- ignores IPv6 in this first version
- preserves overlapping and multi-origin authorizations
- deduplicates identical prefix/ASN assertions
- validates inputs before changing the output file
- produces deterministic output
- writes atomically with os.replace()
- uses a lock so timer/path triggers cannot run concurrently
- supports --dry-run
- never destroys the last generated SLURM if input is malformed
```

### Algorithm

```text
read customers.yaml
        |
        v
build enabled ASN set
        |
        v
read current FORT-PUBLIC VRPs
        |
        v
for each IPv4 VRP:
    if ASN enabled and ASN != 0:
        desired += prefix + ASN + maxPrefixLength 32
        |
        v
deduplicate and sort
        |
        v
build complete SLURM JSON
        |
        v
validate generated structure
        |
        v
compare with existing output
        |
        +--> unchanged -> exit 0
        |
        +--> changed -> atomic replace
```

### Implementation: `/usr/local/sbin/rtbh-slurm-reconcile`

Create the file with the following complete implementation:

```python
#!/usr/bin/env python3
"""Build a deterministic RTBH SLURM file from FORT-PUBLIC VRPs and customer entitlement."""

from __future__ import annotations

import argparse
import csv
import fcntl
import ipaddress
import json
import logging
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

import yaml

DEFAULT_CUSTOMERS = Path("/etc/rtbh/customers.yaml")
DEFAULT_VRPS = Path("/var/lib/fort/output/validated-roas.csv")
DEFAULT_OUTPUT = Path("/etc/fort-rtbh/slurm/generated-rtbh.slurm")
DEFAULT_LOCK = Path("/run/rtbh-slurm-reconcile.lock")

LOG = logging.getLogger("rtbh-slurm-reconcile")


class ReconcileError(RuntimeError):
    pass


def parse_asn(value: Any) -> int:
    if isinstance(value, bool):
        raise ReconcileError(f"Invalid ASN value: {value!r}")
    if isinstance(value, int):
        asn = value
    elif isinstance(value, str):
        raw = value.strip().upper()
        if raw.startswith("AS"):
            raw = raw[2:]
        if not raw.isdigit():
            raise ReconcileError(f"Invalid ASN value: {value!r}")
        asn = int(raw)
    else:
        raise ReconcileError(f"Invalid ASN value: {value!r}")

    if asn < 0 or asn > 4294967295:
        raise ReconcileError(f"ASN out of range: {asn}")
    return asn


def load_enabled_customers(path: Path) -> set[int]:
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ReconcileError(f"Customer database not found: {path}") from exc
    except yaml.YAMLError as exc:
        raise ReconcileError(f"Invalid YAML in {path}: {exc}") from exc

    if raw is None:
        raw = {"customers": []}
    if not isinstance(raw, dict) or not isinstance(raw.get("customers"), list):
        raise ReconcileError("customers.yaml must contain a top-level 'customers' list")

    seen: set[int] = set()
    enabled: set[int] = set()

    for index, item in enumerate(raw["customers"], start=1):
        if not isinstance(item, dict):
            raise ReconcileError(f"Customer entry #{index} must be a mapping")
        if "asn" not in item:
            raise ReconcileError(f"Customer entry #{index} is missing 'asn'")

        asn = parse_asn(item["asn"])
        if asn == 0:
            raise ReconcileError("AS0 cannot be enrolled for RTBH")
        if asn in seen:
            raise ReconcileError(f"Duplicate customer ASN in customers.yaml: AS{asn}")
        seen.add(asn)

        enabled_value = item.get("enabled", False)
        if not isinstance(enabled_value, bool):
            raise ReconcileError(f"AS{asn}: 'enabled' must be true or false")
        if enabled_value:
            enabled.add(asn)

    return enabled


def _validate_vrp(prefix_text: str, asn_value: Any, max_length_value: Any, label: str) -> tuple[ipaddress._BaseNetwork, int, int]:
    try:
        prefix = ipaddress.ip_network(str(prefix_text).strip(), strict=True)
        asn = parse_asn(asn_value)
        max_length = int(str(max_length_value).strip())
    except ValueError as exc:
        raise ReconcileError(f"Invalid {label}: {exc}") from exc

    if max_length < prefix.prefixlen or max_length > prefix.max_prefixlen:
        raise ReconcileError(
            f"Invalid maxLength in {label}: {prefix} maxLength {max_length}"
        )
    return prefix, asn, max_length


def _load_public_vrps_json(text: str) -> list[tuple[ipaddress._BaseNetwork, int, int]]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ReconcileError(f"Invalid FORT JSON: {exc}") from exc

    roas = data.get("roas") if isinstance(data, dict) else None
    if not isinstance(roas, list):
        raise ReconcileError("FORT JSON must contain a top-level 'roas' array")

    result: list[tuple[ipaddress._BaseNetwork, int, int]] = []
    for index, roa in enumerate(roas, start=1):
        if not isinstance(roa, dict):
            raise ReconcileError(f"ROA entry #{index} must be an object")
        try:
            result.append(
                _validate_vrp(
                    roa["prefix"], roa["asn"], roa["maxLength"], f"ROA entry #{index}"
                )
            )
        except KeyError as exc:
            raise ReconcileError(f"ROA entry #{index} is missing {exc.args[0]!r}") from exc
    return result


def _load_public_vrps_csv(text: str) -> list[tuple[ipaddress._BaseNetwork, int, int]]:
    rows = [row for row in csv.reader(text.splitlines()) if row and any(field.strip() for field in row)]
    if not rows:
        return []

    first = [field.strip().lower() for field in rows[0]]
    has_header = any("asn" in field for field in first) and any("prefix" in field for field in first)
    data_rows = rows[1:] if has_header else rows

    result: list[tuple[ipaddress._BaseNetwork, int, int]] = []
    for index, row in enumerate(data_rows, start=2 if has_header else 1):
        if len(row) < 3:
            raise ReconcileError(f"FORT CSV row #{index} has fewer than three fields")
        # FORT's documented CSV order is ASN, Prefix, Max prefix length.
        result.append(_validate_vrp(row[1], row[0], row[2], f"CSV row #{index}"))
    return result


def load_public_vrps(path: Path) -> list[tuple[ipaddress._BaseNetwork, int, int]]:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise ReconcileError(f"FORT-PUBLIC VRP file not found: {path}") from exc

    stripped = text.lstrip()
    if stripped.startswith("{"):
        return _load_public_vrps_json(text)
    return _load_public_vrps_csv(text)


def derive_assertions(
    vrps: list[tuple[ipaddress._BaseNetwork, int, int]], enabled_asns: set[int]
) -> list[dict[str, Any]]:
    unique: set[tuple[int, int, int, int]] = set()

    for prefix, asn, _public_max_length in vrps:
        if prefix.version != 4:
            continue
        if asn == 0 or asn not in enabled_asns:
            continue
        unique.add((int(prefix.network_address), prefix.prefixlen, asn, 32))

    assertions: list[dict[str, Any]] = []
    for address, prefix_length, asn, max_length in sorted(unique):
        prefix = ipaddress.ip_network((address, prefix_length))
        assertions.append(
            {
                "prefix": str(prefix),
                "asn": asn,
                "maxPrefixLength": max_length,
                "comment": "Generated RTBH authorization",
            }
        )
    return assertions


def build_slurm(assertions: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "slurmVersion": 1,
        "validationOutputFilters": {
            "prefixFilters": [],
            "bgpsecFilters": [],
        },
        "locallyAddedAssertions": {
            "prefixAssertions": assertions,
            "bgpsecAssertions": [],
        },
    }


def validate_generated_slurm(data: dict[str, Any]) -> None:
    if data.get("slurmVersion") != 1:
        raise ReconcileError("Generated SLURM has an invalid version")
    assertions = data.get("locallyAddedAssertions", {}).get("prefixAssertions")
    if not isinstance(assertions, list):
        raise ReconcileError("Generated SLURM prefixAssertions is not a list")

    seen: set[tuple[str, int, int]] = set()
    for item in assertions:
        prefix = ipaddress.ip_network(item["prefix"], strict=True)
        asn = parse_asn(item["asn"])
        max_length = int(item["maxPrefixLength"])
        if prefix.version != 4 or max_length != 32 or asn == 0:
            raise ReconcileError(f"Unsafe generated assertion: {item!r}")
        key = (str(prefix), asn, max_length)
        if key in seen:
            raise ReconcileError(f"Duplicate generated assertion: {key}")
        seen.add(key)


def serialize(data: dict[str, Any]) -> bytes:
    return (json.dumps(data, indent=2, ensure_ascii=True) + "\n").encode("utf-8")


def atomic_write(path: Path, payload: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
        dir_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def existing_payload(path: Path) -> bytes | None:
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--customers", type=Path, default=DEFAULT_CUSTOMERS)
    parser.add_argument("--vrps", type=Path, default=DEFAULT_VRPS)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    args.lock.parent.mkdir(parents=True, exist_ok=True)
    with args.lock.open("w", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)

        enabled = load_enabled_customers(args.customers)
        vrps = load_public_vrps(args.vrps)
        assertions = derive_assertions(vrps, enabled)
        slurm = build_slurm(assertions)
        validate_generated_slurm(slurm)
        payload = serialize(slurm)
        current = existing_payload(args.output)

        LOG.info(
            "enabled_customers=%d public_vrps=%d generated_assertions=%d",
            len(enabled),
            len(vrps),
            len(assertions),
        )

        if current == payload:
            LOG.info("SLURM already matches desired state: %s", args.output)
            return 0

        if args.dry_run:
            LOG.info("Dry-run: SLURM would be replaced: %s", args.output)
            sys.stdout.buffer.write(payload)
            return 0

        atomic_write(args.output, payload)
        LOG.info("Published SLURM atomically: %s", args.output)
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReconcileError as exc:
        logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
        LOG.error("%s", exc)
        raise SystemExit(1)

```

Install it:

```bash
sudo install -m 0755 /path/to/rtbh-slurm-reconcile /usr/local/sbin/rtbh-slurm-reconcile
```

Create the destination directory:

```bash
sudo install -d -m 0755 /etc/fort-rtbh/slurm
```

### Manual dry-run

Run:

```bash
sudo /usr/local/sbin/rtbh-slurm-reconcile --dry-run
```

Expected type of output:

```text
INFO enabled_customers=2 public_vrps=... generated_assertions=...
INFO Dry-run: SLURM would be replaced: /etc/fort-rtbh/slurm/generated-rtbh.slurm
```

The generated JSON is printed to stdout in dry-run mode.

### Initial real reconciliation

```bash
sudo /usr/local/sbin/rtbh-slurm-reconcile
```

Inspect:

```bash
python3 -m json.tool /etc/fort-rtbh/slurm/generated-rtbh.slurm | head -80
```

### Offboarding test

Remove an enabled ASN completely from `customers.yaml` and run:

```bash
sudo /usr/local/sbin/rtbh-slurm-reconcile
```

Confirm its assertions disappear:

```bash
grep -n '65000' /etc/fort-rtbh/slurm/generated-rtbh.slurm
```

Repeat with:

```yaml
enabled: false
```

The result must be identical.

## 14. Block: Reconciler systemd Service

### What it does

The service runs exactly one reconciliation and exits. It is invoked by both the path watcher and the periodic timer.

### Implementation

Create:

```text
/etc/systemd/system/rtbh-slurm-reconcile.service
```

```ini
[Unit]
Description=Reconcile RPKI-aware RTBH SLURM authorization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/local/sbin/rtbh-slurm-reconcile
```

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Test manually:

```bash
sudo systemctl start rtbh-slurm-reconcile.service
sudo systemctl status rtbh-slurm-reconcile.service
sudo journalctl -u rtbh-slurm-reconcile.service -n 50 --no-pager
```

## 15. Block: Event-Driven Reconciliation

### What it does

The path unit provides responsiveness. A change in either authorization input triggers reconciliation:

```text
validated-roas.csv changes
OR
customers.yaml changes
        |
        v
rtbh-slurm-reconcile.service
```

### Implementation

Create:

```text
/etc/systemd/system/rtbh-slurm-reconcile.path
```

```ini
[Unit]
Description=Watch RTBH authorization inputs

[Path]
PathChanged=/var/lib/fort/output/validated-roas.csv
PathChanged=/etc/rtbh/customers.yaml
Unit=rtbh-slurm-reconcile.service

[Install]
WantedBy=multi-user.target
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rtbh-slurm-reconcile.path
```

Verify:

```bash
systemctl status rtbh-slurm-reconcile.path
```

The reconciler validates the complete input before replacing SLURM. If it ever catches the VRP file during a partial write, it exits non-zero and leaves the previous SLURM untouched; the periodic timer below provides recovery.

## 16. Block: Periodic Safety Timer

### What it does

The timer is not the primary change-detection mechanism. It is the correctness/recovery mechanism.

```text
systemd.path  -> responsiveness
systemd.timer -> consistency and recovery
```

### Implementation

Create:

```text
/etc/systemd/system/rtbh-slurm-reconcile.timer
```

```ini
[Unit]
Description=Periodic RTBH SLURM consistency reconciliation

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
```

Meaning:

```text
OnBootSec=5min
    Schedule the first normal timer run five minutes after boot.

OnUnitActiveSec=10min
    Schedule another reconciliation roughly ten minutes after the
    associated unit was last activated.

RandomizedDelaySec=60
    Add up to 60 seconds of jitter so redundant nodes do not always
    reconcile at the same instant.

Persistent=true
    If a scheduled execution was missed while the host was down,
    systemd performs a catch-up execution after the timer becomes active.
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rtbh-slurm-reconcile.timer
```

Inspect:

```bash
systemctl list-timers rtbh-slurm-reconcile.timer
```

---

# Part IV — RTBH-Specific RPKI View

## 17. Block: FORT-RTBH

### What it does

`FORT-RTBH` validates normal global RPKI plus the locally generated SLURM assertions.

This produces a separate RTR view where eligible `/32` routes can be RPKI Valid without changing public ROAs.

```text
Global RPKI
    +
generated-rtbh.slurm
        |
        v
FORT-RTBH
        |
        v
RTR -> FRR-RTBH only
```

### Implementation

Create or reuse a dedicated FORT service account. If the existing FORT installation already uses a service account named `fort`, reuse it. Otherwise create it once:

```bash
sudo useradd --system --home-dir /var/lib/fort --shell /usr/sbin/nologin fort
```

If the user already exists, `useradd` will report that fact; do not recreate it.

Create directories:

```bash
sudo install -d -m 0755 /etc/fort-rtbh/slurm
sudo install -d -o fort -g fort -m 0755 /var/lib/fort-rtbh/repository
sudo install -d -o fort -g fort -m 0755 /var/lib/fort-rtbh/output
```

The same TAL directory may be reused read-only:

```text
/etc/fort/tal
```

Create:

```text
/etc/fort-rtbh/config.json
```

Example for RTBH node 1:

```json
{
  "mode": "server",
  "tal": "/etc/fort/tal",
  "local-repository": "/var/lib/fort-rtbh/repository",
  "slurm": "/etc/fort-rtbh/slurm",
  "output": {
    "roa": "/var/lib/fort-rtbh/output/validated-roas.csv",
    "format": "csv"
  },
  "server": {
    "address": [
      "127.0.0.1",
      "10.0.1.16"
    ],
    "port": "323",
    "max-rtr-version": 1,
    "interval": {
      "validation": 3600,
      "refresh": 3600,
      "retry": 600,
      "expire": 7200
    }
  },
  "log": {
    "output": "console",
    "level": "info"
  }
}
```

Create:

```text
/etc/systemd/system/fort-rtbh.service
```

```ini
[Unit]
Description=FORT RTBH RPKI Validator
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=fort
Group=fort
ExecStart=/usr/local/bin/fort --configuration-file=/etc/fort-rtbh/config.json
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

Ensure the service account can read the TALs, configuration, and generated SLURM file:

```bash
sudo chown root:fort /etc/fort-rtbh/config.json
sudo chmod 0640 /etc/fort-rtbh/config.json
sudo chmod 0755 /etc/fort /etc/fort/tal /etc/fort-rtbh /etc/fort-rtbh/slurm
sudo chmod 0644 /etc/fort-rtbh/slurm/generated-rtbh.slurm
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fort-rtbh.service
```

Verify:

```bash
sudo systemctl status fort-rtbh.service
sudo journalctl -u fort-rtbh.service -n 100 --no-pager
sudo ss -lntp | grep ':323'
```

If FORT-PUBLIC and FORT-RTBH run on the same host, they must bind different IP addresses or different ports. They cannot both bind the same address and TCP port.

### Verify the two RPKI views

Public:

```bash
rtrclient -e -t csv -o public-vrps.csv tcp 10.0.1.15 323
```

RTBH:

```bash
rtrclient -e -t csv -o rtbh-vrps.csv tcp 10.0.1.16 323
```

For an enabled AS65000 with public:

```text
10.0.0.0/24 AS65000 maxLength 24
```

the RTBH view should also contain effective authorization up to `/32`.

### Redundant deployment

For production, deploy the same generated entitlement state to both RTBH validation stacks:

```text
FORT-RTBH-1
FORT-RTBH-2
```

There are two valid operational models:

```text
A. Run an identical reconciler on each RTBH stack using the same
   customers.yaml and an equivalent local FORT-PUBLIC VRP feed.

B. Generate the SLURM centrally and distribute the generated file
   atomically to both RTBH stacks using the operator's configuration
   distribution system.
```

The routing architecture does not depend on which file-distribution model is chosen. What matters is that both RTBH validators consume the same declarative entitlement policy.

---

# Part V — Generic Edge Configuration

## 18. Block: Customer RTBH Ingress

### What it does

Every edge uses the same RTBH policy. No RTBH route-map or AS-path list contains a customer ASN.

A customer request is accepted as RTBH only when:

```text
- it arrives from an eBGP customer session
- it carries 65010:666
- it is exactly /32
- its AS_PATH contains exactly one ASN
- FRR first-AS enforcement confirms that ASN is the configured peer ASN
```

Normal customer traffic continues through the normal ROV policy.

### Generic objects — identical on every edge

```frr
ip prefix-list RTBH-IPV4-HOST seq 10 permit 0.0.0.0/0 ge 32 le 32

bgp community-list standard CUSTOMER-RTBH permit 65010:666

bgp large-community-list standard RTBH-REQUEST permit 65010:9000:0
bgp large-community-list standard RTBH-VALIDATED-REQUEST permit 65010:9010:0
bgp large-community-list standard RTBH-APPROVED permit 65010:9001:0

bgp as-path access-list RTBH-DIRECT-ORIGIN permit ^[0-9]+$
```

The AS-path expression uses FRR's POSIX-based BGP regular expression syntax and matches one decimal ASN with no spaces or additional path segments.

### Generic customer ingress route-map

```frr
route-map CUSTOMER-IN deny 5
 description Reject forged internal RTBH-REQUEST
 match large-community RTBH-REQUEST

route-map CUSTOMER-IN deny 6
 description Reject forged local RTBH-VALIDATED-REQUEST
 match large-community RTBH-VALIDATED-REQUEST

route-map CUSTOMER-IN deny 7
 description Reject forged internal RTBH-APPROVED
 match large-community RTBH-APPROVED

route-map CUSTOMER-IN permit 10
 description Translate valid direct-customer RTBH request
 match community CUSTOMER-RTBH
 match ip address prefix-list RTBH-IPV4-HOST
 match as-path RTBH-DIRECT-ORIGIN
 set comm-list delete CUSTOMER-RTBH
 set large-community 65010:9000:0 additive
 set local-preference 5

route-map CUSTOMER-IN deny 20
 description Reject malformed RTBH signaling
 match community CUSTOMER-RTBH

route-map CUSTOMER-IN permit 100
 description Accept normal RPKI-valid customer route
 match rpki valid

route-map CUSTOMER-IN permit 110
 description Apply operator policy to normal RPKI-notfound route
 match rpki notfound

route-map CUSTOMER-IN deny 120
 description Reject normal RPKI-invalid customer route
 match rpki invalid

route-map CUSTOMER-IN deny 999
```

Sequence 20 is important: a route that carries the customer RTBH signal but fails `/32` or direct-origin validation must not fall through into normal routing policy.

### Why `set comm-list delete CUSTOMER-RTBH`

After successful translation, the customer-facing trigger is no longer needed internally. This command removes only the standard communities matched by `CUSTOMER-RTBH`, leaving unrelated standard communities intact.

### Generic customer peer-group

```frr
router bgp 65010
 bgp enforce-first-as

 neighbor CUSTOMER-PEERS peer-group

 address-family ipv4 unicast
  neighbor CUSTOMER-PEERS route-map CUSTOMER-IN in
  neighbor CUSTOMER-PEERS soft-reconfiguration inbound
  neighbor CUSTOMER-PEERS send-community all
 exit-address-family
```

FRR enables first-AS enforcement by default for eBGP, but this guide configures it explicitly because it is part of the RTBH security model.

### Per-customer configuration that remains

Only normal BGP adjacency identity is customer-specific:

```frr
router bgp 65010
 neighbor 203.0.113.2 remote-as 65000
 neighbor 203.0.113.2 peer-group CUSTOMER-PEERS
 neighbor 203.0.113.2 description CUSTOMER
```

Another customer:

```frr
router bgp 65010
 neighbor 198.51.100.2 remote-as 65020
 neighbor 198.51.100.2 peer-group CUSTOMER-PEERS
 neighbor 198.51.100.2 description CUSTOMER
```

This is session identity, not RTBH policy.

### RPKI cache for normal edge ROV

The edge uses **FORT-PUBLIC**, not FORT-RTBH:

```frr
rpki
 rpki cache tcp 10.0.1.15 323 preference 1
 exit
```

FRR RPKI support must be installed/enabled according to the distribution packaging. FRR's current documentation identifies the `frr-rpki-rtrlib` package and the RPKI module option.

Example package installation:

```bash
sudo apt install frr-rpki-rtrlib
```

Ensure `/etc/frr/daemons` loads the RPKI module for bgpd, for example:

```text
bgpd_options="   -A 127.0.0.1 -M rpki"
```

Then:

```bash
sudo systemctl restart frr
```

Verify:

```bash
sudo vtysh -c 'show rpki cache-connection'
sudo vtysh -c 'show rpki prefix 10.0.0.0/24 65000'
```

## 19. Block: Keep REQUEST Out of Forwarding

### What it does

The unapproved request must remain in BGP so the RR infrastructure can carry it to the validators, but it must not reach Zebra/FIB.

FRR `table-map` is used at the BGP-to-Zebra boundary.

### Implementation

Create a local discard next-hop on every edge:

```frr
ip route 192.0.2.1/32 Null0
```

Then configure:

```frr
route-map BGP-TO-ZEBRA permit 5
 description Install approved RTBH /32 through local discard next-hop
 match ip address prefix-list RTBH-IPV4-HOST
 match large-community RTBH-APPROVED
 set ip next-hop 192.0.2.1

route-map BGP-TO-ZEBRA deny 10
 description Never install unapproved RTBH requests
 match large-community RTBH-REQUEST

route-map BGP-TO-ZEBRA permit 100
 description Permit all other selected BGP routes
```

Apply:

```frr
router bgp 65010
 address-family ipv4 unicast
  table-map BGP-TO-ZEBRA
 exit-address-family
```

Before approval the expected state is:

```text
BGP RIB:    present
advertised: yes
Zebra/FIB:  absent
```

After approval:

```text
BGP best path: approved route
Zebra next-hop: local discard address
kernel result: discard via Null0
```

### Why the edge sets the next-hop

The central RTBH plane distributes **intent**:

```text
65010:9001:0 = blackhole this /32
```

The edge chooses the local forwarding implementation. This avoids dependence on RR next-hop rewriting, IGP reachability, or vendor-specific forwarding behavior.

---

# Part VI — Route Reflector RTBH Feed

## 20. Block: RR-to-RTBH Request Feed

### What it does

The RRs have two RTBH-specific responsibilities only:

```text
1. Send all REQUEST paths to the two RTBH nodes, even if a REQUEST
   is no longer the global best path.

2. Accept only APPROVED /32 routes back from the RTBH nodes and give
   those routes a high LOCAL_PREF.
```

Normal RR behavior for the rest of the network remains unchanged.

### Important FRR behavior

FRR requires:

```frr
bgp route-reflector allow-outbound-policy
```

for an outbound route-map to apply to reflected routes. This command affects reflected routes globally, so it must be reviewed against existing RR outbound policy before production deployment. The RTBH route-map itself is attached only to the RTBH peer-group.

### Implementation: common objects

```frr
ip prefix-list RTBH-IPV4-HOST seq 10 permit 0.0.0.0/0 ge 32 le 32

bgp large-community-list standard RTBH-REQUEST permit 65010:9000:0
bgp large-community-list standard RTBH-APPROVED permit 65010:9001:0
```

### RR -> RTBH route-map

```frr
route-map RR-TO-RTBH permit 10
 description Send only RTBH request host routes to RTBH validators
 match ip address prefix-list RTBH-IPV4-HOST
 match large-community RTBH-REQUEST

route-map RR-TO-RTBH deny 100
```

### RTBH -> RR route-map

```frr
route-map RTBH-TO-RR permit 10
 description Accept only centrally approved RTBH host routes
 match ip address prefix-list RTBH-IPV4-HOST
 match large-community RTBH-APPROVED
 set local-preference 500

route-map RTBH-TO-RR deny 100
```

### RTBH node peer-group on each RR

```frr
router bgp 65010
 bgp route-reflector allow-outbound-policy

 neighbor RTBH-NODES peer-group
 neighbor RTBH-NODES remote-as internal

 neighbor <RTBH1_IP> peer-group RTBH-NODES
 neighbor <RTBH2_IP> peer-group RTBH-NODES

 address-family ipv4 unicast
  neighbor RTBH-NODES activate
  neighbor RTBH-NODES route-reflector-client
  neighbor RTBH-NODES send-community all
  neighbor RTBH-NODES addpath-tx-all-paths
  neighbor RTBH-NODES route-map RR-TO-RTBH out
  neighbor RTBH-NODES route-map RTBH-TO-RR in
 exit-address-family
```

### Verification

Check capability/session state:

```bash
sudo vtysh -c 'show bgp ipv4 unicast summary'
sudo vtysh -c 'show bgp neighbor <RTBH1_IP>'
```

After a REQUEST exists:

```bash
sudo vtysh -c 'show bgp neighbor <RTBH1_IP> advertised-routes'
```

Mandatory PoC acceptance criterion:

```text
REQUEST remains advertised to FRR-RTBH even after APPROVED becomes
best path, and APPROVED is not sent on the RR-TO-RTBH request feed.
```

---

# Part VII — FRR-RTBH Validation Nodes

## 21. Block: FRR-RTBH BGP/RPKI Policy

### What it does

The dedicated FRR-RTBH node receives only REQUEST paths from the RRs, validates them against FORT-RTBH, and marks locally accepted requests with:

```text
65010:9010:0
```

The controller then queries this marker instead of duplicating RPKI logic.

### Why a local validated marker is useful

Without it, the controller would need to infer RPKI state from FRR's complete BGP JSON structure. With it, FRR performs the policy decision and the controller only consumes the already-filtered result.

```text
REQUEST
  + exact /32
  + single-AS path
  + match rpki valid
        |
        v
add 65010:9010:0
        |
        v
controller query target
```

### Install/enable FRR RPKI support

Example:

```bash
sudo apt install frr-rpki-rtrlib
```

Ensure `/etc/frr/daemons` contains the RPKI module in `bgpd_options`, for example:

```text
bgpd_options="   -A 127.0.0.1 -M rpki"
```

Restart:

```bash
sudo systemctl restart frr
```

### Configure the RTBH RPKI cache

Node 1:

```frr
rpki
 rpki cache tcp 10.0.1.16 323 preference 1
 exit
```

Node 2 uses its corresponding RTBH validator, for example:

```frr
rpki
 rpki cache tcp 10.0.1.17 323 preference 1
 exit
```

### Generic objects

```frr
ip prefix-list RTBH-IPV4-HOST seq 10 permit 0.0.0.0/0 ge 32 le 32

bgp large-community-list standard RTBH-REQUEST permit 65010:9000:0
bgp large-community-list standard RTBH-VALIDATED-REQUEST permit 65010:9010:0
bgp large-community-list standard RTBH-APPROVED permit 65010:9001:0

bgp as-path access-list RTBH-DIRECT-ORIGIN permit ^[0-9]+$
```

### Inbound validation route-map

```frr
route-map FROM-RR-REQUESTS permit 10
 description Accept and locally mark valid RTBH requests
 match ip address prefix-list RTBH-IPV4-HOST
 match large-community RTBH-REQUEST
 match as-path RTBH-DIRECT-ORIGIN
 match rpki valid
 set large-community 65010:9010:0 additive

route-map FROM-RR-REQUESTS deny 100
```

The `RTBH-VALIDATED-REQUEST` marker remains local to the RTBH node.

### Outbound approval route-map

The controller creates plain local BGP `network /32` statements. The fixed outbound route-map marks those locally originated host routes as approved:

```frr
route-map TO-RR-APPROVED permit 10
 description Mark locally originated RTBH host routes as approved
 match ip address prefix-list RTBH-IPV4-HOST
 set large-community 65010:9001:0 additive

route-map TO-RR-APPROVED deny 100
```

This guide deliberately does **not** require `network ... route-map` and does not use redistribution.

The dedicated-node invariant is:

```text
All locally configured IPv4 BGP network /32 statements on an
FRR-RTBH node are controller-managed RTBH approvals.
```

Do not use the same BGP instance for unrelated locally originated `/32` network statements.

### BGP skeleton

```frr
router bgp 65010
 bgp router-id 10.255.10.11
 bgp no-rib
 no bgp network import-check

 neighbor RR-PEERS peer-group
 neighbor RR-PEERS remote-as internal

 neighbor <RR1_IP> peer-group RR-PEERS
 neighbor <RR2_IP> peer-group RR-PEERS

 address-family ipv4 unicast
  neighbor RR-PEERS activate
  neighbor RR-PEERS send-community all
  neighbor RR-PEERS soft-reconfiguration inbound
  neighbor RR-PEERS route-map FROM-RR-REQUESTS in
  neighbor RR-PEERS route-map TO-RR-APPROVED out
 exit-address-family
```

`bgp no-rib` keeps this dedicated control-plane node from installing BGP routes into Zebra/kernel forwarding.

`no bgp network import-check` allows controller-created `network /32` statements to originate BGP routes without requiring a static route in the local RIB.

### Why soft reconfiguration is required here

FRR documents that updates from an RPKI cache are directly applied and path selection is updated accordingly, with inbound soft reconfiguration required for that behavior. Therefore:

```frr
neighbor RR-PEERS soft-reconfiguration inbound
```

is part of the design, not an optional convenience.

### Verify RPKI state

```bash
sudo vtysh -c 'show rpki cache-connection'
sudo vtysh -c 'show rpki prefix 10.0.0.5/32 65000'
```

### Verify validated request marker

After a valid request is received:

```bash
sudo vtysh -c 'show bgp ipv4 large-community 65010:9010:0'
```

JSON form used by the controller:

```bash
sudo vtysh -c 'show bgp ipv4 large-community 65010:9010:0 json'
```

---

# Part VIII — Local RTBH Controller

## 22. Block: RTBH Controller

### What it does

The controller is a small local reconciler that runs only on `FRR-RTBH-1` and `FRR-RTBH-2`.

It does not:

```text
- SSH to edge routers
- write RR configuration
- implement ROA lookup
- implement RPKI validation
- maintain customer prefix-lists
- redistribute static routes
```

It does:

```text
1. Read customers.yaml.
2. Confirm FRR has a positively connected RPKI cache.
3. Query routes carrying the local RTBH-VALIDATED-REQUEST marker.
4. Extract exact /32 and origin ASN from each AS_PATH.
5. Keep only enabled ASNs.
6. Compute desired approved /32 prefixes.
7. Compare desired prefixes with local BGP network /32 statements.
8. Add missing network statements.
9. Remove stale network statements.
```

### Why the controller checks RPKI cache connectivity

FRR documents that if it cannot establish an RPKI cache connection after its timeout, it may continue processing BGP routes without prefix-origin validation. The controller therefore requires a positively connected cache before treating its local request view as authoritative.

The supplied implementation is conservative: if it cannot confirm cache connectivity or cannot read its inputs for longer than the configured stale timeout, it withdraws all controller-managed approvals.

### State model

```text
desired = validated REQUEST prefixes that have at least one enabled origin ASN
actual  = local BGP network /32 statements on this dedicated RTBH node

to_add    = desired - actual
to_remove = actual - desired
```

For overlapping/anycast authorization:

```text
10.0.0.5/32 -> {65000, 65020}
```

If either enabled and valid origin remains active, the single approved `/32` remains originated. It is withdrawn only when the eligible origin set becomes empty.

### Implementation: `/usr/local/sbin/rtbh-controller`

Create the following complete program:

```python
#!/usr/bin/env python3
"""Materialize validated RTBH requests as ephemeral local BGP /32 networks."""

from __future__ import annotations

import argparse
import fcntl
import ipaddress
import json
import logging
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Iterable

import yaml

DEFAULT_CUSTOMERS = Path("/etc/rtbh/customers.yaml")
DEFAULT_LOCK = Path("/run/rtbh-controller.lock")
DEFAULT_LOCAL_AS = 65010
DEFAULT_VALIDATED_COMMUNITY = "65010:9010:0"
DEFAULT_INTERVAL = 3.0
DEFAULT_STALE_TIMEOUT = 30.0

LOG = logging.getLogger("rtbh-controller")
STOP = False
ASN_RE = re.compile(r"^[0-9]+$")
NETWORK_LINE_RE = re.compile(r"^\s*network\s+([0-9.]+/32)(?:\s|$)")


class ControllerError(RuntimeError):
    pass


def run_vtysh(commands: Iterable[str], timeout: float = 10.0) -> str:
    argv = ["vtysh"]
    for command in commands:
        argv.extend(["-c", command])
    try:
        completed = subprocess.run(
            argv,
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as exc:
        stderr = getattr(exc, "stderr", "") or ""
        raise ControllerError(f"vtysh failed: {stderr.strip() or exc}") from exc
    return completed.stdout


def load_enabled_customers(path: Path) -> set[int]:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ControllerError(f"Customer database not found: {path}") from exc
    except yaml.YAMLError as exc:
        raise ControllerError(f"Invalid YAML in {path}: {exc}") from exc

    if data is None:
        data = {"customers": []}
    if not isinstance(data, dict) or not isinstance(data.get("customers"), list):
        raise ControllerError("customers.yaml must contain a top-level 'customers' list")

    enabled: set[int] = set()
    seen: set[int] = set()
    for index, item in enumerate(data["customers"], start=1):
        if not isinstance(item, dict) or "asn" not in item:
            raise ControllerError(f"Invalid customer entry #{index}")
        try:
            asn = int(item["asn"])
        except (TypeError, ValueError) as exc:
            raise ControllerError(f"Invalid ASN in customer entry #{index}") from exc
        if asn <= 0 or asn > 4294967295:
            raise ControllerError(f"ASN out of range in customer entry #{index}: {asn}")
        if asn in seen:
            raise ControllerError(f"Duplicate customer ASN: AS{asn}")
        seen.add(asn)
        enabled_value = item.get("enabled", False)
        if not isinstance(enabled_value, bool):
            raise ControllerError(f"AS{asn}: 'enabled' must be true or false")
        if enabled_value:
            enabled.add(asn)
    return enabled


def recursively_has_connected_state(value: Any) -> bool:
    if isinstance(value, dict):
        for key, item in value.items():
            normalized_key = str(key).lower().replace("_", "-")
            if normalized_key in {"connected", "is-connected"} and item is True:
                return True
            if normalized_key in {"state", "status", "connection-state"}:
                if isinstance(item, str) and item.lower() in {"connected", "up", "established"}:
                    return True
            if recursively_has_connected_state(item):
                return True
    elif isinstance(value, list):
        return any(recursively_has_connected_state(item) for item in value)
    return False


def require_rpki_cache_connected() -> None:
    raw = run_vtysh(["show rpki cache-connection json"])
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ControllerError("FRR returned invalid JSON for RPKI cache state") from exc
    if not recursively_has_connected_state(data):
        raise ControllerError("No positively connected RPKI cache found in FRR state")


def extract_as_path(path: dict[str, Any]) -> str | None:
    direct = path.get("path")
    if isinstance(direct, str):
        return direct.strip()

    for key in ("aspath", "asPath", "as-path"):
        value = path.get(key)
        if isinstance(value, str):
            return value.strip()
        if isinstance(value, dict):
            for subkey in ("string", "str", "path"):
                subvalue = value.get(subkey)
                if isinstance(subvalue, str):
                    return subvalue.strip()
    return None


def extract_routes_object(data: Any) -> dict[str, Any]:
    if isinstance(data, dict) and isinstance(data.get("routes"), dict):
        return data["routes"]
    if isinstance(data, dict):
        candidates = {
            key: value
            for key, value in data.items()
            if isinstance(key, str) and "/" in key and isinstance(value, (list, dict))
        }
        if candidates:
            return candidates
    raise ControllerError("Unrecognized FRR BGP JSON schema: no routes object found")


def normalize_paths(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if isinstance(value, dict):
        if isinstance(value.get("paths"), list):
            return [item for item in value["paths"] if isinstance(item, dict)]
        return [value]
    return []


def read_validated_requests(validated_community: str) -> dict[ipaddress.IPv4Network, set[int]]:
    raw = run_vtysh([
        f"show bgp ipv4 large-community {validated_community} json"
    ])
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ControllerError("FRR returned invalid JSON for validated RTBH requests") from exc

    routes = extract_routes_object(data)
    requests: dict[ipaddress.IPv4Network, set[int]] = {}

    for prefix_text, route_value in routes.items():
        try:
            prefix = ipaddress.ip_network(prefix_text, strict=True)
        except ValueError:
            continue
        if not isinstance(prefix, ipaddress.IPv4Network) or prefix.prefixlen != 32:
            continue

        for path in normalize_paths(route_value):
            as_path = extract_as_path(path)
            if as_path is None or not ASN_RE.fullmatch(as_path):
                continue
            asn = int(as_path)
            if asn <= 0 or asn > 4294967295:
                continue
            requests.setdefault(prefix, set()).add(asn)

    return requests


def read_local_networks(local_as: int) -> set[ipaddress.IPv4Network]:
    config = run_vtysh(["show running-config"])
    in_bgp = False
    in_ipv4 = False
    networks: set[ipaddress.IPv4Network] = set()

    for raw_line in config.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()

        if stripped.startswith("router bgp "):
            fields = stripped.split()
            in_bgp = len(fields) >= 3 and fields[2] == str(local_as)
            in_ipv4 = False
            continue

        if in_bgp and stripped.startswith("router "):
            in_bgp = False
            in_ipv4 = False
            continue

        if in_bgp and stripped == "address-family ipv4 unicast":
            in_ipv4 = True
            continue

        if in_bgp and in_ipv4 and stripped == "exit-address-family":
            in_ipv4 = False
            continue

        if in_bgp and in_ipv4:
            match = NETWORK_LINE_RE.match(line)
            if match:
                networks.add(ipaddress.ip_network(match.group(1), strict=True))

    return networks


def apply_network_changes(
    local_as: int,
    to_add: set[ipaddress.IPv4Network],
    to_remove: set[ipaddress.IPv4Network],
    dry_run: bool,
) -> None:
    if not to_add and not to_remove:
        return

    LOG.info(
        "network changes: add=%s remove=%s",
        ",".join(map(str, sorted(to_add))) or "-",
        ",".join(map(str, sorted(to_remove))) or "-",
    )

    if dry_run:
        return

    commands = [
        "configure terminal",
        f"router bgp {local_as}",
        "address-family ipv4 unicast",
    ]
    commands.extend(f"no network {prefix}" for prefix in sorted(to_remove))
    commands.extend(f"network {prefix}" for prefix in sorted(to_add))
    commands.extend(["exit-address-family", "end"])
    run_vtysh(commands)


def reconcile_once(args: argparse.Namespace) -> None:
    enabled = load_enabled_customers(args.customers)
    require_rpki_cache_connected()
    requests = read_validated_requests(args.validated_community)

    desired: set[ipaddress.IPv4Network] = set()
    for prefix, origins in requests.items():
        eligible = origins & enabled
        if eligible:
            desired.add(prefix)

    actual = read_local_networks(args.local_as)
    to_add = desired - actual
    to_remove = actual - desired

    LOG.info(
        "enabled_customers=%d request_prefixes=%d desired_prefixes=%d active_networks=%d",
        len(enabled),
        len(requests),
        len(desired),
        len(actual),
    )
    apply_network_changes(args.local_as, to_add, to_remove, args.dry_run)


def cleanup(args: argparse.Namespace) -> None:
    actual = read_local_networks(args.local_as)
    apply_network_changes(args.local_as, set(), actual, args.dry_run)


def signal_handler(_signum: int, _frame: Any) -> None:
    global STOP
    STOP = True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--customers", type=Path, default=DEFAULT_CUSTOMERS)
    parser.add_argument("--local-as", type=int, default=DEFAULT_LOCAL_AS)
    parser.add_argument("--validated-community", default=DEFAULT_VALIDATED_COMMUNITY)
    parser.add_argument("--interval", type=float, default=DEFAULT_INTERVAL)
    parser.add_argument("--stale-timeout", type=float, default=DEFAULT_STALE_TIMEOUT)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    if args.local_as <= 0 or args.local_as > 4294967295:
        raise ControllerError("Invalid local AS")
    if args.interval <= 0 or args.stale_timeout < 0:
        raise ControllerError("Invalid interval or stale timeout")

    args.lock.parent.mkdir(parents=True, exist_ok=True)
    with args.lock.open("w", encoding="utf-8") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ControllerError("Another controller instance is already running") from exc

        if args.cleanup:
            cleanup(args)
            return 0

        if args.once:
            reconcile_once(args)
            return 0

        signal.signal(signal.SIGTERM, signal_handler)
        signal.signal(signal.SIGINT, signal_handler)

        last_success = time.monotonic()
        fail_closed_done = False

        while not STOP:
            try:
                reconcile_once(args)
                last_success = time.monotonic()
                fail_closed_done = False
            except Exception as exc:
                LOG.error("Reconciliation failed: %s", exc)
                stale_for = time.monotonic() - last_success
                if stale_for >= args.stale_timeout and not fail_closed_done:
                    LOG.error(
                        "Input state has been unavailable for %.1f seconds; withdrawing all managed RTBH networks",
                        stale_for,
                    )
                    cleanup(args)
                    fail_closed_done = True

            deadline = time.monotonic() + args.interval
            while not STOP and time.monotonic() < deadline:
                time.sleep(min(0.2, max(0.0, deadline - time.monotonic())))

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ControllerError as exc:
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
        LOG.error("%s", exc)
        raise SystemExit(1)

```

Install it:

```bash
sudo install -m 0755 /path/to/rtbh-controller /usr/local/sbin/rtbh-controller
```

### Test FRR JSON before enabling the service

The parser supports common FRR JSON layouts but intentionally fails closed on an unrecognized schema. Capture the actual output from the exact FRR version deployed:

```bash
sudo vtysh -c 'show bgp ipv4 large-community 65010:9010:0 json' | python3 -m json.tool
```

Also inspect:

```bash
sudo vtysh -c 'show rpki cache-connection json' | python3 -m json.tool
```

If the exact keys differ from the conservative parser, adjust only the parsing helper functions before production rollout.

### Dry-run once

```bash
sudo /usr/local/sbin/rtbh-controller --once --dry-run
```

Expected type of log output:

```text
enabled_customers=2 request_prefixes=1 desired_prefixes=1 active_networks=0
network changes: add=10.0.0.5/32 remove=-
```

### One real reconciliation

```bash
sudo /usr/local/sbin/rtbh-controller --once
```

Then verify:

```bash
sudo vtysh -c 'show running-config' | grep '^  network '
sudo vtysh -c 'show bgp ipv4 unicast 10.0.0.5/32'
```

The controller intentionally does **not** execute `write memory`. Dynamic `/32` network statements are ephemeral operational state.

## 23. Block: Controller systemd Service

### What it does

The service keeps the controller running continuously. A graceful stop or crash invokes cleanup so stale approvals are not intentionally left behind.

### Implementation

Create:

```text
/etc/systemd/system/rtbh-controller.service
```

```ini
[Unit]
Description=RPKI-aware RTBH local BGP controller
After=frr.service network-online.target
Requires=frr.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/sbin/rtbh-controller --interval 3 --stale-timeout 30
ExecStopPost=/usr/local/sbin/rtbh-controller --cleanup
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rtbh-controller.service
```

Monitor:

```bash
sudo systemctl status rtbh-controller.service
sudo journalctl -u rtbh-controller.service -f
```

### Fail-closed behavior

Default values in this guide:

```text
reconcile interval = 3 seconds
stale input timeout = 30 seconds
```

If the controller cannot obtain trustworthy input state for 30 seconds, it removes all local `/32` BGP `network` statements managed by the dedicated RTBH instance.

Tune these values after measuring PoC behavior.

---

# Part IX — External Routing Security

## 24. Block: Prevent Internal RTBH Signals from External Use

### What it does

Customers and external peers must never be able to directly assert:

```text
65010:9000:0
65010:9010:0
65010:9001:0
```

The customer ingress route-map rejects REQUEST, VALIDATED-REQUEST, and APPROVED before normal customer policy.

### Implementation

Define:

```frr
bgp large-community-list standard RTBH-REQUEST permit 65010:9000:0
bgp large-community-list standard RTBH-VALIDATED-REQUEST permit 65010:9010:0
bgp large-community-list standard RTBH-APPROVED permit 65010:9001:0
```

Add external ingress guards appropriate to the existing policy framework.

At a minimum, reject all three internal markers before normal external-import policy.

## 25. Block: Prevent RTBH State from Leaking Externally

### What it does

REQUEST and APPROVED are operator-internal control-plane signals. They must not be exported to transit, peers, customers, or IX route servers.

### Shared guard

```frr
route-map BLOCK-INTERNAL-RTBH-OUT deny 10
 match large-community RTBH-REQUEST

route-map BLOCK-INTERNAL-RTBH-OUT deny 20
 match large-community RTBH-VALIDATED-REQUEST

route-map BLOCK-INTERNAL-RTBH-OUT deny 30
 match large-community RTBH-APPROVED

route-map BLOCK-INTERNAL-RTBH-OUT permit 100
```

Integrate this as a guard stage in the existing external export route-maps. FRR route-maps support the `call` action, so an existing export policy can call this guard instead of replacing existing commercial/prefix policy.

Example pattern:

```frr
route-map CUSTOMER-OUT permit 10
 call BLOCK-INTERNAL-RTBH-OUT
 on-match next

route-map CUSTOMER-OUT permit 100
 description Existing customer export policy continues here
```

Adapt the final export policy to the actual network; do not replace existing controls with an unconditional permit.

---

# Part X — Redundancy and State Changes

## 26. Two FRR-RTBH Nodes

Both RTBH nodes receive REQUEST paths through RR Add-Path and independently originate an approval when appropriate.

```text
                  RR-1 / RR-2
                   /       \
                  /         \
         FRR-RTBH-1       FRR-RTBH-2
             |                 |
          APPROVED          APPROVED
             \                 /
              \               /
                 RR-1 / RR-2
                      |
                    edges
```

If one node fails, the other approved BGP path remains.

## 27. Customer Withdraw

```text
customer withdraws /32
        |
        v
REQUEST withdrawn through iBGP/Add-Path
        |
        v
controller removes /32 from desired set
        |
        v
no network /32
        |
        v
APPROVED withdrawal
```

## 28. Customer `enabled:false`

```yaml
- asn: 65000
  enabled: false
```

causes both:

```text
reconciler -> remove AS65000 SLURM assertions
controller -> stop considering AS65000 requests eligible
```

## 29. Customer Removed from `customers.yaml`

Removing the entry completely has exactly the same result as `enabled:false`.

## 30. Public VRP Withdrawal

```text
public VRP removed
        |
        v
reconciler removes corresponding SLURM assertion
        |
        v
FORT-RTBH validation changes
        |
        v
FRR soft-reconfiguration re-evaluates REQUEST
        |
        v
local validated marker disappears
        |
        v
controller withdraws approval
```

## 31. Public Origin ASN Change

Old:

```text
10.0.0.0/24 AS65000
```

New:

```text
10.0.0.0/24 AS65050
```

The reconciler removes the AS65000 assertion. It adds AS65050 only if AS65050 is explicitly enabled.

## 32. Publicly Valid `/32` from a Non-Customer

A route can be RPKI Valid because its public ROA already allows `/32`. That alone does not grant RTBH service.

```text
RPKI Valid
AND
origin ASN absent from customers.yaml
        |
        v
NO RTBH APPROVAL
```

This is why `customers.yaml` is checked by the runtime controller in addition to being used for SLURM generation.

---

# Part XI — Complete Per-Device Configuration Summary

## 33. FRR-MAIN Edge — RTBH-Specific Template

The following RTBH policy is identical on every edge:

```frr
ip route 192.0.2.1/32 Null0

ip prefix-list RTBH-IPV4-HOST seq 10 permit 0.0.0.0/0 ge 32 le 32

bgp community-list standard CUSTOMER-RTBH permit 65010:666

bgp large-community-list standard RTBH-REQUEST permit 65010:9000:0
bgp large-community-list standard RTBH-VALIDATED-REQUEST permit 65010:9010:0
bgp large-community-list standard RTBH-APPROVED permit 65010:9001:0

bgp as-path access-list RTBH-DIRECT-ORIGIN permit ^[0-9]+$

route-map CUSTOMER-IN deny 5
 match large-community RTBH-REQUEST

route-map CUSTOMER-IN deny 6
 match large-community RTBH-VALIDATED-REQUEST

route-map CUSTOMER-IN deny 7
 match large-community RTBH-APPROVED

route-map CUSTOMER-IN permit 10
 match community CUSTOMER-RTBH
 match ip address prefix-list RTBH-IPV4-HOST
 match as-path RTBH-DIRECT-ORIGIN
 set comm-list delete CUSTOMER-RTBH
 set large-community 65010:9000:0 additive
 set local-preference 5

route-map CUSTOMER-IN deny 20
 match community CUSTOMER-RTBH

route-map CUSTOMER-IN permit 100
 match rpki valid

route-map CUSTOMER-IN permit 110
 match rpki notfound

route-map CUSTOMER-IN deny 120
 match rpki invalid

route-map CUSTOMER-IN deny 999

route-map BGP-TO-ZEBRA permit 5
 match ip address prefix-list RTBH-IPV4-HOST
 match large-community RTBH-APPROVED
 set ip next-hop 192.0.2.1

route-map BGP-TO-ZEBRA deny 10
 match large-community RTBH-REQUEST

route-map BGP-TO-ZEBRA permit 100

router bgp 65010
 bgp enforce-first-as
 neighbor CUSTOMER-PEERS peer-group

 address-family ipv4 unicast
  neighbor CUSTOMER-PEERS route-map CUSTOMER-IN in
  neighbor CUSTOMER-PEERS soft-reconfiguration inbound
  neighbor CUSTOMER-PEERS send-community all
  table-map BGP-TO-ZEBRA
 exit-address-family
```

Normal per-customer neighbor definitions remain separate.

## 34. Existing RR — RTBH-Specific Template

```frr
ip prefix-list RTBH-IPV4-HOST seq 10 permit 0.0.0.0/0 ge 32 le 32

bgp large-community-list standard RTBH-REQUEST permit 65010:9000:0
bgp large-community-list standard RTBH-APPROVED permit 65010:9001:0

route-map RR-TO-RTBH permit 10
 match ip address prefix-list RTBH-IPV4-HOST
 match large-community RTBH-REQUEST

route-map RR-TO-RTBH deny 100

route-map RTBH-TO-RR permit 10
 match ip address prefix-list RTBH-IPV4-HOST
 match large-community RTBH-APPROVED
 set local-preference 500

route-map RTBH-TO-RR deny 100

router bgp 65010
 bgp route-reflector allow-outbound-policy

 neighbor RTBH-NODES peer-group
 neighbor RTBH-NODES remote-as internal
 neighbor <RTBH1_IP> peer-group RTBH-NODES
 neighbor <RTBH2_IP> peer-group RTBH-NODES

 address-family ipv4 unicast
  neighbor RTBH-NODES activate
  neighbor RTBH-NODES route-reflector-client
  neighbor RTBH-NODES send-community all
  neighbor RTBH-NODES addpath-tx-all-paths
  neighbor RTBH-NODES route-map RR-TO-RTBH out
  neighbor RTBH-NODES route-map RTBH-TO-RR in
 exit-address-family
```

## 35. FRR-RTBH — RTBH-Specific Template

```frr
ip prefix-list RTBH-IPV4-HOST seq 10 permit 0.0.0.0/0 ge 32 le 32

bgp large-community-list standard RTBH-REQUEST permit 65010:9000:0
bgp large-community-list standard RTBH-VALIDATED-REQUEST permit 65010:9010:0
bgp large-community-list standard RTBH-APPROVED permit 65010:9001:0

bgp as-path access-list RTBH-DIRECT-ORIGIN permit ^[0-9]+$

route-map FROM-RR-REQUESTS permit 10
 match ip address prefix-list RTBH-IPV4-HOST
 match large-community RTBH-REQUEST
 match as-path RTBH-DIRECT-ORIGIN
 match rpki valid
 set large-community 65010:9010:0 additive

route-map FROM-RR-REQUESTS deny 100

route-map TO-RR-APPROVED permit 10
 match ip address prefix-list RTBH-IPV4-HOST
 set large-community 65010:9001:0 additive

route-map TO-RR-APPROVED deny 100

router bgp 65010
 bgp router-id <RTBH_ROUTER_ID>
 bgp no-rib
 no bgp network import-check

 neighbor RR-PEERS peer-group
 neighbor RR-PEERS remote-as internal
 neighbor <RR1_IP> peer-group RR-PEERS
 neighbor <RR2_IP> peer-group RR-PEERS

 address-family ipv4 unicast
  neighbor RR-PEERS activate
  neighbor RR-PEERS send-community all
  neighbor RR-PEERS soft-reconfiguration inbound
  neighbor RR-PEERS route-map FROM-RR-REQUESTS in
  neighbor RR-PEERS route-map TO-RR-APPROVED out
 exit-address-family
```

The controller dynamically adds only:

```frr
network <approved-prefix>/32
```

and dynamically removes it with:

```frr
no network <approved-prefix>/32
```

---

# Part XII — End-to-End Validation

## 36. Test 1: Public Aggregate

Customer advertises:

```text
10.0.0.0/24 AS65000
```

Expected:

```text
FORT-PUBLIC -> Valid
normal routing -> accepted according to normal policy
```

## 37. Test 2: RTBH `/32` Before Approval

Customer sends:

```text
10.0.0.5/32
AS_PATH 65000
community 65010:666
```

On ingress edge:

```bash
sudo vtysh -c 'show bgp ipv4 unicast 10.0.0.5/32 detail'
```

Expected internal marker:

```text
65010:9000:0
```

Forwarding must not contain the request:

```bash
sudo vtysh -c 'show ip route 10.0.0.5/32'
ip route get 10.0.0.5
```

## 38. Test 3: REQUEST Reaches Both Validators

On each FRR-RTBH:

```bash
sudo vtysh -c 'show bgp ipv4 large-community 65010:9000:0'
```

Verify RPKI:

```bash
sudo vtysh -c 'show rpki prefix 10.0.0.5/32 65000'
```

Verify validated marker:

```bash
sudo vtysh -c 'show bgp ipv4 large-community 65010:9010:0'
```

## 39. Test 4: Controller Approval

Watch:

```bash
sudo journalctl -u rtbh-controller.service -f
```

Verify local network:

```bash
sudo vtysh -c 'show running-config' | grep 'network 10.0.0.5/32'
```

Verify local BGP route:

```bash
sudo vtysh -c 'show bgp ipv4 unicast 10.0.0.5/32 detail'
```

## 40. Test 5: Approved Route on Edge

On another edge:

```bash
sudo vtysh -c 'show bgp ipv4 unicast 10.0.0.5/32 detail'
sudo vtysh -c 'show ip route 10.0.0.5/32'
```

Expected:

```text
Large Community 65010:9001:0
next-hop rewritten locally to RTBH discard address
forwarding resolves to Null0
```

## 41. Test 6: Add-Path Persistence

After APPROVED becomes best path, confirm the RR still sends REQUEST to each RTBH node:

```bash
sudo vtysh -c 'show bgp neighbor <RTBH1_IP> advertised-routes'
```

The controller must continue seeing the validated REQUEST. No approval/request oscillation should occur.

## 42. Test 7: Customer Withdraw

Withdraw the customer `/32`.

Expected within controller convergence time:

```text
validated REQUEST disappears
network /32 removed from both RTBH nodes
APPROVED withdrawn
all edges remove blackhole
```

## 43. Test 8: Explicit Offboarding

Set:

```yaml
enabled: false
```

Expected:

```text
SLURM assertions removed
active approvals removed
```

## 44. Test 9: Offboarding by Deletion

Delete the ASN entry completely.

Expected result must be exactly the same as `enabled:false`.

## 45. Test 10: RPKI Revocation

Remove/change the public covering authorization in a controlled laboratory setup.

Expected:

```text
FORT-PUBLIC changes
reconciler updates SLURM
FORT-RTBH state changes
FRR soft-reconfiguration removes validated request eligibility
controller withdraws local network
approved route disappears from edges
```

## 46. Test Matrix

| Test | Expected result |
|---|---|
| Normal public RPKI-valid aggregate | Normal route accepted |
| Normal public RPKI-invalid route | Rejected by normal ROV |
| `/32` RTBH from enabled/direct/authorized customer | Approved |
| `/31` with RTBH community | Rejected at ingress |
| `/32` with prepended AS_PATH | Rejected as RTBH request |
| `/32` with downstream origin AS | Rejected as RTBH request |
| Customer absent from `customers.yaml` | No approval |
| Customer `enabled:false` | No approval / active approval withdrawn |
| Publicly valid `/32` from non-RTBH customer | No RTBH approval |
| Forged RTBH-REQUEST externally | Rejected |
| Forged RTBH-APPROVED externally | Rejected |
| Public VRP disappears | Approval withdrawn |
| Customer withdraws request | Approval withdrawn |
| One RTBH node fails | Other node maintains approval |
| Both RTBH nodes fail | BGP approvals disappear |
| APPROVED becomes best path | REQUEST remains visible through RR Add-Path |

---

# Part XIII — Monitoring and Operations

## 47. FORT Monitoring

```bash
sudo systemctl status fort
sudo systemctl status fort-rtbh.service
sudo journalctl -u fort-rtbh.service --since '1 hour ago'
```

Monitor:

```text
last successful validation time
RTR listener availability
VRP output age
SLURM parse errors
repository synchronization failures
```

## 48. Reconciler Monitoring

```bash
sudo journalctl -u rtbh-slurm-reconcile.service --since '1 hour ago'
systemctl list-timers rtbh-slurm-reconcile.timer
systemctl status rtbh-slurm-reconcile.path
```

Useful file checks:

```bash
stat /var/lib/fort/output/validated-roas.csv
stat /etc/fort-rtbh/slurm/generated-rtbh.slurm
python3 -m json.tool /etc/fort-rtbh/slurm/generated-rtbh.slurm >/dev/null
```

## 49. FRR RPKI Monitoring

```bash
sudo vtysh -c 'show rpki cache-connection'
sudo vtysh -c 'show rpki cache-server'
sudo vtysh -c 'show rpki configuration'
```

## 50. RTBH Controller Monitoring

```bash
sudo systemctl status rtbh-controller.service
sudo journalctl -u rtbh-controller.service --since '1 hour ago'
```

Monitor at least:

```text
enabled customer count
validated request count
desired approval count
active network count
reconciliation failures
fail-closed withdrawals
controller loop latency
```

## 51. BGP Monitoring

Edges:

```bash
sudo vtysh -c 'show bgp ipv4 large-community 65010:9000:0'
sudo vtysh -c 'show bgp ipv4 large-community 65010:9001:0'
```

RTBH nodes:

```bash
sudo vtysh -c 'show bgp ipv4 large-community 65010:9010:0'
```

RRs:

```bash
sudo vtysh -c 'show bgp neighbor <RTBH1_IP>'
sudo vtysh -c 'show bgp neighbor <RTBH2_IP>'
```

---

# Part XIV — Production Safety Rules

## 52. Mandatory Invariants

```text
1. FORT-PUBLIC never loads RTBH SLURM.
2. FRR-MAIN edges use only FORT-PUBLIC for normal ROV.
3. FRR-RTBH nodes use only FORT-RTBH for RTBH validation.
4. customers.yaml is closed-world: absent means disabled.
5. AS0 is never enrolled.
6. Only exact IPv4 /32 routes are active RTBH in v1.
7. Customer identity comes from direct AS_PATH + configured eBGP peer ASN.
8. Internal RTBH communities are rejected on external ingress.
9. Internal RTBH communities are blocked on external egress.
10. REQUEST is kept out of forwarding until APPROVED exists.
11. APPROVED is checked as exact /32 again on every edge.
12. The discard next-hop is local to every edge.
13. FRR-RTBH is a dedicated control-plane BGP instance.
14. All local BGP network /32 statements on FRR-RTBH are controller-managed.
15. Dynamic /32 network statements are never written to persistent FRR config.
16. RR Add-Path is limited to the RTBH validator peer-group.
17. RPKI cache connectivity is positively checked by the controller.
18. Loss of trustworthy controller input eventually fails closed.
```

## 53. Configuration Management

Persist and version-control:

```text
customers.yaml
base FRR policy
FORT configurations
systemd units
reconciler code
controller code
```

Do not persist as desired configuration:

```text
active attack /32 network statements
```

Those are ephemeral operational state reconstructed from BGP requests.

## 54. Change Process for a New RTBH Customer

Routing session configuration remains normal:

```text
neighbor IP
remote-as
session authentication
normal customer policy
```

RTBH enrollment requires only adding:

```yaml
- asn: 65100
  enabled: true
```

No RTBH route-map, RTBH prefix-list, or customer-specific RTBH Large Community is added to any edge.

## 55. Change Process for Offboarding

Either:

```yaml
- asn: 65100
  enabled: false
```

or delete the entire entry.

Both must remove:

```text
derived SLURM authorization
active RTBH approvals relying on that ASN
```

---

# Part XV — Implementation Status and PoC Gates

## 56. Behavior Supported by Current Primary Documentation

The design relies on FRR features documented in the current official manual:

```text
bgp enforce-first-as
AS-path access lists and POSIX BGP regular expressions
set comm-list delete
set large-community ... additive
match rpki valid
soft-reconfiguration inbound
show rpki cache-connection json
show bgp ... large-community ... json
table-map
set ip next-hop
addpath-tx-all-paths
bgp route-reflector allow-outbound-policy
network A.B.C.D/M
bgp network import-check / no bgp network import-check
bgp no-rib
peer-groups
```

FORT current documentation supports:

```text
output.roa in CSV or JSON
SLURM file or directory input
prefixAssertions with prefix/asn/maxPrefixLength
SLURM reload on validation cycles
fallback to previous valid SLURM when a new SLURM configuration is invalid
```

## 57. Mandatory PoC Gates Before Production

Even when commands are documented, verify their combined behavior on the exact deployed FRR release:

```text
1. RR addpath-tx-all-paths + RR-TO-RTBH outbound route-map sends
   non-best REQUEST paths and does not send APPROVED paths.

2. bgp route-reflector allow-outbound-policy does not create an
   unexpected interaction with existing RR outbound policies.

3. table-map leaves REQUEST in BGP while suppressing it from Zebra/FIB.

4. RPKI state changes re-evaluate FROM-RR-REQUESTS using the configured
   inbound soft reconfiguration.

5. show bgp ... large-community ... json matches the controller parser.

6. show rpki cache-connection json matches the conservative connection
   parser or the parser is adjusted to the exact release.

7. no bgp network import-check allows the controller's plain network /32
   to be locally originated without a static route.

8. TO-RR-APPROVED adds the approval community only to the dedicated
   controller-managed local /32 announcements.

9. Two FRR-RTBH nodes can originate the same approval without instability.

10. Customer withdrawal, entitlement removal, and RPKI revocation all
    produce deterministic approval withdrawal.
```

---

# Part XVI — Reference Basis

## 58. FORT

FORT Validator program arguments:

```text
https://nicmx.github.io/FORT-validator/usage.html
```

FORT SLURM documentation:

```text
https://nicmx.github.io/FORT-validator/slurm.html
```

FORT router/RTR behavior:

```text
https://nicmx.github.io/FORT-validator/routers.html
```

## 59. FRRouting

FRR BGP documentation:

```text
https://docs.frrouting.org/en/latest/bgp.html
```

FRR route-map documentation:

```text
https://docs.frrouting.org/en/latest/routemap.html
```

## 60. Relevant RFCs

```text
RFC 8416  - SLURM
RFC 8092  - BGP Large Communities
RFC 7999  - BLACKHOLE Community
RFC 5635  - Remote Triggered Black Hole Filtering
RFC 6811 / RFC 8893 - BGP Prefix Origin Validation model and clarifications
```

---

# Part XVII — Recommended Laboratory Build Order

## 61. Phase 1 — Authorization Plane

Implement and prove:

```text
FORT-PUBLIC
customers.yaml
rtbh-slurm-reconcile
FORT-RTBH
```

Do not configure BGP RTBH yet.

Acceptance:

```text
enabled customer -> correct local /32 authorization
disabled customer -> no local authorization
absent customer -> no local authorization
VRP removal -> assertion removed
overlapping origins -> preserved independently
```

## 62. Phase 2 — REQUEST Plane

Implement:

```text
generic edge CUSTOMER-IN
REQUEST FIB suppression
RR RTBH Add-Path feed
FRR-RTBH inbound validation marker
```

Acceptance:

```text
REQUEST reaches both RTBH nodes
REQUEST does not forward
valid REQUEST receives local 65010:9010:0 marker
invalid REQUEST does not
```

## 63. Phase 3 — Approval Plane

Run controller first with:

```bash
sudo /usr/local/sbin/rtbh-controller --once --dry-run
```

Then real one-shot:

```bash
sudo /usr/local/sbin/rtbh-controller --once
```

Acceptance:

```text
local BGP /32 appears
RR receives 65010:9001:0
LOCAL_PREF becomes 500 at RR import
edges receive approved path
```

## 64. Phase 4 — Forwarding Enforcement

Enable edge `BGP-TO-ZEBRA` and local discard route.

Acceptance:

```text
REQUEST only -> no FIB /32
APPROVED -> FIB /32 through local discard
```

## 65. Phase 5 — Automated Controller

Enable:

```bash
sudo systemctl enable --now rtbh-controller.service
```

Run the full failure/offboarding/revocation test matrix before production rollout.

---

# 66. Final Architecture Summary

The final implementation deliberately keeps the dynamic portion small:

```text
DYNAMIC:
    customers.yaml entitlement
    generated SLURM
    active REQUEST paths
    local FRR-RTBH network /32 statements
    approved BGP routes

STATIC AND IDENTICAL ON EDGES:
    RTBH communities
    /32 rule
    generic CUSTOMER-IN policy
    BGP-to-Zebra safety policy
    local discard next-hop
```

The central design principle is:

```text
FORT decides authorization.
BGP transports intent.
The local controller materializes only approved active state.
The edges implement discard locally.
```

This keeps normal ROV strict, eliminates per-customer RTBH policy objects on edges, avoids static-route redistribution, and confines dynamic router configuration to the two dedicated RTBH control-plane nodes.
