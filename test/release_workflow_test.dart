import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('runtime version matches pubspec version', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync());
    final pubspecVersion = (pubspec['version'] as String).split('+').first;
    final appSource = File('lib/foundation/app.dart').readAsStringSync();
    final runtimeVersion = RegExp(
      r'final version = "([^"]+)";',
    ).firstMatch(appSource)!.group(1);

    expect(runtimeVersion, pubspecVersion);
  });

  test('workflow validates versions before every build', () {
    final workflow = loadYaml(
      File('.github/workflows/main.yml').readAsStringSync(),
    );
    final jobs = workflow['jobs'] as YamlMap;
    final validation = jobs['Validate_Version'] as YamlMap;
    final validationStep = (validation['steps'] as YamlList).last as YamlMap;

    expect(validationStep['run'], contains('tool/check_version.py'));
    expect(
      validationStep['env']['RELEASE_TAG'],
      contains('github.event.release.tag_name'),
    );

    for (final jobName in [
      'Build_MacOS',
      'Build_IOS',
      'Build_Android',
      'Build_Windows',
      'Build_Linux',
      'Build_Linux_ARM64',
    ]) {
      expect((jobs[jobName] as YamlMap)['needs'], contains('Validate_Version'));
    }
    expect((jobs['Release'] as YamlMap)['needs'], contains('Validate_Version'));
    expect(
      (jobs['Release'] as YamlMap)['if'],
      contains("needs.Validate_Version.result == 'success'"),
    );
  });

  test('release gathers all build artifacts including AppImages', () {
    final workflow = loadYaml(
      File('.github/workflows/main.yml').readAsStringSync(),
    );
    final steps = workflow['jobs']['Release']['steps'] as YamlList;
    final download = steps.first['with'];
    expect(download['pattern'], '*_build');
    expect(download['merge-multiple'], isTrue);
    expect(steps.last['run'], contains('exit 1'));
    expect(steps.last['if'], contains("needs.*.result"));
  });
}
