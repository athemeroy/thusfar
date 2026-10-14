/// Fixed generation instructions precede book-specific evidence.
library;

import '../py/py_repr.dart';

class GenerationPrompt {
  const GenerationPrompt(this.system, this.user);

  final String system;
  final String user;

  List<Map<String, String>> messages(
    Map<String, Object?> values, {
    String systemNote = '',
    String extraUser = '',
  }) => [
    {'role': 'system', 'content': system + systemNote},
    {'role': 'user', 'content': _format(user, values) + extraUser},
  ];
}

String _format(String pattern, Map<String, Object?> values) {
  const String open = '\u0001', close = '\u0002';
  final String escaped = pattern.replaceAll('{{', open).replaceAll('}}', close);
  return escaped
      .replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (m) => pyStr(values[m[1]]))
      .replaceAll(open, '{')
      .replaceAll(close, '}');
}

const rewrite = GenerationPrompt(
  "下面这份人物简介由 AI 生成，自动校验认为它可能包含【原文】和【旧简介】都没有交代的内容（可能是编造，也可能是后文才揭示的剧透）。\n请逐句核对，只保留能从【原文】或【旧简介】直接得到支持的内容，重写这份简介。不要补充任何原文之外的信息。\n\n只输出 JSON：{\"tagline\": \"≤18字\", \"bio\": \"60～160字\"}",
  "【旧简介】{old}\n\n【原文】\n{text}\n\n【待核对的简介】\n一句话身份：{tagline}\n简介：{bio}",
);

const chapterRecap = GenerationPrompt(
  "你在为一款防剧透阅读器写章节梗概。\n只能使用下面给出的本章事件，绝不能写入任何后文情节，即使你知道这部作品。\n\n写本章梗概：80～200 字，按情节顺序，具体到人名。只输出梗概正文。",
  "读者刚读完《{title}》的「{chapter}」。\n\n【本章发生的事】（按顺序）\n{events}",
);

const saga = GenerationPrompt(
  "你在为一款防剧透阅读器更新“前情提要”。\n只能使用下面的材料，绝不能写入任何后文情节，即使你知道这部作品。\n\n写截至目前的全书前情提要：300～700 字，融合此前提要与新的各章梗概，详略得当，越近的情节写得越具体。只输出提要正文。",
  "读者已读到《{title}》的「{chapter}」结束。\n\n【此前的前情提要】\n{saga}\n\n【之后各章梗概】\n{recaps}",
);

const recap = GenerationPrompt(
  "你在为一款防剧透阅读器写“前情提要”。\n只能使用下面给出的信息，绝不能写入任何后文情节，即使你知道这部作品。\n\n按下面的格式输出，不要其他内容：\n<recap>本章梗概，80～200字，按情节顺序，具体到人名</recap>\n<saga>截至本章结束的全书前情提要，200～600字，融合此前提要与本章，详略得当，越近的情节写得越具体</saga>",
  "读者刚读完《{title}》的「{chapter}」。\n\n【此前的前情提要】\n{saga}\n\n【本章发生的事】（按顺序）\n{events}\n\n【本章人物动态】\n{profiles}",
);

const relationWords = GenerationPrompt(
  "下面是用户提供的一段原文，以及其中几对同时出场的人物。自动判断认为他们之间**有关系但不属于常见类别**（亲属、婚恋、主仆、师生、朋友、敌对、生意往来都不是）。\n请只根据这段原文，写出每一对的关系；本段看不出关系的，b_is 留空。\n\n只输出 JSON：{\"1\": {\"b_is\": \"B 对 A 而言是什么（≤8字）\", \"a_is\": \"A 对 B 而言是什么（≤8字）\", \"desc\": \"≤20字说明\", \"quote\": \"本段原文里逐字出现的一句支持它的片段\"}}",
  "【作品】《{title}》\n\n【本段原文】\n{text}\n\n【人物对】\n{pairs}",
);

const consolidate = GenerationPrompt(
  "你在为一款防剧透阅读器编写“人物表”。\n只能使用下面给出的资料，不得补写后文、常识推测或人物尚未做的事。\n\n为每个人物写：\n- tagline：一句话身份（≤18字），只写资料已明确的身份或关系。\n- bio：按时间顺序概括有记录的主要经历和关系，通常不超过160字。资料少时允许只写一两句，没有最低字数。\n每句话都必须有资料支持。性格、心理、性别、住处、去向、计划和当前活动，资料没有明确交代就省略。不得从一次行为推断性格，不得把临走前的动作续写为返程或其他活动，也不得把工作记录写成正在发生的事。\n不要求固定写性格或以“目前……”结尾。不要为了凑字数、段落结构或完整故事而补全信息。用姓名代替未知性别的代词。合并重复经历，不罗列无关细节，不评价、不预测。\n\n只输出 JSON：{\"P1\": {\"tagline\": \"...\", \"bio\": \"...\"}, ...}",
  "读者刚读完《{title}》的「{chapter}」。\n\n{dossiers}",
);

const String extractorRevision =
    "2ead2ec689628def6e1b12c657e554008571d3717a2b42ab6fbce98184fc0f55";
