import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/local_io.dart';
import 'package:path/path.dart' as p;

const _libraryId = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
const _photoId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _missingId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const _trashedId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
const _outsideId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const _picker = MethodChannel('cool.gravitas.haven/photos_import');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'imports originals and edits with ordered albums, without duplicates',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'haven-photos-test-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final library = Directory(p.join(scratch.path, 'Example.photoslibrary'));
      final database = File(p.join(library.path, 'database', 'Photos.sqlite'));
      await database.parent.create(recursive: true);
      final write = await Process.run('/usr/bin/sqlite3', [
        database.path,
        '''
      CREATE TABLE Z_METADATA(Z_UUID TEXT);
      INSERT INTO Z_METADATA VALUES ('$_libraryId');
      CREATE TABLE ZASSET(
        Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZDIRECTORY TEXT, ZFILENAME TEXT,
        ZKIND INTEGER, ZKINDSUBTYPE INTEGER, ZADJUSTMENTSSTATE INTEGER,
        ZTRASHEDSTATE INTEGER, ZADDITIONALATTRIBUTES INTEGER, ZDATECREATED REAL
      );
      INSERT INTO ZASSET VALUES
        (1, '$_photoId', 'a', '$_photoId.heic', 0, 2, 1, 0, 10, 100),
        (2, '$_missingId', 'b', '$_missingId.jpeg', 0, 0, 1, 0, NULL, NULL),
        (3, '$_trashedId', 'c', '$_trashedId.jpeg', 0, 0, 0, 1, NULL, NULL),
        (4, '$_outsideId', 's', 'outside.jpeg', 0, 0, 0, 0, NULL, NULL);
      CREATE TABLE ZADDITIONALASSETATTRIBUTES(
        Z_PK INTEGER PRIMARY KEY, ZORIGINALFILENAME TEXT, ZTITLE TEXT
      );
      INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (10, 'IMG_001.HEIC', 'Cottage');
      CREATE TABLE ZGENERICALBUM(
        Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZTITLE TEXT, ZKIND INTEGER,
        ZPARENTFOLDER INTEGER
      );
      INSERT INTO ZGENERICALBUM VALUES
        (1, 'folder', 'Trips', 4000, NULL),
        (2, 'album', 'Summer', 2, 1),
        (3, 'empty', 'Empty Album', 2, NULL);
      CREATE TABLE Z_34ASSETS(
        Z_34ALBUMS INTEGER, Z_3ASSETS INTEGER, Z_FOK_3ASSETS INTEGER
      );
      INSERT INTO Z_34ASSETS VALUES (2, 1, 20), (2, 2, 10), (2, 3, 1);
      ''',
      ]);
      expect(write.exitCode, 0, reason: '${write.stderr}');
      final dbBytes = await database.readAsBytes();
      Future<File> media(String relative, String bytes) async {
        final file = await File(
          p.join(library.path, relative),
        ).create(recursive: true);
        return file.writeAsString(bytes);
      }

      final original = await media('originals/a/$_photoId.heic', 'original');
      await media('originals/a/${_photoId}_3.mov', 'motion');
      await media('originals/a/${_photoId}_4.dng', 'raw');
      await media('resources/renders/a/${_photoId}_1_201_a.heic', 'edited');
      await media(
        'resources/renders/a/${_photoId}_2_100_a.mov',
        'edited motion',
      );
      await media('originals/c/$_trashedId.jpeg', 'trash');
      final outside = await File(
        p.join(scratch.path, 'outside.jpeg'),
      ).writeAsString('outside');
      await Directory(p.join(library.path, 'originals', 's')).create();
      await Link(
        p.join(library.path, 'originals', 's', 'outside.jpeg'),
      ).create(outside.path);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_picker, (call) async {
        expect(call.method, 'chooseLibrary');
        return library.path;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_picker, null));
      final root = await Directory(p.join(scratch.path, 'repository')).create();
      final mediaRoot = await Directory(
        p.join(scratch.path, 'nas-media'),
      ).create();
      final repo = DiskRepository()
        ..root = root.path
        ..mediaRoot = mediaRoot.path;

      final first = (await repo.importApplePhotos((_, _) {}))!;
      expect(first.files, 5);
      expect(first.albums, 2);
      expect(first.missingOriginals, 2);
      expect(first.missingEdits, 1);
      expect(first.missingLiveVideos, 0);
      final catalog = File(
        first.entries.singleWhere((e) => e.mime.endsWith('/json')).ref,
      );
      final manifest = jsonDecode(await catalog.readAsString()) as Map;
      final albums = manifest['albums'] as List;
      expect(albums.first['folders'], ['Trips']);
      expect(albums.first['members'], [_missingId, _photoId]);
      expect(albums.last['members'], isEmpty);
      final assets = manifest['assets'] as List;
      expect(assets.map((asset) => asset['id']), [
        _photoId,
        _missingId,
        _outsideId,
      ]);
      expect(assets.first['name'], 'IMG_001.HEIC');
      expect(assets.first['title'], 'Cottage');
      final copied = first.entries.where((e) => e.mime != 'application/json');
      final destination = await mediaRoot.resolveSymbolicLinks();
      expect(copied.every((file) => p.isWithin(destination, file.ref)), isTrue);
      expect(await Future.wait(copied.map((e) => File(e.ref).readAsString())), [
        'original',
        'edited',
        'motion',
        'edited motion',
        'raw',
      ]);
      final second = (await repo.importApplePhotos((_, _) {}))!;
      expect(second.entries.map((e) => e.ref), first.entries.map((e) => e.ref));
      expect(await repo.scanRoot(), hasLength(6));
      expect(await database.readAsBytes(), dbBytes);
      expect(await original.readAsString(), 'original');
    },
    skip: !Platform.isMacOS,
  );
}
