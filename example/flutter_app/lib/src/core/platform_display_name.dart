import 'package:flutter/foundation.dart';

String platformDisplayName(String baseName) {
  return '$baseName - ${platformLabel()}';
}

@visibleForTesting
String platformLabel({TargetPlatform? platform, bool isWeb = kIsWeb}) {
  if (isWeb) {
    return 'web';
  }

  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'Fuchsia',
  };
}
