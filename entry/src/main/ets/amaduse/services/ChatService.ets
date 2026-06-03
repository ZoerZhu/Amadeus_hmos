import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import {
  ChatMessage,
  ChatMode,
  ModelSettings,
  PersonaPreset,
} from '../model/AppModels';
import {
  PersonaPromptBuilder,
  PromptRuntimeContext,
} from '../persona/PersonaPromptBuilder';
import {
  cleanDisplayText,
  cleanStreamChunk,
  currentPromptTimeText,
} from './AppUtils';
import {
  AgentToolCall,
  AgentToolCallbacks,
  AgentToolDefinition,
  AgentToolResult,
  createAgentToolCall,
  createAgentToolDefinitions,
  createFallbackAgentToolCall,
  isSupportedAgentTool,
} from '../tools/AgentTools';

export interface AssistantReply {
  text: string;
  thinking: string;
  error: string;
}

interface ChatCompletionModeConfig {
  providerName: string;
  providerBaseUrl: string;
  baseUrl: string;
  model: string;
  defaultModel: string;
}

interface ThinkingPayload {
  type: string;
}

interface ReasoningPayload {
  effort: string;
  exclude: boolean;
}

interface ChatPayload {
  model: string;
  stream: boolean;
  messages: ChatCompletionMessage[];
  tools?: AgentToolDefinition[];
  tool_choice?: string;
  thinking?: ThinkingPayload;
  top_p?: number;
  temperature?: number;
  max_completion_tokens?: number;
  reasoning?: ReasoningPayload;
  max_tokens?: number;
  enable_thinking?: boolean;
  thinking_budget?: number;
  reasoning_effort?: string;
}

interface HttpHeaderMap {
  'Content-Type': string;
  'Accept': string;
  'Authorization'?: string;
}

interface ChatCompletionToolFunction {
  name?: string;
  arguments?: string;
}

interface ChatCompletionToolCall {
  id?: string;
  type?: string;
  function?: ChatCompletionToolFunction;
}

interface ChatCompletionMessage {
  role: string;
  content: string;
  tool_calls?: ChatCompletionToolCall[];
  tool_call_id?: string;
  name?: string;
}

interface ChatCompletionResponseMessage {
  content?: string;
  reasoning_content?: string;
  reasoning?: string;
  tool_calls?: ChatCompletionToolCall[];
}

interface ChatCompletionChoice {
  message: ChatCompletionResponseMessage;
}

interface ChatCompletionResponse {
  choices: ChatCompletionChoice[];
}

interface ChatCompletionStreamChoice {
  delta?: ChatCompletionResponseMessage;
  message?: ChatCompletionResponseMessage;
}

interface ChatCompletionStreamError {
  message?: string;
}

interface ChatCompletionStreamChunk {
  choices?: ChatCompletionStreamChoice[];
  error?: ChatCompletionStreamError;
}

interface StreamDelta {
  text: string;
  thinking: string;
  error: string;
}

interface HttpTextResponse {
  code: number;
  body: string;
}

interface ToolDecision {
  text: string;
  thinking: string;
  error: string;
  message: ChatCompletionResponseMessage;
  toolCalls: AgentToolCall[];
}

export class ChatService {
  static async requestAssistantMessage(
    history: ChatMessage[],
    userText: string,
    persona: PersonaPreset,
    mode: ChatMode,
    settings: ModelSettings,
  ): Promise<AssistantReply> {
    if (looksLikeLocalToolRequest(userText) && (!settings.useRemote || settings.apiKey.length === 0)) {
      return {
        text: '[emotion:neutral]\n我识别到这是一个工具请求。鸿蒙迁移版已经保留了工具入口和参数收集逻辑，但系统闹钟、日历、文件创建、语音播报这些平台级执行还需要继续接入 HarmonyOS 对应 API。先把目标、时间和内容说完整，我会按同样的流程整理参数。',
        thinking: '',
        error: '',
      };
    }

    if (!settings.useRemote) {
      return ChatService.demoReply(userText, mode);
    }
    if (!settings.provider.compatible) {
      return {
        text: '',
        thinking: '',
        error: `${settings.provider.name} 当前只提供配置界面，专用协议尚未接入。`,
      };
    }
    if (settings.apiKey.length === 0 && settings.provider.name.toLowerCase() !== 'ollama') {
      return {
        text: '',
        thinking: '',
        error: '远程 API 需要先在设置中填写 API Key。',
      };
    }

    const base = trimEnd(settings.baseUrl.trim(), '/');
    const endpoint = `${base}/chat/completions`;
    const payload = ChatService.buildPayload(settings, persona, mode, history);
    const request = http.createHttp();
    try {
      const headers: HttpHeaderMap = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      if (settings.apiKey.length > 0) {
        headers.Authorization = `Bearer ${settings.apiKey}`;
      }
      const response = await request.request(endpoint, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(payload),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 60000,
      });
      const code = response.responseCode;
      const body = responseBodyToString(response.result, response.resultType);
      if (code < 200 || code > 299) {
        return { text: '', thinking: '', error: `HTTP ${code} ${body.substring(0, 220)}` };
      }
      return ChatService.parseCompletionResponse(body, mode);
    } catch (error) {
      return {
        text: '',
        thinking: '',
        error: errorToString(error),
      };
    } finally {
      request.destroy();
    }
  }

  static async streamAssistantMessage(
    history: ChatMessage[],
    userText: string,
    persona: PersonaPreset,
    mode: ChatMode,
    settings: ModelSettings,
    onThinkingDelta: (delta: string) => void,
    onTextDelta: (delta: string) => void,
    toolCallbacks?: AgentToolCallbacks,
  ): Promise<AssistantReply> {
    if (toolCallbacks !== undefined && looksLikeAgentToolRequest(userText) &&
      (!settings.useRemote || (settings.apiKey.length === 0 && settings.provider.name.toLowerCase() !== 'ollama'))) {
      const fallback = createFallbackAgentToolCall(userText);
      if (fallback !== undefined) {
        return ChatService.runFallbackToolCall(fallback, mode, toolCallbacks);
      }
    }

    if (!settings.useRemote) {
      return ChatService.demoReply(userText, mode);
    }
    if (!settings.provider.compatible) {
      return {
        text: '',
        thinking: '',
        error: `${settings.provider.name} 当前只提供配置界面，专用协议尚未接入。`,
      };
    }
    if (settings.apiKey.length === 0 && settings.provider.name.toLowerCase() !== 'ollama') {
      return {
        text: '',
        thinking: '',
        error: '远程 API 需要先在设置中填写 API Key。',
      };
    }

    const base = trimEnd(settings.baseUrl.trim(), '/');
    const endpoint = `${base}/chat/completions`;
    const toolReply = await ChatService.tryRunAgentToolRound(
      endpoint,
      history,
      userText,
      persona,
      mode,
      settings,
      onThinkingDelta,
      onTextDelta,
      toolCallbacks,
    );
    if (toolReply !== undefined) {
      return toolReply;
    }

    const payload = ChatService.buildPayload(settings, persona, mode, history);
    payload.stream = true;
    return ChatService.streamPayload(endpoint, payload, settings, mode, onThinkingDelta, onTextDelta);
  }

  private static async runFallbackToolCall(
    call: AgentToolCall,
    mode: ChatMode,
    toolCallbacks: AgentToolCallbacks,
  ): Promise<AssistantReply> {
    toolCallbacks.onToolCallStart(call);
    const result = await toolCallbacks.executeTool(call);
    toolCallbacks.onToolCallFinish(result);
    return {
      text: `[emotion:neutral]\n${result.summary}`,
      thinking: mode === ChatMode.Thinking ? '本地工具兜底：当前没有可用远程模型，因此用前端关键词规则生成了一次工具调用。' : '',
      error: '',
    };
  }

  private static async tryRunAgentToolRound(
    endpoint: string,
    history: ChatMessage[],
    userText: string,
    persona: PersonaPreset,
    mode: ChatMode,
    settings: ModelSettings,
    onThinkingDelta: (delta: string) => void,
    onTextDelta: (delta: string) => void,
    toolCallbacks?: AgentToolCallbacks,
  ): Promise<AssistantReply | undefined> {
    if (toolCallbacks === undefined || !looksLikeAgentToolRequest(userText)) {
      return undefined;
    }

    const payload = ChatService.buildPayload(settings, persona, mode, history);
    payload.stream = false;
    payload.tools = createAgentToolDefinitions();
    payload.tool_choice = 'auto';
    payload.messages.splice(1, 0, createChatCompletionMessage(
      'system',
      '你可以调用工具完成明确的外部动作：系统闹钟、系统日历、系统联系人，以及 host_agent_tool。host_agent_tool 会把任务转发给用户配置的主机后端工具或后端 Agent，适合电脑文件、命令、脚本、搜索、浏览器、MCP、LangGraph 或其他前端无法直接完成的能力。只有用户确实需要这些外部能力时才调用工具；普通聊天、解释、推理不要调用。缺少关键字段时先追问。endpoint_path 通常留空，payload_json 必须是 JSON object 字符串。工具返回后，根据结果生成简短自然语言回复。',
    ));

    const decisionResponse = await ChatService.requestCompletionPayload(endpoint, payload, settings);
    if (decisionResponse.code < 200 || decisionResponse.code > 299) {
      return { text: '', thinking: '', error: `HTTP ${decisionResponse.code} ${decisionResponse.body.substring(0, 220)}` };
    }
    const decision = ChatService.parseToolDecisionResponse(decisionResponse.body, mode);
    if (decision.error.length > 0) {
      return { text: '', thinking: decision.thinking, error: decision.error };
    }
    if (decision.toolCalls.length === 0) {
      return {
        text: decision.text.length > 0 ? decision.text : '[emotion:neutral]\n模型没有返回正文。',
        thinking: decision.thinking,
        error: '',
      };
    }

    const toolMessages = payload.messages.slice();
    toolMessages.push(createAssistantToolChatMessage(decision.message));
    for (let index = 0; index < decision.toolCalls.length; index += 1) {
      const call = decision.toolCalls[index];
      toolCallbacks.onToolCallStart(call);
      const result = await toolCallbacks.executeTool(call);
      toolCallbacks.onToolCallFinish(result);
      toolMessages.push(createToolResultChatMessage(result));
    }

    const finalPayload = ChatService.buildPayload(settings, persona, mode, []);
    finalPayload.messages = toolMessages;
    finalPayload.stream = true;
    return ChatService.streamPayload(endpoint, finalPayload, settings, mode, onThinkingDelta, onTextDelta);
  }

  private static async streamPayload(
    endpoint: string,
    payload: ChatPayload,
    settings: ModelSettings,
    mode: ChatMode,
    onThinkingDelta: (delta: string) => void,
    onTextDelta: (delta: string) => void,
  ): Promise<AssistantReply> {
    const request = http.createHttp();
    let responseText = '';
    let responseThinking = '';
    let rawBody = '';
    let pending = '';
    let streamError = '';

    const onDataReceive = (chunk: ArrayBuffer): void => {
      const part = responseBodyToString(chunk, http.HttpDataType.ARRAY_BUFFER);
      rawBody += part;
      pending += part;
      const lines = pending.split('\n');
      pending = lines.length > 0 ? lines[lines.length - 1] : '';
      for (let index = 0; index < lines.length - 1; index += 1) {
        const line = lines[index].trim();
        if (!line.startsWith('data:')) {
          continue;
        }
        const data = line.substring(5).trim();
        if (data.length === 0 || data === '[DONE]') {
          continue;
        }
        const delta = parseStreamDelta(data, mode);
        if (delta.error.length > 0) {
          streamError = delta.error;
        }
        if (delta.thinking.length > 0) {
          responseThinking += delta.thinking;
          onThinkingDelta(delta.thinking);
        }
        if (delta.text.length > 0) {
          responseText += delta.text;
          onTextDelta(delta.text);
        }
      }
    };

    request.on('dataReceive', onDataReceive);
    try {
      const headers = createHttpHeaders(settings, 'text/event-stream');
      const code = await request.requestInStream(endpoint, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(payload),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 120000,
      });
      if (pending.trim().length > 0) {
        const delta = parseStreamDelta(pending.trim(), mode);
        if (delta.error.length > 0) {
          streamError = delta.error;
        }
        if (delta.thinking.length > 0) {
          responseThinking += delta.thinking;
          onThinkingDelta(delta.thinking);
        }
        if (delta.text.length > 0) {
          responseText += delta.text;
          onTextDelta(delta.text);
        }
      }
      if (code < 200 || code > 299) {
        return { text: responseText, thinking: responseThinking, error: `HTTP ${code} ${rawBody.substring(0, 220)}` };
      }
      if (streamError.length > 0) {
        return { text: responseText, thinking: responseThinking, error: streamError };
      }
      return {
        text: responseText.length > 0 ? responseText : '[emotion:neutral]\n模型没有返回正文。',
        thinking: responseThinking,
        error: '',
      };
    } catch (error) {
      return {
        text: responseText,
        thinking: responseThinking,
        error: errorToString(error),
      };
    } finally {
      request.off('dataReceive', onDataReceive);
      request.destroy();
    }
  }

  private static async requestCompletionPayload(
    endpoint: string,
    payload: ChatPayload,
    settings: ModelSettings,
  ): Promise<HttpTextResponse> {
    const request = http.createHttp();
    try {
      const response = await request.request(endpoint, {
        method: http.RequestMethod.POST,
        header: createHttpHeaders(settings, 'application/json'),
        extraData: JSON.stringify(payload),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 60000,
      });
      return {
        code: response.responseCode,
        body: responseBodyToString(response.result, response.resultType),
      };
    } catch (error) {
      return {
        code: 0,
        body: errorToString(error),
      };
    } finally {
      request.destroy();
    }
  }

  private static parseToolDecisionResponse(body: string, mode: ChatMode): ToolDecision {
    try {
      const json = JSON.parse(body) as ChatCompletionResponse;
      const choices = json.choices;
      if (!Array.isArray(choices) || choices.length === 0) {
        return createToolDecision('', '', '响应中没有 choices。', {}, []);
      }
      const first = choices[0];
      const message = first.message;
      const text = cleanDisplayText(cleanStreamChunk(stringValue(message.content)));
      let reasoning = '';
      if (mode === ChatMode.Thinking) {
        reasoning = cleanDisplayText(cleanStreamChunk(stringValue(message.reasoning_content)));
        if (reasoning.length === 0) {
          reasoning = cleanDisplayText(cleanStreamChunk(stringValue(message.reasoning)));
        }
      }
      const toolCalls = parseAgentToolCalls(message);
      return createToolDecision(text, reasoning, '', message, toolCalls);
    } catch (error) {
      return createToolDecision('', '', error instanceof Error ? error.message : '响应解析失败。', {}, []);
    }
  }

  private static demoReply(userText: string, mode: ChatMode): AssistantReply {
    const thinking = mode === ChatMode.Thinking
      ? '本地演示模式：先识别用户意图，再用红莉栖人格给出短答；没有调用远程模型。'
      : '';
    return {
      text: `[emotion:smile]\n本地演示回复而已。你的问题是“${userText}”。如果要得到真正的模型回答，就去设置里添加一个 OpenAI-compatible API Key。别把演示模式当成论文结论，明白吗？`,
      thinking,
      error: '',
    };
  }

  private static buildPayload(
    settings: ModelSettings,
    persona: PersonaPreset,
    mode: ChatMode,
    history: ChatMessage[],
  ): ChatPayload {
    const messages: ChatCompletionMessage[] = [];
    const promptContext: PromptRuntimeContext = {
      userName: '用户',
      currentTimeText: currentPromptTimeText(),
      mode,
      hasCameraFrame: false,
      isSelfMotivated: false,
      memoryFacts: [],
    };
    messages.push(createChatCompletionMessage('system', PersonaPromptBuilder.build(persona, promptContext)));
    const recent = history.filter((message: ChatMessage) => message.text.trim().length > 0).slice(-12);
    recent.forEach((message: ChatMessage) => {
      messages.push(createChatCompletionMessage(message.isAgent ? 'assistant' : 'user', message.text));
    });

    const config: ChatCompletionModeConfig = {
      providerName: settings.provider.name,
      providerBaseUrl: settings.provider.baseUrl,
      baseUrl: settings.baseUrl,
      model: settings.model,
      defaultModel: settings.provider.defaultModel,
    };
    const requestModel = resolveRequestModel(config, mode);
    const payload: ChatPayload = {
      model: requestModel,
      stream: false,
      messages,
    };
    applyModeParameters(payload, config, mode, requestModel);
    return payload;
  }

  private static parseCompletionResponse(body: string, mode: ChatMode): AssistantReply {
    try {
      const json = JSON.parse(body) as ChatCompletionResponse;
      const choices = json.choices;
      if (!Array.isArray(choices) || choices.length === 0) {
        return { text: '', thinking: '', error: '响应中没有 choices。' };
      }
      const first = choices[0];
      const message = first.message;
      const content = cleanDisplayText(cleanStreamChunk(stringValue(message.content)));
      let reasoning = '';
      if (mode === ChatMode.Thinking) {
        reasoning = cleanDisplayText(cleanStreamChunk(stringValue(message.reasoning_content)));
        if (reasoning.length === 0) {
          reasoning = cleanDisplayText(cleanStreamChunk(stringValue(message.reasoning)));
        }
      }
      return {
        text: content.length > 0 ? content : '[emotion:neutral]\n模型没有返回正文。',
        thinking: reasoning,
        error: '',
      };
    } catch (error) {
      return {
        text: '',
        thinking: '',
        error: error instanceof Error ? error.message : '响应解析失败。',
      };
    }
  }
}

function createHttpHeaders(settings: ModelSettings, accept: string): HttpHeaderMap {
  const headers: HttpHeaderMap = {
    'Content-Type': 'application/json',
    'Accept': accept,
  };
  if (settings.apiKey.length > 0) {
    headers.Authorization = `Bearer ${settings.apiKey}`;
  }
  return headers;
}

function createToolDecision(
  text: string,
  thinking: string,
  error: string,
  message: ChatCompletionResponseMessage,
  toolCalls: AgentToolCall[],
): ToolDecision {
  return {
    text,
    thinking,
    error,
    message,
    toolCalls,
  };
}

function parseAgentToolCalls(message: ChatCompletionResponseMessage): AgentToolCall[] {
  const rawToolCalls = message.tool_calls;
  if (!Array.isArray(rawToolCalls) || rawToolCalls.length === 0) {
    return [];
  }
  const calls: AgentToolCall[] = [];
  rawToolCalls.forEach((toolCall: ChatCompletionToolCall) => {
    const fn = toolCall.function;
    if (fn === undefined) {
      return;
    }
    const name = stringValue(fn.name);
    if (!isSupportedAgentTool(name)) {
      return;
    }
    calls.push(createAgentToolCall(stringValue(toolCall.id), name, stringValue(fn.arguments)));
  });
  return calls;
}

function createAssistantToolChatMessage(message: ChatCompletionResponseMessage): ChatCompletionMessage {
  const rawToolCalls = message.tool_calls;
  if (Array.isArray(rawToolCalls)) {
    return {
      role: 'assistant',
      content: stringValue(message.content),
      tool_calls: rawToolCalls,
    };
  }
  return {
    role: 'assistant',
    content: stringValue(message.content),
  };
}

function createToolResultChatMessage(result: AgentToolResult): ChatCompletionMessage {
  return {
    role: 'tool',
    content: result.content,
    tool_call_id: result.toolCallId,
    name: result.toolName,
  };
}

function parseStreamDelta(data: string, mode: ChatMode): StreamDelta {
  try {
    let payload = data;
    if (payload.startsWith('data:')) {
      payload = payload.substring(5).trim();
    }
    const chunk = JSON.parse(payload) as ChatCompletionStreamChunk;
    let error = '';
    if (chunk.error !== undefined) {
      error = stringValue(chunk.error.message);
    }
    const choices = chunk.choices;
    if (!Array.isArray(choices) || choices.length === 0) {
      return createStreamDelta('', '', error);
    }
    const first = choices[0];
    let delta: ChatCompletionResponseMessage | undefined = first.delta;
    if (delta === undefined) {
      delta = first.message;
    }
    if (delta === undefined) {
      return createStreamDelta('', '', error);
    }
    const text = cleanDisplayText(cleanStreamChunk(stringValue(delta.content)));
    let thinking = '';
    if (mode === ChatMode.Thinking) {
      thinking = cleanDisplayText(cleanStreamChunk(stringValue(delta.reasoning_content)));
      if (thinking.length === 0) {
        thinking = cleanDisplayText(cleanStreamChunk(stringValue(delta.reasoning)));
      }
    }
    return createStreamDelta(text, thinking, error);
  } catch (_) {
    return createStreamDelta('', '', '');
  }
}

function createStreamDelta(text: string, thinking: string, error: string): StreamDelta {
  return {
    text,
    thinking,
    error,
  };
}

function resolveRequestModel(config: ChatCompletionModeConfig, mode: ChatMode): string {
  const model = config.model.length > 0 ? config.model : config.defaultModel;
  if (!isDeepSeekProvider(config)) {
    return model;
  }
  if (mode === ChatMode.Fast && containsIgnoreCase(model, 'reasoner')) {
    return 'deepseek-chat';
  }
  if (mode === ChatMode.Thinking && model.toLowerCase() === 'deepseek-chat') {
    return 'deepseek-reasoner';
  }
  return model;
}

function applyModeParameters(
  payload: ChatPayload,
  config: ChatCompletionModeConfig,
  mode: ChatMode,
  requestModel: string,
): void {
  if (isMiMoProvider(config, requestModel)) {
    payload.thinking = createThinkingPayload(mode === ChatMode.Thinking ? 'enabled' : 'disabled');
    payload.top_p = 0.95;
    if (mode === ChatMode.Fast) {
      payload.temperature = 0.7;
      payload.max_completion_tokens = 1024;
    } else {
      payload.max_completion_tokens = 4096;
    }
    return;
  }
  if (isOpenRouterProvider(config)) {
    payload.reasoning = mode === ChatMode.Fast
      ? createReasoningPayload('none', true)
      : createReasoningPayload('medium', false);
    payload.max_tokens = mode === ChatMode.Fast ? 1024 : 4096;
    if (mode === ChatMode.Fast) {
      payload.temperature = 0.7;
    }
    return;
  }
  if (isDashScopeProvider(config, requestModel)) {
    payload.enable_thinking = mode === ChatMode.Thinking;
    payload.max_tokens = mode === ChatMode.Thinking ? 4096 : 1024;
    if (mode === ChatMode.Thinking) {
      payload.thinking_budget = 1024;
    } else {
      payload.temperature = 0.7;
    }
    return;
  }
  if (isDeepSeekProvider(config)) {
    payload.max_tokens = mode === ChatMode.Thinking ? 4096 : 1024;
    if (mode === ChatMode.Fast && !containsIgnoreCase(requestModel, 'reasoner')) {
      payload.temperature = 0.7;
    }
    return;
  }
  if (isOpenAiProvider(config, requestModel)) {
    if (isOpenAiReasoningModel(requestModel)) {
      payload.reasoning_effort = mode === ChatMode.Thinking ? 'medium' : 'minimal';
      payload.max_completion_tokens = mode === ChatMode.Thinking ? 4096 : 1024;
    } else {
      payload.max_tokens = mode === ChatMode.Thinking ? 2048 : 1024;
      if (mode === ChatMode.Fast) {
        payload.temperature = 0.7;
      }
    }
    return;
  }
  payload.max_tokens = mode === ChatMode.Thinking ? 2048 : 1024;
  if (mode === ChatMode.Fast) {
    payload.temperature = 0.7;
  }
}

function createChatCompletionMessage(role: string, content: string): ChatCompletionMessage {
  return {
    role,
    content,
  };
}

function createThinkingPayload(type: string): ThinkingPayload {
  return {
    type,
  };
}

function createReasoningPayload(effort: string, exclude: boolean): ReasoningPayload {
  return {
    effort,
    exclude,
  };
}

function isMiMoProvider(config: ChatCompletionModeConfig, requestModel: string): boolean {
  const haystack = `${config.providerName} ${config.providerBaseUrl} ${config.baseUrl} ${requestModel}`.toLowerCase();
  return haystack.indexOf('mimo') >= 0 || haystack.indexOf('xiaomi') >= 0 || haystack.indexOf('小米') >= 0;
}

function isOpenRouterProvider(config: ChatCompletionModeConfig): boolean {
  return config.providerName.toLowerCase() === 'openrouter' || config.baseUrl.toLowerCase().indexOf('openrouter.ai') >= 0;
}

function isDashScopeProvider(config: ChatCompletionModeConfig, requestModel: string): boolean {
  const haystack = `${config.providerName} ${config.providerBaseUrl} ${config.baseUrl} ${requestModel}`.toLowerCase();
  return haystack.indexOf('dashscope') >= 0 || haystack.indexOf('qwen') >= 0 || haystack.indexOf('通义') >= 0;
}

function isDeepSeekProvider(config: ChatCompletionModeConfig): boolean {
  const haystack = `${config.providerName} ${config.providerBaseUrl} ${config.baseUrl} ${config.model}`.toLowerCase();
  return haystack.indexOf('deepseek') >= 0;
}

function isOpenAiProvider(config: ChatCompletionModeConfig, requestModel: string): boolean {
  const haystack = `${config.providerName} ${config.providerBaseUrl} ${config.baseUrl} ${requestModel}`.toLowerCase();
  return haystack.indexOf('openai') >= 0 || haystack.indexOf('api.openai.com') >= 0;
}

function isOpenAiReasoningModel(model: string): boolean {
  const normalized = model.toLowerCase();
  return normalized.startsWith('o1') ||
    normalized.startsWith('o3') ||
    normalized.startsWith('o4') ||
    normalized.startsWith('gpt-5');
}

function looksLikeAgentToolRequest(text: string): boolean {
  const normalized = text.toLowerCase();
  const words = [
    '闹钟', '提醒我', '叫醒我', '日程', '日历', '会议', '行程', '安排',
    '联系人', '通讯录', '电话', '手机号', '邮箱', '查一下联系人', '查联系人',
    '主机', '后端', '电脑', 'pc', 'agent', 'mcp', 'langgraph', '调用工具',
    '工具调用', '有什么工具', '哪些工具', '能力列表', '终端', '命令', '脚本',
    '运行代码', '执行代码', '创建文件', '保存文件', '生成文件', '写入文件',
    '搜索', '联网', '网上', '网页', '浏览器', '爬取', '下载',
    'alarm', 'calendar', 'schedule', 'contact',
    'tool', 'backend', 'host', 'computer', 'command', 'script', 'search', 'web',
  ];
  return words.some((word: string): boolean => normalized.indexOf(word) >= 0);
}

function looksLikeLocalToolRequest(text: string): boolean {
  const normalized = text.toLowerCase();
  const words = [
    '闹钟', '提醒我', '叫醒我', '备忘', '记一下', '记下来', '记录一下',
    '你能说话', '能说话', '出声', '语音测试', '测试语音', '表情', 'live2d',
    'emotion', '搜索', '联网', '网上', '查一下', '查找', '查资料', '核实',
    '最新', '新闻', '今天', '现在', 'web search', 'search', '创建文件',
    '保存文件', '生成文件', '写入文件', '导出', 'txt', 'md', 'markdown',
    'csv', 'docx', 'xlsx', 'excel', 'word',
  ];
  return words.some((word: string) => normalized.indexOf(word) >= 0);
}

function containsIgnoreCase(value: string, part: string): boolean {
  return value.toLowerCase().indexOf(part.toLowerCase()) >= 0;
}

function trimEnd(value: string, char: string): string {
  let output = value;
  while (output.endsWith(char)) {
    output = output.substring(0, output.length - char.length);
  }
  return output;
}

function stringValue(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

function responseBodyToString(result: string | Object | ArrayBuffer, resultType: http.HttpDataType): string {
  if (typeof result === 'string') {
    return result;
  }
  if (resultType === http.HttpDataType.ARRAY_BUFFER || result instanceof ArrayBuffer) {
    try {
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(result as ArrayBuffer));
    } catch (_) {
      return '';
    }
  }
  try {
    return JSON.stringify(result);
  } catch (_) {
    return String(result);
  }
}

function errorToString(error: Error | Object | string): string {
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === 'string') {
    return error;
  }
  try {
    return JSON.stringify(error);
  } catch (_) {
    return String(error);
  }
}
