import 'package:crypto/crypto.dart' as crypto;

/// Frozen Python 1.7.5 hashes that depended on Python source bytes.
final class LegacyHashes {
  const LegacyHashes._();

  /// SHA-256 of `pipeline/local.py` in the frozen 1.7.5 oracle.
  static const String extractorRevision =
      '2ead2ec689628def6e1b12c657e554008571d3717a2b42ab6fbce98184fc0f55';
}

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();
