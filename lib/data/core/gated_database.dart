import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'database_access_gate.dart';
import 'gated_batch.dart';
import 'gated_transaction.dart';

/// Protected wrapper around sqflite [Database].
///
/// Guarantees:
/// 1. Admission gating on every database query, mutation, batch, and transaction.
/// 2. Bounded transaction scopes: nested calls within a transaction share admission
///    without deadlocking or creating secondary tickets.
/// 3. Escaped transaction handle rejection.
/// 4. Preserves full sqflite database semantics and compatibility.
class GatedDatabase implements Database {
  final Database _rawDb;
  final DatabaseAccessGate _gate;

  GatedDatabase(this._rawDb, this._gate);

  Database get rawDb => _rawDb;
  DatabaseAccessGate get gate => _gate;

  @override
  String get path => _rawDb.path;

  @override
  bool get isOpen => _rawDb.isOpen;

  @override
  Database get database => this;

  @override
  Future<void> close() async {
    await _rawDb.close();
  }

  @override
  Batch batch() {
    return GatedBatch(_rawDb.batch(), _gate);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    return _gate.admit(() => _rawDb.execute(sql, arguments));
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) {
    return _gate.admit(() => _rawDb.rawInsert(sql, arguments));
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    return _gate.admit(
      () => _rawDb.insert(
        table,
        values,
        nullColumnHack: nullColumnHack,
        conflictAlgorithm: conflictAlgorithm,
      ),
    );
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) {
    return _gate.admit(() => _rawDb.rawUpdate(sql, arguments));
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    return _gate.admit(
      () => _rawDb.update(
        table,
        values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm,
      ),
    );
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) {
    return _gate.admit(() => _rawDb.rawDelete(sql, arguments));
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) {
    return _gate.admit(
      () => _rawDb.delete(table, where: where, whereArgs: whereArgs),
    );
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    return _gate.admit(() => _rawDb.rawQuery(sql, arguments));
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
  }) {
    return _gate.admit(
      () => _rawDb.query(
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
      ),
    );
  }

  @override
  Future<QueryCursor> rawQueryCursor(
    String sql,
    List<Object?>? arguments, {
    int? bufferSize,
  }) {
    return _gate.admit(
      () => _rawDb.rawQueryCursor(sql, arguments, bufferSize: bufferSize),
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
  }) {
    return _gate.admit(
      () => _rawDb.queryCursor(
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
      ),
    );
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) {
    return _gate.admit(() async {
      return await _rawDb.transaction<T>((rawTxn) async {
        final gatedTxn = GatedTransaction(rawTxn, _gate);
        final token = TransactionAdmissionToken();
        try {
          return await runZoned(
            () => action(gatedTxn),
            zoneValues: {
              kGatedTransactionToken: token,
              kGatedTransactionInstance: gatedTxn,
            },
          );
        } finally {
          token.invalidate();
          gatedTxn.invalidate();
        }
      }, exclusive: exclusive);
    });
  }

  @override
  Future<T> readTransaction<T>(
    Future<T> Function(Transaction txn) action,
  ) {
    return _gate.admit(() async {
      return await _rawDb.readTransaction<T>((rawTxn) async {
        final gatedTxn = GatedTransaction(rawTxn, _gate);
        final token = TransactionAdmissionToken();
        try {
          return await runZoned(
            () => action(gatedTxn),
            zoneValues: {
              kGatedTransactionToken: token,
              kGatedTransactionInstance: gatedTxn,
            },
          );
        } finally {
          token.invalidate();
          gatedTxn.invalidate();
        }
      });
    });
  }

  @override
  @Deprecated('Dev only')
  Future<T> devInvokeMethod<T>(String method, [Object? arguments]) {
    return _gate.admit(() => _rawDb.devInvokeMethod<T>(method, arguments));
  }

  @override
  @Deprecated('Dev only')
  Future<T> devInvokeSqlMethod<T>(
    String method,
    String sql, [
    List<Object?>? arguments,
  ]) {
    return _gate.admit(
      () => _rawDb.devInvokeSqlMethod<T>(method, sql, arguments),
    );
  }
}
