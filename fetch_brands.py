#!/usr/bin/env python3
"""Vendor the brand marks the TOTP popup draws for known issuers.

Run once; the results are committed, so the plugin needs no network at runtime.
That matters more here than in most plugins: this is an authenticator, and a
popup that phoned a CDN every time it opened would leak which services you hold
accounts with.

Two sources, in preference order:

  ph  Phosphor (MIT). Used wherever it has the brand, because it is one
      hand-drawn system at a uniform weight and optical size — a row of
      Phosphor marks reads as a designed set rather than a pile of logos.
  si  Simple Icons (CC0-1.0). Fills the brands Phosphor does not carry yet.

Both ship single-path `currentColor` SVGs, so nothing needs recolouring on
disk: the popup tints each one from the theme at paint time.

Every icon is written unmodified, and `brands/SOURCES.md` records which
upstream each file came from, because the two licences differ.
"""
from __future__ import annotations

import json
import pathlib
import urllib.error
import urllib.request

OUT = pathlib.Path(__file__).resolve().parent / "brands"
API = "https://api.iconify.design"

# (file stem, Phosphor name or None, Simple Icons name or None)
# Phosphor first. The Simple Icons name is usually the same slug.
BRANDS = [
    ("amazon",     "amazon-logo",        "amazon"),
    ("bitwarden",  None,                 "bitwarden"),
    ("github",     "github-logo",        "github"),
    ("google",     "google-logo",        "google"),
    ("hetzner",    None,                 "hetzner"),
    ("jetbrains",  None,                 "jetbrains"),
    ("linkedin",   "linkedin-logo",      "linkedin"),
    ("mongodb",    None,                 "mongodb"),
    ("openai",     None,                 "openai"),
    ("opera",      None,                 "opera"),
    ("paypal",     "paypal-logo",        "paypal"),
    ("reddit",     "reddit-logo",        "reddit"),
    ("slack",      "slack-logo",         "slack"),
    ("stripe",     "stripe-logo",        "stripe"),
    ("twitter",    "twitter-logo",       "twitter"),
    ("vivaldi",    None,                 "vivaldi"),
    ("xing",       None,                 "xing"),
    ("zoho",       None,                 "zoho"),
]


def fetch(prefix: str, name: str) -> str | None:
    url = f"{API}/{prefix}/{name}.svg"
    # The CDN rejects urllib's default user agent with a 403. That reads as
    # "this icon does not exist" if you only skim the error, which is exactly
    # the wrong conclusion — it just wants a plausible client.
    req = urllib.request.Request(url, headers={"User-Agent": "curl/8.7.1"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8")
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
        print(f"    {prefix}/{name}: {exc}")
        return None
    if "<svg" not in body or "path" not in body:
        print(f"    {prefix}/{name}: not an icon")
        return None
    return body


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    prov: dict[str, str] = {}
    failed: list[str] = []

    for stem, ph, si in BRANDS:
        target = OUT / f"{stem}.svg"
        if target.exists():
            print(f"  {stem:<12} already vendored")
            continue

        body = source = None
        if ph:
            body = fetch("ph", ph)
            source = f"ph/{ph}"
        if body is None and si:
            body = fetch("simple-icons", si)
            source = f"simple-icons/{si}"

        if body is None:
            failed.append(stem)
            print(f"  {stem:<12} NO ICON")
            continue

        target.write_text(body)
        prov[stem] = source
        print(f"  {stem:<12} {source}  ({len(body)} bytes)")

    if prov:
        lines = [
            "# Brand icon sources",
            "",
            "Vendored by `fetch_brands.py`. Unmodified upstream files.",
            "",
            "| Icon | Source | Licence |",
            "|------|--------|---------|",
        ]
        for stem, src in sorted(prov.items()):
            lic = "MIT" if src.startswith("ph/") else "CC0-1.0"
            lines.append(f"| `{stem}.svg` | {src} | {lic} |")
        lines += [
            "",
            "Phosphor: https://github.com/phosphor-icons/core (MIT)",
            "Simple Icons: https://github.com/simple-icons/simple-icons (CC0-1.0)",
            "",
            "The marks themselves remain trademarks of their owners. They are used",
            "here nominatively — to indicate which service a one-time-password entry",
            "belongs to — which is the purpose they exist for. Vendoring them offline",
            "means the popup never contacts a CDN, so it cannot leak which services",
            "you hold accounts with.",
        ]
        (OUT / "SOURCES.md").write_text("\n".join(lines) + "\n")
        print(f"\nwrote {OUT/'SOURCES.md'}")

    if failed:
        print(f"\nno icon for: {', '.join(failed)} — these fall back to the initial badge")


if __name__ == "__main__":
    main()
