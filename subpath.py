"""Make RomM's frontend work under a URL prefix such as /romm.

RomM has no base-path setting: the frontend hardcodes root-absolute paths
(/api, /assets, /ws, ...) and the router assumes it lives at /. This script
fixes that in two passes:

  src  <frontend_dir> <prefix>   before `vite build --base <prefix>/`
       Targeted source edits for things a bundle rewrite can't tell apart
       (router base, router paths used for full-page navigation or links).
  dist <dist_dir> <prefix>       after the build
       Prefixes every string literal / CSS url() that starts with a server
       path, then regenerates the .gz siblings nginx serves.

Every rule reports how many spots it changed. Required rules that match
nothing abort the install, so an upstream change can't silently break it.
"""

import gzip
import pathlib
import re
import sys

SERVER_PATHS = r"(?:api|assets|ws|netplay|openapi\.json)"


def fail(msg):
    sys.exit(f"subpath: {msg}")


def src_pass(root: pathlib.Path, prefix: str):
    src = root / "src"
    files = [
        p
        for p in src.rglob("*")
        if p.suffix in (".ts", ".vue")
        and ".test." not in p.name
        and "__generated__" not in p.parts
    ]
    totals = {}

    def apply(name, pattern, repl, required=False, only=None):
        n_total = 0
        rx = re.compile(pattern)
        for p in files:
            if only and not str(p).endswith(only):
                continue
            s = p.read_text()
            new, n = rx.subn(repl, s)
            if n:
                p.write_text(new)
                n_total += n
        totals[name] = n_total
        if required and n_total == 0:
            fail(f"required source rule '{name}' matched nothing (upstream changed)")

    # 1. Router history base: process.env is defined as {} in vite.config, so
    #    this was always "/". import.meta.env.BASE_URL follows --base.
    apply(
        "router base",
        r"createWebHistory\(process\.env\.BASE_URL\)",
        "createWebHistory(import.meta.env.BASE_URL)",
        required=True,
        only="plugins/router.ts",
    )

    # 2. Absolute links built from the origin (pair/invite/share links, EJS
    #    background): `${window.location.origin}/x` -> `${...origin}/romm/x`.
    #    `${origin}${path}` is left alone, since `path` is a server path that
    #    the dist pass already prefixes.
    apply(
        "origin template links",
        r"\$\{window\.location\.origin\}/",
        lambda m: "${window.location.origin}" + prefix + "/",
    )
    apply(
        "origin + router path",
        r"window\.location\.origin \+ `/",
        lambda m: "window.location.origin + `" + prefix + "/",
    )

    # 3. Leaving a player with a full-document load: path is a router path.
    apply(
        "player exit",
        r"window\.location\.replace\(path\);",
        "window.location.replace(router.resolve(path).href);",
        required=True,
        only="usePlayerExit/index.ts",
    )

    # 4. 401 handler resolves the browser path as a router path.
    js_prefix_rx = "/^" + prefix.replace("/", "\\/") + "(?=\\/|$)/"
    apply(
        "401 handler pathname",
        r"const pathname = window\.location\.pathname;",
        lambda m: f'const pathname = window.location.pathname.replace({js_prefix_rx}, "") || "/";',
        required=True,
        only="services/api/index.ts",
    )
    apply(
        "401 handler resolve",
        r"router\.resolve\(window\.location\.pathname\)",
        "router.resolve(pathname)",
        required=True,
        only="services/api/index.ts",
    )

    # 5. Plain <a href> to router routes in templates (server paths are left
    #    to the dist pass).
    apply(
        "template href to routes",
        r'(\s:?href=")(`?)/(?!' + SERVER_PATHS + r"\b)",
        lambda m: f"{m.group(1)}{m.group(2)}{prefix}/",
    )

    for k, v in totals.items():
        print(f"  src  {v:4d}  {k}")


def dist_pass(root: pathlib.Path, prefix: str):
    # A quote/backtick, or CSS url(, followed by a server path.
    rx = re.compile(r"""(["'`]|url\()/(""" + SERVER_PATHS + r""")(?=[/"'`?#)\s]|$)""")
    manifest_rx = re.compile(r'"/(?!' + re.escape(prefix.strip("/")) + r"/)")
    changed = total = 0
    for p in root.rglob("*"):
        if not p.is_file() or p.suffix not in (".js", ".mjs", ".css", ".html", ".json", ".webmanifest"):
            continue
        s = p.read_text(encoding="utf-8", errors="surrogateescape")
        new, n = rx.subn(lambda m: f"{m.group(1)}{prefix}/{m.group(2)}", s)
        if p.suffix == ".html":
            # root-absolute href/src the build left alone (e.g. files missing from public/)
            new, n2 = re.subn(r'((?:href|src)=")/(?!' + re.escape(prefix.strip("/")) + r"/)", rf"\g<1>{prefix}/", new)
            n += n2
        if p.suffix == ".webmanifest":
            new, n2 = manifest_rx.subn(f'"{prefix}/', new)
            n += n2
        if not n:
            continue
        p.write_text(new, encoding="utf-8", errors="surrogateescape")
        changed += 1
        total += n
        gz = p.with_name(p.name + ".gz")
        if gz.exists():
            gz.write_bytes(gzip.compress(new.encode("utf-8", "surrogateescape"), 9))
    if total == 0:
        fail("dist rewrite matched nothing (upstream changed)")
    print(f"  dist {total:4d}  server paths prefixed in {changed} files")

    index = (root / "index.html").read_text()
    if f'src="{prefix}/assets/' not in index:
        fail("index.html doesn't load its bundle from the prefix; was --base passed?")


if __name__ == "__main__":
    mode, path, prefix = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3].rstrip("/")
    if not prefix.startswith("/"):
        fail("prefix must start with /")
    {"src": src_pass, "dist": dist_pass}[mode](path, prefix)
