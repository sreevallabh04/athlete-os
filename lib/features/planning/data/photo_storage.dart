import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Stores progress photos in app-private storage
/// (`<app documents>/progress_photos/`). Photos are never uploaded.
class PhotoStorage {
  PhotoStorage(this._baseDir);

  /// Resolves the app documents directory (overridable in tests).
  final Future<Directory> Function() _baseDir;

  Future<Directory> directory() async {
    final dir = Directory(p.join((await _baseDir()).path, 'progress_photos'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Copies [sourcePath] into private storage as `<id>.<ext>`.
  Future<String> import(String sourcePath, String id) async {
    final dir = await directory();
    final ext = p.extension(sourcePath).toLowerCase();
    final target = p.join(dir.path, '$id${ext.isEmpty ? '.jpg' : ext}');
    await File(sourcePath).copy(target);
    return target;
  }

  /// Deletes a stored photo file. Only paths inside the photo directory are
  /// touched.
  Future<void> delete(String path) async {
    final dir = await directory();
    if (!p.isWithin(dir.path, path)) return;
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  /// Deletes every stored progress photo file.
  Future<void> deleteAll() async {
    final dir = await directory();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

final photoStorageProvider = Provider<PhotoStorage>(
  (ref) => PhotoStorage(getApplicationDocumentsDirectory),
);
