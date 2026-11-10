import 'dart:io';
import 'package:path/path.dart' as p;

/// Security utility for canonical filesystem validation of database files, sidecars,
/// journals, and staging directories prior to protected mutations.
///
/// Enforces:
/// 1. Directory containment and parent directory symlink resolution.
/// 2. Prevention of path traversal and symlink escapes.
/// 3. Sidecar association to the authorized active database.
/// 4. Disposable environment protection against accidental production database access.
class CanonicalPathValidator {
  CanonicalPathValidator._();

  /// Permitted filename suffixes for database mutation targets and sidecars.
  static const List<String> _permittedDatabaseExtensions = [
    '.db',
    '-wal',
    '-shm',
    '.pre_restore_backup',
    '.new_swap',
    '.json',
    '.tmp',
  ];

  /// Regex pattern matching authorized timestamped quarantine and archive artifacts.
  static final RegExp _quarantineOrArchivePattern = RegExp(
    r'(\.db|\.new_swap|\.pre_restore_backup|-wal|-shm|\.json|\.tmp)\.[a-zA-Z0-9_]+_\d+$',
  );

  /// Asserts that [targetPath] is safe for database filesystem mutation.
  /// Resolves canonical parent and target paths to prevent symlink traversal and escapes.
  static void assertSafeDatabaseMutationPath(
    String targetPath, {
    bool isDisposableRequired = false,
  }) {
    final trimmed = targetPath.trim();
    if (trimmed.isEmpty) {
      throw StateError('Security violation: Database target path cannot be empty');
    }

    final targetFile = File(trimmed);
    final parentDir = targetFile.parent;
    if (!parentDir.existsSync()) {
      if ((Platform.isAndroid || Platform.isIOS) && trimmed.contains('.dart_tool')) {
        throw StateError(
          'Security violation: Database target path cannot point to .dart_tool on mobile devices: $trimmed',
        );
      }
      parentDir.createSync(recursive: true);
    }

    final canonicalParent = parentDir.resolveSymbolicLinksSync();
    final normalizedTarget = p.normalize(trimmed);
    final baseName = p.basename(normalizedTarget);

    // Resolve target path if it exists to detect symlink escapes
    String canonicalTarget;
    if (targetFile.existsSync() || FileSystemEntity.isLinkSync(trimmed)) {
      try {
        canonicalTarget = targetFile.resolveSymbolicLinksSync();
      } on FileSystemException {
        canonicalTarget = p.normalize(p.join(canonicalParent, baseName));
      }
    } else {
      canonicalTarget = p.normalize(p.join(canonicalParent, baseName));
    }

    // 1. Directory containment check
    final isContained = p.isWithin(canonicalParent, canonicalTarget) ||
        canonicalTarget == p.normalize(p.join(canonicalParent, baseName));
    if (!isContained) {
      throw StateError(
        'Security violation: Database target $trimmed ($canonicalTarget) escapes parent directory $canonicalParent',
      );
    }

    // 2. Traversal check
    if (normalizedTarget.contains('..') || trimmed.contains('/../') || trimmed.contains(r'\..\')) {
      throw StateError('Security violation: Path traversal detected in database target: $trimmed');
    }

    // 3. Extension / artifact pattern check
    final isPermittedExtension = _permittedDatabaseExtensions.any((ext) => baseName.endsWith(ext)) ||
        _quarantineOrArchivePattern.hasMatch(baseName) ||
        baseName.contains('.corrupt_') ||
        baseName.contains('.archive_backup_');
    if (!isPermittedExtension) {
      throw StateError('Security violation: Database target $trimmed has unauthorized filename format: $baseName');
    }

    // 4. Disposable isolation assertion
    if (isDisposableRequired) {
      final canonicalBaseName = p.basename(canonicalTarget);
      if (canonicalBaseName == 'spendx.db' ||
          canonicalBaseName == 'spendx.db-wal' ||
          canonicalBaseName == 'spendx.db-shm' ||
          !canonicalBaseName.contains('spendx_m45c_qualification.db')) {
        throw StateError(
          'FATAL SAFETY ABORT: Production database access forbidden during disposable qualification: $canonicalTarget',
        );
      }
    }
  }

  /// Asserts that [sidecarFile] belongs to [activeDbPath] and is safely contained
  /// in the same directory without symlink escaping.
  static void assertSafeSidecarMutation(
    File sidecarFile, {
    required String activeDbPath,
    bool isDisposableRequired = false,
  }) {
    assertSafeDatabaseMutationPath(sidecarFile.path, isDisposableRequired: isDisposableRequired);

    final activeParent = File(activeDbPath).parent.resolveSymbolicLinksSync();
    final sidecarParent = sidecarFile.parent.resolveSymbolicLinksSync();

    if (activeParent != sidecarParent) {
      throw StateError(
        'Security violation: Sidecar ${sidecarFile.path} is not in active database directory $activeParent',
      );
    }

    final activeBase = p.basename(activeDbPath);
    final sidecarBase = p.basename(sidecarFile.path);

    if (!sidecarBase.startsWith(activeBase)) {
      throw StateError(
        'Security violation: Sidecar $sidecarBase does not match expected active prefix $activeBase',
      );
    }
  }

  /// Asserts that [stagingDir] is an authorized restore staging directory.
  static void assertSafeStagingDirectory(
    Directory stagingDir, {
    String expectedPrefix = 'spendx_restore_stage_',
  }) {
    final normalized = p.normalize(stagingDir.path);
    final base = p.basename(normalized);
    if (!base.contains(expectedPrefix)) {
      throw StateError(
        'Security violation: Staging directory $normalized does not match authorized prefix $expectedPrefix',
      );
    }

    final parent = stagingDir.parent;
    if (parent.existsSync()) {
      final canonicalParent = parent.resolveSymbolicLinksSync();
      final canonicalDir = stagingDir.existsSync() ? stagingDir.resolveSymbolicLinksSync() : normalized;
      if (!p.isWithin(canonicalParent, canonicalDir) && canonicalDir != p.normalize(p.join(canonicalParent, base))) {
        throw StateError(
          'Security violation: Staging directory $normalized escapes parent directory $canonicalParent',
        );
      }
    }
  }

  /// Asserts that [journalFile] belongs to the database directory of [activeDbPath].
  static void assertSafeJournalMutation(
    File journalFile, {
    required String activeDbPath,
  }) {
    final activeParent = File(activeDbPath).parent.resolveSymbolicLinksSync();
    final journalParent = journalFile.parent.resolveSymbolicLinksSync();

    if (activeParent != journalParent) {
      throw StateError(
        'Security violation: Journal file ${journalFile.path} is not in database directory $activeParent',
      );
    }

    final base = p.basename(journalFile.path);
    final isAuthorizedJournal = base == 'spendx_restore_journal.json' ||
        base == 'spendx_restore_journal.json.tmp' ||
        base.startsWith('spendx_restore_journal.json.') ||
        base.startsWith('corrupt_journal') ||
        base.startsWith('incomplete_journal_tmp') ||
        base.startsWith('uncommitted_journal_tmp');

    if (!isAuthorizedJournal) {
      throw StateError('Security violation: Unauthorized journal mutation target: $base');
    }
  }
}
