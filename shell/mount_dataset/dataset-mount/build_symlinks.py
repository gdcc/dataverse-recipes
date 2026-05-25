#!/usr/bin/env python3
"""Build friendly-name symlinks for a Dataverse dataset's files.

Reads a Dataverse /api/datasets/:persistentId/versions/<v>/files response
from disk and creates

    <files_dir>/<directoryLabel>/<filename>  ->  <s3_mount>/<identifier>/<storageFilename>

The symlinks use *relative* paths so they resolve identically from the
container's view (e.g. /mount/files -> /mount/.s3) and from the host's
view (e.g. ~/dataset/files -> ~/dataset/.s3), as long as <files_dir> and
<s3_mount> are siblings under the same shared mount point — which is the
case for mount_dataset.sh.

Storage identifiers look like ``<driver>://[<bucket>:]<filename>``. The
driver and bucket prefix are stripped; only the trailing filename is used
as the path inside the mounted bucket.
"""
import json
import os
import sys


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit(
            "usage: build_symlinks.py <manifest.json> <s3-mount> <files-dir> <identifier>"
        )
    manifest_path, s3_mount, files_dir, identifier = sys.argv[1:5]

    with open(manifest_path) as fh:
        payload = json.load(fh)

    if payload.get("status") != "OK":
        sys.exit(f"unexpected Dataverse response: {payload}")

    linked = 0
    for item in payload.get("data", []):
        df = item.get("dataFile") or {}
        fname = df.get("filename") or item.get("label")
        sid = df.get("storageIdentifier", "")
        dirlabel = (item.get("directoryLabel") or "").strip("/")
        if not fname or "://" not in sid:
            continue

        rest = sid.split("://", 1)[1]
        storage_filename = rest.split(":", 1)[1] if ":" in rest else rest

        absolute_source = os.path.join(s3_mount, identifier, storage_filename)
        target_dir = os.path.join(files_dir, dirlabel) if dirlabel else files_dir
        os.makedirs(target_dir, exist_ok=True)
        target = os.path.join(target_dir, fname)
        # Compute the relative path from the symlink's *directory* to the
        # source so the link resolves wherever the tree lives.
        relative_source = os.path.relpath(absolute_source, start=target_dir)
        if os.path.lexists(target):
            os.remove(target)
        os.symlink(relative_source, target)
        linked += 1

    print(f"linked {linked} file(s)")


if __name__ == "__main__":
    main()
