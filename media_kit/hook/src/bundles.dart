import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'process.dart';

String findSevenZip(Map<String, String> environment) {
  String unquote(String value) => value.trim().replaceAll(RegExp(r'^"|"$'), '');
  final explicit = unquote(environment['MEDIA_KIT_7ZIP'] ?? '');
  if (explicit.isNotEmpty && File(explicit).existsSync()) return explicit;

  for (final entry in (environment['PATH'] ?? '').split(';')) {
    final directory = unquote(entry);
    if (directory.isEmpty) continue;
    for (final name in ['7z.exe', '7zz.exe']) {
      final candidate = p.join(directory, name);
      if (File(candidate).existsSync()) return candidate;
    }
  }
  for (final directory in [
    environment['ProgramW6432'],
    environment['ProgramFiles'],
    environment['ProgramFiles(x86)'],
  ]) {
    if (directory == null || directory.trim().isEmpty) continue;
    final candidate = p.join(unquote(directory), '7-Zip', '7z.exe');
    if (File(candidate).existsSync()) return candidate;
  }
  throw StateError(
    'Windows .7z media bundles require 7-Zip. Install 7-Zip and add '
    '7z.exe or 7zz.exe to PATH, or set MEDIA_KIT_7ZIP to its executable path.',
  );
}

final class Bundle {
  Bundle(String target, Map<String, dynamic> json)
    : url = Uri.parse(json['url'] as String),
      checksum = json['sha256'] as String,
      format = json['format'] as String,
      library = json['library'] as String,
      root = json['root'] as String?,
      xcframework = json['xcframework'] == true {
    if (url.scheme != 'https' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum)) {
      throw FormatException('Invalid native bundle: $target');
    }
  }

  final String checksum, format, library;
  final String? root;
  final Uri url;
  final bool xcframework;

  static Future<Map<String, Bundle>> read(File catalog) async {
    final json =
        jsonDecode(await catalog.readAsString()) as Map<String, dynamic>;
    if (json['schema'] != 1) {
      throw FormatException('Unsupported bundle catalog');
    }
    return (json['bundles'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(key, Bundle(key, value as Map<String, dynamic>)),
    );
  }
}

Future<String> _fileDigest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// Publishes verified archives and extractions under an exclusive cache lock.
final class BundleCache {
  BundleCache(this._directory);
  final Directory _directory;

  Future<Directory> prepare(Bundle bundle) async {
    final cache = Directory(p.join(_directory.path, bundle.checksum));
    await cache.create(recursive: true);
    final lock = await File(
      p.join(cache.path, 'lock'),
    ).open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    try {
      final archive = File(p.join(cache.path, 'archive.${bundle.format}'));
      if (!await archive.exists() ||
          await _fileDigest(archive) != bundle.checksum) {
        final partial = File('${archive.path}.partial');
        await _download(bundle.url, partial);
        final actual = await _fileDigest(partial);
        if (actual != bundle.checksum) {
          await partial.delete();
          throw StateError('SHA-256 mismatch for ${bundle.url}: $actual');
        }
        if (await archive.exists()) await archive.delete();
        await partial.rename(archive.path);
      }
      final extracted = Directory(p.join(cache.path, 'files'));
      final stamp = File(p.join(cache.path, 'extracted.json'));
      if (await _validExtraction(extracted, stamp)) return extracted;
      // Both directories are fixed children of this content-addressed cache.
      if (await extracted.exists()) await extracted.delete(recursive: true);
      final temporary = Directory(p.join(cache.path, 'extracting'));
      if (await temporary.exists()) await temporary.delete(recursive: true);
      await temporary.create();
      await extractBundle(archive, bundle.format, temporary);
      final hashes = <String, String>{};
      await for (final entity in temporary.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          hashes[p.relative(entity.path, from: temporary.path)] =
              await _fileDigest(entity);
        }
      }
      if (hashes.isEmpty) {
        throw StateError('Empty native bundle: ${bundle.url}');
      }
      await temporary.rename(extracted.path);
      await stamp.writeAsString(jsonEncode(hashes), flush: true);
      return extracted;
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  Future<bool> _validExtraction(Directory root, File stamp) async {
    if (!await root.exists() || !await stamp.exists()) return false;
    try {
      final hashes =
          jsonDecode(await stamp.readAsString()) as Map<String, dynamic>;
      if (hashes.isEmpty) return false;
      for (final entry in hashes.entries) {
        final file = File(p.join(root.path, entry.key));
        if (!p.isWithin(root.path, file.path) ||
            !await file.exists() ||
            await _fileDigest(file) != entry.value) {
          return false;
        }
      }
      return true;
    } on FormatException {
      return false;
    }
  }
}

Future<void> _download(Uri url, File destination) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  client.findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, 'media-kit-build-hook');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Native bundle download returned ${response.statusCode}',
        uri: url,
      );
    }
    final sink = destination.openWrite();
    try {
      await sink.addStream(response.timeout(const Duration(minutes: 2)));
    } finally {
      await sink.close();
    }
  } finally {
    client.close(force: true);
  }
}

String checkedArchivePath(String name) {
  final normalized = p.posix.normalize(name.replaceAll('\\', '/'));
  if (p.posix.isAbsolute(normalized) ||
      normalized == '..' ||
      normalized.startsWith('../') ||
      normalized.contains(':')) {
    throw FormatException('Unsafe native archive path: $name');
  }
  return normalized;
}

Future<void> extractBundle(
  File archive,
  String format,
  Directory destination,
) async {
  if (format == 'zip') {
    final stream = InputFileStream(archive.path);
    try {
      final decoded = ZipDecoder().decodeStream(stream);
      for (final entry in decoded) {
        final name = checkedArchivePath(entry.name);
        final file = File(p.join(destination.path, name));
        if (entry.isSymbolicLink) {
          checkedArchivePath(
            p.posix.join(p.posix.dirname(name), entry.symbolicLink!),
          );
          continue; // SONAME binaries are regular files; aliases aren't bundled.
        }
        if (!entry.isFile) continue;
        await file.parent.create(recursive: true);
        final output = OutputFileStream(file.path);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
      }
    } finally {
      await stream.close();
    }
    return;
  }
  if (format != '7z' && format != 'tar.gz') {
    throw UnsupportedError('Unsupported native archive format: $format');
  }
  if (Platform.isWindows && format == '7z') {
    final sevenZip = findSevenZip(Platform.environment);
    final listing = await runNativeTool(sevenZip, ['l', '-slt', archive.path]);
    for (final line in const LineSplitter().convert(listing)) {
      if (!line.startsWith('Path = ')) continue;
      final name = line.substring('Path = '.length);
      if (name.isEmpty || p.normalize(name) == p.normalize(archive.path)) {
        continue;
      }
      checkedArchivePath(name);
    }
    await runNativeTool(sevenZip, [
      'x',
      '-y',
      '-o${destination.path}',
      archive.path,
    ]);
    return;
  }
  // Apple/Linux and Windows tar.gz extraction.
  final listing = await runNativeTool('tar', ['-tf', archive.path]);
  for (final name in const LineSplitter().convert(listing)) {
    checkedArchivePath(name);
  }
  await runNativeTool('tar', ['-xf', archive.path, '-C', destination.path]);
}

Future<List<File>> selectLibraries(Directory directory, String library) async {
  final files = <File>[];
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (name.endsWith('.dll') || RegExp(r'\.so(?:\.\d+)*$').hasMatch(name)) {
      files.add(entity);
    }
  }
  if (files.where((file) => p.basename(file.path) == library).length != 1) {
    throw StateError('Expected one $library in ${directory.path}');
  }
  final names = <String>{};
  for (final file in files) {
    if (!names.add(p.basename(file.path))) {
      throw StateError(
        'Duplicate native library name: ${p.basename(file.path)}',
      );
    }
  }
  return files..sort((a, b) => a.path.compareTo(b.path));
}
