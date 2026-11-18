// handoff_ui.dart
// Phone <-> PC link handoff over the local network, paired with a QR code.
//
// Put this file next to main.dart in lib/. main.dart already imports it.
// Needs in pubspec.yaml: qr_flutter, simple_barcode_scanner
//
// How it works:
//  * Every device runs a tiny HTTP receiver on the LAN (port 47653+).
//  * Device A shows a QR (its IPs, port, one-time code). Device B scans it.
//  * They swap per-device secret tokens, so later requests are authenticated.
//  * "Send to PC/Phone" POSTs {url, fileName, headers, referer} to the peer,
//    which calls downloadManager.addDownload(...).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:simple_barcode_scanner/simple_barcode_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

// main.dart <-> handoff_ui.dart import each other. Dart allows that.
import 'main.dart';

const int kHandoffBasePort = 47653;

// ==========================================
// HELPERS
// ==========================================

String _randomHex(int bytes) {
  final r = math.Random.secure();
  return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String _randomToken() => _randomHex(24);

int _ipRank(String ip) {
  if (ip.startsWith('192.168.')) return 0;
  if (ip.startsWith('10.')) return 1;
  final m = RegExp(r'^172\.(\d+)\.').firstMatch(ip);
  if (m != null) {
    final n = int.tryParse(m.group(1)!) ?? 0;
    if (n >= 16 && n <= 31) return 2;
  }
  return 3;
}

Future<List<String>> _localIps() async {
  final ips = <String>[];
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    for (final i in ifs) {
      for (final a in i.addresses) {
        if (a.address.startsWith('169.254.')) continue;
        ips.add(a.address);
      }
    }
  } catch (_) {}
  ips.sort((a, b) => _ipRank(a).compareTo(_ipRank(b)));
  return ips;
}

class _HttpResult {
  final int status;
  final Map<String, dynamic> body;
  _HttpResult(this.status, this.body);
}

Future<_HttpResult> _postJson(
  String host,
  int port,
  String path,
  Map<String, dynamic> payload, {
  String? token,
  Duration timeout = const Duration(seconds: 4),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.postUrl(Uri(scheme: 'http', host: host, port: port, path: path)).timeout(timeout);
    req.headers.contentType = ContentType.json;
    if (token != null) req.headers.set('x-handoff-token', token);
    req.add(utf8.encode(jsonEncode(payload)));
    final res = await req.close().timeout(timeout * 2);
    final text = await utf8.decodeStream(res).timeout(timeout);
    Map<String, dynamic> body = {};
    try {
      final d = jsonDecode(text);
      if (d is Map<String, dynamic>) body = d;
    } catch (_) {}
    return _HttpResult(res.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

// ==========================================
// MODEL
// ==========================================

class HandoffPeer {
  final String id;
  String name;
  String host;
  int port;

  /// Token WE must present when calling this peer.
  final String outToken;

  /// Token THEY must present when calling us.
  final String inToken;

  HandoffPeer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.outToken,
    required this.inToken,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'out': outToken,
        'in': inToken,
      };

  static HandoffPeer fromJson(Map<String, dynamic> j) => HandoffPeer(
        id: j['id'] as String,
        name: j['name'] as String,
        host: j['host'] as String,
        port: (j['port'] as num).toInt(),
        outToken: j['out'] as String,
        inToken: j['in'] as String,
      );
}

// ==========================================
// CONTROLLER (receiver + pairing + sending)
// ==========================================

class HandoffController extends ChangeNotifier {
  HandoffController._();
  static final HandoffController instance = HandoffController._();

  final DatabaseHelper _db = DatabaseHelper.instance;
  final List<HandoffPeer> _peers = [];
  List<HandoffPeer> get peers => List.unmodifiable(_peers);
  bool get hasPeers => _peers.isNotEmpty;

  String deviceId = '';
  String deviceName = 'Tasky device';

  HttpServer? _server;
  int serverPort = 0;
  bool get serverRunning => _server != null;

  String? _pairCode;
  DateTime? _pairCodeExpiry;

  /// Bumped on every successful pairing (used by the QR dialog to show success).
  int pairEvents = 0;
  String? lastPairedName;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      var id = await _db.getSetting('handoff_device_id');
      if (id == null || id.isEmpty) {
        id = _randomHex(8);
        await _db.saveSetting('handoff_device_id', id);
      }
      deviceId = id;

      String fallbackName = 'Tasky device';
      try {
        fallbackName = Platform.localHostname;
      } catch (_) {}
      deviceName = (await _db.getSetting('handoff_device_name')) ?? fallbackName;

      final raw = await _db.getSetting('handoff_peers');
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        _peers
          ..clear()
          ..addAll(list.map((e) => HandoffPeer.fromJson(e as Map<String, dynamic>)));
      }
    } catch (e) {
      debugPrint('Handoff init (settings) failed: $e');
    }

    await _startServer();
    notifyListeners();
  }

  Future<void> _savePeers() async {
    try {
      await _db.saveSetting('handoff_peers', jsonEncode(_peers.map((p) => p.toJson()).toList()));
    } catch (e) {
      debugPrint('Handoff: saving peers failed: $e');
    }
  }

  Future<void> _addOrReplacePeer(HandoffPeer peer) async {
    _peers.removeWhere((p) => p.id == peer.id);
    _peers.add(peer);
    pairEvents++;
    lastPairedName = peer.name;
    await _savePeers();
    notifyListeners();
  }

  Future<void> removePeer(String id) async {
    _peers.removeWhere((p) => p.id == id);
    await _savePeers();
    notifyListeners();
  }

  // ---------------- receiver ----------------

  Future<void> _startServer() async {
    for (var port = kHandoffBasePort; port < kHandoffBasePort + 10; port++) {
      try {
        final s = await HttpServer.bind(InternetAddress.anyIPv4, port);
        _server = s;
        serverPort = port;
        s.listen(_handle, onError: (Object e) => debugPrint('Handoff server error: $e'));
        debugPrint('Handoff receiver listening on port $port');
        return;
      } catch (_) {}
    }
    debugPrint('Handoff receiver could not bind any port.');
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > 65536) throw const FormatException('Body too large');
    }
    final d = jsonDecode(utf8.decode(bytes));
    if (d is! Map<String, dynamic>) throw const FormatException('Expected JSON object');
    return d;
  }

  Future<void> _reply(HttpRequest req, int status, Map<String, dynamic> body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }

  HandoffPeer? _peerForToken(String? token) {
    if (token == null || token.isEmpty) return null;
    for (final p in _peers) {
      if (p.inToken == token) return p;
    }
    return null;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;

      if (req.method == 'POST' && path == '/pair') {
        await _handlePair(req);
        return;
      }

      final peer = _peerForToken(req.headers.value('x-handoff-token'));
      if (peer == null) {
        await _reply(req, 401, {'error': 'unauthorized'});
        return;
      }

      // Self-heal if the peer's IP changed since pairing.
      final remote = req.connectionInfo?.remoteAddress.address;
      if (remote != null && remote != peer.host) {
        peer.host = remote;
        unawaited(_savePeers());
      }

      if (req.method == 'GET' && path == '/ping') {
        await _reply(req, 200, {'ok': true, 'name': deviceName});
      } else if (req.method == 'POST' && path == '/add') {
        await _handleAdd(req, peer);
      } else {
        await _reply(req, 404, {'error': 'not_found'});
      }
    } catch (e) {
      try {
        await _reply(req, 400, {'error': '$e'});
      } catch (_) {}
    }
  }

  Future<void> _handlePair(HttpRequest req) async {
    final j = await _readJson(req);
    final valid = _pairCode != null &&
        _pairCodeExpiry != null &&
        DateTime.now().isBefore(_pairCodeExpiry!) &&
        j['code'] == _pairCode;
    if (!valid) {
      await _reply(req, 403, {'error': 'invalid_or_expired_code'});
      return;
    }
    // One-time code.
    _pairCode = null;
    _pairCodeExpiry = null;

    final host = req.connectionInfo?.remoteAddress.address;
    if (host == null) {
      await _reply(req, 400, {'error': 'no_remote_address'});
      return;
    }

    final tokenForPeer = _randomToken();
    final peer = HandoffPeer(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? 'Device',
      host: host,
      port: (j['port'] as num?)?.toInt() ?? 0,
      outToken: j['token'] as String,
      inToken: tokenForPeer,
    );
    await _addOrReplacePeer(peer);
    await _reply(req, 200, {'id': deviceId, 'name': deviceName, 'token': tokenForPeer});
  }

  Future<void> _handleAdd(HttpRequest req, HandoffPeer peer) async {
    final j = await _readJson(req);
    final url = (j['url'] as String?)?.trim() ?? '';
    final lower = url.toLowerCase();
    if (!(lower.startsWith('http://') || lower.startsWith('https://') || lower.startsWith('magnet:?'))) {
      await _reply(req, 400, {'error': 'unsupported_url'});
      return;
    }
    final fileName = (j['fileName'] as String?) ?? '';
    final headers = (j['headers'] as Map?)?.map((k, v) => MapEntry('$k', '$v'));
    final referer = j['referer'] as String?;

    // Answer right away; metadata fetching can be slow.
    await _reply(req, 200, {'ok': true});

    unawaited(downloadManager
        .addDownload(url, fileName, headers: headers, referer: referer)
        .catchError((Object e) => debugPrint('Handoff addDownload failed: $e')));

    try {
      await NotificationService.show(
        9000 + math.Random().nextInt(900),
        'Link received from ${peer.name}',
        fileName.isNotEmpty ? fileName : url,
        isLowPriority: true,
      );
    } catch (_) {}
  }

  // ---------------- pairing ----------------

  /// Builds the text that goes inside the QR code. Valid for 5 minutes, one use.
  Future<String> createPairingPayload() async {
    _pairCode = _randomHex(12);
    _pairCodeExpiry = DateTime.now().add(const Duration(minutes: 5));
    return jsonEncode({
      't': 'tasky-handoff',
      'v': 1,
      'name': deviceName,
      'hosts': await _localIps(),
      'port': serverPort,
      'code': _pairCode,
    });
  }

  /// Called on the device that SCANNED the QR. Returns an error message or null.
  Future<String?> pairFromQr(String raw) async {
    Map<String, dynamic> j;
    try {
      final d = jsonDecode(raw);
      if (d is! Map<String, dynamic> || d['t'] != 'tasky-handoff') throw const FormatException();
      j = d;
    } catch (_) {
      return 'That QR code is not a Tasky pairing code.';
    }

    final hosts = ((j['hosts'] as List?) ?? const []).map((e) => '$e').toList();
    final port = (j['port'] as num?)?.toInt() ?? 0;
    final code = j['code'] as String? ?? '';
    if (hosts.isEmpty || port <= 0 || code.isEmpty) {
      return 'The other device is not ready to pair (no network address).';
    }

    final myInToken = _randomToken();

    for (final host in hosts) {
      try {
        final res = await _postJson(host, port, '/pair', {
          'code': code,
          'id': deviceId,
          'name': deviceName,
          'port': serverPort,
          'token': myInToken,
        });
        if (res.status == 200) {
          final peer = HandoffPeer(
            id: res.body['id'] as String,
            name: (res.body['name'] as String?) ?? (j['name'] as String? ?? 'Device'),
            host: host,
            port: port,
            outToken: res.body['token'] as String,
            inToken: myInToken,
          );
          await _addOrReplacePeer(peer);
          return null;
        }
        if (res.status == 403) {
          return 'The pairing code expired. Show a fresh QR on the other device and try again.';
        }
      } catch (_) {
        // Try the next address.
      }
    }
    return 'Could not reach the other device. Make sure both are on the same Wi-Fi '
        'and the PC firewall allows the app on private networks.';
  }

  // ---------------- sending ----------------

  /// Returns an error message or null on success.
  Future<String?> sendLink(
    HandoffPeer peer,
    String url,
    String fileName, {
    Map<String, String>? headers,
    String? referer,
  }) async {
    if (peer.port <= 0) return '${peer.name} cannot receive links (its receiver is not running).';
    try {
      final res = await _postJson(
        peer.host,
        peer.port,
        '/add',
        {
          'url': url,
          'fileName': fileName,
          if (headers != null && headers.isNotEmpty) 'headers': headers,
          if (referer != null && referer.isNotEmpty) 'referer': referer,
        },
        token: peer.outToken,
        timeout: const Duration(seconds: 5),
      );
      if (res.status == 200) return null;
      if (res.status == 401 || res.status == 403) {
        return 'Pairing is no longer valid. Remove the device and pair again.';
      }
      return '${peer.name} replied with error ${res.status}.';
    } on TimeoutException {
      return 'Could not reach ${peer.name}. Are both devices on the same Wi-Fi and is the app open there?';
    } on SocketException {
      return 'Could not reach ${peer.name}. Are both devices on the same Wi-Fi and is the app open there?';
    } catch (e) {
      return 'Send failed: $e';
    }
  }
}

// ==========================================
// ACTIONS (what main.dart calls)
// ==========================================

class HandoffActions {
  HandoffActions._();

  /// Feature is available on every platform (unpaired -> offers to pair).
  static bool get available => true;

  static bool get canScan => true; // Always allow scanning

  static String get label => 'Send to Device'; // Generic label

  static Future<void> send(
    BuildContext context, {
    required String url,
    required String fileName,
    Map<String, String>? headers,
    String? referer,
  }) async {
    final c = HandoffController.instance;
    final messenger = ScaffoldMessenger.of(context);

    if (c.peers.isEmpty) {
      final pair = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No device paired'),
          content: const Text('Pair your phone and PC once with a QR code, then you can send links between them.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pair now')),
          ],
        ),
      );
      if (pair == true && context.mounted) {
        await pairNow(context);
      }
      return;
    }

    HandoffPeer? peer;
    if (c.peers.length == 1) {
      peer = c.peers.first;
    } else {
      peer = await showDialog<HandoffPeer>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Send to...'),
          children: [
            for (final p in c.peers)
              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, p), child: Text(p.name)),
          ],
        ),
      );
    }
    if (peer == null) return;

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('Sending to ${peer.name}...'), duration: const Duration(seconds: 2)));

    final err = await c.sendLink(peer, url, fileName, headers: headers, referer: referer);

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(err ?? 'Sent to ${peer.name}'),
      backgroundColor: err == null ? null : Colors.red,
    ));
  }

  static Future<void> pairNow(BuildContext context) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Pair a device'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'scan'), child: const Text('Scan a QR code')),
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'show'), child: const Text('Show my QR code')),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'scan') {
      await scanAndPair(context);
    } else {
      await showDialog(context: context, builder: (_) => const HandoffQrDialog());
    }
  }

  static Future<void> scanAndPair(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final raw = await navigator.push<String>(MaterialPageRoute(builder: (_) => const HandoffScanPage()));
    if (raw == null || !context.mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 16),
            Expanded(child: Text('Pairing...')),
          ],
        ),
      ),
    );

    final err = await HandoffController.instance.pairFromQr(raw);
    navigator.pop(); // close the progress dialog

    final name = HandoffController.instance.lastPairedName ?? 'device';
    messenger.showSnackBar(SnackBar(
      content: Text(err ?? 'Paired with $name'),
      backgroundColor: err == null ? null : Colors.red,
    ));
  }
}

/// Used by main.dart: context-menu entries for cards.
List<PopupMenuEntry<String>> handoffMenuEntries() {
  if (!HandoffActions.available) return <PopupMenuEntry<String>>[];
  return <PopupMenuEntry<String>>[
    PopupMenuItem<String>(
      value: 'send_to_pc',
      child: ListTile(
        leading: const Icon(Icons.devices),
        title: Text(HandoffActions.label),
      ),
    ),
  ];
}

/// Used by main.dart: called after the context menu returns 'send_to_pc'.
void handoffSendTask(BuildContext context, DownloadTask task) {
  unawaited(HandoffActions.send(
    context,
    url: task.url,
    fileName: task.fileName,
    headers: task.customHeaders,
    referer: task.referer,
  ));
}

// ==========================================
// WIDGETS
// ==========================================

/// Button for the "Add Download" dialog.
class SendToPcButton extends StatelessWidget {
  final String Function() url;
  final String Function() fileName;

  const SendToPcButton({super.key, required this.url, required this.fileName});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.devices, size: 18),
      label: Text(HandoffActions.label),
      onPressed: () => HandoffActions.send(context, url: url(), fileName: fileName()),
    );
  }
}

/// Section inside the Settings dialog.
class HandoffSettingsSection extends StatelessWidget {
  const HandoffSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = HandoffController.instance;
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 4),
              child: Text('Device Handoff (QR)', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            Text(
              'Pair your phone and PC once with a QR code, then send links between them over the same Wi-Fi.',
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
            const SizedBox(height: 8),
            if (c.peers.isEmpty)
              Text('No paired devices yet.', style: TextStyle(fontSize: 13, color: theme.hintColor))
            else
              for (final p in c.peers)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices),
                  title: Text(p.name),
                  subtitle: Text('${p.host}:${p.port}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    tooltip: 'Unpair',
                    onPressed: () => c.removePeer(p.id),
                  ),
                ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.qr_code, size: 18),
                  label: const Text('Show pairing QR'),
                  onPressed: () => showDialog(context: context, builder: (_) => const HandoffQrDialog()),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: const Text('Scan QR'),
                  onPressed: () => HandoffActions.scanAndPair(context),
                ),
              ],
            ),
            if (!c.serverRunning)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Receiver could not start (ports $kHandoffBasePort-${kHandoffBasePort + 9} busy). '
                  'This device can send but not receive.',
                  style: const TextStyle(fontSize: 12, color: Colors.red),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Dialog that shows the pairing QR.
class HandoffQrDialog extends StatefulWidget {
  const HandoffQrDialog({super.key});

  @override
  State<HandoffQrDialog> createState() => _HandoffQrDialogState();
}

class _HandoffQrDialogState extends State<HandoffQrDialog> {
  late Future<String> _payload;
  late final int _startEvents;

  @override
  void initState() {
    super.initState();
    _startEvents = HandoffController.instance.pairEvents;
    _payload = HandoffController.instance.createPairingPayload();
  }

  void _refresh() {
    setState(() {
      _payload = HandoffController.instance.createPairingPayload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = HandoffController.instance;

    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final paired = c.pairEvents > _startEvents;

        return AlertDialog(
          title: const Text('Pair a device'),
          content: SizedBox(
            width: 300,
            child: paired
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green, size: 64),
                      const SizedBox(height: 12),
                      Text('Paired with ${c.lastPairedName ?? 'device'}', textAlign: TextAlign.center),
                    ],
                  )
                : !c.serverRunning
                    ? const Text('The receiver could not start on this device, so it cannot be paired by QR.')
                    : FutureBuilder<String>(
                        future: _payload,
                        builder: (context, snap) {
                          if (!snap.hasData) {
                            return const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()));
                          }
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                color: Colors.white,
                                padding: const EdgeInsets.all(12),
                                child: QrImageView(data: snap.data!, size: 240, backgroundColor: Colors.white),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'On the other device open Settings > Device Handoff > Scan QR.\nValid for 5 minutes, one use.',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                              ),
                            ],
                          );
                        },
                      ),
          ),
          actions: [
            if (!paired && c.serverRunning) TextButton(onPressed: _refresh, child: const Text('New code')),
            TextButton(onPressed: () => Navigator.pop(context), child: Text(paired ? 'Done' : 'Close')),
          ],
        );
      },
    );
  }
}

/// Full-screen camera page that returns the scanned text.
class HandoffScanPage extends StatefulWidget {
  const HandoffScanPage({super.key});

  @override
  State<HandoffScanPage> createState() => _HandoffScanPageState();
}

class _HandoffScanPageState extends State<HandoffScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing QR')),
      body: SimpleBarcodeScanner(
        onBarcodeViewCreated: (controller) {},
        onScanned: (res) {
          if (_done) return;
          // simple_barcode_scanner returns '-1' when the user cancels or closes it
          if (res.isNotEmpty && res != '-1') {
            _done = true;
            Navigator.pop(context, res);
          }
        },
      ),
    );
  }
}