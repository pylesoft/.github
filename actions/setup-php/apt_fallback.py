"""Use the Azure Ubuntu mirror when an official archive is unreachable."""

import pathlib
import re
import subprocess

ARCHIVE = re.compile(r"https?://(?:archive|security)\.ubuntu\.com/ubuntu(?=[/\s]|$)")
MIRROR = "http://azure.archive.ubuntu.com/ubuntu"


def reachable(url):
    # ponytail: header probes miss slow package downloads; the caller timeout remains the backstop.
    return subprocess.run(
        ["curl", "--fail", "--silent", "--show-error", "--head",
         "--connect-timeout", "3", "--max-time", "5", url],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=7,
        check=False,
    ).returncode == 0


def use_fallback(files, codename, probe=reachable):
    contents = {path: path.read_text() for path in files if path.is_file()}
    sources = sorted({url for text in contents.values() for url in ARCHIVE.findall(text)})
    unavailable = [url for url in sources if not probe(f"{url}/dists/{codename}-security/InRelease")]
    if not unavailable:
        return False
    if not probe(f"{MIRROR}/dists/{codename}-security/InRelease"):
        print("::warning::Ubuntu archive and Azure fallback are unreachable; keeping existing sources.", flush=True)
        return False
    for path, text in contents.items():
        updated = ARCHIVE.sub(lambda match: MIRROR if match[0] in unavailable else match[0], text)
        if updated != text:
            path.write_text(updated)
    print(f"::warning::Using Azure Ubuntu mirror for {', '.join(unavailable)}.", flush=True)
    return True


if __name__ == "__main__":
    release = dict(line.split("=", 1) for line in pathlib.Path("/etc/os-release").read_text().splitlines() if "=" in line)
    if release.get("ID", "").strip('"') == "ubuntu":
        codename = release["VERSION_CODENAME"].strip('"')
        apt = pathlib.Path("/etc/apt")
        files = [apt / "sources.list", *(apt / "sources.list.d").glob("*.list"), *(apt / "sources.list.d").glob("*.sources")]
        if use_fallback(files, codename):
            # Refresh signed indexes; never disable APT signature or expiry checks.
            subprocess.run(["apt-get", "update", "-o", "Acquire::Retries=0",
                            "-o", "Acquire::http::Timeout=10", "-o", "Acquire::https::Timeout=10",
                            "-o", "APT::Update::Error-Mode=any"], check=True, timeout=90)
