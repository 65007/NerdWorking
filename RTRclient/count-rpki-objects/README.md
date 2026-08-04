# RPKI Object Counter and VRP Validator

**Author:** Nicolas Antoniello (Git: 65007)

## Overview

`count-rpki-objects.sh` analyzes an RPKI CSV export that is expected to contain VRPs (Validated ROA Payloads).

The script validates the structure and semantics of each VRP, reports IPv4 and IPv6 statistics, detects records that do not resemble the expected VRP schema, and writes unclassified records to a separate CSV file.

The current implementation supports the **VRP** profile only. ASPA, Router Key, and future RPKI object profiles are intentionally rejected until their actual `rtrclient` export formats are known and dedicated validators are implemented.

## Expected VRP Format

The current VRP profile expects four CSV fields:

```text
prefix_address, prefix_length, max_length, origin_asn
```

Example:

```text
1.0.0.0, 24, 24, 13335
```

## What the Script Does

The script:

1. Reads the input CSV file line by line.
2. Displays progress every configurable number of input lines.
3. Counts and ignores blank or whitespace-only lines.
4. Detects records that resemble the expected VRP schema.
5. Validates:
   - CSV field count
   - IPv4 or IPv6 address syntax
   - Prefix length
   - Maximum prefix length
   - Network-address alignment
   - Origin ASN syntax and range
6. Counts valid IPv4 and IPv6 VRPs separately.
7. Counts invalid VRP candidates by error category.
8. Counts records that do not resemble VRPs.
9. Writes unknown or non-VRP records to a separate CSV file.
10. Publishes the unclassified file atomically, replacing the result from the previous execution only after the new file has been written successfully.

## Signed ASN Compatibility

The tested `rtrclient` version may export some 32-bit unsigned ASNs as negative signed integers in CSV output.

For example:

```text
49.236.204.0, 24, 24, -92765234
```

The corresponding unsigned ASN is:

```text
4202202062
```

The script converts signed 32-bit values to their equivalent unsigned 32-bit values **in memory for validation only**.

The source CSV file is not modified.

The number of conversions is reported as:

```text
Signed ASN conversions: 18
```

## Unclassified Records

Records that do not resemble the expected VRP schema are not automatically classified as ASPA, Router Keys, or any other RPKI object type.

They are written to:

```text
/home/nicolas/RPKI/unclassified-records.csv
```

The file contains:

```text
line_number,reason,original_record
```

Each execution replaces the previous `unclassified-records.csv`. Therefore, the file always represents the most recent analysis.

## Requirements

- Bash
- Python 3
- A CSV file exported by `rtrclient`

On Ubuntu Server:

```bash
sudo apt update
sudo apt install -y python3 rtr-tools
```

## Installation

Clone or copy the script into the working directory:

```bash
cd /home/nicolas/RPKI
chmod 0755 count-rpki-objects.sh
```

Optional syntax check:

```bash
bash -n count-rpki-objects.sh
```

## Usage

Run with the default object type and input file:

```bash
./count-rpki-objects.sh
```

Defaults:

```text
Object type: vrp
Input file: roas.csv
```

Run with explicit arguments:

```bash
./count-rpki-objects.sh vrp roas.csv
```

Run against another CSV file:

```bash
./count-rpki-objects.sh vrp /path/to/vrps.csv
```

## Example Input Generation

The input file can be generated from an RPKI-RTR cache with `rtrclient`:

```bash
rtrclient -e -t csv -o roas.csv tcp 10.0.1.15 323
```

## Example Output

```text
Starting RPKI object analysis...
Expected object type: vrp
Input file: roas.csv
Progress interval: 100000 records

Step 1: Opening input CSV file...
Step 2: Processed 100,000 input lines...
Step 2: Processed 200,000 input lines...
Step 2: Processed 300,000 input lines...
Step 3: Writing unclassified records file...
Step 4: Unclassified records file published successfully.

Step 5: Analysis completed.

Object type: VRP
IPv4 VRPs: 753172
IPv6 VRPs: 229771
Total valid VRPs: 982943
Invalid structure: 0
Invalid prefix: 0
Invalid length: 0
Invalid ASN: 0
Total invalid VRP candidates: 0
Unknown or non-VRP records: 0
Signed ASN conversions: 18
Empty lines: 2
Non-empty records: 982943
Total input lines: 982945
Unclassified records: 0
Unclassified output: /home/nicolas/RPKI/unclassified-records.csv
```

## Output Fields

| Field | Meaning |
|---|---|
| `IPv4 VRPs` | Valid VRPs containing IPv4 prefixes |
| `IPv6 VRPs` | Valid VRPs containing IPv6 prefixes |
| `Total valid VRPs` | Sum of valid IPv4 and IPv6 VRPs |
| `Invalid structure` | Records with an unexpected number of CSV fields |
| `Invalid prefix` | Invalid IP addresses or prefixes not aligned to a network boundary |
| `Invalid length` | Invalid prefix length or maximum length |
| `Invalid ASN` | ASN values that cannot be interpreted as valid unsigned 32-bit values |
| `Total invalid VRP candidates` | Sum of all invalid VRP categories |
| `Unknown or non-VRP records` | Records that do not resemble the expected VRP schema |
| `Signed ASN conversions` | Negative signed integers converted in memory to unsigned ASN values |
| `Empty lines` | Blank or whitespace-only input lines |
| `Non-empty records` | All non-empty input records |
| `Total input lines` | All physical lines read from the input file |
| `Unclassified records` | Number of rows written to the unclassified output |
| `Unclassified output` | Path to the generated unclassified CSV file |

## Progress Reporting

The progress interval is configured inside the script:

```bash
PROGRESS_INTERVAL="100000"
```

To display progress more frequently:

```bash
PROGRESS_INTERVAL="50000"
```

To disable periodic progress messages:

```bash
PROGRESS_INTERVAL="0"
```

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Analysis completed and no invalid VRP candidates were found |
| `1` | Input, permission, dependency, or VRP validation error |
| `2` | Unsupported or not-yet-implemented object profile |
| `3` | Internal record-accounting mismatch |

## Current Limitations

- Only the VRP profile is implemented.
- The script does not modify or normalize the source CSV.
- Unknown records are not automatically identified as ASPA or Router Keys.
- Future RTRv2 object support depends on the export format implemented by `rtrclient`.
- The signed-ASN compatibility handling is a workaround for affected CSV exports and should be reviewed when the upstream issue is fixed.

## Future Extensions

The script is structured so that future profiles can be added for:

- ASPA
- Router Keys
- Other RPKI-RTR object types

Each future profile should define its own:

- Expected schema
- Structural validation
- Semantic validation
- Statistics
- Output handling

## License

MIT License

Copyright (c) 2026 Nicolas Antoniello

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
