import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HostAgentSettings } from '../model/AppModels';
import { ChatPersistence } from '../services/ChatPersistence';
import { currentPromptTimeText } from '../services/AppUtils';
import {
  AgentToolCall,
  AgentToolResult,
  agentToolActionLabel,
  agentToolDisplayName,
} from './AgentTools';

const DEFAULT_ENDPOINT_PATH = '/api/agent/invoke';
const MAX_BACKEND_BODY_CHARS = 8000;
const MAX_SUMMARY_CHARS = 240;

interface HostAgentArguments {
  action?: string;
  target_type?: string;
  target?: string;
  intent?: string;
  payload_json?: string;
  endpoint_path?: string;
}

interface HostAgentRequestBody {
  action: string;
  targetType: string;
  target: string;
  intent: string;
  payload: Object;
  rawArguments: Object;
  client: string;
  requestedAt: string;
}

interface HostToolPayload {
  ok: boolean;
  tool: string;
  action: string;
  target: string;
  summary: string;
  endpoint?: string;
  httpStatus?: number;
  request?: HostAgentRequestBody;
  response?: Object;
  responseText?: string;
  error?: string;
}

interface HostHttpHeaderMap {
  'Content-Type': string;
  'Accept': string;
  'Authorization'?: string;
}

interface HostEndpoint {
  ok: boolean;
  url: string;
  error: string;
}

interface HostBackendPreview {
  ok?: boolean;
  summary?: string;
  message?: string;
  text?: string;
  error?: string;
  result?: Object;
  data?: Object;
}

interface EmptyPayload {
}

interface RawArgumentFallback {
  raw: string;
}

interface TextPayloadFallback {
  text: string;
}

interface ValuePayloadFallback {
  value: string;
}

export class HostAgentToolService {
  static async execute(context: common.UIAbilityContext, call: AgentToolCall): Promise<AgentToolResult> {
    const args = parseHostAgentArguments(call.argumentsJson);
    const action = normalizedHostAction(args.action);
    try {
      const settings = await ChatPersistence.loadHostAgentSettings(context);
      const configError = validateHostAgentSettings(settings);
      if (configError.length > 0) {
        return createFailureResult(call, action, stringValue(args.target), configError, configError);
      }

      const endpoint = resolveEndpoint(settings, stringValue(args.endpoint_path));
      if (!endpoint.ok) {
        return createFailureResult(call, action, stringValue(args.target), endpoint.error, endpoint.error);
      }

      const body = createRequestBody(action, args, call.argumentsJson);
      const response = await postToHostBackend(endpoint.url, settings, body);
      if (response.code < 200 || response.code > 299) {
        const summary = `主机后端返回 HTTP ${response.code}：${response.body.substring(0, MAX_SUMMARY_CHARS)}`;
        return createFailureResult(call, action, body.target, summary, response.body, endpoint.url, response.code, body);
      }

      const payload = createBackendSuccessPayload(call, action, body.target, endpoint.url, response.code, response.body, body);
      return createResult(call, true, payload.summary, payload);
    } catch (error) {
      const detail = errorToString(error);
      return createFailureResult(call, action, stringValue(args.target), `主机后端调用失败：${detail}`, detail);
    }
  }
}

function createRequestBody(action: string, args: HostAgentArguments, rawArgumentsJson: string): HostAgentRequestBody {
  return {
    action,
    targetType: stringValue(args.target_type, 'auto'),
    target: stringValue(args.target),
    intent: stringValue(args.intent),
    payload: parsePayloadObject(stringValue(args.payload_json)),
    rawArguments: parseRawArguments(rawArgumentsJson),
    client: 'Amaduse HarmonyOS',
    requestedAt: currentPromptTimeText(),
  };
}

async function postToHostBackend(
  endpoint: string,
  settings: HostAgentSettings,
  body: HostAgentRequestBody,
): Promise<HttpTextResponse> {
  const request = http.createHttp();
  try {
    const headers: HostHttpHeaderMap = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (settings.apiKey.trim().length > 0) {
      headers.Authorization = `Bearer ${settings.apiKey.trim()}`;
    }
    const response = await request.request(endpoint, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: JSON.stringify(body),
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 20000,
      readTimeout: 120000,
    });
    return {
      code: response.responseCode,
      body: limitText(responseBodyToString(response.result, response.resultType), MAX_BACKEND_BODY_CHARS),
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

interface HttpTextResponse {
  code: number;
  body: string;
}

function validateHostAgentSettings(settings: HostAgentSettings): string {
  if (!settings.enabled) {
    return '主机后端 Agent 未启用。请在设置里开启并填写主机后端地址。';
  }
  const baseUrl = settings.baseUrl.trim();
  if (baseUrl.length === 0) {
    return '主机后端地址为空。请填写例如 http://192.168.1.10:8000。';
  }
  if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
    return '主机后端地址必须以 http:// 或 https:// 开头。';
  }
  return '';
}

function resolveEndpoint(settings: HostAgentSettings, requestedPath: string): HostEndpoint {
  const path = requestedPath.length > 0 ? requestedPath : stringValue(settings.endpointPath, DEFAULT_ENDPOINT_PATH);
  if (!isSafeRelativePath(path)) {
    return {
      ok: false,
      url: '',
      error: '后端路径必须是以 / 开头的相对路径，且不能包含协议、反斜杠或 ..。',
    };
  }
  return {
    ok: true,
    url: `${trimEnd(settings.baseUrl.trim(), '/')}${path}`,
    error: '',
  };
}

function isSafeRelativePath(path: string): boolean {
  return path.startsWith('/') &&
    path.indexOf('://') < 0 &&
    path.indexOf('\\') < 0 &&
    path.indexOf('..') < 0;
}

function createBackendSuccessPayload(
  call: AgentToolCall,
  action: string,
  target: string,
  endpoint: string,
  status: number,
  responseBody: string,
  requestBody: HostAgentRequestBody,
): HostToolPayload {
  const parsed = parseBackendResponse(responseBody);
  if (parsed !== undefined) {
    const ok = parsed.ok === undefined ? true : parsed.ok;
    const summary = backendSummary(parsed, status);
    return {
      ok,
      tool: call.name,
      action,
      target,
      summary,
      endpoint,
      httpStatus: status,
      request: requestBody,
      response: parsed,
      error: ok ? undefined : stringValue(parsed.error, summary),
    };
  }
  return {
    ok: true,
    tool: call.name,
    action,
    target,
    summary: `主机后端已返回结果：${responseBody.substring(0, MAX_SUMMARY_CHARS)}`,
    endpoint,
    httpStatus: status,
    request: requestBody,
    responseText: responseBody,
  };
}

function backendSummary(parsed: HostBackendPreview, status: number): string {
  const summary = stringValue(parsed.summary,
    stringValue(parsed.message,
      stringValue(parsed.text,
        stringValue(parsed.error))));
  if (summary.length > 0) {
    return limitText(summary, MAX_SUMMARY_CHARS);
  }
  return `主机后端已返回 JSON 结果，HTTP ${status}。`;
}

function createFailureResult(
  call: AgentToolCall,
  action: string,
  target: string,
  summary: string,
  error: string,
  endpoint: string = '',
  status: number = 0,
  requestBody?: HostAgentRequestBody,
): AgentToolResult {
  const payload: HostToolPayload = {
    ok: false,
    tool: call.name,
    action,
    target,
    summary,
    endpoint: endpoint.length > 0 ? endpoint : undefined,
    httpStatus: status > 0 ? status : undefined,
    request: requestBody,
    error,
  };
  return createResult(call, false, summary, payload);
}

function createResult(call: AgentToolCall, ok: boolean, summary: string, payload: HostToolPayload): AgentToolResult {
  return {
    toolCallId: call.id,
    toolName: call.name,
    displayName: `${agentToolDisplayName(call.name)} · ${agentToolActionLabel(payload.action)}`,
    ok,
    summary,
    content: JSON.stringify(payload),
  };
}

function parseHostAgentArguments(argumentsJson: string): HostAgentArguments {
  try {
    return JSON.parse(argumentsJson) as HostAgentArguments;
  } catch (_) {
    return {
      action: 'call_agent',
      target_type: 'auto',
      target: '',
      intent: argumentsJson,
      payload_json: '{}',
    };
  }
}

function parseRawArguments(argumentsJson: string): Object {
  try {
    return JSON.parse(argumentsJson) as Object;
  } catch (_) {
    const fallback: RawArgumentFallback = {
      raw: argumentsJson,
    };
    return fallback;
  }
}

function parsePayloadObject(payloadJson: string): Object {
  if (payloadJson.trim().length === 0) {
    const empty: EmptyPayload = {};
    return empty;
  }
  try {
    const parsed = JSON.parse(payloadJson) as Object;
    if (typeof parsed === 'object') {
      return parsed;
    }
    const fallback: ValuePayloadFallback = {
      value: payloadJson,
    };
    return fallback;
  } catch (_) {
    const fallback: TextPayloadFallback = {
      text: payloadJson,
    };
    return fallback;
  }
}

function parseBackendResponse(body: string): HostBackendPreview | undefined {
  try {
    return JSON.parse(body) as HostBackendPreview;
  } catch (_) {
    return undefined;
  }
}

function normalizedHostAction(action: string | undefined): string {
  const normalized = stringValue(action).toLowerCase();
  if (normalized === 'call_tool' || normalized === 'tool' || normalized === '工具') {
    return 'call_tool';
  }
  if (normalized === 'query_capabilities' || normalized === 'capabilities' || normalized === 'list_tools' ||
    normalized === '能力查询' || normalized === '查询能力') {
    return 'query_capabilities';
  }
  return 'call_agent';
}

function trimEnd(value: string, char: string): string {
  let output = value;
  while (output.endsWith(char)) {
    output = output.substring(0, output.length - char.length);
  }
  return output;
}

function limitText(value: string, maxLength: number): string {
  if (value.length <= maxLength) {
    return value;
  }
  return `${value.substring(0, maxLength)}...`;
}

function stringValue(value: string | undefined, fallback: string = ''): string {
  return typeof value === 'string' && value.length > 0 ? value : fallback;
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
