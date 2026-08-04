#!/usr/bin/env bash

# Creted by Nicolas Antoniello (Git: 65007)
# Last update: 2026-08-03

###############################################################################
# Script: count-rpki-objects.sh
#
# Purpose
# -------
# Analyze an RPKI CSV export and validate records expected to be VRPs
# (Validated ROA Payloads).
#
# Current input format
# --------------------
# The current VRP profile expects four CSV fields:
#
#   prefix_address, prefix_length, max_length, origin_asn
#
# Example:
#
#   1.0.0.0, 24, 24, 13335
#
# Processing performed
# --------------------
# 1. Reads the input CSV file line by line.
# 2. Shows progress every configured number of input lines.
# 3. Ignores and counts empty or whitespace-only lines.
# 4. Identifies records that resemble the expected VRP format.
# 5. Validates:
#      - CSV field count
#      - IPv4 or IPv6 prefix syntax
#      - prefix length
#      - maximum prefix length
#      - network address alignment
#      - origin ASN format and range
# 6. Counts valid IPv4 and IPv6 VRPs separately.
# 7. Counts invalid VRP candidates by error category.
# 8. Counts records that do not resemble VRPs.
# 9. Writes unknown or non-VRP records to:
#
#      /home/nicolas/RPKI/unclassified-records.csv
#
# Signed ASN compatibility
# ------------------------
# The installed rtrclient version may export some 32-bit unsigned ASNs as
# negative signed integers. The script converts values in the signed int32
# range to their equivalent uint32 value for validation and reports how many
# conversions were required.
#
# This conversion is performed only in memory. The source CSV file is not
# modified.
#
# Unclassified output behavior
# ----------------------------
# The unclassified-records.csv file is generated using a temporary file and
# published atomically.
#
# Each execution replaces the previous unclassified-records.csv file. It
# therefore represents only the results of the most recent analysis.
#
# Future object support
# ---------------------
# The script currently implements only the VRP validation profile.
#
# ASPA, Router Key, and future RPKI object profiles are intentionally rejected
# until their actual rtrclient export schemas are known and dedicated
# validators are implemented.
#
# A record that does not resemble a VRP is not automatically classified as
# ASPA or another object type. It is stored as an unclassified record.
#
# Usage
# -----
# Default input:
#
#   ./count-rpki-objects.sh
#
# Explicit object type and input file:
#
#   ./count-rpki-objects.sh vrp roas.csv
#
# Exit codes
# ----------
# 0  Analysis completed and no invalid VRP candidates were found.
# 1  Input, permission, dependency, or VRP validation error.
# 2  Unsupported or not-yet-implemented object profile.
# 3  Internal record accounting mismatch.
###############################################################################

set -euo pipefail

###############################################################################
# Configuration
###############################################################################

OBJECT_TYPE="${1:-vrp}"
INPUT_FILE="${2:-roas.csv}"

OUTPUT_DIR="/home/nicolas/RPKI"
UNCLASSIFIED_FILE="${OUTPUT_DIR}/unclassified-records.csv"

PROGRESS_INTERVAL="100000"

###############################################################################
# Initial checks
###############################################################################

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: input file not found: $INPUT_FILE" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

if [[ ! -w "$OUTPUT_DIR" ]]; then
    echo "Error: output directory is not writable: $OUTPUT_DIR" >&2
    exit 1
fi

case "$OBJECT_TYPE" in
    vrp)
        ;;
    aspa)
        echo "Error: ASPA validation profile is not implemented yet." >&2
        exit 2
        ;;
    router_key)
        echo "Error: Router Key validation profile is not implemented yet." >&2
        exit 2
        ;;
    *)
        echo "Error: unsupported object type: $OBJECT_TYPE" >&2
        exit 2
        ;;
esac

###############################################################################
# Execution summary
###############################################################################

echo "Starting RPKI object analysis..."
echo "Expected object type: $OBJECT_TYPE"
echo "Input file: $INPUT_FILE"
echo "Progress interval: $PROGRESS_INTERVAL records"
echo

###############################################################################
# Process the file
###############################################################################

python3 - \
    "$INPUT_FILE" \
    "$UNCLASSIFIED_FILE" \
    "$PROGRESS_INTERVAL" <<'PYTHON'
import csv
import ipaddress
import os
import sys
import tempfile
from pathlib import Path

input_file = Path(sys.argv[1])
unclassified_file = Path(sys.argv[2])
progress_interval = int(sys.argv[3])

ipv4_count = 0
ipv6_count = 0

invalid_structure = 0
invalid_prefix = 0
invalid_length = 0
invalid_asn = 0

unknown_non_vrp = 0
signed_asn_conversions = 0
empty_count = 0
non_empty_count = 0
total_lines = 0

invalid_examples: list[str] = []
max_examples = 10

unclassified_records: list[tuple[int, str, str]] = []


def add_invalid_example(
    line_number: int,
    reason: str,
    row: list[str],
) -> None:
    if len(invalid_examples) >= max_examples:
        return

    rendered = ",".join(row)

    invalid_examples.append(
        f"Line {line_number}: {reason}: {rendered}"
    )


def looks_like_ip_text(value: str) -> bool:
    value = value.strip()

    return "." in value or ":" in value


def is_integer_text(value: str) -> bool:
    value = value.strip()

    if value.startswith(("+", "-")):
        value = value[1:]

    return bool(value) and value.isdigit()


def looks_like_vrp_candidate(row: list[str]) -> bool:
    if not row:
        return False

    first_field = row[0].strip()

    if looks_like_ip_text(first_field):
        return True

    if len(row) == 4:
        numeric_fields = sum(
            is_integer_text(field)
            for field in row[1:]
        )

        if numeric_fields >= 2:
            return True

    return False


print("Step 1: Opening input CSV file...", flush=True)

with input_file.open(
    "r",
    encoding="utf-8",
    newline="",
) as file_handle:
    reader = csv.reader(file_handle)

    for line_number, row in enumerate(reader, start=1):
        total_lines += 1

        if (
            progress_interval > 0
            and total_lines % progress_interval == 0
        ):
            print(
                f"Step 2: Processed {total_lines:,} input lines...",
                flush=True,
            )

        if not row or all(not field.strip() for field in row):
            empty_count += 1
            continue

        non_empty_count += 1

        original_record = ",".join(row)

        if not looks_like_vrp_candidate(row):
            unknown_non_vrp += 1

            unclassified_records.append(
                (
                    line_number,
                    "Record does not resemble the expected VRP schema",
                    original_record,
                )
            )
            continue

        if len(row) != 4:
            invalid_structure += 1

            add_invalid_example(
                line_number,
                f"expected 4 fields, received {len(row)}",
                row,
            )
            continue

        prefix_text = row[0].strip()
        prefix_length_text = row[1].strip()
        max_length_text = row[2].strip()
        origin_asn_text = row[3].strip()

        try:
            address = ipaddress.ip_address(prefix_text)
        except ValueError:
            invalid_prefix += 1

            add_invalid_example(
                line_number,
                "invalid IPv4 or IPv6 address",
                row,
            )
            continue

        try:
            prefix_length = int(prefix_length_text, 10)
            max_length = int(max_length_text, 10)
        except ValueError:
            invalid_length += 1

            add_invalid_example(
                line_number,
                "prefix length or max length is not an integer",
                row,
            )
            continue

        maximum_bits = address.max_prefixlen

        if not 0 <= prefix_length <= maximum_bits:
            invalid_length += 1

            add_invalid_example(
                line_number,
                "prefix length is outside the address-family range",
                row,
            )
            continue

        if not prefix_length <= max_length <= maximum_bits:
            invalid_length += 1

            add_invalid_example(
                line_number,
                "max length is outside the valid range",
                row,
            )
            continue

        try:
            origin_asn = int(origin_asn_text, 10)
        except ValueError:
            invalid_asn += 1

            add_invalid_example(
                line_number,
                "origin ASN is not an integer",
                row,
            )
            continue

        # Compatibility handling for rtrclient versions that print a uint32
        # ASN as a signed 32-bit integer in CSV output.
        if -(2**31) <= origin_asn < 0:
            origin_asn += 2**32
            signed_asn_conversions += 1

        if not 0 <= origin_asn <= 2**32 - 1:
            invalid_asn += 1

            add_invalid_example(
                line_number,
                "origin ASN is outside the uint32 range",
                row,
            )
            continue

        network = ipaddress.ip_network(
            f"{prefix_text}/{prefix_length}",
            strict=False,
        )

        if address != network.network_address:
            invalid_prefix += 1

            add_invalid_example(
                line_number,
                "prefix address is not a network address",
                row,
            )
            continue

        if address.version == 4:
            ipv4_count += 1
        else:
            ipv6_count += 1


valid_count = ipv4_count + ipv6_count

total_invalid = (
    invalid_structure
    + invalid_prefix
    + invalid_length
    + invalid_asn
)

classified_records = valid_count + total_invalid
accounted_non_empty = classified_records + unknown_non_vrp

if accounted_non_empty != non_empty_count:
    print(
        "Error: internal record accounting mismatch.",
        file=sys.stderr,
    )
    raise SystemExit(3)


print(
    "Step 3: Writing unclassified records file...",
    flush=True,
)

unclassified_file.parent.mkdir(
    parents=True,
    exist_ok=True,
)

temporary_descriptor, temporary_name = tempfile.mkstemp(
    prefix=f".{unclassified_file.name}.",
    dir=unclassified_file.parent,
    text=True,
)

try:
    with os.fdopen(
        temporary_descriptor,
        "w",
        encoding="utf-8",
        newline="",
    ) as output_handle:
        writer = csv.writer(output_handle)

        writer.writerow(
            [
                "line_number",
                "reason",
                "original_record",
            ]
        )

        writer.writerows(unclassified_records)

    os.chmod(temporary_name, 0o644)
    os.replace(temporary_name, unclassified_file)

except Exception:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass

    raise


print(
    "Step 4: Unclassified records file published successfully.",
    flush=True,
)

print()
print("Step 5: Analysis completed.")
print()

print("Object type: VRP")
print(f"IPv4 VRPs: {ipv4_count}")
print(f"IPv6 VRPs: {ipv6_count}")
print(f"Total valid VRPs: {valid_count}")
print(f"Invalid structure: {invalid_structure}")
print(f"Invalid prefix: {invalid_prefix}")
print(f"Invalid length: {invalid_length}")
print(f"Invalid ASN: {invalid_asn}")
print(f"Total invalid VRP candidates: {total_invalid}")
print(f"Unknown or non-VRP records: {unknown_non_vrp}")
print(f"Signed ASN conversions: {signed_asn_conversions}")
print(f"Empty lines: {empty_count}")
print(f"Non-empty records: {non_empty_count}")
print(f"Total input lines: {total_lines}")
print(f"Unclassified records: {unknown_non_vrp}")
print(f"Unclassified output: {unclassified_file}")

if invalid_examples:
    print()
    print("Invalid VRP examples:")

    for example in invalid_examples:
        print(example)

if total_invalid:
    raise SystemExit(1)
PYTHON
