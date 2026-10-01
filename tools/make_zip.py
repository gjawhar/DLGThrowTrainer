"""Builds the release ZIP in the shape FrSky Suite's Lua installer requires,
from the files of a git tag (default: the latest tag), so the ZIP is exactly
the released code.

    python3 tools/make_zip.py              # latest tag -> ~/Downloads/ThrowTrainer-v<version>.zip
    python3 tools/make_zip.py v1.2.3       # a specific tag
    python3 tools/make_zip.py HEAD 1.2.4   # any ref, with an explicit version

Rules, read out of FrSky Suite 2.0.1's own installer code (2026-09-30):
- `ethos_lua_manifest.json` must sit at the ZIP ROOT, or it refuses with
  "No ethos_lua_manifest.json found at zip root."
- manifestVersion must be the number 1; name <= 128 chars; key matches
  ^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$; version parses as a version number;
  folder matches ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$.
- files: non-empty list of relative paths inside the ZIP ("*" globs within a
  segment, "**" as a whole segment). Every non-glob entry must exist, every
  glob must match something, and main.lua (or main.luac) must be among them.
- Install target is scripts/<folder>/<path>, where a leading "<folder>/" is
  stripped from each path. So the app folder goes at the ZIP root, NOT under
  "scripts/". Only the listed files are written and nothing is deleted, so an
  upgrade never touches the pilot's data. Never list a data file.
"""
import json, os, re, subprocess, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
FOLDER, KEY, NAME, PREFIX = "ThrowTrn", "thrwtrn", "Throw Trainer", "ThrowTrainer"
INTRO = "DLG launch-height training assistant: logs every throw and shows whether a setup change (camber, trim, ballast, rudder offset) actually helped or was just throw-to-throw noise. Needs Mike Shellim's DLG for Ethos template and an Altitude sensor."
RELEASES = "https://github.com/gjawhar/DLGThrowTrainer/releases"
MANIFEST = "ethos_lua_manifest.json"

def git(*args, binary=False):
    out = subprocess.run(["git", "-C", ROOT] + list(args), check=True, capture_output=True).stdout
    return out if binary else out.decode("utf-8").strip()

def validate(m, names):
    """The same checks FrSky Suite makes. Returns a list of problems (empty = installable)."""
    bad = []
    if m.get("manifestVersion") != 1: bad.append("manifestVersion must be the number 1")
    if not (isinstance(m.get("name"), str) and 0 < len(m["name"].strip()) and len(m["name"]) <= 128): bad.append("name")
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$", str(m.get("key", "")).strip()): bad.append("key")
    if not re.match(r"^\d+(\.\d+){0,3}$", str(m.get("version", ""))): bad.append("version")
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$", str(m.get("folder", ""))): bad.append("folder")
    if len(m.get("introduction", "")) > 1024: bad.append("introduction longer than 1024")
    files = m.get("files")
    if not (isinstance(files, list) and files): return bad + ["files must be a non-empty list"]
    entries = [n for n in names if not n.endswith("/") and n.split("/")[-1].lower() != MANIFEST]
    lower = {n.lower() for n in entries}
    matched = []
    for f in files:
        if f.startswith("/") or ".." in f.split("/") or "" in f.split("/"): bad.append("unsafe path " + f); continue
        if "*" not in f:
            if f.lower() not in lower: bad.append("listed file missing from the ZIP: " + f)
            else: matched.append(f)
            continue
        rx = "^" + "/".join(".*" if seg == "**" else re.escape(seg).replace(r"\*", "[^/]*") for seg in f.split("/")) + "$"
        hits = [n for n in entries if re.match(rx, n, re.I)]
        if not hits: bad.append("glob matches nothing: " + f)
        matched += hits
    if not any(n.split("/")[-1].lower() in ("main.lua", "main.luac") for n in matched): bad.append("main.lua not among the files")
    if MANIFEST not in names: bad.append(MANIFEST + " is not at the ZIP root")
    if any(n.lower().endswith(".csv") for n in entries): bad.append("a data file (.csv) is in the ZIP")
    return bad

def build(ref=None, version=None, out=None):
    ref = ref or git("describe", "--tags", "--abbrev=0")
    version = version or ref.lstrip("v")
    files = [f for f in git("ls-tree", "-r", "--name-only", ref, "--", FOLDER).splitlines() if f]
    m = {"manifestVersion": 1, "name": NAME, "key": KEY, "version": version, "folder": FOLDER, "files": files,
         "introduction": INTRO,
         "releaseNotes": {"format": "markdown", "content": "See " + RELEASES + " for what changed in " + version + "."}}
    out = out or os.path.expanduser("~/Downloads/%s-v%s.zip" % (PREFIX, version))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(MANIFEST, json.dumps(m, indent=2) + "\n")
        for f in files:
            z.writestr(f, git("show", ref + ":" + f, binary=True))
    names = zipfile.ZipFile(out).namelist()
    return out, ref, names, validate(json.loads(zipfile.ZipFile(out).read(MANIFEST)), names)

if __name__ == "__main__":
    a = sys.argv[1:]
    out, ref, names, problems = build(a[0] if a else None, a[1] if len(a) > 1 else None)
    print("%s  (built from %s)" % (out, ref))
    for n in names: print("  ", n)
    print("FrSky Suite manifest check:", "OK, installable" if not problems else "PROBLEMS: " + "; ".join(problems))
    sys.exit(1 if problems else 0)
