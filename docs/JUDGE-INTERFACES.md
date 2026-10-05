# 可选核对接口

「模型设置」把生成模型和核对模型分开。抽取、人物小传、问答继续使用上方生成模型。新安装仍默认使用原来的免费判断接口。

核对方式可选：

- **免费判断接口**：保留现有 classifier.dev 设置及用户可选的模型备用路线。
- **System One 兼容接口**：填写完整的判断接口地址、可选模型名、可选 API 密钥。未指定模型时使用服务默认模型；未填地址时使用生成接口地址加 `/systemone`。
- **System Two 对话模型**：通过上方选择的 OpenAI / Gemini / Claude 兼容协议回答判断题。地址、模型、密钥可以单独填写，留空的项使用生成模型设置。这里的地址是协议的基础地址，例如 OpenAI 兼容服务的 `https://host/v1`。

核对密钥保存在本机私有设置中。未单独填写时使用生成接口密钥。书库 ZIP 仅保留地址、模型和核对方式，排除密钥。

「测试并保存」先检查生成接口，再给核对接口一条短判断题。只有返回完整、有效的选项和概率后才保存。测试检查兼容性；它不代表判断准确率。

## System One 请求和响应

地址由用户指定，不限定模型、厂商、模型版本或主机。使用 HTTP POST、JSON 和可选的 `Authorization: Bearer <key>`。

```json
{
  "state": "林舟是灯塔管理员。",
  "model": "user-selected-model",
  "questions": {
    "check": {
      "type": "choice",
      "instructions": "Does the passage support that 林舟 is the lighthouse keeper?",
      "criteria": {"yes": "Supported", "no": "Not supported"}
    }
  }
}
```

`model` 未填写时省略。`state` 可以是字符串或 JSON 数据。服务必须回答所有问题，并提供每个选项的概率。

```json
{
  "answers": {
    "check": {
      "type": "choice",
      "choice": "yes",
      "probabilities": {"yes": 0.95, "no": 0.05}
    }
  }
}
```

响应里的 `model`、`revision` 等服务信息均为可选，不作为兼容要求。概率必须是 0 到 1 的有限数字，覆盖全部选项，合计接近 1。格式不完整时保留进度并报错，不自动改用另一家模型。

System Two 使用同一套选项和概率要求，由现有对话适配器生成请求，并保留已有的有限修正重试及每本书额度。

已有的单书核对选择优先于全局设置。要让某本书使用新的全局接口，先在书籍详情停用该书的单独核对选择。
