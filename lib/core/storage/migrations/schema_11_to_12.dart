import 'package:bb_mobile/core/storage/sqlite_database.steps.dart';
import 'package:drift/drift.dart';

class Schema11To12 {
  static Future<void> migrate(Migrator m, Schema12 schema12) async {
    // Add enableSsl column to mempoolServers table with default value true
    final mempoolServers = schema12.mempoolServers;
    await m.addColumn(mempoolServers, mempoolServers.enableSsl);
  }
}
