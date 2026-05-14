import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dartvex_flutter_demo/src/core/platform_display_name.dart';

void main() {
  test('platformDisplayName appends detected platform label', () {
    expect(
      platformDisplayName('Anonymous Friend'),
      startsWith('Anonymous Friend - '),
    );
  });

  test('platformLabel maps native Flutter targets', () {
    expect(platformLabel(platform: TargetPlatform.iOS, isWeb: false), 'iOS');
    expect(
      platformLabel(platform: TargetPlatform.android, isWeb: false),
      'Android',
    );
    expect(
      platformLabel(platform: TargetPlatform.macOS, isWeb: false),
      'macOS',
    );
    expect(
      platformLabel(platform: TargetPlatform.windows, isWeb: false),
      'Windows',
    );
    expect(
      platformLabel(platform: TargetPlatform.linux, isWeb: false),
      'Linux',
    );
  });

  test('platformLabel reports web before host platform', () {
    expect(platformLabel(platform: TargetPlatform.macOS, isWeb: true), 'web');
  });
}
