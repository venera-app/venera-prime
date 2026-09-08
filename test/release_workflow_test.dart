import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
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
