"""builder: generate a CMake build of the SDK host tools from Android.bp.

    python3 -m builder --os linux_musl --arch x86_64 --out build/generated

reads repos.json (which local checkout is which AOSP project), every Android.bp
under those checkouts and the overlay .bp files next to this package, then
writes <out>/CMakeLists.txt plus <out>/aosp (a symlink farm with AOSP's layout)
and <out>/gen (codegen scripts/outputs). Configure it with plain CMake.
"""

import argparse
import glob as _glob
import json
import os
import sys

from .blueprint import SelectConfig
from .cmake import Emitter
from .convert import GLOBAL_INCLUDES, Converter
from .soong import OS_TYPES, Loader, ResolveError, Tree, soong_target

HERE = os.path.dirname(os.path.abspath(__file__))
GLOBAL_DEFAULTS = "builder_defaults"


def parse_var(s):
    k, _, v = s.partition("=")
    if v in ("true", "false"):
        return k, v == "true"
    return k, v


def make_link(src, dst):
    if os.path.lexists(dst):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    try:
        os.symlink(src, dst, target_is_directory=True)
    except OSError:
        if os.name != "nt":
            raise
        import _winapi  # junctions need no privilege on Windows
        _winapi.CreateJunction(src, dst)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="builder", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".", help="repo root holding repos.json (default: .)")
    ap.add_argument("--repos", help="project map (default: <root>/repos.json)")
    ap.add_argument("--overlay", action="append", default=[],
                    help="extra overlay .bp file or dir, read after builder/overlay")
    ap.add_argument("--platform", help="build.sh PLATFORM (linux|bionic|macos|windows|bsd)")
    ap.add_argument("--triple", help="build.sh TARGET triple; with --platform, picks --os/--arch")
    ap.add_argument("--os", choices=sorted(OS_TYPES))
    ap.add_argument("--arch", help="Soong arch (arm, arm64, x86, x86_64, riscv64); others pass through")
    ap.add_argument("--arch-feature", action="append", default=[], help="e.g. neon")
    ap.add_argument("--var", action="append", default=[], type=parse_var,
                    help="select()/soong_config value, e.g. sdk:rust_mdns=true")
    ap.add_argument("--tools", help="comma-separated modules to build (default: the "
                                    "overlay's sdk_tools)")
    ap.add_argument("--out", required=True, help="output directory")
    args = ap.parse_args(argv)
    if args.platform and args.triple:
        os_name, arch = soong_target(args.platform, args.triple)
        args.os = args.os or os_name
        args.arch = args.arch or arch
    if not args.os or not args.arch:
        ap.error("give --os and --arch, or --platform and --triple")

    root = os.path.abspath(args.root)
    with open(args.repos or os.path.join(root, "repos.json")) as f:
        repos = json.load(f)
    projects = [(r["aosp"], os.path.join(root, r["path"])) for r in repos]
    # fetch-source.sh only clones what the release's manifest has
    present = [(a, l) for a, l in projects if os.path.isdir(l)]
    if not present:
        sys.exit("builder: no sources under %s (run scripts/fetch-source.sh)" % root)
    tree = Tree(root, present)

    overlays = []
    for o in [os.path.join(HERE, "overlay")] + args.overlay:
        overlays += sorted(_glob.glob(os.path.join(o, "*.bp"))) if os.path.isdir(o) else [o]

    os_type = OS_TYPES[args.os]
    variables = dict(args.var)
    variables.setdefault("sdk:os", args.os)
    loader = Loader(tree, SelectConfig(args.os, args.arch, variables), overlays)

    out = os.path.abspath(args.out)
    gen = os.path.join(out, "gen")
    os.makedirs(out, exist_ok=True)
    notes = []
    conv = Converter(loader, tree, os_type, args.arch, gen, args.arch_feature, log=notes.append)
    globals_ = {}
    if GLOBAL_DEFAULTS in loader.overlay:
        # Soong puts its global flags ahead of every module's own; one
        # add_compile_options() says the same without repeating them per target.
        gp = loader.flatten(loader.overlay[GLOBAL_DEFAULTS], os_type, args.arch)
        from .convert import _clean_flags
        globals_ = {k: _clean_flags(gp.get(k, []))
                    for k in ("cflags", "cppflags", "conlyflags", "asflags", "ldflags")}
        globals_["ldlibs"] = conv._ldlibs(gp.get("host_ldlibs", []))
        conv.drop_flags = {k: set(gp.get("exclude_" + k, []))
                           for k in ("cflags", "cppflags", "conlyflags", "asflags")}

    if args.tools:
        tools = [t for t in args.tools.split(",") if t]
    else:
        tools = []
        for m in loader.sdk_tools:
            p = loader.flatten(m, os_type, args.arch)
            drop = set(p.get("exclude_tools", []))
            tools += [t for t in p.get("tools", []) if t not in drop]
    built = []
    try:
        for t in tools:
            try:
                m = loader.lookup(t)
            except ResolveError:
                if args.tools:
                    raise
                notes.append("note: %s does not exist in these sources; skipped" % t)
                continue
            if loader.flatten(m, os_type, args.arch).get("enabled") is False and not args.tools:
                notes.append("note: %s is disabled for %s upstream; skipped" % (t, args.os))
                continue
            built.append(conv.convert(t).name)
    except ResolveError as e:
        sys.exit("builder: %s" % e)

    needs = set()
    for t in conv.order:
        for g in t.gens:
            s = g.script if isinstance(g.script, list) else []
            if "${PROTOC}" in s:
                needs.add("protoc")
            if "${BISON}" in s:
                needs.add("bison")
            if "${FLEX}" in s:
                needs.add("flex")

    farm = os.path.join(out, "aosp")
    for a, l in tree.projects:
        make_link(l, os.path.join(farm, a))
    global_includes = ["${AOSP}/" + i for i in GLOBAL_INCLUDES if tree.to_local(i)
                       and os.path.isdir(tree.to_local(i))]

    text = Emitter(conv, built, root, global_includes, needs, globals_).render()
    with open(os.path.join(out, "CMakeLists.txt"), "w", newline="\n") as f:
        f.write(text)
    for n in dict.fromkeys(notes):
        print(n, file=sys.stderr)
    kinds = {}
    for t in conv.order:
        kinds[t.kind] = kinds.get(t.kind, 0) + 1
    print("builder: %s/%s: %d tools, %d modules (%s) -> %s" % (
        args.os, args.arch, len(built), len(conv.order),
        ", ".join("%d %s" % (v, k) for k, v in sorted(kinds.items())), out))


if __name__ == "__main__":
    main()
