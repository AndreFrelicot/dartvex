import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ConnectivityPlusSignal emits only on the offline->online edge',
      () async {
    final controller = StreamController<List<ConnectivityResult>>();
    final signal = ConnectivityPlusSignal(changes: controller.stream);
    final emissions = <void>[];
    final subscription = signal.onRestored.listen(emissions.add);

    controller.add(<ConnectivityResult>[ConnectivityResult.none]); // offline
    controller.add(<ConnectivityResult>[ConnectivityResult.wifi]); // restored
    controller.add(<ConnectivityResult>[ConnectivityResult.mobile]); // still on
    controller.add(<ConnectivityResult>[ConnectivityResult.none]); // dropped
    controller.add(<ConnectivityResult>[ConnectivityResult.wifi]); // restored
    await Future<void>.delayed(Duration.zero);

    expect(emissions, hasLength(2));

    await subscription.cancel();
    await controller.close();
  });
}
