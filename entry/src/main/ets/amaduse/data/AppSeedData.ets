import {
  ChatRecord,
  ModelProviderPreset,
  ToolShortcut,
} from '../model/AppModels';

export const modelProviderPresets: ModelProviderPreset[] = [
  {
    name: '演示模型',
    baseUrl: 'local://demo',
    defaultModel: 'amaduse-demo-stream',
    compatible: false,
    note: '无需 Key，本地生成流式演示回复',
  },
  {
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4.1-mini',
    compatible: true,
    note: 'Chat Completions 兼容流式接口',
  },
  {
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'openai/gpt-4.1-mini',
    compatible: true,
    note: '聚合多家模型，使用 OpenAI-compatible 协议',
  },
  {
    name: '小米 MiMo',
    baseUrl: 'https://api.xiaomimimo.com/v1',
    defaultModel: 'mimo-v2.5-pro',
    compatible: true,
    note: 'MiMo OpenAI-compatible 接口，快速模式关闭 thinking，思考模式开启 thinking',
  },
  {
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
    compatible: true,
    note: '可切换 deepseek-reasoner 获取 reasoning_content',
  },
  {
    name: '通义千问',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
    compatible: true,
    note: 'DashScope 兼容模式',
  },
  {
    name: 'Kimi',
    baseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'moonshot-v1-8k',
    compatible: true,
    note: 'Moonshot OpenAI-compatible 接口',
  },
  {
    name: '智谱 GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4-flash',
    compatible: true,
    note: 'BigModel 兼容接口',
  },
  {
    name: 'Ollama',
    baseUrl: 'http://127.0.0.1:11434/v1',
    defaultModel: 'qwen2.5:7b',
    compatible: true,
    note: '鸿蒙设备访问本机服务时请改成局域网 IP',
  },
  {
    name: 'Anthropic',
    baseUrl: 'https://api.anthropic.com/v1',
    defaultModel: 'claude-3-5-haiku-latest',
    compatible: false,
    note: '已提供配置项，专用协议后续接入',
  },
  {
    name: 'Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    defaultModel: 'gemini-2.5-flash',
    compatible: false,
    note: '已提供配置项，专用协议后续接入',
  },
  {
    name: '自定义',
    baseUrl: 'https://example.com/v1',
    defaultModel: 'custom-model',
    compatible: true,
    note: '填写任意 OpenAI-compatible 服务',
  },
];

export const toolShortcuts: ToolShortcut[] = [
  { title: '相机', subtitle: '拍照提问', icon: '□' },
  { title: '图片', subtitle: '上传视觉上下文', icon: '▧' },
  { title: '文件', subtitle: '附加资料', icon: '≡' },
  { title: '闹钟', subtitle: '创建提醒', icon: '◷' },
  { title: '备忘', subtitle: '创建日历任务', icon: '▤' },
  { title: '电脑', subtitle: '发送 PC 任务', icon: '⌘' },
];

export const seedChatRecords: ChatRecord[] = [
  { id: 'seed-layout', title: 'Amaduse 前端布局', subtitle: '当前会话 · 模型和思考模式调试', active: true },
  { id: 'seed-ll1', title: 'LL(1) 文法介绍', subtitle: '编译原理笔记', active: false },
  { id: 'seed-cursor', title: 'Cursor 配置 DeepSeek API', subtitle: 'OpenAI-compatible 设置', active: false },
  { id: 'seed-vpn', title: 'VPN 访问国内加速', subtitle: '网络配置排查', active: false },
  { id: 'seed-mcp', title: 'Codex MCP 配置推荐', subtitle: '工具链与插件', active: false },
  { id: 'seed-greeting', title: 'Greeting Exchange', subtitle: '英语对话练习', active: false },
  { id: 'seed-mimo', title: 'Claude Code 小米 MiMo 配置问题', subtitle: '模型服务兼容', active: false },
  { id: 'seed-powershell', title: 'Windows 下载命令错误', subtitle: 'PowerShell 故障分析', active: false },
  { id: 'seed-plugin', title: 'OpenCode 卸载插件方法', subtitle: 'CLI 维护', active: false },
  { id: 'seed-research', title: '轻量实验选题建议', subtitle: '研究方向整理', active: false },
  { id: 'seed-runfail', title: '程序运行失败原因分析', subtitle: '日志和堆栈定位', active: false },
  { id: 'seed-plus', title: 'GPT Plus 使用限制', subtitle: '订阅和额度', active: false },
];

export function providerByName(name: string): ModelProviderPreset {
  const found = modelProviderPresets.find((item: ModelProviderPreset) => item.name === name);
  if (found !== undefined) {
    return found;
  }
  const custom = modelProviderPresets.find((item: ModelProviderPreset) => item.name === '自定义');
  return custom as ModelProviderPreset;
}

export function defaultModelProvider(): ModelProviderPreset {
  const provider = modelProviderPresets.find((item: ModelProviderPreset) => item.name === 'OpenAI');
  return provider as ModelProviderPreset;
}
