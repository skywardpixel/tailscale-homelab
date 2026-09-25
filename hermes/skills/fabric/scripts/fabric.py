#!/usr/bin/env python3
"""Run a Fabric pattern on the homelab Fabric server and print the result.

    fabric.py <pattern> [--file PATH | --text TEXT] [--model MODEL --vendor VENDOR]
    fabric.py --list [FILTER]

Input comes from --file, --text, or stdin. Reads FABRIC_URL (the Fabric
project's https://CUSTOM_DOMAIN) and FABRIC_API_KEY from the environment.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request


def request(path, body=None):
    url = os.environ.get("FABRIC_URL", "").rstrip("/")
    key = os.environ.get("FABRIC_API_KEY")
    if not url or not key:
        sys.exit("FABRIC_URL and FABRIC_API_KEY must both be set")
    req = urllib.request.Request(
        url + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"X-API-Key": key, "Content-Type": "application/json"},
    )
    try:
        return urllib.request.urlopen(req, timeout=300)
    except urllib.error.HTTPError as e:
        sys.exit(f"fabric: HTTP {e.code} on {path}: {e.read().decode(errors='replace')[:500]}")
    except urllib.error.URLError as e:
        sys.exit(f"fabric: cannot reach {req.full_url}: {e.reason}")


def list_patterns(needle):
    names = json.load(request("/patterns/names"))
    for name in sorted(names):
        if not needle or needle.lower() in name.lower():
            print(name)


def run(pattern, text, vendor, model):
    prompt = {"userInput": text, "patternName": pattern}
    if vendor:
        prompt["vendor"] = vendor
    if model:
        prompt["model"] = model
    # /chat streams server-sent events: content chunks, usage, then complete.
    with request("/chat", {"prompts": [prompt]}) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data: "):
                continue
            event = json.loads(line[6:])
            if event.get("type") == "content":
                sys.stdout.write(event.get("content", ""))
                sys.stdout.flush()
            elif event.get("type") == "error":
                sys.exit(f"\nfabric: {event.get('content')}")
    print()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("pattern", nargs="?")
    p.add_argument("--list", nargs="?", const="", metavar="FILTER")
    src = p.add_mutually_exclusive_group()
    src.add_argument("--file")
    src.add_argument("--text")
    p.add_argument("--vendor", help="override the server's default vendor (e.g. Anthropic)")
    p.add_argument("--model", help="override the server's default model")
    a = p.parse_args()

    if a.list is not None:
        return list_patterns(a.list)
    if not a.pattern:
        p.error("pattern is required (or use --list)")
    if a.file:
        with open(a.file, encoding="utf-8", errors="replace") as f:
            text = f.read()
    elif a.text is not None:
        text = a.text
    else:
        text = sys.stdin.read()
    if not text.strip():
        p.error("no input text")
    run(a.pattern, text, a.vendor, a.model)


if __name__ == "__main__":
    main()
