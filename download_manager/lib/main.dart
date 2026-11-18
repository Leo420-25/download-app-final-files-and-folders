import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:crypto/crypto.dart';

// NEW IMPORTS FOR BACKGROUND & PERMISSIONS
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// --- ARIA2 INTEGRATION ---
import 'aria2_client.dart';

// --- HANDOFF INTEGRATION ---
import 'handoff_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // NEW: Foreground Task & Permission Guards
  await ensureStoragePermissions();
  await checkNotificationPermissions();
  await initForegroundTask();

  await NotificationService.init();
  await downloadManager.init();
  await HandoffController.instance.init();

  runApp(const DownloadManagerApp());
}

// ==========================================
// BACKGROUND & NOTIFICATION GUARDS
// ==========================================

Future<bool> ensureStoragePermissions() async {
  if (!Platform.isAndroid) return true;

  final androidInfo = await DeviceInfoPlugin().androidInfo;

  // API 28 is Android 9 (Pie). Only API <= 28 requires WRITE_EXTERNAL_STORAGE.
  if (androidInfo.version.sdkInt <= 28) {
    final status = await Permission.storage.status;
    if (!status.isGranted) {
      final result = await Permission.storage.request();
      return result.isGranted;
    }
  }

  return true;
}

Future<Directory> getDefaultDownloadDir() async {
  if (Platform.isAndroid) {
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final downloadDir = Directory(p.join(extDir.path, 'Download'));
        if (!downloadDir.existsSync()) {
          downloadDir.createSync(recursive: true);
        }
        return downloadDir;
      }
    } catch (e) {
      debugPrint('getExternalStorageDirectory failed, falling back: $e');
    }
  }
  return (await getDownloadsDirectory()) ?? await getApplicationDocumentsDirectory();
}

Future<void> checkNotificationPermissions() async {
  if (!Platform.isAndroid) return;

  final NotificationPermission notificationPermission =
      await FlutterForegroundTask.checkNotificationPermission();

  if (notificationPermission != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
}

Future<void> initForegroundTask() async {
  if (!Platform.isAndroid) return;

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'download_manager_service',
      channelName: 'Download Manager Service',
      channelDescription: 'Keeps active downloads running in the background',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(1000),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

// ==========================================
// 1. CONSTANTS, MODELS & NOTIFICATIONS
// ==========================================

const String kDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

enum MainTab { downloads, torrents }
enum DownloadStatus { waiting, connecting, downloading, paused, completed, failed, cancelled }
enum DownloadFilter { all, active, queued, paused, completed, failed }
enum FileCategory { all, media, documents, archives, programs, torrents, others }
enum SortBy { manual, dateDesc, dateAsc, nameAsc, nameDesc, sizeDesc, sizeAsc }

extension SortByLabel on SortBy {
  String get label {
    switch (this) {
      case SortBy.manual: return 'Custom (Dragged)';
      case SortBy.dateDesc: return 'Newest First';
      case SortBy.dateAsc: return 'Oldest First';
      case SortBy.nameAsc: return 'Name (A-Z)';
      case SortBy.nameDesc: return 'Name (Z-A)';
      case SortBy.sizeDesc: return 'Largest First';
      case SortBy.sizeAsc: return 'Smallest First';
    }
  }
}

enum QueueSortStrategy { manual, smallestFirst, largestFirst, oldestFirst, newestFirst }

extension QueueSortStrategyLabel on QueueSortStrategy {
  String get label {
    switch (this) {
      case QueueSortStrategy.manual: return 'Manual (drag to reorder)';
      case QueueSortStrategy.smallestFirst: return 'Smallest file first';
      case QueueSortStrategy.largestFirst: return 'Largest file first';
      case QueueSortStrategy.oldestFirst: return 'Oldest first (FIFO)';
      case QueueSortStrategy.newestFirst: return 'Newest first';
    }
  }
}

class SpeedPoint {
  final double downloadSpeed;
  final double uploadSpeed;
  SpeedPoint(this.downloadSpeed, this.uploadSpeed);
}

class SafeDenseContainer extends StatelessWidget {
  final Widget child;
  final double maxScale;

  const SafeDenseContainer({
    super.key,
    required this.child,
    this.maxScale = 1.25,
  });

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final clampedScaler = mediaQuery.textScaler.clamp(
      minScaleFactor: 0.85,
      maxScaleFactor: maxScale,
    );

    return MediaQuery(
      data: mediaQuery.copyWith(textScaler: clampedScaler),
      child: child,
    );
  }
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings();
    const linux = LinuxInitializationSettings(defaultActionName: 'Open Notification');

    const windows = WindowsInitializationSettings(
      appName: 'Download Manager',
      appUserModelId: 'com.example.downloadmanager',
      guid: '6f39d2c1-3f41-4777-a8a5-d5c4149fa81f',
    );

    const initSettings = InitializationSettings(
      android: android,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    await _plugin.initialize(settings: initSettings);
  }

  static Future<void> show(int id, String title, String body, {bool isLowPriority = false}) async {
    final androidDetails = AndroidNotificationDetails(
      'download_channel',
      'Downloads',
      importance: isLowPriority ? Importance.low : Importance.max,
      priority: isLowPriority ? Priority.low : Priority.high,
    );
    final details = NotificationDetails(
      android: androidDetails,
      macOS: const DarwinNotificationDetails(),
      linux: const LinuxNotificationDetails(),
    );

    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }
}

// ==========================================
// 1a. ENGINE CLASSES (ARIA2 + SEGMENTS)
// ==========================================

class TorrentEngine {
  Aria2Daemon? _daemon;
  Aria2RpcClient? _client;
  bool isLoaded = false;

  Aria2RpcClient get client {
    if (_client == null) throw StateError('TorrentEngine not initialized yet.');
    return _client!;
  }

  String _generateSecureSecret() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<void> init(String defaultDownloadDir) async {
    if (isLoaded) return;

    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/F', '/IM', 'aria2c.exe']);
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (_) {}
    }

    final secret = _generateSecureSecret();
    _daemon = Aria2Daemon(rpcSecret: secret, downloadDirFallback: defaultDownloadDir);
    _client = Aria2RpcClient(port: _daemon!.rpcPort, secret: secret);
    try {
      await _daemon!.start();
      isLoaded = true;
    } catch (e) {
      debugPrint('aria2 daemon failed to start: $e');
      isLoaded = false;
    }
  }

  Future<String?> addMagnet(String uriOrPath, String savePath) async {
    if (!isLoaded) return null;
    try {
      if (uriOrPath.endsWith('.torrent') && File(uriOrPath).existsSync()) {
        final bytes = await File(uriOrPath).readAsBytes();
        return await client.addTorrent(bytes, saveDirectory: savePath);
      }
      return await client.addUri(uriOrPath, saveDirectory: savePath);
    } catch (e) {
      debugPrint('addMagnet failed: $e');
      return null;
    }
  }

  Future<void> shutdown() async {
    await _daemon?.stop();
    isLoaded = false;
  }

  void safePause(String gid) {
    try { client.pause(gid).catchError((_) {}); } catch (_) {}
  }

  void safeForceRemove(String gid) {
    try { client.forceRemove(gid).catchError((_) {}); } catch (_) {}
  }

  void safeRemoveDownloadResult(String gid) {
    try { client.removeDownloadResult(gid).catchError((_) {}); } catch (_) {}
  }
}

final torrentEngine = TorrentEngine();

class TorrentFile {
  final String name;
  final int sizeBytes;
  final double progress;
  bool shouldDownload;
  TorrentFile({required this.name, required this.sizeBytes, required this.progress, required this.shouldDownload});
}

class DownloadSegment {
  final int index;
  final int startByte;
  final int endByte;
  int downloadedBytes;
  int retryCount;
  String? lastError;
  double speedBytesPerSecond;

  DownloadSegment({
    required this.index,
    required this.startByte,
    required this.endByte,
    this.downloadedBytes = 0,
    this.retryCount = 0,
    this.lastError,
    this.speedBytesPerSecond = 0,
  });

  int get segmentSize => endByte - startByte + 1;
  bool get isComplete => downloadedBytes >= segmentSize;
  double get progress => segmentSize > 0 ? (downloadedBytes / segmentSize).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => {'i': index, 's': startByte, 'e': endByte, 'd': downloadedBytes};

  static DownloadSegment fromJson(Map<String, dynamic> j) => DownloadSegment(
        index: j['i'] as int,
        startByte: j['s'] as int,
        endByte: j['e'] as int,
        downloadedBytes: j['d'] as int? ?? 0,
      );
}

class DownloadTask extends ChangeNotifier {
  static int _notificationIdCounter = 1000;
  final int notificationId = _notificationIdCounter++;

  final String id;
  String url;
  String fileName;
  String saveDirectory;
  int totalBytes;
  int downloadedBytes;
  double speedBytesPerSecond;
  int etaSeconds;
  DownloadStatus status;
  String errorMessage;
  bool supportsRange;
  CancelToken? cancelToken;
  int createdAtMillis;

  String expectedHash;
  String hashAlgorithm;
  bool? hashVerified;

  int retryCount;

  List<DownloadSegment> segments = [];
  List<CancelToken>? segmentCancelTokens;

  String? aria2Gid;
  List<TorrentFile> torrentFiles = [];
  bool get isTorrent => url.startsWith('magnet:?') || url.endsWith('.torrent') || aria2Gid != null;
  double uploadSpeedBytesPerSecond = 0.0;
  int uploadedBytes = 0;
  int peers = 0;
  int seeds = 0;
  int pieces = 0;

  bool isSchedulerEnabled;
  TimeOfDay? scheduleStartTime;
  TimeOfDay? scheduleStopTime;

  Map<String, String> customHeaders;
  String? referer;

  DownloadTask({
    required this.id,
    required this.url,
    required this.fileName,
    required this.saveDirectory,
    this.totalBytes = 0,
    this.downloadedBytes = 0,
    this.speedBytesPerSecond = 0,
    this.etaSeconds = 0,
    this.status = DownloadStatus.waiting,
    this.errorMessage = '',
    this.supportsRange = false,
    this.expectedHash = '',
    this.hashAlgorithm = 'SHA-256',
    this.hashVerified,
    this.retryCount = 0,
    this.isSchedulerEnabled = false,
    this.scheduleStartTime,
    this.scheduleStopTime,
    this.aria2Gid,
    this.customHeaders = const {},
    this.referer,
    int? createdAtMillis,
  }) : createdAtMillis = createdAtMillis ?? DateTime.now().millisecondsSinceEpoch;

  String get fullPath => '$saveDirectory${Platform.pathSeparator}$fileName';

  String get segmentsJson => segments.isEmpty ? '' : jsonEncode(segments.map((s) => s.toJson()).toList());

  set segmentsJson(String json) {
    if (json.isEmpty) {
      segments = [];
      return;
    }
    try {
      final list = jsonDecode(json) as List;
      segments = list.map((e) => DownloadSegment.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      segments = [];
    }
  }

  String get customHeadersJson => customHeaders.isEmpty ? '' : jsonEncode(customHeaders);

  set customHeadersJson(String json) {
    if (json.isEmpty) {
      customHeaders = {};
      return;
    }
    try {
      final map = jsonDecode(json) as Map;
      customHeaders = map.map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      customHeaders = {};
    }
  }

  void notifyUI() => notifyListeners();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'url': url,
      'fileName': fileName,
      'saveDirectory': saveDirectory,
      'totalBytes': totalBytes,
      'downloadedBytes': downloadedBytes,
      'status': status.name,
      'errorMessage': errorMessage,
      'supportsRange': supportsRange ? 1 : 0,
      'createdAtMillis': createdAtMillis,
      'expectedHash': expectedHash,
      'hashAlgorithm': hashAlgorithm,
      'hashVerified': hashVerified == true ? 1 : (hashVerified == false ? 0 : null),
      'segmentsJson': segmentsJson,
      'taskSchedulerEnabled': isSchedulerEnabled ? 1 : 0,
      'taskStartTime': scheduleStartTime != null ? '${scheduleStartTime!.hour}:${scheduleStartTime!.minute}' : null,
      'taskStopTime': scheduleStopTime != null ? '${scheduleStopTime!.hour}:${scheduleStopTime!.minute}' : null,
      'aria2Gid': aria2Gid,
      'customHeadersJson': customHeadersJson,
      'referer': referer,
    };
  }

  static TimeOfDay? _parseTime(String? timeStr) {
    if (timeStr == null || timeStr.isEmpty) return null;
    final parts = timeStr.split(':');
    if (parts.length != 2) return null;
    return TimeOfDay(hour: int.tryParse(parts[0]) ?? 0, minute: int.tryParse(parts[1]) ?? 0);
  }

  static DownloadTask fromMap(Map<String, dynamic> map) {
    final task = DownloadTask(
      id: map['id'] as String,
      url: map['url'] as String,
      fileName: map['fileName'] as String,
      saveDirectory: map['saveDirectory'] as String,
      totalBytes: map['totalBytes'] as int? ?? 0,
      downloadedBytes: map['downloadedBytes'] as int? ?? 0,
      status: DownloadStatus.values.firstWhere((s) => s.name == map['status'], orElse: () => DownloadStatus.paused),
      errorMessage: map['errorMessage'] as String? ?? '',
      supportsRange: (map['supportsRange'] as int? ?? 0) == 1,
      createdAtMillis: map['createdAtMillis'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      expectedHash: map['expectedHash'] as String? ?? '',
      hashAlgorithm: map['hashAlgorithm'] as String? ?? 'SHA-256',
      hashVerified: map['hashVerified'] == 1 ? true : (map['hashVerified'] == 0 ? false : null),
      isSchedulerEnabled: (map['taskSchedulerEnabled'] as int? ?? 0) == 1,
      scheduleStartTime: _parseTime(map['taskStartTime'] as String?),
      scheduleStopTime: _parseTime(map['taskStopTime'] as String?),
      aria2Gid: map['aria2Gid'] as String?,
      referer: map['referer'] as String?,
    );
    task.segmentsJson = map['segmentsJson'] as String? ?? '';
    task.customHeadersJson = map['customHeadersJson'] as String? ?? '';
    return task;
  }
}

// ==========================================
// 1b. DISK SPACE + DUPLICATE DETECTION
// ==========================================

class DiskSpaceHelper {
  static Future<int?> getFreeBytes(String path) async {
    try {
      if (Platform.isWindows) {
        final root = p.rootPrefix(path);
        final driveLetter = root.replaceAll(r'\', '').replaceAll(':', '');
        if (driveLetter.isEmpty) return null;
        final result = await Process.run('powershell', ['-NoProfile', '-Command', "(Get-PSDrive -Name '$driveLetter').Free"]);
        if (result.exitCode == 0) return int.tryParse((result.stdout as String).trim());
      } else {
        final result = await Process.run('df', ['-Pk', path]);
        if (result.exitCode == 0) {
          final lines = (result.stdout as String).trim().split('\n');
          if (lines.length >= 2) {
            final parts = lines.last.trim().split(RegExp(r'\s+'));
            if (parts.length >= 4) {
              final availableKb = int.tryParse(parts[3]);
              if (availableKb != null) return availableKb * 1024;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }
  static const int safetyBufferBytes = 50 * 1024 * 1024;
}

class DuplicateCheckResult {
  final DownloadTask? activeMatch;
  final DownloadTask? completedMatch;
  const DuplicateCheckResult({this.activeMatch, this.completedMatch});
  bool get hasMatch => activeMatch != null || completedMatch != null;
}

// ==========================================
// 2. DATABASE LAYER
// ==========================================

class DatabaseHelper {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final docsDir = await getApplicationSupportDirectory();
    final dbPath = p.join(docsDir.path, 'smart_download_manager_v2.db');
    return openDatabase(
      dbPath, version: 13,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE downloads (
            id TEXT PRIMARY KEY, url TEXT NOT NULL, fileName TEXT NOT NULL,
            saveDirectory TEXT NOT NULL, totalBytes INTEGER NOT NULL DEFAULT 0,
            downloadedBytes INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL,
            errorMessage TEXT NOT NULL DEFAULT '', supportsRange INTEGER NOT NULL DEFAULT 0,
            createdAtMillis INTEGER NOT NULL, expectedHash TEXT NOT NULL DEFAULT '',
            hashAlgorithm TEXT NOT NULL DEFAULT 'SHA-256', hashVerified INTEGER,
            segmentsJson TEXT NOT NULL DEFAULT '',
            taskSchedulerEnabled INTEGER NOT NULL DEFAULT 0,
            taskStartTime TEXT, taskStopTime TEXT, aria2Gid TEXT,
            customHeadersJson TEXT NOT NULL DEFAULT '', referer TEXT
          )
        ''');
        await db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        for (final stmt in [
          "ALTER TABLE downloads ADD COLUMN expectedHash TEXT NOT NULL DEFAULT ''",
          "ALTER TABLE downloads ADD COLUMN hashAlgorithm TEXT NOT NULL DEFAULT 'SHA-256'",
          "ALTER TABLE downloads ADD COLUMN hashVerified INTEGER",
          "ALTER TABLE downloads ADD COLUMN segmentsJson TEXT NOT NULL DEFAULT ''",
          "ALTER TABLE downloads ADD COLUMN taskSchedulerEnabled INTEGER NOT NULL DEFAULT 0",
          "ALTER TABLE downloads ADD COLUMN taskStartTime TEXT",
          "ALTER TABLE downloads ADD COLUMN taskStopTime TEXT",
          "ALTER TABLE downloads ADD COLUMN aria2Gid TEXT",
          "ALTER TABLE downloads ADD COLUMN customHeadersJson TEXT NOT NULL DEFAULT ''",
          "ALTER TABLE downloads ADD COLUMN referer TEXT",
        ]) {
          try { await db.execute(stmt); } catch (_) {}
        }
        try { await db.execute('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)'); } catch (_) {}
      }
    );
  }

  Future<void> upsertTask(DownloadTask task) async {
    final db = await database;
    await db.insert('downloads', task.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteTask(String id) async {
    final db = await database;
    await db.delete('downloads', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<DownloadTask>> loadAllTasks() async {
    final db = await database;
    final rows = await db.query('downloads', orderBy: 'createdAtMillis DESC');
    return rows.map((row) => DownloadTask.fromMap(row)).toList();
  }

  Future<void> saveSetting(String key, String value) async {
    final db = await database;
    await db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getSetting(String key) async {
    final db = await database;
    final maps = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    if (maps.isNotEmpty) return maps.first['value'] as String?;
    return null;
  }

  /// Alias used by `HandoffPairing` in `handoff_pairing.dart`.
  Future<String?> loadSetting(String key) => getSetting(key);
}

// ==========================================
// 3. ENGINE CORE
// ==========================================

class _AsyncLock {
  Future<void> _chain = Future.value();
  Future<T> synchronized<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _chain;
    _chain = completer.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        completer.complete();
      }
    });
  }
}

class DownloadManager extends ChangeNotifier {
  // 🔥 FIXED: Lowered max connections back to 8 to avoid server disconnects
  final Dio _dio = Dio(BaseOptions(headers: {'User-Agent': kDefaultUserAgent}, followRedirects: true, maxRedirects: 5))
    ..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.maxConnectionsPerHost = 8;
        return client;
      },
    );

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  final List<DownloadTask> activeTasks = [];
  int maxConcurrentDownloads = 2;
  bool isInitialized = false;

  MainTab currentTab = MainTab.downloads;
  String searchQuery = '';
  DownloadFilter currentFilter = DownloadFilter.all;
  FileCategory currentCategory = FileCategory.all;
  SortBy listSortBy = SortBy.dateDesc;
  QueueSortStrategy queueSortStrategy = QueueSortStrategy.manual;

  ThemeMode appThemeMode = ThemeMode.system;
  bool use24HourFormat = false;

  final Set<String> selectedTaskIds = {};

  final Map<String, int> _lastDbWriteMillis = {};
  static const int _dbWriteIntervalMillis = 3000;

  bool isOffline = false;
  StreamSubscription<dynamic>? _connectivitySub;
  final Set<String> _networkPausedTaskIds = {};

  int globalSpeedLimitKbps = 0;
  double _throttleTokens = 0;
  int _lastThrottleUpdate = DateTime.now().millisecondsSinceEpoch;

  final Map<String, int> _activeConnectionsPerHost = {};
  // 🔥 FIXED: Lowered soft limit back to 8
  static const int _maxConnectionsPerHostSoft = 8;

  int segmentsPerDownload = 8;
  static const int _minSegmentSizeBytes = 2 * 1024 * 1024;
  static const int _segmentedMinFileSize = 5 * 1024 * 1024;

  final Map<String, Timer> _progressTimers = {};
  
  final Map<String, RandomAccessFile> _segmentFileHandles = {};
  final Map<String, _AsyncLock> _segmentFileLocks = {};

  bool isSchedulerEnabled = false;
  TimeOfDay? scheduleStartTime;
  TimeOfDay? scheduleStopTime;
  Timer? _schedulerTimer;
  Timer? _uiRefreshTimer;
  Timer? _globalSpeedTimer;

  List<SpeedPoint> speedHistory = [];
  int dailyDownloadedBytes = 0;
  int dailyUploadedBytes = 0;
  double peakSpeedBytesPerSecond = 0.0;
  int activeTaskCount = 0;

  Future<void> init() async {
    if (isInitialized) {
      return;
    }

    final defaultDir = await getDefaultDownloadDir();
    try {
      await torrentEngine.init(defaultDir.path);
    } catch (e) {
      debugPrint("Warning: aria2 engine failed to load - $e");
    }

    final savedTasks = await _dbHelper.loadAllTasks();
    for (final task in savedTasks) {
      if ([DownloadStatus.downloading, DownloadStatus.connecting, DownloadStatus.waiting].contains(task.status)) {
        task.status = DownloadStatus.waiting;
        task.speedBytesPerSecond = 0;
        task.etaSeconds = 0;
        task.retryCount = 0;
      }
      if (task.isTorrent && task.status != DownloadStatus.completed) {
        task.aria2Gid = null;
      }
      activeTasks.add(task);
      await _dbHelper.upsertTask(task);
    }

    final formatStr = await _dbHelper.getSetting('use_24_hour_format');
    use24HourFormat = formatStr == 'true';

    final enabledStr = await _dbHelper.getSetting('scheduler_enabled');
    isSchedulerEnabled = enabledStr == 'true';

    final startStr = await _dbHelper.getSetting('scheduler_start');
    if (startStr != null) {
      final parts = startStr.split(':');
      scheduleStartTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    } else {
      scheduleStartTime = const TimeOfDay(hour: 2, minute: 0);
    }

    final stopStr = await _dbHelper.getSetting('scheduler_stop');
    if (stopStr != null) {
      final parts = stopStr.split(':');
      scheduleStopTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    } else {
      scheduleStopTime = const TimeOfDay(hour: 7, minute: 0);
    }

    _scheduleNextSchedulerCheck();

    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      for (final t in activeTasks) {
        if (t.status == DownloadStatus.waiting && !canTaskRun(t)) {
          t.notifyUI();
        }
      }
      if (isSchedulerEnabled && !isInSchedulerWindow) {
        notifyListeners();
      }
    });

    _globalSpeedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      double currentDl = 0.0;
      double currentUl = 0.0;
      int activeCount = 0;

      for (final t in activeTasks) {
        if ([DownloadStatus.downloading, DownloadStatus.connecting].contains(t.status)) {
          currentDl += t.speedBytesPerSecond;
          currentUl += t.uploadSpeedBytesPerSecond;
          activeCount++;
        }
      }

      dailyDownloadedBytes += currentDl.toInt();
      dailyUploadedBytes += currentUl.toInt();

      final currentTotal = currentDl + currentUl;
      if (currentTotal > peakSpeedBytesPerSecond) {
        peakSpeedBytesPerSecond = currentTotal;
      }

      speedHistory.add(SpeedPoint(currentDl, currentUl));
      if (speedHistory.length > 60) {
        speedHistory.removeAt(0);
      }

      activeTaskCount = activeCount;
      notifyListeners();
    });

    isInitialized = true;
    await _initConnectivityMonitoring();
    notifyListeners();
    _processQueue();
  }

  /// Integration point called by `HandoffController` when a link is sent from a phone.
  Future<void> addDownload(
    String url,
    String fileName, {
    Map<String, String>? headers,
    String? referer,
  }) async {
    final cleanedUrl = cleanUrl(url);
    final meta = await fetchFileMetadata(
      cleanedUrl,
      customHeaders: headers,
      referer: referer,
    );
    final dir = await getDefaultDownloadDir();

    String resolvedName = fileName.trim();
    if (resolvedName.isEmpty ||
        resolvedName == 'download' ||
        resolvedName == 'downloaded_file') {
      if (meta['success'] == true &&
          (meta['fileName'] as String?)?.isNotEmpty == true) {
        resolvedName = meta['fileName'] as String;
      } else if (cleanedUrl.startsWith('magnet:?')) {
        resolvedName = 'Torrent Download (Fetching metadata...)';
      } else {
        resolvedName = 'downloaded_file';
      }
    }

    final totalBytes = meta['success'] == true ? (meta['totalBytes'] as int? ?? 0) : 0;
    final supportsRange = meta['success'] == true ? (meta['supportsRange'] as bool? ?? false) : false;
    final saveDir = meta['success'] == true ? (meta['saveDirectory'] as String? ?? dir.path) : dir.path;

    final task = DownloadTask(
      id: '${DateTime.now().millisecondsSinceEpoch}_${cleanedUrl.hashCode}',
      url: meta['success'] == true ? (meta['cleanUrl'] as String? ?? cleanedUrl) : cleanedUrl,
      fileName: resolvedName,
      saveDirectory: saveDir,
      totalBytes: totalBytes,
      supportsRange: supportsRange,
      customHeaders: headers ?? const {},
      referer: referer,
    );

    enqueueDownload(task);
  }

  bool get isInSchedulerWindow {
    if (scheduleStartTime == null || scheduleStopTime == null) {
      return true;
    }
    final now = TimeOfDay.now();
    double nowMins = now.hour * 60.0 + now.minute;
    double startMins = scheduleStartTime!.hour * 60.0 + scheduleStartTime!.minute;
    double stopMins = scheduleStopTime!.hour * 60.0 + scheduleStopTime!.minute;
    if (startMins < stopMins) {
      return nowMins >= startMins && nowMins < stopMins;
    }
    return nowMins >= startMins || nowMins < stopMins;
  }

  Duration? get timeUntilNextWindowOpen {
    if (!isSchedulerEnabled || scheduleStartTime == null || isInSchedulerWindow) {
      return null;
    }
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, scheduleStartTime!.hour, scheduleStartTime!.minute);
    if (!next.isAfter(now)) {
      next = next.add(const Duration(days: 1));
    }
    return next.difference(now);
  }

  bool canTaskRun(DownloadTask task) {
    bool checkWindow(TimeOfDay? start, TimeOfDay? stop) {
      if (start == null || stop == null) {
        return true;
      }
      final now = TimeOfDay.now();
      double nowMins = now.hour * 60.0 + now.minute;
      double startMins = start.hour * 60.0 + start.minute;
      double stopMins = stop.hour * 60.0 + stop.minute;
      if (startMins < stopMins) {
        return nowMins >= startMins && nowMins < stopMins;
      }
      return nowMins >= startMins || nowMins < stopMins;
    }

    if (task.isSchedulerEnabled) {
      return checkWindow(task.scheduleStartTime, task.scheduleStopTime);
    } else if (isSchedulerEnabled) {
      return checkWindow(scheduleStartTime, scheduleStopTime);
    }
    return true;
  }

  DateTime? _getNextBoundary() {
    final now = DateTime.now();
    final candidates = <DateTime>[];

    void addCandidates(TimeOfDay? start, TimeOfDay? stop) {
      if (start != null && stop != null) {
        var dStart = DateTime(now.year, now.month, now.day, start.hour, start.minute);
        var dStop = DateTime(now.year, now.month, now.day, stop.hour, stop.minute);
        if (!dStart.isAfter(now)) {
          dStart = dStart.add(const Duration(days: 1));
        }
        if (!dStop.isAfter(now)) {
          dStop = dStop.add(const Duration(days: 1));
        }
        candidates.add(dStart);
        candidates.add(dStop);
      }
    }

    if (isSchedulerEnabled) {
      addCandidates(scheduleStartTime, scheduleStopTime);
    }
    for (final t in activeTasks) {
      if (t.isSchedulerEnabled) {
        addCandidates(t.scheduleStartTime, t.scheduleStopTime);
      }
    }

    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort();
    return candidates.first;
  }

  void _scheduleNextSchedulerCheck() {
    _schedulerTimer?.cancel();
    _schedulerTimer = null;
    final next = _getNextBoundary();
    if (next == null) {
      return;
    }

    final wait = next.difference(DateTime.now()) + const Duration(seconds: 1);
    _schedulerTimer = Timer(wait, () {
      _checkScheduler();
      _scheduleNextSchedulerCheck();
    });
  }

  void recheckScheduler() {
    _checkScheduler();
    _scheduleNextSchedulerCheck();
  }

  Duration? timeUntilNextWindowOpenForTask(DownloadTask task) {
    if (canTaskRun(task)) {
      return null;
    }

    TimeOfDay? start;
    if (task.isSchedulerEnabled) {
      start = task.scheduleStartTime;
    } else if (isSchedulerEnabled) {
      start = scheduleStartTime;
    }

    if (start == null) {
      return null;
    }

    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, start.hour, start.minute);
    if (!next.isAfter(now)) {
      next = next.add(const Duration(days: 1));
    }
    return next.difference(now);
  }

  void updateTaskSchedule(DownloadTask task, bool enabled, TimeOfDay? start, TimeOfDay? stop) {
    task.isSchedulerEnabled = enabled;
    task.scheduleStartTime = start;
    task.scheduleStopTime = stop;

    if (enabled && task.status == DownloadStatus.paused) {
      task.status = DownloadStatus.waiting;
      if (queueSortStrategy != QueueSortStrategy.manual) {
        _applyAutoSortToQueueSlots();
      }
    }

    _dbHelper.upsertTask(task);
    task.notifyUI();
    _checkScheduler();
    _scheduleNextSchedulerCheck();
    _processQueue();
  }

  void setSchedulerEnabled(bool enabled) {
    isSchedulerEnabled = enabled;
    _dbHelper.saveSetting('scheduler_enabled', enabled.toString());
    _scheduleNextSchedulerCheck();
    _checkScheduler();
    notifyListeners();
  }

  void setSchedulerTimes({TimeOfDay? start, TimeOfDay? stop}) {
    if (start != null) {
      scheduleStartTime = start;
      _dbHelper.saveSetting('scheduler_start', '${start.hour}:${start.minute}');
    }
    if (stop != null) {
      scheduleStopTime = stop;
      _dbHelper.saveSetting('scheduler_stop', '${stop.hour}:${stop.minute}');
    }
    _scheduleNextSchedulerCheck();
    _checkScheduler();
    notifyListeners();
  }

  void _checkScheduler() {
    bool stateChanged = false;
    for (final t in activeTasks) {
      final allowed = canTaskRun(t);
      final isDownloading = [DownloadStatus.downloading, DownloadStatus.connecting].contains(t.status);

      if (isDownloading && !allowed) {
        t.status = DownloadStatus.waiting;
        t.speedBytesPerSecond = 0;
        t.etaSeconds = 0;
        t.cancelToken?.cancel('Scheduler window closed');
        _cancelSegmentTokens(t, 'Scheduler window closed');

        if (t.isTorrent && t.aria2Gid != null) {
          torrentEngine.safePause(t.aria2Gid!);
        }

        _progressTimers[t.id]?.cancel();
        _progressTimers.remove(t.id);
        if (t.segments.isNotEmpty && !t.isTorrent) {
          t.downloadedBytes = t.segments.fold<int>(0, (s, seg) => s + seg.downloadedBytes);
        }
        t.notifyUI();
        _persistTask(t, force: true);
        stateChanged = true;
      }
    }
    if (stateChanged) {
      notifyListeners();
    }
    _processQueue();
  }

  Future<TimeOfDay?> pickTime(BuildContext context, TimeOfDay initial) {
    return showTimePicker(
      context: context,
      initialTime: initial,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24HourFormat),
        child: child!,
      ),
    );
  }

  void setTimeFormat(bool use24) {
    use24HourFormat = use24;
    _dbHelper.saveSetting('use_24_hour_format', use24.toString());
    notifyListeners();
  }

  void toggleTheme() {
    if (appThemeMode == ThemeMode.system) {
      appThemeMode = ThemeMode.light;
    } else if (appThemeMode == ThemeMode.light) {
      appThemeMode = ThemeMode.dark;
    } else {
      appThemeMode = ThemeMode.system;
    }
    notifyListeners();
  }

  void setGlobalSpeedLimit(int kbps) {
    globalSpeedLimitKbps = kbps;
    _throttleTokens = 0;
    _lastThrottleUpdate = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  void setSegmentsPerDownload(int count) {
    segmentsPerDownload = count.clamp(1, 32);
    notifyListeners();
  }

  Future<void> _throttleBandwidth(int bytes) async {
    if (globalSpeedLimitKbps <= 0) return;
    final limitBps = globalSpeedLimitKbps * 1024;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _lastThrottleUpdate;
    _throttleTokens += (elapsed * limitBps) / 1000.0;
    if (_throttleTokens > limitBps) {
      _throttleTokens = limitBps.toDouble();
    }
    _throttleTokens -= bytes;
    _lastThrottleUpdate = DateTime.now().millisecondsSinceEpoch;
    if (_throttleTokens < 0) {
      final deficit = -_throttleTokens;
      final msToWait = ((deficit / limitBps) * 1000).ceil();
      await Future.delayed(Duration(milliseconds: msToWait));
      _lastThrottleUpdate = DateTime.now().millisecondsSinceEpoch;
    }
  }

  Future<T> _withHostLimit<T>(String url, Future<T> Function() action) async {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return await action();

    while ((_activeConnectionsPerHost[host] ?? 0) >= _maxConnectionsPerHostSoft) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    _activeConnectionsPerHost[host] = (_activeConnectionsPerHost[host] ?? 0) + 1;
    try {
      return await action();
    } finally {
      _activeConnectionsPerHost[host] = (_activeConnectionsPerHost[host] ?? 1) - 1;
    }
  }

  bool get isSelectionMode => selectedTaskIds.isNotEmpty;

  void toggleSelection(String id) {
    if (selectedTaskIds.contains(id)) {
      selectedTaskIds.remove(id);
    } else {
      selectedTaskIds.add(id);
    }
    notifyListeners();
  }

  void selectAll(List<DownloadTask> tasks) {
    selectedTaskIds.addAll(tasks.map((t) => t.id));
    notifyListeners();
  }

  void clearSelection() {
    selectedTaskIds.clear();
    notifyListeners();
  }

  void pauseSelected() {
    for (var id in selectedTaskIds) {
      final t = activeTasks.firstWhere((task) => task.id == id);
      pauseDownload(t);
    }
    clearSelection();
  }

  void resumeSelected() {
    for (var id in selectedTaskIds) {
      final t = activeTasks.firstWhere((task) => task.id == id);
      enqueueDownload(t);
    }
    clearSelection();
  }

  void deleteSelected({required bool deleteFile}) {
    final toDelete = activeTasks.where((t) => selectedTaskIds.contains(t.id)).toList();
    for (var t in toDelete) {
      removeTask(t, deleteFile: deleteFile);
    }
    clearSelection();
  }

  bool _resultIsOffline(dynamic result) {
    if (result is List<ConnectivityResult>) {
      return result.isEmpty || result.every((r) => r == ConnectivityResult.none);
    }
    if (result is ConnectivityResult) {
      return result == ConnectivityResult.none;
    }
    return false;
  }

  Future<void> _initConnectivityMonitoring() async {
    try {
      final connectivity = Connectivity();
      final initial = await connectivity.checkConnectivity();
      isOffline = _resultIsOffline(initial);
      _connectivitySub = connectivity.onConnectivityChanged.listen((result) {
        final offline = _resultIsOffline(result);
        if (offline == isOffline) return;
        isOffline = offline;
        if (isOffline) {
          _pauseAllForNetworkLoss();
        } else {
          _resumeNetworkPausedTasks();
        }
        notifyListeners();
      });
    } catch (_) {}
  }

  void _pauseAllForNetworkLoss() {
    for (final t in activeTasks) {
      if ([DownloadStatus.downloading, DownloadStatus.connecting].contains(t.status)) {
        _networkPausedTaskIds.add(t.id);
        if (t.isTorrent && t.aria2Gid != null) {
          torrentEngine.safePause(t.aria2Gid!);
        } else {
          t.cancelToken?.cancel('Network connection lost');
          _cancelSegmentTokens(t, 'Network connection lost');
        }
        t.status = DownloadStatus.paused;
        t.speedBytesPerSecond = 0;
        t.etaSeconds = 0;
        t.notifyUI();
        _persistTask(t, force: true);
      }
    }
  }

  void _resumeNetworkPausedTasks() {
    if (_networkPausedTaskIds.isEmpty) return;
    final ids = List<String>.from(_networkPausedTaskIds);
    _networkPausedTaskIds.clear();
    for (final id in ids) {
      try {
        final match = activeTasks.firstWhere((t) => t.id == id);
        if (match.status == DownloadStatus.paused) {
          match.status = DownloadStatus.waiting;
          match.notifyUI();
          _persistTask(match, force: true);
        }
      } catch (_) {}
    }
    if (queueSortStrategy != QueueSortStrategy.manual) {
      _applyAutoSortToQueueSlots();
    }
    _processQueue();
  }

  @override
  void dispose() {
    torrentEngine.shutdown();
    _globalSpeedTimer?.cancel();
    _uiRefreshTimer?.cancel();
    _connectivitySub?.cancel();
    for (final timer in _progressTimers.values) {
      timer.cancel();
    }
    _schedulerTimer?.cancel();
    for (final raf in _segmentFileHandles.values) {
      try { raf.close(); } catch (_) {}
    }
    super.dispose();
  }

  List<DownloadTask> get displayedTasks {
    List<DownloadTask> list = List.from(activeTasks);

    if (currentTab == MainTab.downloads) {
      list = list.where((t) => !t.isTorrent).toList();
    } else {
      list = list.where((t) => t.isTorrent).toList();
    }

    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      list = list.where((t) => t.fileName.toLowerCase().contains(q) || t.url.toLowerCase().contains(q)).toList();
    }
    switch (currentFilter) {
      case DownloadFilter.active: list = list.where((t) => [DownloadStatus.downloading, DownloadStatus.connecting].contains(t.status)).toList(); break;
      case DownloadFilter.queued: list = list.where((t) => t.status == DownloadStatus.waiting).toList(); break;
      case DownloadFilter.paused: list = list.where((t) => t.status == DownloadStatus.paused).toList(); break;
      case DownloadFilter.completed: list = list.where((t) => t.status == DownloadStatus.completed).toList(); break;
      case DownloadFilter.failed: list = list.where((t) => t.status == DownloadStatus.failed).toList(); break;
      default: break;
    }
    if (currentCategory != FileCategory.all) {
      if (currentCategory == FileCategory.torrents) {
        list = list.where((t) => t.isTorrent).toList();
      } else {
        list = list.where((t) => FormattingHelper.getCategory(t.fileName, t.isTorrent) == currentCategory).toList();
      }
    }
    if (listSortBy != SortBy.manual) {
      switch (listSortBy) {
        case SortBy.dateDesc: list.sort((a, b) => b.createdAtMillis.compareTo(a.createdAtMillis)); break;
        case SortBy.dateAsc: list.sort((a, b) => a.createdAtMillis.compareTo(b.createdAtMillis)); break;
        case SortBy.nameAsc: list.sort((a, b) => a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase())); break;
        case SortBy.nameDesc: list.sort((a, b) => b.fileName.toLowerCase().compareTo(a.fileName.toLowerCase())); break;
        case SortBy.sizeDesc: list.sort((a, b) => b.totalBytes.compareTo(a.totalBytes)); break;
        case SortBy.sizeAsc: list.sort((a, b) => a.totalBytes.compareTo(b.totalBytes)); break;
        default: break;
      }
    }
    return list;
  }

  void setTab(MainTab tab) { currentTab = tab; clearSelection(); notifyListeners(); }
  void setSearchQuery(String query) { searchQuery = query; notifyListeners(); }
  void setFilter(DownloadFilter filter) { currentFilter = filter; clearSelection(); notifyListeners(); }
  void setCategory(FileCategory category) { currentCategory = category; clearSelection(); notifyListeners(); }
  void setListSort(SortBy sort) { listSortBy = sort; notifyListeners(); }

  void updateMaxConcurrentDownloads(int max) {
    maxConcurrentDownloads = max.clamp(1, 10);
    notifyListeners();
    _processQueue();
  }

  void setQueueSortStrategy(QueueSortStrategy strategy) {
    queueSortStrategy = strategy;
    if (strategy != QueueSortStrategy.manual) {
      _applyAutoSortToQueueSlots();
    }
    notifyListeners();
    _processQueue();
  }

  List<DownloadTask> _sortedWaitingTasks() {
    final waiting = activeTasks.where((t) => t.status == DownloadStatus.waiting).toList();
    switch (queueSortStrategy) {
      case QueueSortStrategy.smallestFirst:
        waiting.sort((a, b) {
          if (a.totalBytes <= 0 && b.totalBytes <= 0) return a.createdAtMillis.compareTo(b.createdAtMillis);
          if (a.totalBytes <= 0) return 1;
          if (b.totalBytes <= 0) return -1;
          return a.totalBytes.compareTo(b.totalBytes);
        });
        break;
      case QueueSortStrategy.largestFirst: waiting.sort((a, b) => b.totalBytes.compareTo(a.totalBytes)); break;
      case QueueSortStrategy.oldestFirst: waiting.sort((a, b) => a.createdAtMillis.compareTo(b.createdAtMillis)); break;
      case QueueSortStrategy.newestFirst: waiting.sort((a, b) => b.createdAtMillis.compareTo(a.createdAtMillis)); break;
      case QueueSortStrategy.manual: break;
    }
    return waiting;
  }

  void _applyAutoSortToQueueSlots() {
    final sorted = _sortedWaitingTasks();
    int i = 0;
    for (int idx = 0; idx < activeTasks.length; idx++) {
      if (activeTasks[idx].status == DownloadStatus.waiting) {
        activeTasks[idx] = sorted[i];
        i++;
      }
    }
  }

  void reorderGlobal(int oldIndex, int newIndex, List<DownloadTask> currentDisplay) {
    final task = currentDisplay.removeAt(oldIndex);
    currentDisplay.insert(newIndex, task);
    activeTasks.remove(task);
    if (newIndex >= currentDisplay.length - 1) {
      activeTasks.add(task);
    } else {
      final referenceTask = currentDisplay[newIndex + 1];
      final insertIndex = activeTasks.indexOf(referenceTask);
      if (insertIndex != -1) {
        activeTasks.insert(insertIndex, task);
      } else {
        activeTasks.add(task);
      }
    }
    queueSortStrategy = QueueSortStrategy.manual;
    listSortBy = SortBy.manual;
    notifyListeners();
    _processQueue();
  }

  String cleanUrl(String raw) {
    var trimmed = raw.trim().replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');
    if (trimmed.startsWith('magnet:?') || (trimmed.toLowerCase().endsWith('.torrent') && File(trimmed).existsSync())) {
      return trimmed;
    }
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    return trimmed;
  }

  Future<Map<String, dynamic>> fetchFileMetadata(
    String rawUrl, {
    Map<String, String>? customHeaders,
    String? referer,
  }) async {
    final url = cleanUrl(rawUrl);

    if (url.toLowerCase().endsWith('.torrent') && File(url).existsSync()) {
      final dir = await getDefaultDownloadDir();
      return {
        'success': true, 'cleanUrl': url, 'fileName': url.split(Platform.pathSeparator).last,
        'totalBytes': 0, 'saveDirectory': dir.path, 'supportsRange': false, 'isTorrent': true
      };
    }

    if (url.startsWith('magnet:?')) {
      final dir = await getDefaultDownloadDir();
      return {
        'success': true, 'cleanUrl': url, 'fileName': 'Torrent Download (Fetching metadata...)',
        'totalBytes': 0, 'saveDirectory': dir.path, 'supportsRange': false, 'isTorrent': true
      };
    }

    try {
      final reqHeaders = <String, dynamic>{
        'User-Agent': kDefaultUserAgent,
        if (customHeaders != null) ...customHeaders,
        if (referer != null && referer.isNotEmpty) 'Referer': referer,
      };
      final options = Options(
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
        headers: reqHeaders,
      );
      Response response;
      try {
        response = await _dio.head(url, options: options);
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 300));
        try {
          response = await _dio.get(url, options: options.copyWith(headers: {...reqHeaders, 'range': 'bytes=0-0'}));
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 300));
          final cancelToken = CancelToken();
          response = await _dio.get(url, options: options.copyWith(responseType: ResponseType.stream), cancelToken: cancelToken);
          cancelToken.cancel();
        }
      }
      final contentLengthStr = response.headers.value(Headers.contentLengthHeader);
      int totalBytes = contentLengthStr != null ? int.tryParse(contentLengthStr) ?? 0 : 0;
      final contentRange = response.headers.value('content-range');
      if (contentRange != null && contentRange.contains('/')) {
        totalBytes = int.tryParse(contentRange.split('/').last) ?? totalBytes;
      }

      String fileName = 'downloaded_file';
      final contentDisposition = response.headers.value('content-disposition');
      if (contentDisposition != null) {
        final starMatch = RegExp(r"filename\*\s*=\s*[^']*''([^;]+)", caseSensitive: false).firstMatch(contentDisposition);
        final plainMatch = RegExp(r'filename\s*=\s*"?([^";]+)"?', caseSensitive: false).firstMatch(contentDisposition);
        if (starMatch != null) {
          fileName = Uri.decodeComponent(starMatch.group(1)!.trim());
        } else if (plainMatch != null) {
          fileName = plainMatch.group(1)!.trim();
        }
      } else {
        final uri = Uri.tryParse(url);
        if (uri != null && uri.pathSegments.isNotEmpty) fileName = uri.pathSegments.last;
      }

      fileName = Uri.decodeComponent(fileName).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      fileName = fileName.replaceAll(RegExp(r'[\s.]+$'), '');

      if (fileName.length > 200) {
        final extIndex = fileName.lastIndexOf('.');
        if (extIndex != -1 && fileName.length - extIndex < 20) {
          fileName = fileName.substring(0, 200 - (fileName.length - extIndex)) + fileName.substring(extIndex);
        } else {
          fileName = fileName.substring(0, 200);
        }
      }

      final baseName = fileName.split('.').first.toUpperCase();
      const reserved = ['CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'];
      if (reserved.contains(baseName)) {
        fileName = 'download_$fileName';
      }
      if (fileName.isEmpty) fileName = 'downloaded_file';

      final acceptRanges = response.headers.value('accept-ranges');
      final supportsRange = (acceptRanges != null && acceptRanges != 'none') || contentRange != null;
      final dir = await getDefaultDownloadDir();

      bool isTorrent = url.endsWith('.torrent');

      return {
        'success': true, 'cleanUrl': url, 'fileName': fileName,
        'totalBytes': totalBytes, 'saveDirectory': dir.path, 'supportsRange': supportsRange,
        'isTorrent': isTorrent
      };
    } on DioException catch (e) {
      return {'success': false, 'error': _mapFriendlyError(e)};
    } catch (e) {
      return {'success': false, 'error': 'Invalid URL or network parsing error.'};
    }
  }

  String _getUniqueFileName(String directory, String originalName) {
    if (originalName.contains('Fetching metadata')) return originalName;

    String name = originalName;
    String extension = '';
    int dotIndex = originalName.lastIndexOf('.');
    if (dotIndex != -1) {
      name = originalName.substring(0, dotIndex);
      extension = originalName.substring(dotIndex);
    }
    String currentName = originalName;
    int counter = 1;
    while (File('$directory${Platform.pathSeparator}$currentName').existsSync()) {
      currentName = '$name ($counter)$extension';
      counter++;
    }
    return currentName;
  }

  Future<DuplicateCheckResult> checkForDuplicate(String url, String directory, String fileName) async {
    final cleanedUrl = cleanUrl(url);
    DownloadTask? activeMatch;
    DownloadTask? completedMatch;

    for (final t in activeTasks) {
      if (t.url == cleanedUrl) {
        if (t.status == DownloadStatus.completed) {
          completedMatch ??= t;
        } else if (t.status != DownloadStatus.cancelled) {
          activeMatch ??= t;
        }
      }
    }
    if (completedMatch == null && !cleanedUrl.startsWith('magnet:?')) {
      for (final t in activeTasks) {
        if (t.status == DownloadStatus.completed && t.fileName == fileName && t.saveDirectory == directory) {
          if (await File(t.fullPath).exists()) {
            completedMatch = t;
            break;
          }
        }
      }
    }
    return DuplicateCheckResult(activeMatch: activeMatch, completedMatch: completedMatch);
  }

  void addAsPaused(DownloadTask task) {
    if (!activeTasks.contains(task)) {
      task.fileName = _getUniqueFileName(task.saveDirectory, task.fileName);
      activeTasks.insert(0, task);
    }
    task.status = DownloadStatus.paused;

    if (task.isTorrent) {
      currentTab = MainTab.torrents;
    } else {
      currentTab = MainTab.downloads;
    }

    _scheduleNextSchedulerCheck();
    notifyListeners();
    _persistTask(task, force: true);
  }

  void enqueueDownload(DownloadTask task) {
    if (!activeTasks.contains(task)) {
      if (task.status == DownloadStatus.waiting) {
        task.fileName = _getUniqueFileName(task.saveDirectory, task.fileName);
      }
      activeTasks.insert(0, task);
    }
    task.status = DownloadStatus.waiting;

    if (task.isTorrent) {
      currentTab = MainTab.torrents;
    } else {
      currentTab = MainTab.downloads;
    }

    if (queueSortStrategy != QueueSortStrategy.manual) {
      _applyAutoSortToQueueSlots();
    }
    _scheduleNextSchedulerCheck();
    notifyListeners();
    _persistTask(task, force: true);
    _processQueue();
  }

  void forceStartDownload(DownloadTask task) {
    if (activeTasks.contains(task)) {
      activeTasks.remove(task);
    } else {
      task.fileName = _getUniqueFileName(task.saveDirectory, task.fileName);
    }
    task.createdAtMillis = DateTime.now().millisecondsSinceEpoch;
    activeTasks.insert(0, task);

    if (task.isTorrent) {
      currentTab = MainTab.torrents;
    } else {
      currentTab = MainTab.downloads;
    }

    final active = activeTasks.where((t) => t.status == DownloadStatus.downloading && t.id != task.id).toList();
    if (active.length >= maxConcurrentDownloads && active.isNotEmpty) {
      final taskToPause = active.last;

      if (taskToPause.isTorrent && taskToPause.aria2Gid != null) {
        torrentEngine.safePause(taskToPause.aria2Gid!);
      } else {
        taskToPause.cancelToken?.cancel('Paused to allow forced download');
        _cancelSegmentTokens(taskToPause, 'Paused to allow forced download');
      }

      taskToPause.status = DownloadStatus.paused;
      taskToPause.speedBytesPerSecond = 0;
      taskToPause.etaSeconds = 0;
      _networkPausedTaskIds.remove(taskToPause.id);
      taskToPause.notifyUI();
      _persistTask(taskToPause, force: true);
    }
    queueSortStrategy = QueueSortStrategy.manual;
    listSortBy = SortBy.manual;
    notifyListeners();
    _startDownloadInternal(task);
  }

  void _processQueue() {
    if (isOffline) return;
    final activeCount = activeTasks.where((t) => [DownloadStatus.downloading, DownloadStatus.connecting].contains(t.status)).length;
    int availableSlots = maxConcurrentDownloads - activeCount;
    if (availableSlots <= 0) return;

    final orderedWaiting = _sortedWaitingTasks();
    for (var task in orderedWaiting) {
      if (availableSlots <= 0) break;
      if (!canTaskRun(task)) continue;
      _startDownloadInternal(task);
      availableSlots--;
    }
  }

  void _persistTask(DownloadTask task, {bool force = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastDbWriteMillis[task.id] ?? 0;
    if (!force && (now - last) < _dbWriteIntervalMillis) return;
    _lastDbWriteMillis[task.id] = now;
    _dbHelper.upsertTask(task);
  }

  void _cancelSegmentTokens(DownloadTask task, String reason) {
    final tokens = task.segmentCancelTokens;
    if (tokens == null) return;
    for (final ct in tokens) {
      if (!ct.isCancelled) {
        ct.cancel(reason);
      }
    }
  }

  String _getSmartRetryMessage(int retryCount) {
    switch (retryCount) {
      case 1: return '🔄 Connection unstable. Reconnecting...';
      case 2: return '🔄 Connection unstable. Resuming from last byte...';
      case 3: return '🔄 Connection unstable. Re-checking server...';
      case 4: return '🔄 Connection unstable. Trying alternate connection strategy...';
      default: return '🔄 Connection unstable. Reducing threads...';
    }
  }

  Duration _getRetryDelay(DioException e, int retryCount) {
    if (e.response?.statusCode == 429) {
      final retryAfter = e.response?.headers.value('retry-after');
      if (retryAfter != null) {
        final seconds = int.tryParse(retryAfter);
        if (seconds != null) return Duration(seconds: seconds);
        try {
          final date = HttpDate.parse(retryAfter);
          final diff = date.difference(DateTime.now());
          if (diff > Duration.zero) return diff;
        } catch (_) {}
      }
      return Duration(seconds: math.pow(2, retryCount + 2).toInt());
    }
    return Duration(seconds: math.pow(2, retryCount).toInt());
  }

  void _pollTorrent(DownloadTask task) {
    _progressTimers[task.id]?.cancel();
    _progressTimers[task.id] = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (task.aria2Gid == null) {
        timer.cancel();
        return;
      }
      try {
        final status = await torrentEngine.client.tellStatus(task.aria2Gid!);

        task.totalBytes = status.totalLength;
        task.downloadedBytes = status.completedLength;
        task.speedBytesPerSecond = status.downloadSpeed.toDouble();

        task.uploadSpeedBytesPerSecond = status.uploadSpeed.toDouble();
        task.peers = status.connections;
        task.seeds = status.numSeeders;

        task.pieces = 0;
        task.uploadedBytes = 0;

        if (status.downloadSpeed > 0 && status.totalLength > 0) {
          task.etaSeconds = ((status.totalLength - status.completedLength) / status.downloadSpeed).round();
        }
        if (status.infoHashName != null && status.infoHashName!.isNotEmpty) {
          task.fileName = status.infoHashName!;
        }

        if (status.files.isNotEmpty) {
          task.torrentFiles = status.files.map((f) => TorrentFile(
            name: f.path.split(Platform.pathSeparator).last,
            sizeBytes: f.length,
            progress: f.progress,
            shouldDownload: f.selected,
          )).toList();
        }

        switch (status.state) {
          case Aria2State.complete:
            timer.cancel();
            _progressTimers.remove(task.id);
            await _finalizeTask(task);
            return;
          case Aria2State.error:
            timer.cancel();
            _progressTimers.remove(task.id);
            task.status = DownloadStatus.failed;
            task.errorMessage = status.errorMessage.isNotEmpty ? status.errorMessage : 'Torrent error.';
            task.speedBytesPerSecond = 0;
            NotificationService.show(task.notificationId, 'Download Failed', '${task.fileName}: ${task.errorMessage}');
            break;
          case Aria2State.paused:
            timer.cancel();
            _progressTimers.remove(task.id);
            task.status = DownloadStatus.paused;
            task.speedBytesPerSecond = 0;
            break;
          default:
            task.status = DownloadStatus.downloading;
        }

        task.notifyUI();
        _persistTask(task);
      } catch (e) {
        debugPrint('poll error for ${task.id}: $e');
      }
    });
  }

  void _startTorrentDownload(DownloadTask task) async {
    if (task.aria2Gid != null) {
      try {
        await torrentEngine.client.unpause(task.aria2Gid!);
        task.status = DownloadStatus.downloading;
        task.notifyUI();
        _persistTask(task, force: true);
        _pollTorrent(task);
        return;
      } catch (e) {
        task.aria2Gid = null;
      }
    }

    task.status = DownloadStatus.connecting;
    task.notifyUI();
    _persistTask(task, force: true);

    final gid = await torrentEngine.addMagnet(task.url, task.saveDirectory);
    if (gid == null) {
      task.status = DownloadStatus.failed;
      task.errorMessage = 'Could not start torrent engine.';
      task.notifyUI();
      _persistTask(task, force: true);
      _processQueue();
      return;
    }
    task.aria2Gid = gid;
    task.status = DownloadStatus.downloading;
    task.notifyUI();
    _persistTask(task, force: true);
    _pollTorrent(task);
  }

  void _startDownloadInternal(DownloadTask task) async {
    if (task.isTorrent) {
      _startTorrentDownload(task);
      return;
    }

    task.status = DownloadStatus.connecting;
    if (!task.errorMessage.startsWith('🔄')) {
      task.errorMessage = '';
    }
    task.notifyUI();
    _persistTask(task, force: true);
    if (task.totalBytes > 0) {
      final remainingNeeded = task.totalBytes - task.downloadedBytes;
      final freeBytes = await DiskSpaceHelper.getFreeBytes(task.saveDirectory);
      if (freeBytes != null && freeBytes < remainingNeeded + DiskSpaceHelper.safetyBufferBytes) {
        task.status = DownloadStatus.failed;
        task.errorMessage = 'Insufficient disk space.';
        task.speedBytesPerSecond = 0;
        NotificationService.show(task.notificationId, 'Download Failed', '${task.fileName} failed: Insufficient space');
        task.notifyUI();
        _persistTask(task, force: true);
        _processQueue();
        return;
      }
    }
    if (_shouldSegment(task)) {
      await _startSegmentedDownload(task);
    } else {
      if (!task.supportsRange && task.downloadedBytes > 0) {
        task.status = DownloadStatus.paused;
        task.errorMessage = 'Server does not support resuming. Link may be expired.';
        task.notifyUI();
        _persistTask(task, force: true);
        _processQueue();
        return;
      }
      await _startSingleStreamDownload(task);
    }
  }

  bool _shouldSegment(DownloadTask task) {
    return task.supportsRange && task.totalBytes >= _segmentedMinFileSize && segmentsPerDownload > 1;
  }

  List<DownloadSegment> _buildSegments(DownloadTask task) {
    int count = segmentsPerDownload.clamp(1, 32);
    while (count > 1 && (task.totalBytes / count) < _minSegmentSizeBytes) {
      count--;
    }
    final segments = <DownloadSegment>[];
    final baseSize = task.totalBytes ~/ count;
    int start = 0;
    for (int i = 0; i < count; i++) {
      final end = (i == count - 1) ? task.totalBytes - 1 : start + baseSize - 1;
      segments.add(DownloadSegment(index: i, startByte: start, endByte: end));
      start = end + 1;
    }
    return segments;
  }

  Future<void> _finalizeTask(DownloadTask task) async {
    task.status = DownloadStatus.completed;
    task.speedBytesPerSecond = 0;
    task.etaSeconds = 0;
    task.errorMessage = '';

    if (task.expectedHash.isNotEmpty && !task.isTorrent) {
      task.notifyUI();
      try {
        final fileStream = File(task.fullPath).openRead();
        Digest digest;
        if (task.hashAlgorithm == 'MD5') {
          digest = await md5.bind(fileStream).first;
        } else if (task.hashAlgorithm == 'SHA-1') {
          digest = await sha1.bind(fileStream).first;
        } else {
          digest = await sha256.bind(fileStream).first;
        }
        task.hashVerified = (digest.toString().toLowerCase() == task.expectedHash.toLowerCase());
      } catch (_) {
        task.hashVerified = false;
      }
    }

    NotificationService.show(task.notificationId, 'Download Complete', task.fileName);
    task.notifyUI();
    notifyListeners();
    _persistTask(task, force: true);
    _processQueue();
  }

  Future<void> _startSegmentedDownload(DownloadTask task) async {
    final currentPlanSize = task.segments.fold<int>(0, (s, seg) => s + seg.segmentSize);
    if (task.segments.isEmpty || currentPlanSize != task.totalBytes) {
      task.segments = _buildSegments(task);
    }
    
    final file = File(task.fullPath);
    final onDiskLengthMatches = file.existsSync() && (await file.length()) == task.totalBytes;
    final needsAlloc = !onDiskLengthMatches;
    
    RandomAccessFile? raf = _segmentFileHandles[task.id];
    bool allocated = raf != null && !needsAlloc;
    Object? allocError;
    
    if (needsAlloc) {
      if (raf != null) {
        try { await raf.close(); } catch (_) {}
        _segmentFileHandles.remove(task.id);
        raf = null;
      }
      for (int attempt = 0; attempt < 3 && !allocated; attempt++) {
        try {
          final newRaf = await file.open(mode: FileMode.write);
          if (task.totalBytes > 0) {
            await newRaf.setPosition(task.totalBytes - 1);
            await newRaf.writeByte(0);
          }
          for (final seg in task.segments) {
            seg.downloadedBytes = 0;
            seg.lastError = null;
          }
          raf = newRaf;
          allocated = true;
        } catch (e, st) {
          allocError = e;
          debugPrint('Segmented alloc attempt ${attempt + 1} failed for ${task.fullPath}: $e\n$st');
          if (attempt < 2) await Future.delayed(Duration(seconds: (attempt + 1) * 2));
        }
      }
    } else if (raf == null) {
      try {
        raf = await file.open(mode: FileMode.append);
        allocated = true;
      } catch (e) {
        allocError = e;
      }
    }
    
    if (!allocated || raf == null) {
      task.status = DownloadStatus.failed;
      task.errorMessage = 'Could not allocate file on disk: $allocError';
      task.speedBytesPerSecond = 0;
      task.notifyUI();
      _persistTask(task, force: true);
      _processQueue();
      return;
    }
    
    _segmentFileHandles[task.id] = raf;
    final lock = _segmentFileLocks.putIfAbsent(task.id, () => _AsyncLock());
    
    task.status = DownloadStatus.downloading;
    task.segmentCancelTokens = [];
    task.notifyUI();
    _persistTask(task, force: true);

    int lastAggregateBytes = task.segments.fold<int>(0, (s, seg) => s + seg.downloadedBytes);
    int lastTickMillis = DateTime.now().millisecondsSinceEpoch;
    final Map<int, int> lastSegmentBytes = {
      for (final seg in task.segments) seg.index: seg.downloadedBytes,
    };

    _progressTimers[task.id]?.cancel();
    _progressTimers[task.id] = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final dt = now - lastTickMillis;

      int total = 0;
      for (final seg in task.segments) {
        total += seg.downloadedBytes;
        if (dt > 0) {
          final lastBytes = lastSegmentBytes[seg.index] ?? seg.downloadedBytes;
          final instSpeed = (seg.downloadedBytes - lastBytes) / (dt / 1000);
          seg.speedBytesPerSecond = instSpeed > 0 ? instSpeed : (seg.isComplete ? 0 : seg.speedBytesPerSecond);
          lastSegmentBytes[seg.index] = seg.downloadedBytes;
        }
      }

      if (dt > 0) {
        final instSpeed = (total - lastAggregateBytes) / (dt / 1000);
        task.speedBytesPerSecond = instSpeed > 0 ? instSpeed : 0;
      }
      task.downloadedBytes = total;
      if (task.speedBytesPerSecond > 0 && task.totalBytes > 0) {
        task.etaSeconds = ((task.totalBytes - total) / task.speedBytesPerSecond).round();
      }
      lastAggregateBytes = total;
      lastTickMillis = now;
      task.notifyUI();
      _persistTask(task);
    });

    final futures = <Future<void>>[];
    for (final segment in task.segments) {
      if (!segment.isComplete) {
        futures.add(_downloadSegment(task, segment, raf, lock));
      }
    }
    
    try {
      await Future.wait(futures);
    } catch (_) {}

    _progressTimers[task.id]?.cancel();
    _progressTimers.remove(task.id);

    if (task.status == DownloadStatus.paused || task.status == DownloadStatus.cancelled) {
      task.downloadedBytes = task.segments.fold<int>(0, (s, seg) => s + seg.downloadedBytes);
      _persistTask(task, force: true);
      return;
    }

    final failedSegment = task.segments.where((s) => !s.isComplete && s.lastError != null).toList();
    if (failedSegment.isNotEmpty) {
      task.status = DownloadStatus.failed;
      task.errorMessage = failedSegment.first.lastError ?? 'One or more segments failed.';
      task.speedBytesPerSecond = 0;
      NotificationService.show(task.notificationId, 'Download Failed', '${task.fileName}: ${task.errorMessage}');
      task.notifyUI();
      _persistTask(task, force: true);
      await _closeSegmentHandle(task.id);
      _processQueue();
      return;
    }

    task.downloadedBytes = task.totalBytes;
    await _closeSegmentHandle(task.id);
    await _finalizeTask(task);
  }

  Future<void> _closeSegmentHandle(String taskId) async {
    final raf = _segmentFileHandles.remove(taskId);
    _segmentFileLocks.remove(taskId);
    if (raf != null) {
      try { await raf.close(); } catch (_) {}
    }
  }

  // 🔥 ULTRA HIGH-SPEED SEGMENT DOWNLOADER WITH 1MB RAM BUFFER & ZERO-CONTENTION LOCKS 🔥
  Future<void> _downloadSegment(DownloadTask task, DownloadSegment segment, RandomAccessFile raf, _AsyncLock lock) async {
    final absoluteStart = segment.startByte + segment.downloadedBytes;
    if (absoluteStart > segment.endByte) return;
    
    final cancelToken = CancelToken();
    task.segmentCancelTokens?.add(cancelToken);
    final targetUrl = task.url;
    
    try {
      final reqHeaders = <String, dynamic>{
        'User-Agent': kDefaultUserAgent,
        ...task.customHeaders,
        if (task.referer != null && task.referer!.isNotEmpty) 'Referer': task.referer,
        'range': 'bytes=$absoluteStart-${segment.endByte}',
      };
      final response = await _withHostLimit(targetUrl, () => _dio.get<ResponseBody>(
        targetUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(seconds: 30),
          headers: reqHeaders,
        ),
      ));

      // Strictly enforce partial response
      if (response.statusCode != 206) {
        throw DioException(
          requestOptions: response.requestOptions,
          type: DioExceptionType.badResponse,
          message: 'Server rejected partial download (Status: ${response.statusCode})',
        );
      }

      if (task.errorMessage.startsWith('🔄')) {
        task.errorMessage = '';
        task.notifyUI();
      }

      int position = absoluteStart;
      int bytesRemaining = (segment.endByte - absoluteStart) + 1;

      // 🔥 FIX 1: copy: true prevents Dart from overwriting the socket buffers in RAM
      final buffer = BytesBuilder(copy: true);
      const int maxBufferSize = 1024 * 1024; // 1 MB chunk buffer

      await for (final chunk in response.data!.stream) {
        if (bytesRemaining <= 0) break;

        List<int> bytesToWrite = chunk;
        if (chunk.length > bytesRemaining) {
          bytesToWrite = chunk.sublist(0, bytesRemaining);
        }

        // Only incur async overhead if throttle limit is actively set
        if (globalSpeedLimitKbps > 0) {
          await _throttleBandwidth(bytesToWrite.length);
        }

        buffer.add(bytesToWrite);
        bytesRemaining -= bytesToWrite.length;

        // Flush directly to disk in fast atomic blocks
        if (buffer.length >= maxBufferSize || bytesRemaining <= 0) {
          final dataToWrite = buffer.takeBytes();
          final writePosition = position; // 🔥 FIX: position already holds the correct start offset

          await lock.synchronized(() async {
            await raf.setPosition(writePosition);
            await raf.writeFrom(dataToWrite); // 🔥 FIX: Async write to prevent UI block
          });

          position += dataToWrite.length;
          segment.downloadedBytes += dataToWrite.length;
        }
      }
      
      // 🔥 FIX 2: Catch silent CDN disconnects and force a retry
      if (bytesRemaining > 0) {
        throw DioException(
          requestOptions: response.requestOptions,
          type: DioExceptionType.connectionError,
          message: 'Stream ended early ($bytesRemaining bytes short)',
        );
      }
      
      segment.lastError = null;
      segment.retryCount = 0;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      if (task.status == DownloadStatus.paused || task.status == DownloadStatus.cancelled) return;
      segment.retryCount++;
      if (segment.retryCount <= 10) {
        task.errorMessage = _getSmartRetryMessage(segment.retryCount);
        task.notifyUI();

        if (segment.retryCount == 1) {
          NotificationService.show(task.notificationId, 'Download Stalled', '${task.fileName} is retrying near the end...', isLowPriority: true);
        }

        final delay = _getRetryDelay(e, segment.retryCount);
        await Future.delayed(delay);

        if (task.status == DownloadStatus.paused || task.status == DownloadStatus.cancelled) return;
        await _downloadSegment(task, segment, raf, lock);
        return;
      }
      segment.lastError = _mapFriendlyError(e);
    } catch (e, st) {
      if (task.status == DownloadStatus.paused || task.status == DownloadStatus.cancelled) return;
      debugPrint('Segment ${segment.index} file system error for ${task.fullPath}: $e\n$st');
      segment.retryCount++;
      if (segment.retryCount <= 10) {
        task.errorMessage = _getSmartRetryMessage(segment.retryCount);
        task.notifyUI();

        if (segment.retryCount == 1) {
          NotificationService.show(task.notificationId, 'Download Stalled', '${task.fileName} is retrying near the end...', isLowPriority: true);
        }

        await Future.delayed(Duration(seconds: math.pow(2, segment.retryCount).toInt()));

        if (task.status == DownloadStatus.paused || task.status == DownloadStatus.cancelled) return;
        await _downloadSegment(task, segment, raf, lock);
        return;
      }
      segment.lastError = 'File system error on part ${segment.index + 1}: $e';
    }
  }

  Future<void> _startSingleStreamDownload(DownloadTask task) async {
    task.status = DownloadStatus.connecting;
    if (!task.errorMessage.startsWith('🔄')) {
      task.errorMessage = '';
    }
    task.cancelToken = CancelToken();
    task.notifyUI();
    _persistTask(task, force: true);

    int lastUpdateTime = DateTime.now().millisecondsSinceEpoch;
    int lastReceivedBytes = task.downloadedBytes;
    final targetUrl = task.url;

    int received = task.downloadedBytes;

    try {
      final headers = <String, dynamic>{
        'User-Agent': kDefaultUserAgent,
        ...task.customHeaders,
        if (task.referer != null && task.referer!.isNotEmpty) 'Referer': task.referer,
      };
      if (task.downloadedBytes > 0 && task.supportsRange) {
        headers['range'] = 'bytes=${task.downloadedBytes}-';
      }
      final response = await _withHostLimit(targetUrl, () => _dio.get<ResponseBody>(
        targetUrl,
        cancelToken: task.cancelToken,
        options: Options(responseType: ResponseType.stream, receiveTimeout: const Duration(seconds: 30), headers: headers),
      ));

      if (task.errorMessage.startsWith('🔄')) {
        task.errorMessage = '';
        task.notifyUI();
      }

      if (task.downloadedBytes > 0 && task.supportsRange && response.statusCode != 206) {
        task.status = DownloadStatus.paused;
        task.errorMessage = 'Link expired or server rejected resume.';
        task.cancelToken?.cancel('Resume rejected');
        task.notifyUI();
        _persistTask(task, force: true);
        _processQueue();
        return;
      }
      final contentLengthStr = response.headers.value(Headers.contentLengthHeader);
      final liveTotalBytes = contentLengthStr != null ? int.tryParse(contentLengthStr) ?? 0 : 0;
      if (task.totalBytes <= 0 && liveTotalBytes > 0) {
        final freeBytes = await DiskSpaceHelper.getFreeBytes(task.saveDirectory);
        if (freeBytes != null && freeBytes < liveTotalBytes + DiskSpaceHelper.safetyBufferBytes) {
          task.status = DownloadStatus.failed;
          task.errorMessage = 'Insufficient disk space.';
          NotificationService.show(task.notificationId, 'Download Failed', '${task.fileName} failed: Insufficient space');
          task.notifyUI();
          _persistTask(task, force: true);
          _processQueue();
          return;
        }
        task.totalBytes = liveTotalBytes;
      }

      final file = File(task.fullPath);
      RandomAccessFile? raf;
      try {
        raf = await file.open(mode: task.downloadedBytes > 0 ? FileMode.append : FileMode.write);
        final stream = response.data!.stream;
        await for (var chunk in stream) {
          if (globalSpeedLimitKbps > 0) {
            await _throttleBandwidth(chunk.length);
          }
          await raf.writeFrom(chunk); // 🔥 FIX: Async write to prevent UI block
          received += chunk.length;
          final now = DateTime.now().millisecondsSinceEpoch;
          final timeDiff = now - lastUpdateTime;
          if (timeDiff > 500 || (task.totalBytes > 0 && received == task.totalBytes)) {
            task.retryCount = 0;
            task.status = DownloadStatus.downloading;
            task.downloadedBytes = received;
            task.speedBytesPerSecond = (received - lastReceivedBytes) / (timeDiff / 1000);
            if (task.speedBytesPerSecond > 0 && task.totalBytes > 0) {
              task.etaSeconds = ((task.totalBytes - received) / task.speedBytesPerSecond).round();
            }
            lastReceivedBytes = received;
            lastUpdateTime = now;
            task.notifyUI();
            _persistTask(task);
          }
        }
        
        // 🔥 FIX 3: Catch silent CDN disconnects on single stream downloads too
        if (task.totalBytes > 0 && received < task.totalBytes) {
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.connectionError,
            message: 'Stream ended early. Expected ${task.totalBytes} but got $received',
          );
        }

      } finally {
        await raf?.close();
      }

      if (![DownloadStatus.paused, DownloadStatus.cancelled].contains(task.status)) {
        await _finalizeTask(task);
      }
    } on DioException catch (e) {
      if (!CancelToken.isCancel(e)) {
        if (task.retryCount < 10) {
          task.retryCount++;
          task.status = DownloadStatus.waiting;
          task.speedBytesPerSecond = 0;
          task.errorMessage = _getSmartRetryMessage(task.retryCount);
          task.notifyUI();
          _persistTask(task, force: true);

          if (task.retryCount == 1) {
            NotificationService.show(task.notificationId, 'Download Stalled', '${task.fileName} is retrying near the end...', isLowPriority: true);
          }

          final delay = _getRetryDelay(e, task.retryCount);
          Future.delayed(delay, () {
            if (task.status == DownloadStatus.waiting && !isOffline) {
              _processQueue();
            }
          });
          return;
        }
        task.status = DownloadStatus.failed;
        task.errorMessage = _mapFriendlyError(e);
        task.speedBytesPerSecond = 0;
        NotificationService.show(task.notificationId, 'Download Failed', '${task.fileName}: ${task.errorMessage}');
        task.notifyUI();
        _persistTask(task, force: true);
        _processQueue();
      }
    } catch (e, st) {
      debugPrint('Single-stream file system error for ${task.fullPath}: $e\n$st');
      if ([DownloadStatus.paused, DownloadStatus.cancelled].contains(task.status)) return;
      if (task.retryCount < 10) {
        task.retryCount++;
        task.status = DownloadStatus.waiting;
        task.speedBytesPerSecond = 0;
        task.errorMessage = _getSmartRetryMessage(task.retryCount);
        task.notifyUI();
        _persistTask(task, force: true);

        if (task.retryCount == 1) {
          NotificationService.show(task.notificationId, 'Download Stalled', '${task.fileName} is retrying near the end...', isLowPriority: true);
        }

        final delaySeconds = math.pow(2, task.retryCount).toInt();
        Future.delayed(Duration(seconds: delaySeconds), () {
          if (task.status == DownloadStatus.waiting && !isOffline) {
            _processQueue();
          }
        });
        return;
      }
      task.status = DownloadStatus.failed;
      task.errorMessage = 'File system error: $e';
      task.speedBytesPerSecond = 0;
      NotificationService.show(task.notificationId, 'Download Failed', '${task.fileName}: File error');
      task.notifyUI();
      _persistTask(task, force: true);
      _processQueue();
    }
  }

  Future<void> pauseDownload(DownloadTask task) async {
    if (task.isTorrent && task.aria2Gid != null) {
      torrentEngine.safePause(task.aria2Gid!);
      _progressTimers[task.id]?.cancel();
      _progressTimers.remove(task.id);
      task.status = DownloadStatus.paused;
      task.speedBytesPerSecond = 0;
      task.uploadSpeedBytesPerSecond = 0;
      task.etaSeconds = 0;
      _networkPausedTaskIds.remove(task.id);
      task.notifyUI();
      _persistTask(task, force: true);
      _processQueue();
      return;
    }

    task.status = DownloadStatus.paused;
    task.speedBytesPerSecond = 0;
    task.etaSeconds = 0;
    task.cancelToken?.cancel('Paused');
    _cancelSegmentTokens(task, 'Paused');
    _progressTimers[task.id]?.cancel();
    _progressTimers.remove(task.id);
    _networkPausedTaskIds.remove(task.id);
    if (task.segments.isNotEmpty && !task.isTorrent) {
      task.downloadedBytes = task.segments.fold<int>(0, (s, seg) => s + seg.downloadedBytes);
    }
    
    await _closeSegmentHandle(task.id);

    task.notifyUI();
    _persistTask(task, force: true);
    _processQueue();
  }

  void cancelDownload(DownloadTask task) {
    if (task.isTorrent && task.aria2Gid != null) {
      torrentEngine.safeForceRemove(task.aria2Gid!);
      torrentEngine.safeRemoveDownloadResult(task.aria2Gid!);
    } else {
      task.cancelToken?.cancel('Cancelled');
      _cancelSegmentTokens(task, 'Cancelled');
    }

    task.status = DownloadStatus.cancelled;
    task.speedBytesPerSecond = 0;
    task.uploadSpeedBytesPerSecond = 0;
    task.etaSeconds = 0;
    _progressTimers[task.id]?.cancel();
    _progressTimers.remove(task.id);
    _networkPausedTaskIds.remove(task.id);
    task.segments = [];
    _closeSegmentHandle(task.id);
    notifyListeners();
    _scheduleNextSchedulerCheck();
    _persistTask(task, force: true);
    Future.delayed(const Duration(milliseconds: 200), () {
      _cleanupPartialFile(task.fullPath);
      _cleanupPartialFile('${task.fullPath}.part');
    });
    _processQueue();
  }

  void retryDownload(DownloadTask task) {
    task.retryCount = 0;
    task.errorMessage = '';
    enqueueDownload(task);
  }

  void renameTask(DownloadTask task, String newName) {
    if ([DownloadStatus.downloading, DownloadStatus.connecting].contains(task.status) || task.isTorrent) {
      return;
    }
    final cleanName = newName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final oldFile = File(task.fullPath);
    task.fileName = cleanName;
    if (oldFile.existsSync()) {
      oldFile.renameSync(task.fullPath);
    }
    _dbHelper.upsertTask(task);
    task.notifyUI();
  }

  void removeTask(DownloadTask task, {bool deleteFile = false}) {
    if (task.isTorrent && task.aria2Gid != null) {
      torrentEngine.safeForceRemove(task.aria2Gid!);
      torrentEngine.safeRemoveDownloadResult(task.aria2Gid!);
    }

    activeTasks.remove(task);
    _lastDbWriteMillis.remove(task.id);
    _networkPausedTaskIds.remove(task.id);
    selectedTaskIds.remove(task.id);
    _progressTimers[task.id]?.cancel();
    _progressTimers.remove(task.id);
    _closeSegmentHandle(task.id);
    _dbHelper.deleteTask(task.id);
    if (task.status != DownloadStatus.completed || deleteFile) {
      _cleanupPartialFile(task.fullPath);
    }
    _cleanupPartialFile('${task.fullPath}.part');
    _scheduleNextSchedulerCheck();
    notifyListeners();
  }

  void clearCompleted() {
    final toRemove = activeTasks.where((t) => t.status == DownloadStatus.completed).toList();
    for (final t in toRemove) {
      removeTask(t, deleteFile: false);
    }
  }

  void _cleanupPartialFile(String path) {
    final file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  String _mapFriendlyError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout: return 'Connection timed out.';
      case DioExceptionType.connectionError: return 'Network disconnected.';
      case DioExceptionType.badResponse:
        if (e.response?.statusCode == 429) return 'Rate-limited by the server (429). Try again shortly.';
        return 'Server rejected request (Error ${e.response?.statusCode}).';
      case DioExceptionType.cancel: return 'Request cancelled.';
      default:
        String msg = e.message ?? 'Unknown error';
        if (msg.length > 50) msg = '${msg.substring(0, 50)}...';
        return msg;
    }
  }

  Future<void> updateTaskUrl(DownloadTask task, String newUrl) async {
    task.status = DownloadStatus.connecting;
    task.errorMessage = 'Refreshing link...';
    task.notifyUI();

    final meta = await fetchFileMetadata(
      newUrl,
      customHeaders: task.customHeaders,
      referer: task.referer,
    );
    if (meta['success'] == true) {
      task.url = meta['cleanUrl'];
      task.supportsRange = meta['supportsRange'];
      task.errorMessage = '';
      task.retryCount = 0;
      _dbHelper.upsertTask(task);
      enqueueDownload(task);
    } else {
      task.status = DownloadStatus.paused;
      task.errorMessage = 'Failed to verify new link: ${meta['error']}';
      task.notifyUI();
    }
  }
}

final downloadManager = DownloadManager();

// ==========================================
// 4. UI HELPERS & COMPONENTS
// ==========================================

class FormattingHelper {
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String formatSpeed(double bps) {
    if (bps <= 0) return '0 B/s';
    if (bps < 1024) return '${bps.toStringAsFixed(0)} B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    if (bps < 1024 * 1024 * 1024) return '${(bps / (1024 * 1024)).toStringAsFixed(2)} MB/s';
    return '${(bps / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB/s';
  }

  static String formatEta(int seconds) {
    if (seconds <= 0) return '--';
    if (seconds < 60) return '${seconds}s';
    final min = seconds ~/ 60;
    if (min < 60) return '${min}m';
    final hr = min ~/ 60;
    final m = min % 60;
    return '${hr}h ${m}m';
  }

  static String formatTime(TimeOfDay time, bool use24Hour) {
    if (use24Hour) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else {
      final int hour = time.hour == 0 ? 12 : (time.hour > 12 ? time.hour - 12 : time.hour);
      final String period = time.hour >= 12 ? 'PM' : 'AM';
      return '$hour:${time.minute.toString().padLeft(2, '0')} $period';
    }
  }

  static FileCategory getCategory(String filename, bool isTorrent) {
    if (isTorrent) return FileCategory.torrents;
    final ext = filename.split('.').last.toLowerCase();
    if (['mp4', 'mkv', 'avi', 'mov', 'mp3', 'wav', 'flac', 'jpg', 'jpeg', 'png', 'webp', 'gif'].contains(ext)) return FileCategory.media;
    if (['pdf', 'doc', 'docx', 'txt', 'xls', 'xlsx', 'csv'].contains(ext)) return FileCategory.documents;
    if (['zip', 'rar', '7z', 'tar', 'gz', 'iso'].contains(ext)) return FileCategory.archives;
    if (['exe', 'msi', 'apk', 'app', 'dmg'].contains(ext)) return FileCategory.programs;
    return FileCategory.others;
  }

  static IconData getFileIcon(String filename, bool isTorrent) {
    if (isTorrent) return Icons.cloud_download;
    final cat = getCategory(filename, false);
    switch (cat) {
      case FileCategory.media: return Icons.perm_media_outlined;
      case FileCategory.documents: return Icons.description_outlined;
      case FileCategory.archives: return Icons.archive_outlined;
      case FileCategory.programs: return Icons.computer_outlined;
      default: return Icons.insert_drive_file_outlined;
    }
  }
}

// ------------------------------------------
// SPEED CENTER GRAPH PAINTER
// ------------------------------------------
class SpeedGraphPainter extends CustomPainter {
  final List<SpeedPoint> history;
  final bool showDownload;
  final bool showUpload;
  final Color downloadColor;
  final Color uploadColor;

  SpeedGraphPainter({
    required this.history,
    required this.showDownload,
    required this.showUpload,
    required this.downloadColor,
    required this.uploadColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;

    double maxSpeed = 1024 * 1024;
    for (var point in history) {
      if (showDownload && point.downloadSpeed > maxSpeed) maxSpeed = point.downloadSpeed;
      if (showUpload && point.uploadSpeed > maxSpeed) maxSpeed = point.uploadSpeed;
    }
    maxSpeed *= 1.2;

    final gridPaint = Paint()
      ..color = Colors.grey.withAlpha(50)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final textStyle = const TextStyle(color: Colors.grey, fontSize: 10);

    for (int i = 0; i <= 4; i++) {
      double y = size.height - (i * size.height / 4);
      double speedVal = (i / 4) * maxSpeed;

      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);

      if (i > 0) {
        final textSpan = TextSpan(text: FormattingHelper.formatSpeed(speedVal), style: textStyle);
        final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
        textPainter.layout();
        textPainter.paint(canvas, Offset(5, y - 15));
      }
    }

    if (history.length < 2) return;

    final dx = size.width / (60 - 1);

    void drawLine(Color color, double Function(SpeedPoint) getValue) {
      final path = Path();
      final fillPath = Path();

      path.moveTo(0, size.height - (getValue(history[0]) / maxSpeed) * size.height);
      fillPath.moveTo(0, size.height);
      fillPath.lineTo(0, size.height - (getValue(history[0]) / maxSpeed) * size.height);

      for (int i = 1; i < history.length; i++) {
        double x = i * dx;
        double y = size.height - (getValue(history[i]) / maxSpeed) * size.height;
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }

      fillPath.lineTo((history.length - 1) * dx, size.height);
      fillPath.close();

      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withAlpha(100), color.withAlpha(0)],
        ).createShader(Rect.fromLTRB(0, 0, size.width, size.height))
        ..style = PaintingStyle.fill;

      canvas.drawPath(fillPath, fillPaint);
      canvas.drawPath(path, paint);
    }

    if (showUpload) drawLine(uploadColor, (p) => p.uploadSpeed);
    if (showDownload) drawLine(downloadColor, (p) => p.downloadSpeed);
  }

  @override
  bool shouldRepaint(covariant SpeedGraphPainter oldDelegate) => true;
}

class SpeedCenterDialog extends StatefulWidget {
  const SpeedCenterDialog({super.key});

  @override
  State<SpeedCenterDialog> createState() => _SpeedCenterDialogState();
}

class _SpeedCenterDialogState extends State<SpeedCenterDialog> {
  bool _showDownload = true;
  bool _showUpload = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.speed, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          const Text('Speed Center'),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: AnimatedBuilder(
          animation: downloadManager,
          builder: (context, _) {
            final activeCount = downloadManager.activeTaskCount;
            final dlBytes = downloadManager.dailyDownloadedBytes;
            final ulBytes = downloadManager.dailyUploadedBytes;
            final peak = downloadManager.peakSpeedBytesPerSecond;

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('TODAY', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2, fontSize: 12)),
                const SizedBox(height: 12),
                SafeDenseContainer(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildStatCol('Downloaded', FormattingHelper.formatBytes(dlBytes), Colors.blue),
                      _buildStatCol('Uploaded', FormattingHelper.formatBytes(ulBytes), Colors.purple),
                      _buildStatCol('Peak Speed', FormattingHelper.formatSpeed(peak), Colors.green),
                      _buildStatCol('Active', activeCount.toString(), theme.colorScheme.onSurface),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('NETWORK ACTIVITY', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2, fontSize: 12)),
                    Row(
                      children: [
                        FilterChip(
                          label: const Text('Download'),
                          selected: _showDownload,
                          selectedColor: Colors.blue.withAlpha(50),
                          checkmarkColor: Colors.blue,
                          labelStyle: TextStyle(color: _showDownload ? Colors.blue : theme.hintColor),
                          onSelected: (val) => setState(() => _showDownload = val),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          label: const Text('Upload'),
                          selected: _showUpload,
                          selectedColor: Colors.purple.withAlpha(50),
                          checkmarkColor: Colors.purple,
                          labelStyle: TextStyle(color: _showUpload ? Colors.purple : theme.hintColor),
                          onSelected: (val) => setState(() => _showUpload = val),
                        ),
                      ],
                    )
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  height: 200,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.black26 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.dividerColor.withAlpha(50)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CustomPaint(
                      painter: SpeedGraphPainter(
                        history: downloadManager.speedHistory,
                        showDownload: _showDownload,
                        showUpload: _showUpload,
                        downloadColor: Colors.blue,
                        uploadColor: Colors.purple,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('60s ago', style: TextStyle(color: theme.hintColor, fontSize: 11)),
                    Text('Now', style: TextStyle(color: theme.hintColor, fontSize: 11)),
                  ],
                )
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))
      ],
    );
  }

  Widget _buildStatCol(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}

// ------------------------------------------
// 4a. TORRENT DETAILS SCREEN
// ------------------------------------------
class TorrentDetailsScreen extends StatelessWidget {
  final DownloadTask task;

  const TorrentDetailsScreen({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
        title: const Text('Torrent Details'),
        elevation: 1,
      ),
      body: AnimatedBuilder(
        animation: task,
        builder: (context, _) {
          double progress = task.totalBytes > 0 ? task.downloadedBytes / task.totalBytes : 0.0;
          progress = progress.clamp(0.0, 1.0);
          final percent = (progress * 100).toStringAsFixed(1);
          final isActive = [DownloadStatus.downloading, DownloadStatus.connecting].contains(task.status);

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.hub, color: Colors.blue, size: 28),
                    const SizedBox(width: 12),
                    Expanded(child: Text(task.fileName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
                  ],
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 16),
                Text('$percent% complete', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: task.totalBytes > 0 ? progress : null,
                    minHeight: 12,
                    backgroundColor: theme.dividerColor.withAlpha(100),
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(FormattingHelper.formatSpeed(task.speedBytesPerSecond), style: TextStyle(fontSize: 16, color: theme.hintColor, fontWeight: FontWeight.bold)),
                    Text(isActive ? 'ETA ${FormattingHelper.formatEta(task.etaSeconds)}' : task.status.name.toUpperCase(), style: TextStyle(fontSize: 16, color: theme.hintColor)),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 16),
                const Text('OVERVIEW', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                const SizedBox(height: 16),
                _buildStatRow('Download', '${FormattingHelper.formatBytes(task.downloadedBytes)} / ${task.totalBytes > 0 ? FormattingHelper.formatBytes(task.totalBytes) : 'Unknown'}'),
                _buildStatRow('Uploaded', FormattingHelper.formatBytes(task.uploadedBytes)),
                _buildStatRow('Peers', task.peers.toString()),
                _buildStatRow('Seeds', task.seeds.toString()),
                _buildStatRow('Connections', task.peers.toString()),
                _buildStatRow('Status', task.status.name.substring(0, 1).toUpperCase() + task.status.name.substring(1)),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 16),
                const Text('FILES', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                const SizedBox(height: 12),
                if (task.torrentFiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text('Fetching metadata...', style: TextStyle(color: theme.hintColor)),
                  )
                else
                  TorrentFileListTable(
                    task: task,
                    scrollable: false,
                    onSelectionChanged: () {},
                  ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 16),
                const Text('NETWORK', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                const SizedBox(height: 16),
                _buildNetworkRow('DHT', 'Connected', true),
                _buildNetworkRow('PEX', 'Enabled', true),
                _buildNetworkRow('Tracker', '${task.peers} peers', true),
                _buildNetworkRow('Port', '6881', true),
                const SizedBox(height: 48),
                Center(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      if (isActive) {
                        downloadManager.pauseDownload(task);
                      } else {
                        downloadManager.enqueueDownload(task);
                      }
                    },
                    icon: Icon(isActive ? Icons.pause : Icons.play_arrow),
                    label: Text(isActive ? 'Pause Torrent' : 'Resume Torrent'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    ),
                  ),
                )
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: SafeDenseContainer(
        child: Row(
          children: [
            SizedBox(width: 120, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.grey))),
            Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.bold))),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkRow(String label, String value, bool isGood) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: SafeDenseContainer(
        child: Row(
          children: [
            SizedBox(width: 120, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.grey))),
            Icon(Icons.circle, size: 10, color: isGood ? Colors.green : Colors.grey),
            const SizedBox(width: 8),
            Expanded(child: Text(value)),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------
// 4b. TORRENT FILE LIST TABLE
// ------------------------------------------
class TorrentFileListTable extends StatelessWidget {
  final DownloadTask task;
  final VoidCallback onSelectionChanged;
  final bool scrollable;

  const TorrentFileListTable({
    super.key,
    required this.task,
    required this.onSelectionChanged,
    this.scrollable = false,
  });

  Future<void> _updateAria2Selection() async {
    if (task.aria2Gid != null) {
      final selected = <int>[];
      for (var j = 0; j < task.torrentFiles.length; j++) {
        if (task.torrentFiles[j].shouldDownload) selected.add(j + 1);
      }
      try {
        await torrentEngine.client.selectFiles(task.aria2Gid!, selected);
      } catch (_) {}
    }
    onSelectionChanged();
    task.notifyUI();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget listWidget = ListView.builder(
      shrinkWrap: !scrollable,
      physics: scrollable ? const AlwaysScrollableScrollPhysics() : const NeverScrollableScrollPhysics(),
      itemCount: task.torrentFiles.length,
      itemBuilder: (context, i) {
        final file = task.torrentFiles[i];
        final isEven = i % 2 == 0;
        return Container(
          color: isEven ? theme.dividerColor.withAlpha(15) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: SafeDenseContainer(
            child: Row(
              children: [
                Checkbox(
                  value: file.shouldDownload,
                  activeColor: Colors.blue,
                  onChanged: (v) {
                    file.shouldDownload = v ?? false;
                    _updateAria2Selection();
                  }
                ),
                Expanded(
                  flex: 5,
                  child: Row(
                    children: [
                      Icon(FormattingHelper.getFileIcon(file.name, false), size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(FormattingHelper.formatBytes(file.sizeBytes), style: TextStyle(fontSize: 13, color: theme.hintColor)),
                ),
                Expanded(
                  flex: 3,
                  child: Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: file.progress,
                            minHeight: 6,
                            backgroundColor: theme.dividerColor.withAlpha(100),
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 45,
                        child: Text('${(file.progress * 100).toStringAsFixed(1)}%', style: const TextStyle(fontSize: 12), textAlign: TextAlign.right),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor.withAlpha(50)),
        borderRadius: BorderRadius.circular(8),
        color: theme.cardColor,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: theme.dividerColor.withAlpha(20),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.surface,
                    foregroundColor: theme.colorScheme.onSurface,
                    elevation: 1,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: Size.zero,
                  ),
                  onPressed: () {
                    for (var f in task.torrentFiles) { f.shouldDownload = true; }
                    _updateAria2Selection();
                  },
                  child: const Text('Select All', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.surface,
                    foregroundColor: theme.colorScheme.onSurface,
                    elevation: 1,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: Size.zero,
                  ),
                  onPressed: () {
                    for (var f in task.torrentFiles) { f.shouldDownload = false; }
                    _updateAria2Selection();
                  },
                  child: const Text('Select None', style: TextStyle(fontSize: 12)),
                ),
                const Spacer(),
                Text('${task.torrentFiles.length} items', style: TextStyle(color: theme.hintColor, fontSize: 12)),
                const SizedBox(width: 8),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor.withAlpha(50))),
            ),
            child: Row(
              children: [
                const SizedBox(width: 48),
                Expanded(flex: 5, child: Text('Name', style: TextStyle(fontWeight: FontWeight.bold, color: theme.hintColor, fontSize: 12))),
                Expanded(flex: 2, child: Text('Total Size', style: TextStyle(fontWeight: FontWeight.bold, color: theme.hintColor, fontSize: 12))),
                Expanded(flex: 3, child: Text('Progress', style: TextStyle(fontWeight: FontWeight.bold, color: theme.hintColor, fontSize: 12))),
              ],
            ),
          ),
          scrollable ? Expanded(child: listWidget) : listWidget,
        ],
      ),
    );
  }
}

// ------------------------------------------
// 4c. TORRENT CARD UI
// ------------------------------------------
class TorrentDownloadCard extends StatelessWidget {
  final DownloadTask task;
  final int? queuePosition;
  final bool showDragHandle;
  final int? listIndex;

  const TorrentDownloadCard({
    super.key,
    required this.task,
    this.queuePosition,
    this.showDragHandle = false,
    this.listIndex,
  });

  void _showContextMenu(BuildContext context, Offset position) {
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final isDownloading = [DownloadStatus.downloading, DownloadStatus.connecting].contains(task.status);
    final isPaused = task.status == DownloadStatus.paused;
    final isQueued = task.status == DownloadStatus.waiting;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(position & const Size(40, 40), Offset.zero & overlay.size),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(child: const ListTile(leading: Icon(Icons.check_box_outlined), title: Text('Select')), onTap: () => downloadManager.toggleSelection(task.id)),
        if (task.url.toLowerCase().startsWith('magnet:?')) ...handoffMenuEntries(),

        if (task.isTorrent && (isDownloading || isPaused || isQueued)) PopupMenuItem<String>(
          child: const ListTile(leading: Icon(Icons.list), title: Text('Select Files')),
          onTap: () async {
            await Future.delayed(Duration.zero);
            if (!context.mounted) return;
            _showTorrentContentDialog(context);
          }
        ),

        if (isPaused) PopupMenuItem<String>(child: const ListTile(leading: Icon(Icons.play_arrow), title: Text('Resume')), onTap: () => downloadManager.enqueueDownload(task)),
        if (isQueued) PopupMenuItem<String>(child: const ListTile(leading: Icon(Icons.flash_on), title: Text('Force Start')), onTap: () => downloadManager.forceStartDownload(task)),
        if (isDownloading) PopupMenuItem<String>(child: const ListTile(leading: Icon(Icons.pause), title: Text('Pause')), onTap: () => downloadManager.pauseDownload(task)),
        PopupMenuItem<String>(
          child: const ListTile(leading: Icon(Icons.delete, color: Colors.red), title: Text('Delete', style: TextStyle(color: Colors.red))),
          onTap: () async {
            await Future.delayed(Duration.zero);
            if (!context.mounted) return;
            _showDeleteDialog(context);
          }
        ),
      ],
    ).then((value) {
      if (value == 'send_to_pc' && context.mounted) {
        handoffSendTask(context, task);
      }
    });
  }

  void _showTorrentContentDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Torrent Files'),
          content: SizedBox(
            width: 700,
            height: 500,
            child: task.torrentFiles.isEmpty
              ? const Center(child: Text('Fetching metadata or no files available yet...'))
              : TorrentFileListTable(
                  task: task,
                  scrollable: true,
                  onSelectionChanged: () => setDialogState((){}),
                ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        )
      )
    );
  }

  void _showDeleteDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Torrent?'),
        content: const Text('This will remove the torrent from the manager.\nDo you also want to delete the downloaded files?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              downloadManager.removeTask(task, deleteFile: false);
              Navigator.pop(ctx);
            },
            child: const Text('Remove from List'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              downloadManager.removeTask(task, deleteFile: true);
              Navigator.pop(ctx);
            },
            child: const Text('Delete Files & List'),
          ),
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: task,
      builder: (context, _) {
        final theme = Theme.of(context);
        final isSelected = downloadManager.selectedTaskIds.contains(task.id);
        final selectionMode = downloadManager.isSelectionMode;

        double progress = task.totalBytes > 0 ? task.downloadedBytes / task.totalBytes : 0.0;
        progress = progress.clamp(0.0, 1.0);
        final percent = (progress * 100).toInt();

        final isActive = [DownloadStatus.downloading, DownloadStatus.connecting].contains(task.status);
        final isQueued = task.status == DownloadStatus.waiting;
        final isFailed = task.status == DownloadStatus.failed;

        return GestureDetector(
          onLongPress: () => downloadManager.toggleSelection(task.id),
          onSecondaryTapDown: (details) => _showContextMenu(context, details.globalPosition),
          onTap: () {
            if (selectionMode) {
              downloadManager.toggleSelection(task.id);
            } else {
              Navigator.push(context, MaterialPageRoute(builder: (_) => TorrentDetailsScreen(task: task)));
            }
          },
          child: Card(
            margin: const EdgeInsets.only(bottom: 12),
            elevation: 1,
            color: isSelected ? Colors.blue.withAlpha(20) : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: isSelected ? const BorderSide(color: Colors.blue, width: 2) : BorderSide(color: theme.dividerColor.withAlpha(50)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (selectionMode) ...[
                        Checkbox(
                          value: isSelected,
                          onChanged: (val) => downloadManager.toggleSelection(task.id),
                          activeColor: Colors.blue,
                        ),
                        const SizedBox(width: 4),
                      ] else if (showDragHandle && listIndex != null) ...[
                        ReorderableDragStartListener(
                          index: listIndex!,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 12.0, top: 2.0, bottom: 8.0),
                              child: Icon(Icons.drag_indicator, color: theme.hintColor.withAlpha(150)),
                            ),
                          ),
                        ),
                      ],
                      if (queuePosition != null && !selectionMode) ...[
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: Colors.blue.withAlpha(30),
                          child: Text('$queuePosition', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blue)),
                        ),
                        const SizedBox(width: 10),
                      ],
                      const Text('🧲', style: TextStyle(fontSize: 18)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          task.fileName,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${FormattingHelper.formatBytes(task.downloadedBytes)} / ${task.totalBytes > 0 ? FormattingHelper.formatBytes(task.totalBytes) : 'Unknown'}', style: const TextStyle(fontSize: 13)),
                      Text(isActive ? FormattingHelper.formatSpeed(task.speedBytesPerSecond) : task.status.name.toUpperCase(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: isActive ? Colors.blue : theme.hintColor)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: task.totalBytes > 0 ? progress : null,
                            minHeight: 10,
                            backgroundColor: theme.dividerColor.withAlpha(100),
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 35,
                        child: Text('$percent%', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold), textAlign: TextAlign.right),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.arrow_downward, size: 12, color: theme.hintColor),
                          const SizedBox(width: 4),
                          Text(FormattingHelper.formatSpeed(task.speedBytesPerSecond), style: TextStyle(fontSize: 12, color: theme.hintColor)),
                          const SizedBox(width: 16),
                          Icon(Icons.arrow_upward, size: 12, color: theme.hintColor),
                          const SizedBox(width: 4),
                          Text(FormattingHelper.formatSpeed(task.uploadSpeedBytesPerSecond), style: TextStyle(fontSize: 12, color: theme.hintColor)),
                        ],
                      ),
                      Row(
                        children: [
                          const Text('👥', style: TextStyle(fontSize: 12)),
                          const SizedBox(width: 4),
                          Text('${task.peers} peers', style: TextStyle(fontSize: 12, color: theme.hintColor)),
                          const SizedBox(width: 16),
                          const Text('⏱', style: TextStyle(fontSize: 12)),
                          const SizedBox(width: 4),
                          Text(FormattingHelper.formatEta(task.etaSeconds), style: TextStyle(fontSize: 12, color: theme.hintColor)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (isFailed && task.errorMessage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Text('⚠ ${task.errorMessage}', style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Seeds  ${task.seeds}    Peers  ${task.peers}', style: TextStyle(fontSize: 12, color: theme.hintColor)),
                      if (!selectionMode) Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isActive || isQueued)
                            IconButton(
                              icon: const Icon(Icons.pause, size: 20),
                              constraints: const BoxConstraints(),
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              onPressed: () => downloadManager.pauseDownload(task),
                            )
                          else
                            IconButton(
                              icon: Icon(isFailed ? Icons.refresh : Icons.play_arrow, size: 20),
                              constraints: const BoxConstraints(),
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              tooltip: isFailed ? 'Retry' : null,
                              onPressed: () => isFailed ? downloadManager.retryDownload(task) : downloadManager.enqueueDownload(task),
                            ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            constraints: const BoxConstraints(),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            onPressed: () => downloadManager.cancelDownload(task),
                          ),
                          IconButton(
                            icon: const Icon(Icons.more_vert, size: 20),
                            constraints: const BoxConstraints(),
                            padding: const EdgeInsets.only(left: 8),
                            onPressed: () {
                              final RenderBox box = context.findRenderObject() as RenderBox;
                              final Offset position = box.localToGlobal(Offset(box.size.width, 0));
                              _showContextMenu(context, position);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      }
    );
  }
}

// ------------------------------------------
// 4d. HTTP DOWNLOAD CARD
// ------------------------------------------
class DetailedDownloadCard extends StatelessWidget {
  final DownloadTask task;
  final int? queuePosition;
  final bool showDragHandle;
  final int? listIndex;

  const DetailedDownloadCard({super.key, required this.task, this.queuePosition, this.showDragHandle = false, this.listIndex});

  void _showContextMenu(BuildContext context, Offset position) {
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final isCompleted = task.status == DownloadStatus.completed;
    final isDownloading = [DownloadStatus.downloading, DownloadStatus.connecting].contains(task.status);
    final isPaused = task.status == DownloadStatus.paused;
    final isQueued = task.status == DownloadStatus.waiting;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(position & const Size(40, 40), Offset.zero & overlay.size),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(child: const ListTile(leading: Icon(Icons.check_box_outlined), title: Text('Select')), onTap: () => downloadManager.toggleSelection(task.id)),
        ...handoffMenuEntries(),

        if (isPaused) PopupMenuItem<String>(child: const ListTile(leading: Icon(Icons.play_arrow), title: Text('Resume')), onTap: () => downloadManager.enqueueDownload(task)),
        if (isQueued) PopupMenuItem<String>(child: const ListTile(leading: Icon(Icons.flash_on), title: Text('Download Now')), onTap: () => downloadManager.forceStartDownload(task)),
        if (isDownloading) PopupMenuItem<String>(child: const ListTile(leading: Icon(Icons.pause), title: Text('Pause')), onTap: () => downloadManager.pauseDownload(task)),
        if (task.status == DownloadStatus.failed || task.status == DownloadStatus.cancelled)
          PopupMenuItem<String>(child: const ListTile(leading: Icon(Icons.refresh), title: Text('Retry')), onTap: () => downloadManager.retryDownload(task)),
        if (isCompleted) PopupMenuItem<String>(child: const ListTile(leading: Icon(Icons.folder_open), title: Text('Open File')), onTap: () => OpenFilex.open(task.fullPath)),
        if (isCompleted) PopupMenuItem<String>(
          child: const ListTile(leading: Icon(Icons.folder), title: Text('Open Folder')),
          onTap: () {
            if (Platform.isWindows) {
              Process.run('explorer.exe', ['/select,', task.fullPath]);
            } else {
              OpenFilex.open(task.saveDirectory);
            }
          }
        ),
        if (!isDownloading) PopupMenuItem<String>(
          child: const ListTile(leading: Icon(Icons.schedule), title: Text('Set Schedule')),
          onTap: () async {
            await Future.delayed(Duration.zero);
            if (!context.mounted) return;
            _showTaskScheduleDialog(context);
          }
        ),
        if (!isDownloading) PopupMenuItem<String>(
          child: const ListTile(leading: Icon(Icons.edit), title: Text('Rename')),
          onTap: () async {
            await Future.delayed(Duration.zero);
            if (!context.mounted) return;
            _showRenameDialog(context);
          }
        ),
        if (!isDownloading && !isCompleted) PopupMenuItem<String>(
          child: const ListTile(leading: Icon(Icons.link), title: Text('Update URL')),
          onTap: () async {
            await Future.delayed(Duration.zero);
            if (!context.mounted) return;
            _showUpdateUrlDialog(context);
          }
        ),
        PopupMenuItem<String>(
          child: const ListTile(leading: Icon(Icons.delete, color: Colors.red), title: Text('Delete', style: TextStyle(color: Colors.red))),
          onTap: () async {
            await Future.delayed(Duration.zero);
            if (!context.mounted) return;
            _showDeleteDialog(context);
          }
        ),
      ],
    ).then((value) {
      if (value == 'send_to_pc' && context.mounted) {
        handoffSendTask(context, task);
      }
    });
  }

  void _showTaskScheduleDialog(BuildContext context) {
    bool localEnabled = task.isSchedulerEnabled;
    TimeOfDay? localStart = task.scheduleStartTime ?? const TimeOfDay(hour: 2, minute: 0);
    TimeOfDay? localStop = task.scheduleStopTime ?? const TimeOfDay(hour: 7, minute: 0);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Task Scheduler'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('Enable Specific Schedule'),
                subtitle: const Text('Overrides the global scheduler for this exact file.'),
                value: localEnabled,
                onChanged: (val) => setDialogState(() => localEnabled = val),
                activeThumbColor: Theme.of(context).colorScheme.primary,
              ),
              if (localEnabled) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        final t = await downloadManager.pickTime(ctx, localStart!);
                        if (t != null) {
                          setDialogState(() => localStart = t);
                        }
                      },
                      child: Text('Start: ${FormattingHelper.formatTime(localStart!, downloadManager.use24HourFormat)}'),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        final t = await downloadManager.pickTime(ctx, localStop!);
                        if (t != null) {
                          setDialogState(() => localStop = t);
                        }
                      },
                      child: Text('Stop: ${FormattingHelper.formatTime(localStop!, downloadManager.use24HourFormat)}'),
                    ),
                  ]
                )
              ]
            ]
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                downloadManager.updateTaskSchedule(task, localEnabled, localStart, localStop);
                Navigator.pop(ctx);
              },
              child: const Text('Save')
            )
          ]
        )
      )
    );
  }

  void _showDeleteDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Download?'),
        content: const Text('This will remove the download from the manager.\nDo you also want to delete the file from your computer?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              downloadManager.removeTask(task, deleteFile: false);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Removed from list.')));
            },
            child: const Text('Remove from List'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              downloadManager.removeTask(task, deleteFile: true);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File deleted.')));
            },
            child: const Text('Delete File & List'),
          ),
        ],
      )
    );
  }

  void _showRenameDialog(BuildContext context) {
    final controller = TextEditingController(text: task.fileName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename File'),
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: 'File Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              downloadManager.renameTask(task, controller.text);
              Navigator.pop(ctx);
            },
            child: const Text('Rename'),
          ),
        ],
      )
    );
  }

  void _showUpdateUrlDialog(BuildContext context) {
    final controller = TextEditingController(text: task.url);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update Download URL'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'New URL',
            hintText: 'Paste fresh link here...'
          ),
          maxLines: 3,
          minLines: 1,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                downloadManager.updateTaskUrl(task, controller.text.trim());
              }
              Navigator.pop(ctx);
            },
            child: const Text('Update & Resume'),
          ),
        ],
      )
    );
  }

  void _showConnectionsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.bolt, color: Theme.of(ctx).colorScheme.primary),
                const SizedBox(width: 8),
                const Text('Active Connections'),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              task.fileName,
              style: TextStyle(fontSize: 13, color: Theme.of(ctx).hintColor, fontWeight: FontWeight.normal),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: AnimatedBuilder(
            animation: task,
            builder: (context, _) {
              if (task.status != DownloadStatus.downloading && task.status != DownloadStatus.connecting) {
                Navigator.of(ctx).pop();
                return const SizedBox.shrink();
              }
              final segments = task.segments;
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final seg in segments) _connectionRow(context, seg),
                    const Divider(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Combined', style: TextStyle(fontWeight: FontWeight.bold)),
                        Text(
                          FormattingHelper.formatSpeed(task.speedBytesPerSecond),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _connectionRow(BuildContext context, DownloadSegment seg) {
    final theme = Theme.of(context);
    final done = seg.isComplete;
    final color = done ? Colors.green : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SafeDenseContainer(
        child: Row(
          children: [
            SizedBox(
              width: 90,
              child: Text('Connection ${seg.index + 1}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            SizedBox(
              width: 80,
              child: Text(
                done ? 'Done' : FormattingHelper.formatSpeed(seg.speedBytesPerSecond),
                style: TextStyle(fontSize: 12, color: done ? Colors.green : theme.hintColor),
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: seg.progress,
                  minHeight: 8,
                  backgroundColor: theme.dividerColor.withAlpha(100),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 36,
              child: Text('${(seg.progress * 100).toInt()}%', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([task, downloadManager]),
      builder: (context, _) {
        final isActive = [DownloadStatus.downloading, DownloadStatus.connecting].contains(task.status);
        final isPaused = task.status == DownloadStatus.paused;
        final isQueued = task.status == DownloadStatus.waiting;
        final isFailed = task.status == DownloadStatus.failed;
        final isCompleted = task.status == DownloadStatus.completed;
        final theme = Theme.of(context);
        final isSelected = downloadManager.selectedTaskIds.contains(task.id);
        final selectionMode = downloadManager.isSelectionMode;
        final isSegmented = task.segments.length > 1;

        double progress = task.totalBytes > 0 ? task.downloadedBytes / task.totalBytes : 0.0;
        progress = progress.clamp(0.0, 1.0);

        Color statusColor = theme.colorScheme.primary;
        if (isCompleted) statusColor = Colors.green;
        if (isFailed) statusColor = Colors.red;
        if (isPaused) statusColor = Colors.orange;

        bool isScheduledWaiting = isQueued && !downloadManager.canTaskRun(task);
        if (isScheduledWaiting) {
          statusColor = Colors.deepPurple;
        } else if (task.errorMessage.startsWith('🔄')) {
          statusColor = Colors.orange;
        }

        return GestureDetector(
          onLongPress: () => downloadManager.toggleSelection(task.id),
          onSecondaryTapDown: (details) => _showContextMenu(context, details.globalPosition),
          onTap: selectionMode ? () => downloadManager.toggleSelection(task.id) : null,
          child: Card(
            margin: const EdgeInsets.only(bottom: 12),
            elevation: 1,
            color: isSelected ? theme.colorScheme.primary.withAlpha(20) : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: isSelected ? BorderSide(color: theme.colorScheme.primary, width: 2) : BorderSide.none,
            ),
            child: LayoutBuilder(
              builder: (context, cardConstraints) {
                final bool compact = cardConstraints.maxWidth < 380;
                final double hPad = compact ? 10.0 : 16.0;
                final double iconBoxPad = compact ? 7.0 : 10.0;
                final double iconSize = compact ? 22.0 : 28.0;
                final double gapAfterIcon = compact ? 10.0 : 16.0;

                return Padding(
                  padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          if (selectionMode) ...[
                            Checkbox(
                              value: isSelected,
                              onChanged: (val) => downloadManager.toggleSelection(task.id),
                              activeColor: theme.colorScheme.primary,
                              visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
                            ),
                            SizedBox(width: compact ? 0 : 4),
                          ] else if (showDragHandle && listIndex != null) ...[
                            ReorderableDragStartListener(
                              index: listIndex!,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: Padding(
                                  padding: EdgeInsets.only(right: compact ? 6.0 : 12.0, top: 8.0, bottom: 8.0),
                                  child: Icon(Icons.drag_indicator, color: theme.hintColor.withAlpha(150), size: compact ? 18 : 24),
                                ),
                              ),
                            ),
                          ],
                          if (queuePosition != null && !selectionMode) ...[
                            CircleAvatar(
                              radius: compact ? 10 : 12,
                              backgroundColor: theme.colorScheme.primary.withAlpha(30),
                              child: Text('$queuePosition', style: TextStyle(fontSize: compact ? 10 : 11, fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                            ),
                            SizedBox(width: compact ? 6 : 10),
                          ],
                          Container(
                            padding: EdgeInsets.all(iconBoxPad),
                            decoration: BoxDecoration(color: statusColor.withAlpha(20), borderRadius: BorderRadius.circular(12)),
                            child: Icon(isCompleted ? Icons.check_circle : (isScheduledWaiting ? Icons.schedule : FormattingHelper.getFileIcon(task.fileName, false)), color: statusColor, size: iconSize),
                          ),
                          SizedBox(width: gapAfterIcon),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(task.fileName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                                    ),
                                    if (isActive && isSegmented) ...[
                                      const SizedBox(width: 6),
                                      InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: () => _showConnectionsDialog(context),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.primary.withAlpha(25),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.bolt, size: 11, color: theme.colorScheme.primary),
                                              const SizedBox(width: 2),
                                              Text('${task.segments.length}×', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Text(
                                      isFailed ? 'ERROR' : (isScheduledWaiting ? 'SCHEDULED' : (task.errorMessage.startsWith('🔄') ? 'RETRYING' : task.status.name.toUpperCase())),
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isScheduledWaiting ? Colors.deepPurple : (task.errorMessage.startsWith('🔄') ? Colors.orange : theme.hintColor))
                                    ),
                                    const SizedBox(width: 8),
                                    if (isScheduledWaiting && downloadManager.timeUntilNextWindowOpenForTask(task) != null)
                                      Text('(in ${FormattingHelper.formatEta(downloadManager.timeUntilNextWindowOpenForTask(task)!.inSeconds)})', style: const TextStyle(fontSize: 12, color: Colors.deepPurple))
                                    else if (!isQueued) ...[
                                      Text('${FormattingHelper.formatBytes(task.downloadedBytes)} / ${task.totalBytes > 0 ? FormattingHelper.formatBytes(task.totalBytes) : 'Unknown'}', style: TextStyle(fontSize: 12, color: theme.hintColor)),
                                      if (task.errorMessage.startsWith('🔄')) ...[
                                        const SizedBox(width: 8),
                                        Flexible(child: Text(task.errorMessage, style: const TextStyle(fontSize: 12, color: Colors.orange), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                      ]
                                    ] else ...[
                                      Text(task.totalBytes > 0 ? FormattingHelper.formatBytes(task.totalBytes) : 'Size unknown', style: TextStyle(fontSize: 12, color: theme.hintColor)),
                                      if (task.errorMessage.startsWith('🔄')) ...[
                                        const SizedBox(width: 8),
                                        Flexible(child: Text(task.errorMessage, style: const TextStyle(fontSize: 12, color: Colors.orange), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                      ]
                                    ]
                                  ],
                                ),
                                if (isCompleted && task.expectedHash.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4.0),
                                    child: Row(
                                      children: [
                                        Icon(
                                          task.hashVerified == true ? Icons.verified : (task.hashVerified == false ? Icons.error : Icons.hourglass_empty),
                                          size: 14,
                                          color: task.hashVerified == true ? Colors.green : (task.hashVerified == false ? Colors.red : Colors.orange)
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          task.hashVerified == true ? 'Hash Verified' : (task.hashVerified == false ? 'Hash Mismatch' : 'Verifying...'),
                                          style: TextStyle(fontSize: 11, color: task.hashVerified == true ? Colors.green : (task.hashVerified == false ? Colors.red : Colors.orange))
                                        )
                                      ]
                                    ),
                                  )
                              ],
                            ),
                          ),
                          if (isActive && !task.errorMessage.startsWith('🔄') && !compact) ...[
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(task.errorMessage.isNotEmpty && task.speedBytesPerSecond == 0 ? task.errorMessage : FormattingHelper.formatSpeed(task.speedBytesPerSecond), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                Text(FormattingHelper.formatEta(task.etaSeconds), style: TextStyle(color: theme.hintColor, fontSize: 12)),
                              ],
                            ),
                            const SizedBox(width: 16),
                          ],
                          if (!selectionMode) Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isQueued) IconButton(icon: const Icon(Icons.flash_on), tooltip: 'Download Now', iconSize: compact ? 20 : 24, padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : null, constraints: compact ? const BoxConstraints() : null, onPressed: () => downloadManager.forceStartDownload(task)),
                              if (isActive && task.supportsRange) IconButton(icon: const Icon(Icons.pause), iconSize: compact ? 20 : 24, padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : null, constraints: compact ? const BoxConstraints() : null, onPressed: () => downloadManager.pauseDownload(task)),
                              if (isPaused) IconButton(icon: const Icon(Icons.play_arrow), iconSize: compact ? 20 : 24, padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : null, constraints: compact ? const BoxConstraints() : null, onPressed: () => downloadManager.enqueueDownload(task)),
                              if (isActive || isQueued) IconButton(icon: const Icon(Icons.close), color: Colors.red.shade400, iconSize: compact ? 20 : 24, padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : null, constraints: compact ? const BoxConstraints() : null, onPressed: () => downloadManager.cancelDownload(task)),
                              if (isFailed || task.status == DownloadStatus.cancelled) IconButton(icon: const Icon(Icons.refresh), iconSize: compact ? 20 : 24, padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : null, constraints: compact ? const BoxConstraints() : null, onPressed: () => downloadManager.retryDownload(task)),
                              if (isCompleted) IconButton(icon: const Icon(Icons.folder_open), color: theme.colorScheme.primary, iconSize: compact ? 20 : 24, padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : null, constraints: compact ? const BoxConstraints() : null, onPressed: () => Platform.isWindows ? Process.run('explorer.exe', ['/select,', task.fullPath]) : OpenFilex.open(task.saveDirectory)),
                              IconButton(
                                icon: const Icon(Icons.more_vert),
                                iconSize: compact ? 20 : 24,
                                padding: compact ? const EdgeInsets.only(left: 4) : null,
                                constraints: compact ? const BoxConstraints() : null,
                                onPressed: () {
                                  final RenderBox box = context.findRenderObject() as RenderBox;
                                  final Offset position = box.localToGlobal(Offset(box.size.width, 0));
                                  _showContextMenu(context, position);
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (isActive && compact && !task.errorMessage.startsWith('🔄')) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Text(
                              task.errorMessage.isNotEmpty && task.speedBytesPerSecond == 0 ? task.errorMessage : FormattingHelper.formatSpeed(task.speedBytesPerSecond),
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                            const SizedBox(width: 8),
                            Text('· ${FormattingHelper.formatEta(task.etaSeconds)}', style: TextStyle(color: theme.hintColor, fontSize: 12)),
                          ],
                        ),
                      ],
                      if (isActive || isPaused || isQueued) ...[
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: task.totalBytes > 0 ? progress : null,
                            minHeight: 8,
                            backgroundColor: theme.dividerColor.withAlpha(100),
                            valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                          ),
                        ),
                      ],
                      if (isFailed)
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text('⚠ ${task.errorMessage}', style: const TextStyle(color: Colors.red, fontSize: 12)),
                        )
                    ],
                  ),
                );
              },
            ),
          ),
        );
      }
    );
  }
}

// ==========================================
// 5. APPLICATION UI
// ==========================================

class DownloadManagerApp extends StatelessWidget {
  const DownloadManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: downloadManager,
      builder: (context, _) {
        return MaterialApp(
          title: 'Tasky',
          debugShowCheckedModeBanner: false,
          themeMode: downloadManager.appThemeMode,
          theme: ThemeData.light().copyWith(
            scaffoldBackgroundColor: Colors.white,
            cardColor: Colors.white,
            colorScheme: const ColorScheme.light(
              primary: Color(0xFFD2042D),
              secondary: Color(0xFF8B0000),
              surface: Colors.white,
              onSurface: Colors.black,
            ),
            appBarTheme: const AppBarTheme(backgroundColor: Colors.white, foregroundColor: Colors.black, elevation: 0),
          ),
          darkTheme: ThemeData.dark().copyWith(
            scaffoldBackgroundColor: Colors.black,
            cardColor: const Color(0xFF111111),
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFFD2042D),
              secondary: Color(0xFF8B0000),
              surface: Colors.black,
              onSurface: Colors.white,
            ),
            appBarTheme: const AppBarTheme(backgroundColor: Colors.black, foregroundColor: Colors.white, elevation: 0),
          ),
          home: const DashboardScreen(),
        );
      }
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  bool _isChecking = false;
  bool _isDragging = false;
  bool _isSearching = false;
  String _lastClipboardText = '';
  Timer? _clipboardTimer;

  static const double _mobileBreakpoint = 800;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchController.addListener(() => setState((){}));
    _clipboardTimer = Timer.periodic(const Duration(seconds: 2), (_) => _checkClipboard());
  }

  @override
  void dispose() {
    _clipboardTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _urlController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
      downloadManager.recheckScheduler();
    }
  }

  void _checkClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';

      if (text.isEmpty || text == _lastClipboardText) return;

      final urlRegExp = RegExp(r'^https?://.*\.(zip|rar|7z|iso|exe|msi|pdf|mp4|mkv|mp3|apk|deb|dmg|tar|gz)(\?.*)?$', caseSensitive: false);
      final isMagnet = text.startsWith('magnet:?');
      final isLocalTorrent = text.toLowerCase().endsWith('.torrent') && File(text).existsSync();

      if (urlRegExp.hasMatch(text) || isMagnet || isLocalTorrent) {
        _lastClipboardText = text;
        _showSmartClipboardPopup(text).catchError((e) {
          debugPrint('Clipboard popup failed: $e');
        });
      }
    } catch (e) {
      debugPrint('Clipboard check failed: $e');
    }
  }

  Future<void> _pickTorrentFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['torrent'],
      dialogTitle: 'Select .torrent File',
    );
    if (file != null && file.path != null) {
      _processUrl(file.path!);
    }
  }

  Future<void> _showSmartClipboardPopup(String url) async {
    final metadata = await downloadManager.fetchFileMetadata(url);

    if (!mounted || metadata['success'] != true) return;

    final currentDir = metadata['saveDirectory'];
    final freeBytes = await DiskSpaceHelper.getFreeBytes(currentDir);

    if (!mounted) return;

    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        padding: EdgeInsets.zero,
        backgroundColor: theme.cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: theme.colorScheme.primary.withAlpha(50), width: 1)
        ),
        duration: const Duration(seconds: 10),
        content: Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome, color: theme.colorScheme.primary, size: 18),
                  const SizedBox(width: 8),
                  Text('Download Link Detected', style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold, fontSize: 13)),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, size: 18, color: theme.hintColor),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
                  )
                ],
              ),
              const SizedBox(height: 12),
              Text(metadata['fileName'], style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: theme.colorScheme.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Text(metadata['totalBytes'] > 0 ? FormattingHelper.formatBytes(metadata['totalBytes'] as int) : 'Unknown Size', style: TextStyle(fontSize: 14, color: theme.hintColor, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              if (metadata['supportsRange'] == true && metadata['totalBytes'] > DownloadManager._segmentedMinFileSize && metadata['isTorrent'] != true)
                Row(
                  children: [
                    const Text('⚡ ', style: TextStyle(fontSize: 14)),
                    Text('${downloadManager.segmentsPerDownload} connections available', style: const TextStyle(color: Colors.green, fontSize: 13, fontWeight: FontWeight.w500)),
                  ],
                ),
              if (metadata['isTorrent'] == true)
                Row(
                  children: [
                    const Icon(Icons.cloud_download, color: Colors.blue, size: 16),
                    const SizedBox(width: 4),
                    const Text('Torrent engine available', style: TextStyle(color: Colors.blue, fontSize: 13, fontWeight: FontWeight.w500)),
                  ],
                ),
              if (freeBytes != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Row(
                    children: [
                      const Text('💾 ', style: TextStyle(fontSize: 14)),
                      Text('${FormattingHelper.formatBytes(freeBytes)} free on disk', style: TextStyle(color: theme.hintColor, fontSize: 13)),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
                    child: Text('Ignore', style: TextStyle(color: theme.hintColor)),
                  ),
                  if (HandoffActions.available)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.computer, size: 18),
                      label: const Text('Send to PC'),
                      onPressed: () {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        HandoffActions.send(
                          context,
                          url: metadata['cleanUrl'],
                          fileName: metadata['fileName'],
                        );
                      },
                    ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12)
                    ),
                    onPressed: () {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      downloadManager.enqueueDownload(DownloadTask(
                        id: DateTime.now().millisecondsSinceEpoch.toString(),
                        url: metadata['cleanUrl'],
                        fileName: metadata['fileName'],
                        saveDirectory: currentDir,
                        totalBytes: metadata['totalBytes'],
                        supportsRange: metadata['supportsRange'],
                      ));
                    },
                    child: const Text('DOWNLOAD', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
                  )
                ],
              )
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _processUrl(String url) async {
    setState(() => _isChecking = true);
    final metadata = await downloadManager.fetchFileMetadata(url);

    if (!mounted) return;
    setState(() => _isChecking = false);

    if (metadata['success'] == true) {
      final dup = await downloadManager.checkForDuplicate(
        metadata['cleanUrl'] as String,
        metadata['saveDirectory'] as String,
        metadata['fileName'] as String,
      );
      if (!mounted) return;
      
      if (dup.hasMatch) {
        _showDuplicateDialog(dup, metadata);
      } else {
        _showAddDialog(metadata);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(metadata['error']), backgroundColor: Colors.red));
    }
  }

  void _showDuplicateDialog(DuplicateCheckResult dup, Map<String, dynamic> meta) {
    final isCompletedOnly = dup.completedMatch != null && dup.activeMatch == null;
    final existing = dup.activeMatch ?? dup.completedMatch!;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: Colors.orange), SizedBox(width: 8), Text('Possible Duplicate')]),
        content: Text(
          isCompletedOnly
              ? '"${existing.fileName}" already appears to be downloaded in this folder.'
              : 'This URL is already ${existing.status.name} in your list as "${existing.fileName}".',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          if (!isCompletedOnly && existing.status == DownloadStatus.paused)
            OutlinedButton(onPressed: () { Navigator.pop(ctx); downloadManager.enqueueDownload(existing); }, child: const Text('Resume Existing')),
          if (isCompletedOnly)
            OutlinedButton(onPressed: () { Navigator.pop(ctx); OpenFilex.open(existing.fullPath); }, child: const Text('Open File')),
          ElevatedButton(onPressed: () { Navigator.pop(ctx); _showAddDialog(meta); }, child: const Text('Download Anyway')),
        ],
      ),
    );
  }

  InputDecoration _dialogInputDecoration(BuildContext context, String label, {Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      suffixIcon: suffix,
      filled: true,
      fillColor: Theme.of(context).dividerColor.withAlpha(20),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
    );
  }

  void _showBatchImportDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const BatchImportDialogWidget(),
    );
  }

  void _showAddDialog(Map<String, dynamic> meta) {
    final nameController = TextEditingController(text: meta['fileName']);
    String currentDir = meta['saveDirectory'];
    String expectedHash = '';
    String hashAlgorithm = 'SHA-256';

    bool enableSchedule = false;
    TimeOfDay? scheduleStart = const TimeOfDay(hour: 2, minute: 0);
    TimeOfDay? scheduleStop = const TimeOfDay(hour: 7, minute: 0);
    bool isTorrent = meta['isTorrent'] == true;

    Future<int?> freeSpaceFuture = DiskSpaceHelper.getFreeBytes(currentDir);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> pickDir() async {
            final picked = await FilePicker.getDirectoryPath(dialogTitle: 'Select Location');
            if (picked != null) {
              setDialogState(() {
                currentDir = picked;
                freeSpaceFuture = DiskSpaceHelper.getFreeBytes(currentDir);
              });
            }
          }

          final dialogWidth = MediaQuery.of(context).size.width < 560
              ? MediaQuery.of(context).size.width * 0.92
              : 500.0;

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(children: [Icon(isTorrent ? Icons.cloud_download : Icons.download, color: isTorrent ? Colors.blue : Theme.of(context).colorScheme.primary), const SizedBox(width: 8), const Text('Add Download')]),
            content: SizedBox(
              width: dialogWidth,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: TextEditingController(text: meta['cleanUrl']), readOnly: true, decoration: _dialogInputDecoration(context, 'URL')),
                    const SizedBox(height: 16),
                    TextField(controller: TextEditingController(text: currentDir), readOnly: true, decoration: _dialogInputDecoration(context, 'Save Location', suffix: IconButton(icon: const Icon(Icons.folder), onPressed: pickDir))),
                    const SizedBox(height: 16),
                    TextField(controller: nameController, decoration: _dialogInputDecoration(context, 'File Name')),
                    const SizedBox(height: 16),
                    if (!isTorrent) Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            onChanged: (v) => expectedHash = v,
                            decoration: _dialogInputDecoration(context, 'Expected Hash (Optional)'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 1,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(color: Theme.of(context).dividerColor.withAlpha(20), borderRadius: BorderRadius.circular(8)),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: hashAlgorithm,
                                isExpanded: true,
                                items: ['MD5', 'SHA-1', 'SHA-256'].map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 14)))).toList(),
                                onChanged: (v) => setDialogState(() => hashAlgorithm = v!),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (!isTorrent) const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Size: ${FormattingHelper.formatBytes(meta['totalBytes'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text(meta['supportsRange'] ? 'Resume Supported ✓' : (isTorrent ? 'Torrent Engine ✓' : 'Resume Not Supported'), style: TextStyle(color: (meta['supportsRange'] || isTorrent) ? Colors.green : Colors.orange)),
                      ],
                    ),
                    if (meta['supportsRange'] == true && (meta['totalBytes'] as int) >= DownloadManager._segmentedMinFileSize && !isTorrent)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            Icon(Icons.bolt, size: 14, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Will download using up to ${downloadManager.segmentsPerDownload} parallel connections',
                                style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary),
                              ),
                            ),
                          ],
                        ),
                      ),
                    FutureBuilder<int?>(
                      future: freeSpaceFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done || snapshot.data == null) {
                          return const SizedBox.shrink();
                        }
                        final free = snapshot.data!;
                        final needed = meta['totalBytes'] as int;
                        final insufficient = needed > 0 && free < (needed + DiskSpaceHelper.safetyBufferBytes);
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              Icon(Icons.storage, size: 16, color: insufficient ? Colors.red : Theme.of(context).hintColor),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  insufficient
                                      ? 'Only ${FormattingHelper.formatBytes(free)} free — not enough space for this download.'
                                      : '${FormattingHelper.formatBytes(free)} free on disk',
                                  style: TextStyle(fontSize: 12, color: insufficient ? Colors.red : Theme.of(context).hintColor, fontWeight: insufficient ? FontWeight.bold : FontWeight.normal),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    AnimatedBuilder(
                      animation: downloadManager,
                      builder: (context, _) {
                        if (!downloadManager.isOffline) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              Icon(Icons.wifi_off, size: 16, color: Colors.orange.shade700),
                              const SizedBox(width: 6),
                              Text('You\'re offline — this will queue and start automatically once reconnected.', style: TextStyle(fontSize: 12, color: Colors.orange.shade700)),
                            ],
                          ),
                        );
                      },
                    ),
                    const Divider(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Schedule this download', style: TextStyle(fontWeight: FontWeight.bold)),
                      value: enableSchedule,
                      onChanged: (val) => setDialogState(() => enableSchedule = val),
                      activeThumbColor: Theme.of(context).colorScheme.primary,
                    ),
                    if (enableSchedule) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            icon: const Icon(Icons.play_circle_outline, size: 18),
                            label: Text('Start: ${FormattingHelper.formatTime(scheduleStart!, downloadManager.use24HourFormat)}'),
                            onPressed: () async {
                              final t = await downloadManager.pickTime(context, scheduleStart!);
                              if (t != null) {
                                setDialogState(() => scheduleStart = t);
                              }
                            }
                          ),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.stop_circle_outlined, size: 18),
                            label: Text('Stop: ${FormattingHelper.formatTime(scheduleStop!, downloadManager.use24HourFormat)}'),
                            onPressed: () async {
                              final t = await downloadManager.pickTime(context, scheduleStop!);
                              if (t != null) {
                                setDialogState(() => scheduleStop = t);
                              }
                            }
                          ),
                        ]
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
            actionsOverflowButtonSpacing: 8,
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              SendToPcButton(
                url: () => meta['cleanUrl'] as String? ?? '',
                fileName: () => nameController.text,
              ),
              if (enableSchedule)
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white),
                  onPressed: () {
                    downloadManager.enqueueDownload(DownloadTask(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      url: meta['cleanUrl'],
                      fileName: nameController.text,
                      saveDirectory: currentDir,
                      totalBytes: meta['totalBytes'],
                      supportsRange: meta['supportsRange'],
                      expectedHash: expectedHash,
                      hashAlgorithm: hashAlgorithm,
                      isSchedulerEnabled: enableSchedule,
                      scheduleStartTime: enableSchedule ? scheduleStart : null,
                      scheduleStopTime: enableSchedule ? scheduleStop : null,
                    ));
                    Navigator.pop(context);
                  },
                  child: const Text('Schedule Download'),
                )
              else ...[
                OutlinedButton(
                  onPressed: () {
                    downloadManager.addAsPaused(DownloadTask(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      url: meta['cleanUrl'],
                      fileName: nameController.text,
                      saveDirectory: currentDir,
                      totalBytes: meta['totalBytes'],
                      supportsRange: meta['supportsRange'],
                      expectedHash: expectedHash,
                      hashAlgorithm: hashAlgorithm,
                      isSchedulerEnabled: false,
                    ));
                    Navigator.pop(context);
                  },
                  child: const Text('Add as Paused'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white),
                  onPressed: () {
                    downloadManager.forceStartDownload(DownloadTask(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      url: meta['cleanUrl'],
                      fileName: nameController.text,
                      saveDirectory: currentDir,
                      totalBytes: meta['totalBytes'],
                      supportsRange: meta['supportsRange'],
                      expectedHash: expectedHash,
                      hashAlgorithm: hashAlgorithm,
                      isSchedulerEnabled: false,
                    ));
                    Navigator.pop(context);
                  },
                  child: const Text('Download Now'),
                ),
              ],
            ],
          );
        }
      )
    );
  }

  void _showSettings() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Settings'),
          content: SizedBox(
            width: math.min(MediaQuery.of(context).size.width * 0.92, 440),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Download Threads per File'),
                    subtitle: const Text('Splits large files into parallel connections for faster speed'),
                    trailing: DropdownButton<int>(
                      value: downloadManager.segmentsPerDownload,
                      items: const [1, 2, 4, 6, 8, 12, 16].map((n) => DropdownMenuItem(value: n, child: Text(n == 1 ? 'Off' : '$n×'))).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          downloadManager.setSegmentsPerDownload(val);
                          setDialogState(() {});
                        }
                      },
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Global Speed Limit'),
                    subtitle: const Text('Throttle total bandwidth'),
                    trailing: DropdownButton<int>(
                      value: downloadManager.globalSpeedLimitKbps,
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('Unlimited')),
                        DropdownMenuItem(value: 256, child: Text('256 KB/s')),
                        DropdownMenuItem(value: 1024, child: Text('1 MB/s')),
                        DropdownMenuItem(value: 5120, child: Text('5 MB/s')),
                        DropdownMenuItem(value: 10240, child: Text('10 MB/s')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          downloadManager.setGlobalSpeedLimit(val);
                          setDialogState(() {});
                        }
                      },
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Max Concurrent Downloads'),
                    subtitle: const Text('How many downloads run in parallel'),
                    trailing: DropdownButton<int>(
                      value: downloadManager.maxConcurrentDownloads,
                      items: List.generate(10, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
                      onChanged: (val) {
                        if (val != null) {
                          downloadManager.updateMaxConcurrentDownloads(val);
                          setDialogState(() {});
                        }
                      },
                    ),
                  ),
                  const Divider(),
                  const Padding(
                    padding: EdgeInsets.only(top: 4, bottom: 4),
                    child: Text('Queue Scheduling', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Text(
                    'Decides which queued download starts next when a slot frees up.',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                  ),
                  const SizedBox(height: 8),
                  ...QueueSortStrategy.values.map((s) => RadioMenuButton<QueueSortStrategy>(
                    value: s,
                    groupValue: downloadManager.queueSortStrategy,
                    onChanged: (val) {
                      if (val != null) {
                        downloadManager.setQueueSortStrategy(val);
                        setDialogState(() {});
                      }
                    },
                    child: Text(s.label),
                  )),
                  const Divider(),
                  const Padding(
                    padding: EdgeInsets.only(top: 4, bottom: 4),
                    child: Text('Global Scheduler', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Text(
                    'Automatically start and stop queued downloads between specific hours. "Download Now" always ignores this and starts immediately.',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable Scheduler', style: TextStyle(fontSize: 14)),
                    value: downloadManager.isSchedulerEnabled,
                    onChanged: (val) {
                      downloadManager.setSchedulerEnabled(val);
                      setDialogState(() {});
                    },
                    activeThumbColor: Theme.of(context).colorScheme.primary,
                  ),
                  if (downloadManager.isSchedulerEnabled) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          icon: const Icon(Icons.play_circle_outline, size: 18),
                          label: Text('Start: ${FormattingHelper.formatTime(downloadManager.scheduleStartTime ?? const TimeOfDay(hour: 2, minute: 0), downloadManager.use24HourFormat)}'),
                          onPressed: () async {
                            final t = await downloadManager.pickTime(context, downloadManager.scheduleStartTime ?? const TimeOfDay(hour: 2, minute: 0));
                            if (t != null) {
                              downloadManager.setSchedulerTimes(start: t);
                              setDialogState(() {});
                            }
                          }
                        ),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.stop_circle_outlined, size: 18),
                          label: Text('Stop: ${FormattingHelper.formatTime(downloadManager.scheduleStopTime ?? const TimeOfDay(hour: 7, minute: 0), downloadManager.use24HourFormat)}'),
                          onPressed: () async {
                            final t = await downloadManager.pickTime(context, downloadManager.scheduleStopTime ?? const TimeOfDay(hour: 7, minute: 0));
                            if (t != null) {
                              downloadManager.setSchedulerTimes(stop: t);
                              setDialogState(() {});
                            }
                          }
                        ),
                      ]
                    ),
                    if (!downloadManager.isInSchedulerWindow && downloadManager.timeUntilNextWindowOpen != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, size: 14, color: Theme.of(context).hintColor),
                            const SizedBox(width: 6),
                            Text(
                              'Outside the window right now — resumes in ${FormattingHelper.formatEta(downloadManager.timeUntilNextWindowOpen!.inSeconds)}.',
                              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                  const Divider(),
                  const Padding(
                    padding: EdgeInsets.only(top: 4, bottom: 4),
                    child: Text('System', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use 24-Hour Clock Format', style: TextStyle(fontSize: 14)),
                    value: downloadManager.use24HourFormat,
                    onChanged: (val) {
                      downloadManager.setTimeFormat(val);
                      setDialogState(() {});
                    },
                    activeThumbColor: Theme.of(context).colorScheme.primary,
                  ),
                  const Divider(),
                  const HandoffSettingsSection(),
                ],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      )
    );
  }

  void _showBulkDeleteDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Selected?'),
        content: Text('Delete ${downloadManager.selectedTaskIds.length} items?\nDo you also want to delete the files from your computer?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              downloadManager.deleteSelected(deleteFile: false);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Items removed from list.')));
            },
            child: const Text('Remove from List'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              downloadManager.deleteSelected(deleteFile: true);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Files and list items deleted.')));
            },
            child: const Text('Delete Files & List'),
          ),
        ],
      )
    );
  }

  // =========================================================
  // BUILD — responsive entry point
  // =========================================================
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: downloadManager,
      builder: (context, _) {
        final bool isSelectionMode = downloadManager.isSelectionMode;
        final double width = MediaQuery.of(context).size.width;
        final bool isMobile = width < _mobileBreakpoint;

        return Scaffold(
          drawer: isMobile ? Drawer(child: SafeArea(child: _buildSidebar())) : null,
          appBar: isSelectionMode ? _buildSelectionAppBar() : _buildDefaultAppBar(isMobile),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                if (downloadManager.isOffline) _buildOfflineBanner(),
                if (downloadManager.isSchedulerEnabled && !downloadManager.isOffline) _buildSchedulerBanner(isMobile),
                Expanded(
                  child: DropTarget(
                    onDragDone: (detail) {
                      if (detail.files.isNotEmpty) {
                        _processUrl(detail.files.first.path);
                      }
                    },
                    onDragEntered: (detail) => setState(() => _isDragging = true),
                    onDragExited: (detail) => setState(() => _isDragging = false),
                    child: Container(
                      color: _isDragging ? Theme.of(context).colorScheme.primary.withAlpha(20) : null,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final bool narrow = constraints.maxWidth < _mobileBreakpoint;
                          if (narrow) {
                            return _buildMainContent(isMobile: true);
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildSidebar(),
                              Expanded(child: _buildMainContent(isMobile: false)),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    );
  }

  // =========================================================
  // APP BARS
  // =========================================================
  PreferredSizeWidget _buildSelectionAppBar() {
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(20),
      leading: IconButton(icon: const Icon(Icons.close), onPressed: downloadManager.clearSelection),
      title: Text('${downloadManager.selectedTaskIds.length} Selected', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
      actions: [
        IconButton(icon: const Icon(Icons.select_all), tooltip: 'Select All', onPressed: () => downloadManager.selectAll(downloadManager.displayedTasks)),
        IconButton(icon: const Icon(Icons.play_arrow), tooltip: 'Resume Selected', onPressed: downloadManager.resumeSelected),
        IconButton(icon: const Icon(Icons.pause), tooltip: 'Pause Selected', onPressed: downloadManager.pauseSelected),
        IconButton(icon: const Icon(Icons.delete, color: Colors.red), tooltip: 'Delete Selected', onPressed: _showBulkDeleteDialog),
        const SizedBox(width: 8),
      ],
    );
  }

  PreferredSizeWidget _buildDefaultAppBar(bool isMobile) {
    if (!isMobile) {
      return AppBar(
        actions: [
          Container(
            width: 250,
            margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search downloads...',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () { _searchController.clear(); downloadManager.setSearchQuery(''); })
                    : null,
                filled: true,
                fillColor: Theme.of(context).cardColor,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
              ),
              onChanged: downloadManager.setSearchQuery,
            ),
          ),
          IconButton(
            icon: Icon(downloadManager.appThemeMode == ThemeMode.dark ? Icons.dark_mode : (downloadManager.appThemeMode == ThemeMode.light ? Icons.light_mode : Icons.brightness_auto)),
            tooltip: 'Toggle Theme',
            onPressed: downloadManager.toggleTheme,
          ),
          IconButton(icon: const Icon(Icons.settings), tooltip: 'Settings', onPressed: _showSettings),
          IconButton(
            icon: const Icon(Icons.speed),
            tooltip: 'Speed Center',
            onPressed: () => showDialog(context: context, builder: (_) => const SpeedCenterDialog()),
          ),
          const SizedBox(width: 16),
        ],
      );
    }

    return AppBar(
      titleSpacing: _isSearching ? 0 : null,
      title: _isSearching
          ? TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search downloads...',
                border: InputBorder.none,
                isDense: true,
              ),
              onChanged: downloadManager.setSearchQuery,
            )
          : const Text('Tasky'),
      actions: [
        IconButton(
          icon: Icon(_isSearching ? Icons.close : Icons.search),
          onPressed: () {
            setState(() {
              if (_isSearching) {
                _searchController.clear();
                downloadManager.setSearchQuery('');
              }
              _isSearching = !_isSearching;
            });
          },
        ),
        if (!_isSearching) ...[
          IconButton(
            icon: Icon(downloadManager.appThemeMode == ThemeMode.dark ? Icons.dark_mode : (downloadManager.appThemeMode == ThemeMode.light ? Icons.light_mode : Icons.brightness_auto)),
            tooltip: 'Toggle Theme',
            onPressed: downloadManager.toggleTheme,
          ),
          PopupMenuButton<void>(
            icon: const Icon(Icons.more_vert),
            itemBuilder: (ctx) => [
              PopupMenuItem<void>(
                child: const ListTile(leading: Icon(Icons.settings), title: Text('Settings')),
                onTap: () => Future.delayed(Duration.zero, _showSettings),
              ),
              PopupMenuItem<void>(
                child: const ListTile(leading: Icon(Icons.speed), title: Text('Speed Center')),
                onTap: () => Future.delayed(Duration.zero, () => showDialog(context: context, builder: (_) => const SpeedCenterDialog())),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildOfflineBanner() {
    return Container(
      width: double.infinity,
      color: Colors.orange.shade700,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: const Row(
        children: [
          Icon(Icons.wifi_off, color: Colors.white, size: 18),
          SizedBox(width: 8),
          Expanded(child: Text('No internet connection — active downloads are paused and will resume automatically once you\'re back online.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildSchedulerBanner(bool isMobile) {
    final text = isMobile
        ? 'Scheduler active: ${FormattingHelper.formatTime(downloadManager.scheduleStartTime!, downloadManager.use24HourFormat)} – ${FormattingHelper.formatTime(downloadManager.scheduleStopTime!, downloadManager.use24HourFormat)}'
        : 'Global Scheduler is active. Standard downloads obey window: ${FormattingHelper.formatTime(downloadManager.scheduleStartTime!, downloadManager.use24HourFormat)} – ${FormattingHelper.formatTime(downloadManager.scheduleStopTime!, downloadManager.use24HourFormat)}';
    return Container(
      width: double.infinity,
      color: Colors.blue.shade700,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.public, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  // =========================================================
  // SIDEBAR
  // =========================================================
  Widget _buildSidebar() {
    final theme = Theme.of(context);
    final isDownloads = downloadManager.currentTab == MainTab.downloads;

    final tabTasks = downloadManager.activeTasks.where((t) =>
        isDownloads ? !t.isTorrent : t.isTorrent
    ).toList();

    int all = tabTasks.length;
    int active = tabTasks.where((t) => [DownloadStatus.downloading, DownloadStatus.connecting].contains(t.status)).length;
    int queued = tabTasks.where((t) => t.status == DownloadStatus.waiting).length;
    int paused = tabTasks.where((t) => t.status == DownloadStatus.paused).length;
    int completed = tabTasks.where((t) => t.status == DownloadStatus.completed).length;
    int failed = tabTasks.where((t) => t.status == DownloadStatus.failed).length;

    return SizedBox(
      width: 240,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: theme.dividerColor.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => downloadManager.setTab(MainTab.downloads),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: isDownloads ? theme.cardColor : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: isDownloads ? [BoxShadow(color: Colors.black.withAlpha(10), blurRadius: 4, offset: const Offset(0, 2))] : [],
                        ),
                        alignment: Alignment.center,
                        child: Text('Downloads', style: TextStyle(fontWeight: isDownloads ? FontWeight.bold : FontWeight.normal, color: isDownloads ? theme.colorScheme.primary : theme.hintColor)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () => downloadManager.setTab(MainTab.torrents),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: !isDownloads ? theme.cardColor : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: !isDownloads ? [BoxShadow(color: Colors.black.withAlpha(10), blurRadius: 4, offset: const Offset(0, 2))] : [],
                        ),
                        alignment: Alignment.center,
                        child: Text('Torrents', style: TextStyle(fontWeight: !isDownloads ? FontWeight.bold : FontWeight.normal, color: !isDownloads ? Colors.blue : theme.hintColor)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                _sidebarItem('All', Icons.home_outlined, DownloadFilter.all, all),
                _sidebarItem('Active', Icons.play_arrow_outlined, DownloadFilter.active, active),
                _sidebarItem('Queued', Icons.hourglass_empty, DownloadFilter.queued, queued),
                _sidebarItem('Paused', Icons.pause_circle_outline, DownloadFilter.paused, paused),
                _sidebarItem('Completed', Icons.check_circle_outline, DownloadFilter.completed, completed),
                _sidebarItem('Failed', Icons.error_outline, DownloadFilter.failed, failed),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebarItem(String title, IconData icon, DownloadFilter filter, int count) {
    final isSelected = downloadManager.currentFilter == filter;
    final tabColor = downloadManager.currentTab == MainTab.downloads
        ? Theme.of(context).colorScheme.primary
        : Colors.blue;
    final color = isSelected ? tabColor : Theme.of(context).hintColor;

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: TextStyle(color: color, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      trailing: count > 0 ? Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: isSelected ? color.withAlpha(25) : Theme.of(context).dividerColor.withAlpha(50), borderRadius: BorderRadius.circular(12)),
        child: Text('$count', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      ) : null,
      selected: isSelected,
      onTap: () {
        downloadManager.setFilter(filter);
        if (Scaffold.of(context).isDrawerOpen) Navigator.pop(context);
      },
    );
  }

  // =========================================================
  // MAIN CONTENT
  // =========================================================
  Widget _buildMainContent({required bool isMobile}) {
    final theme = Theme.of(context);
    final displayedTasks = downloadManager.displayedTasks;
    final isDownloadsTab = downloadManager.currentTab == MainTab.downloads;
    final primaryColor = isDownloadsTab ? theme.colorScheme.primary : Colors.blue;
    final double contentPadding = isMobile ? 12.0 : 24.0;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: isMobile ? null : const BorderRadius.only(topLeft: Radius.circular(24)),
        border: isMobile ? null : Border(left: BorderSide(color: theme.dividerColor.withAlpha(20)), top: BorderSide(color: theme.dividerColor.withAlpha(20))),
      ),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(contentPadding),
            child: isMobile ? _buildAddDownloadRowMobile(isDownloadsTab, primaryColor) : _buildAddDownloadRowDesktop(isDownloadsTab, primaryColor),
          ),
          Container(
            padding: EdgeInsets.symmetric(horizontal: contentPadding, vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.dividerColor.withAlpha(20)))),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        FileCategory.all,
                        FileCategory.media,
                        FileCategory.documents,
                        FileCategory.archives,
                        FileCategory.programs,
                        if (isDownloadsTab) FileCategory.others,
                      ].map((cat) {
                        final isSelected = downloadManager.currentCategory == cat;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: FilterChip(
                            label: Text(cat.name.substring(0, 1).toUpperCase() + cat.name.substring(1)),
                            selected: isSelected,
                            onSelected: (_) => downloadManager.setCategory(cat),
                            backgroundColor: theme.scaffoldBackgroundColor,
                            selectedColor: primaryColor.withAlpha(20),
                            labelStyle: TextStyle(color: isSelected ? primaryColor : theme.hintColor),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: isSelected ? primaryColor : Colors.transparent)),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                if (!isMobile)
                  DropdownButtonHideUnderline(
                    child: DropdownButton<SortBy>(
                      value: downloadManager.listSortBy,
                      icon: Icon(Icons.sort, color: theme.hintColor, size: 20),
                      alignment: Alignment.centerRight,
                      style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 13),
                      items: SortBy.values.map((s) => DropdownMenuItem(value: s, child: Text(s.label))).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          downloadManager.setListSort(val);
                        }
                      },
                    ),
                  )
                else
                  IconButton(
                    icon: Icon(Icons.sort, color: theme.hintColor, size: 20),
                    tooltip: 'Sort',
                    onPressed: _showMobileSortSheet,
                  ),
                if (downloadManager.currentFilter == DownloadFilter.completed && displayedTasks.isNotEmpty) ...[
                  if (!isMobile) ...[
                    const SizedBox(width: 16),
                    TextButton.icon(
                      onPressed: downloadManager.clearCompleted,
                      icon: const Icon(Icons.clear_all, size: 18),
                      label: const Text('Clear Completed'),
                      style: TextButton.styleFrom(foregroundColor: theme.hintColor),
                    )
                  ] else
                    IconButton(
                      icon: const Icon(Icons.clear_all, size: 20),
                      tooltip: 'Clear Completed',
                      color: theme.hintColor,
                      onPressed: downloadManager.clearCompleted,
                    ),
                ]
              ],
            ),
          ),
          Expanded(
            child: displayedTasks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inbox, size: 64, color: theme.dividerColor),
                      const SizedBox(height: 16),
                      Text('No downloads found', style: TextStyle(color: theme.hintColor, fontSize: 16)),
                    ],
                  ),
                )
              : downloadManager.listSortBy == SortBy.manual && downloadManager.searchQuery.isEmpty && downloadManager.currentFilter == DownloadFilter.all && downloadManager.currentCategory == FileCategory.all
                  ? ReorderableListView.builder(
                      padding: EdgeInsets.all(contentPadding),
                      buildDefaultDragHandles: false,
                      itemCount: displayedTasks.length,
                      onReorderItem: (oldIndex, newIndex) => downloadManager.reorderGlobal(oldIndex, newIndex, displayedTasks),
                      itemBuilder: (context, index) {
                        final task = displayedTasks[index];
                        final isWaiting = task.status == DownloadStatus.waiting;
                        int? qPos;
                        if (isWaiting) {
                          final waitingTasks = displayedTasks.where((t) => t.status == DownloadStatus.waiting).toList();
                          qPos = waitingTasks.indexOf(task) + 1;
                        }
                        return Container(
                          key: ValueKey(task.id),
                          child: task.isTorrent
                            ? TorrentDownloadCard(task: task, queuePosition: qPos, showDragHandle: true, listIndex: index)
                            : DetailedDownloadCard(task: task, queuePosition: qPos, showDragHandle: true, listIndex: index),
                        );
                      },
                    )
                  : ListView.builder(
                      padding: EdgeInsets.all(contentPadding),
                      itemCount: displayedTasks.length,
                      itemBuilder: (context, index) {
                        final task = displayedTasks[index];
                        final isWaiting = task.status == DownloadStatus.waiting;
                        int? qPos;
                        if (isWaiting) {
                          final waitingTasks = displayedTasks.where((t) => t.status == DownloadStatus.waiting).toList();
                          qPos = waitingTasks.indexOf(task) + 1;
                        }
                        if (task.isTorrent) {
                          return TorrentDownloadCard(task: task, queuePosition: qPos);
                        }
                        return DetailedDownloadCard(task: task, queuePosition: qPos);
                      },
                    ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddDownloadRowDesktop(bool isDownloadsTab, Color primaryColor) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _urlController,
            decoration: InputDecoration(
              hintText: isDownloadsTab ? 'Enter URL to download...' : 'Enter magnet link or URL...',
              prefixIcon: const Icon(Icons.link),
              filled: true,
              fillColor: theme.scaffoldBackgroundColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onSubmitted: (url) {
              if (url.isNotEmpty) {
                _processUrl(url);
                _urlController.clear();
              }
            },
          ),
        ),
        const SizedBox(width: 12),
        ElevatedButton.icon(
          onPressed: _isChecking
              ? null
              : () {
                  if (_urlController.text.isNotEmpty) {
                    _processUrl(_urlController.text);
                    _urlController.clear();
                  }
                },
          icon: _isChecking ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.add),
          label: Text(_isChecking ? 'Checking...' : 'Download'),
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(width: 12),
        ElevatedButton.icon(
          onPressed: isDownloadsTab ? _showBatchImportDialog : _pickTorrentFile,
          icon: Icon(isDownloadsTab ? Icons.library_add : Icons.folder_open),
          label: Text(isDownloadsTab ? 'Batch Import' : 'Open .torrent'),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.scaffoldBackgroundColor,
            foregroundColor: theme.colorScheme.onSurface,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    );
  }

  Widget _buildAddDownloadRowMobile(bool isDownloadsTab, Color primaryColor) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _urlController,
            decoration: InputDecoration(
              hintText: isDownloadsTab ? 'Enter URL...' : 'Magnet link or URL...',
              prefixIcon: const Icon(Icons.link, size: 20),
              isDense: true,
              filled: true,
              fillColor: theme.scaffoldBackgroundColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
            ),
            onSubmitted: (url) {
              if (url.isNotEmpty) {
                _processUrl(url);
                _urlController.clear();
              }
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 48,
          width: 48,
          child: _isChecking
              ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton.filled(
                  onPressed: () {
                    if (_urlController.text.isNotEmpty) {
                      _processUrl(_urlController.text);
                      _urlController.clear();
                    }
                  },
                  icon: const Icon(Icons.add),
                  style: IconButton.styleFrom(backgroundColor: primaryColor, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 48,
          width: 48,
          child: IconButton(
            tooltip: isDownloadsTab ? 'Batch Import' : 'Open .torrent',
            onPressed: isDownloadsTab ? _showBatchImportDialog : _pickTorrentFile,
            icon: Icon(isDownloadsTab ? Icons.library_add : Icons.folder_open),
            style: IconButton.styleFrom(backgroundColor: theme.scaffoldBackgroundColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ),
      ],
    );
  }

  void _showMobileSortSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 12, bottom: 4),
              child: Text('Sort by', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ...SortBy.values.map((s) => ListTile(
              title: Text(s.label),
              trailing: downloadManager.listSortBy == s ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                downloadManager.setListSort(s);
                Navigator.pop(ctx);
              },
            )),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------
// 6. BATCH IMPORT DIALOG WIDGET
// ------------------------------------------
class BatchImportDialogWidget extends StatefulWidget {
  const BatchImportDialogWidget({super.key});

  @override
  State<BatchImportDialogWidget> createState() => _BatchImportDialogWidgetState();
}

class _BatchImportDialogWidgetState extends State<BatchImportDialogWidget> {
  final TextEditingController _batchController = TextEditingController();
  bool _isProcessing = false;
  List<Map<String, dynamic>> _parsedUrls = [];
  String _batchSaveDir = '';

  @override
  void initState() {
    super.initState();
    _initDefaultDir();
  }

  Future<void> _initDefaultDir() async {
    final dir = await getDefaultDownloadDir();
    setState(() => _batchSaveDir = dir.path);
  }

  Future<void> _processBatchText() async {
    final text = _batchController.text;
    if (text.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _parsedUrls = [];
    });

    final lines = text.split('\n');
    final validUrls = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty && (trimmed.startsWith('http') || trimmed.startsWith('magnet:?'))) {
        validUrls.add(trimmed);
      }
    }

    final results = <Map<String, dynamic>>[];
    for (final url in validUrls) {
      final meta = await downloadManager.fetchFileMetadata(url);
      if (meta['success'] == true) {
        meta['saveDirectory'] = _batchSaveDir;
        results.add(meta);
      }
    }

    if (mounted) {
      setState(() {
        _parsedUrls = results;
        _isProcessing = false;
      });
    }
  }

  void _addParsedDownloads() {
    for (final meta in _parsedUrls) {
      downloadManager.enqueueDownload(DownloadTask(
        id: DateTime.now().millisecondsSinceEpoch.toString() + meta['cleanUrl'].hashCode.toString(),
        url: meta['cleanUrl'],
        fileName: meta['fileName'],
        saveDirectory: meta['saveDirectory'],
        totalBytes: meta['totalBytes'],
        supportsRange: meta['supportsRange'],
      ));
    }
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_parsedUrls.length} downloads added to queue.')));
  }

  @override
  void dispose() {
    _batchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final bool isMobile = screenSize.width < 600;
    final double dialogWidth = isMobile ? screenSize.width * 0.92 : 600;
    final double dialogHeight = isMobile ? screenSize.height * 0.7 : 400;

    return AlertDialog(
      insetPadding: isMobile
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 24)
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      title: const Row(
        children: [
          Icon(Icons.library_add),
          SizedBox(width: 8),
          Flexible(child: Text('Batch Import Downloads', overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            if (_parsedUrls.isEmpty) ...[
              const Text('Paste multiple URLs below (one per line) to add them all at once.'),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: _batchController,
                  maxLines: null,
                  expands: true,
                  decoration: InputDecoration(
                    hintText: 'https://example.com/file1.zip\nhttps://example.com/file2.rar\nmagnet:?xt=urn:btih:...',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    filled: true,
                    fillColor: Theme.of(context).dividerColor.withAlpha(20),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Save To: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Expanded(
                    child: Text(_batchSaveDir, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.folder),
                    label: const Text('Change'),
                    onPressed: () async {
                      final picked = await FilePicker.getDirectoryPath(dialogTitle: 'Select Location');
                      if (picked != null) {
                        setState(() => _batchSaveDir = picked);
                      }
                    },
                  )
                ]
              )
            ] else ...[
              Text('Found ${_parsedUrls.length} valid links. Review them below before adding.'),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: _parsedUrls.length,
                  itemBuilder: (ctx, i) {
                    final meta = _parsedUrls[i];
                    return ListTile(
                      leading: Icon(meta['isTorrent'] == true ? Icons.cloud_download : Icons.file_present),
                      title: Text(meta['fileName'], maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(meta['totalBytes'] > 0 ? FormattingHelper.formatBytes(meta['totalBytes']) : 'Unknown size'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => setState(() => _parsedUrls.removeAt(i)),
                      ),
                    );
                  }
                ),
              ),
            ]
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (_parsedUrls.isEmpty)
          ElevatedButton(
            onPressed: _isProcessing || _batchController.text.trim().isEmpty ? null : _processUrlList,
            child: _isProcessing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Scan Links'),
          )
        else
          ElevatedButton(
            onPressed: _parsedUrls.isEmpty ? null : _addParsedDownloads,
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white),
            child: Text('Add ${_parsedUrls.length} Downloads'),
          ),
      ],
    );
  }

  Future<void> _processUrlList() async {
    await _processBatchText();
  }
}