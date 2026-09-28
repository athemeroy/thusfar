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
  return _outcome.hasMatch(title);
}

// Without a verdict each title is judged on its own words. The cues name an
// outcome that has happened — a death, a killing, a capture or defeat, a
// betrayal or unmasking, a marriage or pregnancy, a return from the dead or
// the ending — in simplified and traditional Chinese, including the classical
// euphemisms of chaptered novels (「苦绛珠魂归离恨天」). A title that only names
// a place, a person, a scene or a threat stays visible (「死亡沙海」, 「置之死地」,
// 「刺杀」). English cues avoid words that are common in other languages, so
// German 「Die …」 titles stay visible.
final RegExp _outcome = RegExp(
  // death
  r'身亡|死去|之死(?!地)|[仙夭薨自病长長]逝|夭|薨|捐[馆館]|[亲親理治发發奔][丧喪]|'
  r'寿终|壽終|[归歸]地府|赴冥|登太[虚虛]|返真元|殉|自焚|吞金|吞生金|投井|上吊|'
  r'[惨慘战戰病身]死|病故|去世|殒命|殞命|陨命|隕命|陨落|隕落|丧命|喪命|毙命|斃命|'
  r'遇害|自尽|自盡|自刎|自[杀殺]|魂[归歸]|咽气|嚥氣|气绝|氣絕|[归歸]西|撒手人寰|'
  r'香消玉[殒殞]|一命[呜嗚]呼|命[丧喪]|[处處赐賜]死|[处處]斩|[处處]斬|斩首|斬首|'
  r'伏[诛誅]|同[归歸][于於][尽盡]|死[里裡]逃生|不死之身|'
  // a killing or destruction that has happened
  r'被[杀殺害]|[杀殺]死|[斩斬镇鎮击擊诛誅格反][杀殺]|[灭滅]口|[灭滅][门門]|'
  r'全[灭滅]|覆[灭滅]|[灭滅]亡|'
  // capture, ruin, surrender, victory and defeat
  r'查抄|抄家|抄[没沒]|被[擒俘捕抓]|落[网網]|入[狱獄]|就擒|投降|[归歸]降|'
  r'[败敗]亡|兵[败敗]|[惨慘]败|[惨慘]敗|大[败敗]|[败敗]北|[获獲][胜勝]|完[胜勝]|'
  r'[夺奪]冠|[两兩][败敗]俱[伤傷]|'
  // betrayal and identity reveals
  r'背叛|叛[变變]|出[卖賣]|叛徒|[内內]奸|反水|倒戈|[揭拆]穿|[识識]破|[败敗]露|'
  r'真面目|真[凶兇]|[凶兇]手|幕[后後]黑手|真[实實]身份|身份揭[晓曉]|身份曝光|'
  r'原[来來]是|竟然是|居然是|竟是|[谁誰]是|'
  // marriage, pregnancy and birth
  r'成大[礼禮]|[偷悔误誤远遠改再]嫁|[偷悔强強续續再]娶|成婚|成[亲親]|完婚|大婚|'
  r'[结結]婚|[订訂]婚|定[亲親]|出嫁|嫁[给給与與]|娶了|迎娶|洞房|[怀懷]孕|身孕|'
  r'[产產]子|婚事|'
  // revival, return, reunion and the ending
  r'[复復]活|[归歸][来來]|相[认認]|[团團][圆圓]|[认認][亲親]|大[结結]局|'
  r'最[终終][结結]局|完[结結]篇|'
  r'\b(?:died|killed|murdered|slain|executed|suicide|funeral|wedding|married|'
  r'marries|betrothed|unmasked|betray(?:s|ed|al)|traitor|captured|arrested|'
  r'rescued|victory|defeated|revealed|revived|killer|finale|death of)\b',
  caseSensitive: false,
);
