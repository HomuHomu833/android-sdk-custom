"""The slice of Soong's module model needed to lower cc modules to CMake.

Loading: every Android.bp under the mapped source trees (plus the overlay .bp
files) is evaluated into Modules. Resolution for one (os, arch) then follows
Soong's own order:

  1. soong_config_module_type instances pick their soong_config_variables,
  2. defaults are gathered depth-first and each one prepended (defaults.go),
  3. target.* and arch.* are merged in the order of arch.go's
     setOSProperties/getArchProperties, honouring variant_prepend,
  4. overlay `amend` modules are merged on top, and exclude_* lists applied.
"""

import copy
import fnmatch
import os
import re
import sys

from .blueprint import BlueprintError, Evaluator, Module, parse_file

# --- os / arch axes ----------------------------------------------------------


class OsType:
    """An entry of Soong's OS axis, plus the BSD hosts Soong has no notion of."""

    def __init__(self, name, host=True, linux=False, bionic=False, windows=False, extra=()):
        self.name, self.host, self.linux = name, host, linux
        self.bionic, self.windows = bionic, windows
        self.extra = tuple(extra)  # extra target.<x> keys (non-Soong, e.g. bsd)

    def target_keys(self):
        """target.<key> structs merged for this OS, in setOSProperties order."""
        keys = []
        if self.host:
            keys.append("host")
        if self.linux:
            keys.append("linux")
        if self.linux and self.host:
            keys.append("host_linux")
        if self.bionic:
            keys.append("bionic")
        if self.name == "linux_glibc":
            keys.append("glibc")
        if self.name == "linux_musl":
            keys.append("musl")
        keys.extend(self.extra)
        keys.append(self.name)
        if self.host and not self.windows:
            keys.append("not_windows")
        if not self.host:
            keys.append("android64")  # resolved per arch below
        return keys

    def arch_target_keys(self, arch):
        keys = []
        if self.linux:
            keys.append("linux_" + arch)
        if self.bionic:
            keys.append("bionic_" + arch)
        keys.extend(e + "_" + arch for e in self.extra)
        keys.append(self.name + "_" + arch)
        if self.name == "linux_glibc":
            keys.append("glibc_" + arch)
        if self.name == "linux_musl":
            keys.append("musl_" + arch)
        return keys


OS_TYPES = {
    "linux_glibc": OsType("linux_glibc", linux=True),
    "linux_musl": OsType("linux_musl", linux=True),
    "linux_bionic": OsType("linux_bionic", linux=True, bionic=True),
    "android": OsType("android", host=False, linux=True, bionic=True),
    "darwin": OsType("darwin"),
    "windows": OsType("windows", windows=True),
    "freebsd": OsType("freebsd", extra=("bsd",)),
    "netbsd": OsType("netbsd", extra=("bsd",)),
    "openbsd": OsType("openbsd", extra=("bsd",)),
}

def soong_target(platform, triple):
    """(os, arch) for one of build.sh's PLATFORM/TARGET pairs.

    Little-endian arm/arm64/x86/x86_64/riscv64 map onto Soong's arches, so
    their arch.* sources (assembly, SIMD) are used. Everything Soong has never
    built for keeps its own name: no upstream arch struct matches it, which
    leaves the portable C paths, and overlays can still key on it.
    """
    parts = triple.split("-")
    cpu = parts[0]
    if platform == "bionic":
        os_name = "linux_bionic"
    elif platform == "macos":
        os_name = "darwin"
    elif platform == "windows":
        os_name = "windows"
    elif platform == "bsd":
        os_name = parts[1]
    elif platform == "linux":
        os_name = "linux_musl" if "musl" in triple else "linux_glibc"
    else:
        raise ValueError("unknown platform %s" % platform)
    if os_name not in OS_TYPES:
        raise ValueError("unknown os %s (from %s)" % (os_name, triple))
    abi = parts[-1]
    if cpu in ("aarch64", "arm64", "arm64e"):
        arch = "arm64"
    elif cpu == "x86_64" and abi.endswith("x32"):
        arch = "x32"
    elif cpu in ("x86_64", "x86_64h"):
        arch = "x86_64"
    elif cpu in ("x86", "i386", "i686"):
        arch = "x86"
    elif cpu in ("arm", "armv7a", "armv7", "thumb"):
        arch = "arm"
    elif cpu == "riscv64":
        arch = "riscv64"
    else:
        arch = cpu  # arm64ec, armeb, aarch64_be, mips*, powerpc*, s390x, ...
    return os_name, arch


# Soong's arch names; anything else (mips, powerpc, ...) is passed through so
# overlays can still key on it, but no upstream arch struct will match.
SOONG_ARCHES = {"arm", "arm64", "riscv64", "x86", "x86_64"}
LP64_ARCHES = {"arm64", "x86_64", "riscv64", "mips64", "powerpc64", "s390x", "loongarch64"}

# Properties tagged `variant_prepend` in cc/compiler.go, linker.go, library.go:
# arch/target values for these go in front of the base value, not after it.
VARIANT_PREPEND = {
    "include_dirs", "local_include_dirs", "generated_headers", "static_libs",
    "header_libs", "whole_static_libs", "export_header_lib_headers",
    "export_include_dirs", "export_system_include_dirs",
}

# Keys holding per-variant structs; stripped from the flattened result.
VARIANT_KEYS = ("target", "arch", "multilib", "codegen", "product_variables")

CC_TYPES = {
    "cc_library": "library",
    "cc_library_static": "static",
    "cc_library_host_static": "static",
    "cc_library_shared": "static",
    "cc_library_host_shared": "static",
    "cc_library_headers": "headers",
    "cc_binary": "binary",
    "cc_binary_host": "binary",
    "cc_object": "object",
    "cc_prebuilt_library_static": "prebuilt",
    "cc_prebuilt_library": "prebuilt",
    # art/build/art.go wraps the cc types; its Go hooks are re-expressed in
    # the overlay (see overlay/art.bp).
    "art_cc_library": "library",
    "art_cc_library_static": "static",
    "art_cc_binary": "binary",
}
DEFAULTS_TYPES = {
    "cc_defaults", "art_cc_defaults", "art_global_defaults", "art_debug_defaults",
    "genrule_defaults", "java_defaults", "rust_defaults", "python_defaults", "defaults",
}
GEN_TYPES = {"genrule", "gensrcs", "cc_genrule"}


class ResolveError(Exception):
    pass


# --- property merging --------------------------------------------------------


def _merge(dst, src, mode, prepend_keys=()):
    """Merge src into dst (both dicts) and return the result.

    mode "append": lists extend, scalars from src win (AppendProperties).
    mode "prepend": lists are src+dst, scalars already in dst win
    (PrependProperties, used for defaults). Keys in prepend_keys always use
    list-prepend semantics (variant_prepend).
    """
    out = dict(dst)
    for k, v in src.items():
        if k not in out:
            out[k] = copy.deepcopy(v)
            continue
        cur = out[k]
        if isinstance(cur, dict) and isinstance(v, dict):
            out[k] = _merge(cur, v, mode, prepend_keys)
        elif isinstance(cur, list) and isinstance(v, list):
            if mode == "prepend" or k in prepend_keys:
                out[k] = copy.deepcopy(v) + cur
            else:
                out[k] = cur + copy.deepcopy(v)
        elif mode == "append":
            out[k] = copy.deepcopy(v)
        # prepend mode: keep dst's scalar
    return out


def _alias_targets(target, alias):
    """Apply an amend's target_alias ({to: from}) to one module's target map.

    target.<from> is appended to target.<to>, and each target.<from>_<arch>
    to target.<to>_<arch>, so an OS Soong lacks takes that module's settings
    for an OS it has (target_alias: { bsd: "linux" }).
    """
    out = dict(target)
    for to, frm in alias.items():
        for k, v in target.items():
            if k == frm:
                key = to
            elif k.startswith(frm + "_") and k[len(frm) + 1:] in SOONG_ARCHES:
                key = to + k[len(frm):]
            else:
                continue
            out[key] = _merge(out.get(key) or {}, v, "append")
    return out


# --- source tree -------------------------------------------------------------


class Tree:
    """Maps AOSP tree paths (system/core/...) to local directories.

    Local checkouts need not mirror AOSP's layout (this repo keeps them flat
    under src/), so every tree-root-relative path in Android.bp goes through
    here. Paths outside every mapped project fall back to the repo root, which
    is how overlays reach this repo's own include/ and patches/.
    """

    def __init__(self, root, projects):
        self.root = os.path.abspath(root)
        # longest prefix first so nested projects (build/soong in build/make) win
        self.projects = sorted(
            ((a.strip("/"), os.path.abspath(l)) for a, l in projects),
            key=lambda p: -len(p[0]))

    def to_local(self, aosp_path):
        p = aosp_path.strip("/")
        for a, l in self.projects:
            if p == a:
                return l
            if p.startswith(a + "/"):
                return os.path.join(l, p[len(a) + 1:])
        cand = os.path.join(self.root, p)
        return cand if os.path.exists(cand) else None

    def to_aosp(self, local_path):
        lp = os.path.abspath(local_path)
        for a, l in self.projects:
            if lp == l:
                return a
            if lp.startswith(l + os.sep):
                return a + "/" + os.path.relpath(lp, l).replace(os.sep, "/")
        return None


# --- loading -----------------------------------------------------------------


class Loader:
    def __init__(self, tree, select_config, overlay_files=(), warn=None):
        self.tree = tree
        self.ev = Evaluator(select_config)
        self.cfg = select_config
        self.warn = warn or (lambda m: print("warning: " + m, file=sys.stderr))
        self.modules = {}          # name -> [Module]
        self.namespaces = {}       # aosp dir -> True (soong_namespace roots)
        self.config_types = {}     # soong_config_module_type name -> props
        self.amends = {}           # name -> [Module] (overlay amendments)
        self.overlay = {}          # name -> Module (overlay replacements)
        self.sdk_tools = []        # overlay sdk_tools modules
        self.errors = {}           # module name -> error text
        self._scopes = {}          # aosp dir -> scope dict
        self._imported = set()     # files read by soong_config_module_type_import
        # Soong config values an AOSP source build has (overlay
        # soong_config_values modules) must be known before any select() or
        # soong_config_variables is evaluated; values given on the command line win.
        for f in overlay_files:
            self._preload_config_values(f)
        for _, local in tree.projects:
            self._load_project(local)
        for f in overlay_files:
            self._load_overlay(f)

    # -- files

    def _load_project(self, local_root):
        files = []
        for dp, dns, fns in os.walk(local_root):
            dns[:] = sorted(d for d in dns if not d.startswith(".") and d != "out")
            if "Android.bp" in fns:
                files.append(os.path.join(dp, "Android.bp"))
        files.sort(key=lambda f: f.count(os.sep))
        for f in files:
            self._load_file(f)

    def _preload_config_values(self, path):
        for d in parse_file(path):
            if d[0] == "module" and d[1] == "soong_config_values":
                props = self.ev.eval(("map", d[2]), [{}], path)
                for ns, values in props.items():
                    if isinstance(values, dict):
                        for var, val in values.items():
                            self.cfg.variables.setdefault("%s:%s" % (ns, var), val)

    def _import_config_types(self, m):
        """soong_config_module_type_import: read the soong_config_module_type
        definitions of another file, which Soong does not load on its own."""
        path = self.tree.to_local(m.props.get("from", ""))
        if not path or path in self._imported or not os.path.isfile(path):
            return
        self._imported.add(path)
        try:
            defs = parse_file(path)
        except BlueprintError as e:
            self.warn(str(e))
            return
        for d in defs:
            if d[0] == "module" and d[1] == "soong_config_module_type":
                props = self.ev.eval(("map", d[2]), [{}], path)
                self.config_types[props["name"]] = props

    def _parent_scope(self, aosp_dir):
        d = aosp_dir
        while d:
            d = os.path.dirname(d) if "/" in d else ""
            if d in self._scopes:
                return self._scopes[d]
        return self._scopes.get("", [])

    def _load_file(self, path, scope=None, overlay=False):
        aosp_dir = self.tree.to_aosp(os.path.dirname(path)) if not overlay else ""
        if aosp_dir is None:
            aosp_dir = ""
        try:
            defs = parse_file(path)
        except BlueprintError as e:
            self.warn(str(e))
            return
        if scope is None:
            scope = [{}] + list(self._parent_scope(aosp_dir))
            if not overlay:
                self._scopes[aosp_dir] = scope
        local = scope[0]
        for d in defs:
            if d[0] == "assign":
                _, name, expr, append, line = d
                where = "%s:%d" % (path, line)
                try:
                    val = self.ev.eval(expr, scope, where)
                except BlueprintError as e:
                    self.warn(str(e))
                    continue
                if append:
                    if name not in local:
                        self.warn("%s: += to variable %s not defined in this file" % (where, name))
                        continue
                    local[name] = local[name] + val
                else:
                    local[name] = val
                if name == "build" and not overlay:
                    for extra in val:
                        self._load_file(os.path.join(os.path.dirname(path), extra), scope)
                continue
            _, mtype, props, line = d
            where = "%s:%d" % (path, line)
            try:
                pv = self.ev.eval(("map", props), scope, where)
            except BlueprintError as e:
                name = next((ev[1] for k, ev in props if k == "name" and ev[0] == "lit"), None)
                if name:
                    self.errors[name] = str(e)
                continue
            self._add_module(Module(mtype, pv, path, line), aosp_dir, overlay)

    def _load_overlay(self, path):
        # Overlay modules live at the repo root: their relative paths resolve
        # against it, and they may reference upstream modules by name.
        self._load_file(path, scope=[{}], overlay=True)

    def _add_module(self, m, aosp_dir, overlay):
        m.aosp_dir = aosp_dir
        m.overlay = overlay
        t = m.type
        if t == "soong_namespace":
            self.namespaces[aosp_dir] = True
            return
        if t == "soong_config_module_type":
            self.config_types[m.name] = m.props
            return
        if t == "soong_config_module_type_import":
            self._import_config_types(m)
            return
        if t == "soong_config_values":
            return
        if overlay and t == "amend":
            self.amends.setdefault(m.name, []).append(m)
            return
        if overlay and t == "sdk_tools":
            self.sdk_tools.append(m)
            return
        if not m.name:
            return
        if t in ("ndk_library", "llndk_library", "ndk_headers"):
            # Soong registers these under a suffixed name (ndk_library.go)
            m.props = dict(m.props, name=m.name + ".ndk")
        m.namespace = self._namespace_of(aosp_dir) if not overlay else None
        if overlay:
            self.overlay[m.name] = m
        self.modules.setdefault(m.name, []).append(m)

    def _namespace_of(self, aosp_dir):
        d = aosp_dir
        while True:
            if d in self.namespaces:
                return d
            if not d:
                return None
            d = os.path.dirname(d)

    # -- lookup

    def lookup(self, name, frm=None):
        """Find module `name` as seen from module `frm` (namespace aware)."""
        if name in self.overlay:
            return self.overlay[name]
        if name.startswith("//"):
            path, _, name = name[2:].partition(":")
            cands = [m for m in self.modules.get(name, []) if m.aosp_dir == path]
        else:
            cands = self.modules.get(name, [])
        if not cands:
            if name in self.errors:
                raise ResolveError("module %s failed to evaluate: %s" % (name, self.errors[name]))
            raise ResolveError("unknown module %s%s" % (name, " (needed by %s)" % frm.name if frm else ""))
        if len(cands) == 1:
            return cands[0]
        ns = frm.namespace if frm is not None else None
        same = [m for m in cands if m.namespace == ns]
        if len(same) == 1:
            return same[0]
        root = [m for m in cands if m.namespace is None]
        if len(root) == 1:
            return root[0]
        raise ResolveError("ambiguous module %s: %s" % (name, ", ".join(repr(c) for c in cands)))

    # -- resolution

    def base_type(self, m):
        t = m.type
        seen = set()
        while t in self.config_types and t not in seen:
            seen.add(t)
            t = self.config_types[t].get("module_type", t)
        return t

    def _apply_soong_config(self, m, props):
        if m.type not in self.config_types:
            return props
        ct = self.config_types[m.type]
        ns = ct.get("config_namespace", "")
        scv = props.pop("soong_config_variables", {}) or {}
        bools = set(ct.get("bool_variables", []))
        for var, branches in scv.items():
            val = self.cfg.variables.get("%s:%s" % (ns, var))
            if var in bools:
                chosen = ({k: v for k, v in branches.items() if k != "conditions_default"}
                          if val in (True, "true") else branches.get("conditions_default", {}))
            elif val is not None and isinstance(branches.get(val), dict):
                chosen = branches[val]
            else:
                chosen = branches.get("conditions_default", {})
            props = _merge(props, chosen, "append", VARIANT_PREPEND)
        return props

    def _amended(self, m):
        """m's own props with its soong_config choices and overlay amends."""
        props = self._apply_soong_config(m, copy.deepcopy(m.props))
        for a in self.amends.get(m.name, []):
            extra = copy.deepcopy(a.props)
            extra.pop("name", None)
            props = _merge(props, extra, "append")
        alias = props.pop("target_alias", None)
        if alias:
            props["target"] = _alias_targets(props.get("target") or {}, alias)
        return props

    def _with_defaults(self, m):
        props = self._amended(m)
        names = props.get("defaults", [])
        if not names:
            return props
        # walkDeps order: pre-order DFS over `defaults`, each visited once.
        order, seen = [], set()

        def walk(names, frm):
            for n in names:
                d = self.lookup(n, frm)
                if id(d) in seen:
                    continue
                seen.add(id(d))
                order.append(d)
                walk(d.props.get("defaults", []), d)
        walk(names, m)
        for d in order:
            dp = self._amended(d)
            dp.pop("name", None)
            dp.pop("defaults", None)
            dp.pop("visibility", None)
            props = _merge(props, dp, "prepend")
        return props

    def flatten(self, m, os_type, arch, arch_features=()):
        """Fully resolved props of module m for one (os, arch) variant."""
        props = self._with_defaults(m)
        base = {k: v for k, v in props.items() if k not in VARIANT_KEYS}
        target = props.get("target", {}) or {}
        archp = props.get("arch", {}) or {}
        multilib = props.get("multilib", {}) or {}

        def merge_in(struct):
            nonlocal base
            if isinstance(struct, dict):
                s = {k: v for k, v in struct.items() if not isinstance(v, dict) or k not in arch_features}
                base = _merge(base, s, "append", VARIANT_PREPEND)

        for key in os_type.target_keys():
            if key == "android64":
                key = "android64" if arch in LP64_ARCHES else "android32"
            merge_in(target.get(key))
        a = archp.get(arch)
        merge_in(a)
        if isinstance(a, dict):
            for f in arch_features:
                merge_in(a.get(f))
        merge_in(multilib.get("lib64" if arch in LP64_ARCHES else "lib32"))
        for key in os_type.arch_target_keys(arch):
            merge_in(target.get(key))
        return base


# --- globbing ----------------------------------------------------------------

_glob_cache = {}


def _glob_re(pattern):
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        else:
            c = pattern[i]
            out.append("[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def glob(base, pattern):
    """Soong-style glob of `pattern` (relative, may contain **) under base."""
    if not any(c in pattern for c in "*?"):
        return [os.path.join(base, pattern)]
    fixed = pattern.split("*")[0].split("?")[0]
    fixed = fixed[:fixed.rfind("/") + 1]
    start = os.path.join(base, fixed)
    key = (start, pattern)
    if key not in _glob_cache:
        rx = _glob_re(pattern)
        hits = []
        for dp, dns, fns in os.walk(start):
            dns[:] = sorted(d for d in dns if not d.startswith("."))
            for fn in sorted(fns):
                full = os.path.join(dp, fn)
                rel = os.path.relpath(full, base).replace(os.sep, "/")
                if rx.match(rel):
                    hits.append(full)
        _glob_cache[key] = hits
    return list(_glob_cache[key])


def match_exclude(path, base, patterns):
    rel = os.path.relpath(path, base).replace(os.sep, "/")
    for p in patterns:
        if p == rel or ("*" in p and (_glob_re(p).match(rel) or fnmatch.fnmatch(rel, p))):
            return True
    return False
