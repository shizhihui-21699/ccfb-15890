/// Canonical JSON serialization (RFC 8785 style, simplified).
///
/// Every hash and signature in the evidence system is computed over the exact
/// same byte sequence on device and server, so encoding rules must be
/// deterministic: maps are emitted with keys sorted lexicographically by UTF-16
/// code unit, no whitespace, numbers use their minimal round-trippable form.
/// Only JSON-native types are accepted — anything else throws, because an
/// object with ambiguous encoding would make signatures unverifiable.
String canonicalJson(Object? value) {
  final buf = StringBuffer();
  _write(buf, value);
  return buf.toString();
}

void _write(StringBuffer buf, Object? value) {
  if (value == null) {
    buf.write('null');
  } else if (value is bool) {
    buf.write(value ? 'true' : 'false');
  } else if (value is int) {
    buf.write(value.toString());
  } else if (value is double) {
    if (value.isNaN || value.isInfinite) {
      throw ArgumentError('Non-finite numbers cannot be canonicalized');
    }
    buf.write(value.toString());
  } else if (value is String) {
    _writeString(buf, value);
  } else if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    buf.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) buf.write(',');
      _writeString(buf, keys[i]);
      buf.write(':');
      _write(buf, value[keys[i]]);
    }
    buf.write('}');
  } else if (value is Iterable) {
    buf.write('[');
    var first = true;
    for (final item in value) {
      if (!first) buf.write(',');
      first = false;
      _write(buf, item);
    }
    buf.write(']');
  } else if (value is DateTime) {
    // Always UTC ISO-8601 with offset Z.
    _writeString(buf, value.toUtc().toIso8601String());
  } else {
    throw ArgumentError(
      'Type ${value.runtimeType} has no canonical JSON encoding',
    );
  }
}

void _writeString(StringBuffer buf, String s) {
  buf.write('"');
  final codes = s.codeUnits;
  for (final c in codes) {
    switch (c) {
      case 0x22:
        buf.write(r'\"');
      case 0x5C:
        buf.write(r'\\');
      case 0x08:
        buf.write(r'\b');
      case 0x0C:
        buf.write(r'\f');
      case 0x0A:
        buf.write(r'\n');
      case 0x0D:
        buf.write(r'\r');
      case 0x09:
        buf.write(r'\t');
      default:
        if (c < 0x20) {
          buf.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          buf.writeCharCode(c);
        }
    }
  }
  buf.write('"');
}
