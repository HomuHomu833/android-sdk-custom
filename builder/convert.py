"""Lower resolved Soong modules into CMake targets.

Everything below mirrors what Soong's cc package does for one module variant
(cc/compiler.go, cc/linker.go, cc/library.go, cc/proto.go, cc/gen.go and
genrule/genrule.go), reduced to what a static host-tool build needs: every
library is built static, shared_libs are linked statically, and there is no
APEX/VNDK/sanitizer machinery.

Paths are tracked as local filesystem paths while resolving and rendered as
${AOSP}/<tree path> (a symlink farm mirroring AOSP's layout), ${SDK}/<path>
for files of this repo, or ${GEN}/<module>/... for generated files.
"""

import os
import re
import shlex

from .soong import (CC_TYPES, DEFAULTS_TYPES, GEN_TYPES, VARIANT_PREPEND, ResolveError,
                    _merge, glob, match_exclude)

# Soong's cc/config global flags that carry meaning for the code being built.
# Hardening, debug-info and -Werror flags are toolchain policy, not semantics,
# and are left to the toolchain wrappers (build.sh) instead.
GLOBAL_INCLUDES = [
    "system/core/include", "system/logging/liblog/include", "system/media/audio/include",
    "hardware/libhardware/include", "hardware/libhardware_legacy/include",
    "hardware/ril/include", "frameworks/native/include", "frameworks/native/opengl/include",
    "frameworks/av/include",
]
EXTERNAL_CFLAGS = [
    "-Wno-enum-compare", "-Wno-enum-compare-switch", "-Wno-null-pointer-arithmetic",
    "-Wno-null-pointer-subtraction", "-Wno-string-concatenation",
    "-Wno-deprecated-non-prototype", "-Wno-unused", "-Wno-unused-but-set-variable",
    "-Wno-deprecated", "-Wno-tautological-constant-compare",
]
C_STD, CPP_STD = "gnu23", "gnu++20"
EXPERIMENTAL_C_STD, EXPERIMENTAL_CPP_STD = "gnu2y", "gnu++2b"

# host_ldlibs each host toolchain accepts (cc/config/*_host.go
# AvailableLibraries); anything else is dropped, as Soong rejects it.
AVAILABLE_LDLIBS = {
    "linux": {"c", "dl", "gcc", "gcc_s", "m", "ncurses", "pthread", "resolv", "rt", "util"},
    "bionic": {"c", "dl", "m", "log"},
    "darwin": {"c", "dl", "m", "ncurses", "objc", "pthread"},
    "windows": {"bcrypt", "dbghelp", "gdi32", "imagehlp", "iphlpapi", "netapi32", "ntdll",
                "oleaut32", "ole32", "opengl32", "powrprof", "psapi", "pthread", "ucrt",
                "userenv", "uuid", "version", "ws2_32", "windowscodecs",
                # llvm-mingw's USB/setup libs, used by the libusb windows backend
                "setupapi", "cfgmgr32", "winusb", "advapi32", "shell32", "wlanapi", "crypt32"},
    "bsd": {"c", "m", "pthread", "util", "execinfo", "kvm", "usb", "rt"},
}

# Libraries the toolchain itself provides; depending on them adds nothing.
SYSTEM_LIBS = {"libc", "libc++", "libc++_static", "libc++demangle", "libc++abi", "libm",
               "libdl", "libpthread", "libunwind", "libclang_rt.builtins", "libgcc",
               "libgcc_stripped", "libcompiler_rt-extras", "libatomic", "libdl_android",
               "libc_musl", "libc_musl_static"}

SRC_EXTS = {".c", ".cc", ".cpp", ".cxx", ".c++", ".S", ".s"}
HDR_EXTS = {".h", ".hh", ".hpp", ".hxx", ".inc", ".def", ".inl", ".ipp", ".tcc"}

_BAD_FLAG = re.compile(r"^(-Werror(=.*)?|-pedantic-errors|-Wl,--fatal-warnings)$")


def _clean_flags(flags, drop=None):
    drop = drop or ()
    return [f for f in flags if isinstance(f, str) and not _BAD_FLAG.match(f) and f not in drop]


def _target_name(name):
    return re.sub(r"[^A-Za-z0-9_.+-]", "_", name)


class GenRule:
    """One custom command (codegen step)."""

    def __init__(self, outputs, script, depends, comment, byproducts=()):
        self.outputs, self.script, self.depends = outputs, script, depends
        self.comment, self.byproducts = comment, list(byproducts)


class Target:
    def __init__(self, name, kind, module):
        self.name = _target_name(name)
        self.soong_name = name
        self.kind = kind  # static binary object headers prebuilt gen
        self.module = module
        self.srcs = []
        self.gens = []
        self.includes = []           # PRIVATE, in order
        self.export_includes = []    # PUBLIC
        self.export_system_includes = []
        self.cflags, self.cppflags, self.conlyflags, self.asflags = [], [], [], []
        self.c_std, self.cpp_std = C_STD, CPP_STD
        self.link = []               # (target, public, mode) mode: link|headers|whole
        self.objs = []               # cc_object targets
        self.ldflags, self.ldlibs = [], []
        self.output_name = None
        self.prebuilt = None
        self.outputs = []            # gen: every output
        self.interface_sources = []  # gen: header outputs generated_headers users depend on


class Converter:
    def __init__(self, loader, tree, os_type, arch, gen_dir, arch_features=(),
                 script_dir=None, log=print):
        self.L, self.tree, self.os, self.arch = loader, tree, os_type, arch
        self.features = tuple(arch_features)
        self.gen_dir = gen_dir          # absolute; ${GEN}
        self.script_dir = script_dir or os.path.join(gen_dir, ".scripts")
        self.drop_flags = {}            # prop -> flags removed from every module
        self.log = log
        self.targets = {}               # soong name -> Target
        self.order = []
        self._stack = []
        self.farm_roots = set()         # aosp project paths the build touches
        if os_type.windows:
            self.ldlib_family = "windows"
        elif os_type.name == "darwin":
            self.ldlib_family = "darwin"
        elif os_type.bionic:
            self.ldlib_family = "bionic"
        elif "bsd" in os_type.extra:
            self.ldlib_family = "bsd"
        else:
            self.ldlib_family = "linux"

    # -- paths

    def cm(self, path):
        """Render a local path for CMake."""
        if path.startswith("${"):
            return path
        if path.startswith(self.gen_dir + os.sep) or path == self.gen_dir:
            return "${GEN}" + path[len(self.gen_dir):].replace(os.sep, "/")
        a = self.tree.to_aosp(path)
        if a is not None:
            self._note_farm(a)
            return "${AOSP}/" + a
        rel = os.path.relpath(path, self.tree.root).replace(os.sep, "/")
        if rel.startswith("../"):
            return os.path.abspath(path).replace(os.sep, "/")  # e.g. a system library
        return "${SDK}/" + rel

    def tree_rel(self, path):
        """Path as seen from the AOSP farm root (cwd of codegen commands)."""
        if path.startswith(self.gen_dir):
            return path.replace(os.sep, "/")
        a = self.tree.to_aosp(path)
        if a is not None:
            self._note_farm(a)
            return a
        return os.path.abspath(path).replace(os.sep, "/")

    def _note_farm(self, aosp_path):
        for a, _ in self.tree.projects:
            if aosp_path == a or aosp_path.startswith(a + "/"):
                self.farm_roots.add(a)
                return

    def mod_dir(self, m):
        return self.tree.root if m.overlay else m.dir

    def root_path(self, p):
        """Tree-root-relative path (include_dirs) to a local path."""
        if p.startswith("${"):
            return p
        return self.tree.to_local(p)

    # -- entry points

    def convert(self, name, frm=None):
        """Target for module `name`. Static libraries may depend on each other
        in cycles, so a target is registered before its deps are walked and a
        cycle simply gets the (still filling) target back."""
        if name in self.targets:
            return self.targets[name]
        m = self.L.lookup(name, frm)
        if m.name in self.targets:  # reached through a //path:name alias
            self.targets[name] = self.targets[m.name]
            return self.targets[name]
        self._stack.append(m.name)
        try:
            t = self._convert(m)
        except ResolveError as e:
            if not str(e).startswith("while converting"):
                e = ResolveError("while converting %s: %s" % (" -> ".join(self._stack), e))
            raise e
        finally:
            self._stack.pop()
        self.targets[name] = t
        if t not in self.order:
            self.order.append(t)
        return t

    def _new(self, m, kind):
        t = Target(m.name, kind, m)
        self.targets[m.name] = t
        return t

    def _convert(self, m):
        btype = self.L.base_type(m)
        if btype == "filegroup":
            return self._filegroup(m)
        if btype in GEN_TYPES:
            return self._genrule(m, btype)
        if btype in CC_TYPES:
            return self._cc(m, CC_TYPES[btype])
        if btype in DEFAULTS_TYPES:
            raise ResolveError("%s is a defaults module, not a dependency" % m.name)
        raise ResolveError("module %s has unsupported type %s (%s); replace it in an overlay"
                           % (m.name, m.type, m.path))

    def props(self, m):
        p = self.L.flatten(m, self.os, self.arch, self.features)
        return self._apply_excludes(p)

    @staticmethod
    def _apply_excludes(p):
        for k in [k for k in p if k.startswith("exclude_") and k != "exclude_srcs"]:
            base = k[len("exclude_"):]
            if isinstance(p.get(base), list):
                drop = set(p[k])
                p[base] = [x for x in p[base] if x not in drop]
        for sub in ("static", "proto"):
            if isinstance(p.get(sub), dict):
                Converter._apply_excludes(p[sub])
        return p

    # -- sources

    def expand_srcs(self, m, srcs, excludes=(), objs=None):
        """Resolve srcs (globs, :module refs) to local paths / generated outputs.

        cc_object references are appended to `objs` when given (Soong allows
        them in srcs)."""
        base = self.mod_dir(m)
        out = []
        for s in srcs:
            if s.startswith(":") or s.startswith("//"):
                ref = s[1:] if s.startswith(":") else s
                tag = None
                if "{" in ref:
                    ref, tag = ref.split("{", 1)
                    tag = tag.rstrip("}")
                dep = self.convert(ref, m)
                if dep.kind == "filegroup":
                    out.extend(dep.srcs)
                elif dep.kind == "gen":
                    outs = dep.outputs
                    if tag:
                        outs = [o for o in outs if o.endswith("/" + tag.lstrip("."))
                                or o.endswith(tag)]
                    out.extend(outs)
                elif dep.kind == "object" and objs is not None:
                    objs.append(dep)
                else:
                    raise ResolveError("%s: srcs reference %s of kind %s" % (m.name, s, dep.kind))
                continue
            if s.startswith("${"):
                out.append(s)
                continue
            hits = glob(base, s)
            if any(c in s for c in "*?"):
                hits = [h for h in hits if os.path.isfile(h)]
            out.extend(os.path.normpath(h) for h in hits)
        if excludes:
            local_ex = [e for e in excludes if not e.startswith(":")]
            ex_mods = set()
            for e in excludes:
                if e.startswith(":"):
                    ex_mods.update(self.expand_srcs(m, [e]))
            out = [o for o in out if o not in ex_mods and
                   (o.startswith("${") or not match_exclude(o, base, local_ex))]
        seen, uniq = set(), []
        for o in out:
            if o not in seen:
                seen.add(o)
                uniq.append(o)
        return uniq

    # -- filegroup

    def _filegroup(self, m):
        p = self.props(m)
        t = self._new(m, "filegroup")
        t.srcs = self.expand_srcs(m, p.get("srcs", []), p.get("exclude_srcs", []))
        return t

    # -- genrule / gensrcs

    def _genrule(self, m, btype):
        p = self.props(m)
        t = self._new(m, "gen")
        gdir = os.path.join(self.gen_dir, t.name)
        srcs = self.expand_srcs(m, p.get("srcs", []), p.get("exclude_srcs", []))
        tool_files = self.expand_srcs(m, p.get("tool_files", []))
        tools = {}
        for tool in p.get("tools", []):
            tools[tool] = self._host_tool(m, tool)
            tool_files += tools[tool][1]
        cmd = p.get("cmd")
        if cmd is None:
            raise ResolveError("genrule %s has no cmd" % m.name)
        depends = [self.cm(s) if not s.startswith("${GEN}") else s for s in srcs + tool_files]
        if btype == "gensrcs":
            ext = p.get("output_extension", "")
            outs_all = []
            for i, s in enumerate(srcs):
                rel = self.tree_rel(s)
                o = os.path.join(gdir, "gen", os.path.splitext(rel)[0] + ("." + ext if ext else ""))
                outs_all.append(o)
                script = self._gen_script(m, cmd, [s], [o], srcs, tool_files, gdir, i, tools)
                t.gens.append(GenRule([self.cm(o)], script, depends,
                                      "Generating %s" % os.path.basename(o)))
            t.outputs = [self.cm(o) for o in outs_all]
        else:
            outs = [os.path.join(gdir, "gen", o) for o in p.get("out", [])]
            script = self._gen_script(m, cmd, srcs, outs, srcs, tool_files, gdir, tools=tools)
            t.gens.append(GenRule([self.cm(o) for o in outs], script, depends,
                                  "Generating %s" % " ".join(p.get("out", []))[:120]))
            t.outputs = [self.cm(o) for o in outs]
        t.interface_sources = [o for o in t.outputs if os.path.splitext(o)[1] not in SRC_EXTS]
        inc = p.get("export_include_dirs")
        gen_root = os.path.join(gdir, "gen")
        if inc:
            t.export_includes = [self.cm(os.path.join(gen_root, d)) for d in inc]
        else:
            t.export_includes = [self.cm(gen_root)]
        return t

    def _host_tool(self, m, name):
        """A genrule `tools` entry we can run without building it: Python and
        shell host tools run straight from source. Returns (command, files)."""
        tm = self.L.lookup(name, m)
        btype = self.L.base_type(tm)
        if btype in ("python_binary_host", "sh_binary_host"):
            p = self.L.flatten(tm, self.os, self.arch)
            srcs = self.expand_srcs(tm, p.get("srcs", []) if btype == "python_binary_host"
                                    else [p.get("src")])
            main = p.get("main")
            if main:
                entry = next((f for f in srcs if f.replace(os.sep, "/").endswith(main)), None)
            else:
                entry = srcs[0] if len(srcs) == 1 else None
            if entry is None:
                raise ResolveError("genrule %s: cannot tell the entry point of %s" % (m.name, name))
            interp = "python3" if btype == "python_binary_host" else "bash"
            return "%s %s" % (interp, shlex.quote(self.tree_rel(entry))), srcs
        raise ResolveError("genrule %s needs host tool %s (%s); replace the genrule in an overlay"
                           % (m.name, name, tm.type))

    def _gen_script(self, m, cmd, ins, outs, srcs, tool_files, gdir, index=None, tools=None):
        """Write the genrule's cmd as a bash script, with Soong's $(...) expanded.

        Runs from the AOSP farm root with tree-relative inputs, like Soong's
        sandboxed genrules, so commands such as `cp --parents $(in)` behave.
        """
        gen_root = os.path.join(gdir, "gen")
        q = lambda p: shlex.quote(p.replace(os.sep, "/"))
        locs = {}
        for f in srcs + tool_files:
            rel = os.path.relpath(f, self.mod_dir(m)).replace(os.sep, "/") if not f.startswith("${") else f
            locs[rel] = self.tree_rel(f)
            locs[os.path.basename(f)] = self.tree_rel(f)

        tools = tools or {}

        def location(label):
            label = label.strip()
            if label in tools:
                return tools[label][0]
            if not label and len(tools) == 1 and not tool_files:
                return next(iter(tools.values()))[0]
            if label.startswith(":"):
                files = self.expand_srcs(m, [label])
                return " ".join(q(self.tree_rel(f)) for f in files)
            if label in locs:
                return q(locs[label])
            if not label and len(tool_files) == 1:
                return q(self.tree_rel(tool_files[0]))
            raise ResolveError("genrule %s: cannot resolve $(location %s)" % (m.name, label))

        def sub(mo):
            body = mo.group(1)
            if body == "in":
                return " ".join(q(self.tree_rel(f)) for f in ins)
            if body == "out":
                return " ".join(q(o) for o in outs)
            if body == "genDir":
                return q(gen_root)
            if body.startswith("location") or body.startswith("locations"):
                return location(body.split(None, 1)[1] if " " in body else "")
            if body.startswith("in ") or body.startswith("out "):
                return q(body.split(None, 1)[1])
            raise ResolveError("genrule %s: unsupported $(%s)" % (m.name, body))

        text = cmd.replace("$$", "\0")
        text = re.sub(r"\$\(([^)]*)\)", sub, text).replace("\0", "$")
        os.makedirs(self.script_dir, exist_ok=True)
        path = os.path.join(self.script_dir, _target_name(m.name) + (
            "" if index is None else ".%d" % index) + ".sh")
        with open(path, "w", newline="\n") as f:
            f.write("#!/usr/bin/env bash\n# genrule %s (%s)\nset -e\n" % (m.name, m.path))
            for o in outs:
                f.write("mkdir -p %s\n" % q(os.path.dirname(o)))
            f.write(text.rstrip() + "\n")
        return self.cm(path)

    # -- cc modules

    def _cc(self, m, kind):
        p = self.props(m)
        if kind == "library":
            kind = "static"
            if isinstance(p.get("static"), dict):
                p = _merge(p, p.pop("static"), "append", VARIANT_PREPEND)
        if p.get("enabled") is False and self._stack and len(self._stack) > 1:
            self.log("note: %s is disabled for %s upstream; building it anyway" % (m.name, self.os.name))
        if kind == "prebuilt":
            return self._prebuilt(m, p)
        t = self._new(m, kind)
        mdir = self.mod_dir(m)
        aosp_dir = m.aosp_dir if not m.overlay else ""

        # sources and codegen
        raw = self.expand_srcs(m, p.get("srcs", []), p.get("exclude_srcs", []), t.objs)
        protos, yaccs, lexes = [], [], []
        for s in raw:
            ext = os.path.splitext(s)[1]
            if ext == ".proto":
                protos.append(s)
            elif ext in (".y", ".yy"):
                yaccs.append(s)
            elif ext in (".l", ".ll"):
                lexes.append(s)
            elif ext in SRC_EXTS or ext in HDR_EXTS or s.startswith("${"):
                t.srcs.append(s if s.startswith("${") else self.cm(s))
            elif ext in (".aidl", ".sysprop", ".rs"):
                raise ResolveError("%s: %s sources need an overlay replacement (%s)"
                                   % (m.name, ext, s))
            # other files (.map, .txt, ...) carry no compile semantics
        for g in p.get("generated_sources", []):
            t.srcs.extend(self.convert(g, m).outputs)

        # include paths, in Soong's order
        t.includes += [self.cm(os.path.join(mdir, d)) for d in p.get("local_include_dirs", [])]
        for d in p.get("include_dirs", []):
            lp = self.root_path(d)
            if lp is None or not (lp.startswith("${") or os.path.isdir(lp)):
                self.log("note: %s: include_dirs %s is not in the source set; skipped" % (m.name, d))
                continue
            t.includes.append(self.cm(lp) if not lp.startswith("${") else lp)
        if p.get("include_build_directory", True):
            t.includes.append(self.cm(mdir))
        for d in p.get("export_include_dirs", []):
            t.export_includes.append(d if d.startswith("${") else self.cm(os.path.join(mdir, d)))
        for d in p.get("export_system_include_dirs", []):
            t.export_system_includes.append(self.cm(os.path.join(mdir, d)))

        # flags
        third_party = aosp_dir.startswith(("external/", "vendor/", "hardware/", "device/"))
        drop = self.drop_flags
        t.cflags = _clean_flags(p.get("cflags", []), drop.get("cflags"))
        if third_party:
            t.cflags = EXTERNAL_CFLAGS + t.cflags
        if not aosp_dir.startswith("external/"):
            t.cflags = ["-DANDROID_STRICT"] + t.cflags
        t.cppflags = _clean_flags(p.get("cppflags", []), drop.get("cppflags"))
        t.conlyflags = _clean_flags(p.get("conlyflags", []), drop.get("conlyflags"))
        t.asflags = _clean_flags(p.get("asflags", []), drop.get("asflags"))
        t.cppflags = (["-frtti"] if p.get("rtti") else ["-fno-rtti"]) + t.cppflags
        t.c_std = self._std(p.get("c_std"), C_STD, EXPERIMENTAL_C_STD)
        t.cpp_std = self._std(p.get("cpp_std"), CPP_STD, EXPERIMENTAL_CPP_STD)
        if p.get("gnu_extensions") is False:
            t.c_std = t.c_std.replace("gnu", "c")
            t.cpp_std = t.cpp_std.replace("gnu", "c")

        # dependencies
        reexp_static = set(p.get("export_static_lib_headers", []))
        reexp_shared = set(p.get("export_shared_lib_headers", []))
        reexp_header = set(p.get("export_header_lib_headers", []))
        reexp_gen = set(p.get("export_generated_headers", []))
        static_libs = list(p.get("static_libs", []))
        whole = list(p.get("whole_static_libs", []))
        if p.get("use_version_lib"):
            whole.append("libbuildversion")

        if protos:
            self._proto(m, p, t, protos, static_libs, reexp_static)
        if yaccs or lexes:
            self._yacc_lex(m, p, t, yaccs, lexes)

        def dep(name):
            if name in SYSTEM_LIBS:
                return None
            return self.convert(name, m)

        # whole_static_libs re-export their headers (cc.go wholeStatic deps
        # carry reexportFlags); in a binary they are linked --whole-archive.
        for n in whole:
            d = dep(n)
            if d is not None:
                t.link.append((d, True, "whole" if kind == "binary" else "link"))
        for n in static_libs:
            d = dep(n)
            if d is not None:
                t.link.append((d, n in reexp_static, "link"))
        for n in p.get("shared_libs", []):
            d = dep(n)
            if d is not None:
                t.link.append((d, n in reexp_shared, "link"))
        for n in p.get("header_libs", []):
            d = dep(n)
            if d is not None:
                t.link.append((d, n in reexp_header, "headers"))
        # device_first_generated_headers come from the device variant of a
        # genrule in Soong; there is only one variant here.
        for n in p.get("generated_headers", []) + p.get("device_first_generated_headers", []):
            d = dep(n)
            if d is not None:
                t.link.append((d, n in reexp_gen, "link"))
        for n in p.get("objs", []):
            d = dep(n)
            if d is not None:
                t.objs.append(d)

        # link
        t.ldflags = _clean_flags(p.get("ldflags", []))
        t.ldlibs = self._ldlibs(p.get("host_ldlibs", []) + p.get("ldlibs", []))
        if kind == "binary":
            t.output_name = p.get("stem", m.name) + p.get("suffix", "")
        return t

    @staticmethod
    def _std(v, default, experimental):
        if not v or v == "default":
            return default
        if v == "experimental":
            return experimental
        return v

    def _ldlibs(self, libs):
        ok = AVAILABLE_LDLIBS[self.ldlib_family]
        out = []
        i = 0
        while i < len(libs):
            l = libs[i]
            if l == "-framework" and i + 1 < len(libs):
                out.append("-framework " + libs[i + 1])
                i += 2
                continue
            if l.startswith("-framework"):
                out.append(l)
            elif l.startswith("-l"):
                if l[2:] in ok:
                    out.append(l)
            else:
                out.append(l)
            i += 1
        return out

    def _prebuilt(self, m, p):
        srcs = p.get("srcs", [])
        if not srcs:
            # A prebuilt selected away for this configuration (e.g. a Rust
            # staticlib the target has no std for): depending on it is a no-op.
            return self._new(m, "headers")
        t = self._new(m, "prebuilt")
        if len(srcs) != 1:
            raise ResolveError("prebuilt %s needs exactly one src" % m.name)
        s = srcs[0]
        t.prebuilt = s if s.startswith("${") else self.cm(os.path.join(self.mod_dir(m), s))
        for d in p.get("export_include_dirs", []):
            t.export_includes.append(d if d.startswith("${") else self.cm(os.path.join(self.mod_dir(m), d)))
        t.ldlibs = self._ldlibs(p.get("host_ldlibs", []))
        for n in p.get("static_libs", []) + p.get("shared_libs", []):
            if n not in SYSTEM_LIBS:
                t.link.append((self.convert(n, m), False, "link"))
        return t

    # -- proto (cc/proto.go + android/proto.go)

    def _proto(self, m, p, t, protos, static_libs, reexp_static):
        pp = p.get("proto", {}) or {}
        ptype = pp.get("type", "lite")
        if ptype not in ("lite", "full"):
            raise ResolveError("%s: proto type %s unsupported" % (m.name, ptype))
        lib = "libprotobuf-cpp-" + ptype
        if lib not in static_libs:
            static_libs.append(lib)
        reexp_static.add(lib)
        canonical = pp.get("canonical_path_from_root", True)
        pdir = os.path.join(self.gen_dir, t.name, "proto")
        flags = []
        for d in pp.get("local_include_dirs", []):
            flags.append("-I" + self.tree_rel(os.path.join(self.mod_dir(m), d)))
        for d in pp.get("include_dirs", []):
            lp = self.root_path(d)
            if lp:
                flags.append("-I" + self.tree_rel(lp))
        out_flag = "--cpp_out=lite:" if ptype == "lite" else "--cpp_out="
        for src in protos:
            rel = self.tree_rel(src)
            if canonical:
                base_i, in_rel = ".", rel
            else:
                mrel = os.path.relpath(src, self.mod_dir(m)).replace(os.sep, "/")
                base_i, in_rel = rel[:-len(mrel)].rstrip("/") or ".", rel
                rel = mrel
            stem = os.path.splitext(rel)[0]
            outs = [self.cm(os.path.join(pdir, stem + ".pb.cc")),
                    self.cm(os.path.join(pdir, stem + ".pb.h"))]
            cmd = ["${PROTOC}", out_flag + "${GEN}/" + t.name + "/proto", "-I", base_i] + flags + [in_rel]
            t.gens.append(GenRule(outs, cmd, [self.cm(src)], "Generating %s.pb.{cc,h}" % stem))
            t.srcs.extend(outs)
        t.cflags = ["-DGOOGLE_PROTOBUF_NO_RTTI"] + t.cflags
        incs = []
        if canonical:
            aosp_dir = m.aosp_dir if not m.overlay else ""
            incs.append(self.cm(os.path.join(pdir, aosp_dir)))
        incs.append(self.cm(pdir))
        t.includes += incs
        if pp.get("export_proto_headers"):
            t.export_includes += incs

    # -- yacc / lex (cc/gen.go)

    def _yacc_lex(self, m, p, t, yaccs, lexes):
        ydir = os.path.join(self.gen_dir, t.name, "yacc")
        ldir = os.path.join(self.gen_dir, t.name, "lex")
        yflags = (p.get("yacc", {}) or {}).get("flags", [])
        lflags = (p.get("lex", {}) or {}).get("flags", [])
        for src in yaccs:
            rel = self.tree_rel(src)
            ext = "cpp" if src.endswith(".yy") else "c"
            out = os.path.join(ydir, os.path.splitext(rel)[0] + "." + ext)
            hdr = os.path.join(ydir, os.path.splitext(rel)[0] + ".h")
            cmd = ["${BISON}", "-d"] + yflags + ["--defines=" + self.cm(hdr), "-o", self.cm(out), rel]
            extra = []
            y = p.get("yacc", {}) or {}
            if y.get("gen_location_hh"):
                extra.append(self.cm(os.path.join(os.path.dirname(out), "location.hh")))
            if y.get("gen_position_hh"):
                extra.append(self.cm(os.path.join(os.path.dirname(out), "position.hh")))
            t.gens.append(GenRule([self.cm(out), self.cm(hdr)] + extra, cmd, [self.cm(src)],
                                  "bison %s" % os.path.basename(src)))
            t.srcs += [self.cm(out), self.cm(hdr)] + extra
        for src in lexes:
            rel = self.tree_rel(src)
            ext = "cpp" if src.endswith(".ll") else "c"
            out = os.path.join(ldir, os.path.splitext(rel)[0] + "." + ext)
            cmd = ["${FLEX}"] + lflags + ["-o" + self.cm(out), rel]
            t.gens.append(GenRule([self.cm(out)], cmd, [self.cm(src)], "flex %s" % os.path.basename(src)))
            t.srcs.append(self.cm(out))
        aosp_dir = m.aosp_dir if not m.overlay else ""
        t.includes.append(self.cm(os.path.join(ydir, aosp_dir)))
