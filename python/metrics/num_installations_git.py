#!/usr/bin/env python3
import json
import sys
import os
import argparse
import subprocess
from datetime import datetime, timedelta


def main():
    parser = argparse.ArgumentParser(
        description="Show a count or a list of Dataverse installations based on data in git."
    )
    parser.add_argument("-d", "--date", help="A date in YYYY-MM-DD format.", type=str)
    parser.add_argument(
        "-l",
        "--list",
        help="Print the installations instead of a count.",
        action="store_true",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        help="Show more output.",
        action="store_true",
    )
    args = parser.parse_args()

    requested_date = None

    if args.date:
        requested_date = parse_date(args.date)
    else:
        requested_date = datetime.now()

    # one day later because we pass the date as "before"
    before_date = requested_date + timedelta(days=1)

    if args.verbose:
        print(f"requested date {requested_date}")
        print(f"one day later {before_date}")

    git_repo = "dataverse-installations"

    git_clone_or_pull(git_repo)

    commit_hash = get_commit_hash(git_repo, before_date)

    if args.verbose:
        print(commit_hash)

    if not commit_hash:
        print("No commit found before the specified date.")
        sys.exit(1)

    checkout_commit(git_repo, commit_hash)

    data = load_json_data(git_repo)
    # print(json.dumps(data, indent=4))
    if args.list:
        for i in sorted(
            data.get("installations", []),
            key=lambda x: x["name"].lower(),
        ):
            print(i["name"])
    else:
        print(len(data.get('installations', [])))


def parse_date(date_str):
    try:
        return datetime.strptime(date_str, "%Y-%m-%d")
    except ValueError as e:
        print(f"Invalid date format: {date_str}. Expected format is YYYY-MM-DD.")
        sys.exit(1)


def get_commit_hash(repo_path, date):
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                repo_path,
                "rev-list",
                "-n",
                "1",
                "--before",
                f"{date}",
                "main",
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        return result.stdout.strip()
    except Exception as e:
        print(f"Error while retrieving commit hash: {e}")
        return None


def checkout_commit(repo_path, commit_hash):
    try:
        subprocess.run(
            ["git", "-C", repo_path, "checkout", commit_hash],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        print(f"Error while checking out commit {commit_hash}: {e}")
        sys.exit(1)


def git_clone_or_pull(repo_path):
    if not os.path.isdir(repo_path):
        result = subprocess.run(
            ["git", "clone", f"https://github.com/IQSS/{repo_path}.git"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    else:
        result = subprocess.run(
            ["git", "-C", repo_path, "checkout", "main"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        result = subprocess.run(
            ["git", "-C", repo_path, "pull"],
            stdout=subprocess.PIPE,
            text=True,
        )


def load_json_data(repo_path):
    json_file = f"{repo_path}/data/data.json"
    try:
        with open(json_file, "r") as file:
            return json.load(file)
    except FileNotFoundError:
        print(f"JSON file not found: {json_file}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error decoding JSON from file {json_file}: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
