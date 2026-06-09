import { http, webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HostAgentSettings } from '../model/AppModels';

const MOBILE_TASKS_PATH = '/api/mobile/code-tasks';
const MOBILE_TASK_CONNECT_TIMEOUT_MS = 20000;
const MOBILE_TASK_WS_READY_TIMEOUT_MS = 5000;
const MOBILE_TASK_REQUEST_READ_TIMEOUT_MS = 20000;
const MOBILE_TASK_READ_TIMEOUT_MS = 600000;

export interface CodeTaskQuestionOption {
  label?: string;
  description?: string;
}

export interface CodeTaskQuestionItem {
  question?: string;
  header?: string;
  options?: CodeTaskQuestionOption[];
  multiple?: boolean;
  custom?: boolean;
}

export interface CodeTaskQuestionPayload {
  requestId?: string;
  sessionId?: string;
  questions?: CodeTaskQuestionItem[];
  message?: string;
  v2?: boolean;
}

export interface CodeTaskEventPayload extends CodeTaskQuestionPayload {
  taskId?: string;
  eventId?: number;
  emittedAt?: string;
  text?: string;
  source?: string;
  status?: string;
  serverUrl?: string;
  workspacePath?: string;
  title?: string;
  command?: string;
  output?: string;
  path?: string;
  diff?: string;
  name?: string;
  detail?: string;
  action?: string;
  resources?: string[];
  answers?: string[][];
  rejected?: boolean;
}

export interface CodeTaskEventRecord {
  seq: number;
  event: string;
  payload: CodeTaskEventPayload;
  createdAt: string;
}

export interface CodeTaskSnapshotQuestion {
  requestId?: string;
  sessionId?: string;
  serverUrl?: string;
  questions?: CodeTaskQuestionItem[];
  v2?: boolean;
  answered?: boolean;
  rejected?: boolean;
  answers?: string[][];
}

export interface CodeTaskSnapshotMessage {
  id?: string;
  kind?: string;
  title?: string;
  text?: string;
  detail?: string;
  question?: CodeTaskSnapshotQuestion;
  createdAt?: string;
}

export interface CodeTaskSnapshot {
  id?: string;
  title?: string;
  prompt?: string;
  workspacePath?: string;
  status?: string;
  sessionId?: string;
  messages?: CodeTaskSnapshotMessage[];
  summary?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface CodeTaskSummary {
  id: string;
  title?: string;
  prompt?: string;
  workspacePath?: string;
  status?: string;
  sessionId?: string;
  serverUrl?: string;
  running?: boolean;
  backgroundRunning?: boolean;
  pendingQuestions?: CodeTaskQuestionPayload[];
  createdAt?: string;
  updatedAt?: string;
  eventCount?: number;
  lastEvent?: CodeTaskEventRecord;
  summary?: string;
}

export interface CodeTaskDetail extends CodeTaskSummary {
  events?: CodeTaskEventRecord[];
  snapshot?: CodeTaskSnapshot;
}

export interface CodeTaskMessageResult {
  ok?: boolean;
  taskId?: string;
  mode?: string;
  summary?: string;
  error?: string;
}

export interface CodeTaskQuestionReplyResult {
  ok?: boolean;
  answers?: string[][];
  rejected?: boolean;
  task?: CodeTaskDetail;
  timedOut?: boolean;
  error?: string;
}

export interface CodeTaskEventStream {
  close(): void;
  sendMessage?(prompt: string, title: string): Promise<CodeTaskMessageResult>;
  replyQuestion?(
    requestId: string,
    answers: string[][],
    v2: boolean,
    reject?: boolean,
  ): Promise<CodeTaskQuestionReplyResult>;
}

export interface CodeTaskEventStreamCallbacks {
  onTask?: (task: CodeTaskDetail) => void;
  onEvent: (event: CodeTaskEventRecord) => void;
  onError: (message: string) => void;
  onDone?: () => void;
}

class HttpCodeTaskEventStream implements CodeTaskEventStream {
  private closeHandler: () => void;

  constructor(closeHandler: () => void) {
    this.closeHandler = closeHandler;
  }

  close(): void {
    this.closeHandler();
  }
}

interface CodeTaskListResponse {
  tasks?: CodeTaskSummary[];
}

interface CodeTaskDetailResponse {
  task?: CodeTaskDetail;
}

interface CodeTaskWaitResponse {
  task?: CodeTaskDetail;
  timedOut?: boolean;
}

interface CodeTaskHttpHeaderMap {
  'Content-Type': string;
  'Accept': string;
  'Authorization'?: string;
  'Cache-Control'?: string;
  'Pragma'?: string;
}

interface CodeTaskSendMessageBody {
  prompt: string;
  title: string;
  autoApprove: boolean;
  timeoutSeconds: number;
}

interface CodeTaskQuestionReplyBody {
  requestId: string;
  answers: string[][];
  v2: boolean;
  reject: boolean;
  waitForResult?: boolean;
  afterSeq?: number;
  timeoutSeconds?: number;
}

interface CodeTaskWsMessageCommand {
  type: string;
  prompt: string;
  title: string;
  autoApprove: boolean;
  timeoutSeconds: number;
}

interface CodeTaskWsQuestionReplyCommand {
  type: string;
  requestId: string;
  answers: string[][];
  v2: boolean;
  reject: boolean;
}

interface SseTaskEnvelope {
  task?: CodeTaskDetail;
}

interface WebSocketTaskEnvelope {
  type?: string;
  action?: string;
  event?: string;
  payload?: CodeTaskEventPayload;
  seq?: number;
  createdAt?: string;
  task?: CodeTaskDetail;
  result?: CodeTaskMessageResult | CodeTaskQuestionReplyResult;
  message?: string;
}

export class CodeTaskRemoteService {
  static isConfigured(settings: HostAgentSettings): boolean {
    return settings.enabled && settings.baseUrl.trim().length > 0;
  }

  static async listTasks(settings: HostAgentSettings): Promise<CodeTaskSummary[]> {
    const response = await requestJson(settings, cacheBustedPath(MOBILE_TASKS_PATH), http.RequestMethod.GET);
    const payload = parseJson<CodeTaskListResponse>(response);
    return Array.isArray(payload.tasks) ? payload.tasks : [];
  }

  static async getTaskDetail(settings: HostAgentSettings, taskId: string): Promise<CodeTaskDetail> {
    const response = await requestJson(settings, cacheBustedPath(`${MOBILE_TASKS_PATH}/${encodeURIComponent(taskId)}`), http.RequestMethod.GET);
    const payload = parseJson<CodeTaskDetailResponse>(response);
    if (payload.task === undefined) {
      throw new Error('主机端未返回任务详情。');
    }
    return payload.task;
  }

  static async waitTaskResult(
    settings: HostAgentSettings,
    taskId: string,
    afterSeq: number,
    ignoreQuestionRequestId: string,
    timeoutSeconds: number = 180,
  ): Promise<CodeTaskWaitResponse> {
    const path = `${MOBILE_TASKS_PATH}/${encodeURIComponent(taskId)}/wait` +
      `?afterSeq=${afterSeq}` +
      `&ignoreQuestionRequestId=${encodeURIComponent(ignoreQuestionRequestId)}` +
      `&timeoutSeconds=${timeoutSeconds}`;
    const response = await requestJson(
      settings,
      cacheBustedPath(path),
      http.RequestMethod.GET,
      undefined,
      MOBILE_TASK_READ_TIMEOUT_MS,
    );
    return parseJson<CodeTaskWaitResponse>(response);
  }

  static async sendMessage(
    settings: HostAgentSettings,
    taskId: string,
    prompt: string,
    title: string,
  ): Promise<CodeTaskMessageResult> {
    const body: CodeTaskSendMessageBody = {
      prompt,
      title,
      autoApprove: false,
      timeoutSeconds: 1800,
    };
    const response = await requestJson(
      settings,
      `${MOBILE_TASKS_PATH}/${encodeURIComponent(taskId)}/messages`,
      http.RequestMethod.POST,
      body,
    );
    return parseJson<CodeTaskMessageResult>(response);
  }

  static async replyQuestion(
    settings: HostAgentSettings,
    taskId: string,
    requestId: string,
    answers: string[][],
    v2: boolean,
    reject: boolean = false,
    waitForResult: boolean = false,
    afterSeq: number = 0,
    timeoutSeconds: number = 180,
  ): Promise<CodeTaskQuestionReplyResult> {
    const body: CodeTaskQuestionReplyBody = {
      requestId,
      answers,
      v2,
      reject,
      waitForResult,
      afterSeq,
      timeoutSeconds,
    };
    const response = await requestJson(
      settings,
      `${MOBILE_TASKS_PATH}/${encodeURIComponent(taskId)}/question/reply`,
      http.RequestMethod.POST,
      body,
      waitForResult ? MOBILE_TASK_READ_TIMEOUT_MS : MOBILE_TASK_REQUEST_READ_TIMEOUT_MS,
    );
    return parseJson<CodeTaskQuestionReplyResult>(response);
  }

  static streamTaskEvents(
    settings: HostAgentSettings,
    taskId: string,
    callbacks: CodeTaskEventStreamCallbacks,
  ): CodeTaskEventStream {
    return new WebSocketCodeTaskEventStream(settings, taskId, callbacks);
  }

  static streamTaskEventsByHttp(
    settings: HostAgentSettings,
    taskId: string,
    callbacks: CodeTaskEventStreamCallbacks,
  ): CodeTaskEventStream {
    const endpoint = `${resolveBaseUrl(settings)}${MOBILE_TASKS_PATH}/${encodeURIComponent(taskId)}/events?replay=true`;
    const request = http.createHttp();
    let closed = false;
    let pending = '';

    const onDataReceive = (chunk: ArrayBuffer): void => {
      if (closed) {
        return;
      }
      pending += responseBodyToString(chunk, http.HttpDataType.ARRAY_BUFFER).replace(/\r\n/g, '\n');
      pending = consumeSseBuffer(pending, callbacks);
    };

    request.on('dataReceive', onDataReceive);
    request.requestInStream(endpoint, {
      method: http.RequestMethod.GET,
      header: createHeaders(settings, 'text/event-stream'),
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: MOBILE_TASK_CONNECT_TIMEOUT_MS,
      readTimeout: MOBILE_TASK_READ_TIMEOUT_MS,
    }).then((code: number): void => {
      if (closed) {
        return;
      }
      if (pending.trim().length > 0) {
        consumeSseBlock(pending, callbacks);
        pending = '';
      }
      if (code < 200 || code > 299) {
        callbacks.onError(`主机任务事件流 HTTP ${code}`);
      }
      if (callbacks.onDone !== undefined) {
        callbacks.onDone();
      }
    }).catch((error: Error | Object | string): void => {
      if (!closed) {
        callbacks.onError(errorToString(error));
      }
    }).finally((): void => {
      request.off('dataReceive', onDataReceive);
      request.destroy();
    });

    return new HttpCodeTaskEventStream((): void => {
      closed = true;
      request.off('dataReceive', onDataReceive);
      request.destroy();
    });
  }
}

class WebSocketCodeTaskEventStream implements CodeTaskEventStream {
  private socket: webSocket.WebSocket = webSocket.createWebSocket();
  private callbacks: CodeTaskEventStreamCallbacks;
  private ready: Promise<void>;
  private closed: boolean = false;
  private pendingAction: string = '';
  private pendingResolve?: (value: CodeTaskMessageResult | CodeTaskQuestionReplyResult) => void;
  private pendingReject?: (reason: Error) => void;
  private pendingTimer: number = -1;

  constructor(settings: HostAgentSettings, taskId: string, callbacks: CodeTaskEventStreamCallbacks) {
    this.callbacks = callbacks;
    const endpoint = `${resolveWebSocketBaseUrl(settings)}${MOBILE_TASKS_PATH}/${encodeURIComponent(taskId)}/ws`;
    this.socket.on('message', (error: Error | undefined, data: string | ArrayBuffer): void => {
      if (error !== undefined) {
        this.callbacks.onError(errorToString(error));
        return;
      }
      this.handleMessage(data);
    });
    this.socket.on('close', (_error: Error | undefined): void => {
      if (!this.closed && this.callbacks.onDone !== undefined) {
        this.callbacks.onDone();
      }
    });
    this.socket.on('error', (error: Error): void => {
      if (!this.closed) {
        this.callbacks.onError(errorToString(error));
      }
      this.rejectPending(errorToString(error));
    });
    this.ready = this.socket.connect(endpoint, {
      header: createHeaders(settings, 'application/json'),
      pingInterval: 25,
      pongTimeout: 20,
    }).then((): void => undefined).catch((error: Error | Object | string): void => {
      const message = errorToString(error);
      this.callbacks.onError(`任务 WebSocket 连接失败：${message}`);
      this.rejectPending(message);
      throw new Error(message);
    });
  }

  close(): void {
    this.closed = true;
    this.rejectPending('任务连接已关闭。');
    try {
      this.socket.off('message');
      this.socket.off('close');
      this.socket.off('error');
      this.socket.close();
    } catch (_) {
    }
  }

  async sendMessage(prompt: string, title: string): Promise<CodeTaskMessageResult> {
    const body: CodeTaskWsMessageCommand = {
      type: 'message',
      prompt,
      title,
      autoApprove: false,
      timeoutSeconds: 1800,
    };
    const result = await this.sendCommand('message', body);
    return result as CodeTaskMessageResult;
  }

  async replyQuestion(
    requestId: string,
    answers: string[][],
    v2: boolean,
    reject: boolean = false,
  ): Promise<CodeTaskQuestionReplyResult> {
    const body: CodeTaskWsQuestionReplyCommand = {
      type: 'question_reply',
      requestId,
      answers,
      v2,
      reject,
    };
    const result = await this.sendCommand('question_reply', body);
    return result as CodeTaskQuestionReplyResult;
  }

  private async sendCommand(
    action: string,
    body: CodeTaskWsMessageCommand | CodeTaskWsQuestionReplyCommand,
  ): Promise<CodeTaskMessageResult | CodeTaskQuestionReplyResult> {
    if (this.closed) {
      throw new Error('任务连接已关闭。');
    }
    if (this.pendingAction.length > 0) {
      throw new Error('已有任务指令正在提交。');
    }
    await this.waitReady();
    return new Promise<CodeTaskMessageResult | CodeTaskQuestionReplyResult>((
      resolve: (value: CodeTaskMessageResult | CodeTaskQuestionReplyResult) => void,
      reject: (reason: Error) => void,
    ): void => {
      this.pendingAction = action;
      this.pendingResolve = resolve;
      this.pendingReject = reject;
      this.pendingTimer = setTimeout((): void => {
        this.rejectPending('主机端未确认任务指令。');
      }, MOBILE_TASK_CONNECT_TIMEOUT_MS);
      this.socket.send(JSON.stringify(body)).catch((error: Error | Object | string): void => {
        this.rejectPending(errorToString(error));
      });
    });
  }

  private async waitReady(): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      let settled = false;
      const timer = setTimeout((): void => {
        if (settled) {
          return;
        }
        settled = true;
        reject(new Error('任务 WebSocket 连接超时。'));
      }, MOBILE_TASK_WS_READY_TIMEOUT_MS);
      this.ready.then((): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve();
      }).catch((error: Error | Object | string): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        reject(new Error(errorToString(error)));
      });
    });
  }

  private handleMessage(data: string | ArrayBuffer): void {
    if (this.closed) {
      return;
    }
    const text = responseBodyToString(data, data instanceof ArrayBuffer ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING);
    if (text.length === 0) {
      return;
    }
    let envelope: WebSocketTaskEnvelope;
    try {
      envelope = parseJson<WebSocketTaskEnvelope>(text);
    } catch (error) {
      this.callbacks.onError(`任务 WebSocket 解析失败：${errorToString(error)}`);
      return;
    }
    if (envelope.type === 'task' && envelope.task !== undefined) {
      if (this.callbacks.onTask !== undefined) {
        this.callbacks.onTask(envelope.task);
      }
      return;
    }
    if (envelope.type === 'event') {
      const emptyPayload: CodeTaskEventPayload = {};
      const payload = envelope.payload === undefined ? emptyPayload : envelope.payload;
      this.callbacks.onEvent({
        seq: numberValue(envelope.seq, numberValue(payload.eventId, Date.now())),
        event: stringValue(envelope.event, 'log'),
        payload,
        createdAt: stringValue(envelope.createdAt, stringValue(payload.emittedAt, new Date().toISOString())),
      });
      return;
    }
    if (envelope.type === 'ack') {
      const emptyResult: CodeTaskMessageResult = {};
      this.resolvePending(stringValue(envelope.action), envelope.result === undefined ? emptyResult : envelope.result);
      return;
    }
    if (envelope.type === 'error') {
      const message = stringValue(envelope.message, '主机端任务连接错误。');
      this.callbacks.onError(message);
      this.rejectPending(message);
    }
  }

  private resolvePending(action: string, result: CodeTaskMessageResult | CodeTaskQuestionReplyResult): void {
    if (this.pendingAction.length === 0 || action !== this.pendingAction) {
      return;
    }
    const resolve = this.pendingResolve;
    this.clearPending();
    if (resolve !== undefined) {
      resolve(result);
    }
  }

  private rejectPending(message: string): void {
    if (this.pendingAction.length === 0) {
      return;
    }
    const reject = this.pendingReject;
    this.clearPending();
    if (reject !== undefined) {
      reject(new Error(message));
    }
  }

  private clearPending(): void {
    if (this.pendingTimer >= 0) {
      clearTimeout(this.pendingTimer);
      this.pendingTimer = -1;
    }
    this.pendingAction = '';
    this.pendingResolve = undefined;
    this.pendingReject = undefined;
  }
}

async function requestJson(
  settings: HostAgentSettings,
  path: string,
  method: http.RequestMethod,
  body?: Object,
  readTimeout: number = MOBILE_TASK_REQUEST_READ_TIMEOUT_MS,
): Promise<string> {
  const endpoint = `${resolveBaseUrl(settings)}${path}`;
  const request = http.createHttp();
  try {
    const response = await request.request(endpoint, {
      method,
      header: createHeaders(settings, 'application/json'),
      extraData: body === undefined ? undefined : JSON.stringify(body),
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: MOBILE_TASK_CONNECT_TIMEOUT_MS,
      readTimeout,
    });
    const responseBody = responseBodyToString(response.result, response.resultType);
    if (response.responseCode < 200 || response.responseCode > 299) {
      throw new Error(`HTTP ${response.responseCode} ${responseBody.substring(0, 240)}`);
    }
    return responseBody;
  } finally {
    request.destroy();
  }
}

function resolveBaseUrl(settings: HostAgentSettings): string {
  if (!settings.enabled) {
    throw new Error('远程主机未启用。');
  }
  const baseUrl = settings.baseUrl.trim();
  if (baseUrl.length === 0) {
    throw new Error('远程主机地址为空。');
  }
  if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
    throw new Error('远程主机地址必须以 http:// 或 https:// 开头。');
  }
  return trimEnd(baseUrl, '/');
}

function resolveWebSocketBaseUrl(settings: HostAgentSettings): string {
  const baseUrl = resolveBaseUrl(settings);
  if (baseUrl.startsWith('https://')) {
    return `wss://${baseUrl.substring('https://'.length)}`;
  }
  return `ws://${baseUrl.substring('http://'.length)}`;
}

function createHeaders(settings: HostAgentSettings, accept: string): CodeTaskHttpHeaderMap {
  const headers: CodeTaskHttpHeaderMap = {
    'Content-Type': 'application/json',
    'Accept': accept,
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
  };
  if (settings.apiKey.trim().length > 0) {
    headers.Authorization = `Bearer ${settings.apiKey.trim()}`;
  }
  return headers;
}

function cacheBustedPath(path: string): string {
  const separator = path.indexOf('?') >= 0 ? '&' : '?';
  return `${path}${separator}_=${Date.now()}`;
}

function consumeSseBuffer(buffer: string, callbacks: CodeTaskEventStreamCallbacks): string {
  let pending = buffer;
  let separatorIndex = pending.indexOf('\n\n');
  while (separatorIndex >= 0) {
    const block = pending.substring(0, separatorIndex);
    consumeSseBlock(block, callbacks);
    pending = pending.substring(separatorIndex + 2);
    separatorIndex = pending.indexOf('\n\n');
  }
  return pending;
}

function consumeSseBlock(block: string, callbacks: CodeTaskEventStreamCallbacks): void {
  const trimmed = block.trim();
  if (trimmed.length === 0) {
    return;
  }
  const lines = trimmed.split('\n');
  let eventName = 'message';
  const dataLines: string[] = [];
  lines.forEach((line: string): void => {
    if (line.startsWith('event:')) {
      eventName = line.substring(6).trim();
      return;
    }
    if (line.startsWith('data:')) {
      dataLines.push(line.substring(5).trim());
    }
  });
  if (dataLines.length === 0) {
    return;
  }
  const data = dataLines.join('\n');
  if (eventName === 'task') {
    const taskEnvelope = parseJson<SseTaskEnvelope>(data);
    if (taskEnvelope.task !== undefined && callbacks.onTask !== undefined) {
      callbacks.onTask(taskEnvelope.task);
    }
    return;
  }
  try {
    const payload = parseJson<CodeTaskEventPayload>(data);
    callbacks.onEvent({
      seq: numberValue(payload.eventId, Date.now()),
      event: eventName,
      payload,
      createdAt: stringValue(payload.emittedAt, new Date().toISOString()),
    });
  } catch (error) {
    callbacks.onError(`任务事件解析失败：${errorToString(error)}`);
  }
}

function parseJson<T>(body: string): T {
  return JSON.parse(body) as T;
}

function stringValue(value: string | undefined, fallback: string = ''): string {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }
  return fallback;
}

function numberValue(value: number | undefined, fallback: number): number {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  return fallback;
}

function trimEnd(value: string, char: string): string {
  let output = value;
  while (output.endsWith(char)) {
    output = output.substring(0, output.length - char.length);
  }
  return output;
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
