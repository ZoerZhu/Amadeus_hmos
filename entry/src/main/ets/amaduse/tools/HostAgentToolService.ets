import { common } from '@kit.AbilityKit';
import { buffer, util } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
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
const MAX_BACKEND_BODY_CHARS = 30000;
const MAX_SUMMARY_CHARS = 240;
const HOST_CONNECT_TIMEOUT_MS = 30000;
const HOST_READ_TIMEOUT_MS = 600000;
const HOST_FILE_DIR_NAME = 'host_agent_docs';
const HOST_FILE_MAX_BYTES = 100 * 1024 * 1024;

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
  mobileFile?: HostMobileFile;
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

interface HostMobileFile {
  path: string;
  uri?: string;
  storage?: string;
  fileName: string;
  mimeType: string;
  sizeBytes: number;
  sourcePath: string;
  note?: string;
  error?: string;
}

interface MobileSaveResult {
  path: string;
  uri: string;
  storage: string;
  note: string;
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

interface HostBackendToolResponse {
  data?: HostBackendToolData;
}

interface HostBackendToolData {
  tool?: string;
  result?: HostBackendToolResult;
}

interface HostBackendToolResult {
  agent?: string;
  title?: string;
  format?: string;
  saved?: boolean;
  outputPath?: string;
  absolutePath?: string;
  byteCount?: number;
  mimeType?: string;
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

interface WebSearchPayload {
  query: string;
  intent: string;
  freshness?: string;
  domains?: string[];
  excludeDomains?: string[];
  maxResults?: number;
  fetchContent?: boolean;
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
        const summary = hostHttpFailureSummary(response);
        return createFailureResult(call, body.action, body.target, summary, response.body, endpoint.url, response.code, body);
      }

      const payload = createBackendSuccessPayload(call, body.action, body.target, endpoint.url, response.code, response.body, body);
      await enrichPayloadWithMobileFile(context, settings, payload);
      return createResult(call, payload.ok, payload.summary, payload);
    } catch (error) {
      const detail = errorToString(error);
      return createFailureResult(call, action, stringValue(args.target), `主机后端调用失败：${detail}`, detail);
    }
  }
}

function createRequestBody(action: string, args: HostAgentArguments, rawArgumentsJson: string): HostAgentRequestBody {
  let resolvedAction = action;
  let targetType = stringValue(args.target_type, 'auto');
  let target = stringValue(args.target);
  let payload = parsePayloadObject(stringValue(args.payload_json));
  if (isWebSearchRequest(action, args)) {
    resolvedAction = 'call_tool';
    targetType = 'tool';
    target = 'web_search';
    payload = createWebSearchPayload(args);
  }
  return {
    action: resolvedAction,
    targetType,
    target,
    intent: stringValue(args.intent),
    payload,
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
      connectTimeout: HOST_CONNECT_TIMEOUT_MS,
      readTimeout: HOST_READ_TIMEOUT_MS,
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
  if (isLikelyHttpsToPlainUvicorn(baseUrl)) {
    return '当前主机后端是 uvicorn 明文 HTTP 服务，Backend URL 请使用 http://电脑局域网IP:8000，不能用 https://。否则后端会打印 Invalid HTTP request received。';
  }
  if (isLoopbackHost(baseUrl)) {
    return '手机不能用 127.0.0.1 或 localhost 访问电脑后端。请把 Backend URL 改成电脑局域网 IP，例如 http://192.168.1.10:8000，并确认手机和电脑在同一网络。';
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

async function enrichPayloadWithMobileFile(
  context: common.UIAbilityContext,
  settings: HostAgentSettings,
  payload: HostToolPayload,
): Promise<void> {
  if (!payload.ok || payload.response === undefined) {
    return;
  }
  const doc = extractDocWriterResult(payload.response);
  if (doc === undefined) {
    return;
  }
  const outputPath = stringValue(doc.outputPath);
  if (outputPath.length === 0 || doc.saved === false) {
    return;
  }
  try {
    const fileName = fileNameForDocWriterResult(doc, outputPath);
    const mobileFile = await downloadHostFile(context, settings, outputPath, fileName, stringValue(doc.mimeType));
    payload.mobileFile = mobileFile;
    if (mobileFile.storage === 'files') {
      payload.summary = `${payload.summary} 已保存到手机文件：${mobileFile.path}。`;
    } else {
      payload.summary = `${payload.summary} 已保存到应用沙箱：${mobileFile.path}。`;
    }
  } catch (error) {
    const detail = errorToString(error);
    payload.mobileFile = {
      path: '',
      fileName: fileNameForDocWriterResult(doc, outputPath),
      mimeType: stringValue(doc.mimeType, 'application/octet-stream'),
      sizeBytes: 0,
      sourcePath: outputPath,
      storage: 'none',
      error: detail,
    };
    payload.summary = `${payload.summary} 移动端保存失败：${limitText(detail, 120)}。`;
  }
}

function extractDocWriterResult(response: Object): HostBackendToolResult | undefined {
  const parsed = response as HostBackendToolResponse;
  const data = parsed.data;
  if (data === undefined) {
    return undefined;
  }
  const tool = stringValue(data.tool).toLowerCase();
  const result = data.result;
  if (result === undefined) {
    return undefined;
  }
  const agent = stringValue(result.agent).toLowerCase();
  if (tool === 'doc_writer' || tool === 'doc_writer_agent' || agent === 'doc_writer_agent') {
    return result;
  }
  return undefined;
}

async function downloadHostFile(
  context: common.UIAbilityContext,
  settings: HostAgentSettings,
  sourcePath: string,
  fileName: string,
  mimeType: string,
): Promise<HostMobileFile> {
  const endpoint = `${trimEnd(settings.baseUrl.trim(), '/')}/api/files/download?path=${encodeURIComponent(sourcePath)}`;
  const request = http.createHttp();
  try {
    const headers: HostHttpHeaderMap = {
      'Content-Type': 'application/json',
      'Accept': mimeType.length > 0 ? mimeType : 'application/octet-stream',
    };
    if (settings.apiKey.trim().length > 0) {
      headers.Authorization = `Bearer ${settings.apiKey.trim()}`;
    }
    const response = await request.request(endpoint, {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: HOST_CONNECT_TIMEOUT_MS,
      readTimeout: HOST_READ_TIMEOUT_MS,
      maxLimit: HOST_FILE_MAX_BYTES,
    });
    if (response.responseCode < 200 || response.responseCode > 299) {
      throw new Error(`HTTP ${response.responseCode} ${responseBodyToString(response.result, response.resultType).substring(0, 220)}`);
    }
    const body = responseBodyToArrayBuffer(response.result, response.resultType);
    const saved = await writeMobileFile(context, fileName, body);
    return {
      path: saved.path,
      uri: saved.uri.length > 0 ? saved.uri : undefined,
      storage: saved.storage,
      fileName,
      mimeType: mimeType.length > 0 ? mimeType : mimeTypeForFileName(fileName),
      sizeBytes: body.byteLength,
      sourcePath,
      note: saved.note.length > 0 ? saved.note : undefined,
    };
  } finally {
    request.destroy();
  }
}

async function writeMobileFile(context: common.UIAbilityContext, fileName: string, body: ArrayBuffer): Promise<MobileSaveResult> {
  const historyPath = writeMobileFileToSandbox(context, fileName, body);
  try {
    const saved = await writeMobileFileToUserFiles(context, fileName, body);
    return {
      path: saved.path,
      uri: saved.uri,
      storage: saved.storage,
      note: `App 内历史副本：${historyPath}`,
    };
  } catch (error) {
    return {
      path: historyPath,
      uri: '',
      storage: 'app_sandbox',
      note: `系统文件保存未完成，已回退到应用沙箱：${errorToString(error)}`,
    };
  }
}

async function writeMobileFileToUserFiles(
  context: common.UIAbilityContext,
  fileName: string,
  body: ArrayBuffer,
): Promise<MobileSaveResult> {
  const saveOptions = new picker.DocumentSaveOptions();
  saveOptions.newFileNames = [safeFileName(fileName)];
  const documentPicker = new picker.DocumentViewPicker(context);
  const uris = await documentPicker.save(saveOptions);
  if (uris.length === 0) {
    throw new Error('用户取消保存');
  }
  const uri = uris[0];
  const file = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, body);
  } finally {
    fileIo.closeSync(file);
  }
  return {
    path: uri,
    uri,
    storage: 'files',
    note: '',
  };
}

function writeMobileFileToSandbox(context: common.UIAbilityContext, fileName: string, body: ArrayBuffer): string {
  const dir = `${context.filesDir}/${HOST_FILE_DIR_NAME}`;
  if (!fileExists(dir)) {
    fileIo.mkdirSync(dir, true);
  }
  const localPath = uniqueLocalPath(dir, safeFileName(fileName));
  const file = fileIo.openSync(localPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, body);
  } finally {
    fileIo.closeSync(file);
  }
  return localPath;
}

function uniqueLocalPath(dir: string, fileName: string): string {
  const dotIndex = fileName.lastIndexOf('.');
  const stem = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
  const suffix = dotIndex > 0 ? fileName.substring(dotIndex) : '';
  let candidate = `${dir}/${fileName}`;
  let index = 1;
  while (fileExists(candidate)) {
    candidate = `${dir}/${stem}_${index}${suffix}`;
    index += 1;
  }
  return candidate;
}

function fileNameForDocWriterResult(doc: HostBackendToolResult, outputPath: string): string {
  const fromPath = basename(outputPath);
  if (fromPath.length > 0) {
    return fromPath;
  }
  const title = safeFileName(stringValue(doc.title, 'document'));
  const format = stringValue(doc.format, 'md').toLowerCase();
  return `${title}.${format}`;
}

function basename(path: string): string {
  const normalized = path.replace(/\\/g, '/');
  const index = normalized.lastIndexOf('/');
  if (index < 0) {
    return normalized;
  }
  return normalized.substring(index + 1);
}

function safeFileName(value: string): string {
  let output = value.trim().replace(/[<>:"/\\|?*\x00-\x1f]/g, '_');
  while (output.endsWith('.') || output.endsWith(' ')) {
    output = output.substring(0, output.length - 1);
  }
  if (output.length === 0 || output === '.' || output === '..') {
    return `document_${Date.now()}.md`;
  }
  return output;
}

function mimeTypeForFileName(fileName: string): string {
  const lower = fileName.toLowerCase();
  if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
    return 'text/markdown';
  }
  if (lower.endsWith('.txt')) {
    return 'text/plain';
  }
  if (lower.endsWith('.csv')) {
    return 'text/csv';
  }
  if (lower.endsWith('.docx')) {
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  }
  if (lower.endsWith('.xlsx')) {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  return 'application/octet-stream';
}

function fileExists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (_) {
    return false;
  }
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

function createWebSearchPayload(args: HostAgentArguments): WebSearchPayload {
  const payload = parseWebSearchPayload(stringValue(args.payload_json));
  const query = stringValue(payload.query, stringValue(args.intent));
  const next: WebSearchPayload = {
    query,
    intent: stringValue(payload.intent, stringValue(args.intent, query)),
  };
  if (payload.freshness !== undefined && payload.freshness.length > 0) {
    next.freshness = payload.freshness;
  }
  if (payload.domains !== undefined && payload.domains.length > 0) {
    next.domains = payload.domains;
  }
  if (payload.excludeDomains !== undefined && payload.excludeDomains.length > 0) {
    next.excludeDomains = payload.excludeDomains;
  }
  if (payload.maxResults !== undefined && Number.isFinite(payload.maxResults)) {
    next.maxResults = payload.maxResults;
  } else {
    next.maxResults = 10;
  }
  if (payload.fetchContent !== undefined) {
    next.fetchContent = payload.fetchContent;
  } else {
    next.fetchContent = true;
  }
  return next;
}

function parseWebSearchPayload(payloadJson: string): WebSearchPayload {
  if (payloadJson.trim().length === 0) {
    return createEmptyWebSearchPayload();
  }
  try {
    return JSON.parse(payloadJson) as WebSearchPayload;
  } catch (_) {
    const payload: WebSearchPayload = {
      query: payloadJson,
      intent: payloadJson,
    };
    return payload;
  }
}

function createEmptyWebSearchPayload(): WebSearchPayload {
  return {
    query: '',
    intent: '',
  };
}

function isWebSearchRequest(action: string, args: HostAgentArguments): boolean {
  if (action === 'query_capabilities') {
    return false;
  }
  const target = stringValue(args.target).toLowerCase();
  if (isExplicitNonSearchHostTarget(target)) {
    return false;
  }
  if (target === 'web_search' || target === 'web_search_agent') {
    return true;
  }
  const haystack = `${target} ${stringValue(args.intent)} ${stringValue(args.payload_json)}`.toLowerCase();
  return containsAny(haystack, ['搜索', '联网', '网上', '网页', '查资料', 'web search', 'search', 'web']);
}

function isExplicitNonSearchHostTarget(target: string): boolean {
  return target === 'doc_writer' ||
    target === 'doc_writer_agent' ||
    target === 'file_reader' ||
    target === 'file_reader_agent' ||
    target === 'todo_task' ||
    target === 'todo_task_agent';
}

function parseBackendResponse(body: string): HostBackendPreview | undefined {
  try {
    return JSON.parse(body) as HostBackendPreview;
  } catch (_) {
    return undefined;
  }
}

function containsAny(value: string, parts: string[]): boolean {
  return parts.some((part: string): boolean => value.indexOf(part) >= 0);
}

function hostHttpFailureSummary(response: HttpTextResponse): string {
  if (response.code === 0 && isTimeoutError(response.body)) {
    return '主机后端连接超时：请确认 Backend URL 使用 http://电脑局域网IP:8000，不要用 https://、127.0.0.1 或 localhost；电脑后端监听 0.0.0.0:8000；Windows 防火墙已放行端口 8000；手机和电脑在同一 Wi-Fi。若这些都正确，可能是 web_search 抓网页耗时过长。';
  }
  return `主机后端返回 HTTP ${response.code}：${response.body.substring(0, MAX_SUMMARY_CHARS)}`;
}

function isTimeoutError(body: string): boolean {
  const normalized = body.toLowerCase();
  return normalized.indexOf('2300028') >= 0 ||
    normalized.indexOf('operation timeout') >= 0 ||
    normalized.indexOf('timeout') >= 0 ||
    normalized.indexOf('timed out') >= 0;
}

function isLoopbackHost(baseUrl: string): boolean {
  const normalized = baseUrl.toLowerCase();
  return normalized.startsWith('http://127.') ||
    normalized.startsWith('https://127.') ||
    normalized.startsWith('http://localhost') ||
    normalized.startsWith('https://localhost') ||
    normalized.startsWith('http://[::1]') ||
    normalized.startsWith('https://[::1]');
}

function isLikelyHttpsToPlainUvicorn(baseUrl: string): boolean {
  const normalized = baseUrl.trim().toLowerCase();
  if (!normalized.startsWith('https://')) {
    return false;
  }
  const withoutScheme = normalized.substring('https://'.length);
  const hostPort = withoutScheme.split('/')[0];
  return hostPort.endsWith(':8000');
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

function responseBodyToArrayBuffer(result: string | Object | ArrayBuffer, resultType: http.HttpDataType): ArrayBuffer {
  if (result instanceof ArrayBuffer) {
    return result;
  }
  if (resultType === http.HttpDataType.ARRAY_BUFFER && result instanceof ArrayBuffer) {
    return result;
  }
  if (typeof result === 'string') {
    return buffer.from(result, 'binary').buffer;
  }
  return buffer.from(JSON.stringify(result), 'utf-8').buffer;
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
