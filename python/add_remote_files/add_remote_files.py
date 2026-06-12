#!/usr/bin/env python3
"""
add_remote_files.py

Register files in a local directory tree as remote-store references in a
Dataverse dataset.  No file bytes are transferred; only metadata (storage
identifier, filename, MIME type, MD5 hash) is sent to the Dataverse API.

Dataverse and the specific dataset must be configured to use a remote store.
The remote store id must match the --store-id parameter in this script, and
the configured base-url must correspond to the --local-offset used, i.e.
for a base-url https://example.com/shareddata, the URL
https://example.com/sharedddata/file.txt must correspond the local path
<local-offset>/file.txt. Further, a file in the --base-dir is expected to
correspond to a URL matching the base-url plus the relative path difference
between the --local-offset and the file path. (With the usage example below,
a file.txt in the base dir should be accessible at
https://example.com/sharedddata/project/files/file.txt)

Usage
-----
python dataverse_remote_store_upload.py \\
    --server    https://dataverse.example.org \\
    --api-key   xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \\
    --store-id    trs \\
    --local-offset /mnt/data \\
    --pid       doi:10.5072/FK27U7YBV \\
    --base-dir  /mnt/data/project/files

Storage-identifier construction
--------------------------------
Given:
  --local-offset  /mnt/data
  --store-id      trs
  file path       /mnt/data/project/files/subdir/file.csv

The local offset is stripped from the absolute path to produce:
  /project/files/subdir/file.csv

The storage identifier becomes:
  trs:///project/files/subdir/file.csv

API used
--------
POST /api/datasets/:persistentId/addFiles?persistentId=<PID>
with a multipart/form-data field "jsonData" containing a JSON array of
file-metadata objects (the "add multiple files" variant of the Direct
DataFile Upload/Replace API).
"""

import argparse
import hashlib
import json
import mimetypes
import os
import sys
import urllib.parse
import urllib.request


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def compute_md5(path: str, chunk: int = 1 << 20) -> str:
    """Return the hex-encoded MD5 digest of a file."""
    h = hashlib.md5()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(chunk)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def guess_mime(filename: str) -> str:
    """Return a best-guess MIME type for *filename*, defaulting to
    'application/octet-stream'."""
    mime, _ = mimetypes.guess_type(filename)
    return mime or "application/octet-stream"


def build_storage_identifier(store_id: str, local_offset: str, abs_path: str) -> str:
    """
    Strip *local_offset* from the start of *abs_path* to get the canonical
    remote path, then format it as  <store-id>://<remaining path>.

    Example
    -------
    store-id     = "trs"
    local_offset = "/mnt/data"
    abs_path     = "/mnt/data/project/files/foo.csv"
    → "trs:///project/files/foo.csv"
    """
    # Normalise both paths so trailing slashes etc. don't cause problems.
    local_offset = os.path.normpath(local_offset)
    abs_path = os.path.normpath(abs_path)

    if not abs_path.startswith(local_offset):
        raise ValueError(
            f"File path '{abs_path}' does not start with "
            f"local-offset '{local_offset}'"
        )

    remaining = abs_path[len(local_offset):]  # starts with '/' on POSIX
    if not remaining.startswith("/"):
        remaining = "/" + remaining

    # Use double-slash after the scheme so the path is clearly absolute:
    # trs:///some/path  (scheme + empty authority + absolute path)
    return f"{store_id}://{remaining}"


def collect_files(base_dir: str):
    """Yield absolute paths for every regular file under *base_dir*."""
    for dirpath, _dirnames, filenames in os.walk(base_dir):
        for name in filenames:
            yield os.path.join(dirpath, name)


def build_file_metadata(
    abs_path: str,
    store_id: str,
    local_offset: str,
    base_dir: str,
    verbose: bool = True,
) -> dict:
    """Return the JSON-serialisable metadata dict for one file."""
    filename = os.path.basename(abs_path)
    storage_id = build_storage_identifier(store_id, local_offset, abs_path)
    mime = guess_mime(filename)

    if verbose:
        print(f"  Hashing  {abs_path} …", end=" ", flush=True)
    md5 = compute_md5(abs_path)
    if verbose:
        print(md5)

    # Derive a directoryLabel relative to base_dir (optional but useful).
    rel = os.path.relpath(os.path.dirname(abs_path), base_dir)
    dir_label = rel if rel != "." else ""

    entry = {
        "storageIdentifier": storage_id,
        "fileName": filename,
        "mimeType": mime,
        "md5Hash": md5,
        "description": "",
    }
    if dir_label:
        entry["directoryLabel"] = dir_label

    return entry


# ---------------------------------------------------------------------------
# Dataverse API call
# ---------------------------------------------------------------------------

def add_files_to_dataset(
    server: str,
    api_key: str,
    pid: str,
    file_entries: list[dict],
    dry_run: bool = False,
) -> dict | None:
    """
    POST the file-metadata array to the Dataverse "addFiles" endpoint.

    Returns the parsed JSON response, or None on dry-run.
    """
    encoded_pid = urllib.parse.quote(pid, safe="")
    url = f"{server.rstrip('/')}/api/datasets/:persistentId/addFiles?persistentId={encoded_pid}"

    json_data = json.dumps(file_entries)

    print(f"\n→ POST {url}")
    print(f"  Files to register: {len(file_entries)}")
    if dry_run:
        print("  [DRY RUN] jsonData payload:")
        print(json.dumps(file_entries, indent=2))
        return None

    # Build a minimal multipart/form-data request by hand so we only need
    # the standard library (no 'requests' dependency).
    boundary = "----DataverseRemoteUploadBoundary"
    body_parts = [
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="jsonData"\r\n\r\n'
        f"{json_data}\r\n",
        f"--{boundary}--\r\n",
    ]
    body = "".join(body_parts).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "X-Dataverse-key": api_key,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )

    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        print(f"\n[ERROR] HTTP {exc.code}: {exc.reason}", file=sys.stderr)
        print(raw, file=sys.stderr)
        sys.exit(1)

    return json.loads(raw)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(
        description="Register remote-store file references in a Dataverse dataset."
    )
    p.add_argument(
        "--server", required=True,
        help="Base URL of the Dataverse server, e.g. https://demo.dataverse.org",
    )
    p.add_argument(
        "--api-key", required=True,
        help="Dataverse API token.",
    )
    p.add_argument(
        "--store-id", required=True,
        help="Remote store store-id configured in Dataverse, e.g. 'trs'.",
    )
    p.add_argument(
        "--local-offset", required=True,
        help=(
            "Local path prefix to strip before building the storage identifier, "
            "e.g. /mnt/data  →  trs:///project/files/foo.csv"
        ),
    )
    p.add_argument(
        "--pid", required=True,
        help="Dataset persistent identifier, e.g. doi:10.5072/FK27U7YBV",
    )
    p.add_argument(
        "--base-dir", required=True,
        help="Local directory tree to scan for files.",
    )
    p.add_argument(
        "--dry-run", action="store_true",
        help="Build and print the JSON payload but do NOT call the API.",
    )
    p.add_argument(
        "--batch-size", type=int, default=100,
        help="Number of files to send per API call (default: 100).",
    )
    return p.parse_args()


def main():
    args = parse_args()

    base_dir = os.path.abspath(args.base_dir)
    local_offset = os.path.abspath(args.local_offset)

    if not os.path.isdir(base_dir):
        print(f"[ERROR] --base-dir '{base_dir}' is not a directory.", file=sys.stderr)
        sys.exit(1)

    print(f"Scanning {base_dir} …")
    all_files = sorted(collect_files(base_dir))
    print(f"Found {len(all_files)} file(s).\n")

    if not all_files:
        print("Nothing to do.")
        return

    # Build metadata for every file.
    entries = []
    for path in all_files:
        print(f"Processing: {path}")
        try:
            meta = build_file_metadata(path, args.store_id, local_offset, base_dir)
            entries.append(meta)
        except ValueError as exc:
            print(f"  [SKIP] {exc}", file=sys.stderr)

    if not entries:
        print("No valid entries produced.")
        return

    # Send in batches.
    batch_size = max(1, args.batch_size)
    for i in range(0, len(entries), batch_size):
        batch = entries[i : i + batch_size]
        print(f"\nBatch {i // batch_size + 1}: registering files {i + 1}–{i + len(batch)}")
        result = add_files_to_dataset(
            server=args.server,
            api_key=args.api_key,
            pid=args.pid,
            file_entries=batch,
            dry_run=args.dry_run,
        )
        if result is not None:
            status = result.get("status", "?")
            print(f"  Status: {status}")
            data = result.get("data", {})
            summary = data.get("Result", {})
            if summary:
                for k, v in summary.items():
                    print(f"  {k}: {v}")
            # Print per-file errors if any.
            for f in data.get("Files", []):
                if "errorMessage" in f:
                    fname = f.get("fileDetails", {}).get("fileName", "?")
                    print(f"  [FILE ERROR] {fname}: {f['errorMessage']}", file=sys.stderr)

    print("\nDone.")


if __name__ == "__main__":
    main()
