@TestOn('vm')
library;

import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import '../../hook/src/apple.dart';
import '../../hook/src/bundles.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('media-kit-bundles-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('every catalog target has a pinned HTTPS archive', () async {
    final catalog = await Bundle.read(File('hook/native_bundles.json'));
    expect(
      catalog.keys,
      containsAll([
        'android_arm64',
        'windows_x64',
        'linux_x64',
        'ios_arm64',
        'macos_arm64',
      ]),
    );
    for (final bundle in catalog.values) {
      expect(bundle.url.scheme, 'https');
      expect(bundle.checksum, matches(r'^[a-f0-9]{64}$'));
    }
  });

  test('rejects traversal, absolute and drive archive paths', () {
    for (final name in ['../x', '/tmp/x', r'C:\x', r'a\..\..\x']) {
      expect(() => checkedArchivePath(name), throwsFormatException);
    }
    expect(checkedArchivePath('lib/./arm64/libmpv.so'), 'lib/arm64/libmpv.so');
  });

  test('7-Zip explicit path takes priority over PATH', () async {
    final explicit = await File(p.join(temp.path, 'explicit.exe')).create();
    await File(p.join(temp.path, '7z.exe')).create();
    expect(findSevenZip({'MEDIA_KIT_7ZIP': explicit.path, 'PATH': temp.path}),
        explicit.path);
  });

  test('7-Zip searches quoted PATH entries before installation locations',
      () async {
    final tool = await File(p.join(temp.path, '7z.exe')).create();
    final installed = await Directory(p.join(temp.path, '7-Zip')).create();
    await File(p.join(installed.path, '7z.exe')).create();
    expect(findSevenZip({'PATH': '"${temp.path}"', 'ProgramFiles': temp.path}),
        tool.path);
  });

  test('7-Zip discovers 7zz.exe and skips missing explicit paths', () async {
    final tool = await File(p.join(temp.path, '7zz.exe')).create();
    expect(findSevenZip({
      'MEDIA_KIT_7ZIP': p.join(temp.path, 'missing.exe'),
      'PATH': temp.path,
    }), tool.path);
  });

  test('7-Zip discovers a common installation outside PATH', () async {
    final installed = await Directory(p.join(temp.path, '7-Zip')).create();
    final tool = await File(p.join(installed.path, '7z.exe')).create();
    expect(findSevenZip({'ProgramFiles': temp.path}), tool.path);
  });

  test('7-Zip missing tool reports installation and configuration guidance', () {
    expect(() => findSevenZip({
      'PATH': temp.path,
      'ProgramFiles': temp.path,
      'ProgramW6432': temp.path,
      'ProgramFiles(x86)': temp.path,
    }), throwsA(isA<StateError>().having(
      (error) => error.message, 'guidance',
      allOf(contains('7-Zip'), contains('PATH'), contains('MEDIA_KIT_7ZIP')),
    )));
  });

  test(
    'cache repairs modified extracted binaries from its verified archive',
    () async {
      final archive = Archive()
        ..addFile(ArchiveFile('lib/arm64/libmpv.so', 3, [1, 2, 3]))
        ..addFile(ArchiveFile('lib/arm64/libhelper.so', 2, [4, 5]))
        ..addFile(ArchiveFile('include/client.h', 1, [6]));
      final bytes = ZipEncoder().encode(archive);
      final checksum = sha256.convert(bytes).toString();
      final bundle = Bundle('android_arm64', {
        'url': 'https://invalid.example/native.zip',
        'sha256': checksum,
        'format': 'zip',
        'root': 'lib/arm64',
        'library': 'libmpv.so',
      });
      final cache = Directory(p.join(temp.path, checksum));
      await cache.create();
      await File(p.join(cache.path, 'archive.zip')).writeAsBytes(bytes);
      final prepared = await BundleCache(temp).prepare(bundle);
      final libraries = await selectLibraries(
        Directory(p.join(prepared.path, bundle.root)),
        bundle.library,
      );
      expect(libraries.map((f) => p.basename(f.path)), [
        'libhelper.so',
        'libmpv.so',
      ]);
      final binary = libraries.last;
      await binary.writeAsBytes([0]);
      await BundleCache(temp).prepare(bundle);
      expect(await binary.readAsBytes(), [1, 2, 3]);
      // A damaged completion marker is also repaired; no network is needed.
      await File(p.join(cache.path, 'extracted.json')).writeAsString('{');
      await BundleCache(temp).prepare(bundle);
      expect(await binary.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'zip traversal does not create a file outside the extraction directory',
    () async {
      final archive = Archive()..addFile(ArchiveFile('../escaped', 1, [1]));
      final file = File(p.join(temp.path, 'bad.zip'));
      await file.writeAsBytes(ZipEncoder().encode(archive));
      final output = await Directory(p.join(temp.path, 'out')).create();
      await expectLater(
        extractBundle(file, 'zip', output),
        throwsFormatException,
      );
      expect(await File(p.join(temp.path, 'escaped')).exists(), isFalse);
    },
  );

  test('selection rejects missing or duplicated player modules', () async {
    await expectLater(selectLibraries(temp, 'libmpv-2.dll'), throwsStateError);
    for (final name in ['a', 'b']) {
      final directory = await Directory(p.join(temp.path, name)).create();
      await File(p.join(directory.path, 'libmpv-2.dll')).writeAsBytes([1]);
    }
    await expectLater(selectLibraries(temp, 'libmpv-2.dll'), throwsStateError);
  });

  test('XCFramework selection separates arm64 devices from simulators', () {
    String slice(String id, String os, List<String> arch, {String? variant}) =>
        '''
      <dict><key>LibraryIdentifier</key><string>$id</string>
      <key>LibraryPath</key><string>Mpv.framework</string>
      <key>SupportedPlatform</key><string>$os</string>
      <key>SupportedArchitectures</key><array>${arch.map((a) => '<string>$a</string>').join()}</array>
      ${variant == null ? '' : '<key>SupportedPlatformVariant</key><string>$variant</string>'}</dict>''';
    final plist =
        '<plist><dict><key>AvailableLibraries</key><array>'
        '${slice('device', 'ios', ['arm64'])}'
        '${slice('simulator', 'ios', ['arm64', 'x86_64'], variant: 'simulator')}'
        '${slice('catalyst', 'ios', ['arm64'], variant: 'maccatalyst')}'
        '${slice('desktop', 'macos', ['arm64', 'x86_64'])}'
        '</array></dict></plist>';
    expect(
      selectAppleSlice(
        plist,
        'ios',
        'arm64',
        simulator: false,
      )['LibraryIdentifier'],
      'device',
    );
    expect(
      selectAppleSlice(
        plist,
        'ios',
        'arm64',
        simulator: true,
      )['LibraryIdentifier'],
      'simulator',
    );
    expect(
      selectAppleSlice(
        plist,
        'macos',
        'x86_64',
        simulator: false,
      )['LibraryIdentifier'],
      'desktop',
    );
    expect(
      () => selectAppleSlice(plist, 'ios', 'x86_64', simulator: false),
      throwsStateError,
    );
  });
}
