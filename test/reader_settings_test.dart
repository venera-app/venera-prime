import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  test('reader settings resolve global, device, and comic priority', () {
    final settings = appdata.settings;
    const comicId = 'settings-test-comic';
    const sourceKey = 'settings-test-source';

    settings['readerBackground'] = 'white';
    settings['deviceId'] = 'settings-test-device';
    settings.resetDeviceReaderSettings();
    settings.resetComicReaderSettings('$comicId@$sourceKey');

    expect(
      settings.getReaderSetting(comicId, sourceKey, 'readerBackground'),
      'white',
    );

    settings.setEnabledDeviceSpecificSettings(true);
    settings.setDeviceReaderSetting('readerBackground', 'gray');
    expect(
      settings.getReaderSetting(comicId, sourceKey, 'readerBackground'),
      'gray',
    );

    settings.setEnabledComicSpecificSettings(comicId, sourceKey, true);
    settings.setReaderSetting(comicId, sourceKey, 'readerBackground', 'black');
    expect(
      settings.getReaderSetting(comicId, sourceKey, 'readerBackground'),
      'black',
    );

    settings.resetComicReaderSettings('$comicId@$sourceKey');
    expect(
      settings.getReaderSetting(comicId, sourceKey, 'readerBackground'),
      'gray',
    );

    settings.resetDeviceReaderSettings();
    settings['deviceId'] = '';
    settings['readerBackground'] = 'theme';
  });
}
