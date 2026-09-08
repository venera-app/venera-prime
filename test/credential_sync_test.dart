import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  test(
    'sync restores credentials, respects exclusions and retains its endpoint',
    () {
      final snapshot = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(appdata.toJson())),
      );
      try {
        appdata.settings['webdav'] = [
          'https://local.test',
          'local',
          'local-password',
        ];
        appdata.settings['disableSyncFields'] = 'excludedToken';
        appdata.settings['excludedToken'] = 'local-token';
        appdata.syncData({
          'settings': {
            'token': 'remote-token',
            'account': ['user', 'password'],
            'excludedToken': 'remote-excluded',
            'webdav': ['https://remote.test', 'remote', 'remote-password'],
          },
        }, persist: false);
        expect(appdata.settings['token'], 'remote-token');
        expect(appdata.settings['account'], ['user', 'password']);
        expect(appdata.settings['excludedToken'], 'local-token');
        expect(appdata.settings['webdav'][0], 'https://local.test');
        appdata.syncData(
          {
            'settings': {
              'webdav': ['https://remote.test', 'remote', 'remote-password'],
            },
          },
          persist: false,
          restoreWebdav: true,
        );
        expect(appdata.settings['webdav'][2], 'remote-password');
      } finally {
        appdata.restoreMemorySnapshot(snapshot);
      }
    },
  );
}
