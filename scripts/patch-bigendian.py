#!/usr/bin/env python3
"""Big-endian support for the SDK tools' Android file formats.

Android only runs on little-endian CPUs, so AOSP reads and writes the on-disk
little-endian structures of zip archives, resource tables and dex files
straight through host-order fields. On big-endian hosts every such read comes
out byte-swapped. This makes those accesses explicit little-endian, leaving
little-endian builds byte-for-byte the same:

  * libziparchive: the packed on-disk records' fields become an Le<T> wrapper
    that converts on every read and assignment; the loose unaligned reads and
    writes get the same conversion.
  * androidfw/libutils: dtohl()/dtohs()/htodl()/htods() swap again on
    big-endian, as they did before Android dropped those hosts.

Usage: patch-bigendian.py <src-root> <libziparchive-dir> <libutils-dir>
Each edit applies only where the code it expects is present, so the script
is a no-op on a tree it has already patched.
"""
import os
import re
import sys

SRC, ZIP, UTILS = sys.argv[1:4]

LE_HEADER = r'''
// Little-endian on-disk values on any host (patch-bigendian.py).
#ifndef SDK_LE_WRAPPER
#define SDK_LE_WRAPPER
#ifdef __cplusplus
#include <stdint.h>
#include <limits>
#include <type_traits>
namespace sdk_le {
template <typename T>
constexpr T swap(T v) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
  if constexpr (sizeof(T) == 2) {
    return static_cast<T>(__builtin_bswap16(static_cast<uint16_t>(v)));
  } else if constexpr (sizeof(T) == 4) {
    return static_cast<T>(__builtin_bswap32(static_cast<uint32_t>(v)));
  } else if constexpr (sizeof(T) == 8) {
    return static_cast<T>(__builtin_bswap64(static_cast<uint64_t>(v)));
  } else {
    return v;
  }
#else
  return v;
#endif
}
// An already little-endian value, as htodl()/htods() return it: assigning it
// to a wrapped field stores it as is; read as a plain integer it is the raw word.
template <typename T>
struct Raw {
  T raw;
  constexpr operator T() const { return raw; }
  // For an enum-typed on-disk field (static_cast<Flags>(htodl(x))).
  template <typename E, typename = std::enable_if_t<std::is_enum_v<E>>>
  constexpr explicit operator E() const { return static_cast<E>(raw); }
};
#define SDK_LE_BODY(Name)                                                     \
  T raw_;                                                                     \
  constexpr operator T() const { return swap(raw_); }                         \
  Name& operator=(T v) { raw_ = swap(v); return *this; }                     \
  template <typename U>                                                       \
  Name& operator=(Raw<U> r) { return *this = static_cast<T>(swap(r.raw)); }  \
  Name& operator+=(T v) { return *this = static_cast<T>(T(*this) + v); }     \
  Name& operator-=(T v) { return *this = static_cast<T>(T(*this) - v); }     \
  Name& operator|=(T v) { return *this = static_cast<T>(T(*this) | v); }     \
  Name& operator&=(T v) { return *this = static_cast<T>(T(*this) & v); }     \
  template <typename U>                                                       \
  Name& operator|=(Raw<U> r) { raw_ |= static_cast<T>(r.raw); return *this; } \
  template <typename U>                                                       \
  Name& operator&=(Raw<U> r) { raw_ &= static_cast<T>(r.raw); return *this; } \
  Name& operator++() { return *this += 1; }                                  \
  Name& operator--() { return *this -= 1; }                                  \
  T operator++(int) { T o = *this; *this += 1; return o; }                   \
  T operator--(int) { T o = *this; *this -= 1; return o; }
// A T stored little-endian, byte-aligned (packed records read from anywhere).
template <typename T>
struct __attribute__((packed)) Le { SDK_LE_BODY(Le) };
// The same with T's own alignment, so a struct's layout does not change.
template <typename T>
struct LeA { SDK_LE_BODY(LeA) };
#undef SDK_LE_BODY
template <typename T> constexpr T value(const Le<T>& v) { return v; }
template <typename T> constexpr T value(const LeA<T>& v) { return v; }
// Anything else as is (used where a field may or may not be wrapped).
template <typename T> constexpr T value(const T& v) { return v; }
template <typename T> constexpr bool operator==(const LeA<T>& a, Raw<T> b) { return a.raw_ == b.raw; }
template <typename T> constexpr bool operator!=(const LeA<T>& a, Raw<T> b) { return a.raw_ != b.raw; }
template <typename T> constexpr bool operator==(Raw<T> b, const LeA<T>& a) { return a.raw_ == b.raw; }
template <typename T> constexpr bool operator!=(Raw<T> b, const LeA<T>& a) { return a.raw_ != b.raw; }
// A float kept in a wrapped word (Res_value::data): convert the value, not
// the stored bytes.
inline float bits_float(uint32_t v) { float f; __builtin_memcpy(&f, &v, 4); return f; }
inline uint32_t float_bits(float f) { uint32_t v; __builtin_memcpy(&v, &f, 4); return v; }
// dtohl()/dtohs(): a wrapped field already reads in host order; a plain
// integer is a raw little-endian word.
inline constexpr uint32_t dtoh32(uint32_t v) { return swap(v); }
inline constexpr uint16_t dtoh16(uint16_t v) { return swap(v); }
template <typename T> constexpr T dtoh32(const LeA<T>& v) { return v; }
template <typename T> constexpr T dtoh16(const LeA<T>& v) { return v; }
template <typename T> constexpr T dtoh32(const Le<T>& v) { return v; }
template <typename T> constexpr T dtoh16(const Le<T>& v) { return v; }
// htodl()/htods(): to little-endian; of a wrapped field, its stored bytes.
inline constexpr Raw<uint32_t> htod32(uint32_t v) { return {swap(v)}; }
inline constexpr Raw<uint16_t> htod16(uint16_t v) { return {swap(v)}; }
template <typename T> constexpr Raw<T> htod32(const LeA<T>& v) { return {v.raw_}; }
template <typename T> constexpr Raw<T> htod16(const LeA<T>& v) { return {v.raw_}; }
}  // namespace sdk_le
// std::min/std::max deduce one type from both arguments; let a wrapped field
// stand in for its value there too.
namespace std {
#define SDK_LE_MINMAX(W)                                                                     \
  template <typename T> constexpr T max(const T& a, const sdk_le::W<T>& b) { return a < T(b) ? T(b) : a; } \
  template <typename T> constexpr T max(const sdk_le::W<T>& a, const T& b) { return T(a) < b ? b : T(a); } \
  template <typename T> constexpr T max(const sdk_le::W<T>& a, const sdk_le::W<T>& b) { return T(a) < T(b) ? T(b) : T(a); } \
  template <typename T> constexpr T min(const T& a, const sdk_le::W<T>& b) { return T(b) < a ? T(b) : a; } \
  template <typename T> constexpr T min(const sdk_le::W<T>& a, const T& b) { return b < T(a) ? b : T(a); } \
  template <typename T> constexpr T min(const sdk_le::W<T>& a, const sdk_le::W<T>& b) { return T(b) < T(a) ? T(b) : T(a); }
SDK_LE_MINMAX(Le)
SDK_LE_MINMAX(LeA)
#undef SDK_LE_MINMAX
// numeric_limits<decltype(header->field)> means the field's integer type.
template <typename T> class numeric_limits<sdk_le::Le<T>> : public numeric_limits<T> {};
template <typename T> class numeric_limits<sdk_le::LeA<T>> : public numeric_limits<T> {};
}  // namespace std
#endif  // __cplusplus
#endif  // SDK_LE_WRAPPER
'''


DONE = []


def need(cond, what):
    """Each expected edit must have landed; a release whose code moved on
    stops the build here instead of shipping a silently unpatched tool."""
    if not cond:
        sys.exit('patch-bigendian.py: %s' % what)
    DONE.append(what)


def read(path):
    with open(path, newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', newline='') as f:
        f.write(text)


def after_includes(text, block):
    """Insert block after the last top-level #include of text."""
    last = None
    for m in re.finditer(r'^#include [<"][^>"]+[>"][^\n]*\n', text, re.M):
        last = m
    pos = last.end() if last else 0
    return text[:pos] + block + text[pos:]


def ziparchive():
    common = os.path.join(ZIP, 'zip_archive_common.h')
    if not os.path.exists(common):
        return
    text = read(common)
    if 'sdk_le.h' in text:
        return
    write(os.path.join(ZIP, 'sdk_le.h'),
          '#pragma once\n#include <stdint.h>\n' + LE_HEADER)
    text = after_includes(text, '#include "sdk_le.h"\n')

    # Fields of the packed on-disk records become Le<>.
    fields = set()
    def wrap(m):
        def one(f):
            fields.add(f.group(3))
            return '%ssdk_le::Le<%s> %s;' % (f.group(1), f.group(2), f.group(3))
        body = re.sub(r'^(\s+)(uint(?:16|32|64)_t) (\w+);', one, m.group(2), flags=re.M)
        return m.group(1) + body + m.group(3)
    text, n = re.subn(r'(struct \w+ \{\n)(.*?)(\n\} __attribute__\(\(packed\)\);)',
                      wrap, text, flags=re.S)
    need(n >= 3, 'zip: %d packed on-disk records wrapped' % n)
    write(common, text)

    # ConsumeUnaligned / EmitUnaligned read and write little-endian.
    priv = os.path.join(ZIP, 'zip_archive_private.h')
    if os.path.exists(priv):
        t = read(priv)
        t = after_includes(t, '#include "sdk_le.h"\n')
        t = t.replace('auto ret = android::base::get_unaligned<T>(*address);',
                      'auto ret = sdk_le::swap(android::base::get_unaligned<T>(*address));')
        t = t.replace('android::base::put_unaligned<T>(*address, data);',
                      'android::base::put_unaligned<T>(*address, sdk_le::swap(data));')
        need('get_unaligned<T>' not in t or 'sdk_le::swap(android::base::get_unaligned<T>' in t,
             'zip: ConsumeUnaligned/EmitUnaligned')
        write(priv, t)

    # Varargs (logging) take a wrapped field as is; convert it first.
    field_re = re.compile(r'(?<![\w.>+])(\w+(?:->|\.)(?:%s))\b(?!\s*[(=])' %
                          '|'.join(sorted(fields, key=len, reverse=True)))
    def plus_args(m):
        return field_re.sub(r'+\1', m.group(0))
    for name in sorted(os.listdir(ZIP)):
        if not name.endswith(('.cc', '.cpp')) or name.endswith(('_test.cc', '_fuzzer.cpp', '_benchmark.cpp')):
            continue
        path = os.path.join(ZIP, name)
        t = read(path)
        t2 = re.sub(r'\b(?:ALOG[VDIWE]|LOG\(\w+\)\s*<<|printf|fprintf|StringPrintf)\s*\((?:[^;]|;(?!\s*$))*?\);',
                    plus_args, t, flags=re.M)
        if t2 != t:
            write(path, t2)

    arch = os.path.join(ZIP, 'zip_archive.cc')
    t = read(arch)
    # Signatures read as bare host-order words.
    t = re.sub(r'((?:android::base::)?get_unaligned<uint32_t>\(sig_addr\))( == EocdRecord::kSignature)',
               r'sdk_le::swap(\1)\2', t)
    t = re.sub(r'\*lfh_start_bytes\b(?! =)', 'sdk_le::swap(*lfh_start_bytes)', t)       # newer
    t = re.sub(r'(?<![&\w])lfh_start_bytes\b(?=\s*[!=]=|\);)', 'sdk_le::swap(lfh_start_bytes)', t)  # 29.x
    t = re.sub(r'(const uint32_t ddSignature = )(\*\(reinterpret_cast<const uint32_t\*>\(\w+\)\));',
               r'\1sdk_le::swap(\2);', t)
    need('sdk_le::swap(' in t and re.search(r'swap\((?:android::base::)?get_unaligned<uint32_t>\(sig_addr\)\)', t),
         'zip: EOCD signature scan')
    need('sdk_le::swap(lfh_start_bytes)' in t or 'sdk_le::swap(*lfh_start_bytes)' in t,
         'zip: first local header signature')
    need(re.search(r'ddSignature = sdk_le::swap\(', t), 'zip: data descriptor signature')
    # Nothing else may read a raw multi-byte word.
    for name in ('zip_archive.cc', 'zip_writer.cc', 'zip_archive_stream_entry.cc', 'zip_cd_entry_map.cc'):
        path = os.path.join(ZIP, name)
        if name != 'zip_archive.cc' and os.path.exists(path):
            u = read(path)
        elif name == 'zip_archive.cc':
            u = t
        else:
            continue
        for line in u.splitlines():
            # A dereference of a reinterpret_cast word, or an unaligned word read.
            if re.search(r'\*\s*\(?\s*reinterpret_cast<const uint(16|32|64)_t\s*\*>|'
                         r'(?:android::base::)?get_unaligned<uint(16|32|64)_t>', line) \
                    and 'sdk_le::swap' not in line:
                sys.exit('patch-bigendian.py: zip: unhandled raw read in %s: %s' % (name, line.strip()))
    write(arch, t)

    writer = os.path.join(ZIP, 'zip_writer.cc')
    if os.path.exists(writer):
        t = read(writer)
        # The data descriptor goes out as a plain array of words (newer) or
        # after a bare signature word (29.x).
        t = re.sub(r'^(\s*)(if \(fwrite\(dataDescriptor\.data\(\))',
                   r'\1for (auto& word : dataDescriptor) word = sdk_le::swap(word);\n\1\2',
                   t, count=1, flags=re.M)
        t = t.replace('const uint32_t sig = DataDescriptor::kOptSignature;',
                      'const uint32_t sig = sdk_le::swap(DataDescriptor::kOptSignature);')
        need('sdk_le::swap(word)' in t or 'sdk_le::swap(DataDescriptor::kOptSignature)' in t,
             'zip: writer data descriptor')
        write(writer, t)


def byteorder():
    """dtohl()/dtohs()/htodl()/htods() become the sdk_le overloads (C++) or
    plain swaps (C), so they convert raw words and pass wrapped fields through."""
    path = os.path.join(UTILS, 'include', 'utils', 'ByteOrder.h')
    if not os.path.exists(path):
        return
    t = read(path)
    if 'SDK_LE_WRAPPER' in t:
        return
    t, n = re.subn(r'^#\s*define\s+(dtohl|dtohs|htodl|htods)\b[^\n]*\n', '', t, flags=re.M)
    need(n >= 4, 'androidfw: ByteOrder.h dtohl/dtohs/htodl/htods replaced (%d)' % n)
    block = LE_HEADER + r"""
#ifdef __cplusplus
#define dtohl(x) (::sdk_le::dtoh32(x))
#define dtohs(x) (::sdk_le::dtoh16(x))
#define htodl(x) (::sdk_le::htod32(x))
#define htods(x) (::sdk_le::htod16(x))
#elif defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#define dtohl(x) (__builtin_bswap32(x))
#define dtohs(x) (__builtin_bswap16(x))
#define htodl(x) (__builtin_bswap32(x))
#define htods(x) (__builtin_bswap16(x))
#else
#define dtohl(x) (x)
#define dtohs(x) (x)
#define htodl(x) (x)
#define htods(x) (x)
#endif
"""
    # Before the include guard's #endif, or at the end of a #pragma once header.
    m = re.search(r'\n#endif[^\n]*\n*$', t)
    t = (t[:m.start()] + '\n' + block + t[m.start():]) if m and '#pragma once' not in t else t + block
    write(path, t)


def resourcetypes():
    """The fixed-width fields of androidfw's on-disk structs become LeA<>."""
    path = os.path.join(SRC, 'base', 'libs', 'androidfw', 'include', 'androidfw', 'ResourceTypes.h')
    if not os.path.exists(path):
        return
    t = read(path)
    if 'sdk_le::LeA<' in t:
        return
    # Fixed-width integers, and the header's typedefs of them (Res_value::data_type).
    types = ['u?int(?:16|32|64)_t'] + re.findall(r'typedef u?int(?:16|32|64)_t (\w+);', t)
    field = re.compile(r'^(\s+)(%s) (\w+);(.*)$' % '|'.join(types))
    out, depth, skip, n = [], 0, False, 0
    for line in t.split('\n'):
        m = re.match(r'\s*(?:struct|union)\s+(?:alignas\([^)]*\)\s+)?(\w+)', line)
        if m:
            skip = m.group(1) == 'Res_png_9patch'  # serialised by its own (network-order) code
        f = field.match(line)
        if f and depth > 0 and not skip:
            line = '%ssdk_le::LeA<%s> %s;%s' % (f.group(1), f.group(2), f.group(3), f.group(4))
            n += 1
        out.append(line)
        depth += line.count('{') - line.count('}')
    need(n >= 60, 'androidfw: %d on-disk struct fields wrapped' % n)
    t = '\n'.join(out)
    # Older headers get dtohl() and friends only from their includers.
    if '#include <utils/ByteOrder.h>' not in t:
        t = after_includes(t, '#include <utils/ByteOrder.h>\n')
    write(path, t)





def stringpool():
    """ResStringPool::setTo() still has its pre-2010 path for foreign-endian
    data: it converts its private copy's plain arrays (string and style
    offsets, UTF-16 text) to host order and reads them as is, which stays
    right. It also converts the style spans, which are ResStringPool_span
    structs whose fields now convert on access themselves; leave those."""
    path = os.path.join(SRC, 'base', 'libs', 'androidfw', 'ResourceTypes.cpp')
    if not os.path.exists(path):
        return
    t = read(path)
    t, n = re.subn(r'\n(\s*)uint32_t\* s = const_cast<uint32_t\*>\(mStyles[^;]*;\n'
                   r'\s*for \(i=0; i<mStylePoolSize; i\+\+\) \{\n\s*s\[i\] = dtohl\((?:s|mStyles)\[i\]\);\n\s*\}',
                   r'\n\1// (style spans convert on access; patch-bigendian.py)', t)
    done = '(style spans convert on access; patch-bigendian.py)' in t
    need(n == 1 or done, 'androidfw: string pool style spans left to their fields')
    write(path, t)



def punning():
    """Code that reinterprets Res_value::data's storage (float values, or a
    uint32_t* out-parameter) sees the stored little-endian bytes; go through
    the value instead."""
    total = 0
    roots = [os.path.join(SRC, 'base', 'libs', 'androidfw'), os.path.join(SRC, 'base', 'tools')]
    for root in roots:
        for dirpath, _, names in os.walk(root):
            for name in names:
                if not name.endswith('.cpp') or name.endswith('_test.cpp'):
                    continue
                path = os.path.join(dirpath, name)
                t = u = read(path)
                X = r'([\w.>-]+?(?:->|\.)data)'
                FP = r'\*\s*\(\s*(?:const\s+)?float\s*\*\s*\)\s*'
                # *(float*)(&x->data) = f;  /  *(float*)&x->data = f;
                u = re.sub(FP + r'\(\s*&\s*' + X + r'\s*\)\s*=\s*([^;]+);', r'\1 = ::sdk_le::float_bits(\2);', u)
                u = re.sub(FP + r'&\s*' + X + r'\s*=\s*([^;]+);', r'\1 = ::sdk_le::float_bits(\2);', u)
                # reads: *(const float*)(&x.data), *(const float*)&x.data, *reinterpret_cast<const float*>(&x.data)
                u = re.sub(FP + r'\(\s*&\s*' + X + r'\s*\)', r'::sdk_le::bits_float(\1)', u)
                u = re.sub(FP + r'&\s*' + X + r'\b', r'::sdk_le::bits_float(\1)', u)
                u = re.sub(r'\*\s*reinterpret_cast<\s*(?:const\s+)?float\s*\*\s*>\(\s*&\s*' + X + r'\s*\)',
                           r'::sdk_le::bits_float(\1)', u)
                # status_t err = lookupResourceId(&value->data);
                u = re.sub(r'lookupResourceId\(&(\w+)->data\)',
                           r'[&] { uint32_t sdk_id = \1->data; auto sdk_r = lookupResourceId(&sdk_id); '
                           r'\1->data = sdk_id; return sdk_r; }()', u)
                if u != t:
                    total += sum(1 for a_, b_ in zip(t.splitlines(), u.splitlines()) if a_ != b_)
                    write(path, u)
    DONE.append('androidfw/aapt2: %d float/address uses of Res_value::data converted' % total)



def typespecflags():
    """LoadedArsc's GetFlagsForEntryIndex() returns a type spec's per-entry
    flag word (SPEC_PUBLIC, ...) straight from the file; convert it."""
    path = os.path.join(SRC, 'base', 'libs', 'androidfw', 'include', 'androidfw', 'LoadedArsc.h')
    if not os.path.exists(path):
        return
    t = read(path)
    t, n = re.subn(r'return entry_flags_ptr\.value\(\);', 'return dtohl(entry_flags_ptr.value());', t)
    t, m = re.subn(r'return flags\[entry_index\];', 'return dtohl(flags[entry_index]);', t)
    done = 'dtohl(entry_flags_ptr.value())' in t or 'dtohl(flags[entry_index])' in t
    need(done, 'androidfw: type spec entry flags converted')
    write(path, t)



def stringencoders():
    """String pool encoders write UTF-16 lengths (and aapt2 its characters)
    as host-order units; on disk they are little-endian like the rest of the
    pool. UTF-8 units are bytes, which the swap leaves alone."""
    count = 0
    for rel in (('base', 'libs', 'androidfw', 'StringPool.cpp'), ('base', 'tools', 'aapt2', 'StringPool.cpp')):
        path = os.path.join(SRC, *rel)
        if not os.path.exists(path):
            continue
        t = read(path)
        if 'sdk_le::swap(static_cast<T>' in t:
            count += 1
            continue
        t, a = re.subn(r'\*data\+\+ = (kMask \| \(kMaxSize & \(length >> \(sizeof\(T\) \* 8\)\)\));',
                       r'*data++ = ::sdk_le::swap(static_cast<T>(\1));', t)
        t, b = re.subn(r'\*data\+\+ = length;', r'*data++ = ::sdk_le::swap(static_cast<T>(length));', t)
        t, c = re.subn(r'memcpy\(data, encoded\.data\(\), byte_length\);',
                       r'for (size_t sdk_i = 0; sdk_i < encoded.size(); sdk_i++) {\n'
                       r'      data[sdk_i] = ::sdk_le::swap(static_cast<char16_t>(encoded[sdk_i]));\n'
                       r'    }\n    (void)byte_length;', t)
        need(a == 1 and b == 1 and c == 1, 'aapt2: %s length/UTF-16 encoding (%d %d %d)' % ('/'.join(rel[1:]), a, b, c))
        if 'utils/ByteOrder.h' not in t and 'androidfw/ResourceTypes.h' not in t:
            t = after_includes(t, '#include <utils/ByteOrder.h>\n')
        write(path, t)
        count += 1
    path = os.path.join(SRC, 'base', 'tools', 'aapt', 'StringPool.cpp')
    if os.path.exists(path):
        t = read(path)
        if 'sdk_le::swap' not in t:
            unit = r'std::remove_reference_t<decltype(*(str))>'
            t, a = re.subn(r'\*\(str\)\+\+ = maxMask \| \(\(\(strSize\)>>\(\(chrsz\)\*8\)\)&maxSize\);',
                           r'*(str)++ = ::sdk_le::swap(static_cast<%s>(maxMask | (((strSize)>>((chrsz)*8))&maxSize)));' % unit, t)
            t, b = re.subn(r'\*\(str\)\+\+ = strSize; \\', r'*(str)++ = ::sdk_le::swap(static_cast<%s>(strSize)); \\' % unit, t)
            need(a == 1 and b == 1, 'aapt: ENCODE_LENGTH little-endian (%d %d)' % (a, b))
            write(path, t)
        count += 1
    if count:
        DONE.append('string pool encoders: %d' % count)



FORMAT_CALL = (r'\b(?:ALOG[VDIWE]|printf|fprintf|snprintf|StringPrintf|String8::format|appendFormat)'
               r'\s*\((?:[^;]|;(?!\s*$))*?\);')


def plus_fields(text, fields):
    """Inside printf-style calls, `+field` so a wrapped field is passed as its
    value (varargs would otherwise take the wrapper's stored bytes)."""
    # Whole top-level arguments only (after a comma, up to the next one): a
    # field inside a nested call such as to_string(x.type) is not a vararg.
    field_re = re.compile(r'(,\s*)(\w+(?:(?:->|\.)\w+)*(?:->|\.)(?:%s))(?=\s*[,)])' %
                          '|'.join(sorted(fields, key=len, reverse=True)))
    return re.sub(FORMAT_CALL, lambda m: field_re.sub(r'\1+\2', m.group(0)), text, flags=re.M)


def resource_varargs():
    """Resource-table code: printf-style calls get wrapped fields' values, and
    a field read written as htodl()/htods() (harmless when both were the same
    swap) reads with dtohl()/dtohs()."""
    header = os.path.join(SRC, 'base', 'libs', 'androidfw', 'include', 'androidfw', 'ResourceTypes.h')
    if not os.path.exists(header):
        return
    fields = set(re.findall(r'sdk_le::LeA<\w+> (\w+);', read(header)))
    if not fields:
        return
    changed = 0
    for root in (os.path.join(SRC, 'base', 'libs', 'androidfw'), os.path.join(SRC, 'base', 'tools')):
        for dirpath, _, names in os.walk(root):
            for name in names:
                if not name.endswith(('.cpp', '.h')) or name.endswith(('_test.cpp', 'Test.cpp')):
                    continue
                path = os.path.join(dirpath, name)
                t = read(path)
                u = plus_fields(t, fields)
                u = re.sub(r'\b((?:const\s+)?(?:uint32_t|uint16_t|size_t|int|auto|status_t)\s+\w+\s*=\s*)'
                           r'htod([ls])\((\w+(?:->|\.)[\w.>-]+)\)', r'\1dtoh\2(\3)', u)
                if u != t:
                    write(path, u)
                    changed += 1
    DONE.append('androidfw/aapt/aapt2: %d files pass field values to printf-style calls' % changed)



def dumpmanifest():
    """aapt2 dump badging hands out int32_t pointers straight into an
    attribute's Res_value::data; on big-endian hosts point them at a value
    copy instead (one per field, so stored pointers stay valid)."""
    path = os.path.join(SRC, 'base', 'tools', 'aapt2', 'dump', 'DumpManifest.cpp')
    if not os.path.exists(path):
        return
    t = read(path)
    t, n = re.subn(r'^(\s*)return \(int32_t\*\) &(\w+)->value\.data;',
                   r'#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__\n'
                   r'\1static std::unordered_map<const void*, int32_t> sdk_values;\n'
                   r'\1auto& sdk_value = sdk_values[&\2->value.data];\n'
                   r'\1sdk_value = static_cast<int32_t>(\2->value.data);\n'
                   r'\1return &sdk_value;\n#else\n\g<0>\n#endif', t, flags=re.M)
    done = 'sdk_values[&' in t
    need(done, 'aapt2: dump badging integer attributes')
    if n and '#include <unordered_map>' not in t:
        t = after_includes(t, '#include <unordered_map>\n')
    write(path, t)



def optional_returns():
    """`return x.field;` from a function returning Maybe<T>/std::optional<T>
    needs two user conversions with a wrapped field; return its value."""
    header = os.path.join(SRC, 'base', 'libs', 'androidfw', 'include', 'androidfw', 'ResourceTypes.h')
    if not os.path.exists(header):
        return
    fields = set(re.findall(r'sdk_le::LeA<\w+> (\w+);', read(header)))
    ret = re.compile(r'\breturn (\w+(?:(?:->|\.)\w+)*(?:->|\.)(?:%s));' %
                     '|'.join(sorted(fields, key=len, reverse=True)))
    sig = re.compile(r'(?:Maybe|std::optional)<[^;{}()]*>\s+[\w:~]+\s*\([^;{}]*\)\s*(?:const\s*)?\{')
    changed = 0
    for root in (os.path.join(SRC, 'base', 'libs', 'androidfw'), os.path.join(SRC, 'base', 'tools')):
        for dirpath, _, names in os.walk(root):
            for name in names:
                if not name.endswith(('.cpp', '.h')) or name.endswith(('_test.cpp', 'Test.cpp')):
                    continue
                path = os.path.join(dirpath, name)
                t = read(path)
                out, pos = [], 0
                for m in sig.finditer(t):
                    if m.start() < pos:
                        continue
                    depth, i = 1, m.end()
                    while i < len(t) and depth:
                        depth += {'{': 1, '}': -1}.get(t[i], 0)
                        i += 1
                    body = ret.sub(r'return ::sdk_le::value(\1);', t[m.end():i])
                    out.append(t[pos:m.end()] + body)
                    pos = i
                u = ''.join(out) + t[pos:]
                if u != t:
                    write(path, u)
                    changed += 1
    DONE.append('aapt2: %d files return field values from Maybe/optional functions' % changed)



def f2fs_sizes():
    """Older f2fs-tools (sload_f2fs, until upstream fixed it) store an inode's
    64-bit i_size/i_blocks with a 32-bit swap, which on big-endian lands the
    value in the high word."""
    path = os.path.join(SRC, 'f2fs-tools', 'fsck', 'dir.c')
    if not os.path.exists(path):
        return
    t = read(path)
    t, n = re.subn(r'(\bnode_blk->i\.i_(?:size|blocks) = )cpu_to_le32\(', r'\1cpu_to_le64(', t)
    if n:
        write(path, t)
        DONE.append('f2fs: %d 64-bit inode fields stored with cpu_to_le64' % n)




def f2fs_quota_inodes():
    """__le32 on-disk numbers used as host numbers: the superblock's qf_ino[]
    (an array index in older mkfs, copies into host variables and a comparison
    in the fsck quota code), a SIT journal entry's segno and an inode's
    i_namelen (sload)."""
    root = os.path.join(SRC, 'f2fs-tools')
    if not os.path.isdir(root):
        return
    n = 0
    for sub in ('mkfs', 'fsck', 'include', 'lib'):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            if not name.endswith(('.c', '.h')):
                continue
            path = os.path.join(d, name)
            t = u = read(path)
            q = r'(sb)->qf_ino\[(\w+)\]'
            u = re.sub(r'\[' + q + r'\]', r'[le32_to_cpu(\1->qf_ino[\2])]', u)
            u = re.sub(r'((?<![.>\w])(?:f2fs_ino_t\s+|nid_t\s+|u32\s+)?(?:qf_ino|qf_inum|ino)\s*=\s*)' + q + ';',
                       r'\1le32_to_cpu(\2->qf_ino[\3]);', u)
            u = re.sub(q + r'(\s*==\s*ino\b)', r'le32_to_cpu(\1->qf_ino[\2])\3', u)
            # Journal entries' segno/nid are __le32 as well (flush_sit_journal_entries).
            u = re.sub(r'(\b(?:segno|nid)\s*=\s*)((?:segno|nid)_in_journal\([^;]*\));', r'\1le32_to_cpu(\2);', u)
            # ...and an inode's i_namelen as a memcpy length (older fsck_chk_inode_blk).
            u = re.sub(r'(memcpy\([^;]*?,\s*)(node_blk->i\.i_namelen)\);', r'\1le32_to_cpu(\2));', u)
            if u != t:
                n += sum(1 for a_, b_ in zip(t.splitlines(), u.splitlines()) if a_ != b_)
                write(path, u)
    if n:
        DONE.append('f2fs: %d host uses of on-disk qf_ino/segno converted' % n)


def liblog_priority():
    """Older liblog passes the priority to the host logger as the first byte
    of an int (vec[0].iov_base = (unsigned char*)&prio); on big-endian that
    byte is 0 and every message falls below the minimum priority."""
    for rel in (('logging', 'liblog', 'logger_write.cpp'), ('core', 'liblog', 'logger_write.cpp')):
        path = os.path.join(SRC, *rel)
        if not os.path.exists(path):
            continue
        t = read(path)
        t, n = re.subn(r'^(\s*)vec\[0\]\.iov_base = \(unsigned char\*\)&prio;',
                       r'\1unsigned char sdk_prio = static_cast<unsigned char>(prio);\n'
                       r'\1vec[0].iov_base = &sdk_prio;', t, flags=re.M)
        if n:
            write(path, t)
            DONE.append('liblog: priority byte passed on its own')


def helpers():
    """util::HostToDevice32() and friends wrap htodl()/dtohl() but return a
    plain integer, losing whether the value is already little-endian; make
    them pass the macros' results (and arguments) through unchanged."""
    total = 0
    for path in (os.path.join(SRC, 'base', 'libs', 'androidfw', 'include', 'androidfw', 'Util.h'),
                 os.path.join(SRC, 'base', 'tools', 'aapt2', 'util', 'Util.h')):
        if not os.path.exists(path):
            continue
        t = read(path)
        total += len(re.findall(r'inline auto (?:HostToDevice|DeviceToHost)(?:16|32)\(const T& value\)', t))
        t, n = re.subn(r'inline uint(?:16|32)_t ((?:HostToDevice|DeviceToHost)(?:16|32))\(uint(?:16|32)_t value\) \{\n'
                       r'(\s*)return (\w+)\(value\);\n\}',
                       r'template <typename T>\ninline auto \1(const T& value) {\n\2return \3(value);\n}', t)
        if n:
            write(path, t)
            total += n
    need(total >= 4, 'aapt2: %d HostToDevice/DeviceToHost helpers pass values through' % total)


def writers():
    """Resource writers fill plain integer arrays (string and entry offsets,
    config masks) from BigBuffer::NextBlock<uintN_t>(); hand them out as
    little-endian arrays so every store converts."""
    roots = [os.path.join(SRC, 'base', 'libs', 'androidfw'),
             os.path.join(SRC, 'base', 'tools', 'aapt2')]
    total = 0
    for root in roots:
        for dirpath, _, names in os.walk(root):
            for name in names:
                if not name.endswith('.cpp') or name.endswith('_test.cpp'):
                    continue
                path = os.path.join(dirpath, name)
                t = read(path)
                if 'NextBlock<uint' not in t:
                    continue
                if 'sdk_le::LeA<' in t:
                    total += t.count('reinterpret_cast<sdk_le::LeA<')
                    continue
                t, n = re.subn(r'\buint(16|32)_t\* (\w+)(\s*=\s*)((?:[^;]*?\?\s*)?)(\w+(?:->|\.)NextBlock<uint\1_t>\([^;]*?\))',
                               r'sdk_le::LeA<uint\1_t>* \2\3\4reinterpret_cast<sdk_le::LeA<uint\1_t>*>(\5)', t)
                # A bare store into a fresh block: *w.NextBlock<uint32_t>() = v;
                t, m = re.subn(r'\*(\w+(?:->|\.)NextBlock<uint(16|32)_t>\(\))(\s*=)',
                               r'*reinterpret_cast<sdk_le::LeA<uint\2_t>*>(\1)\3', t)
                # References into those arrays: uint32_t& x = arr[i];
                for arr in re.findall(r'sdk_le::LeA<uint(?:16|32)_t>\* (\w+)\s*=', t):
                    t = re.sub(r'\buint(?:16|32)_t& (\w+) = %s\[' % arr, r'auto& \1 = %s[' % arr, t)
                if n or m:
                    if 'utils/ByteOrder.h' not in t and 'androidfw/ResourceTypes.h' not in t:
                        t = after_includes(t, '#include <utils/ByteOrder.h>\n')
                    write(path, t)
                    total += n + m
    need(total >= 3 or not os.path.isdir(roots[1]), 'aapt2: %d raw offset arrays made little-endian' % total)


DEX_SWAPPER = r'''
// --- big-endian hosts (patch-bigendian.py) ---------------------------------
// ART reads dex files in host byte order. On a big-endian host, convert a
// little-endian dex in place before it is opened, as Dalvik's DexSwapVerify
// did, and remember the original checksum so verification still checks the
// bytes as they were on disk.
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
namespace {
std::mutex g_sdk_swapped_lock;
std::map<const uint8_t*, uint32_t>& SdkSwapped() {
  static auto* m = new std::map<const uint8_t*, uint32_t>();
  return *m;
}
inline uint16_t SdkLd16(const uint8_t* p) { return p[0] | (p[1] << 8); }
inline uint32_t SdkLd32(const uint8_t* p) {
  return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
struct SdkDexSwapper {
  uint8_t* base;
  size_t size;
  bool ok = true;
  bool In(size_t off, size_t n) const { return off <= size && n <= size - off; }
  void U16(size_t off, size_t n = 1) {
    if (!In(off, n * 2)) { ok = false; return; }
    for (size_t i = 0; i < n; i++) std::swap(base[off + 2 * i], base[off + 2 * i + 1]);
  }
  void U32(size_t off, size_t n = 1) {
    if (!In(off, n * 4)) { ok = false; return; }
    for (size_t i = 0; i < n; i++) std::reverse(base + off + 4 * i, base + off + 4 * i + 4);
  }
  void U64(size_t off, size_t n = 1) {
    if (!In(off, n * 8)) { ok = false; return; }
    for (size_t i = 0; i < n; i++) std::reverse(base + off + 8 * i, base + off + 8 * i + 8);
  }
  static size_t Align4(size_t x) { return (x + 3) & ~static_cast<size_t>(3); }
  uint32_t Uleb(size_t* off) {
    uint32_t v = 0;
    for (int shift = 0; *off < size && shift < 35; shift += 7) {
      uint8_t b = base[(*off)++];
      v |= static_cast<uint32_t>(b & 0x7f) << shift;
      if (!(b & 0x80)) return v;
    }
    ok = false;
    return 0;
  }
  int32_t Sleb(size_t* off) {
    int32_t v = 0;
    int shift = 0;
    uint8_t b = 0;
    do {
      if (*off >= size || shift >= 35) { ok = false; return 0; }
      b = base[(*off)++];
      v |= static_cast<int32_t>(b & 0x7f) << shift;
      shift += 7;
    } while (b & 0x80);
    if (shift < 32 && (b & 0x40)) v |= -(static_cast<int32_t>(1) << shift);
    return v;
  }
  void Insns(size_t off, uint32_t count) {
    size_t i = 0;
    while (ok && i < count) {
      size_t at = off + 2 * i;
      uint16_t unit = SdkLd16(base + at);
      size_t len;
      if (unit == 0x0100) {  // packed-switch payload
        len = 4 + static_cast<size_t>(SdkLd16(base + at + 2)) * 2;
        if (i + len > count) break;
        U16(at, 2);
        U32(at + 4, (len - 2) / 2);
      } else if (unit == 0x0200) {  // sparse-switch payload
        len = 2 + static_cast<size_t>(SdkLd16(base + at + 2)) * 4;
        if (i + len > count) break;
        U16(at, 2);
        U32(at + 4, (len - 2) / 2);
      } else if (unit == 0x0300) {  // fill-array-data payload
        uint16_t width = SdkLd16(base + at + 2);
        uint32_t elems = SdkLd32(base + at + 4);
        len = 4 + (static_cast<uint64_t>(width) * elems + 1) / 2;
        if (i + len > count) break;
        U16(at, 2);
        U32(at + 4);
        if (width == 2) U16(at + 8, elems);
        else if (width == 4) U32(at + 8, elems);
        else if (width == 8) U64(at + 8, elems);
      } else {
        // An instruction's length follows from its opcode alone.
        uint16_t host[4] = {unit, 0, 0, 0};
        len = Instruction::At(host)->SizeInCodeUnits();
        if (len == 0 || i + len > count) break;
        U16(at, len);
      }
      i += len;
    }
    if (i != count) ok = false;
  }
  size_t CodeItem(size_t off) {
    off = Align4(off);
    if (!In(off, 16)) { ok = false; return size; }
    uint16_t tries = SdkLd16(base + off + 6);
    uint32_t insns_size = SdkLd32(base + off + 12);
    U16(off, 4);
    U32(off + 8, 2);
    size_t insns = off + 16;
    if (!In(insns, static_cast<size_t>(insns_size) * 2)) { ok = false; return size; }
    Insns(insns, insns_size);
    size_t end = insns + static_cast<size_t>(insns_size) * 2;
    if (tries != 0) {
      if (insns_size & 1) end += 2;
      for (uint16_t t = 0; t < tries && ok; t++, end += 8) {
        U32(end);
        U16(end + 4, 2);
      }
      uint32_t lists = Uleb(&end);
      for (uint32_t l = 0; l < lists && ok; l++) {
        int32_t n = Sleb(&end);
        for (int32_t h = 0; h < (n < 0 ? -n : n) && ok; h++) {
          Uleb(&end);
          Uleb(&end);
        }
        if (n <= 0) Uleb(&end);
      }
    }
    return end;
  }
  bool Run() {
    if (!In(0, 0x70)) return false;
    const uint32_t header_size = SdkLd32(base + 36);
    const uint32_t map_off = SdkLd32(base + 52);
    const uint32_t class_defs = SdkLd32(base + 96);
    if (header_size < 0x70 || !In(0, header_size) || !In(map_off, 4)) return false;
    U32(8);                             // checksum
    U32(32, (header_size - 32) / 4);    // file_size .. data_off (and v41's fields)
    const uint32_t items = SdkLd32(base + map_off);
    if (!In(map_off + 4, static_cast<size_t>(items) * 12)) return false;
    struct Item { uint16_t type; uint32_t count, off; };
    std::vector<Item> map;
    for (uint32_t k = 0; k < items; k++) {
      const uint8_t* p = base + map_off + 4 + 12 * k;
      map.push_back({SdkLd16(p), SdkLd32(p + 4), SdkLd32(p + 8)});
    }
    U32(map_off);
    for (uint32_t k = 0; k < items; k++) {
      U16(map_off + 4 + 12 * k, 2);
      U32(map_off + 8 + 12 * k, 2);
    }
    for (const Item& it : map) {
      size_t off = it.off;
      switch (it.type) {
        case 0x0001: case 0x0002: case 0x0007:  // string_id, type_id, call_site_id
          U32(off, it.count);
          break;
        case 0x0003:  // proto_id: shorty u4, return type u2, pad u2, parameters u4
          for (uint32_t i = 0; i < it.count; i++, off += 12) { U32(off); U16(off + 4, 2); U32(off + 8); }
          break;
        case 0x0004: case 0x0005:  // field_id / method_id: u2 u2 u4
          for (uint32_t i = 0; i < it.count; i++, off += 8) { U16(off, 2); U32(off + 4); }
          break;
        case 0x0006:  // class_def
          for (uint32_t i = 0; i < it.count; i++, off += 32) {
            U16(off, 2); U32(off + 4); U16(off + 8, 2); U32(off + 12, 5);
          }
          break;
        case 0x0008:  // method_handle: 4 x u2
          U16(off, static_cast<size_t>(it.count) * 4);
          break;
        case 0x1001:  // type_list
          for (uint32_t i = 0; i < it.count && ok; i++) {
            off = Align4(off);
            if (!In(off, 4)) { ok = false; break; }
            uint32_t n = SdkLd32(base + off);
            U32(off);
            U16(off + 4, n);
            off += 4 + static_cast<size_t>(n) * 2;
          }
          break;
        case 0x1002: case 0x1003:  // annotation_set_ref_list, annotation_set_item
          for (uint32_t i = 0; i < it.count && ok; i++) {
            off = Align4(off);
            if (!In(off, 4)) { ok = false; break; }
            uint32_t n = SdkLd32(base + off);
            U32(off, 1 + static_cast<size_t>(n));
            off += 4 + static_cast<size_t>(n) * 4;
          }
          break;
        case 0x2001:  // code_item
          for (uint32_t i = 0; i < it.count && ok; i++) off = CodeItem(off);
          break;
        case 0x2006:  // annotations_directory_item
          for (uint32_t i = 0; i < it.count && ok; i++) {
            off = Align4(off);
            if (!In(off, 16)) { ok = false; break; }
            size_t pairs = static_cast<size_t>(SdkLd32(base + off + 4)) + SdkLd32(base + off + 8) +
                           SdkLd32(base + off + 12);
            U32(off, 4);
            U32(off + 16, pairs * 2);
            off += 16 + pairs * 8;
          }
          break;
        case 0xF000:  // hiddenapi_class_data: size, then one offset per class_def
          U32(off, 1 + static_cast<size_t>(class_defs));
          break;
        default:  // header, map, class_data, string_data, debug_info, annotation, encoded_array
          break;
      }
      if (!ok) return false;
    }
    return ok;
  }
};
}  // namespace

void SdkSwapDexToHostIfNeeded(const uint8_t* begin, size_t size) {
  if (size < 0x70 || memcmp(begin, "dex\n", 4) != 0 || SdkLd32(begin + 40) != 0x12345678) {
    return;  // not a little-endian dex (or already converted)
  }
  uint32_t checksum = DexFile::CalculateChecksum(begin, size);
  SdkDexSwapper swapper{const_cast<uint8_t*>(begin), size};
  swapper.Run();  // a malformed file stays malformed; verification reports it
  std::lock_guard<std::mutex> lock(g_sdk_swapped_lock);
  SdkSwapped()[begin] = checksum;
}

bool SdkSwappedDexChecksum(const uint8_t* begin, uint32_t* checksum) {
  std::lock_guard<std::mutex> lock(g_sdk_swapped_lock);
  auto it = SdkSwapped().find(begin);
  if (it == SdkSwapped().end()) return false;
  *checksum = it->second;
  return true;
}
#else
void SdkSwapDexToHostIfNeeded(const uint8_t*, size_t) {}
bool SdkSwappedDexChecksum(const uint8_t*, uint32_t*) { return false; }
#endif
'''


def dexfile():
    dex = os.path.join(SRC, 'art', 'libdexfile', 'dex')
    dex_file = os.path.join(dex, 'dex_file.cc')
    loader = os.path.join(dex, 'dex_file_loader.cc')
    if not os.path.exists(dex_file) or not os.path.exists(loader):
        return
    t = read(dex_file)
    if 'SdkSwapDexToHostIfNeeded' in t:
        return
    head = ('#include <algorithm>\n#include <cstring>\n#include <map>\n#include <mutex>\n#include <vector>\n'
            '#include "dex_instruction.h"\n')
    t = after_includes(t, head)
    # The swapper lives in namespace art, after the file's first use of it.
    m = re.search(r'^namespace art \{\n', t, re.M)
    need(m, 'dex: namespace art found')
    decl = ('bool SdkSwappedDexChecksum(const uint8_t* begin, uint32_t* checksum);\n'
            'void SdkSwapDexToHostIfNeeded(const uint8_t* begin, size_t size);\n')
    t = t[:m.end()] + '\n' + decl + t[m.end():]
    # Checksum of a converted file: the one its on-disk bytes had.
    t, n = re.subn(r'(uint32_t DexFile::CalculateChecksum\(const uint8_t\* begin, size_t size\) \{\n)',
                   r'\1  if (uint32_t sdk_sum; SdkSwappedDexChecksum(begin, &sdk_sum)) return sdk_sum;\n', t)
    need(n == 1, 'dex: checksum of converted files')
    t = re.sub(r'(\n\}  // namespace art\n?\s*)$', '\n' + DEX_SWAPPER.replace('\\', '\\\\') + r'\1', t)
    need('SdkDexSwapper' in t, 'dex: swapper added')
    write(dex_file, t)

    t = read(loader)
    m = re.search(r'^namespace art \{\n', t, re.M)
    t = t[:m.end()] + '\nvoid SdkSwapDexToHostIfNeeded(const uint8_t* begin, size_t size);\n' + t[m.end():]
    if 'const uint8_t* base = container->Begin();\n  size_t size = container->Size();\n' in t:  # 34.0.x
        need(True, 'dex: hooked into OpenCommon')
        t = t.replace('const uint8_t* base = container->Begin();\n  size_t size = container->Size();\n',
                      'const uint8_t* base = container->Begin();\n  size_t size = container->Size();\n'
                      '  SdkSwapDexToHostIfNeeded(base, size);\n', 1)
    elif 'const size_t size = container->End() - base;\n' in t:
        need(True, 'dex: hooked into OpenCommon')
        t = t.replace('const size_t size = container->End() - base;\n',
                      'const size_t size = container->End() - base;\n'
                      '  SdkSwapDexToHostIfNeeded(base, size);\n', 1)
    else:
        t, n = re.subn(r'(DexFileLoader::OpenCommon\(const uint8_t\* base,\n\s*size_t size,[^{]*\{\n)',
                       r'\1  SdkSwapDexToHostIfNeeded(base, size);\n', t, count=1)
        need(n == 1, 'dex: hooked into OpenCommon')
    write(loader, t)



DEXDUMP_UNIT = r"""
// patch-bigendian.py: the file's bytes for code unit `at` of the instruction
// starting at `start`, from the host-order units the loader converted to
// (payload words were converted whole, so take their halves).
static void sdkDumpUnit(const u2* insns, u4 start, u4 at) {
  const u2* p = insns + start;
  const u4 i = at - start;
  u2 unit = p[i];
  const u2 ident = p[0];
  auto word = [&](u4 k) { u4 v; memcpy(&v, &p[k & ~1u], 4); return (k & 1) ? u2(v >> 16) : u2(v); };
  if ((ident == 0x0100 || ident == 0x0200) && i >= 2) {
    unit = word(i);
  } else if (ident == 0x0300 && i >= 2) {
    const u2 width = p[1];
    if (i < 4) {
      unit = word(i);
    } else if (width == 1) {
      const u1* b = reinterpret_cast<const u1*>(&p[i]);
      fprintf(gOutFile, " %02x%02x", b[0], b[1]);
      return;
    } else if (width == 4) {
      unit = word(i);  // elements start at unit 4, so word pairs line up
    } else if (width == 8) {
      u8 v;
      memcpy(&v, &p[4 + ((i - 4) & ~3u)], 8);
      unit = u2(v >> (16 * ((i - 4) & 3)));
    }
  }
  fprintf(gOutFile, " %02x%02x", unit & 0xff, unit >> 8);
}
"""


def dexdump():
    path = os.path.join(SRC, 'art', 'dexdump', 'dexdump.cc')
    if not os.path.exists(path):
        return
    t = read(path)
    if 'sdkDumpUnit' in t:
        return
    t, n = re.subn(r'const u1\* bytePtr = \(const u1\*\) &(accessor\.Insns\(\)|insns)\[insnIdx \+ i\];\n'
                   r'(\s*)fprintf\(gOutFile, " %02x%02x", bytePtr\[0\], bytePtr\[1\]\);',
                   r'sdkDumpUnit(\1, insnIdx, insnIdx + i);', t)
    need(n == 1, 'dexdump: raw code unit bytes')
    # Before the first function that uses it.
    m = re.search(r'^static void dumpInstruction\(', t, re.M)
    need(m, 'dexdump: dumpInstruction found')
    t = t[:m.start()] + DEXDUMP_UNIT.lstrip('\n') + '\n' + t[m.start():]
    write(path, t)


ziparchive()
byteorder()
resourcetypes()
stringpool()
punning()
typespecflags()
stringencoders()
resource_varargs()
dumpmanifest()
optional_returns()
f2fs_sizes()
f2fs_quota_inodes()
liblog_priority()
helpers()
writers()
dexfile()
dexdump()
print('patch-bigendian.py: ' + ('; '.join(DONE) if DONE else 'already applied'))
