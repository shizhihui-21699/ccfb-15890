import 'dart:convert';
import 'dart:io';

/// Persistence seam for the ledger. The ledger itself stays storage-agnostic,
/// which keeps the whole evidence engine unit-testable without a filesystem.
abstract class LedgerStorage {
  Future<void> appendJson(Map<String, Object?> json);

  /// Must return events in append order.
  Future<List<Map<String, Object?>>> readAll();

  Future<void> flush();
}

/// In-memory storage for tests and the demo.
class MemoryLedgerStorage implements LedgerStorage {
  final List<Map<String, Object?>> rows = [];

  @override
  Future<void> appendJson(Map<String, Object?> json) async => rows.add(json);

  @override
  Future<List<Map<String, Object?>>> readAll() async =>
      List<Map<String, Object?>>.from(rows);

  @override
  Future<void> flush() async {}
}

/// Append-only JSON Lines file.
///
/// Writes go through an [IOSink] so scanning hundreds of parcels costs one
/// buffered write per event rather than open/write/close cycles. The file is
/// append-only by contract; the chain verification (not file permissions) is
/// what makes tampering detectable — a leader with root access can edit the
/// file, but cannot recompute the server-pinned checkpoint.
class JsonlLedgerStorage implements LedgerStorage {
  final File file;
  IOSink? _sink;
  bool _exists;

  JsonlLedgerStorage(this.file) : _exists = file.existsSync();

  @override
  Future<void> appendJson(Map<String, Object?> json) async {
    final sink = _sink ??= file.openWrite(
      mode: FileMode.append,
      encoding: utf8,
    );
    sink.writeln(jsonEncode(json));
  }

  @override
  Future<List<Map<String, Object?>>> readAll() async {
    if (!_exists && !file.existsSync()) return const [];
    final lines = await file.readAsLines();
    return lines
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();
  }

  @override
  Future<void> flush() async {
    await _sink?.flush();
  }

  Future<void> close() async {
    await _sink?.close();
    _sink = null;
    _exists = true;
  }
}
