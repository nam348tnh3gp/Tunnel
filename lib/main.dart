import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'models/tunnel_config.dart';
import 'services/log_buffer.dart';
import 'services/settings_store.dart';
import 'services/tunnel_runner.dart';
import 'ui/tunnel_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'tunnel_channel',
      channelName: 'Tunnel Service',
      channelDescription: 'Keep tunnel running in background',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      iconData: const NotificationIconData(
        resType: ResourceType.mipmap,
        resPrefix: ResourcePrefix.ic,
        name: 'launcher',
      ),
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: const ForegroundTaskOptions(
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );

  final store = await SettingsStore.open();
  final log = LogBuffer();
  final runner = TunnelRunner(store: store, log: log);
  final TunnelConfig config = store.loadConfig();
  final String token = await store.readToken();

  runApp(TunnelApp(
    runner: runner,
    log: log,
    store: store,
    initialConfig: config,
    initialToken: token,
  ));
}

class TunnelApp extends StatelessWidget {
  const TunnelApp({
    super.key,
    required this.runner,
    required this.log,
    required this.store,
    required this.initialConfig,
    required this.initialToken,
  });

  final TunnelRunner runner;
  final LogBuffer log;
  final SettingsStore store;
  final TunnelConfig initialConfig;
  final String initialToken;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tunnel Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.blueGrey,
        scaffoldBackgroundColor: const Color(0xFF1E1E2E),
        cardColor: const Color(0xFF2D2D44),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white70),
          bodySmall: TextStyle(color: Colors.white54),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF3A3A5A),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
      home: TunnelPage(
        runner: runner,
        log: log,
        store: store,
        initialConfig: initialConfig,
        initialToken: initialToken,
      ),
    );
  }
}
