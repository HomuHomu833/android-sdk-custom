"""Blueprint (Android.bp) lexer, parser and evaluator.

Parses the Blueprint language into plain Python values: every module becomes a
Module whose props are dicts/lists/str/int/bool, with variables, `+` and
select() already resolved for one build configuration. Resolving select()
early is safe because a converter run only ever targets one os/arch.
"""

import os
import re

__all__ = ["BlueprintError", "Module", "UNSET", "parse_file", "Evaluator", "SelectConfig"]


class BlueprintError(Exception):
    pass


class _Unset:
    """A select() branch that evaluated to `unset`: the property is removed."""

    def __repr__(self):
        return "UNSET"


UNSET = _Unset()


# --- lexer -------------------------------------------------------------------

_TOKEN_RE = re.compile(
    r"""
    (?P<ws>[ \t\r\n]+)
  | (?P<lcomment>//[^\n]*)
  | (?P<bcomment>/\*.*?\*/)
  | (?P<string>"(?:[^"\\\n]|\\.)*")
  | (?P<raw>`[^`]*`)
  | (?P<int>[0-9]+)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>\+=|[{}\[\](),:=+\-@])
    """,
    re.VERBOSE | re.DOTALL,
)

_GO_ESCAPES = {
    "a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v",
    "\\": "\\", "'": "'", '"': '"',
}


def _unquote(lit):
    body = lit[1:-1]
    if "\\" not in body:
        return body
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        e = body[i + 1]
        if e in _GO_ESCAPES:
            out.append(_GO_ESCAPES[e])
            i += 2
        elif e == "x":
            out.append(chr(int(body[i + 2:i + 4], 16)))
            i += 4
        elif e == "u":
            out.append(chr(int(body[i + 2:i + 6], 16)))
            i += 6
        elif e == "U":
            out.append(chr(int(body[i + 2:i + 10], 16)))
            i += 10
        elif e in "01234567":
            out.append(chr(int(body[i + 1:i + 4], 8)))
            i += 4
        else:
            raise BlueprintError("bad escape \\%s in %s" % (e, lit))
    return "".join(out)


class _Tok:
    __slots__ = ("kind", "val", "line")

    def __init__(self, kind, val, line):
        self.kind, self.val, self.line = kind, val, line

    def __repr__(self):
        return "%s(%r)@%d" % (self.kind, self.val, self.line)


def _lex(text, path):
    toks, pos, line = [], 0, 1
    while pos < len(text):
        m = _TOKEN_RE.match(text, pos)
        if not m:
            raise BlueprintError("%s:%d: unexpected character %r" % (path, line, text[pos]))
        kind = m.lastgroup
        val = m.group()
        if kind == "string":
            toks.append(_Tok("str", _unquote(val), line))
        elif kind == "raw":
            toks.append(_Tok("str", val[1:-1], line))
        elif kind == "int":
            toks.append(_Tok("int", int(val), line))
        elif kind == "ident":
            toks.append(_Tok("ident", val, line))
        elif kind == "op":
            toks.append(_Tok("op", val, line))
        line += val.count("\n")
        pos = m.end()
    toks.append(_Tok("eof", None, line))
    return toks


# --- AST ---------------------------------------------------------------------
# Expressions are tuples: ("lit", v) ("var", name) ("list", [e]) ("map", [(k, e)])
# ("add", [e]) ("select", conds, cases) ("unset",). A select condition is
# (func_name, [args]); a case is ([patterns], expr) and a pattern is one of
# ("lit", v) ("default",) ("any", bind_name_or_None).


class Module:
    __slots__ = ("type", "props", "path", "line", "aosp_dir", "overlay", "namespace")

    def __init__(self, type_, props, path, line):
        self.type, self.props, self.path, self.line = type_, props, path, line
        self.aosp_dir, self.overlay, self.namespace = "", False, None

    @property
    def name(self):
        return self.props.get("name")

    @property
    def dir(self):
        return os.path.dirname(self.path)

    def __repr__(self):
        return "<%s %s @ %s:%d>" % (self.type, self.name, self.path, self.line)


class _Parser:
    def __init__(self, toks, path):
        self.toks, self.i, self.path = toks, 0, path

    def peek(self, k=0):
        return self.toks[self.i + k]

    def next(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def error(self, msg, tok=None):
        tok = tok or self.peek()
        raise BlueprintError("%s:%d: %s (at %r)" % (self.path, tok.line, msg, tok.val))

    def accept(self, op):
        t = self.peek()
        if t.kind == "op" and t.val == op:
            self.i += 1
            return True
        return False

    def expect(self, op):
        if not self.accept(op):
            self.error("expected %r" % op)

    def ident(self):
        t = self.next()
        if t.kind != "ident":
            self.error("expected identifier", t)
        return t.val

    def file(self):
        defs = []
        while self.peek().kind != "eof":
            name_tok = self.peek()
            name = self.ident()
            if self.accept("="):
                defs.append(("assign", name, self.expression(), False, name_tok.line))
            elif self.accept("+="):
                defs.append(("assign", name, self.expression(), True, name_tok.line))
            elif self.accept("{"):
                defs.append(("module", name, self.properties("}"), name_tok.line))
            elif self.accept("("):
                defs.append(("module", name, self.properties(")"), name_tok.line))
            else:
                self.error("expected assignment or module body")
        return defs

    def properties(self, close):
        props = []
        while not self.accept(close):
            key = self.ident()
            if not (self.accept(":") or self.accept("=")):
                self.error("expected ':' after property name")
            props.append((key, self.expression()))
            if not self.accept(","):
                self.expect(close)
                break
        return props

    def expression(self):
        terms = [self.value()]
        while self.accept("+"):
            terms.append(self.value())
        return terms[0] if len(terms) == 1 else ("add", terms)

    def value(self):
        t = self.next()
        if t.kind in ("str", "int"):
            return ("lit", t.val)
        if t.kind == "op" and t.val == "-" and self.peek().kind == "int":
            return ("lit", -self.next().val)
        if t.kind == "op" and t.val == "[":
            items = []
            while not self.accept("]"):
                items.append(self.expression())
                if not self.accept(","):
                    self.expect("]")
                    break
            return ("list", items)
        if t.kind == "op" and t.val == "{":
            return ("map", self.properties("}"))
        if t.kind == "ident":
            if t.val == "true":
                return ("lit", True)
            if t.val == "false":
                return ("lit", False)
            if t.val == "unset":
                return ("unset",)
            if t.val == "select" and self.accept("("):
                return self.select()
            return ("var", t.val)
        self.error("unexpected token", t)

    def select(self):
        if self.accept("("):
            conds = []
            while not self.accept(")"):
                conds.append(self.condition())
                if not self.accept(","):
                    self.expect(")")
                    break
        else:
            conds = [self.condition()]
        self.expect(",")
        self.expect("{")
        cases = []
        while not self.accept("}"):
            if self.accept("("):
                pats = []
                while not self.accept(")"):
                    pats.append(self.pattern())
                    if not self.accept(","):
                        self.expect(")")
                        break
            else:
                pats = [self.pattern()]
            self.expect(":")
            cases.append((pats, self.expression()))
            if not self.accept(","):
                self.expect("}")
                break
        self.accept(",")
        self.expect(")")
        return ("select", conds, cases)

    def condition(self):
        name = self.ident()
        self.expect("(")
        args = []
        while not self.accept(")"):
            t = self.next()
            if t.kind != "str":
                self.error("select condition arguments must be strings", t)
            args.append(t.val)
            if not self.accept(","):
                self.expect(")")
                break
        return (name, args)

    def pattern(self):
        t = self.next()
        if t.kind == "str":
            return ("lit", t.val)
        if t.kind == "ident":
            if t.val in ("true", "false"):
                return ("lit", t.val == "true")
            if t.val == "default":
                return ("default",)
            if t.val == "any":
                if self.accept("@"):
                    return ("any", self.ident())
                return ("any", None)
        self.error("bad select pattern", t)


def parse_file(path, text=None):
    if text is None:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    return _Parser(_lex(text, path), path).file()


# --- evaluation --------------------------------------------------------------


class SelectConfig:
    """Answers select() conditions for the one configuration being generated.

    os()/arch() come from the target; soong_config_variable, release_flag and
    product_variable read from `variables` (keys like "ns:var" or "FLAG") and
    otherwise match nothing, so `default` wins, as for an unconfigured product.
    """

    def __init__(self, os_name, arch_name, variables=None):
        self.os, self.arch = os_name, arch_name
        self.variables = variables or {}

    def value(self, func, args):
        if func == "os":
            return self.os
        if func == "arch":
            return self.arch
        if func == "soong_config_variable":
            return self.variables.get(":".join(args))
        if func in ("release_flag", "product_variable"):
            return self.variables.get(args[0])
        if func == "boolean_var_for_testing":
            return None
        if func == "variant":
            return None
        raise BlueprintError("unsupported select condition %s()" % func)


def _add(a, b, where):
    if a is UNSET:
        return b
    if b is UNSET:
        return a
    if isinstance(a, bool) or isinstance(b, bool):
        raise BlueprintError("%s: cannot add booleans" % where)
    if isinstance(a, str) and isinstance(b, str):
        return a + b
    if isinstance(a, int) and isinstance(b, int):
        return a + b
    if isinstance(a, list) and isinstance(b, list):
        return a + b
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items():
            out[k] = _add(out[k], v, where) if k in out else v
        return out
    raise BlueprintError("%s: cannot add %s and %s" % (where, type(a).__name__, type(b).__name__))


class Evaluator:
    def __init__(self, select_config):
        self.cfg = select_config

    def eval(self, expr, scope, where, binds=None):
        kind = expr[0]
        if kind == "lit":
            return expr[1]
        if kind == "unset":
            return UNSET
        if kind == "var":
            name = expr[1]
            if binds and name in binds:
                return binds[name]
            for s in scope:
                if name in s:
                    return s[name]
            raise BlueprintError("%s: undefined variable %s" % (where, name))
        if kind == "list":
            out = []
            for e in expr[1]:
                v = self.eval(e, scope, where, binds)
                if v is not UNSET:
                    out.append(v)
            return out
        if kind == "map":
            out = {}
            for k, e in expr[1]:
                v = self.eval(e, scope, where, binds)
                if v is not UNSET:
                    out[k] = v
            return out
        if kind == "add":
            acc = UNSET
            for e in expr[1]:
                acc = _add(acc, self.eval(e, scope, where, binds), where)
            return acc
        if kind == "select":
            return self._select(expr, scope, where)
        raise BlueprintError("%s: bad expression %r" % (where, expr))

    def _select(self, expr, scope, where):
        _, conds, cases = expr
        values = [self.cfg.value(f, a) for f, a in conds]
        for pats, e in cases:
            if len(pats) != len(values):
                raise BlueprintError("%s: select case arity mismatch" % where)
            binds, ok = {}, True
            for pat, val in zip(pats, values):
                if pat[0] == "default":
                    continue
                if pat[0] == "any":
                    if val is None:
                        ok = False
                        break
                    if pat[1]:
                        binds[pat[1]] = val
                    continue
                if val is None or pat[1] != val:
                    ok = False
                    break
            if ok:
                return self.eval(e, scope, where, binds)
        return UNSET
