/// Whether an unread chapter title should be concealed.
///
/// A model verdict takes precedence. Older interrupted title checks wrote
/// `spoil: true` for every unclassified chapter; while that check is pending,
/// those legacy values need the same local fallback as an absent verdict.
bool titleSpoils(
  Object? verdict,
  String title, {
  bool checkPending = false,
  bool checkedByModel = false,
}) {
  if (verdict == false) return false;
  if (verdict == true && (!checkPending || checkedByModel)) return true;

  // These are deliberately narrow cues. A title without a verdict stays
  // visible unless it strongly implies a future outcome or identity reveal.
  return RegExp(
    r'(?:身亡|死去|死亡|被杀|被害|陨落|复活|凶手|真凶|幕后黑手|叛徒|身份揭晓|真实身份|原来是|竟然是|居然是|谁是|谁获胜|大结局|最终结局|完结篇|成婚|怀孕|嫁给|娶了|灭亡|覆灭|陨命|归来|\b(?:dies?|killed|murdered|revived|killer|traitor|identity revealed|the ending|finale)\b)',
    caseSensitive: false,
  ).hasMatch(title);
}
