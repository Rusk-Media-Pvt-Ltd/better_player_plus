import 'dart:async';

import 'package:better_player_plus/src/configuration/better_player_buffering_configuration.dart';
import 'package:better_player_plus/src/video_player/video_player.dart';
import 'package:better_player_plus/src/video_player/video_player_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePlatform extends VideoPlayerPlatform {
  final events = StreamController<VideoEvent>.broadcast();
  int pauseCalls = 0;

  @override
  bool get isMock => true;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create({BetterPlayerBufferingConfiguration? bufferingConfiguration}) async => 1;

  @override
  Stream<VideoEvent> videoEventsFor(int? textureId) => events.stream;

  @override
  Future<void> setDataSource(int? textureId, DataSource dataSource) async {}

  @override
  Future<void> setLooping(int? textureId, bool looping) async {}

  @override
  Future<void> setVolume(int? textureId, double volume) async {}

  @override
  Future<void> play(int? textureId) async {}

  @override
  Future<void> pause(int? textureId) async => pauseCalls++;

  @override
  Future<void> dispose(int? textureId) async {}
}

void main() {
  final platform = _FakePlatform();
  VideoPlayerPlatform.instance = platform;

  // ALRIGHT-APP-3R3
  testWidgets('VideoPlayer with a null controller builds without throwing', (tester) async {
    await tester.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: VideoPlayer(null)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  // ALRIGHT-APP-2CE
  test('a second initialized event neither throws nor skips _applyPlayPause', () async {
    final errors = <Object>[];
    late VideoPlayerController controller;
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));
    await runZonedGuarded(() async {
      controller = VideoPlayerController();
      await settle();
      unawaited(controller.setNetworkDataSource('https://example.com/video.m3u8'));
      await settle();
    }, (e, _) => errors.add(e));

    const initialized = VideoEvent(
      eventType: VideoEventType.initialized,
      key: null,
      duration: Duration(seconds: 10),
      size: Size(1280, 720),
    );
    platform.events.add(initialized);
    await settle();
    final pausesAfterFirst = platform.pauseCalls;

    platform.events.add(initialized);
    await settle();

    expect(errors, isEmpty);
    expect(platform.pauseCalls, pausesAfterFirst + 1);
  }, timeout: const Timeout(Duration(seconds: 20)));
}
