/// Reader-facing errors. Original details remain in the exported diagnostics.
String processingErrorMessage(String? detail) {
  final String text = detail ?? '';
  if (text.contains('判断回答不完整') ||
      text.contains('概率无效') ||
      text.contains('核对失败') ||
      text.contains('裁判缓存')) {
    return '检查模型没有给出可用的答案。进度已保留，可以再试一次；若反复出现，请在模型设置中更换检查模型。';
  }
  if (text.contains('请求结果') || text.contains('没有收到完整结果')) {
    return '没有收到完整结果，已完成的内容已保留。可以点“继续整理”再试。';
  }
  if (text.contains('HandshakeException') ||
      text.contains('SocketException') ||
      text.contains('HttpException') ||
      text.contains('连接') ||
      text.contains('网络')) {
    return '暂时连不上 AI 服务。进度已保留，请确认网络和 AI 服务可用后再试。';
  }
  if (text.contains('Timeout') || text.contains('超时')) {
    return 'AI 服务暂时没有回复。进度已保留，可以稍后再试。';
  }
  if (text.contains('401') || text.contains('密钥')) {
    return 'AI 服务密钥无法使用，请到模型设置中重新填写并测试。';
  }
  if (text.contains('402') || text.contains('余额')) {
    return 'AI 服务账户余额不足，请检查该服务的账户。';
  }
  if (text.contains('403') || text.contains('拒绝访问')) {
    return 'AI 服务拒绝了连接，请到模型设置中检查地址和密钥。';
  }
  if (text.contains('404') ||
      text.contains('NOT_API') ||
      text.contains('模型名')) {
    return 'AI 服务地址或模型名称有误，请到模型设置中检查并测试。';
  }
  if (text.contains('429')) return 'AI 服务正忙，请稍后再试。进度已保留。';
  if (text.contains('THINKING_ONLY') || text.contains('空内容')) {
    return 'AI 没有给出正文。可以再试一次，或在模型设置中更换模型。';
  }
  if (text.contains('存储') || text.contains('No space')) {
    return '无法保存整理结果，请检查手机剩余空间。';
  }
  return '这一步没有完成，已完成的内容已保留。可以再试一次；若反复出现，请导出问题记录以便排查。';
}
