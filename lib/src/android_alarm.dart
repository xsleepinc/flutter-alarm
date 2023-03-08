// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:alarm/service/notification.dart';
import 'package:alarm/service/storage.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

/// For Android support, AndroidAlarmManager is used to set an alarm
/// and trigger a callback when the given time is reached.
class AndroidAlarm {
  static String ringPort = 'alarm-ring';
  static String stopPort = 'alarm-stop';
  static String id2RingPort(int id)=>"$ringPort-$id";

  /// Initializes AndroidAlarmManager dependency
  static Future<void> init() => AndroidAlarmManager.initialize();

  static const platform =
      MethodChannel('com.gdelataillade.alarm/notifOnAppKill');

  /// Create isolate receive port and set alarm at given [dateTime]
  static Future<bool> set(
    int id,
    DateTime dateTime,
    void Function()? onRing,
    String assetAudioPath,
    bool loopAudio,
    double fadeDuration,
    String? notificationTitle,
    String? notificationBody,
    bool enableNotificationOnKill,
  ) async {
    try {
      final ReceivePort port = ReceivePort();
      final success = IsolateNameServer.registerPortWithName(
        port.sendPort,
        id2RingPort(id),
      );

      if (!success) {
        IsolateNameServer.removePortNameMapping(id2RingPort(id));
        IsolateNameServer.registerPortWithName(port.sendPort, id2RingPort(id));
      }
      port.listen((message) {
        print('[Alarm] $message');
        if (message == 'ring') onRing?.call();
      });
    } catch (e) {
      print('[Alarm] ReceivePort error: $e');
      return false;
    }

    // TODO: Check if observer already exists
    if (enableNotificationOnKill) {
      try {
        await platform.invokeMethod(
          'setNotificationOnKillService',
          {
            'title': AlarmStorage.getNotificationOnAppKillTitle(),
            'description': AlarmStorage.getNotificationOnAppKillBody(),
          },
        );
        print('[Alarm] NotificationOnKillService set with success');
      } catch (e) {
        print('[Alarm] NotificationOnKillService error: $e');
      }
    }

    final res = await AndroidAlarmManager.oneShotAt(
      dateTime,
      id,
      AndroidAlarm.playAlarm,
      alarmClock: true,
      allowWhileIdle: true,
      exact: true,
      rescheduleOnReboot: true,
      params: {
        'assetAudioPath': assetAudioPath,
        'loopAudio': loopAudio,
        'fadeDuration': fadeDuration,
        'notificationTitle': notificationTitle,
        'notificationBody': notificationBody,
      },
    );
    return res;
  }

  /// Callback triggered when alarmDateTime is reached.
  /// The message 'ring' is sent to the main thread in order to
  /// tell the device that the alarm is starting to ring.
  /// Alarm is played with AudioPlayer and stopped when the message 'stop'
  /// is received from the main thread.
  @pragma('vm:entry-point')
  static Future<void> playAlarm(int id, Map<String, dynamic> data) async {
    final audioPlayer = AudioPlayer();
    SendPort send = IsolateNameServer.lookupPortByName(id2RingPort(id))!;

    // TODO: Check if observer already exists
    stopNotificationOnKillService();

    send.send('ring');

    try {
      final assetAudioPath = data['assetAudioPath'] as String;

      if (assetAudioPath.startsWith('http')) {
        await audioPlayer.setUrl(assetAudioPath);
      } else {
        await audioPlayer.setAsset(assetAudioPath);
      }

      final loopAudio = data['loopAudio'];
      if (loopAudio) audioPlayer.setLoopMode(LoopMode.all);

      send.send('[Alarm] Alarm fadeDuration: ${data.toString()}');

      final fadeDuration = (data['fadeDuration'] as int).toDouble();

      if (fadeDuration > 0.0) {
        int counter = 0;

        audioPlayer.setVolume(0.1);
        audioPlayer.play();

        send.send('[Alarm] Alarm playing with fadeDuration ${fadeDuration}s');

        Timer.periodic(
          Duration(milliseconds: fadeDuration * 1000 ~/ 10),
          (timer) {
            counter++;
            audioPlayer.setVolume(counter / 10);
            if (counter >= 10) timer.cancel();
          },
        );
      } else {
        audioPlayer.play();
        send.send('[Alarm] Alarm with id $id starts playing.');
      }
    } catch (e) {
      send.send('[Alarm] AudioPlayer with id $id error: ${e.toString()}');
      await AudioPlayer.clearAssetCache();
      send.send('[Alarm] Asset cache reset. Please try again.');
    }

    final notificationTitle = data['notificationTitle'] as String?;
    final notificationBody = data['notificationBody'] as String?;
    if (notificationTitle != null &&
        notificationTitle.isNotEmpty &&
        notificationBody != null &&
        notificationBody.isNotEmpty) {
      await AlarmNotification.instance.androidAlarmNotif(
        id: id,
        title: notificationTitle,
        body: notificationBody,
      );
    }

    try {
      final ReceivePort port = ReceivePort();
      final success =
          IsolateNameServer.registerPortWithName(port.sendPort, stopPort);

      if (!success) {
        IsolateNameServer.removePortNameMapping(stopPort);
        IsolateNameServer.registerPortWithName(port.sendPort, stopPort);
      }

      port.listen(
        (message) async {
          send.send('[Alarm] (isolate) received: $message');
          if (message == 'stop') {
            await audioPlayer.stop();
            await audioPlayer.dispose();
            port.close();
          }
        },
      );
    } catch (e) {
      send.send('[Alarm] (isolate) ReceivePort error: $e');
    }
  }

  /// This function will send the message 'stop' to the isolate so
  /// the audio player can stop playing and dispose.
  static Future<bool> stop(int id) async {
    try {
      final SendPort send = IsolateNameServer.lookupPortByName(stopPort)!;
      send.send('stop');
    } catch (e) {
      print('[Alarm] (main) SendPort error: $e');
    }

    final res = await AndroidAlarmManager.cancel(id);

    return res;
  }

  static Future<void> stopNotificationOnKillService() async {
    try {
      await platform.invokeMethod('stopNotificationOnKillService');
      print('[Alarm] NotificationOnKillService stopped with success');
    } catch (e) {
      print('[Alarm] NotificationOnKillService error: $e');
    }
  }
}
