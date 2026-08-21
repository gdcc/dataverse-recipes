#!/usr/bin/env python3
"""
add_remote_files.py

Register files in a local directory tree as remote-store references in a
Dataverse dataset.  No file bytes are transferred; only metadata (storage
identifier, filename, MIME type, MD5 hash) is sent to the Dataverse API.

Dataverse and the specific dataset must be configured to use a remote store.
The remote store id must match the --store-id parameter in this script.

The configured base-url of the remote store usually corresponds to the
--web-root directory. If it doesn't, the --web-path parameter can be used
to specify the additional path components.

Example:
  base-url: https://example.com/shareddata
  web-root: /mnt/data
  File /mnt/data/file.txt is accessible at https://example.com/shareddata/file.txt
  (No --web-path needed)

Example with --web-path:
  base-url: https://web.tacc.utexas.edu
  web-root: /corral/Texas-Robotics/web
  web-path: /texasrobotics
  File /corral/Texas-Robotics/web/file.txt is accessible at
  https://web.tacc.utexas.edu/texasrobotics/file.txt

Usage
-----
python add_remote_files.py \\
    --server    https://dataverse.example.org \\
    --api-key   xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \\
    --store-id  trs \\
    --web-root /mnt/data \\
    --web-path /optional-prefix \\
    --pid       doi:10.5072/FK27U7YBV \\
    --base-dir  /mnt/data/project/files

Storage-identifier and directoryLabel construction
------------------------------------------------
Given:
  --web-root  /mnt/data
  --web-path  /prefix  (optional)
  --store-id  trs
  file path   /mnt/data/project/files/subdir/file.csv

The web root is stripped from the absolute path and the web path is prepended:
  /prefix/project/files/subdir/file.csv

The storage identifier becomes:
  trs:///prefix/project/files/subdir/file.csv

The directoryLabel becomes:
  prefix/project/files/subdir

API used
--------
1. GET /api/datasets/:persistentId/versions/:latest/files?persistentId=<PID>
   to list existing files and avoid duplicates.

2. POST /api/datasets/:persistentId/addFiles?persistentId=<PID>
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


def build_storage_identifier(store_id: str, web_root: str, abs_path: str, web_path: str = "") -> str:
    """
    Strip *web_root* from the start of *abs_path* to get the canonical
    remote path. If *web_path* is provided, it is prepended to the result.
    The final path is formatted as <store-id>://<path>.

    Example
    -------
    store-id     = "trs"
    web_root     = "/mnt/data"
    abs_path     = "/mnt/data/project/files/foo.csv"
    web_path     = "/remote/url/prefix"
    → "trs:///remote/url/prefix/project/files/foo.csv"
    """
    # Normalise both paths so trailing slashes etc. don't cause problems.
    web_root = os.path.normpath(web_root)
    abs_path = os.path.normpath(abs_path)

    if not abs_path.startswith(web_root):
        raise ValueError(
            f"File path '{abs_path}' does not start with "
            f"web-root '{web_root}'"
        )

    remaining = abs_path[len(web_root):]
    # Ensure we use forward slashes for the storage identifier
    remaining = remaining.replace(os.sep, "/")
    if not remaining.startswith("/"):
        remaining = "/" + remaining

    full_path = remaining
    if web_path:
        # Prepend web_path, ensuring we don't double up on slashes
        wp = web_path.replace(os.sep, "/").rstrip("/")
        if not wp.startswith("/"):
            wp = "/" + wp
        full_path = wp + remaining

    # Use double-slash after the scheme so the path is clearly absolute:
    # trs:///some/path  (scheme + empty authority + absolute path)
    return f"{store_id}://{full_path}"


def collect_files(base_dir: str):
    """Yield absolute paths for every regular file under *base_dir*."""
    for dirpath, _dirnames, filenames in os.walk(base_dir):
        for name in filenames:
            yield os.path.join(dirpath, name)


def build_file_metadata(
    abs_path: str,
    storage_id: str,
    web_root: str,
    web_path: str = "",
    verbose: bool = True,
) -> dict:
    """Return the JSON-serialisable metadata dict for one file."""
    filename = os.path.basename(abs_path)
    mime = guess_mime(filename)

    if verbose:
        print(f"  Hashing  {abs_path} …", end=" ", flush=True)
    md5 = compute_md5(abs_path)
    if verbose:
        print(md5)

    # Derive a directoryLabel relative to web_root, prepending web_path if present.
    rel = os.path.relpath(os.path.dirname(abs_path), web_root)
    
    parts = []
    if web_path:
        wp = web_path.strip("/").replace(os.sep, "/")
        if wp:
            parts.append(wp)
            
    if rel != ".":
        parts.append(rel.replace(os.sep, "/"))
    
    dir_label = "/".join(parts)

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
# Dataverse API calls
# ---------------------------------------------------------------------------

def get_existing_storage_identifiers(server: str, api_key: str, pid: str, store_id: str) -> set[str]:
    """Fetch the list of files in the dataset and return their storage identifiers."""
    encoded_pid = urllib.parse.quote(pid, safe="")
    url = f"{server.rstrip('/')}/api/datasets/:persistentId/versions/:latest/files?persistentId={encoded_pid}"

    req = urllib.request.Request(
        url,
        headers={
            "X-Dataverse-key": api_key,
        },
    )

    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode("utf-8")
            data = json.loads(raw)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        print(f"\n[ERROR] Failed to list dataset contents: HTTP {exc.code}: {exc.reason}", file=sys.stderr)
        print(raw, file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f"\n[ERROR] Failed to list dataset contents: {exc}", file=sys.stderr)
        sys.exit(1)

    ids = set()
    if data.get("status") == "OK":
        for file_info in data.get("data", []):
            storage_id = file_info.get("dataFile", {}).get("storageIdentifier")
            if storage_id:
                parsed = urllib.parse.urlparse(storage_id)
                if parsed.scheme == store_id:
                    # Dataverse may return identifiers like <store-id>://<uuid>//<path>
                    # We normalize them to <store-id>:///<path> for local comparison.
                    normalized = f"{parsed.scheme}:///{parsed.path.lstrip('/')}"
                    ids.add(normalized)
    return ids


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
        "--web-root", required=True,
        help=(
            "Local path prefix to strip before building the storage identifier, "
            "e.g. /mnt/data  →  trs:///project/files/foo.csv"
        ),
    )
    p.add_argument(
        "--web-path", default="",
        help=(
            "Optional prefix to add to the web path in the storage identifier, "
            "useful when the web-root does not match the store's base-url. "
            "e.g. /texasrobotics  →  trs:///texasrobotics/project/files/foo.csv"
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
    p.add_argument(
        "--limit", type=int,
        help="Only register the first N files that don't exist on the server.",
    )
    return p.parse_args()


def main():
    args = parse_args()

    base_dir = os.path.abspath(args.base_dir)
    web_root = os.path.abspath(args.web_root)
    web_path = args.web_path

    if not os.path.isdir(base_dir):
        print(f"[ERROR] --base-dir '{base_dir}' is not a directory.", file=sys.stderr)
        sys.exit(1)

    print(f"Scanning {base_dir} …")
    all_files = sorted(collect_files(base_dir))
    print(f"Found {len(all_files)} file(s).\n")

    if not all_files:
        print("Nothing to do.")
        return

    print(f"Checking existing files in dataset {args.pid} …")
    existing_ids = get_existing_storage_identifiers(args.server, args.api_key, args.pid, args.store_id)
    print(f"Found {len(existing_ids)} matching existing file(s) in dataset.\n")

    # Build metadata for every file.
    entries = []
    skipped_count = 0
    for path in all_files:
        if args.limit is not None and len(entries) >= args.limit:
            break

        try:
            storage_id = build_storage_identifier(args.store_id, web_root, path, web_path)
            if storage_id in existing_ids:
                skipped_count += 1
                continue

            print(f"Processing: {path}")
            meta = build_file_metadata(path, storage_id, web_root, web_path)
            entries.append(meta)
        except ValueError as exc:
            print(f"  [SKIP] {exc}", file=sys.stderr)

    if skipped_count > 0:
        print(f"\nSkipped {skipped_count} file(s) that already exist in the dataset.")

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
