import 'package:sqflite/sqflite.dart';
import 'database_access_gate.dart';
import 'gated_batch.dart';

/// Protected wrapper around sqflite [Transaction].
///
/// Guarantees:
/// 1. Transaction scope enforcement: Escaped transaction handles are invalidated
///    immediately when the transaction callback completes. Any subsequent operations
///    throw [DatabaseTransactionClosedException].
/// 2. Batch operations created within the transaction are bounded by its lifetime.
/// 3. Injected executor compatibility: Can be passed anywhere a [DatabaseExecutor] is expected.
class GatedTransaction implements Transaction {
  final Transaction _rawTxn;
  final DatabaseAccessGate _gate;
  bool _isClosed = false;

  GatedTransaction(this._rawTxn, this._gate);

  Transaction get rawTxn => _rawTxn;
  bool get isClosed => _isClosed;

  /// Internal invalidator called when the transaction callback finishes.
  void invalidate() {
    _isClosed = true;
  }

  /// Asserts that this transaction handle is currently active and within its callback scope.
  void checkValid() {
    if (_isClosed) {
      throw const DatabaseTransactionClosedException(
        'Cannot execute operations on closed or escaped transaction handle',
      );
    }
  }

  @override
  Database get database => _gate.wrapDatabase(_rawTxn.database);

  @override
  Batch batch() {
    checkValid();
    return GatedBatch(
      _rawTxn.batch(),
      _gate,
      parentTransaction: this,
    );
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    checkValid();
    return await _rawTxn.execute(sql, arguments);
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async {
    checkValid();
    return await _rawTxn.rawInsert(sql, arguments);
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    checkValid();
    return await _rawTxn.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    checkValid();
    return await _rawTxn.rawUpdate(sql, arguments);
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    checkValid();
    return await _rawTxn.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async {
    checkValid();
    return await _rawTxn.rawDelete(sql, arguments);
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    checkValid();
    return await _rawTxn.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    checkValid();
    return await _rawTxn.rawQuery(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    checkValid();
    return await _rawTxn.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<QueryCursor> rawQueryCursor(
    String sql,
    List<Object?>? arguments, {
    int? bufferSize,
  }) async {
    checkValid();
    return await _rawTxn.rawQueryCursor(
      sql,
      arguments,
      bufferSize: bufferSize,
    );
  }

  @override
  Future<QueryCursor> queryCursor(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
    int? bufferSize,
  }) async {
    checkValid();
    return await _rawTxn.queryCursor(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      bufferSize: bufferSize,
    );
  }
}
