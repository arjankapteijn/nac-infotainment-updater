#!/usr/bin/env python3
"""Weekly update watch, run by .github/workflows/update-watch.yml.

Compares three things with the state saved by the previous run:
  - the NAC_EUR_WAVE4 entries in rui.saraiva's changelog
  - the firmware and European map files listed on the tracker's Wave 4 page
  - the HTTP status and size of every download URL in our scripts

Writes the new state, and when something changed (or the tracker could not be
read, or a primary URL no longer serves the expected file) writes a Markdown
report for the workflow to open as an issue.

Usage: check_updates.py <state.json> <report.md>
Exit code 0 always; the report file exists only when there is something to say.
Standard library only.
"""
import html
import json
import os
import re
import sys
import urllib.error
import urllib.request

TRACKER_PAGE = "https://sites.google.com/view/nac-rcc/system/nac/wave-4"
CHANGELOG_PAGE = "https://sites.google.com/view/nac-rcc/changelog"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = [
    "macos/prepare_nac_update_mac.sh",
    "macos/prepare_nac_map_update_mac.sh",
    "windows/Prepare-NacFirmwareUpdate.ps1",
    "windows/Prepare-NacMapUpdate.ps1",
]
USER_AGENT = "nac-infotainment-updater update watch (+https://github.com/arjankapteijn/nac-infotainment-updater)"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8", "replace")


def page_lines(page):
    """HTML to a list of text lines, one per block element."""
    page = re.sub(r"(?is)<(script|style)\b.*?</\1>", "", page)
    page = re.sub(r"(?i)<(br|/p|/div|/li|/h\d|/tr)\b[^>]*>", "\n", page)
    text = html.unescape(re.sub(r"<[^>]+>", "", page))
    lines = (re.sub(r"\s+", " ", line).strip() for line in text.split("\n"))
    return [line for line in lines if line]


def changelog_entries(page):
    entries, date = [], None
    for line in page_lines(page):
        if re.fullmatch(r"\d{1,2} [A-Z][a-z]{2} \d{4}", line):
            date = line
        elif line.startswith("[NAC_EUR_WAVE4]") and date:
            entries.append(f"{date}: {line[len('[NAC_EUR_WAVE4]'):].strip()}")
    return entries


def tracker_files(page):
    names = re.findall(
        r"PSA_ovip-int-firmware-version_[\w.-]+?_NAC_EUR_WAVE4\.tar|PSA_map-eur_[\w.-]+?-NAC_EUR_WAVE4\.tar",
        html.unescape(page))
    return sorted(set(names))


def script_urls():
    """{url: expected size or None} for every .tar URL in our scripts."""
    urls = {}
    for rel in SCRIPTS:
        with open(os.path.join(REPO, rel), encoding="utf-8-sig") as f:
            text = f.read()
        size = re.search(r"^\s*\$?(?:EXPECTED_SIZE|ExpectedSize)\s*=\s*(\d+)", text, re.M)
        for url in re.findall(r"https?://[^\s\"']+\.tar", text):
            urls[url] = int(size.group(1)) if size else None
    return urls


def probe(url):
    """'<status> <size>' for a URL, without downloading it."""
    for method, headers in (("HEAD", {}), ("GET", {"Range": "bytes=0-0"})):
        req = urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT, **headers})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                total = resp.headers.get("Content-Range", "").rpartition("/")[2] or resp.headers.get("Content-Length", "?")
                return f"200 {total}"
        except urllib.error.HTTPError as e:
            if method == "GET" or e.code not in (403, 405):
                return f"{e.code} -"
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            return f"error {type(e).__name__}"
    return "error -"


def diff_lists(title, old, new, code=True):
    added = [x for x in new if x not in old]
    removed = [x for x in old if x not in new]
    out = []
    if added or removed:
        out.append(f"### {title}\n")
        fmt = (lambda x: f"`{x}`") if code else (lambda x: x)
        out += [f"- added: {fmt(x)}" for x in added]
        out += [f"- removed: {fmt(x)}" for x in removed]
        out.append("")
    return out


def main(state_path, report_path):
    old = {}
    if os.path.exists(state_path):
        with open(state_path, encoding="utf-8") as f:
            old = json.load(f)

    problems, new = [], {"changelog": [], "tracker_files": [], "urls": {}}

    try:
        new["changelog"] = changelog_entries(fetch(CHANGELOG_PAGE))
    except Exception as e:  # network or HTTP error
        problems.append(f"Could not load the changelog: {e}")
    try:
        new["tracker_files"] = tracker_files(fetch(TRACKER_PAGE))
    except Exception as e:
        problems.append(f"Could not load the Wave 4 page: {e}")
    if not problems and (not new["changelog"] or not new["tracker_files"]):
        problems.append("The tracker loaded, but no NAC_EUR_WAVE4 entries or files were found. "
                        "The page layout probably changed; tools/check_updates.py needs updating.")

    expected = script_urls()
    for url, size in expected.items():
        new["urls"][url] = probe(url)
    primaries = {u for u in expected if "cloudfront" not in u and "download.tomtom.com" not in u}
    for url in sorted(primaries):
        want = f"200 {expected[url]}"
        if expected[url] and new["urls"][url] != want:
            problems.append(f"`{url}` answers `{new['urls'][url]}`, expected `{want}`.")

    # Keep the last good tracker data when the tracker could not be read,
    # so the next successful run doesn't report everything as new.
    for key in ("changelog", "tracker_files"):
        if not new[key]:
            new[key] = old.get(key, [])

    report = []
    if old:
        report += diff_lists("New in rui.saraiva's changelog (NAC_EUR_WAVE4)",
                             old.get("changelog", []), new["changelog"], code=False)
        report += diff_lists("Files on the tracker's Wave 4 page", old.get("tracker_files", []), new["tracker_files"])
        changed = [u for u in new["urls"] if old.get("urls", {}).get(u) not in (None, new["urls"][u])]
        if changed:
            report.append("### Download URLs in our scripts\n")
            report += [f"- `{u}`: `{old['urls'][u]}` → `{new['urls'][u]}`" for u in changed]
            report.append("")
    if problems:
        report.append("### Problems\n")
        report += [f"- {p}" for p in problems]
        report.append("")

    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(new, f, indent=2, sort_keys=True)
        f.write("\n")

    if report:
        report += [
            "---",
            f"Sources: [Wave 4 page]({TRACKER_PAGE}) · [changelog]({CHANGELOG_PAGE})",
            "",
            "Check whether the scripts need a new version, URL or expected size. "
            "Opened automatically by the weekly update watch.",
        ]
        with open(report_path, "w", encoding="utf-8") as f:
            f.write("\n".join(report) + "\n")
        print("\n".join(report))
    else:
        print("No changes." if old else "Baseline saved, nothing to compare with yet.")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
