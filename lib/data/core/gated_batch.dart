import 'package:sqflite/sqflite.dart';
import 'database_access_gate.dart';
import 'gated_transaction.dart';

/// Protected wrapper around sqflite [Batch].
///
/// Guarantees that batch execution/commit is gated by [DatabaseAccessGate],
/// and verifies that parent transactions have not escaped their valid lifetime.
class GatedBatch implements Batch {
  final Batch _rawBatch;
  final DatabaseAccessGate _gate;
  final GatedTransaction? _parentTransaction;

  GatedBatch(
    this._rawBatch,
    this._gate, {
    GatedTransaction? parentTransaction,
  }) : _parentTransaction = parentTransaction;

  Batch get rawBatch => _rawBatch;

  void _checkParentValidity() {
    _parentTransaction?.checkValid();
  }

  @override
  int get length => _rawBatch.length;

  @override
  void execute(String sql, [List<Object?>? arguments]) {
    _checkParentValidity();
    _rawBatch.execute(sql, arguments);
  }

  @override
  void rawInsert(String sql, [List<Object?>? arguments]) {
    _checkParentValidity();
    _rawBatch.rawInsert(sql, arguments);
  }

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _checkParentValidity();
    _rawBatch.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  void rawUpdate(String sql, [List<Object?>? arguments]) {
    _checkParentValidity();
    _rawBatch.rawUpdate(sql, arguments);
  }

  @override
  void update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _checkParentValidity();
    _rawBatch.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  void rawDelete(String sql, [List<Object?>? arguments]) {
    _checkParentValidity();
    _rawBatch.rawDelete(sql, arguments);
  }

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) {
    _checkParentValidity();
    _rawBatch.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  void query(
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
  }) {
    _checkParentValidity();
    _rawBatch.query(
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
  void rawQuery(String sql, [List<Object?>? arguments]) {
    _checkParentValidity();
    _rawBatch.rawQuery(sql, arguments);
  }

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) {
    _checkParentValidity();
    return _gate.admit(
      () => _rawBatch.commit(
        exclusive: exclusive,
        noResult: noResult,
        continueOnError: continueOnError,
      ),
    );
  }

  @override
  Future<List<Object?>> apply({bool? noResult, bool? continueOnError}) {
    _checkParentValidity();
    return _gate.admit(
      () => _rawBatch.apply(
        noResult: noResult,
        continueOnError: continueOnError,
      ),
    );
  }
}
