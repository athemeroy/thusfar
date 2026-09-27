import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

final Uri _latestReleaseApi = Uri.https(
  'api.github.com',
  '/repos/athemeroy/thusfar/releases/latest',
);
const Duration _networkTimeout = Duration(seconds: 6);
final RegExp _installedVersionPattern = RegExp(
  r'^v?(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?(?:\+\d+|\s|$)',
);
final RegExp _stableTagPattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$');

class ReleaseUpdate {
  const ReleaseUpdate(this.tag);

  final String tag;
  Uri get page =>
      Uri.https('github.com', '/athemeroy/thusfar/releases/tag/$tag');
}

/// Android reports the package version through the native bridge. Desktop and
/// iOS release builds provide it through THUSFAR_VERSION at build time.
Future<String?> installedAppVersion() async {
  const String built = String.fromEnvironment('THUSFAR_VERSION');
  if (built.isNotEmpty) return built;
  if (!Platform.isAndroid) return null;
  try {
    return await const MethodChannel(
      'thusfar/paths',
    ).invokeMethod<String>('appVersion');
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// GitHub's latest-release endpoint excludes drafts and prereleases. Compare
/// the stable tag with the installed version, not the Android build number.
bool isNewerStableRelease(String installed, String tag) {
  final Match? current = _installedVersionPattern.firstMatch(installed.trim());
  final Match? latest = _stableTagPattern.firstMatch(tag.trim());
  if (current == null || latest == null) return false;
  for (int i = 1; i <= 3; i++) {
    final int local = int.parse(current.group(i)!);
    final int remote = int.parse(latest.group(i)!);
    if (remote != local) return remote > local;
  }
  return current.group(4) != null;
}

Future<ReleaseUpdate?> checkForUpdate(String installed) async {
  final HttpClient client = HttpClient()..connectionTimeout = _networkTimeout;
  try {
    final HttpClientRequest request = await client
        .getUrl(_latestReleaseApi)
        .timeout(_networkTimeout);
    request.headers
      ..set(HttpHeaders.userAgentHeader, 'Thusfar/2.0')
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set('X-GitHub-Api-Version', '2022-11-28');
    final HttpClientResponse response = await request.close().timeout(
      _networkTimeout,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('GitHub release request: ${response.statusCode}');
    }
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in response.timeout(_networkTimeout)) {
      if (bytes.length + chunk.length > 128 * 1024) {
        throw const FormatException('GitHub release response too large');
      }
      bytes.addAll(chunk);
    }
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded['draft'] == true ||
        decoded['prerelease'] == true ||
        decoded['tag_name'] is! String) {
      throw const FormatException('GitHub release response incomplete');
    }
    final String tag = decoded['tag_name'] as String;
    if (!isNewerStableRelease(installed, tag)) return null;
    return ReleaseUpdate(tag);
  } finally {
    client.close(force: true);
  }
}
