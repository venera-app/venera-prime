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

  test('reader status info visibility follows reader setting priority', () {
    final settings = appdata.settings;
    const comicId = 'status-info-test-comic';
    const sourceKey = 'status-info-test-source';

    settings['deviceId'] = 'status-info-test-device';
    settings['enableClockAndBatteryInfoInReader'] = false;
    settings.resetDeviceReaderSettings();
    settings.resetComicReaderSettings('$comicId@$sourceKey');

    expect(
      settings.getReaderSetting(
        comicId,
        sourceKey,
        'enableClockAndBatteryInfoInReader',
      ),
      isFalse,
    );

    settings.setEnabledDeviceSpecificSettings(true);
    settings.setDeviceReaderSetting('enableClockAndBatteryInfoInReader', true);
    expect(
      settings.getReaderSetting(
        comicId,
        sourceKey,
        'enableClockAndBatteryInfoInReader',
      ),
      isTrue,
    );

    settings.setEnabledComicSpecificSettings(comicId, sourceKey, true);
    settings.setReaderSetting(
      comicId,
      sourceKey,
      'enableClockAndBatteryInfoInReader',
      false,
    );
    expect(
      settings.getReaderSetting(
        comicId,
        sourceKey,
        'enableClockAndBatteryInfoInReader',
      ),
      isFalse,
    );

    settings.resetComicReaderSettings('$comicId@$sourceKey');
    settings.resetDeviceReaderSettings();
    settings['deviceId'] = '';
    settings['enableClockAndBatteryInfoInReader'] = true;
  });
}
