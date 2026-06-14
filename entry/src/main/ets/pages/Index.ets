import { common } from '@kit.AbilityKit';
import { buffer, util } from '@kit.ArkTS';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import {
  AppScreen,
  AttachmentKind,
  ChatMessage,
  ChatMode,
  ChatRecord,
  chatModeLabel,
  ComposerAttachment,
  ConfiguredModel,
  HostAgentSettings,
  ModelProviderPreset,
  ModelSettings,
  PersonaPreset,
  SettingsSheetMode,
  ToolShortcut,
  ToolPreview,
  VoiceBackend,
  VoiceSettings,
} from '../amaduse/model/AppModels';
import {
  defaultModelProvider,
  modelProviderPresets,
  toolShortcuts,
} from '../amaduse/data/AppSeedData';
import { defaultPersona } from '../amaduse/persona/PersonaPresets';
import {
  ChatPersistence,
  configuredModelToSettings,
  createNewChatRecord,
  defaultHostAgentSettings,
  defaultModelSettings,
  defaultVoiceSettings,
  makeConfiguredModel,
  updateRecordPreview,
} from '../amaduse/services/ChatPersistence';
import { ChatService } from '../amaduse/services/ChatService';
import {
  CodeTaskBridgeStream,
  CodeTaskDetail,
  CodeTaskEventPayload,
  CodeTaskEventRecord,
  CodeTaskMessageResult,
  CodeTaskMobileViewSnapshot,
  CodeTaskQuestionItem,
  CodeTaskQuestionOption,
  CodeTaskQuestionPayload,
  CodeTaskQuestionReplyResult,
  CodeTaskRemoteService,
  CodeTaskSnapshotMessage,
  CodeTaskSummary,
  CodeTaskViewMessage,
  CodeTaskViewPhase,
  CodeTaskViewQuestion,
  CodeTaskViewRecord,
  CodeTaskViewTurn,
} from '../amaduse/services/CodeTaskRemoteService';
import {
  VoicePlaybackCallbacks,
  VoiceService,
} from '../amaduse/services/VoiceService';
import {
  AgentToolCall,
  AgentToolResult,
} from '../amaduse/tools/AgentTools';
import { LocalToolService } from '../amaduse/tools/LocalToolService';
import {
  createId,
  currentTimeText,
  extractEmotion,
  splitForStreaming,
  stripEmotionTagsForDisplay,
} from '../amaduse/services/AppUtils';

const INK_BLACK = '#0B0B0C';
const INK_WHITE = '#FAFAFA';
const PAPER = '#F7F7F5';
const MIST = '#EFEFED';
const LINE = '#1A000000';
const GLASS_LIGHT = '#EAFBFBFB';
const GLASS_MUTED = '#CFEFF3F2';
const AGENT_BUBBLE = '#9EFFFFFF';
const USER_BUBBLE = '#B8FFFFFF';
const CHAT_ACTION_BG = '#C8FFFFFF';
const DIM_OVERLAY = '#52000000';
const ACTIVE_GREEN = '#35D07F';
const BLUE = '#4D8CFF';
const DANGER = '#F44336';
const TEXT_SCAN_STEPS = 84;
const TEXT_SCAN_FRAME_MS = 50;
const TEXT_SCAN_BACKGROUND_SCALE = 2.2;
const AGENT_MESSAGE_MAX_WIDTH = 324;
const AGENT_MESSAGE_TEXT_MAX_WIDTH = 298;
const USER_MESSAGE_MAX_WIDTH = 308;
const HOST_TRANSFER_CONNECT_TIMEOUT_MS = 30000;
const HOST_TRANSFER_READ_TIMEOUT_MS = 600000;
const HOST_UPLOAD_CACHE_DIR = 'amaduse_uploads';
const HOST_UPLOAD_MAX_BYTES = 50 * 1024 * 1024;
const HOST_HISTORY_FILE_DIR = 'host_agent_docs';
const HISTORY_FILE_TEXT_PREVIEW_BYTES = 512 * 1024;
const HISTORY_FILE_BINARY_PREVIEW_BYTES = 96;
const CODE_TASK_REOPEN_REFRESH_DELAY_MS = 900;
const CODE_TASK_REOPEN_REFRESH_RETRY_MS = 2200;
const CODE_TASK_LIST_REFRESH_INTERVAL_MS = 10000;
const CODE_TASK_BRIDGE_HEARTBEAT_MS = 12000;
const PAGE_SLIDE_WIDTH = 420;
const TRANSCRIPT_COLLAPSED_PERCENT = 36;
const TRANSCRIPT_EXPANDED_PERCENT = 84;
const TRANSCRIPT_DRAG_RANGE = 360;
const START_RECORD: ChatRecord = createNewChatRecord();

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve: () => void) => {
    setTimeout(resolve, milliseconds);
  });
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

function stringValue(value: string | undefined, fallback: string = ''): string {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }
  return fallback;
}

function appendThinkingEntry(current: string, entry: string): string {
  const prefix = current.trim().length > 0 ? `${current.trimEnd()}\n` : '';
  return `${prefix}${entry}`;
}

function toolResultThinkingSummary(summary: string): string {
  if (summary.length <= 140) {
    return summary;
  }
  return `已返回正文，长度 ${summary.length} 字。`;
}

function toolPreviewDetail(summary: string): string {
  if (summary.length <= 180) {
    return summary;
  }
  return `${summary.substring(0, 180)}...`;
}

interface HostToolResultPreview {
  target?: string;
  summary?: string;
  mobileFile?: HostMobileFilePreview;
  request?: HostToolRequestPreview;
  response?: HostBackendResultPreview;
}

interface HostToolRequestPreview {
  target?: string;
  payload?: HostToolRequestPayloadPreview;
}

interface HostToolRequestPayloadPreview {
  query?: string;
  path?: string;
  action?: string;
}

interface HostBackendResultPreview {
  summary?: string;
  data?: HostBackendDataPreview;
}

interface HostBackendDataPreview {
  tool?: string;
  result?: HostToolGenericResultPreview;
}

interface HostToolGenericResultPreview extends WebSearchResultPreview {
  agent?: string;
  action?: string;
  path?: string;
  type?: string;
  content?: string;
  encoding?: string;
  mimeType?: string;
  sizeBytes?: number;
  lineCount?: number;
  totalLineCount?: number;
  truncated?: boolean;
  entries?: FileReaderEntryPreview[];
  skipped?: number;
  title?: string;
  format?: string;
  saved?: boolean;
  outputPath?: string;
  absolutePath?: string;
  byteCount?: number;
  tasks?: TodoTaskPreview[];
  task?: TodoTaskPreview;
  counts?: TodoCountsPreview;
  totalMatched?: number;
  deletedIds?: string[];
}

interface HostMobileFilePreview {
  path?: string;
  uri?: string;
  storage?: string;
  fileName?: string;
  mimeType?: string;
  sizeBytes?: number;
  sourcePath?: string;
  note?: string;
  error?: string;
}

interface FileReaderEntryPreview {
  path?: string;
  name?: string;
  type?: string;
  sizeBytes?: number;
  modifiedAt?: string;
}

interface TodoTaskPreview {
  id?: string;
  title?: string;
  description?: string;
  status?: string;
  priority?: string;
  dueAt?: string;
  project?: string;
  tags?: string[];
}

interface TodoCountsPreview {
  total?: number;
  active?: number;
  completed?: number;
  blocked?: number;
  archived?: number;
}

interface UploadHostFilePreview {
  originalFilename?: string;
  filename?: string;
  path?: string;
  contentType?: string;
  sizeBytes?: number;
  readableByFileReader?: boolean;
}

interface UploadHostDataPreview {
  file?: UploadHostFilePreview;
}

interface UploadHostResponsePreview {
  ok?: boolean;
  summary?: string;
  file?: UploadHostFilePreview;
  data?: UploadHostDataPreview;
  detail?: string;
}

interface UploadHttpHeaderMap {
  'Content-Type': string;
  'Accept': string;
  'Authorization'?: string;
}

interface UploadFileBase64Payload {
  filename: string;
  contentType: string;
  dataBase64: string;
  device: string;
  overwrite: boolean;
}

interface LocalHistoryFile {
  id: string;
  name: string;
  path: string;
  sizeBytes: number;
  modifiedEpoch: number;
  modifiedAt: string;
  extension: string;
  kind: string;
  previewable: boolean;
}

interface CodeTaskQuestionDraft {
  index: number;
  selected: string[];
  custom: string;
}

interface CodeTaskConversationTurn {
  id: string;
  request: CodeTaskEventRecord;
  hasRequest: boolean;
  events: CodeTaskEventRecord[];
  running: boolean;
  completed: boolean;
  errored: boolean;
}

interface CodeTaskProcessPhase {
  id: string;
  title: string;
  status: string;
  events: CodeTaskEventRecord[];
}

interface WebSearchResultPreview {
  query?: string;
  answer?: string;
  results?: WebSearchItemPreview[];
  warnings?: WebSearchWarningPreview[];
}

interface WebSearchItemPreview {
  title?: string;
  url?: string;
  domain?: string;
  sourceType?: string;
  snippet?: string;
  contentSummary?: string;
  fetchStatus?: string;
  evidence?: WebSearchEvidencePreview[];
}

interface WebSearchEvidencePreview {
  quote?: string;
}

interface WebSearchWarningPreview {
  message?: string;
}

interface MarkdownBlock {
  kind: string;
  text: string;
  level: number;
}

interface MarkdownInlinePart {
  text: string;
  strong: boolean;
  code: boolean;
}

interface MarkdownSpanPart {
  text: string;
  kind: string;
  strong: boolean;
  code: boolean;
  segmentIndex: number;
}

function toolResultThinkingContent(result: AgentToolResult): string {
  const webSearchDetails = webSearchToolResultDetails(result);
  if (webSearchDetails.length > 0) {
    return webSearchDetails;
  }
  const hostToolDetails = hostAgentToolResultDetails(result);
  if (hostToolDetails.length > 0) {
    return hostToolDetails;
  }
  return toolResultThinkingSummary(result.summary);
}

function toolPreviewDetailForResult(result: AgentToolResult): string {
  const webSearchSummary = webSearchToolPreviewDetail(result);
  if (webSearchSummary.length > 0) {
    return webSearchSummary;
  }
  const hostToolSummary = hostAgentToolPreviewDetail(result);
  if (hostToolSummary.length > 0) {
    return hostToolSummary;
  }
  return toolPreviewDetail(result.summary);
}

function webSearchToolResultDetails(result: AgentToolResult): string {
  const searchResult = hostWebSearchResult(result);
  if (searchResult === undefined) {
    return '';
  }
  const results = searchResult.results === undefined ? [] : searchResult.results;
  const query = stringValue(searchResult.query, '当前问题');
  const fetchedCount = results.filter((item: WebSearchItemPreview): boolean => {
    return stringValue(item.fetchStatus) === 'ok';
  }).length;
  const lines: string[] = [
    `已检索“${query}”，返回 ${results.length} 个候选来源${fetchedCount > 0 ? `，已读取 ${fetchedCount} 个网页正文` : ''}。`,
  ];

  const count = Math.min(10, results.length);
  for (let index = 0; index < count; index += 1) {
    const item = results[index];
    const title = stringValue(item.title, stringValue(item.url, '未命名来源'));
    const url = stringValue(item.url, stringValue(item.domain));
    const sourceType = stringValue(item.sourceType, 'unknown');
    const evidence = item.evidence === undefined ? [] : item.evidence;
    const evidenceText = evidence.length > 0 ? stringValue(evidence[0].quote) : '';
    const detail = truncateToolDetail(stringValue(evidenceText,
      stringValue(item.contentSummary, stringValue(item.snippet))), 180);
    lines.push(`${index + 1}. ${title}（${sourceType}）${url.length > 0 ? `：${url}` : ''}`);
    if (detail.length > 0) {
      lines.push(`   ${detail}`);
    }
  }

  const warnings = searchResult.warnings === undefined ? [] : searchResult.warnings;
  if (warnings.length > 0) {
    const warningText = warnings
      .map((item: WebSearchWarningPreview): string => stringValue(item.message))
      .filter((item: string): boolean => item.length > 0)
      .slice(0, 3)
      .join('；');
    if (warningText.length > 0) {
      lines.push(`风险提示：${warningText}`);
    }
  }
  return lines.join('\n');
}

function webSearchToolPreviewDetail(result: AgentToolResult): string {
  const searchResult = hostWebSearchResult(result);
  if (searchResult === undefined) {
    return '';
  }
  const results = searchResult.results === undefined ? [] : searchResult.results;
  const fetchedCount = results.filter((item: WebSearchItemPreview): boolean => {
    return stringValue(item.fetchStatus) === 'ok';
  }).length;
  return `已返回 ${results.length} 个候选来源${fetchedCount > 0 ? `，读取正文 ${fetchedCount}/${results.length}` : ''}。展开调用结果查看。`;
}

function hostAgentToolResultDetails(result: AgentToolResult): string {
  const payload = parseHostToolResultPreview(result.content);
  if (payload === undefined || isWebSearchToolPayload(payload)) {
    return '';
  }
  const tool = hostToolName(payload);
  const output = payload.response?.data?.result;
  if (tool === 'todo_task') {
    return todoToolResultDetails(payload, output);
  }
  if (tool === 'file_reader') {
    return fileReaderToolResultDetails(payload, output);
  }
  if (tool === 'doc_writer' || output?.agent === 'doc_writer_agent') {
    return docWriterToolResultDetails(payload, output);
  }
  return '';
}

function hostAgentToolPreviewDetail(result: AgentToolResult): string {
  const payload = parseHostToolResultPreview(result.content);
  if (payload === undefined || isWebSearchToolPayload(payload)) {
    return '';
  }
  const tool = hostToolName(payload);
  const output = payload.response?.data?.result;
  if (tool === 'todo_task') {
    const tasks = todoTasksForPreview(output);
    const action = stringValue(output?.action, stringValue(payload.request?.payload?.action));
    return `todo_task ${action.length > 0 ? action : '执行'} 完成${tasks.length > 0 ? `，涉及 ${tasks.length} 个任务` : ''}。展开调用结果查看。`;
  }
  if (tool === 'file_reader') {
    const action = stringValue(output?.action, stringValue(payload.request?.payload?.action));
    const path = stringValue(output?.path, stringValue(payload.request?.payload?.path));
    return `file_reader ${action.length > 0 ? action : '执行'} ${path.length > 0 ? path : ''} 完成。展开调用结果查看。`;
  }
  if (tool === 'doc_writer' || output?.agent === 'doc_writer_agent') {
    const path = stringValue(output?.outputPath);
    const mobilePath = stringValue(payload.mobileFile?.path);
    if (mobilePath.length > 0) {
      return `doc_writer 已生成并保存到移动端。展开调用结果查看。`;
    }
    return `doc_writer 已生成${path.length > 0 ? ` ${path}` : ''}。展开调用结果查看。`;
  }
  return '';
}

function todoToolResultDetails(payload: HostToolResultPreview, output: HostToolGenericResultPreview | undefined): string {
  const lines: string[] = [];
  lines.push(`todo_task：${stringValue(output?.action, stringValue(payload.request?.payload?.action, '执行'))}`);
  const summary = stringValue(payload.response?.summary, stringValue(payload.summary));
  if (summary.length > 0) {
    lines.push(`摘要：${summary}`);
  }
  const counts = output?.counts;
  if (counts !== undefined) {
    lines.push(`计数：total=${numberText(counts.total)} active=${numberText(counts.active)} completed=${numberText(counts.completed)} blocked=${numberText(counts.blocked)} archived=${numberText(counts.archived)}`);
  }
  const tasks = todoTasksForPreview(output);
  if (tasks.length > 0) {
    lines.push('任务：');
    tasks.slice(0, 12).forEach((task: TodoTaskPreview, index: number) => {
      const meta: string[] = [];
      appendIfPresent(meta, stringValue(task.status));
      appendIfPresent(meta, stringValue(task.priority));
      appendIfPresent(meta, stringValue(task.dueAt));
      appendIfPresent(meta, stringValue(task.project));
      lines.push(`${index + 1}. ${stringValue(task.title, stringValue(task.id, '未命名任务'))}${meta.length > 0 ? `（${meta.join(' · ')}）` : ''}`);
      const desc = truncateToolDetail(stringValue(task.description), 140);
      if (desc.length > 0) {
        lines.push(`   ${desc}`);
      }
    });
  }
  const deletedIds = output?.deletedIds === undefined ? [] : output.deletedIds;
  if (deletedIds.length > 0) {
    lines.push(`已删除：${deletedIds.join(', ')}`);
  }
  return lines.join('\n');
}

function fileReaderToolResultDetails(payload: HostToolResultPreview, output: HostToolGenericResultPreview | undefined): string {
  const lines: string[] = [];
  const action = stringValue(output?.action, stringValue(payload.request?.payload?.action, 'read'));
  const path = stringValue(output?.path, stringValue(payload.request?.payload?.path));
  lines.push(`file_reader：${action}${path.length > 0 ? ` · ${path}` : ''}`);
  const summary = stringValue(payload.response?.summary, stringValue(payload.summary));
  if (summary.length > 0) {
    lines.push(`摘要：${summary}`);
  }
  if (output === undefined) {
    return lines.join('\n');
  }
  if (action === 'list') {
    const entries = output.entries === undefined ? [] : output.entries;
    lines.push(`条目：${entries.length}${output.skipped !== undefined && output.skipped > 0 ? `，跳过 ${output.skipped}` : ''}`);
    entries.slice(0, 30).forEach((entry: FileReaderEntryPreview, index: number) => {
      lines.push(`${index + 1}. ${stringValue(entry.type, 'file')} · ${stringValue(entry.path, stringValue(entry.name, '未命名'))}${entry.sizeBytes !== undefined ? ` · ${entry.sizeBytes} bytes` : ''}`);
    });
    return lines.join('\n');
  }
  if (action === 'stat') {
    lines.push(`类型：${stringValue(output.type)}；大小：${numberText(output.sizeBytes)} bytes；MIME：${stringValue(output.mimeType)}`);
    return lines.join('\n');
  }
  lines.push(`行数：${numberText(output.lineCount)}/${numberText(output.totalLineCount)}；大小：${numberText(output.sizeBytes)} bytes；编码：${stringValue(output.encoding)}；truncated=${output.truncated === true ? 'true' : 'false'}`);
  const content = stringValue(output.content);
  if (content.length > 0) {
    lines.push('内容：');
    lines.push(truncateToolDetail(content, 6000));
  }
  return lines.join('\n');
}

function docWriterToolResultDetails(payload: HostToolResultPreview, output: HostToolGenericResultPreview | undefined): string {
  const lines: string[] = [];
  lines.push(`doc_writer：${stringValue(output?.title, '文档')}${output?.format !== undefined ? ` · ${output.format}` : ''}`);
  const summary = stringValue(payload.response?.summary, stringValue(payload.summary));
  if (summary.length > 0) {
    lines.push(`摘要：${summary}`);
  }
  const outputPath = stringValue(output?.outputPath);
  if (outputPath.length > 0) {
    lines.push(`主机路径：${outputPath}`);
  }
  const mobileFile = payload.mobileFile;
  if (mobileFile !== undefined) {
    if (stringValue(mobileFile.path).length > 0) {
      const storage = stringValue(mobileFile.storage);
      const label = storage === 'files' ? '手机文件' : '应用沙箱';
      lines.push(`${label}：${stringValue(mobileFile.path)}（${numberText(mobileFile.sizeBytes)} bytes）`);
      const note = stringValue(mobileFile.note);
      if (note.length > 0) {
        lines.push(`说明：${note}`);
      }
    } else if (stringValue(mobileFile.error).length > 0) {
      lines.push(`移动端保存失败：${mobileFile.error}`);
    }
  }
  if (output?.byteCount !== undefined) {
    lines.push(`主机文件大小：${output.byteCount} bytes`);
  }
  const content = stringValue(output?.content);
  if (content.length > 0) {
    lines.push('文档正文预览：');
    lines.push(truncateToolDetail(content, 4000));
  }
  return lines.join('\n');
}

function hostWebSearchResult(result: AgentToolResult): WebSearchResultPreview | undefined {
  const payload = parseHostToolResultPreview(result.content);
  if (payload === undefined || !isWebSearchToolPayload(payload)) {
    return undefined;
  }
  return payload.response?.data?.result;
}

function parseHostToolResultPreview(content: string): HostToolResultPreview | undefined {
  try {
    return JSON.parse(content) as HostToolResultPreview;
  } catch (_) {
    return undefined;
  }
}

function isWebSearchToolPayload(payload: HostToolResultPreview): boolean {
  const tool = stringValue(payload.response?.data?.tool);
  if (tool === 'web_search') {
    return true;
  }
  const targetText = `${stringValue(payload.target)} ${stringValue(payload.request?.target)}`.toLowerCase();
  return targetText.indexOf('web_search') >= 0;
}

function hostToolName(payload: HostToolResultPreview): string {
  const tool = stringValue(payload.response?.data?.tool).toLowerCase();
  if (tool.length > 0) {
    return tool;
  }
  const targetText = `${stringValue(payload.target)} ${stringValue(payload.request?.target)}`.toLowerCase();
  if (targetText.indexOf('todo_task') >= 0) {
    return 'todo_task';
  }
  if (targetText.indexOf('file_reader') >= 0) {
    return 'file_reader';
  }
  if (targetText.indexOf('doc_writer') >= 0) {
    return 'doc_writer';
  }
  return targetText;
}

function todoTasksForPreview(output: HostToolGenericResultPreview | undefined): TodoTaskPreview[] {
  if (output === undefined) {
    return [];
  }
  if (output.tasks !== undefined && output.tasks.length > 0) {
    return output.tasks;
  }
  if (output.task !== undefined) {
    return [output.task];
  }
  return [];
}

function appendIfPresent(parts: string[], value: string): void {
  if (value.length > 0) {
    parts.push(value);
  }
}

function numberText(value: number | undefined): string {
  if (value === undefined) {
    return '0';
  }
  return `${value}`;
}

function truncateToolDetail(value: string, limit: number): string {
  if (value.length <= limit) {
    return value;
  }
  return `${value.substring(0, limit - 1)}...`;
}

function isMarkdownSpecialLine(line: string): boolean {
  const trimmed = line.trim();
  return trimmed.startsWith('```') ||
    trimmed.startsWith('#') ||
    trimmed.startsWith('>') ||
    trimmed.startsWith('- ') ||
    trimmed.startsWith('* ') ||
    /^\d+\.\s+/.test(trimmed);
}

@Component
struct Live2dSurface {
  controller: webview.WebviewController = new webview.WebviewController();
  private baseUrl: string = 'http://amaduse.local';

  build() {
    Web({
      src: `${this.baseUrl}/live2d_viewer.html`,
      controller: this.controller,
    })
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .fileAccess(true)
      .imageAccess(true)
      .zoomAccess(false)
      .darkMode(WebDarkMode.Off)
      .forceDarkAccess(false)
      .javaScriptProxy({
        object: {
          onCanvasPending: (): void => {
            console.info('[AmaduseLive2D] canvas pending');
          },
          onCanvasReady: (): void => {
            console.info('[AmaduseLive2D] canvas ready');
          },
          onCanvasError: (message: string): void => {
            console.error(`[AmaduseLive2D] ${message}`);
          },
        },
        name: 'AmaduseAndroid',
        methodList: ['onCanvasPending', 'onCanvasReady', 'onCanvasError'],
        controller: this.controller,
      })
      .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse => {
        return this.interceptResource(event);
      })
      .onConsole((event: OnConsoleEvent): boolean => {
        console.info(`[AmaduseLive2D] ${event.message.getMessage()}`);
        return false;
      })
      .onErrorReceive((event: OnErrorReceiveEvent) => {
        console.error(`[AmaduseLive2D] resource error: ${event.request.getRequestUrl()}`);
      })
      .width('100%')
      .height('100%')
      .backgroundColor('#F0F5F6')
  }

  private interceptResource(event: OnInterceptRequestEvent): WebResourceResponse {
    const requestUrl = event.request.getRequestUrl();
    let relativePath = requestUrl;
    if (relativePath.startsWith(this.baseUrl)) {
      relativePath = relativePath.substring(this.baseUrl.length);
    }
    const rawfileMarker = '/rawfile/';
    const rawfileStart = relativePath.indexOf(rawfileMarker);
    if (rawfileStart >= 0) {
      relativePath = relativePath.substring(rawfileStart + rawfileMarker.length);
    }
    const rawfileScheme = 'resource://rawfile/';
    if (relativePath.startsWith(rawfileScheme)) {
      relativePath = relativePath.substring(rawfileScheme.length);
    }
    if (relativePath.startsWith('/')) {
      relativePath = relativePath.substring(1);
    }
    const queryStart = relativePath.indexOf('?');
    if (queryStart >= 0) {
      relativePath = relativePath.substring(0, queryStart);
    }
    const hashStart = relativePath.indexOf('#');
    if (hashStart >= 0) {
      relativePath = relativePath.substring(0, hashStart);
    }
    if (relativePath.length === 0) {
      relativePath = 'live2d_viewer.html';
    }

    const response = new WebResourceResponse();
    try {
      response.setResponseData($rawfile(relativePath));
      response.setResponseMimeType(this.mimeTypeForPath(relativePath));
      response.setResponseEncoding(this.encodingForPath(relativePath));
      response.setResponseCode(200);
      response.setReasonMessage('OK');
    } catch (error) {
      response.setResponseData(this.errorHtml(relativePath, errorToString(error)));
      response.setResponseMimeType('text/html');
      response.setResponseEncoding('utf-8');
      response.setResponseCode(404);
      response.setReasonMessage('Not Found');
    }
    return response;
  }

  private mimeTypeForPath(path: string): string {
    const lower = path.toLowerCase();
    if (lower.endsWith('.html')) {
      return 'text/html';
    }
    if (lower.endsWith('.js')) {
      return 'text/javascript';
    }
    if (lower.endsWith('.json')) {
      return 'application/json';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.moc3')) {
      return 'application/octet-stream';
    }
    if (lower.endsWith('.mp3')) {
      return 'audio/mpeg';
    }
    return 'application/octet-stream';
  }

  private encodingForPath(path: string): string {
    const lower = path.toLowerCase();
    if (lower.endsWith('.moc3') || lower.endsWith('.png') || lower.endsWith('.mp3')) {
      return 'binary';
    }
    return 'utf-8';
  }

  private errorHtml(path: string, detail: string): string {
    return `<!doctype html><html><body style="margin:0;background:#f0f5f6;color:#0b0b0c;font:14px system-ui;padding:16px;">Live2D resource failed: ${path}<br>${detail}</body></html>`;
  }
}

@Component
struct CyclingMessageText {
  @Prop text: string = '';
  @Prop ageLevel: number = 0;
  @Prop isUser: boolean = false;
  @State private scanStep: number = 0;
  private cycleTimer: number = -1;

  aboutToAppear(): void {
    if (this.cycleTimer >= 0) {
      return;
    }
    this.cycleTimer = setInterval(() => {
      this.scanStep = (this.scanStep + 1) % TEXT_SCAN_STEPS;
    }, TEXT_SCAN_FRAME_MS);
  }

  aboutToDisappear(): void {
    if (this.cycleTimer >= 0) {
      clearInterval(this.cycleTimer);
      this.cycleTimer = -1;
    }
  }

  build() {
    Text() {
      ForEach(this.textSegmentIndexes(), (segmentIndex: number) => {
        Span(this.textSegment(segmentIndex))
          .fontSize(16)
          .fontColor(this.segmentColor(segmentIndex))
      }, (segmentIndex: number) => `${segmentIndex}`)
    }
    .lineHeight(24)
  }

  private textSegmentCount(): number {
    const segmentSize = this.textSegmentSize();
    const count = Math.ceil(this.text.length / segmentSize);
    return count > 0 ? count : 1;
  }

  private textSegmentSize(): number {
    return 2;
  }

  private textSegmentIndexes(): number[] {
    const indexes: number[] = [];
    const count = this.textSegmentCount();
    for (let index = 0; index < count; index += 1) {
      indexes.push(index);
    }
    return indexes;
  }

  private textSegment(segmentIndex: number): string {
    const segmentSize = this.textSegmentSize();
    const start = segmentIndex * segmentSize;
    const end = Math.min(this.text.length, start + segmentSize);
    return this.text.substring(start, end);
  }

  private segmentColor(segmentIndex: number): string {
    const count = this.textSegmentCount();
    const positionRatio = count <= 1 ? 0 : segmentIndex / (count - 1);
    const scanRatio = this.scanStep / TEXT_SCAN_STEPS;
    let sample = positionRatio * TEXT_SCAN_BACKGROUND_SCALE - scanRatio * TEXT_SCAN_BACKGROUND_SCALE;
    sample = sample - Math.floor(sample);
    const brightness = this.sampleBrightness(sample) + this.ageLevel * 18;
    return this.grayColor(brightness);
  }

  private sampleBrightness(sample: number): number {
    if (this.isUser) {
      if (sample <= 0.28) {
        return this.interpolate(17, 69, sample / 0.28);
      }
      if (sample <= 0.50) {
        return this.interpolate(69, 154, (sample - 0.28) / 0.22);
      }
      if (sample <= 0.76) {
        return this.interpolate(154, 17, (sample - 0.50) / 0.26);
      }
      return this.interpolate(17, 103, (sample - 0.76) / 0.24);
    }
    if (sample <= 0.22) {
      return this.interpolate(17, 61, sample / 0.22);
    }
    if (sample <= 0.42) {
      return this.interpolate(61, 155, (sample - 0.22) / 0.20);
    }
    if (sample <= 0.62) {
      return this.interpolate(155, 17, (sample - 0.42) / 0.20);
    }
    if (sample <= 0.82) {
      return this.interpolate(17, 108, (sample - 0.62) / 0.20);
    }
    return this.interpolate(108, 17, (sample - 0.82) / 0.18);
  }

  private interpolate(start: number, end: number, progress: number): number {
    return start + (end - start) * progress;
  }

  private grayColor(brightness: number): string {
    const bounded = Math.max(17, Math.min(168, Math.round(brightness)));
    const hex = this.hexByte(bounded);
    return `#${hex}${hex}${hex}`;
  }

  private hexByte(value: number): string {
    const digits = '0123456789ABCDEF';
    const high = Math.floor(value / 16);
    const low = value - high * 16;
    return `${digits.charAt(high)}${digits.charAt(low)}`;
  }
}

@Component
struct MarkdownMessageText {
  @Prop text: string = '';
  @Prop ageLevel: number = 0;
  @State private scanStep: number = 0;
  private cycleTimer: number = -1;

  aboutToAppear(): void {
    if (this.cycleTimer >= 0) {
      return;
    }
    this.cycleTimer = setInterval(() => {
      this.scanStep = (this.scanStep + 1) % TEXT_SCAN_STEPS;
    }, TEXT_SCAN_FRAME_MS);
  }

  aboutToDisappear(): void {
    if (this.cycleTimer >= 0) {
      clearInterval(this.cycleTimer);
      this.cycleTimer = -1;
    }
  }

  build() {
    Text() {
      ForEach(this.markdownSpanParts(), (part: MarkdownSpanPart, index: number) => {
        Span(part.text)
          .fontSize(this.spanSize(part))
          .fontColor(this.segmentColor(part.segmentIndex, part))
          .fontWeight(part.strong || part.kind === 'heading' ? FontWeight.Bold : FontWeight.Normal)
      }, (_part: MarkdownSpanPart, index: number) => `${index}`)
    }
    .constraintSize({ maxWidth: AGENT_MESSAGE_TEXT_MAX_WIDTH })
    .lineHeight(24)
  }

  private markdownBlocks(): MarkdownBlock[] {
    const blocks: MarkdownBlock[] = [];
    const lines = this.text.replace(/\r\n/g, '\n').split('\n');
    let inCode = false;
    let codeLines: string[] = [];
    let paragraphLines: string[] = [];

    const flushParagraph = (): void => {
      if (paragraphLines.length === 0) {
        return;
      }
      blocks.push({
        kind: 'paragraph',
        text: paragraphLines.join(' '),
        level: 0,
      });
      paragraphLines = [];
    };

    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      const trimmed = line.trim();
      if (trimmed.startsWith('```')) {
        if (inCode) {
          blocks.push({
            kind: 'code',
            text: codeLines.join('\n'),
            level: 0,
          });
          codeLines = [];
          inCode = false;
        } else {
          flushParagraph();
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        codeLines.push(line);
        continue;
      }
      if (trimmed.length === 0) {
        flushParagraph();
        if (blocks.length > 0 && blocks[blocks.length - 1].kind !== 'space') {
          blocks.push({ kind: 'space', text: '', level: 0 });
        }
        continue;
      }
      if (trimmed.startsWith('#')) {
        flushParagraph();
        const level = this.headingLevel(trimmed);
        if (level > 0) {
          blocks.push({
            kind: 'heading',
            text: trimmed.substring(level).trim(),
            level,
          });
          continue;
        }
      }
      if (trimmed.startsWith('>')) {
        flushParagraph();
        blocks.push({
          kind: 'quote',
          text: trimmed.substring(1).trim(),
          level: 0,
        });
        continue;
      }
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        flushParagraph();
        blocks.push({
          kind: 'list',
          text: `• ${trimmed.substring(2).trim()}`,
          level: 0,
        });
        continue;
      }
      const ordered = /^(\d+)\.\s+(.+)$/.exec(trimmed);
      if (ordered !== null && ordered.length >= 3) {
        flushParagraph();
        blocks.push({
          kind: 'list',
          text: `${ordered[1]}. ${ordered[2]}`,
          level: 0,
        });
        continue;
      }
      if (isMarkdownSpecialLine(trimmed)) {
        flushParagraph();
        blocks.push({
          kind: 'paragraph',
          text: trimmed,
          level: 0,
        });
        continue;
      }
      paragraphLines.push(trimmed);
    }
    if (inCode && codeLines.length > 0) {
      blocks.push({
        kind: 'code',
        text: codeLines.join('\n'),
        level: 0,
      });
    }
    flushParagraph();
    return blocks.length > 0 ? blocks : [{ kind: 'paragraph', text: this.text, level: 0 }];
  }

  private inlineParts(value: string): MarkdownInlinePart[] {
    const parts: MarkdownInlinePart[] = [];
    let cursor = 0;
    while (cursor < value.length) {
      const codeStart = value.indexOf('`', cursor);
      const strongStart = value.indexOf('**', cursor);
      let next = -1;
      let marker = '';
      if (codeStart >= 0 && (strongStart < 0 || codeStart < strongStart)) {
        next = codeStart;
        marker = '`';
      } else if (strongStart >= 0) {
        next = strongStart;
        marker = '**';
      }
      if (next < 0) {
        parts.push({ text: value.substring(cursor), strong: false, code: false });
        break;
      }
      if (next > cursor) {
        parts.push({ text: value.substring(cursor, next), strong: false, code: false });
      }
      const end = value.indexOf(marker, next + marker.length);
      if (end < 0) {
        parts.push({ text: value.substring(next), strong: false, code: false });
        break;
      }
      parts.push({
        text: value.substring(next + marker.length, end),
        strong: marker === '**',
        code: marker === '`',
      });
      cursor = end + marker.length;
    }
    return parts.filter((part: MarkdownInlinePart): boolean => part.text.length > 0);
  }

  private markdownSpanParts(): MarkdownSpanPart[] {
    const output: MarkdownSpanPart[] = [];
    const blocks = this.markdownBlocks();
    let segmentIndex = 0;
    const appendPart = (text: string, kind: string, strong: boolean, code: boolean): void => {
      const segmentSize = this.textSegmentSize();
      let cursor = 0;
      while (cursor < text.length) {
        const next = Math.min(text.length, cursor + segmentSize);
        output.push({
          text: text.substring(cursor, next),
          kind,
          strong,
          code,
          segmentIndex,
        });
        segmentIndex += 1;
        cursor = next;
      }
    };

    for (let index = 0; index < blocks.length; index += 1) {
      const block = blocks[index];
      if (block.kind === 'space') {
        appendPart('\n', 'space', false, false);
        continue;
      }
      if (index > 0 && output.length > 0 && !output[output.length - 1].text.endsWith('\n')) {
        appendPart('\n', 'break', false, false);
      }
      if (block.kind === 'code') {
        appendPart(block.text, 'code', false, true);
      } else {
        const inline = this.inlineParts(block.text);
        inline.forEach((part: MarkdownInlinePart) => {
          appendPart(part.text, block.kind, part.strong, part.code);
        });
      }
      if (index < blocks.length - 1) {
        appendPart('\n', 'break', false, false);
      }
    }
    return output.length > 0 ? output : [{ text: this.text, kind: 'paragraph', strong: false, code: false, segmentIndex: 0 }];
  }

  private headingLevel(value: string): number {
    let level = 0;
    while (level < value.length && value.charAt(level) === '#') {
      level += 1;
    }
    if (level === 0 || level > 6 || value.charAt(level) !== ' ') {
      return 0;
    }
    return level;
  }

  private headingSize(level: number): number {
    if (level <= 1) {
      return 20;
    }
    if (level === 2) {
      return 18;
    }
    return 16;
  }

  private spanSize(part: MarkdownSpanPart): number {
    if (part.kind === 'heading') {
      return 17;
    }
    if (part.kind === 'code') {
      return 13;
    }
    if (part.kind === 'quote' || part.kind === 'list') {
      return 15;
    }
    return 16;
  }

  private segmentColor(segmentIndex: number, part: MarkdownSpanPart): string {
    const count = this.markdownSegmentCount();
    const positionRatio = count <= 1 ? 0 : segmentIndex / (count - 1);
    const scanRatio = this.scanStep / TEXT_SCAN_STEPS;
    let sample = positionRatio * TEXT_SCAN_BACKGROUND_SCALE - scanRatio * TEXT_SCAN_BACKGROUND_SCALE;
    sample = sample - Math.floor(sample);
    const brightness = this.sampleBrightness(sample) + this.ageLevel * 18 + this.kindBrightnessOffset(part);
    return this.grayColor(brightness);
  }

  private markdownSegmentCount(): number {
    const segmentSize = this.textSegmentSize();
    const count = Math.ceil(this.text.length / segmentSize);
    return count > 0 ? count : 1;
  }

  private textSegmentSize(): number {
    return 2;
  }

  private sampleBrightness(sample: number): number {
    if (sample <= 0.28) {
      return this.interpolate(17, 69, sample / 0.28);
    }
    if (sample <= 0.50) {
      return this.interpolate(69, 154, (sample - 0.28) / 0.22);
    }
    if (sample <= 0.76) {
      return this.interpolate(154, 17, (sample - 0.50) / 0.26);
    }
    return this.interpolate(17, 103, (sample - 0.76) / 0.24);
  }

  private kindBrightnessOffset(part: MarkdownSpanPart): number {
    if (part.kind === 'quote') {
      return 18;
    }
    if (part.kind === 'code') {
      return 8;
    }
    return 0;
  }

  private interpolate(start: number, end: number, progress: number): number {
    return start + (end - start) * progress;
  }

  private grayColor(brightness: number): string {
    const bounded = Math.max(17, Math.min(168, Math.round(brightness)));
    const digits = '0123456789ABCDEF';
    const high = Math.floor(bounded / 16);
    const low = bounded - high * 16;
    const hex = `${digits.charAt(high)}${digits.charAt(low)}`;
    return `#${hex}${hex}${hex}`;
  }
}

@Entry
@Component
struct Index {
  private live2dController: webview.WebviewController = new webview.WebviewController();
  private transcriptScroller: Scroller = new Scroller();
  private codeTaskScroller: Scroller = new Scroller();
  private responseToken: number = 0;

  @State private loading: boolean = true;
  @State private appScreen: AppScreen = AppScreen.Chat;
  @State private records: ChatRecord[] = [START_RECORD];
  @State private selectedRecord: ChatRecord = START_RECORD;
  @State private configuredModels: ConfiguredModel[] = [];
  @State private selectedPersona: PersonaPreset = defaultPersona();
  @State private selectedMode: ChatMode = ChatMode.Fast;
  @State private modelSettings: ModelSettings = defaultModelSettings();
  @State private voiceSettings: VoiceSettings = defaultVoiceSettings();
  @State private hostAgentSettings: HostAgentSettings = defaultHostAgentSettings();
  @State private messages: ChatMessage[] = [];
  @State private draft: string = '';
  @State private attachments: ComposerAttachment[] = [];
  @State private toolsVisible: boolean = false;
  @State private characterExpanded: boolean = false;
  @State private transcriptProgress: number = 0;
  @State private transcriptDetachedFromBottom: boolean = false;
  @State private historyProgress: number = 0;
  @State private codeTaskProgress: number = 0;
  @State private codeTaskDetachedFromBottom: boolean = false;
  @State private recording: boolean = false;
  @State private sending: boolean = false;
  @State private voiceBusy: boolean = false;
  @State private settingsVisible: boolean = false;
  @State private settingsSheetMode: SettingsSheetMode = SettingsSheetMode.Full;
  @State private modelMenuVisible: boolean = false;
  @State private newChatConfirmVisible: boolean = false;
  @State private deleteConfirmRecordId: string = '';
  @State private historyFilesVisible: boolean = false;
  @State private historyFiles: LocalHistoryFile[] = [];
  @State private historyFilesMessage: string = '';
  @State private historyFilePreviewVisible: boolean = false;
  @State private historyFilePreviewTitle: string = '';
  @State private historyFilePreviewMeta: string = '';
  @State private historyFilePreviewText: string = '';
  @State private historyFilePreviewPath: string = '';
  @State private historyFilePreviewKind: string = '';
  @State private historyFilePreviewMarkdown: boolean = false;
  @State private codeTasks: CodeTaskSummary[] = [];
  @State private selectedCodeTaskId: string = '';
  @State private selectedCodeTaskTitle: string = '';
  @State private selectedCodeTaskStatus: string = '';
  @State private selectedCodeTaskRunning: boolean = false;
  @State private selectedCodeTaskSummary: string = '';
  @State private selectedCodeTaskQuestions: CodeTaskQuestionPayload[] = [];
  @State private codeTaskEvents: CodeTaskEventRecord[] = [];
  @State private codeTaskExpandedTurnIds: string[] = [];
  @State private codeTaskMessageDraft: string = '';
  @State private codeTaskQuestionDrafts: CodeTaskQuestionDraft[] = [];
  @State private codeTaskLoading: boolean = false;
  @State private codeTaskSending: boolean = false;
  @State private codeTaskReplying: boolean = false;
  @State private codeTaskConnectionMessage: string = '';
  @State private codeTaskBridgeConnected: boolean = false;

  @State private editModelId: string = '';
  @State private editProvider: ModelProviderPreset = defaultModelProvider();
  @State private editDisplayName: string = 'OpenAI';
  @State private editBaseUrl: string = 'https://api.openai.com/v1';
  @State private editModel: string = 'gpt-4.1-mini';
  @State private editApiKey: string = '';
  @State private editVoiceApiKey: string = '';
  @State private editVoiceUri: string = '';
  @State private editVoiceEnabled: boolean = true;
  @State private editVoiceAutoPlay: boolean = true;
  @State private editVoiceSync: boolean = true;
  @State private editHostAgentEnabled: boolean = false;
  @State private editHostAgentBaseUrl: string = '';
  @State private editHostAgentEndpointPath: string = '/api/agent/invoke';
  @State private editHostAgentApiKey: string = '';
  private transcriptDragStartProgress: number = 0;
  private transcriptAutoScrolling: boolean = false;
  private pageDragStartProgress: number = 0;
  private codeTaskDragStartProgress: number = 0;
  private codeTaskAutoScrolling: boolean = false;
  private codeTaskApplyingHostUpdate: boolean = false;
  private codeTaskScrollTimer: number = -1;
  private codeTaskScrollSettleTimer: number = -1;
  private codeTaskHostUpdateTimer: number = -1;
  private codeTaskRefreshTimer: number = -1;
  private codeTaskReopenRefreshTimer: number = -1;
  private codeTaskBridge?: CodeTaskBridgeStream;
  private codeTaskBridgeReconnectTimer: number = -1;
  private codeTaskBridgeHeartbeatTimer: number = -1;
  @State private codeTaskViewSnapshots: CodeTaskMobileViewSnapshot[] = [];
  private codeTaskLastViewSeq: number = 0;
  private codeTaskPendingQuestionReplyTaskId: string = '';
  private codeTaskPendingQuestionReplyRequestId: string = '';

  aboutToAppear(): void {
    this.loadState();
  }

  aboutToDisappear(): void {
    this.stopCodeTaskListRefresh();
    this.clearCodeTaskReopenRefresh();
    this.clearCodeTaskScrollTimers();
    this.disconnectCodeTaskBridge();
  }

  private abilityContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private async loadState(): Promise<void> {
    const context = this.abilityContext();
    const configured = await ChatPersistence.loadConfiguredModels(context);
    const records = await ChatPersistence.loadChatRecords(context);
    const selectedRecord = records[0];
    this.configuredModels = configured;
    this.records = records;
    this.selectedRecord = selectedRecord;
    this.selectedMode = await ChatPersistence.loadChatMode(context);
    this.modelSettings = await ChatPersistence.loadModelSettings(context, configured);
    this.voiceSettings = await ChatPersistence.loadVoiceSettings(context);
    this.hostAgentSettings = await ChatPersistence.loadHostAgentSettings(context);
    this.messages = await ChatPersistence.loadChatMessages(context, selectedRecord.id);
    this.prepareSettingsDraft(SettingsSheetMode.Full);
    this.loading = false;
    this.scrollTranscriptToBottom(true);
  }

  build() {
    Stack() {
      this.chatScreen();
      this.historyScreen();
      this.codeTaskScreen();

      if (this.historyFilesVisible) {
        this.historyFilesSheet();
      }

      if (this.modelMenuVisible) {
        this.modelMenuOverlay();
      }

      if (this.settingsVisible) {
        this.settingsSheet();
      }

      if (this.newChatConfirmVisible) {
        this.confirmSheet(
          '新建聊天',
          '当前对话会保留在历史记录中，是否创建一个新的上下文？',
          () => this.createNewChat(),
          () => this.newChatConfirmVisible = false,
        );
      }

      if (this.deleteConfirmRecordId.length > 0) {
        this.confirmSheet(
          '删除记录',
          '这会从历史列表中移除此聊天记录。',
          () => this.deleteSelectedRecord(),
          () => this.deleteConfirmRecordId = '',
        );
      }

      if (this.loading) {
        this.loadingOverlay();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .priorityGesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 18 })
        .onActionStart((event: GestureEvent) => {
          this.beginPagePan(event);
        })
        .onActionUpdate((event: GestureEvent) => {
          this.updatePagePan(event);
        })
        .onActionEnd((event: GestureEvent) => {
          this.finishPagePan(event);
        })
    )
  }

  @Builder
  private chatScreen() {
    Column() {
      this.chatTopBar();
      Stack({ alignContent: Alignment.Bottom }) {
        this.live2dConversationArea();
        this.chatComposer();
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .translate({ x: this.chatPageTranslateX() })
  }

  @Builder
  private chatTopBar() {
    Row() {
      this.circleButton('≡', () => {
        this.openHistoryScreen();
      });
      Row() {
        this.modelSelectorButton();
        this.emotionChip();
        this.modeSwitch();
      }
      .layoutWeight(1)
      .margin({ left: 6, right: 6 })
      .alignItems(VerticalAlign.Center)
      this.circleButton('⌁', () => {
        this.openCodeTaskScreen();
      });
      Blank().width(6)
      this.circleButton('+', () => {
        this.newChatConfirmVisible = true;
      });
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 10, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(PAPER)
  }

  @Builder
  private modelSelectorButton() {
    Row() {
      this.statusDot(this.sending);
      Text(this.currentModelLabel())
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('⌄')
        .fontSize(13)
        .fontColor('#5C5C5C')
    }
    .width(88)
    .height(38)
    .padding({ left: 9, right: 8 })
    .borderRadius(22)
    .backgroundColor(GLASS_LIGHT)
    .border({ width: 1, color: LINE })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.modelMenuVisible = true;
    })
  }

  @Builder
  private emotionChip() {
    Row() {
      this.statusDot(false);
      Text(this.selectedPersona.name)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('表情')
        .fontSize(11)
        .fontColor('#666666')
        .margin({ left: 4 })
    }
    .layoutWeight(1)
    .height(38)
    .margin({ left: 5, right: 5 })
    .padding({ left: 10, right: 10 })
    .borderRadius(22)
    .backgroundColor(GLASS_LIGHT)
    .border({ width: 1, color: LINE })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .clip(true)
    .onClick(() => this.playEmotion('joy'))
  }

  @Builder
  private modeSwitch() {
    Row() {
      this.modeSegment(ChatMode.Fast);
      this.modeSegment(ChatMode.Thinking);
    }
    .height(38)
    .width(84)
    .padding(3)
    .borderRadius(22)
    .backgroundColor(GLASS_LIGHT)
    .border({ width: 1, color: LINE })
  }

  @Builder
  private modeSegment(mode: ChatMode) {
    Text(chatModeLabel(mode))
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.selectedMode === mode ? INK_WHITE : INK_BLACK)
      .textAlign(TextAlign.Center)
      .width(39)
      .height(32)
      .padding({ top: 7 })
      .borderRadius(16)
      .backgroundColor(this.selectedMode === mode ? INK_BLACK : '#00FFFFFF')
      .onClick(async () => {
        this.selectedMode = mode;
        await ChatPersistence.saveChatMode(this.abilityContext(), mode);
      })
  }

  @Builder
  private live2dConversationArea() {
    Stack({ alignContent: Alignment.Bottom }) {
      Live2dSurface({
        controller: this.live2dController,
      })
        .width('100%')
        .height('100%')
        .backgroundColor('#EDF2F1')

      this.liveStatusBadge();
      this.transcriptPanel();
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private liveStatusBadge() {
    Row() {
      this.statusDot(this.recording);
      Text(this.selectedPersona.name)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK_BLACK)
    }
    .position({ x: 14, y: 14 })
    .padding({ left: 11, right: 11, top: 7, bottom: 7 })
    .borderRadius(18)
    .backgroundColor(GLASS_LIGHT)
    .border({ width: 1, color: LINE })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private transcriptPanel() {
    Column() {
      Row() {
        Blank()
          .width(this.transcriptHandleWidth())
          .height(4)
          .borderRadius(2)
          .backgroundColor('#660B0B0C')
      }
      .width('100%')
      .height(24)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.setTranscriptExpanded(!this.characterExpanded);
      })
      .gesture(
        PanGesture({ direction: PanDirection.Vertical, distance: 6 })
          .onActionStart(() => {
            this.beginTranscriptPan();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.updateTranscriptPan(event);
          })
          .onActionEnd((event: GestureEvent) => {
            this.finishTranscriptPan(event);
          })
      )

      Stack({ alignContent: Alignment.Bottom }) {
        Scroll(this.transcriptScroller) {
          Column() {
            Text('今天')
              .fontSize(12)
              .fontColor('#747474')
              .padding({ left: 12, right: 12, top: 4, bottom: 4 })
              .borderRadius(12)
              .backgroundColor('#AAFFFFFF')
              .alignSelf(ItemAlign.Center)
              .margin({ bottom: 8 })

            ForEach(this.messages, (message: ChatMessage, index: number) => {
              this.messageRow(message, index);
            }, (message: ChatMessage) => this.messageRenderKey(message))

            if (this.sending && !this.hasStreamingMessage()) {
              this.typingPreview();
            }

            Blank().height(16)
          }
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .onDidScroll((_xOffset: number, _yOffset: number, _scrollState: ScrollState) => {
          this.updateTranscriptBottomButton();
        })
        .onReachEnd(() => {
          this.markTranscriptAtBottom();
        })
        .onScrollStop(() => {
          this.updateTranscriptBottomButton();
        })

        if (this.transcriptDetachedFromBottom) {
          Row() {
            Blank()
              .layoutWeight(1)
            this.transcriptBottomButton();
          }
          .width('100%')
          .padding({ right: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height(this.transcriptHeight())
    .padding({
      left: this.transcriptHorizontalPadding(),
      right: this.transcriptHorizontalPadding(),
      top: this.transcriptTopPadding(),
      bottom: 78,
    })
    .borderRadius(this.transcriptBorderRadius())
    .backgroundColor(this.transcriptBackgroundColor())
    .border({ width: this.transcriptBorderWidth(), color: LINE })
  }

  @Builder
  private transcriptBottomButton() {
    Text('↓')
      .fontSize(20)
      .fontWeight(FontWeight.Bold)
      .fontColor(INK_BLACK)
      .textAlign(TextAlign.Center)
      .width(42)
      .height(42)
      .padding({ top: 8 })
      .borderRadius(22)
      .backgroundColor('#EFFFFFFF')
      .border({ width: 1, color: LINE })
      .shadow({
        radius: 12,
        color: '#22000000',
        offsetX: 0,
        offsetY: 4,
      })
      .onClick(() => {
        this.returnTranscriptToBottom();
      })
  }

  @Builder
  private messageRow(message: ChatMessage, index: number) {
    if (message.isAgent) {
      Row() {
        Column() {
          Column() {
            Text(message.author)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.messageMetaColor(index))
              .margin({ bottom: 5 })

            if (message.showThinking && message.thinking.length > 0) {
              this.thinkingCard(message, index);
            }

            if (message.toolPreview !== undefined) {
              this.toolPreviewCard(message.toolPreview, index);
            }

            if (message.activeToolName.length > 0) {
              Text(`正在调用 ${message.activeToolName} ...`)
                .fontSize(14)
                .fontColor('#666666')
            }

            if (message.text.length > 0) {
              MarkdownMessageText({
                text: message.text,
                ageLevel: this.messageAgeLevel(index),
              })
            } else if (message.streaming && !message.showThinking) {
              this.thinkingLine(`${message.author} thinking...`)
            }
          }
          .constraintSize({ maxWidth: AGENT_MESSAGE_MAX_WIDTH })
          .padding({ left: 13, right: 13, top: 10, bottom: 11 })
          .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 6, bottomRight: 18 })
          .backgroundColor(AGENT_BUBBLE)
          .border({ width: 1, color: LINE })
          .alignItems(HorizontalAlign.Start)

          Row() {
            Text(message.time)
              .fontSize(11)
              .fontColor(this.messageTimeColor(index))
              .layoutWeight(1)

            if (message.text.length > 0) {
              this.messageActionButton('copy', () => {
                this.copyMessageText(message.text);
              });
              this.messageActionButton('play', () => {
                this.playMessageText(message.text);
              });
            }
          }
          .constraintSize({ maxWidth: AGENT_MESSAGE_MAX_WIDTH })
          .margin({ top: 5, left: 2 })
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .margin({ bottom: 12 })
    } else {
      Column() {
        Column() {
          CyclingMessageText({
            text: message.text,
            ageLevel: this.messageAgeLevel(index),
            isUser: true,
          })
          if (message.attachments.length > 0) {
            this.attachmentRow(message.attachments);
          }
        }
        .constraintSize({ maxWidth: USER_MESSAGE_MAX_WIDTH })
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 6 })
        .backgroundColor(USER_BUBBLE)
        .border({ width: 1, color: '#11000000' })
        .alignItems(HorizontalAlign.Start)

        Row() {
          Blank()
            .layoutWeight(1)

          Text(message.time)
            .fontSize(11)
            .fontColor(this.messageTimeColor(index))
            .margin({ right: message.text.length > 0 ? 12 : 0 })

          if (message.text.length > 0) {
            this.messageActionButton('copy', () => {
              this.copyMessageText(message.text);
            });
          }
        }
        .constraintSize({ maxWidth: USER_MESSAGE_MAX_WIDTH })
        .margin({ top: 5, right: 2 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.End)
      .margin({ bottom: 12 })
    }
  }

  @Builder
  private thinkingLine(label: string) {
    Row() {
      LoadingProgress()
        .width(16)
        .height(16)
        .color('#777777')
        .margin({ right: 8 })
      Text(label)
        .fontSize(15)
        .fontColor('#666666')
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private messageActionButton(kind: string, action: () => void) {
    Row() {
      if (kind === 'copy') {
        this.copyIcon();
      } else if (this.voiceBusy) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color('#777777')
      } else {
        this.playIcon();
      }
    }
    .width(30)
    .height(26)
    .margin({ left: 4 })
    .borderRadius(13)
    .backgroundColor('#00FFFFFF')
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick(action)
  }

  @Builder
  private copyIcon() {
    Image($r('app.media.ic_copy'))
      .width(16)
      .height(16)
      .objectFit(ImageFit.Contain)
  }

  @Builder
  private playIcon() {
    Image($r('app.media.ic_volume'))
      .width(16)
      .height(16)
      .objectFit(ImageFit.Contain)
  }

  @Builder
  private thinkingCard(message: ChatMessage, index: number) {
    Column() {
      Row() {
        if (message.streaming && message.thinkingExpanded) {
          LoadingProgress()
            .width(13)
            .height(13)
            .color('#8A8A8A')
            .margin({ right: 6 })
        } else {
          this.statusDot(false);
        }
        Text(message.thinking.indexOf('[工具调用]') >= 0 ?
          (message.streaming && message.thinkingExpanded ? '调用中' : '调用结果') :
          (message.streaming && message.thinkingExpanded ? '思考中' : '思考过程'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#7A7A7A')
          .layoutWeight(1)
        Text(message.thinkingExpanded ? '收起' : '展开')
          .fontSize(11)
          .fontColor('#8A8A8A')
      }
      .alignItems(VerticalAlign.Center)

      if (message.thinkingExpanded) {
        Scroll() {
          Text(message.thinking)
            .fontSize(13)
            .fontColor('#7C7C7C')
            .lineHeight(19)
            .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 420 })
        .scrollBar(BarState.Off)
        .margin({ top: 7 })
      }
    }
    .alignSelf(ItemAlign.Stretch)
    .constraintSize({ maxWidth: '100%' })
    .padding({ left: 9, right: 9, top: 7, bottom: message.thinkingExpanded ? 9 : 7 })
    .margin({ bottom: 9 })
    .borderRadius(14)
    .backgroundColor('#4DFFFFFF')
    .border({ width: 1, color: '#0D000000' })
    .onClick(() => this.toggleThinking(index))
  }

  @Builder
  private toolPreviewCard(preview: ToolPreview, index: number) {
    Column() {
      Row() {
        this.statusDot(preview.risk === '执行中')
        Text(preview.title)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#424242')
          .layoutWeight(1)
        Text(preview.risk)
          .fontSize(11)
          .fontColor(preview.risk === '失败' ? DANGER : '#6C6C6C')
      }
      .alignItems(VerticalAlign.Center)

      if (preview.detail.length > 0) {
        Text(preview.detail)
          .fontSize(12)
          .fontColor('#666666')
          .lineHeight(18)
          .margin({ top: 5 })
      }
    }
    .alignSelf(ItemAlign.Stretch)
    .padding({ left: 9, right: 9, top: 7, bottom: 8 })
    .margin({ bottom: 9 })
    .borderRadius(12)
    .backgroundColor('#66FFFFFF')
    .border({ width: 1, color: '#12000000' })
    .onClick(() => this.toggleThinking(index))
  }

  @Builder
  private attachmentRow(attachments: ComposerAttachment[]) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(attachments, (attachment: ComposerAttachment) => {
        Text(`${attachment.kind === AttachmentKind.Image ? '图片' : '文件'} · ${attachment.label}${stringValue(attachment.hostPath).length > 0 ? ' · 已上传' : ''}`)
          .fontSize(12)
          .fontColor('#333333')
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .borderRadius(999)
          .backgroundColor('#11000000')
          .margin({ right: 6, top: 6 })
      }, (attachment: ComposerAttachment) => attachment.id)
    }
  }

  @Builder
  private typingPreview() {
    Row() {
      LoadingProgress()
        .width(16)
        .height(16)
        .color('#777777')
        .margin({ right: 8 })
      Text(`${this.selectedPersona.name} thinking...`)
        .fontSize(15)
        .fontColor('#666666')
    }
    .padding({ left: 12, top: 6, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private chatComposer() {
    Column() {
      if (this.toolsVisible) {
        this.toolTray();
      }

      if (this.attachments.length > 0) {
        this.attachmentComposerStrip();
      }

      Row() {
        this.circleButton(this.toolsVisible ? '×' : '+', () => {
          this.toolsVisible = !this.toolsVisible;
        });

        Row() {
          TextArea({
            text: this.draft,
            placeholder: this.sending ? 'Amaduse 正在输出...' : (this.recording ? '正在听...' : 'Message Amaduse'),
          })
            .fontSize(16)
            .fontColor(INK_BLACK)
            .placeholderColor('#777777')
            .backgroundColor('#00FFFFFF')
            .layoutWeight(1)
            .maxLines(5)
            .onChange((value: string) => {
              this.draft = value;
            })

          if (this.sending) {
            this.actionCircle('×', () => this.stopResponse(), false);
          } else if (this.canSend()) {
            this.actionCircle('↑', () => this.sendMessage(), true);
          } else {
            this.voiceActionButton(this.recording, () => {
              this.recording = !this.recording;
            });
          }
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 8, top: 6, bottom: 6 })
        .margin({ left: 6 })
        .borderRadius(24)
        .backgroundColor(GLASS_LIGHT)
        .border({ width: 1, color: LINE })
        .alignItems(VerticalAlign.Bottom)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
  }

  @Builder
  private toolTray() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(toolShortcuts, (shortcut: ToolShortcut) => {
        Row() {
          Text(shortcut.icon)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .width(22)
          Column() {
            Text(shortcut.title)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
            Text(shortcut.subtitle)
              .fontSize(11)
              .fontColor('#666666')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width(118)
        .padding({ left: 12, right: 10, top: 10, bottom: 10 })
        .margin({ right: 8, bottom: 8 })
        .borderRadius(18)
        .backgroundColor('#BFFFFFFF')
        .alignItems(VerticalAlign.Center)
        .onClick(() => this.handleToolShortcut(shortcut))
      }, (shortcut: ToolShortcut) => shortcut.title)
    }
    .width('100%')
    .padding(10)
    .borderRadius(22)
    .backgroundColor(GLASS_LIGHT)
    .border({ width: 1, color: LINE })
  }

  @Builder
  private attachmentComposerStrip() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.attachments, (attachment: ComposerAttachment) => {
        Row() {
          Text(`${attachment.label}${stringValue(attachment.hostPath).length > 0 ? ' · 已上传' : ''}`)
            .fontSize(12)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('×')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .margin({ left: 8 })
        }
        .padding({ left: 10, right: 10, top: 7, bottom: 7 })
        .margin({ right: 8, bottom: 8 })
        .borderRadius(16)
        .backgroundColor('#12000000')
        .onClick(() => {
          this.attachments = this.attachments.filter((item: ComposerAttachment) => item.id !== attachment.id);
        })
      }, (attachment: ComposerAttachment) => attachment.id)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8 })
    .borderRadius(18)
    .backgroundColor(GLASS_LIGHT)
    .border({ width: 1, color: LINE })
  }

  @Builder
  private historyScreen() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Scroll() {
        Column() {
          Row() {
            Column() {
              Text('Amaduse')
                .fontSize(30)
                .fontWeight(FontWeight.Bold)
                .fontColor(INK_BLACK)
              Text('Conversation memory')
                .fontSize(12)
                .fontColor('#777777')
                .margin({ top: 3 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            this.historyIconButton('⌕', () => {}, false);
            this.historyIconButton('A', () => this.openSettings(SettingsSheetMode.Full), true);
          }
          .width('100%')
          .padding({ top: 0, bottom: 18 })
          .alignItems(VerticalAlign.Center)

          Row() {
            this.historyActionCard('+', '新建项目', '创建上下文', () => this.newChatConfirmVisible = true, false);
            this.historyActionCard('□', '历史文件', '生成与下载', () => this.openHistoryFiles(), true);
          }
          .width('100%')
          .margin({ top: 14 })
          .alignItems(VerticalAlign.Center)

          Row() {
            Text('最近')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(INK_BLACK)
              .layoutWeight(1)
            Text(`${this.records.length} 条`)
              .fontSize(12)
              .fontColor('#858585')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(999)
              .backgroundColor('#11000000')
          }
          .width('100%')
          .margin({ top: 30, bottom: 12 })
          .alignItems(VerticalAlign.Center)

          ForEach(this.records, (record: ChatRecord) => {
            this.historyRecordRow(record);
          }, (record: ChatRecord) => record.id)

          Blank().height(104)
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .padding({ left: 20, right: 20, top: 58 })
        .justifyContent(FlexAlign.Start)
      }
      .width('100%')
      .height('100%')

      Row() {
        Text('+')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_WHITE)
        Text('聊天')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_WHITE)
          .margin({ left: 8 })
      }
      .padding({ left: 18, right: 20, top: 13, bottom: 13 })
      .margin({ right: 24, bottom: 30 })
      .borderRadius(999)
      .backgroundColor(INK_BLACK)
      .onClick(() => this.newChatConfirmVisible = true)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .translate({ x: this.historyPageTranslateX() })
    .visibility(this.historyProgress <= 0 ? Visibility.Hidden : Visibility.Visible)
  }

  @Builder
  private codeTaskScreen() {
    Column() {
      Row() {
        Column() {
          Text('OpenCode 任务')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK_BLACK)
          Text(this.codeTaskConnectionLabel())
            .fontSize(12)
            .fontColor('#777777')
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.historyIconButton('↻', () => this.refreshCodeTasks(), false);
        this.historyIconButton('×', () => this.closeCodeTaskScreen(), true);
      }
      .width('100%')
      .padding({ top: 20, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      if (!CodeTaskRemoteService.isConfigured(this.hostAgentSettings)) {
        this.codeTaskConfigPanel();
      } else {
        this.codeTaskConnectedPanel();
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, bottom: 16 })
    .backgroundColor(PAPER)
    .translate({ x: this.codeTaskPageTranslateX() })
    .visibility(this.codeTaskProgress <= 0 ? Visibility.Hidden : Visibility.Visible)
  }

  @Builder
  private codeTaskConfigPanel() {
    Column() {
      Text('需要配置远程主机')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK_BLACK)
      Text('填写电脑后端地址后，就能在这里选择已有 OpenCode 任务。')
        .fontSize(13)
        .fontColor('#777777')
        .lineHeight(20)
        .textAlign(TextAlign.Center)
        .margin({ top: 8, bottom: 18 })
      Row() {
        this.sheetAction('关闭', false, () => this.closeCodeTaskScreen());
        this.sheetAction('去配置', true, () => this.openSettings(SettingsSheetMode.Full));
      }
      .width('100%')
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private codeTaskConnectedPanel() {
    Column() {
      this.codeTaskListPanel();
      if (this.selectedCodeTaskId.length > 0) {
        this.codeTaskDetailPanel();
      } else {
        this.codeTaskEmptySelectionPanel();
        this.codeTaskComposer();
      }
    }
    .layoutWeight(1)
    .width('100%')
  }

  @Builder
  private codeTaskListPanel() {
    Column() {
      Row() {
        Text('主机任务')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_BLACK)
          .layoutWeight(1)
        if (this.codeTaskLoading) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(INK_BLACK)
        } else {
          Text(`${this.codeTasks.length} 个`)
            .fontSize(12)
            .fontColor('#777777')
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })

      if (this.codeTasks.length === 0) {
        Column() {
          Text(this.codeTaskLoading ? '正在读取任务...' : '暂无任务')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK_BLACK)
          Text(this.codeTaskConnectionMessage)
            .fontSize(12)
            .fontColor('#777777')
            .margin({ top: 4 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height(96)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.codeTasks, (task: CodeTaskSummary) => {
              this.codeTaskRow(task);
            }, (task: CodeTaskSummary) => task.id)
          }
          .width('100%')
        }
        .height(176)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(20)
    .backgroundColor(GLASS_LIGHT)
    .border({ width: 1, color: LINE })
  }

  @Builder
  private codeTaskRow(task: CodeTaskSummary) {
    Row() {
      Blank()
        .width(4)
        .height(42)
        .borderRadius(2)
        .backgroundColor(task.id === this.selectedCodeTaskId ? INK_BLACK : this.codeTaskStatusColor(this.codeTaskSummaryStatus(task, '')))
        .margin({ right: 10 })

      Column() {
        Text(stringValue(task.title, 'OpenCode 任务'))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_BLACK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.codeTaskRowSubtitle(task))
          .fontSize(12)
          .fontColor('#777777')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.codeTaskStatusText(this.codeTaskSummaryStatus(task, '')))
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(task.id === this.selectedCodeTaskId ? INK_WHITE : INK_BLACK)
        .textAlign(TextAlign.Center)
        .width(58)
        .height(28)
        .padding({ top: 7 })
        .borderRadius(14)
        .backgroundColor(task.id === this.selectedCodeTaskId ? INK_BLACK : '#12000000')
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 10, bottom: 10 })
    .margin({ bottom: 8 })
    .borderRadius(16)
    .backgroundColor(task.id === this.selectedCodeTaskId ? '#F2FFFFFF' : '#A8FFFFFF')
    .border({ width: 1, color: task.id === this.selectedCodeTaskId ? LINE : '#0D000000' })
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.selectCodeTask(task))
  }

  @Builder
  private codeTaskEmptySelectionPanel() {
    Column() {
      Text('选择一个任务')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK_BLACK)
      Text(this.codeTaskConnectionMessage.length > 0 ? this.codeTaskConnectionMessage : '输入任务后会发送到主机端，主机处理过程会同步到这里。')
        .fontSize(13)
        .fontColor('#777777')
        .lineHeight(20)
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private codeTaskDetailPanel() {
    Column() {
      Row() {
        Column() {
          Text(this.selectedCodeTaskTitle.length > 0 ? this.selectedCodeTaskTitle : 'OpenCode 任务')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK_BLACK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.codeTaskStatusText(this.selectedCodeTaskStatus)} · ${this.codeTaskDisplayEvents().length} 条事件`)
            .fontSize(12)
            .fontColor('#777777')
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.statusDot(this.selectedCodeTaskRunning)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 12, bottom: 10 })

      if (this.selectedCodeTaskQuestions.length > 0) {
        this.codeTaskQuestionCard(this.selectedCodeTaskQuestions[0]);
      }

      Stack({ alignContent: Alignment.Bottom }) {
        Scroll(this.codeTaskScroller) {
          Column() {
            if (this.codeTaskEvents.length === 0) {
              Text('暂无事件')
                .fontSize(14)
                .fontColor('#777777')
                .margin({ top: 24 })
            }
            ForEach(this.codeTaskConversationTurns(), (turn: CodeTaskConversationTurn) => {
              this.codeTaskTurnView(turn);
            }, (turn: CodeTaskConversationTurn) => turn.id)
          }
          .width('100%')
          .padding({ bottom: 24 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .onDidScroll((_xOffset: number, _yOffset: number, _scrollState: ScrollState) => {
          this.updateCodeTaskBottomButton();
        })
        .onReachEnd(() => {
          this.markCodeTaskAtBottom();
        })
        .onScrollStop(() => {
          this.updateCodeTaskBottomButton();
        })

        if (this.codeTaskDetachedFromBottom) {
          Row() {
            Blank()
              .layoutWeight(1)
            this.codeTaskBottomButton();
          }
          .width('100%')
          .padding({ right: 8, bottom: 8 })
          .alignItems(VerticalAlign.Center)
        }
      }
      .layoutWeight(1)
      .width('100%')

      this.codeTaskComposer();
    }
    .layoutWeight(1)
    .width('100%')
  }

  @Builder
  private codeTaskQuestionCard(question: CodeTaskQuestionPayload) {
    Column() {
      Row() {
        Text('需要选择')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_BLACK)
          .layoutWeight(1)
        Text(stringValue(question.requestId).substring(0, 8))
          .fontSize(11)
          .fontColor('#777777')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      ForEach(this.codeTaskQuestionItems(question), (item: CodeTaskQuestionItem, index: number) => {
        this.codeTaskQuestionItemView(item, index);
      }, (item: CodeTaskQuestionItem, index: number) => `${index}-${stringValue(item.header, stringValue(item.question))}`)

      Row() {
        this.sheetAction('拒绝', false, () => this.rejectCodeTaskQuestion(question));
        this.sheetAction(this.codeTaskReplying ? '提交中' : '提交', true, () => this.replyCodeTaskQuestion(question));
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(12)
    .margin({ bottom: 10 })
    .borderRadius(18)
    .backgroundColor('#FFF8E7')
    .border({ width: 1, color: '#33F3C21B' })
  }

  @Builder
  private codeTaskQuestionItemView(item: CodeTaskQuestionItem, index: number) {
    Column() {
      Text(stringValue(item.question, stringValue(item.header, '请选择')))
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK_BLACK)
        .lineHeight(20)
        .width('100%')
        .margin({ top: 10, bottom: 6 })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.codeTaskQuestionOptions(item), (option: CodeTaskQuestionOption) => {
          this.codeTaskQuestionOptionChip(index, stringValue(option.label), stringValue(option.description));
        }, (option: CodeTaskQuestionOption) => stringValue(option.label))
      }
      .width('100%')

      if (item.custom || this.codeTaskQuestionOptions(item).length === 0) {
        TextInput({ text: this.codeTaskQuestionCustomValue(index), placeholder: '自定义回答' })
          .fontSize(14)
          .fontColor(INK_BLACK)
          .placeholderColor('#777777')
          .backgroundColor('#BFFFFFFF')
          .borderRadius(14)
          .padding({ left: 10, right: 10 })
          .margin({ top: 8 })
          .onChange((value: string) => this.setCodeTaskQuestionCustom(index, value))
      }
    }
    .width('100%')
  }

  @Builder
  private codeTaskQuestionOptionChip(questionIndex: number, label: string, description: string) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isCodeTaskQuestionOptionSelected(questionIndex, label) ? INK_WHITE : INK_BLACK)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (description.length > 0) {
        Text(description)
          .fontSize(10)
          .fontColor(this.isCodeTaskQuestionOptionSelected(questionIndex, label) ? '#D9FFFFFF' : '#777777')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
    }
    .width(126)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .margin({ right: 8, bottom: 8 })
    .borderRadius(14)
    .backgroundColor(this.isCodeTaskQuestionOptionSelected(questionIndex, label) ? INK_BLACK : '#BFFFFFFF')
    .onClick(() => this.toggleCodeTaskQuestionOption(questionIndex, label))
  }

  @Builder
  private codeTaskTurnView(turn: CodeTaskConversationTurn) {
    Column() {
      if (turn.hasRequest) {
        this.codeTaskRequestBubble(turn.request);
      }
      this.codeTaskProcessedBlock(turn);
      if (this.codeTaskTurnSummaryText(turn).length > 0) {
        this.codeTaskSummaryBubble(turn);
      }
    }
    .width('100%')
    .margin({ bottom: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private codeTaskRequestBubble(event: CodeTaskEventRecord) {
    Row() {
      Blank()
        .layoutWeight(1)
      Column() {
        Text(this.codeTaskEventDetail(event))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_BLACK)
          .lineHeight(20)
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (stringValue(event.payload.workspacePath).length > 0) {
          Text(stringValue(event.payload.workspacePath))
            .fontSize(11)
            .fontColor('#777777')
            .margin({ top: 10 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .width('82%')
      .constraintSize({ maxWidth: 286, minWidth: 132 })
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 6 })
      .backgroundColor(USER_BUBBLE)
      .border({ width: 1, color: '#10000000' })
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ top: 4, bottom: 10 })
  }

  @Builder
  private codeTaskBottomButton() {
    Text('↓')
      .fontSize(20)
      .fontWeight(FontWeight.Bold)
      .fontColor(INK_BLACK)
      .textAlign(TextAlign.Center)
      .width(42)
      .height(42)
      .padding({ top: 8 })
      .borderRadius(22)
      .backgroundColor('#EFFFFFFF')
      .border({ width: 1, color: LINE })
      .shadow({
        radius: 12,
        color: '#22000000',
        offsetX: 0,
        offsetY: 4,
      })
      .onClick(() => {
        this.returnCodeTaskToBottom();
      })
  }

  @Builder
  private codeTaskProcessedBlock(turn: CodeTaskConversationTurn) {
    if (turn.events.length > 0) {
      Column() {
        Row() {
          Row() {
            Row() {
              if (turn.running) {
                LoadingProgress()
                  .width(14)
                  .height(14)
                  .color(BLUE)
              } else {
                Text('✓')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(ACTIVE_GREEN)
                  .textAlign(TextAlign.Center)
                  .width(20)
                  .height(20)
                  .padding({ top: 3 })
              }
            }
            .width(20)
            .height(20)
            .borderRadius(10)
            .backgroundColor('#F7FFFFFF')
            .border({ width: 1, color: turn.running ? '#334D8CFF' : '#3335D07F' })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .margin({ right: 8 })
            Text(turn.running ? '处理中' : '已处理')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(INK_BLACK)
            if (this.codeTaskTurnDuration(turn).length > 0) {
              Text(this.codeTaskTurnDuration(turn))
                .fontSize(12)
                .fontColor('#777777')
                .margin({ left: 8 })
            }
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)

          Text(`${turn.events.length} 条事件  ${this.isCodeTaskTurnExpanded(turn) ? '收起' : '展开'}`)
            .fontSize(12)
            .fontColor('#777777')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .onClick(() => this.toggleCodeTaskTurnExpanded(turn))

        if (this.isCodeTaskTurnExpanded(turn)) {
          Column() {
            Text(`OpenCode 过程已归并为 ${this.codeTaskTurnProcessPhases(turn).length} 个阶段，记录 ${turn.events.length} 条事件。`)
              .fontSize(12)
              .fontColor('#777777')
              .lineHeight(18)
              .margin({ bottom: 8 })
              .width('100%')

            ForEach(this.codeTaskTurnProcessPhases(turn), (phase: CodeTaskProcessPhase) => {
              this.codeTaskProcessPhaseView(phase);
            }, (phase: CodeTaskProcessPhase) => phase.id)
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 12 })
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .borderRadius(18)
      .backgroundColor('#F8FFFFFF')
      .border({ width: 1, color: '#10000000' })
      .margin({ bottom: 10 })
    }
  }

  @Builder
  private codeTaskProcessPhaseView(phase: CodeTaskProcessPhase) {
    Column() {
      Row() {
        Text(this.codeTaskPhaseIcon(phase))
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_WHITE)
          .textAlign(TextAlign.Center)
          .width(20)
          .height(20)
          .padding({ top: 5 })
          .borderRadius(10)
          .backgroundColor(this.codeTaskPhaseColor(phase))
          .margin({ right: 10 })
        Text(phase.title)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_BLACK)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.codeTaskPhaseStatusText(phase.status))
          .fontSize(11)
          .fontColor('#888888')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 4, bottom: 2 })

      if (this.codeTaskHiddenPhaseEventCount(phase) > 0) {
        Text(`已折叠 ${this.codeTaskHiddenPhaseEventCount(phase)} 条较早事件`)
          .fontSize(12)
          .fontColor('#888888')
          .margin({ left: 30, top: 4, bottom: 2 })
          .width('100%')
      }

      ForEach(this.codeTaskVisiblePhaseEvents(phase), (event: CodeTaskEventRecord) => {
        this.codeTaskProcessEventRow(event);
      }, (event: CodeTaskEventRecord) => `${phase.id}-${event.seq}-${event.event}`)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private codeTaskProcessEventRow(event: CodeTaskEventRecord) {
    Row() {
      Text(this.codeTaskEventIcon(event.event))
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK_WHITE)
        .textAlign(TextAlign.Center)
        .width(20)
        .height(20)
        .padding({ top: 5 })
        .borderRadius(10)
        .backgroundColor(this.codeTaskEventColor(event.event))
        .margin({ right: 10 })

      Column() {
        Row() {
          Text(this.codeTaskEventTitle(event))
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK_BLACK)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.shortTimeText(event.createdAt))
            .fontSize(11)
            .fontColor('#888888')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.codeTaskEventDetail(event).length > 0) {
          Text(this.codeTaskEventDetail(event))
            .fontSize(12)
            .fontColor('#666666')
            .lineHeight(18)
            .maxLines(event.event === 'output' ? 8 : 5)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private codeTaskSummaryBubble(turn: CodeTaskConversationTurn) {
    Column() {
      Text('任务总结')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor('#777777')
        .margin({ left: 4, bottom: 6 })
      Column() {
        MarkdownMessageText({
          text: this.codeTaskTurnSummaryText(turn),
          ageLevel: 1,
        })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .borderRadius(18)
      .backgroundColor(AGENT_BUBBLE)
      .border({ width: 1, color: '#10000000' })
      .alignItems(HorizontalAlign.Start)

      Text(this.shortTimeText(this.codeTaskTurnEndTime(turn)))
        .fontSize(11)
        .fontColor('#888888')
        .margin({ left: 4, top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 8 })
  }

  @Builder
  private codeTaskEventRow(event: CodeTaskEventRecord) {
    Row() {
      Text(this.codeTaskEventIcon(event.event))
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK_WHITE)
        .textAlign(TextAlign.Center)
        .width(28)
        .height(28)
        .padding({ top: 7 })
        .borderRadius(14)
        .backgroundColor(this.codeTaskEventColor(event.event))
        .margin({ right: 10 })

      Column() {
        Row() {
          Text(this.codeTaskEventTitle(event))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK_BLACK)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.shortTimeText(event.createdAt))
            .fontSize(11)
            .fontColor('#888888')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.codeTaskEventDetail(event).length > 0) {
          Text(this.codeTaskEventDetail(event))
            .fontSize(12)
            .fontColor('#666666')
            .lineHeight(18)
            .maxLines(5)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .margin({ bottom: 8 })
    .borderRadius(16)
    .backgroundColor('#F3FFFFFF')
    .border({ width: 1, color: '#0D000000' })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private codeTaskComposer() {
    Row() {
      TextArea({
        text: this.codeTaskMessageDraft,
        placeholder: this.codeTaskSending ? '正在发送...' :
          (this.selectedCodeTaskId.length > 0 ? '推进这个任务' : '输入要交给主机完成的任务'),
      })
        .fontSize(15)
        .fontColor(INK_BLACK)
        .placeholderColor('#777777')
        .backgroundColor('#00FFFFFF')
        .layoutWeight(1)
        .maxLines(4)
        .onChange((value: string) => {
          this.codeTaskMessageDraft = value;
        })

      if (this.codeTaskSending) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color(INK_BLACK)
          .margin({ left: 8 })
      } else {
        this.actionCircle('↑', () => this.sendCodeTaskMessage(), this.canSendCodeTaskMessage());
      }
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 7, bottom: 7 })
    .borderRadius(22)
    .backgroundColor(GLASS_LIGHT)
    .border({ width: 1, color: LINE })
    .alignItems(VerticalAlign.Bottom)
  }

  @Builder
  private historyIconButton(label: string, onClick: () => void, filled: boolean) {
    Text(label)
      .fontSize(filled ? 17 : 24)
      .fontWeight(FontWeight.Bold)
      .fontColor(filled ? INK_WHITE : INK_BLACK)
      .textAlign(TextAlign.Center)
      .width(42)
      .height(42)
      .padding({ top: filled ? 11 : 5 })
      .margin({ left: 8 })
      .borderRadius(21)
      .backgroundColor(filled ? '#B59A62' : GLASS_LIGHT)
      .border({ width: filled ? 0 : 1, color: LINE })
      .onClick(onClick)
  }

  @Builder
  private historyActionCard(icon: string, title: string, subtitle: string, onClick: () => void, accent: boolean) {
    Row() {
      Text(icon)
        .fontSize(accent ? 22 : 24)
        .fontWeight(FontWeight.Bold)
        .fontColor(accent ? '#F3C21B' : INK_BLACK)
        .width(30)
        .textAlign(TextAlign.Center)
        .margin({ right: 8 })
      Column() {
        Text(title)
          .fontSize(title.length > 10 ? 13 : 14)
          .fontColor(INK_BLACK)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(subtitle)
          .fontSize(11)
          .fontColor('#696969')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .height(72)
    .padding({ left: 12, right: 10 })
    .margin({ right: accent ? 0 : 10 })
    .borderRadius(18)
    .backgroundColor(accent ? '#FFF8E7' : '#F2FFFFFF')
    .border({ width: 1, color: accent ? '#33F3C21B' : LINE })
    .alignItems(VerticalAlign.Center)
    .onClick(onClick)
  }

  @Builder
  private historyFilesSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
      }
        .width('100%')
        .height('100%')
        .backgroundColor(DIM_OVERLAY)
        .onClick(() => this.closeHistoryFiles())

      Column() {
        Row() {
          Column() {
            Text('历史文件')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(INK_BLACK)
            Text(this.historyFilesMessage)
              .fontSize(12)
              .fontColor('#777777')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          this.historyFileToolbarButton('导入', () => this.importHistoryFileFromPicker());
          this.historyFileToolbarButton('刷新', () => this.loadHistoryFiles());
          this.historyFileToolbarButton('×', () => this.closeHistoryFiles());
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 12 })

        if (this.historyFilePreviewVisible) {
          this.historyFilePreviewPanel();
        } else {
          this.historyFileListPanel();
        }
      }
      .width('100%')
      .height('86%')
      .padding({ left: 18, right: 18, top: 18, bottom: 18 })
      .borderRadius(24)
      .backgroundColor('#FAFFFFFF')
      .border({ width: 1, color: LINE })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private historyFileToolbarButton(text: string, onClick: () => void) {
    Text(text)
      .fontSize(text.length > 1 ? 13 : 18)
      .fontWeight(FontWeight.Bold)
      .fontColor(INK_BLACK)
      .textAlign(TextAlign.Center)
      .width(text.length > 1 ? 52 : 36)
      .height(36)
      .padding({ top: text.length > 1 ? 9 : 5 })
      .margin({ left: 8 })
      .borderRadius(18)
      .backgroundColor('#12000000')
      .onClick(onClick)
  }

  @Builder
  private historyFileListPanel() {
    if (this.historyFiles.length === 0) {
      Column() {
        Text('暂无历史文件')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_BLACK)
        Text('主机端生成并下发到手机的文件会出现在这里。')
          .fontSize(13)
          .fontColor('#777777')
          .lineHeight(20)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      Scroll() {
        Column() {
          ForEach(this.historyFiles, (file: LocalHistoryFile) => {
            this.historyFileRow(file);
          }, (file: LocalHistoryFile) => file.id)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
    }
  }

  @Builder
  private historyFileRow(file: LocalHistoryFile) {
    Row() {
      Text(this.historyFileKindIcon(file.kind))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK_WHITE)
        .textAlign(TextAlign.Center)
        .width(38)
        .height(38)
        .padding({ top: 9 })
        .borderRadius(19)
        .backgroundColor(this.historyFileKindColor(file.kind))
        .margin({ right: 12 })

      Column() {
        Text(file.name)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_BLACK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.formatBytes(file.sizeBytes)} · ${file.kind} · ${file.modifiedAt}`)
          .fontSize(12)
          .fontColor('#777777')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(file.previewable ? '浏览' : '详情')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK_BLACK)
        .textAlign(TextAlign.Center)
        .width(48)
        .height(32)
        .padding({ top: 8 })
        .borderRadius(16)
        .backgroundColor('#12000000')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .margin({ bottom: 10 })
    .borderRadius(18)
    .backgroundColor('#F4FFFFFF')
    .border({ width: 1, color: LINE })
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.openHistoryFilePreview(file))
  }

  @Builder
  private historyFilePreviewPanel() {
    Column() {
      Row() {
        Text('←')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK_BLACK)
          .textAlign(TextAlign.Center)
          .width(34)
          .height(34)
          .padding({ top: 7 })
          .borderRadius(17)
          .backgroundColor('#12000000')
          .onClick(() => this.historyFilePreviewVisible = false)

        Column() {
          Text(this.historyFilePreviewTitle)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK_BLACK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.historyFilePreviewMeta)
            .fontSize(12)
            .fontColor('#777777')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 10 })

      Text(this.historyFilePreviewPath)
        .fontSize(11)
        .fontColor('#777777')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .borderRadius(12)
        .backgroundColor('#0C000000')
        .margin({ bottom: 10 })

      if (this.historyFilePreviewKind === 'image') {
        Column() {
          Image(this.historyFilePreviewPath)
            .width('100%')
            .layoutWeight(1)
            .objectFit(ImageFit.Contain)
            .backgroundColor('#0C000000')
        }
        .layoutWeight(1)
        .width('100%')
        .borderRadius(14)
        .clip(true)
      } else {
        Scroll() {
          Column() {
            if (this.historyFilePreviewMarkdown) {
              MarkdownMessageText({
                text: this.historyFilePreviewText,
                ageLevel: 0,
              })
            } else {
              Text(this.historyFilePreviewText)
                .fontSize(13)
                .fontColor(INK_BLACK)
                .lineHeight(20)
                .width('100%')
            }
          }
          .width('100%')
          .padding(12)
        }
        .layoutWeight(1)
        .width('100%')
        .borderRadius(14)
        .backgroundColor('#F2FFFFFF')
        .border({ width: 1, color: LINE })
      }

      Row() {
        this.sheetAction('复制路径', false, () => this.copyHistoryFilePath());
        this.sheetAction('关闭', true, () => this.closeHistoryFiles());
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .layoutWeight(1)
    .width('100%')
  }

  @Builder
  private historyRecordRow(record: ChatRecord) {
    Row() {
      Blank()
        .width(4)
        .height(38)
        .borderRadius(2)
        .backgroundColor(record.id === this.selectedRecord.id ? INK_BLACK : '#00000000')
        .margin({ right: 12 })

      Column() {
        Text(record.title)
          .fontSize(16)
          .fontColor(INK_BLACK)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(record.subtitle)
          .fontSize(12)
          .fontColor('#777777')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .padding({ top: 8, bottom: 8 })
      .alignItems(HorizontalAlign.Start)

      Text('↑')
        .fontSize(17)
        .fontColor(BLUE)
        .width(34)
        .height(34)
        .padding({ top: 7 })
        .textAlign(TextAlign.Center)
        .borderRadius(17)
        .backgroundColor('#144D8CFF')

      Text('×')
        .fontSize(17)
        .fontColor(DANGER)
        .width(34)
        .height(34)
        .padding({ top: 6 })
        .margin({ left: 6 })
        .textAlign(TextAlign.Center)
        .borderRadius(17)
        .backgroundColor('#12F44336')
        .onClick(() => {
          this.deleteConfirmRecordId = record.id;
        })
    }
    .width('100%')
    .padding({ left: 12, right: 10, top: 10, bottom: 10 })
    .margin({ bottom: 10 })
    .borderRadius(20)
    .backgroundColor(record.id === this.selectedRecord.id ? '#F2FFFFFF' : '#A8FFFFFF')
    .border({ width: 1, color: record.id === this.selectedRecord.id ? LINE : '#0D000000' })
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.selectRecord(record))
  }

  @Builder
  private modelMenuOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      }
        .width('100%')
        .height('100%')
        .backgroundColor('#01000000')
        .onClick(() => this.modelMenuVisible = false)

      Column() {
        if (this.availableConfiguredModels().length === 0) {
          this.modelMenuItem('暂无可用模型', '请先添加 API Key', false, () => {
            this.modelMenuVisible = false;
            this.openSettings(SettingsSheetMode.ModelOnly);
          });
        }
        ForEach(this.availableConfiguredModels(), (configured: ConfiguredModel) => {
          this.modelMenuItem(
            configured.displayName,
            configured.model,
            configured.id === this.modelSettings.configuredModelId,
            async () => {
              const nextSettings = configuredModelToSettings(configured);
              this.modelSettings = nextSettings;
              this.modelMenuVisible = false;
              await ChatPersistence.saveModelSettings(this.abilityContext(), nextSettings);
            },
          );
        }, (configured: ConfiguredModel) => configured.id)
        this.modelMenuItem('自定义', '跳转到模型配置', false, () => {
          this.modelMenuVisible = false;
          this.openSettings(SettingsSheetMode.ModelOnly);
        });
      }
      .width(260)
      .margin({ top: 56, left: 48 })
      .borderRadius(26)
      .backgroundColor('#EEF2F2F7')
      .border({ width: 1, color: LINE })
      .padding({ top: 6, bottom: 6 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private modelMenuItem(title: string, subtitle: string, selected: boolean, onClick: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(selected ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(INK_BLACK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(subtitle)
          .fontSize(12)
          .fontColor('#666666')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      if (selected) {
        Text('✓')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(onClick)
  }

  @Builder
  private settingsSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
      }
        .width('100%')
        .height('100%')
        .backgroundColor(DIM_OVERLAY)
        .onClick(() => this.settingsVisible = false)

      Column() {
        Row() {
          Text(this.settingsSheetMode === SettingsSheetMode.ModelOnly ? '模型配置' : '自定义 Amaduse')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
          Text('×')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .width(42)
            .height(42)
            .textAlign(TextAlign.Center)
            .onClick(() => this.settingsVisible = false)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column() {
            if (this.settingsSheetMode === SettingsSheetMode.Full) {
              this.settingsMenuSection();
            }
            this.modelSettingsSection();
            this.modelParamsSection();
            this.voiceSettingsSection();
            if (this.settingsSheetMode === SettingsSheetMode.Full) {
              this.appSettingsSection();
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        Row() {
          this.sheetAction('取消', false, () => this.settingsVisible = false);
          this.sheetAction('保存', true, () => this.saveSettings());
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .height('88%')
      .padding(14)
      .borderRadius(28)
      .backgroundColor('#F2FBFBFB')
      .border({ width: 1, color: LINE })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private settingsMenuSection() {
    Column() {
      Column() {
        this.settingsRow('个性化', '人格、语调、称呼');
      }
      .width('100%')
      .padding(10)
      .borderRadius(20)
      .backgroundColor(GLASS_LIGHT)
      .border({ width: 1, color: LINE })
    }
    .width('100%')
    .margin({ top: 14 })

    Column() {
      Text('账户')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#666666')
        .margin({ bottom: 8 })
        .alignSelf(ItemAlign.Start)
      Column() {
        this.settingsRow('用户', 'Local Agent');
        this.settingsRow('连接电脑', '未连接');
      }
      .width('100%')
      .padding(10)
      .borderRadius(20)
      .backgroundColor(GLASS_LIGHT)
      .border({ width: 1, color: LINE })
    }
    .width('100%')
    .margin({ top: 14 })
  }

  @Builder
  private modelSettingsSection() {
    Column() {
      Text('模型配置服务')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#666666')
        .margin({ bottom: 8 })
        .alignSelf(ItemAlign.Start)
      Column() {
        if (this.availableConfiguredModels().length === 0) {
          Text('还没有配置 API Key 的模型。添加后会出现在顶部模型下拉栏。')
            .fontSize(14)
            .fontColor('#666666')
            .lineHeight(20)
        }
        ForEach(this.availableConfiguredModels(), (item: ConfiguredModel) => {
          this.configuredModelRow(item);
        }, (item: ConfiguredModel) => item.id)

        this.smallPill('添加模型', false, () => {
          this.editModelId = '';
          this.editProvider = modelProviderPresets.find((item: ModelProviderPreset) => item.name === '自定义') as ModelProviderPreset;
          this.editDisplayName = '自定义';
          this.editModel = this.editProvider.defaultModel;
          this.editBaseUrl = this.editProvider.baseUrl;
          this.editApiKey = '';
        });

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.providerOptions(), (preset: ModelProviderPreset) => {
            this.providerChip(preset);
          }, (preset: ModelProviderPreset) => preset.name)
        }
        .width('100%')
      }
      .width('100%')
    }
    .width('100%')
    .padding(10)
    .borderRadius(20)
    .backgroundColor(GLASS_LIGHT)
    .border({ width: 1, color: LINE })
    .margin({ top: 14 })
  }

  @Builder
  private configuredModelRow(item: ConfiguredModel) {
    Column() {
      Row() {
        Column() {
          Text(item.displayName)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${item.provider.name} · ${item.model}`)
            .fontSize(12)
            .fontColor('#666666')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        if (item.id === this.editModelId) {
          Text('✓').fontSize(16).fontWeight(FontWeight.Bold)
        }
      }
      Row() {
        this.smallPill('编辑', item.id === this.editModelId, () => {
          this.editModelId = item.id;
          this.editProvider = item.provider;
          this.editDisplayName = item.displayName;
          this.editModel = item.model;
          this.editBaseUrl = item.baseUrl;
          this.editApiKey = item.apiKey;
        });
        this.smallPill('删除', false, () => {
          this.configuredModels = this.configuredModels.filter((model: ConfiguredModel) => model.id !== item.id);
          if (this.editModelId === item.id) {
            this.editModelId = '';
          }
        });
      }
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(10)
    .borderRadius(16)
    .backgroundColor(item.id === this.editModelId ? '#14000000' : '#60EFEFED')
  }

  @Builder
  private providerChip(preset: ModelProviderPreset) {
    Text(preset.name)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.editProvider.name === preset.name ? INK_WHITE : INK_BLACK)
      .padding({ left: 11, right: 11, top: 8, bottom: 8 })
      .margin({ right: 8, bottom: 8 })
      .borderRadius(999)
      .backgroundColor(this.editProvider.name === preset.name ? INK_BLACK : MIST)
      .onClick(() => {
        this.editProvider = preset;
        this.editModel = preset.defaultModel;
        this.editBaseUrl = preset.baseUrl;
        if (this.editDisplayName.length === 0 || this.editDisplayName === '自定义') {
          this.editDisplayName = preset.name;
        }
      })
  }

  @Builder
  private modelParamsSection() {
    Column() {
      Text('自定义模型参数配置')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#666666')
        .margin({ bottom: 8 })
        .alignSelf(ItemAlign.Start)
      Column() {
        Text(this.editProvider.note)
          .fontSize(12)
          .fontColor('#666666')
          .lineHeight(18)
        this.inputField('显示名称', this.editDisplayName, (value: string) => this.editDisplayName = value, this.editProvider.name, false);
        this.inputField('Base URL', this.editBaseUrl, (value: string) => this.editBaseUrl = value, '', false);
        this.inputField('Model', this.editModel, (value: string) => this.editModel = value, '', false);
        this.inputField('API Key', this.editApiKey, (value: string) => this.editApiKey = value, 'sk-...', true);
      }
      .width('100%')
      .padding(10)
      .borderRadius(20)
      .backgroundColor(GLASS_LIGHT)
      .border({ width: 1, color: LINE })
    }
    .width('100%')
    .margin({ top: 14 })
  }

  @Builder
  private voiceSettingsSection() {
    Column() {
      Text('硅基流动语音')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#666666')
        .margin({ bottom: 8 })
        .alignSelf(ItemAlign.Start)
      Column() {
        Text('默认使用硅基流动 CosyVoice2 和 rawfile/voices/kurisu-reference.wav 参考音频。朗读前会按人格语言翻译为日语，长文本按段生成，最多两个云端任务并行准备并按原顺序播放；思考过程不会进入语音输出。')
          .fontSize(12)
          .fontColor('#666666')
          .lineHeight(18)
        this.inputField('SiliconFlow API Key', this.editVoiceApiKey, (value: string) => this.editVoiceApiKey = value, 'sk-...', true);
        this.inputField('Voice URI', this.editVoiceUri, (value: string) => this.editVoiceUri = value, 'speech:...', false);
        this.voiceSwitchRow('云端语音', '关闭后不再请求语音生成服务', 'enabled');
        this.voiceSwitchRow('自动播报', '模型回复完成后自动播放语音', 'autoPlay');
        this.voiceSwitchRow('语音字幕同步', '接收到对应语音后再流式显示字幕', 'sync');
      }
      .width('100%')
      .padding(10)
      .borderRadius(20)
      .backgroundColor(GLASS_LIGHT)
      .border({ width: 1, color: LINE })
    }
    .width('100%')
    .margin({ top: 14 })
  }

  @Builder
  private appSettingsSection() {
    Column() {
      Text('主题')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#666666')
        .margin({ bottom: 8 })
        .alignSelf(ItemAlign.Start)
      Column() {
        this.settingsRow('外观', '系统');
        this.settingsRow('重点色', '默认');
      }
      .width('100%')
      .padding(10)
      .borderRadius(20)
      .backgroundColor(GLASS_LIGHT)
      .border({ width: 1, color: LINE })
    }
    .width('100%')
    .margin({ top: 14 })

    Column() {
      Text('主机后端 Agent')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#666666')
        .margin({ bottom: 8 })
        .alignSelf(ItemAlign.Start)
      Column() {
        this.hostAgentSwitchRow();
        this.inputField('Backend URL', this.editHostAgentBaseUrl, (value: string) => this.editHostAgentBaseUrl = value, 'http://192.168.1.10:8000', false);
        this.inputField('Endpoint Path', this.editHostAgentEndpointPath, (value: string) => this.editHostAgentEndpointPath = value, '/api/agent/invoke', false);
        this.inputField('Backend Key', this.editHostAgentApiKey, (value: string) => this.editHostAgentApiKey = value, 'optional', true);
      }
      .width('100%')
      .padding(10)
      .borderRadius(20)
      .backgroundColor(GLASS_LIGHT)
      .border({ width: 1, color: LINE })
    }
    .width('100%')
    .margin({ top: 14 })

    Column() {
      Text('应用设置')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#666666')
        .margin({ bottom: 8 })
        .alignSelf(ItemAlign.Start)
      Column() {
        this.settingsRow('常规', '');
        this.settingsRow('声音', '');
        this.settingsRow('安全与安保', '');
        this.settingsRow('数据控制', '');
      }
      .width('100%')
      .padding(10)
      .borderRadius(20)
      .backgroundColor(GLASS_LIGHT)
      .border({ width: 1, color: LINE })
    }
    .width('100%')
    .margin({ top: 14 })
  }

  @Builder
  private settingsRow(title: string, value: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .layoutWeight(1)
      if (value.length > 0) {
        Text(value)
          .fontSize(15)
          .fontColor('#666666')
      }
      Text('›')
        .fontSize(20)
        .fontColor('#777777')
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private inputField(label: string, value: string, onChange: (value: string) => void, placeholder: string, secret: boolean) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor('#666666')
      if (secret) {
        TextInput({ text: value, placeholder })
          .type(InputType.Password)
          .fontSize(15)
          .fontColor(INK_BLACK)
          .placeholderColor('#777777')
          .backgroundColor('#BFEFEFED')
          .borderRadius(16)
          .padding({ left: 12, right: 12 })
          .onChange(onChange)
      } else {
        TextInput({ text: value, placeholder })
          .fontSize(15)
          .fontColor(INK_BLACK)
          .placeholderColor('#777777')
          .backgroundColor('#BFEFEFED')
          .borderRadius(16)
          .padding({ left: 12, right: 12 })
          .onChange(onChange)
      }
    }
    .width('100%')
    .margin({ top: 8 })
  }

  @Builder
  private voiceSwitchRow(label: string, detail: string, kind: string) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row() {
        Column() {
          Text(label)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK_BLACK)
          Text(detail)
            .fontSize(11)
            .fontColor('#777777')
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row() {
          Blank()
            .width(19)
            .height(19)
            .borderRadius(10)
            .backgroundColor(INK_WHITE)
            .shadow({
              radius: 4,
              color: '#26000000',
              offsetX: 0,
              offsetY: 1,
            })
        }
        .width(42)
        .height(24)
        .padding(2)
        .borderRadius(999)
        .backgroundColor(this.voiceSwitchSelected(kind) ? INK_BLACK : '#2A000000')
        .justifyContent(this.voiceSwitchSelected(kind) ? FlexAlign.End : FlexAlign.Start)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(54)
    .padding(0)
    .margin({ top: 8 })
    .borderRadius(16)
    .backgroundColor(this.voiceSwitchSelected(kind) ? '#0D000000' : '#70EFEFED')
    .onClick(() => this.toggleVoiceSwitch(kind, label))
  }

  @Builder
  private hostAgentSwitchRow() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row() {
        Column() {
          Text('启用主机后端')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK_BLACK)
          Text('允许模型把需要电脑能力的任务转发到后端')
            .fontSize(11)
            .fontColor('#777777')
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row() {
          Blank()
            .width(19)
            .height(19)
            .borderRadius(10)
            .backgroundColor(INK_WHITE)
            .shadow({
              radius: 4,
              color: '#26000000',
              offsetX: 0,
              offsetY: 1,
            })
        }
        .width(42)
        .height(24)
        .padding(2)
        .borderRadius(999)
        .backgroundColor(this.editHostAgentEnabled ? INK_BLACK : '#2A000000')
        .justifyContent(this.editHostAgentEnabled ? FlexAlign.End : FlexAlign.Start)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(54)
    .padding(0)
    .margin({ top: 8 })
    .borderRadius(16)
    .backgroundColor(this.editHostAgentEnabled ? '#0D000000' : '#70EFEFED')
    .onClick(() => this.editHostAgentEnabled = !this.editHostAgentEnabled)
  }

  @Builder
  private sheetAction(text: string, selected: boolean, onClick: () => void) {
    Text(text)
      .fontSize(15)
      .fontWeight(FontWeight.Bold)
      .fontColor(selected ? INK_WHITE : INK_BLACK)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(42)
      .padding({ top: 11 })
      .borderRadius(999)
      .backgroundColor(selected ? INK_BLACK : MIST)
      .margin({ left: selected ? 4 : 0, right: selected ? 0 : 4 })
      .onClick(onClick)
  }

  @Builder
  private smallPill(text: string, selected: boolean, onClick: () => void) {
    Text(text)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(selected ? INK_WHITE : INK_BLACK)
      .textAlign(TextAlign.Center)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius(999)
      .backgroundColor(selected ? INK_BLACK : MIST)
      .margin({ right: 8, top: 8 })
      .onClick(onClick)
  }

  @Builder
  private confirmSheet(title: string, detail: string, onConfirm: () => void, onDismiss: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
      }
        .width('100%')
        .height('100%')
        .backgroundColor(DIM_OVERLAY)
        .onClick(onDismiss)
      Column() {
        Text(title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
        Text(detail)
          .fontSize(14)
          .fontColor('#666666')
          .lineHeight(20)
          .margin({ top: 8, bottom: 16 })
        Row() {
          this.sheetAction('取消', false, onDismiss);
          this.sheetAction('确认', true, onConfirm);
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(24)
      .backgroundColor('#F8FFFFFF')
      .border({ width: 1, color: LINE })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private loadingOverlay() {
    Column() {
      Text('Amaduse')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK_BLACK)
      Text('Loading Kurisu memory data...')
        .fontSize(13)
        .fontColor('#666666')
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F7F7F5')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private circleButton(text: string, onClick: () => void) {
    Text(text)
      .fontSize(20)
      .fontWeight(FontWeight.Bold)
      .fontColor(INK_BLACK)
      .textAlign(TextAlign.Center)
      .width(38)
      .height(38)
      .padding({ top: 6 })
      .borderRadius(19)
      .backgroundColor(GLASS_LIGHT)
      .border({ width: 1, color: LINE })
      .onClick(onClick)
  }

  @Builder
  private actionCircle(text: string, onClick: () => void, primary: boolean) {
    Text(text)
      .fontSize(20)
      .fontWeight(FontWeight.Bold)
      .fontColor(primary ? INK_WHITE : INK_BLACK)
      .textAlign(TextAlign.Center)
      .width(40)
      .height(40)
      .padding({ top: 6 })
      .borderRadius(20)
      .backgroundColor(primary ? INK_BLACK : '#18000000')
      .onClick(onClick)
  }

  @Builder
  private voiceActionButton(active: boolean, onClick: () => void) {
    Row() {
      if (active) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(INK_BLACK)
      } else {
        Image($r('app.media.ic_voice_wait'))
          .width(22)
          .height(22)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor(active ? '#26000000' : '#18000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick(onClick)
  }

  @Builder
  private statusDot(active: boolean) {
    Blank()
      .width(7)
      .height(7)
      .borderRadius(4)
      .backgroundColor(active ? ACTIVE_GREEN : '#8D8D8D')
      .margin({ right: 7 })
  }

  private currentModelLabel(): string {
    const currentConfigured = this.configuredModels.find((item: ConfiguredModel) => item.id === this.modelSettings.configuredModelId);
    if (currentConfigured !== undefined) {
      return currentConfigured.displayName;
    }
    if (this.modelSettings.apiKey.length > 0 || this.modelSettings.provider.name === 'Ollama') {
      return this.modelSettings.provider.name;
    }
    return '未配置';
  }

  private availableConfiguredModels(): ConfiguredModel[] {
    return this.configuredModels.filter((item: ConfiguredModel) => item.apiKey.length > 0 || item.provider.name === 'Ollama');
  }

  private providerOptions(): ModelProviderPreset[] {
    return modelProviderPresets.filter((item: ModelProviderPreset) => item.name !== '演示模型');
  }

  private codeTaskConnectionLabel(): string {
    if (!CodeTaskRemoteService.isConfigured(this.hostAgentSettings)) {
      return '未配置远程主机';
    }
    if (this.codeTaskBridgeConnected) {
      return this.codeTaskConnectionMessage.length > 0 ? this.codeTaskConnectionMessage : '已连接主机 bridge';
    }
    if (this.codeTaskConnectionMessage.length > 0) {
      return this.codeTaskConnectionMessage;
    }
    return this.hostAgentSettings.baseUrl;
  }

  private openCodeTaskScreen(): void {
    this.setCodeTaskProgress(1);
    this.startCodeTaskListRefresh();
    if (CodeTaskRemoteService.isConfigured(this.hostAgentSettings)) {
      this.refreshCodeTasks();
    }
  }

  private closeCodeTaskScreen(): void {
    this.setCodeTaskProgress(0);
    this.stopCodeTaskListRefresh();
    this.clearCodeTaskReopenRefresh();
    this.codeTaskDetachedFromBottom = false;
  }

  private startCodeTaskListRefresh(): void {
    this.connectCodeTaskBridge();
  }

  private stopCodeTaskListRefresh(): void {
    if (this.codeTaskRefreshTimer >= 0) {
      clearInterval(this.codeTaskRefreshTimer);
      this.codeTaskRefreshTimer = -1;
    }
  }

  private connectCodeTaskBridge(): void {
    if (!CodeTaskRemoteService.isConfigured(this.hostAgentSettings)) {
      return;
    }
    if (this.codeTaskBridge !== undefined) {
      return;
    }
    if (this.codeTaskBridgeReconnectTimer >= 0) {
      clearTimeout(this.codeTaskBridgeReconnectTimer);
      this.codeTaskBridgeReconnectTimer = -1;
    }
    this.codeTaskConnectionMessage = '正在连接主机 bridge...';
    try {
      this.codeTaskBridge = CodeTaskRemoteService.connectBridge(this.hostAgentSettings, {
        onOpen: (): void => {
          this.codeTaskBridgeConnected = true;
          this.codeTaskConnectionMessage = 'bridge 已打开，等待主机快照...';
          this.startCodeTaskBridgeHeartbeat();
        },
        onHello: (message: string): void => {
          this.codeTaskBridgeConnected = true;
          this.codeTaskConnectionMessage = message.length > 0 ? '已连接主机 bridge' : '已连接主机 bridge';
          this.startCodeTaskBridgeHeartbeat();
          this.refreshCodeTasks();
        },
        onView: (view: CodeTaskMobileViewSnapshot, seq: number): void => {
          this.codeTaskBridgeConnected = true;
          this.codeTaskLastViewSeq = Math.max(this.codeTaskLastViewSeq, seq);
          this.applyCodeTaskMobileView(view);
        },
        onError: (message: string): void => {
          this.handleCodeTaskBridgeFailure(`bridge 错误：${message.substring(0, 80)}`);
        },
        onDone: (): void => {
          this.codeTaskBridgeConnected = false;
          this.codeTaskBridge = undefined;
          this.stopCodeTaskBridgeHeartbeat();
          if (this.codeTaskProgress > 0 && CodeTaskRemoteService.isConfigured(this.hostAgentSettings)) {
            this.scheduleCodeTaskBridgeReconnect();
          }
        },
      });
      this.startCodeTaskBridgeHeartbeat();
    } catch (error) {
      this.codeTaskBridge = undefined;
      this.codeTaskBridgeConnected = false;
      this.stopCodeTaskBridgeHeartbeat();
      this.codeTaskConnectionMessage = `bridge 连接失败：${errorToString(error).substring(0, 80)}`;
      this.scheduleCodeTaskBridgeReconnect();
    }
  }

  private scheduleCodeTaskBridgeReconnect(): void {
    if (this.codeTaskBridgeReconnectTimer >= 0 || this.codeTaskProgress <= 0) {
      return;
    }
    this.codeTaskBridgeReconnectTimer = setTimeout((): void => {
      this.codeTaskBridgeReconnectTimer = -1;
      this.connectCodeTaskBridge();
    }, 3000);
  }

  private startCodeTaskBridgeHeartbeat(): void {
    if (this.codeTaskBridgeHeartbeatTimer >= 0) {
      return;
    }
    this.codeTaskBridgeHeartbeatTimer = setInterval((): void => {
      this.pingCodeTaskBridge();
    }, CODE_TASK_BRIDGE_HEARTBEAT_MS);
  }

  private stopCodeTaskBridgeHeartbeat(): void {
    if (this.codeTaskBridgeHeartbeatTimer >= 0) {
      clearInterval(this.codeTaskBridgeHeartbeatTimer);
      this.codeTaskBridgeHeartbeatTimer = -1;
    }
  }

  private pingCodeTaskBridge(): void {
    if (this.codeTaskProgress <= 0 || this.codeTaskBridge === undefined) {
      return;
    }
    this.codeTaskBridge.ping().then((): void => {
      this.codeTaskBridgeConnected = true;
    }).catch((error: Error | Object | string): void => {
      const message = errorToString(error);
      if (message.indexOf('已有主机指令正在提交') >= 0) {
        return;
      }
      this.handleCodeTaskBridgeFailure(`bridge 心跳失败：${message.substring(0, 80)}`);
    });
  }

  private handleCodeTaskBridgeFailure(message: string): void {
    this.codeTaskConnectionMessage = message;
    this.stopCodeTaskBridgeHeartbeat();
    if (this.codeTaskBridge !== undefined) {
      try {
        this.codeTaskBridge.close();
      } catch (_) {
      }
      this.codeTaskBridge = undefined;
    }
    this.codeTaskBridgeConnected = false;
    if (this.codeTaskProgress > 0 && CodeTaskRemoteService.isConfigured(this.hostAgentSettings)) {
      this.scheduleCodeTaskBridgeReconnect();
      this.refreshCodeTasks();
    }
  }

  private disconnectCodeTaskBridge(): void {
    if (this.codeTaskBridgeReconnectTimer >= 0) {
      clearTimeout(this.codeTaskBridgeReconnectTimer);
      this.codeTaskBridgeReconnectTimer = -1;
    }
    this.stopCodeTaskBridgeHeartbeat();
    if (this.codeTaskBridge !== undefined) {
      this.codeTaskBridge.close();
      this.codeTaskBridge = undefined;
    }
    this.codeTaskBridgeConnected = false;
  }

  private refreshCodeTasksIfIdle(): void {
    if (this.codeTaskProgress <= 0 || !CodeTaskRemoteService.isConfigured(this.hostAgentSettings)) {
      return;
    }
    if (this.codeTaskLoading || this.codeTaskSending || this.codeTaskReplying) {
      return;
    }
    if (
      (this.selectedCodeTaskRunning ||
        this.hasLocalCodeTaskProcessing() ||
        this.hasPendingCodeTaskQuestionReply(this.selectedCodeTaskId)) &&
        this.selectedCodeTaskId.length > 0
    ) {
      return;
    }
    this.refreshCodeTasks();
  }

  private async refreshCodeTasks(): Promise<void> {
    if (!CodeTaskRemoteService.isConfigured(this.hostAgentSettings)) {
      this.codeTaskConnectionMessage = '请先配置远程主机。';
      return;
    }
    this.connectCodeTaskBridge();
    this.codeTaskLoading = true;
    this.codeTaskConnectionMessage = this.codeTaskBridgeConnected ? '正在读取主机任务视图...' : '正在连接主机...';
    try {
      const views = await CodeTaskRemoteService.listTaskViews(this.hostAgentSettings);
      if (views.length > 0) {
        this.syncCodeTaskMobileViewRecords(views);
        this.codeTaskConnectionMessage = '已同步主机任务视图';
        return;
      }
      this.codeTaskViewSnapshots = [];
      const tasks = await CodeTaskRemoteService.listTasks(this.hostAgentSettings);
      this.codeTasks = tasks;
      this.codeTaskConnectionMessage = tasks.length > 0 ? '已连接主机' : '主机暂无 OpenCode 任务。';
      const current = tasks.find((task: CodeTaskSummary): boolean => task.id === this.selectedCodeTaskId);
      if (current !== undefined) {
        await this.selectCodeTask(current, false);
      } else if (tasks.length === 0) {
        this.clearSelectedCodeTask();
      } else if (tasks.length > 0 && this.selectedCodeTaskId.length === 0) {
        await this.selectCodeTask(tasks[0], false);
      } else {
        this.clearSelectedCodeTask();
      }
    } catch (error) {
      this.codeTaskConnectionMessage = `连接失败：${errorToString(error).substring(0, 80)}`;
      this.showToast(this.codeTaskConnectionMessage);
    } finally {
      this.codeTaskLoading = false;
    }
  }

  private async selectCodeTask(task: CodeTaskSummary, showLoading: boolean = true): Promise<void> {
    const sameTask = this.selectedCodeTaskId === task.id;
    this.selectedCodeTaskId = task.id;
    this.selectedCodeTaskTitle = stringValue(task.title, 'OpenCode 任务');
    this.selectedCodeTaskStatus = this.codeTaskSummaryStatus(task, 'idle');
    this.selectedCodeTaskRunning = this.isCodeTaskTaskRunning(task.running, this.selectedCodeTaskStatus, task.backgroundRunning);
    this.selectedCodeTaskSummary = stringValue(task.summary);
    this.selectedCodeTaskQuestions = this.codeTaskQuestionsForDisplay(task.id, task.pendingQuestions);
    if (!sameTask) {
      this.codeTaskEvents = [];
      this.codeTaskExpandedTurnIds = [];
      this.codeTaskDetachedFromBottom = false;
      this.clearPendingCodeTaskQuestionReply();
    }
    this.initCodeTaskQuestionDrafts();
    if (showLoading) {
      this.codeTaskLoading = true;
    }
    try {
      const cachedView = this.findCodeTaskMobileView(task.id);
      if (cachedView !== undefined) {
        const wasAtBottom = sameTask ? this.shouldAutoFollowCodeTaskBottom() : true;
        this.applyCodeTaskMobileView(cachedView, true, false);
        this.codeTaskConnectionMessage = '已打开主机任务视图';
        if (sameTask) {
          this.preserveCodeTaskScrollAfterUpdate(wasAtBottom);
        } else {
          this.scrollCodeTaskToBottom(true);
        }
        return;
      }
      const detail = await CodeTaskRemoteService.getTaskDetail(this.hostAgentSettings, task.id);
      const wasAtBottom = sameTask ? this.shouldAutoFollowCodeTaskBottom() : true;
      this.applyCodeTaskDetail(detail);
      this.codeTaskConnectionMessage = '已读取任务详情';
      if (sameTask) {
        this.preserveCodeTaskScrollAfterUpdate(wasAtBottom);
      } else {
        this.scrollCodeTaskToBottom(true);
      }
    } catch (error) {
      this.codeTaskConnectionMessage = `任务读取失败：${errorToString(error).substring(0, 80)}`;
      this.showToast(this.codeTaskConnectionMessage);
    } finally {
      if (showLoading) {
        this.codeTaskLoading = false;
      }
    }
  }

  private applyCodeTaskDetail(task: CodeTaskDetail, forceEvents: boolean = false): void {
    this.selectedCodeTaskId = task.id;
    this.selectedCodeTaskTitle = stringValue(task.title, 'OpenCode 任务');
    const taskStatus = stringValue(task.status);
    const snapshotStatus = stringValue(task.snapshot?.status);
    const detailStatus = !this.isCodeTaskTerminalStatus(taskStatus) && this.isCodeTaskTerminalStatus(snapshotStatus)
      ? snapshotStatus
      : stringValue(taskStatus, stringValue(snapshotStatus, 'idle'));
    const nextRunning = this.isCodeTaskTaskRunning(task.running, detailStatus, task.backgroundRunning);
    const preserveLocalProcessing = this.shouldPreserveLocalCodeTaskProcessing(task, detailStatus, nextRunning, forceEvents);
    const keepTerminalStatus = this.isCodeTaskTerminalStatus(this.selectedCodeTaskStatus) &&
      !this.isCodeTaskTerminalStatus(detailStatus);
    if (!preserveLocalProcessing && !keepTerminalStatus) {
      this.selectedCodeTaskStatus = detailStatus;
      this.selectedCodeTaskRunning = nextRunning;
    }
    if (!preserveLocalProcessing) {
      this.selectedCodeTaskSummary = stringValue(task.summary, stringValue(task.snapshot?.summary, this.selectedCodeTaskSummary));
    }
    this.selectedCodeTaskQuestions = this.codeTaskQuestionsForDisplay(task.id, task.pendingQuestions);
    const events = Array.isArray(task.events) ? task.events : [];
    const snapshotEvents = this.codeTaskSnapshotEvents(task);
    if (preserveLocalProcessing) {
      // Keep the optimistic mobile turn until the host task history contains this mobile input.
    } else if (forceEvents && (events.length > 0 || snapshotEvents.length > 0)) {
      this.codeTaskEvents = events.length >= snapshotEvents.length ? events : snapshotEvents;
    } else if (events.length > 0 && events.length >= snapshotEvents.length && events.length >= this.codeTaskEvents.length) {
      this.codeTaskEvents = events;
    } else if (snapshotEvents.length > 0 && snapshotEvents.length >= this.codeTaskEvents.length) {
      this.codeTaskEvents = snapshotEvents;
    } else if (this.codeTaskEvents.length === 0) {
      this.codeTaskEvents = snapshotEvents;
    }
    this.initCodeTaskQuestionDrafts();
    this.syncCodeTaskExpandedTurns();
    if (!preserveLocalProcessing) {
      this.upsertCodeTaskSummary(task);
    }
  }

  private findCodeTaskMobileView(taskId: string): CodeTaskMobileViewSnapshot | undefined {
    return this.codeTaskViewSnapshots.find((view: CodeTaskMobileViewSnapshot): boolean => {
      return this.codeTaskMobileViewTaskId(view) === taskId;
    });
  }

  private syncCodeTaskMobileViewRecords(records: CodeTaskViewRecord[]): void {
    const views: CodeTaskMobileViewSnapshot[] = [];
    records.forEach((record: CodeTaskViewRecord): void => {
      if (record.snapshot === undefined) {
        return;
      }
      if (this.isCodeTaskMobileViewDeleted(record.snapshot)) {
        this.removeCodeTaskMobileView(this.codeTaskMobileViewTaskId(record.snapshot));
        return;
      }
      views.push(record.snapshot);
    });
    const activeIds: string[] = [];
    views.forEach((view: CodeTaskMobileViewSnapshot): void => {
      const taskId = this.codeTaskMobileViewTaskId(view);
      if (taskId.length > 0 && activeIds.indexOf(taskId) < 0) {
        activeIds.push(taskId);
      }
    });
    if (activeIds.length === 0) {
      this.codeTaskViewSnapshots = [];
      this.codeTasks = [];
      this.clearSelectedCodeTask();
      return;
    }
    if (this.selectedCodeTaskId.length > 0 && activeIds.indexOf(this.selectedCodeTaskId) < 0) {
      this.clearSelectedCodeTask();
    }
    this.codeTaskViewSnapshots = [];
    this.codeTasks = [];
    views.forEach((view: CodeTaskMobileViewSnapshot): void => {
      this.applyCodeTaskMobileView(view);
    });
  }

  private applyCodeTaskMobileView(
    view: CodeTaskMobileViewSnapshot,
    forceSelect: boolean = false,
    updateScroll: boolean = true,
  ): void {
    const taskId = this.codeTaskMobileViewTaskId(view);
    if (taskId.length === 0) {
      return;
    }
    if (this.isCodeTaskMobileViewDeleted(view)) {
      this.removeCodeTaskMobileView(taskId);
      return;
    }
    const existingIndex = this.codeTaskViewSnapshots.findIndex((item: CodeTaskMobileViewSnapshot): boolean => {
      return this.codeTaskMobileViewTaskId(item) === taskId;
    });
    if (existingIndex >= 0) {
      const next = this.codeTaskViewSnapshots.slice();
      next[existingIndex] = view;
      this.codeTaskViewSnapshots = next;
    } else {
      this.codeTaskViewSnapshots = this.codeTaskViewSnapshots.concat([view]);
    }

    const summary = this.codeTaskSummaryFromMobileView(view);
    this.upsertCodeTaskSummary(summary);
    
    // 判断是否需要选中并更新UI
    const shouldSelect = forceSelect || this.selectedCodeTaskId.length === 0 || this.selectedCodeTaskId === taskId;
    
    // 即使不需要选中，如果当前选中的就是这个任务，也需要更新UI状态
    const isCurrentSelectedTask = this.selectedCodeTaskId === taskId;
    
    if (!shouldSelect && !isCurrentSelectedTask) {
      return;
    }
    const sameTask = this.selectedCodeTaskId === taskId;
    const previousEventCount = this.codeTaskEvents.length;
    const previousFirstSeq = this.codeTaskEvents.length > 0 ? this.codeTaskEvents[0].seq : 0;
    const previousLastSeq = this.codeTaskEvents.length > 0 ? this.codeTaskEvents[this.codeTaskEvents.length - 1].seq : 0;
    const previousStatus = this.selectedCodeTaskStatus;
    const previousRunning = this.selectedCodeTaskRunning;
    const wasAtBottom = sameTask ? this.shouldAutoFollowCodeTaskBottom() : true;
    this.beginCodeTaskHostUpdateWindow();
    this.selectedCodeTaskId = taskId;
    this.selectedCodeTaskTitle = stringValue(summary.title, 'OpenCode 任务');
    this.selectedCodeTaskStatus = stringValue(view.status, stringValue(summary.status, 'idle'));
    this.selectedCodeTaskRunning = view.running === true;
    this.selectedCodeTaskSummary = stringValue(view.summary, stringValue(summary.summary));
    this.selectedCodeTaskQuestions = this.codeTaskQuestionsForDisplay(taskId, this.codeTaskQuestionsFromMobileView(view));
    if (
      this.selectedCodeTaskQuestions.length > 0 ||
        this.isCodeTaskTerminalStatus(this.selectedCodeTaskStatus) ||
        !this.selectedCodeTaskRunning
    ) {
      this.clearPendingCodeTaskQuestionReply(taskId);
    }
    const nextEvents = this.codeTaskEventsFromMobileView(view);
    const nextFirstSeq = nextEvents.length > 0 ? nextEvents[0].seq : 0;
    const nextLastSeq = nextEvents.length > 0 ? nextEvents[nextEvents.length - 1].seq : 0;
    const eventsChanged = !sameTask ||
      previousEventCount !== nextEvents.length ||
      previousFirstSeq !== nextFirstSeq ||
      previousLastSeq !== nextLastSeq;
    if (eventsChanged) {
      this.codeTaskEvents = nextEvents;
    }
    this.initCodeTaskQuestionDrafts();
    this.syncCodeTaskExpandedTurns();
    this.codeTaskConnectionMessage = this.selectedCodeTaskQuestions.length > 0 ? '主机端等待选择' : '已同步主机任务过程';
    const materialChanged = eventsChanged ||
      previousStatus !== this.selectedCodeTaskStatus ||
      previousRunning !== this.selectedCodeTaskRunning;
    if (!updateScroll || !materialChanged) {
      return;
    }
    const needsSettleScroll = this.isCodeTaskTerminalStatus(this.selectedCodeTaskStatus) || !this.selectedCodeTaskRunning;
    if (sameTask) {
      this.preserveCodeTaskScrollAfterUpdate(wasAtBottom, needsSettleScroll);
    } else {
      this.scrollCodeTaskToBottom(true, needsSettleScroll);
    }
  }

  private codeTaskMobileViewTaskId(view: CodeTaskMobileViewSnapshot): string {
    return stringValue(view.taskId, stringValue(view.task?.id));
  }

  private isCodeTaskMobileViewDeleted(view: CodeTaskMobileViewSnapshot): boolean {
    return stringValue(view.kind) === 'code_task_deleted' || stringValue(view.status) === 'deleted';
  }

  private removeCodeTaskMobileView(taskId: string): void {
    if (taskId.length === 0) {
      return;
    }
    this.codeTaskViewSnapshots = this.codeTaskViewSnapshots.filter((view: CodeTaskMobileViewSnapshot): boolean => {
      return this.codeTaskMobileViewTaskId(view) !== taskId;
    });
    this.codeTasks = this.codeTasks.filter((task: CodeTaskSummary): boolean => task.id !== taskId);
    if (this.selectedCodeTaskId === taskId) {
      this.clearSelectedCodeTask();
      const nextView = this.codeTaskViewSnapshots.length > 0 ? this.codeTaskViewSnapshots[0] : undefined;
      if (nextView !== undefined) {
        this.applyCodeTaskMobileView(nextView, true);
      }
    }
    this.codeTaskConnectionMessage = this.codeTasks.length > 0 ? '主机端已删除任务，已同步列表' : '主机暂无 OpenCode 任务。';
  }

  private codeTaskSummaryFromMobileView(view: CodeTaskMobileViewSnapshot): CodeTaskSummary {
    const taskId = this.codeTaskMobileViewTaskId(view);
    const task = view.task;
    const events = this.codeTaskEventsFromMobileView(view);
    const lastEvent = events.length > 0 ? events[events.length - 1] : undefined;
    const viewEventCount = view.view?.eventCount;
    return {
      id: taskId,
      title: stringValue(task?.title, 'OpenCode 任务'),
      prompt: stringValue(task?.prompt),
      workspacePath: stringValue(task?.workspacePath),
      status: stringValue(view.status, stringValue(task?.status, 'idle')),
      sessionId: stringValue(task?.sessionId),
      running: view.running,
      backgroundRunning: view.running,
      pendingQuestions: this.codeTaskQuestionsFromMobileView(view),
      createdAt: stringValue(task?.createdAt, stringValue(view.renderedAt)),
      updatedAt: stringValue(task?.updatedAt, stringValue(view.renderedAt)),
      eventCount: viewEventCount === undefined ? events.length : viewEventCount,
      lastEvent,
      summary: stringValue(view.summary),
    };
  }

  private codeTaskQuestionsFromMobileView(view: CodeTaskMobileViewSnapshot): CodeTaskQuestionPayload[] {
    const pendingQuestion = view.pendingQuestion;
    if (pendingQuestion === undefined || pendingQuestion === null) {
      return [];
    }
    const question = this.codeTaskQuestionFromView(pendingQuestion);
    return question.requestId === undefined || stringValue(question.requestId).length === 0 ? [] : [question];
  }

  private codeTaskQuestionFromView(question: CodeTaskViewQuestion): CodeTaskQuestionPayload {
    return {
      requestId: stringValue(question.requestId),
      sessionId: stringValue(question.sessionId),
      questions: Array.isArray(question.questions) ? question.questions : [],
      message: '',
      v2: question.v2 !== false,
    };
  }

  private codeTaskEventsFromMobileView(view: CodeTaskMobileViewSnapshot): CodeTaskEventRecord[] {
    const taskId = this.codeTaskMobileViewTaskId(view);
    const turns = Array.isArray(view.turns) ? view.turns : [];
    const events: CodeTaskEventRecord[] = [];
    const seenMessages: string[] = [];
    let seq = 1;
    turns.forEach((turn: CodeTaskViewTurn | null | undefined): void => {
      if (turn === undefined || turn === null) {
        return;
      }
      const request = turn.request;
      if (request !== undefined && request !== null) {
        events.push(this.codeTaskEventFromViewMessage(taskId, request, seq, 'request'));
        seenMessages.push(stringValue(request.id, `${seq}`));
        seq += 1;
      }
      const rawPhases = turn.processed?.phases;
      const phases = Array.isArray(rawPhases) ? rawPhases : [];
      phases.forEach((phase: CodeTaskViewPhase | null | undefined): void => {
        if (phase === undefined || phase === null) {
          return;
        }
        const rawMessages = phase.messages;
        const messages = Array.isArray(rawMessages) ? rawMessages : [];
        messages.forEach((message: CodeTaskViewMessage | null | undefined): void => {
          if (message === undefined || message === null) {
            return;
          }
          const key = stringValue(message.id, `${seq}`);
          if (seenMessages.indexOf(key) >= 0) {
            return;
          }
          events.push(this.codeTaskEventFromViewMessage(taskId, message, seq, stringValue(phase.id)));
          seenMessages.push(key);
          seq += 1;
        });
      });
      const rawResponses = turn.responses;
      const responses = Array.isArray(rawResponses) ? rawResponses : [];
      responses.forEach((message: CodeTaskViewMessage | null | undefined): void => {
        if (message === undefined || message === null) {
          return;
        }
        const key = stringValue(message.id, `${seq}`);
        if (seenMessages.indexOf(key) >= 0) {
          return;
        }
        events.push(this.codeTaskEventFromViewMessage(taskId, message, seq, 'result'));
        seenMessages.push(key);
        seq += 1;
      });
    });
    return events;
  }

  private codeTaskEventFromViewMessage(
    taskId: string,
    message: CodeTaskViewMessage,
    seq: number,
    phaseId: string,
  ): CodeTaskEventRecord {
    const eventSeq = this.codeTaskViewMessageSeq(message, seq);
    const eventName = this.codeTaskViewMessageEventName(message, phaseId);
    const createdAt = stringValue(message.createdAt, new Date().toISOString());
    const text = stringValue(message.text, stringValue(message.detail, stringValue(message.title)));
    const payload: CodeTaskEventPayload = {
      taskId,
      eventId: eventSeq,
      emittedAt: createdAt,
      title: stringValue(message.title),
      text,
      message: text,
      detail: stringValue(message.detail),
      status: eventName === 'status' || eventName === 'done' ? text : undefined,
      source: eventName === 'input' ? 'mobile' : 'host-view',
    };
    const question = message.question;
    if (eventName === 'question' && question !== undefined && question !== null) {
      payload.requestId = stringValue(question.requestId);
      payload.sessionId = stringValue(question.sessionId);
      payload.questions = Array.isArray(question.questions) ? question.questions : [];
      payload.v2 = question.v2 !== false;
      payload.answers = question.answers;
      payload.rejected = question.rejected;
    }
    if (eventName === 'tool') {
      payload.name = stringValue(message.title, 'tool');
    }
    if (eventName === 'command') {
      payload.command = stringValue(message.title, text);
      payload.output = stringValue(message.detail);
    }
    if (eventName === 'file') {
      payload.path = text;
    }
    if (eventName === 'diff') {
      payload.diff = stringValue(message.detail, text);
    }
    return {
      seq: eventSeq,
      event: eventName,
      payload,
      createdAt,
    };
  }

  private codeTaskViewMessageSeq(message: CodeTaskViewMessage, fallback: number): number {
    const rawId = stringValue(message.id);
    if (rawId.length > 0) {
      const parts = rawId.split('-');
      for (let index = parts.length - 2; index >= 0; index -= 1) {
        const value = Number(parts[index]);
        if (Number.isFinite(value) && value > 0) {
          return value;
        }
      }
    }
    return fallback;
  }

  private codeTaskViewMessageEventName(message: CodeTaskViewMessage, phaseId: string): string {
    const kind = stringValue(message.kind);
    const title = stringValue(message.title).toLowerCase();
    if (kind === 'user') {
      return 'input';
    }
    if (kind === 'assistant') {
      return 'output';
    }
    if (kind === 'done') {
      return 'done';
    }
    if (kind === 'error') {
      return 'error';
    }
    if (kind === 'question') {
      return 'question';
    }
    if (kind === 'command') {
      return 'command';
    }
    if (kind === 'tool') {
      return 'tool';
    }
    if (kind === 'permission') {
      return 'permission';
    }
    if (kind === 'file' && (title === 'diff' || phaseId === 'files' && title.indexOf('diff') >= 0)) {
      return 'diff';
    }
    if (kind === 'file') {
      return 'file';
    }
    if (kind === 'status') {
      return 'status';
    }
    return 'log';
  }

  private clearSelectedCodeTask(): void {
    this.clearCodeTaskReopenRefresh();
    this.selectedCodeTaskId = '';
    this.selectedCodeTaskTitle = '';
    this.selectedCodeTaskStatus = '';
    this.selectedCodeTaskRunning = false;
    this.selectedCodeTaskSummary = '';
    this.selectedCodeTaskQuestions = [];
    this.codeTaskQuestionDrafts = [];
    this.codeTaskEvents = [];
    this.codeTaskExpandedTurnIds = [];
    this.codeTaskMessageDraft = '';
    this.clearPendingCodeTaskQuestionReply();
  }

  private codeTaskSnapshotEvents(task: CodeTaskDetail): CodeTaskEventRecord[] {
    const messages = task.snapshot?.messages;
    if (!Array.isArray(messages) || messages.length === 0) {
      return [];
    }
    return messages.map((message: CodeTaskSnapshotMessage, index: number): CodeTaskEventRecord => {
      const eventName = this.codeTaskSnapshotEventName(stringValue(message.kind));
      const payload = this.codeTaskSnapshotEventPayload(task, message, eventName, index + 1);
      return {
        seq: index + 1,
        event: eventName,
        payload,
        createdAt: stringValue(message.createdAt, stringValue(task.updatedAt, stringValue(task.createdAt, ''))),
      };
    });
  }

  private codeTaskSnapshotEventName(kind: string): string {
    if (kind === 'user') {
      return 'input';
    }
    if (kind === 'assistant') {
      return 'output';
    }
    if (kind === 'done') {
      return 'done';
    }
    if (kind === 'error') {
      return 'error';
    }
    if (kind === 'question') {
      return 'question';
    }
    if (kind === 'tool' || kind === 'command' || kind === 'file' || kind === 'permission' || kind === 'status') {
      return kind;
    }
    return 'log';
  }

  private codeTaskSnapshotEventPayload(
    task: CodeTaskDetail,
    message: CodeTaskSnapshotMessage,
    eventName: string,
    eventId: number,
  ): CodeTaskEventPayload {
    const text = stringValue(message.text, stringValue(message.detail, stringValue(message.title)));
    const payload: CodeTaskEventPayload = {
      taskId: task.id,
      eventId,
      emittedAt: stringValue(message.createdAt, stringValue(task.updatedAt, stringValue(task.createdAt, ''))),
      title: stringValue(message.title),
      message: text,
      text,
      status: eventName === 'status' || eventName === 'done' ? stringValue(task.status, eventName) : undefined,
      workspacePath: stringValue(task.workspacePath),
      sessionId: stringValue(task.sessionId),
    };
    if (eventName === 'input') {
      payload.source = 'host-history';
    }
    if (eventName === 'tool') {
      payload.name = stringValue(message.title, 'tool');
      payload.detail = stringValue(message.detail, text);
    }
    if (eventName === 'command') {
      payload.command = stringValue(message.title);
      payload.output = stringValue(message.detail, text);
    }
    if (eventName === 'file') {
      payload.path = text;
    }
    if (eventName === 'question') {
      payload.requestId = stringValue(message.question?.requestId);
      payload.sessionId = stringValue(message.question?.sessionId, stringValue(task.sessionId));
      payload.questions = Array.isArray(message.question?.questions) ? message.question?.questions : [];
      payload.v2 = message.question?.v2 !== false;
      payload.answers = message.question?.answers;
      payload.rejected = message.question?.rejected;
    }
    return payload;
  }

  private scheduleCodeTaskReopenRefresh(
    taskId: string,
    delayMs: number = CODE_TASK_REOPEN_REFRESH_DELAY_MS,
    forceEvents: boolean = true,
  ): void {
    if (taskId.length === 0 || taskId !== this.selectedCodeTaskId) {
      return;
    }
    this.clearCodeTaskReopenRefresh();
    this.codeTaskReopenRefreshTimer = setTimeout((): void => {
      this.codeTaskReopenRefreshTimer = -1;
      if (taskId !== this.selectedCodeTaskId) {
        return;
      }
      this.reloadSelectedCodeTaskLikeReopen(forceEvents).catch((error: Error | Object | string): void => {
        console.error(`[Amaduse] reopen-style code task refresh failed: ${errorToString(error)}`);
        if (
          taskId === this.selectedCodeTaskId &&
          (this.hasLocalCodeTaskProcessing() ||
            this.selectedCodeTaskRunning ||
            this.hasPendingCodeTaskQuestionReply(taskId))
        ) {
          this.scheduleCodeTaskReopenRefresh(taskId, CODE_TASK_REOPEN_REFRESH_RETRY_MS, forceEvents);
        }
      });
    }, delayMs);
  }

  private clearCodeTaskReopenRefresh(): void {
    if (this.codeTaskReopenRefreshTimer >= 0) {
      clearTimeout(this.codeTaskReopenRefreshTimer);
      this.codeTaskReopenRefreshTimer = -1;
    }
  }

  private async reloadSelectedCodeTaskLikeReopen(forceEvents: boolean = true): Promise<void> {
    if (this.selectedCodeTaskId.length === 0 || !CodeTaskRemoteService.isConfigured(this.hostAgentSettings)) {
      return;
    }
    if (this.codeTaskSending || this.codeTaskReplying) {
      this.scheduleCodeTaskReopenRefresh(this.selectedCodeTaskId, CODE_TASK_REOPEN_REFRESH_DELAY_MS, forceEvents);
      return;
    }
    const taskId = this.selectedCodeTaskId;
    const wasAtBottom = this.shouldAutoFollowCodeTaskBottom();
    this.codeTaskConnectionMessage = '主机端处理中，完成后同步结果...';
    const tasks = await CodeTaskRemoteService.listTasks(this.hostAgentSettings);
    if (taskId !== this.selectedCodeTaskId) {
      return;
    }
    this.codeTasks = tasks;
    const current = tasks.find((task: CodeTaskSummary): boolean => task.id === taskId);
    if (current === undefined) {
      this.clearSelectedCodeTask();
      return;
    }
    this.selectedCodeTaskTitle = stringValue(current.title, this.selectedCodeTaskTitle);
    const summaryStatus = this.codeTaskSummaryStatus(current, this.selectedCodeTaskStatus);
    const summaryRunning = this.isCodeTaskTaskRunning(current.running, summaryStatus, current.backgroundRunning);
    if (!this.hasLocalCodeTaskProcessing() || summaryRunning || !this.isCodeTaskTerminalStatus(summaryStatus)) {
      this.selectedCodeTaskStatus = summaryStatus;
      this.selectedCodeTaskRunning = summaryRunning;
      this.selectedCodeTaskSummary = stringValue(current.summary, this.selectedCodeTaskSummary);
    }
    this.selectedCodeTaskQuestions = this.codeTaskQuestionsForDisplay(taskId, current.pendingQuestions);
    const detail = await CodeTaskRemoteService.getTaskDetail(this.hostAgentSettings, taskId);
    if (taskId !== this.selectedCodeTaskId) {
      return;
    }
    const detailStatus = this.codeTaskDetailStatus(detail);
    const detailRunning = this.isCodeTaskTaskRunning(detail.running, detailStatus, detail.backgroundRunning);
    const pendingQuestions = this.normalizedCodeTaskQuestions(detail.pendingQuestions);
    const displayPendingQuestions = this.codeTaskQuestionsForDisplay(taskId, detail.pendingQuestions);
    const hasPendingReply = this.hasPendingCodeTaskQuestionReply(taskId);
    const hasStaleAnsweredQuestionOnly = hasPendingReply && pendingQuestions.length > 0 && displayPendingQuestions.length === 0;
    if (detailRunning && pendingQuestions.length === 0) {
      this.scheduleCodeTaskReopenRefresh(taskId, CODE_TASK_REOPEN_REFRESH_RETRY_MS, false);
      return;
    }
    if (
      hasPendingReply &&
      displayPendingQuestions.length === 0 &&
      !this.isCodeTaskTerminalStatus(detailStatus)
    ) {
      if (hasStaleAnsweredQuestionOnly) {
        this.selectedCodeTaskQuestions = [];
        this.initCodeTaskQuestionDrafts();
      }
      this.selectedCodeTaskStatus = 'running';
      this.selectedCodeTaskRunning = true;
      this.scheduleCodeTaskReopenRefresh(taskId, CODE_TASK_REOPEN_REFRESH_RETRY_MS, true);
      return;
    }
    if (
      this.hasLocalCodeTaskProcessing() &&
      !detailRunning &&
      !this.codeTaskDetailHasCurrentLocalInput(detail) &&
      !this.codeTaskDetailHasNewHostEventsAfterLocalInput(detail) &&
      !this.codeTaskDetailUpdatedAfterLocalInput(detail)
    ) {
      this.scheduleCodeTaskReopenRefresh(taskId, CODE_TASK_REOPEN_REFRESH_RETRY_MS, false);
      return;
    }
    this.applyCodeTaskDetail(this.codeTaskDetailForDisplay(detail), true);
    if (displayPendingQuestions.length > 0 || this.isCodeTaskTerminalStatus(detailStatus) || !this.isCodeTaskTaskRunning(detail.running, detailStatus, detail.backgroundRunning)) {
      this.clearPendingCodeTaskQuestionReply(taskId);
    }
    this.codeTaskConnectionMessage = displayPendingQuestions.length > 0 ? '主机端等待选择' : '已同步任务结果';
    this.preserveCodeTaskScrollAfterUpdate(wasAtBottom);
  }

  private shouldPreserveLocalCodeTaskProcessing(
    task: CodeTaskDetail,
    detailStatus: string,
    nextRunning: boolean,
    forceEvents: boolean,
  ): boolean {
    if (forceEvents || !this.hasLocalCodeTaskProcessing()) {
      return false;
    }
    if (nextRunning || !this.isCodeTaskTerminalStatus(detailStatus)) {
      return false;
    }
    return !this.codeTaskDetailHasCurrentLocalInput(task) &&
      !this.codeTaskDetailHasNewHostEventsAfterLocalInput(task) &&
      !this.codeTaskDetailUpdatedAfterLocalInput(task);
  }

  private codeTaskDetailStatus(task: CodeTaskDetail): string {
    const taskStatus = stringValue(task.status);
    const snapshotStatus = stringValue(task.snapshot?.status);
    return !this.isCodeTaskTerminalStatus(taskStatus) && this.isCodeTaskTerminalStatus(snapshotStatus)
      ? snapshotStatus
      : stringValue(taskStatus, stringValue(snapshotStatus, 'idle'));
  }

  private hasLocalCodeTaskProcessing(): boolean {
    return this.localCodeTaskPrompt().length > 0;
  }

  private localCodeTaskPrompt(): string {
    for (let index = this.codeTaskEvents.length - 1; index >= 0; index -= 1) {
      const event = this.codeTaskEvents[index];
      if (event.event === 'input' && stringValue(event.payload.source) === 'mobile-local') {
        return stringValue(event.payload.text, stringValue(event.payload.message));
      }
    }
    return '';
  }

  private codeTaskDetailHasCurrentLocalInput(task: CodeTaskDetail): boolean {
    const prompt = this.localCodeTaskPrompt();
    if (prompt.length === 0) {
      return false;
    }
    const events = Array.isArray(task.events) ? task.events : [];
    const hasEvent = events.some((event: CodeTaskEventRecord): boolean => {
      if (event.event !== 'input') {
        return false;
      }
      const source = stringValue(event.payload.source);
      const text = stringValue(event.payload.text, stringValue(event.payload.message));
      return source === 'mobile' && this.isSameCodeTaskPrompt(text, prompt);
    });
    if (hasEvent) {
      return true;
    }
    const messages = task.snapshot?.messages;
    if (!Array.isArray(messages)) {
      return false;
    }
    return messages.some((message: CodeTaskSnapshotMessage): boolean => {
      if (stringValue(message.kind) !== 'user') {
        return false;
      }
      const text = stringValue(message.text, stringValue(message.detail, stringValue(message.title)));
      return this.isSameCodeTaskPrompt(text, prompt);
    });
  }

  private codeTaskDetailHasNewHostEventsAfterLocalInput(task: CodeTaskDetail): boolean {
    const localIndex = this.lastLocalCodeTaskInputIndex();
    if (localIndex < 0) {
      return false;
    }
    const baselineCount = this.codeTaskEvents
      .slice(0, localIndex)
      .filter((event: CodeTaskEventRecord): boolean => stringValue(event.payload.source) !== 'mobile-local')
      .length;
    const events = Array.isArray(task.events) ? task.events : [];
    if (events.length > baselineCount + 1) {
      return true;
    }
    const snapshotEvents = this.codeTaskSnapshotEvents(task);
    if (snapshotEvents.length > baselineCount + 1) {
      return true;
    }
    return false;
  }

  private codeTaskDetailUpdatedAfterLocalInput(task: CodeTaskDetail): boolean {
    const localIndex = this.lastLocalCodeTaskInputIndex();
    if (localIndex < 0) {
      return false;
    }
    const localTime = new Date(this.codeTaskEvents[localIndex].createdAt).getTime();
    const detailTime = new Date(stringValue(task.updatedAt, stringValue(task.createdAt))).getTime();
    if (!Number.isFinite(localTime) || !Number.isFinite(detailTime)) {
      return false;
    }
    return detailTime >= localTime;
  }

  private lastLocalCodeTaskInputIndex(): number {
    for (let index = this.codeTaskEvents.length - 1; index >= 0; index -= 1) {
      const event = this.codeTaskEvents[index];
      if (event.event === 'input' && stringValue(event.payload.source) === 'mobile-local') {
        return index;
      }
    }
    return -1;
  }

  private isSameCodeTaskPrompt(left: string, right: string): boolean {
    const leftText = left.replace(/\s+/g, ' ').trim();
    const rightText = right.replace(/\s+/g, ' ').trim();
    if (leftText.length === 0 || rightText.length === 0) {
      return false;
    }
    return leftText === rightText || leftText.indexOf(rightText) >= 0 || rightText.indexOf(leftText) >= 0;
  }

  private applyCodeTaskEvent(event: CodeTaskEventRecord): void {
    this.appendCodeTaskEvent(event);
    const payload = event.payload;
    if (event.event === 'input') {
      this.selectedCodeTaskRunning = true;
      this.selectedCodeTaskStatus = 'running';
    } else if (event.event === 'session') {
      if (!this.isCodeTaskTerminalStatus(this.selectedCodeTaskStatus)) {
        this.selectedCodeTaskRunning = true;
        this.selectedCodeTaskStatus = 'session';
      }
      this.selectedCodeTaskTitle = stringValue(payload.title, this.selectedCodeTaskTitle);
    } else if (event.event === 'status') {
      const nextStatus = stringValue(payload.status, stringValue(payload.message, this.selectedCodeTaskStatus));
      if (!this.isCodeTaskTerminalStatus(this.selectedCodeTaskStatus) || this.isCodeTaskTerminalStatus(nextStatus)) {
        this.selectedCodeTaskStatus = nextStatus;
        this.selectedCodeTaskRunning = !this.isCodeTaskTerminalStatus(this.selectedCodeTaskStatus);
      }
    } else if (event.event === 'question') {
      this.selectedCodeTaskStatus = 'waiting_input';
      this.selectedCodeTaskRunning = true;
      this.addCodeTaskQuestion(payload);
    } else if (event.event === 'question_result') {
      this.selectedCodeTaskStatus = 'running';
      this.selectedCodeTaskRunning = true;
      this.removeCodeTaskQuestion(stringValue(payload.requestId));
    } else if (event.event === 'done') {
      this.selectedCodeTaskStatus = stringValue(payload.status, 'done');
      this.selectedCodeTaskRunning = false;
      this.selectedCodeTaskQuestions = [];
      this.codeTaskQuestionDrafts = [];
    } else if (event.event === 'error') {
      this.selectedCodeTaskStatus = 'error';
      this.selectedCodeTaskRunning = false;
    }
    this.upsertCodeTaskSummaryFromSelected(event);
  }

  private appendCodeTaskEvent(event: CodeTaskEventRecord): void {
    const next = this.codeTaskEvents.slice();
    if (event.event === 'input' && stringValue(event.payload.source) === 'mobile') {
      const incomingText = stringValue(event.payload.text, stringValue(event.payload.message));
      const localIndex = next.findIndex((item: CodeTaskEventRecord): boolean => {
        return item.event === 'input' &&
          stringValue(item.payload.source) === 'mobile-local' &&
          stringValue(item.payload.taskId, this.selectedCodeTaskId) === stringValue(event.payload.taskId, this.selectedCodeTaskId) &&
          stringValue(item.payload.text, stringValue(item.payload.message)) === incomingText;
      });
      if (localIndex >= 0) {
        next[localIndex] = event;
        this.codeTaskEvents = next;
        return;
      }
    }
    const existingIndex = next.findIndex((item: CodeTaskEventRecord): boolean => {
      return item.seq === event.seq && item.event === event.event;
    });
    if (existingIndex >= 0) {
      next[existingIndex] = event;
    } else {
      next.push(event);
    }
    if (next.length > 500) {
      this.codeTaskEvents = next.slice(next.length - 500);
    } else {
      this.codeTaskEvents = next;
    }
  }

  private beginLocalCodeTaskProcessing(taskId: string, prompt: string): void {
    const baseSeq = Date.now() * 1000 + this.codeTaskEvents.length;
    const createdAt = new Date().toISOString();
    const workspacePath = this.currentCodeTaskWorkspacePath();
    this.applyCodeTaskEvent({
      seq: baseSeq,
      event: 'input',
      payload: {
        taskId,
        text: prompt,
        message: prompt,
        source: 'mobile-local',
        workspacePath,
      },
      createdAt,
    });
    this.applyCodeTaskEvent({
      seq: baseSeq + 1,
      event: 'status',
      payload: {
        taskId,
        status: 'running',
        message: '主机端正在处理手机端发送的任务。',
        source: 'mobile-local',
        workspacePath,
      },
      createdAt,
    });
    this.selectedCodeTaskRunning = true;
    this.selectedCodeTaskStatus = 'running';
    this.codeTaskConnectionMessage = '已进入处理中，正在发送到主机端...';
    this.scrollCodeTaskToBottom(true);
  }

  private cancelLocalCodeTaskProcessing(taskId: string, prompt: string): void {
    this.codeTaskEvents = this.codeTaskEvents.filter((event: CodeTaskEventRecord): boolean => {
      if (stringValue(event.payload.source) !== 'mobile-local') {
        return true;
      }
      if (stringValue(event.payload.taskId, this.selectedCodeTaskId) !== taskId) {
        return true;
      }
      if (event.event === 'input') {
        return stringValue(event.payload.text, stringValue(event.payload.message)) !== prompt;
      }
      return event.event !== 'status';
    });
    const current = this.codeTasks.find((task: CodeTaskSummary): boolean => task.id === taskId);
    if (current !== undefined) {
      this.selectedCodeTaskStatus = this.codeTaskSummaryStatus(current, this.selectedCodeTaskStatus);
      this.selectedCodeTaskRunning = this.isCodeTaskTaskRunning(current.running, this.selectedCodeTaskStatus, current.backgroundRunning);
      this.selectedCodeTaskSummary = stringValue(current.summary, this.selectedCodeTaskSummary);
    }
    this.syncCodeTaskExpandedTurns();
  }

  private currentCodeTaskWorkspacePath(): string {
    const current = this.codeTasks.find((task: CodeTaskSummary): boolean => task.id === this.selectedCodeTaskId);
    if (current !== undefined) {
      return stringValue(current.workspacePath);
    }
    return '';
  }

  private codeTaskDisplayEvents(): CodeTaskEventRecord[] {
    const output: CodeTaskEventRecord[] = [];
    this.codeTaskEvents.forEach((event: CodeTaskEventRecord): void => {
      if (event.event !== 'output') {
        output.push(event);
        return;
      }
      const text = stringValue(event.payload.text, stringValue(event.payload.message));
      const last = output.length > 0 ? output[output.length - 1] : undefined;
      if (last !== undefined && last.event === 'output') {
        const previousText = stringValue(last.payload.text, stringValue(last.payload.message));
        const mergedText = `${previousText}${text}`;
        const mergedPayload: CodeTaskEventPayload = {
          taskId: stringValue(last.payload.taskId, stringValue(event.payload.taskId)),
          text: mergedText,
          message: mergedText,
          sessionId: stringValue(event.payload.sessionId, stringValue(last.payload.sessionId)),
          serverUrl: stringValue(event.payload.serverUrl, stringValue(last.payload.serverUrl)),
          workspacePath: stringValue(event.payload.workspacePath, stringValue(last.payload.workspacePath)),
          eventId: event.payload.eventId,
          emittedAt: stringValue(event.payload.emittedAt, last.payload.emittedAt),
        };
        output[output.length - 1] = {
          seq: last.seq,
          event: last.event,
          payload: mergedPayload,
          createdAt: event.createdAt,
        };
        return;
      }
      output.push(event);
    });
    return output;
  }

  private codeTaskConversationTurns(): CodeTaskConversationTurn[] {
    const events = this.codeTaskDisplayEvents();
    const turns: CodeTaskConversationTurn[] = [];
    let currentIndex = -1;

    for (let index = 0; index < events.length; index += 1) {
      const event = events[index];
      if (event.event === 'input' || currentIndex < 0) {
        turns.push({
          id: `${event.seq}-${event.event}`,
          request: event,
          hasRequest: event.event === 'input',
          events: [],
          running: false,
          completed: false,
          errored: false,
        });
        currentIndex = turns.length - 1;
        if (event.event !== 'input') {
          turns[currentIndex].events.push(event);
        }
      } else {
        turns[currentIndex].events.push(event);
      }
      if (event.event === 'done') {
        turns[currentIndex].completed = true;
      }
      if (event.event === 'error') {
        turns[currentIndex].errored = true;
      }
    }

    const terminal = this.isCodeTaskTerminalStatus(this.selectedCodeTaskStatus);
    for (let index = 0; index < turns.length; index += 1) {
      const isLatest = index === turns.length - 1;
      if (this.codeTaskTurnHasLocalProcessing(turns[index]) && !this.codeTaskTurnHasTerminalEvent(turns[index])) {
        turns[index].running = true;
        turns[index].completed = false;
        continue;
      }
      turns[index].running = this.selectedCodeTaskRunning && isLatest;
      if (isLatest && terminal && !turns[index].running && !turns[index].errored) {
        turns[index].completed = true;
      }
      if (isLatest && this.isCodeTaskErrorStatus(this.selectedCodeTaskStatus)) {
        turns[index].errored = true;
      }
    }
    return turns;
  }

  private isCodeTaskTerminalStatus(status: string): boolean {
    const normalized = status.toLowerCase();
    return normalized === 'idle' ||
      normalized === 'done' ||
      normalized === 'completed' ||
      normalized === 'complete' ||
      normalized === 'finished' ||
      normalized === 'success' ||
      normalized === 'succeeded' ||
      normalized === 'stopped' ||
      normalized === 'cancelled' ||
      normalized === 'canceled' ||
      this.isCodeTaskErrorStatus(status);
  }

  private isCodeTaskErrorStatus(status: string): boolean {
    const normalized = status.toLowerCase();
    return normalized === 'error' || normalized === 'failed' || normalized === 'failure';
  }

  private isCodeTaskTaskRunning(running: boolean | undefined, status: string, backgroundRunning: boolean | undefined = false): boolean {
    if (running === true || backgroundRunning === true) {
      const normalized = status.toLowerCase();
      const isRealTerminal = (normalized === 'done' || normalized === 'completed' || normalized === 'complete' ||
        normalized === 'finished' || normalized === 'success' || normalized === 'succeeded' ||
        normalized === 'stopped' || normalized === 'cancelled' || normalized === 'canceled' ||
        this.isCodeTaskErrorStatus(status));
      if (isRealTerminal) {
        return false;
      }
      return true;
    }
    if (this.isCodeTaskTerminalStatus(status)) {
      return false;
    }
    if (running === false) {
      return false;
    }
    const normalized = status.toLowerCase();
    return normalized === 'running' ||
      normalized === 'session' ||
      normalized === 'starting' ||
      normalized === 'connecting' ||
      normalized === 'busy' ||
      normalized === 'processing';
  }

  private codeTaskTurnProcessPhases(turn: CodeTaskConversationTurn): CodeTaskProcessPhase[] {
    const phases: CodeTaskProcessPhase[] = [];
    for (let index = 0; index < turn.events.length; index += 1) {
      const event = turn.events[index];
      const phaseId = this.codeTaskProcessPhaseId(event.event);
      let phaseIndex = phases.findIndex((phase: CodeTaskProcessPhase): boolean => phase.id === phaseId);
      if (phaseIndex < 0) {
        phases.push({
          id: phaseId,
          title: this.codeTaskProcessPhaseTitle(phaseId),
          status: 'completed',
          events: [],
        });
        phaseIndex = phases.length - 1;
      }
      phases[phaseIndex].events.push(event);
    }
    for (let index = 0; index < phases.length; index += 1) {
      const phase = phases[index];
      const hasError = phase.events.some((event: CodeTaskEventRecord): boolean => event.event === 'error');
      if (hasError) {
        phase.status = 'error';
      } else if (turn.running && index === phases.length - 1) {
        phase.status = 'running';
      } else {
        phase.status = 'completed';
      }
    }
    return phases;
  }

  private codeTaskProcessPhaseId(eventName: string): string {
    if (eventName === 'session' || eventName === 'status' || eventName === 'log') {
      return 'setup';
    }
    if (eventName === 'output' || eventName === 'tool') {
      return 'thinking';
    }
    if (eventName === 'command') {
      return 'commands';
    }
    if (eventName === 'file' || eventName === 'diff') {
      return 'files';
    }
    if (eventName === 'permission') {
      return 'permissions';
    }
    if (eventName === 'question' || eventName === 'question_result') {
      return 'questions';
    }
    if (eventName === 'done' || eventName === 'error') {
      return 'result';
    }
    return 'events';
  }

  private codeTaskProcessPhaseTitle(phaseId: string): string {
    if (phaseId === 'setup') {
      return '启动与会话';
    }
    if (phaseId === 'thinking') {
      return '思考与输出';
    }
    if (phaseId === 'commands') {
      return '命令执行';
    }
    if (phaseId === 'files') {
      return '文件与 Diff';
    }
    if (phaseId === 'permissions') {
      return '权限处理';
    }
    if (phaseId === 'questions') {
      return '交互确认';
    }
    if (phaseId === 'result') {
      return '任务结果';
    }
    return '事件';
  }

  private codeTaskVisiblePhaseEvents(phase: CodeTaskProcessPhase): CodeTaskEventRecord[] {
    const limit = 6;
    if (phase.events.length <= limit) {
      return phase.events;
    }
    return phase.events.slice(phase.events.length - limit);
  }

  private codeTaskHiddenPhaseEventCount(phase: CodeTaskProcessPhase): number {
    const hidden = phase.events.length - 6;
    return hidden > 0 ? hidden : 0;
  }

  private codeTaskPhaseStatusText(status: string): string {
    if (status === 'running') {
      return '进行中';
    }
    if (status === 'error') {
      return '异常';
    }
    return '完成';
  }

  private codeTaskPhaseIcon(phase: CodeTaskProcessPhase): string {
    if (phase.status === 'error') {
      return '!';
    }
    if (phase.status === 'running') {
      return '•';
    }
    return '✓';
  }

  private codeTaskPhaseColor(phase: CodeTaskProcessPhase): string {
    if (phase.status === 'error') {
      return DANGER;
    }
    if (phase.status === 'running') {
      return BLUE;
    }
    return ACTIVE_GREEN;
  }

  private isCodeTaskTurnExpanded(turn: CodeTaskConversationTurn): boolean {
    if (this.codeTaskExpandedTurnIds.indexOf(turn.id) >= 0) {
      return true;
    }
    return turn.running || turn.errored || this.codeTaskTurnHasPendingQuestion(turn);
  }

  private toggleCodeTaskTurnExpanded(turn: CodeTaskConversationTurn): void {
    this.setCodeTaskTurnExpanded(turn.id, !this.isCodeTaskTurnExpanded(turn));
  }

  private setCodeTaskTurnExpanded(turnId: string, expanded: boolean): void {
    if (turnId.length === 0) {
      return;
    }
    const existing = this.codeTaskExpandedTurnIds.indexOf(turnId);
    if (expanded && existing < 0) {
      this.codeTaskExpandedTurnIds = this.codeTaskExpandedTurnIds.concat([turnId]);
      return;
    }
    if (!expanded && existing >= 0) {
      this.codeTaskExpandedTurnIds = this.codeTaskExpandedTurnIds.filter((item: string): boolean => item !== turnId);
    }
  }

  private syncCodeTaskExpandedTurns(): void {
    const availableIds: string[] = [];
    this.codeTaskConversationTurns().forEach((turn: CodeTaskConversationTurn): void => {
      availableIds.push(turn.id);
    });
    this.codeTaskExpandedTurnIds = this.codeTaskExpandedTurnIds.filter((turnId: string): boolean => {
      return availableIds.indexOf(turnId) >= 0;
    });
  }

  private codeTaskTurnHasPendingQuestion(turn: CodeTaskConversationTurn): boolean {
    return turn.events.some((event: CodeTaskEventRecord): boolean => {
      if (event.event !== 'question') {
        return false;
      }
      const requestId = stringValue(event.payload.requestId);
      if (requestId.length === 0) {
        return false;
      }
      return this.selectedCodeTaskQuestions.some((question: CodeTaskQuestionPayload): boolean => {
        return stringValue(question.requestId) === requestId;
      });
    });
  }

  private codeTaskTurnSummaryText(turn: CodeTaskConversationTurn): string {
    if (!turn.completed && !turn.errored) {
      return '';
    }
    if (this.codeTaskTurnHasLocalProcessing(turn) && !this.codeTaskTurnHasTerminalEvent(turn)) {
      return '';
    }
    if (turn.errored) {
      const errorText = this.codeTaskTurnLastEventDetail(turn, 'error');
      return `任务执行失败：${errorText.length > 0 ? errorText : 'OpenCode 返回错误。'}`;
    }
    const taskLabel = this.codeTaskCompactTitle(this.codeTaskTurnRequestText(turn));
    const finalOutput = this.codeTaskCleanFinalAnswer(stringValue(this.codeTaskTurnOutputText(turn), this.selectedCodeTaskSummary));
    const conclusion = finalOutput.length > 0 ? `结论：${this.limitCodeTaskText(finalOutput, 6000)}` : '没有收到可用于总结的最终文本。';
    return `OpenCode 已完成「${taskLabel}」。\n\n${conclusion}`;
  }

  private codeTaskTurnHasLocalProcessing(turn: CodeTaskConversationTurn): boolean {
    if (turn.hasRequest && stringValue(turn.request.payload.source) === 'mobile-local') {
      return true;
    }
    return turn.events.some((event: CodeTaskEventRecord): boolean => stringValue(event.payload.source) === 'mobile-local');
  }

  private codeTaskTurnHasTerminalEvent(turn: CodeTaskConversationTurn): boolean {
    return turn.events.some((event: CodeTaskEventRecord): boolean => event.event === 'done' || event.event === 'error');
  }

  private codeTaskTurnRequestText(turn: CodeTaskConversationTurn): string {
    if (turn.hasRequest) {
      return this.codeTaskEventDetail(turn.request);
    }
    return this.selectedCodeTaskTitle.length > 0 ? this.selectedCodeTaskTitle : 'OpenCode 任务';
  }

  private codeTaskTurnOutputText(turn: CodeTaskConversationTurn): string {
    const chunks: string[] = [];
    turn.events.forEach((event: CodeTaskEventRecord): void => {
      if (event.event === 'output') {
        const text = stringValue(event.payload.text, stringValue(event.payload.message));
        if (text.length > 0) {
          chunks.push(text);
        }
      }
    });
    if (chunks.length > 0) {
      return chunks.join('\n');
    }
    return this.codeTaskTurnLastEventDetail(turn, 'done');
  }

  private codeTaskTurnLastEventDetail(turn: CodeTaskConversationTurn, eventName: string): string {
    for (let index = turn.events.length - 1; index >= 0; index -= 1) {
      const event = turn.events[index];
      if (event.event === eventName) {
        return this.codeTaskEventDetail(event);
      }
    }
    return '';
  }

  private codeTaskCleanFinalAnswer(text: string): string {
    const lines = text
      .replace(/\r\n/g, '\n')
      .split('\n')
      .map((line: string): string => line.trim())
      .filter((line: string): boolean => line.length > 0);
    const filtered = lines.filter((line: string): boolean => !this.isCodeTaskSelfNarrationLine(line));
    const normalized = (filtered.length > 0 ? filtered : lines).join('\n');
    return normalized.replace(/\n{3,}/g, '\n\n').trim();
  }

  private isCodeTaskSelfNarrationLine(line: string): boolean {
    if (/^(用户想要|用户说|用户要求|我需要|让我|我已经|现在我|我来|接下来|这有点|可能|也许)/.test(line)) {
      return true;
    }
    return /^(首先|然后|最后)?我(需要|会|已经|来)/.test(line);
  }

  private codeTaskCompactTitle(value: string): string {
    const normalized = value.replace(/\s+/g, ' ').trim();
    const fallback = this.selectedCodeTaskTitle.length > 0 ? this.selectedCodeTaskTitle : 'OpenCode 任务';
    const title = normalized.length > 0 ? normalized : fallback;
    return title.length > 30 ? `${title.substring(0, 30)}...` : title;
  }

  private codeTaskTurnEndTime(turn: CodeTaskConversationTurn): string {
    if (turn.events.length > 0) {
      return turn.events[turn.events.length - 1].createdAt;
    }
    return turn.request.createdAt;
  }

  private codeTaskTurnDuration(turn: CodeTaskConversationTurn): string {
    const startValue = turn.hasRequest ? turn.request.createdAt : (turn.events.length > 0 ? turn.events[0].createdAt : '');
    const endValue = this.codeTaskTurnEndTime(turn);
    const start = new Date(startValue).getTime();
    const end = new Date(endValue).getTime();
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) {
      return '';
    }
    const totalSeconds = Math.max(1, Math.round((end - start) / 1000));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    if (hours > 0) {
      return `${hours}h ${minutes}m ${seconds}s`;
    }
    if (minutes > 0) {
      return `${minutes}m ${seconds}s`;
    }
    return `${seconds}s`;
  }

  private upsertCodeTaskSummary(task: CodeTaskSummary): void {
    const next = this.codeTasks.slice();
    const index = next.findIndex((item: CodeTaskSummary): boolean => item.id === task.id);
    if (index >= 0) {
      next[index] = task;
    } else {
      next.unshift(task);
    }
    this.codeTasks = next;
  }

  private upsertCodeTaskSummaryFromSelected(lastEvent: CodeTaskEventRecord): void {
    const next = this.codeTasks.slice();
    const index = next.findIndex((item: CodeTaskSummary): boolean => item.id === this.selectedCodeTaskId);
    if (index < 0) {
      return;
    }
    const current = next[index];
    next[index] = {
      id: current.id,
      title: this.selectedCodeTaskTitle,
      prompt: stringValue(lastEvent.payload.text, current.prompt),
      workspacePath: stringValue(lastEvent.payload.workspacePath, current.workspacePath),
      status: this.selectedCodeTaskStatus,
      sessionId: stringValue(lastEvent.payload.sessionId, current.sessionId),
      serverUrl: stringValue(lastEvent.payload.serverUrl, current.serverUrl),
      running: this.selectedCodeTaskRunning,
      backgroundRunning: current.backgroundRunning,
      pendingQuestions: this.selectedCodeTaskQuestions,
      createdAt: current.createdAt,
      updatedAt: lastEvent.createdAt,
      eventCount: this.codeTaskEvents.length,
      lastEvent,
      summary: this.selectedCodeTaskSummary,
    };
    this.codeTasks = next;
  }

  private normalizedCodeTaskQuestions(
    questions: (CodeTaskQuestionPayload | null)[] | null | undefined,
  ): CodeTaskQuestionPayload[] {
    if (!Array.isArray(questions)) {
      return [];
    }
    return questions.filter((question: CodeTaskQuestionPayload | null | undefined): boolean => {
      return question !== undefined && question !== null && stringValue(question.requestId).length > 0;
    }) as CodeTaskQuestionPayload[];
  }

  private codeTaskQuestionsForDisplay(
    taskId: string,
    questions: (CodeTaskQuestionPayload | null)[] | null | undefined,
  ): CodeTaskQuestionPayload[] {
    const normalized = this.normalizedCodeTaskQuestions(questions);
    if (!this.hasPendingCodeTaskQuestionReply(taskId)) {
      return normalized;
    }
    const answeredRequestId = this.codeTaskPendingQuestionReplyRequestId;
    return normalized.filter((question: CodeTaskQuestionPayload): boolean => {
      return stringValue(question.requestId) !== answeredRequestId;
    });
  }

  private codeTaskDetailForDisplay(task: CodeTaskDetail): CodeTaskDetail {
    if (!this.hasPendingCodeTaskQuestionReply(task.id)) {
      return task;
    }
    const pendingQuestions = this.codeTaskQuestionsForDisplay(task.id, task.pendingQuestions);
    if (pendingQuestions.length === this.normalizedCodeTaskQuestions(task.pendingQuestions).length) {
      return task;
    }
    return {
      id: task.id,
      title: task.title,
      prompt: task.prompt,
      workspacePath: task.workspacePath,
      status: task.status,
      sessionId: task.sessionId,
      serverUrl: task.serverUrl,
      running: task.running,
      backgroundRunning: task.backgroundRunning,
      pendingQuestions,
      createdAt: task.createdAt,
      updatedAt: task.updatedAt,
      eventCount: task.eventCount,
      lastEvent: task.lastEvent,
      summary: task.summary,
      events: task.events,
      snapshot: task.snapshot,
    };
  }

  private addCodeTaskQuestion(payload: CodeTaskEventPayload): void {
    const requestId = stringValue(payload.requestId);
    if (requestId.length === 0) {
      return;
    }
    const question: CodeTaskQuestionPayload = {
      requestId,
      sessionId: payload.sessionId,
      questions: this.codeTaskQuestionItems(payload),
      message: payload.message,
      v2: payload.v2,
    };
    const next = this.selectedCodeTaskQuestions.filter((item: CodeTaskQuestionPayload): boolean => {
      return stringValue(item.requestId) !== requestId;
    });
    next.push(question);
    this.selectedCodeTaskQuestions = next;
    this.initCodeTaskQuestionDrafts();
  }

  private removeCodeTaskQuestion(requestId: string): void {
    if (requestId.length === 0) {
      this.selectedCodeTaskQuestions = [];
      this.codeTaskQuestionDrafts = [];
      return;
    }
    this.selectedCodeTaskQuestions = this.selectedCodeTaskQuestions.filter((item: CodeTaskQuestionPayload): boolean => {
      return stringValue(item.requestId) !== requestId;
    });
    this.initCodeTaskQuestionDrafts();
  }

  private hasPendingCodeTaskQuestionReply(taskId: string): boolean {
    return taskId.length > 0 &&
      this.codeTaskPendingQuestionReplyTaskId === taskId &&
      this.codeTaskPendingQuestionReplyRequestId.length > 0;
  }

  private clearPendingCodeTaskQuestionReply(taskId: string = ''): void {
    if (taskId.length > 0 && this.codeTaskPendingQuestionReplyTaskId !== taskId) {
      return;
    }
    this.codeTaskPendingQuestionReplyTaskId = '';
    this.codeTaskPendingQuestionReplyRequestId = '';
  }

  private beginLocalCodeTaskQuestionReplyProcessing(
    taskId: string,
    requestId: string,
    answers: string[][],
    rejected: boolean = false,
  ): void {
    this.codeTaskPendingQuestionReplyTaskId = taskId;
    this.codeTaskPendingQuestionReplyRequestId = requestId;
    const baseSeq = Date.now() * 1000 + this.codeTaskEvents.length;
    const createdAt = new Date().toISOString();
    const workspacePath = this.currentCodeTaskWorkspacePath();
    this.applyCodeTaskEvent({
      seq: baseSeq,
      event: 'question_result',
      payload: {
        taskId,
        requestId,
        answers,
        rejected,
        message: rejected ? '手机端已拒绝 OpenCode 选择。' : '手机端已提交 OpenCode 选择。',
        source: 'mobile-local',
        workspacePath,
      },
      createdAt,
    });
    this.applyCodeTaskEvent({
      seq: baseSeq + 1,
      event: 'status',
      payload: {
        taskId,
        status: 'running',
        message: '主机端正在根据选择继续处理任务。',
        source: 'mobile-local',
        workspacePath,
      },
      createdAt,
    });
    this.selectedCodeTaskRunning = true;
    this.selectedCodeTaskStatus = 'running';
    this.codeTaskConnectionMessage = '已提交选择，等待主机端完成任务...';
  }

  private cancelLocalCodeTaskQuestionReplyProcessing(
    taskId: string,
    requestId: string,
    question: CodeTaskQuestionPayload,
  ): void {
    this.codeTaskEvents = this.codeTaskEvents.filter((event: CodeTaskEventRecord): boolean => {
      if (stringValue(event.payload.source) !== 'mobile-local') {
        return true;
      }
      if (stringValue(event.payload.taskId, this.selectedCodeTaskId) !== taskId) {
        return true;
      }
      if (event.event === 'question_result') {
        return stringValue(event.payload.requestId) !== requestId;
      }
      return event.event !== 'status';
    });
    this.clearPendingCodeTaskQuestionReply(taskId);
    const existing = this.selectedCodeTaskQuestions.some((item: CodeTaskQuestionPayload): boolean => {
      return stringValue(item.requestId) === requestId;
    });
    if (!existing) {
      this.selectedCodeTaskQuestions = this.selectedCodeTaskQuestions.concat([question]);
      this.initCodeTaskQuestionDrafts();
    }
    this.selectedCodeTaskStatus = 'waiting_input';
    this.selectedCodeTaskRunning = true;
  }

  private applyCodeTaskQuestionReplyResult(
    taskId: string,
    requestId: string,
    result: CodeTaskQuestionReplyResult,
    afterSeq: number,
  ): void {
    if (taskId !== this.selectedCodeTaskId) {
      return;
    }
    if (result.task === undefined) {
      this.waitForCodeTaskResultAfterQuestionReply(taskId, requestId, afterSeq);
      return;
    }
    const wasAtBottom = this.shouldAutoFollowCodeTaskBottom();
    const detail = this.codeTaskDetailForDisplay(result.task);
    const detailStatus = this.codeTaskDetailStatus(detail);
    const pendingQuestions = this.codeTaskQuestionsForDisplay(taskId, detail.pendingQuestions);
    if (result.timedOut === true && pendingQuestions.length === 0 && !this.isCodeTaskTerminalStatus(detailStatus)) {
      this.scheduleCodeTaskReopenRefresh(taskId, CODE_TASK_REOPEN_REFRESH_RETRY_MS, true);
      return;
    }
    this.applyCodeTaskDetail(detail, true);
    if (pendingQuestions.length > 0 || this.isCodeTaskTerminalStatus(detailStatus) || !this.isCodeTaskTaskRunning(detail.running, detailStatus, detail.backgroundRunning)) {
      this.clearPendingCodeTaskQuestionReply(taskId);
    }
    this.codeTaskConnectionMessage = pendingQuestions.length > 0 ? '主机端等待选择' : '已同步任务结果';
    this.preserveCodeTaskScrollAfterUpdate(wasAtBottom);
  }

  private lastHostCodeTaskEventSeq(): number {
    let output = 0;
    this.codeTaskEvents.forEach((event: CodeTaskEventRecord): void => {
      if (stringValue(event.payload.source) === 'mobile-local') {
        return;
      }
      if (event.seq > output) {
        output = event.seq;
      }
    });
    return output;
  }

  private waitForCodeTaskResultAfterQuestionReply(
    taskId: string,
    requestId: string,
    afterSeq: number,
  ): void {
    CodeTaskRemoteService.waitTaskResult(
      this.hostAgentSettings,
      taskId,
      afterSeq,
      requestId,
      180,
    ).then((result): void => {
      if (taskId !== this.selectedCodeTaskId || result.task === undefined) {
        return;
      }
      const wasAtBottom = this.shouldAutoFollowCodeTaskBottom();
      const detail = this.codeTaskDetailForDisplay(result.task);
      const detailStatus = this.codeTaskDetailStatus(detail);
      const pendingQuestions = this.codeTaskQuestionsForDisplay(taskId, detail.pendingQuestions);
      if (result.timedOut === true && pendingQuestions.length === 0 && !this.isCodeTaskTerminalStatus(detailStatus)) {
        this.scheduleCodeTaskReopenRefresh(taskId, CODE_TASK_REOPEN_REFRESH_RETRY_MS, true);
        return;
      }
      this.applyCodeTaskDetail(detail, true);
      if (pendingQuestions.length > 0 || this.isCodeTaskTerminalStatus(detailStatus) || !this.isCodeTaskTaskRunning(detail.running, detailStatus, detail.backgroundRunning)) {
        this.clearPendingCodeTaskQuestionReply(taskId);
      }
      this.codeTaskConnectionMessage = pendingQuestions.length > 0 ? '主机端等待选择' : '已同步任务结果';
      this.preserveCodeTaskScrollAfterUpdate(wasAtBottom);
    }).catch((error: Error | Object | string): void => {
      console.error(`[Amaduse] wait code task result failed: ${errorToString(error)}`);
      if (taskId === this.selectedCodeTaskId && this.hasPendingCodeTaskQuestionReply(taskId)) {
        this.scheduleCodeTaskReopenRefresh(taskId, CODE_TASK_REOPEN_REFRESH_RETRY_MS, true);
      }
    });
  }

  private initCodeTaskQuestionDrafts(): void {
    if (this.selectedCodeTaskQuestions.length === 0) {
      this.codeTaskQuestionDrafts = [];
      return;
    }
    const items = this.codeTaskQuestionItems(this.selectedCodeTaskQuestions[0]);
    this.codeTaskQuestionDrafts = items.map((_: CodeTaskQuestionItem, index: number): CodeTaskQuestionDraft => {
      const existing = this.codeTaskQuestionDrafts.find((draft: CodeTaskQuestionDraft): boolean => draft.index === index);
      return existing !== undefined ? existing : {
        index,
        selected: [],
        custom: '',
      };
    });
  }

  private codeTaskQuestionItems(question: CodeTaskQuestionPayload): CodeTaskQuestionItem[] {
    return Array.isArray(question.questions) ? question.questions : [];
  }

  private codeTaskQuestionOptions(item: CodeTaskQuestionItem): CodeTaskQuestionOption[] {
    return Array.isArray(item.options) ? item.options : [];
  }

  private activeCodeTaskQuestionItem(index: number): CodeTaskQuestionItem | undefined {
    if (this.selectedCodeTaskQuestions.length === 0) {
      return undefined;
    }
    const items = this.codeTaskQuestionItems(this.selectedCodeTaskQuestions[0]);
    if (index < 0 || index >= items.length) {
      return undefined;
    }
    return items[index];
  }

  private codeTaskQuestionDraft(index: number): CodeTaskQuestionDraft {
    const existing = this.codeTaskQuestionDrafts.find((draft: CodeTaskQuestionDraft): boolean => draft.index === index);
    if (existing !== undefined) {
      return existing;
    }
    return {
      index,
      selected: [],
      custom: '',
    };
  }

  private isCodeTaskQuestionOptionSelected(questionIndex: number, label: string): boolean {
    return this.codeTaskQuestionDraft(questionIndex).selected.indexOf(label) >= 0;
  }

  private toggleCodeTaskQuestionOption(questionIndex: number, label: string): void {
    if (label.length === 0) {
      return;
    }
    const item = this.activeCodeTaskQuestionItem(questionIndex);
    const multiple = item?.multiple === true;
    const next = this.codeTaskQuestionDrafts.slice();
    const existingIndex = next.findIndex((draft: CodeTaskQuestionDraft): boolean => draft.index === questionIndex);
    const draft = existingIndex >= 0 ? next[existingIndex] : this.codeTaskQuestionDraft(questionIndex);
    let selected: string[] = [];
    if (multiple) {
      selected = draft.selected.indexOf(label) >= 0
        ? draft.selected.filter((itemLabel: string): boolean => itemLabel !== label)
        : draft.selected.concat([label]);
    } else {
      selected = draft.selected.indexOf(label) >= 0 ? [] : [label];
    }
    const updated: CodeTaskQuestionDraft = {
      index: questionIndex,
      selected,
      custom: draft.custom,
    };
    if (existingIndex >= 0) {
      next[existingIndex] = updated;
    } else {
      next.push(updated);
    }
    this.codeTaskQuestionDrafts = next;
  }

  private codeTaskQuestionCustomValue(index: number): string {
    return this.codeTaskQuestionDraft(index).custom;
  }

  private setCodeTaskQuestionCustom(index: number, value: string): void {
    const next = this.codeTaskQuestionDrafts.slice();
    const existingIndex = next.findIndex((draft: CodeTaskQuestionDraft): boolean => draft.index === index);
    const draft = existingIndex >= 0 ? next[existingIndex] : this.codeTaskQuestionDraft(index);
    const updated: CodeTaskQuestionDraft = {
      index,
      selected: draft.selected,
      custom: value,
    };
    if (existingIndex >= 0) {
      next[existingIndex] = updated;
    } else {
      next.push(updated);
    }
    this.codeTaskQuestionDrafts = next;
  }

  private buildCodeTaskQuestionAnswers(question: CodeTaskQuestionPayload): string[][] {
    const items = this.codeTaskQuestionItems(question);
    return items.map((_: CodeTaskQuestionItem, index: number): string[] => {
      const draft = this.codeTaskQuestionDraft(index);
      const answers = draft.selected.slice();
      const custom = draft.custom.trim();
      if (custom.length > 0) {
        answers.push(custom);
      }
      return answers;
    });
  }

  private codeTaskBridgeForCommand(): CodeTaskBridgeStream | undefined {
    if (!CodeTaskRemoteService.isConfigured(this.hostAgentSettings)) {
      throw new Error('请先配置远程主机。');
    }
    if (this.codeTaskBridge === undefined) {
      this.connectCodeTaskBridge();
    }
    return this.codeTaskBridge;
  }

  private async replyCodeTaskQuestion(question: CodeTaskQuestionPayload): Promise<void> {
    if (this.codeTaskReplying) {
      return;
    }
    const requestId = stringValue(question.requestId);
    if (requestId.length === 0 || this.selectedCodeTaskId.length === 0) {
      return;
    }
    const taskId = this.selectedCodeTaskId;
    const answers = this.buildCodeTaskQuestionAnswers(question);
    if (answers.length === 0 || answers.some((item: string[]): boolean => item.length === 0)) {
      this.showToast('请先完成选择或自定义回答');
      return;
    }
    this.codeTaskReplying = true;
    this.beginLocalCodeTaskQuestionReplyProcessing(taskId, requestId, answers, false);
    this.selectedCodeTaskQuestions = this.codeTaskQuestionsForDisplay(taskId, this.selectedCodeTaskQuestions);
    this.initCodeTaskQuestionDrafts();
    try {
      const bridge = this.codeTaskBridgeForCommand();
      let result: CodeTaskQuestionReplyResult;
      try {
        if (bridge === undefined) {
          throw new Error('主机 bridge 未连接。');
        }
        result = await bridge.replyQuestion(
          taskId,
          requestId,
          answers,
          question.v2 !== false,
          false,
        );
      } catch (bridgeError) {
        this.codeTaskConnectionMessage = `bridge 发送失败，改用 HTTP 提交：${errorToString(bridgeError).substring(0, 48)}`;
        result = await CodeTaskRemoteService.replyBridgeQuestion(
          this.hostAgentSettings,
          taskId,
          requestId,
          answers,
          question.v2 !== false,
          false,
        );
      }
      if (result.ok === false) {
        throw new Error(stringValue(result.error, '主机端拒绝了选择提交。'));
      }
      this.codeTaskConnectionMessage = '已提交选择，等待主机端推送结果';
      this.showToast('已提交选择');
    } catch (error) {
      this.cancelLocalCodeTaskQuestionReplyProcessing(taskId, requestId, question);
      this.showToast(`提交失败：${errorToString(error).substring(0, 48)}`);
    } finally {
      this.codeTaskReplying = false;
    }
  }

  private async rejectCodeTaskQuestion(question: CodeTaskQuestionPayload): Promise<void> {
    if (this.codeTaskReplying) {
      return;
    }
    const requestId = stringValue(question.requestId);
    if (requestId.length === 0 || this.selectedCodeTaskId.length === 0) {
      return;
    }
    const taskId = this.selectedCodeTaskId;
    this.codeTaskReplying = true;
    this.beginLocalCodeTaskQuestionReplyProcessing(taskId, requestId, [], true);
    this.selectedCodeTaskQuestions = this.codeTaskQuestionsForDisplay(taskId, this.selectedCodeTaskQuestions);
    this.initCodeTaskQuestionDrafts();
    try {
      const bridge = this.codeTaskBridgeForCommand();
      let result: CodeTaskQuestionReplyResult;
      try {
        if (bridge === undefined) {
          throw new Error('主机 bridge 未连接。');
        }
        result = await bridge.replyQuestion(
          taskId,
          requestId,
          [],
          question.v2 !== false,
          true,
        );
      } catch (bridgeError) {
        this.codeTaskConnectionMessage = `bridge 发送失败，改用 HTTP 提交：${errorToString(bridgeError).substring(0, 48)}`;
        result = await CodeTaskRemoteService.replyBridgeQuestion(
          this.hostAgentSettings,
          taskId,
          requestId,
          [],
          question.v2 !== false,
          true,
        );
      }
      if (result.ok === false) {
        throw new Error(stringValue(result.error, '主机端拒绝了选择提交。'));
      }
      this.codeTaskConnectionMessage = '已拒绝选择，等待主机端推送结果';
      this.showToast('已拒绝');
    } catch (error) {
      this.cancelLocalCodeTaskQuestionReplyProcessing(taskId, requestId, question);
      this.showToast(`拒绝失败：${errorToString(error).substring(0, 48)}`);
    } finally {
      this.codeTaskReplying = false;
    }
  }

  private canSendCodeTaskMessage(): boolean {
    return CodeTaskRemoteService.isConfigured(this.hostAgentSettings) &&
      !this.codeTaskSending &&
      this.codeTaskMessageDraft.trim().length > 0;
  }

  private async sendCodeTaskMessage(): Promise<void> {
    if (!this.canSendCodeTaskMessage()) {
      return;
    }
    const prompt = this.codeTaskMessageDraft.trim();
    let taskId = this.selectedCodeTaskId;
    const isNewTask = taskId.length === 0;
    const title = isNewTask ? this.codeTaskCompactTitle(prompt) :
      (this.selectedCodeTaskTitle.length > 0 ? this.selectedCodeTaskTitle : this.codeTaskCompactTitle(prompt));
    this.codeTaskSending = true;
    this.codeTaskMessageDraft = '';
    if (isNewTask) {
      taskId = createId('code-task');
      const createdAt = new Date().toISOString();
      this.selectedCodeTaskId = taskId;
      this.selectedCodeTaskTitle = title;
      this.selectedCodeTaskStatus = 'running';
      this.selectedCodeTaskRunning = true;
      this.selectedCodeTaskSummary = '';
      this.selectedCodeTaskQuestions = [];
      this.codeTaskQuestionDrafts = [];
      this.codeTaskEvents = [];
      this.codeTaskExpandedTurnIds = [];
      this.codeTaskDetachedFromBottom = false;
      this.clearPendingCodeTaskQuestionReply();
      this.upsertCodeTaskSummary({
        id: taskId,
        title,
        prompt,
        status: 'running',
        running: true,
        backgroundRunning: true,
        createdAt,
        updatedAt: createdAt,
        eventCount: 0,
      });
    } else if (this.selectedCodeTaskTitle.length === 0) {
      this.selectedCodeTaskTitle = title;
    }
    this.beginLocalCodeTaskProcessing(taskId, prompt);
    try {
      const bridge = this.codeTaskBridgeForCommand();
      const workspacePath = this.currentCodeTaskWorkspacePath();
      let result: CodeTaskMessageResult;
      try {
        if (bridge === undefined) {
          throw new Error('主机 bridge 未连接。');
        }
        result = await bridge.sendTask(
          taskId,
          prompt,
          title,
          workspacePath,
        );
      } catch (bridgeError) {
        this.codeTaskConnectionMessage = `bridge 发送失败，改用 HTTP 提交：${errorToString(bridgeError).substring(0, 48)}`;
        result = await CodeTaskRemoteService.sendBridgeTask(
          this.hostAgentSettings,
          taskId,
          prompt,
          title,
          workspacePath,
        );
      }
      if (result.ok === false) {
        throw new Error(stringValue(result.error, '主机端拒绝了任务提交。'));
      }
      this.codeTaskConnectionMessage = stringValue(result.summary, '已发送，等待主机端推送任务过程');
      this.showToast('已发送到主机端');
    } catch (error) {
      if (this.selectedCodeTaskId === taskId && this.codeTaskMessageDraft.length === 0) {
        this.codeTaskMessageDraft = prompt;
      }
      this.cancelLocalCodeTaskProcessing(taskId, prompt);
      this.selectedCodeTaskRunning = false;
      this.selectedCodeTaskStatus = 'error';
      const failedTask = this.codeTasks.find((task: CodeTaskSummary): boolean => task.id === taskId);
      if (failedTask !== undefined) {
        this.upsertCodeTaskSummary({
          id: failedTask.id,
          title: failedTask.title,
          prompt: failedTask.prompt,
          workspacePath: failedTask.workspacePath,
          status: 'error',
          sessionId: failedTask.sessionId,
          serverUrl: failedTask.serverUrl,
          running: false,
          backgroundRunning: false,
          pendingQuestions: failedTask.pendingQuestions,
          createdAt: failedTask.createdAt,
          updatedAt: new Date().toISOString(),
          eventCount: this.codeTaskEvents.length,
          lastEvent: failedTask.lastEvent,
          summary: failedTask.summary,
        });
      }
      this.codeTaskConnectionMessage = `发送失败：${errorToString(error).substring(0, 80)}`;
      this.showToast(`发送失败：${errorToString(error).substring(0, 48)}`);
    } finally {
      this.codeTaskSending = false;
    }
  }

  private codeTaskRowSubtitle(task: CodeTaskSummary): string {
    const status = this.codeTaskStatusText(this.codeTaskSummaryStatus(task, ''));
    const prompt = stringValue(task.prompt, stringValue(task.workspacePath));
    const count = task.eventCount === undefined ? 0 : task.eventCount;
    return `${status} · ${count} 条 · ${prompt}`;
  }

  private codeTaskSummaryStatus(task: CodeTaskSummary, fallback: string): string {
    const status = stringValue(task.status);
    if (task.lastEvent !== undefined && task.lastEvent.event === 'error') {
      return 'error';
    }
    if (task.lastEvent !== undefined && task.lastEvent.event === 'done' && !this.isCodeTaskErrorStatus(status)) {
      return stringValue(task.lastEvent.payload.status, 'done');
    }
    if (status.length > 0) {
      return status;
    }
    if (task.lastEvent !== undefined) {
      if (task.lastEvent.event === 'question') {
        return 'waiting_input';
      }
    }
    return fallback;
  }

  private codeTaskStatusText(status: string): string {
    const normalized = status.toLowerCase();
    if (normalized === 'waiting_input') {
      return '等待选择';
    }
    if (normalized === 'running' ||
      normalized === 'session' ||
      normalized === 'starting' ||
      normalized === 'connecting' ||
      normalized === 'busy' ||
      normalized === 'processing') {
      return '运行中';
    }
    if (normalized === 'idle' ||
      normalized === 'done' ||
      normalized === 'completed' ||
      normalized === 'complete' ||
      normalized === 'finished' ||
      normalized === 'success' ||
      normalized === 'succeeded') {
      return '已完成';
    }
    if (normalized === 'stopped' || normalized === 'cancelled' || normalized === 'canceled') {
      return '已停止';
    }
    if (this.isCodeTaskErrorStatus(status)) {
      return '错误';
    }
    return status.length > 0 ? status : '未知';
  }

  private codeTaskStatusColor(status: string): string {
    const normalized = status.toLowerCase();
    if (normalized === 'waiting_input') {
      return '#F3C21B';
    }
    if (this.isCodeTaskErrorStatus(status)) {
      return DANGER;
    }
    if (this.isCodeTaskTerminalStatus(status)) {
      return ACTIVE_GREEN;
    }
    return BLUE;
  }

  private codeTaskEventIcon(event: string): string {
    if (event === 'input') {
      return 'I';
    }
    if (event === 'output') {
      return 'O';
    }
    if (event === 'question') {
      return '?';
    }
    if (event === 'question_result' || event === 'done') {
      return '✓';
    }
    if (event === 'command') {
      return '$';
    }
    if (event === 'file') {
      return 'F';
    }
    if (event === 'diff') {
      return 'D';
    }
    if (event === 'error' || event === 'permission') {
      return '!';
    }
    return '•';
  }

  private codeTaskEventColor(event: string): string {
    if (event === 'error') {
      return DANGER;
    }
    if (event === 'question' || event === 'permission') {
      return '#F3C21B';
    }
    if (event === 'done' || event === 'question_result') {
      return ACTIVE_GREEN;
    }
    if (event === 'output') {
      return INK_BLACK;
    }
    return BLUE;
  }

  private codeTaskEventTitle(event: CodeTaskEventRecord): string {
    const payload = event.payload;
    if (event.event === 'input') {
      return stringValue(payload.source) === 'mobile' ? '手机端指令' : '任务指令';
    }
    if (event.event === 'output') {
      return 'OpenCode 输出';
    }
    if (event.event === 'tool') {
      return `工具 ${stringValue(payload.name, 'tool')}`;
    }
    if (event.event === 'command') {
      return '命令执行';
    }
    if (event.event === 'file') {
      return '文件变更';
    }
    if (event.event === 'diff') {
      return '文件差异';
    }
    if (event.event === 'question') {
      return 'OpenCode 需要选择';
    }
    if (event.event === 'question_result') {
      return payload.rejected === true ? '已拒绝选择' : '已提交选择';
    }
    if (event.event === 'permission') {
      return '权限请求';
    }
    if (event.event === 'done') {
      return '任务结束';
    }
    if (event.event === 'error') {
      return '任务错误';
    }
    if (event.event === 'status') {
      return this.codeTaskStatusText(stringValue(payload.status));
    }
    if (event.event === 'session') {
      return '会话已连接';
    }
    return event.event;
  }

  private codeTaskEventDetail(event: CodeTaskEventRecord): string {
    const payload = event.payload;
    if (event.event === 'output') {
      return this.limitCodeTaskText(stringValue(payload.text), 1200);
    }
    if (event.event === 'input') {
      return this.limitCodeTaskText(stringValue(payload.text, stringValue(payload.message)), 1200);
    }
    if (event.event === 'command') {
      return this.limitCodeTaskText(stringValue(payload.command, stringValue(payload.output, stringValue(payload.message))), 1200);
    }
    if (event.event === 'file') {
      return stringValue(payload.path, stringValue(payload.message));
    }
    if (event.event === 'diff') {
      return this.limitCodeTaskText(stringValue(payload.diff, stringValue(payload.message)), 1200);
    }
    if (event.event === 'question') {
      return this.codeTaskQuestionSummary(payload);
    }
    if (event.event === 'question_result') {
      if (payload.rejected === true) {
        return stringValue(payload.message, '已拒绝。');
      }
      return this.limitCodeTaskText(this.stringifyCodeTaskAnswers(payload.answers), 500);
    }
    if (event.event === 'tool') {
      return this.limitCodeTaskText(stringValue(payload.detail, stringValue(payload.message)), 1200);
    }
    if (event.event === 'session') {
      return stringValue(payload.workspacePath, stringValue(payload.serverUrl));
    }
    return this.limitCodeTaskText(stringValue(payload.message, stringValue(payload.status)), 1200);
  }

  private codeTaskQuestionSummary(question: CodeTaskQuestionPayload): string {
    const items = this.codeTaskQuestionItems(question);
    if (items.length === 0) {
      return stringValue(question.message, 'OpenCode 请求你选择或补充信息。');
    }
    return items.map((item: CodeTaskQuestionItem, index: number): string => {
      return `${index + 1}. ${stringValue(item.question, stringValue(item.header, '请选择'))}`;
    }).join('\n');
  }

  private stringifyCodeTaskAnswers(answers: string[][] | undefined): string {
    if (!Array.isArray(answers) || answers.length === 0) {
      return '已提交。';
    }
    return answers.map((item: string[], index: number): string => {
      return `${index + 1}. ${item.join('，')}`;
    }).join('\n');
  }

  private limitCodeTaskText(value: string, limit: number): string {
    if (value.length <= limit) {
      return value;
    }
    return `${value.substring(0, limit)}...`;
  }

  private shortTimeText(value: string): string {
    if (value.length === 0) {
      return '';
    }
    const marker = value.indexOf('T');
    if (marker >= 0 && value.length >= marker + 6) {
      return value.substring(marker + 1, marker + 6);
    }
    return value.substring(0, Math.min(8, value.length));
  }

  private openSettings(mode: SettingsSheetMode): void {
    this.prepareSettingsDraft(mode);
    this.settingsSheetMode = mode;
    this.settingsVisible = true;
  }

  private prepareSettingsDraft(mode: SettingsSheetMode): void {
    const currentConfigured = this.configuredModels.find((item: ConfiguredModel) => item.id === this.modelSettings.configuredModelId);
    this.settingsSheetMode = mode;
    this.editModelId = currentConfigured?.id ?? '';
    this.editProvider = currentConfigured?.provider ?? this.modelSettings.provider;
    this.editDisplayName = currentConfigured?.displayName ?? this.modelSettings.provider.name;
    this.editModel = currentConfigured?.model ?? this.modelSettings.model;
    this.editBaseUrl = currentConfigured?.baseUrl ?? this.modelSettings.baseUrl;
    this.editApiKey = currentConfigured?.apiKey ?? this.modelSettings.apiKey;
    this.editVoiceApiKey = this.voiceSettings.siliconFlowApiKey;
    this.editVoiceUri = this.voiceSettings.clonedVoiceUri;
    this.editVoiceEnabled = this.voiceSettings.ttsBackend !== VoiceBackend.Off;
    this.editVoiceAutoPlay = this.voiceSettings.autoPlay;
    this.editVoiceSync = this.voiceSettings.syncTextOutput;
    this.editHostAgentEnabled = this.hostAgentSettings.enabled;
    this.editHostAgentBaseUrl = this.hostAgentSettings.baseUrl;
    this.editHostAgentEndpointPath = this.hostAgentSettings.endpointPath;
    this.editHostAgentApiKey = this.hostAgentSettings.apiKey;
  }

  private async saveSettings(): Promise<void> {
    const savedModel = makeConfiguredModel(
      this.editModelId,
      this.editDisplayName.trim(),
      this.editProvider,
      this.editModel.trim(),
      this.editBaseUrl.trim(),
      this.editApiKey.trim(),
    );
    const nextModels = this.configuredModels.slice();
    const existingIndex = nextModels.findIndex((item: ConfiguredModel) => item.id === savedModel.id);
    if (existingIndex >= 0) {
      nextModels[existingIndex] = savedModel;
    } else {
      nextModels.unshift(savedModel);
    }
    const nextSettings = configuredModelToSettings(savedModel);
    const editedVoiceUri = this.editVoiceUri.trim();
    const nextVoice: VoiceSettings = {
      ttsBackend: this.editVoiceEnabled ? VoiceBackend.Cloud : VoiceBackend.Off,
      siliconFlowApiKey: this.editVoiceApiKey.trim(),
      referenceAudioSource: this.voiceSettings.referenceAudioSource,
      clonedVoiceUri: editedVoiceUri,
      clonedVoiceReferenceKey: editedVoiceUri === this.voiceSettings.clonedVoiceUri ? this.voiceSettings.clonedVoiceReferenceKey : '',
      autoPlay: this.editVoiceAutoPlay,
      syncTextOutput: this.editVoiceSync,
      speed: this.voiceSettings.speed,
      gain: this.voiceSettings.gain,
    };
    const nextHostAgent: HostAgentSettings = {
      enabled: this.editHostAgentEnabled,
      baseUrl: this.editHostAgentBaseUrl.trim(),
      endpointPath: this.editHostAgentEndpointPath.trim().length > 0 ? this.editHostAgentEndpointPath.trim() : '/api/agent/invoke',
      apiKey: this.editHostAgentApiKey.trim(),
    };
    this.configuredModels = nextModels;
    this.modelSettings = nextSettings;
    this.voiceSettings = nextVoice;
    this.hostAgentSettings = nextHostAgent;
    const context = this.abilityContext();
    await ChatPersistence.saveConfiguredModels(context, nextModels);
    await ChatPersistence.saveModelSettings(context, nextSettings);
    await ChatPersistence.saveVoiceSettings(context, nextVoice);
    await ChatPersistence.saveHostAgentSettings(context, nextHostAgent);
    await ChatPersistence.saveChatMode(context, this.selectedMode);
    this.settingsVisible = false;
    this.disconnectCodeTaskBridge();
    if (this.codeTaskProgress > 0 && CodeTaskRemoteService.isConfigured(nextHostAgent)) {
      this.refreshCodeTasks();
    }
  }

  private voiceSwitchSelected(kind: string): boolean {
    if (kind === 'enabled') {
      return this.editVoiceEnabled;
    }
    if (kind === 'autoPlay') {
      return this.editVoiceAutoPlay;
    }
    return this.editVoiceSync;
  }

  private toggleVoiceSwitch(kind: string, label: string): void {
    const next = !this.voiceSwitchSelected(kind);
    console.info(`[Amaduse] voice switch tap label=${label} next=${next}`);
    if (kind === 'enabled') {
      this.setVoiceEnabled(next);
      return;
    }
    if (kind === 'autoPlay') {
      this.setVoiceAutoPlay(next);
      return;
    }
    this.setVoiceSync(next);
  }

  private setVoiceEnabled(enabled: boolean): void {
    this.applyVoiceSwitches(enabled, this.editVoiceAutoPlay, this.editVoiceSync);
  }

  private setVoiceAutoPlay(autoPlay: boolean): void {
    this.applyVoiceSwitches(this.editVoiceEnabled, autoPlay, this.editVoiceSync);
  }

  private setVoiceSync(syncTextOutput: boolean): void {
    this.applyVoiceSwitches(this.editVoiceEnabled, this.editVoiceAutoPlay, syncTextOutput);
  }

  private applyVoiceSwitches(enabled: boolean, autoPlay: boolean, syncTextOutput: boolean): void {
    this.editVoiceEnabled = enabled;
    this.editVoiceAutoPlay = autoPlay;
    this.editVoiceSync = syncTextOutput;
    const editedVoiceUri = this.editVoiceUri.trim();
    const nextVoice: VoiceSettings = {
      ttsBackend: enabled ? VoiceBackend.Cloud : VoiceBackend.Off,
      siliconFlowApiKey: this.editVoiceApiKey.trim(),
      referenceAudioSource: this.voiceSettings.referenceAudioSource,
      clonedVoiceUri: editedVoiceUri,
      clonedVoiceReferenceKey: editedVoiceUri === this.voiceSettings.clonedVoiceUri ? this.voiceSettings.clonedVoiceReferenceKey : '',
      autoPlay,
      syncTextOutput,
      speed: this.voiceSettings.speed,
      gain: this.voiceSettings.gain,
    };
    this.voiceSettings = nextVoice;
    console.info(`[Amaduse] voice switches enabled=${enabled} autoPlay=${autoPlay} syncText=${syncTextOutput}`);
    ChatPersistence.saveVoiceSettings(this.abilityContext(), nextVoice)
      .then(async (): Promise<void> => {
        if (nextVoice.ttsBackend === VoiceBackend.Off) {
          await VoiceService.stopCurrentPlayer();
        }
      })
      .catch((error: Error | Object | string): void => {
        console.error(`[Amaduse] save voice switch failed: ${errorToString(error)}`);
        this.showToast('语音开关保存失败');
      });
  }

  private canSend(): boolean {
    return !this.sending && (this.draft.trim().length > 0 || this.attachments.length > 0);
  }

  private hasStreamingMessage(): boolean {
    return this.messages.findIndex((message: ChatMessage) => message.streaming) >= 0;
  }

  private transcriptHeight(): string {
    const height = TRANSCRIPT_COLLAPSED_PERCENT +
      (TRANSCRIPT_EXPANDED_PERCENT - TRANSCRIPT_COLLAPSED_PERCENT) * this.transcriptProgress;
    return `${height}%`;
  }

  private transcriptHandleWidth(): number {
    return 42 + 6 * this.transcriptProgress;
  }

  private transcriptHorizontalPadding(): number {
    return 10 * this.transcriptProgress;
  }

  private transcriptTopPadding(): number {
    return 8 * this.transcriptProgress;
  }

  private transcriptBorderRadius(): number {
    return 22 + 6 * this.transcriptProgress;
  }

  private transcriptBorderWidth(): number {
    return this.transcriptProgress > 0.04 ? 1 : 0;
  }

  private transcriptBackgroundColor(): string {
    if (this.transcriptProgress <= 0.02) {
      return '#00FFFFFF';
    }
    const alpha = Math.round(168 * this.transcriptProgress);
    return `#${this.hexByte(alpha)}EFF3F2`;
  }

  private setTranscriptExpanded(expanded: boolean): void {
    const targetProgress = expanded ? 1 : 0;
    if (this.characterExpanded === expanded && Math.abs(this.transcriptProgress - targetProgress) < 0.01) {
      return;
    }
    this.getUIContext().animateTo({
      duration: 220,
      curve: Curve.EaseOut,
      onFinish: () => {
        this.characterExpanded = expanded;
        this.transcriptProgress = targetProgress;
        this.scrollTranscriptToBottom(true);
      },
    }, () => {
      this.characterExpanded = expanded;
      this.transcriptProgress = targetProgress;
    });
  }

  private beginTranscriptPan(): void {
    this.transcriptDragStartProgress = this.transcriptProgress;
  }

  private updateTranscriptPan(event: GestureEvent): void {
    const nextProgress = this.transcriptDragStartProgress - event.offsetY / TRANSCRIPT_DRAG_RANGE;
    this.transcriptProgress = this.clampTranscriptProgress(nextProgress);
    this.characterExpanded = this.transcriptProgress >= 0.5;
  }

  private finishTranscriptPan(event: GestureEvent): void {
    const projectedProgress = this.transcriptDragStartProgress -
      event.offsetY / TRANSCRIPT_DRAG_RANGE -
      event.velocityY / 2600;
    this.setTranscriptExpanded(this.clampTranscriptProgress(projectedProgress) >= 0.5);
  }

  private resetTranscriptPanel(): void {
    this.characterExpanded = false;
    this.transcriptProgress = 0;
    this.transcriptDragStartProgress = 0;
    this.transcriptDetachedFromBottom = false;
  }

  private clampTranscriptProgress(value: number): number {
    return Math.max(0, Math.min(1, value));
  }

  private updateTranscriptBottomButton(): void {
    if (this.transcriptAutoScrolling) {
      return;
    }
    this.transcriptDetachedFromBottom = !this.isTranscriptAtBottom();
  }

  private markTranscriptAtBottom(): void {
    this.transcriptDetachedFromBottom = false;
  }

  private isTranscriptAtBottom(): boolean {
    try {
      return this.transcriptScroller.isAtEnd();
    } catch (_) {
      return true;
    }
  }

  private returnTranscriptToBottom(): void {
    this.scrollTranscriptToBottom(true);
  }

  private hexByte(value: number): string {
    const bounded = Math.max(0, Math.min(255, Math.round(value)));
    const digits = '0123456789ABCDEF';
    const high = Math.floor(bounded / 16);
    const low = bounded - high * 16;
    return `${digits.charAt(high)}${digits.charAt(low)}`;
  }

  private openHistoryScreen(): void {
    this.setHistoryProgress(1);
  }

  private closeHistoryScreen(): void {
    this.setHistoryProgress(0);
  }

  private beginPagePan(event: GestureEvent): void {
    this.pageDragStartProgress = this.historyProgress;
    this.codeTaskDragStartProgress = this.codeTaskProgress;
  }

  private updatePagePan(event: GestureEvent): void {
    if (this.pageDragStartProgress > 0) {
      this.historyProgress = this.clampPageProgress(this.pageDragStartProgress + event.offsetX / PAGE_SLIDE_WIDTH);
      this.codeTaskProgress = 0;
    } else if (this.codeTaskDragStartProgress > 0) {
      this.codeTaskProgress = this.clampPageProgress(this.codeTaskDragStartProgress - event.offsetX / PAGE_SLIDE_WIDTH);
      this.historyProgress = 0;
    } else if (event.offsetX >= 0) {
      this.historyProgress = this.clampPageProgress(event.offsetX / PAGE_SLIDE_WIDTH);
      this.codeTaskProgress = 0;
    } else {
      this.codeTaskProgress = this.clampPageProgress(-event.offsetX / PAGE_SLIDE_WIDTH);
      this.historyProgress = 0;
    }
    if (this.historyProgress > 0) {
      this.appScreen = AppScreen.History;
    } else {
      this.appScreen = AppScreen.Chat;
    }
  }

  private finishPagePan(event: GestureEvent): void {
    if (this.pageDragStartProgress > 0) {
      const projectedHistory = this.pageDragStartProgress + event.offsetX / PAGE_SLIDE_WIDTH + event.velocityX / 2600;
      this.setHistoryProgress(projectedHistory >= 0.5 ? 1 : 0);
      return;
    }
    if (this.codeTaskDragStartProgress > 0) {
      const projectedTask = this.codeTaskDragStartProgress - event.offsetX / PAGE_SLIDE_WIDTH - event.velocityX / 2600;
      this.setCodeTaskProgress(projectedTask >= 0.5 ? 1 : 0);
      return;
    }
    const projected = event.offsetX / PAGE_SLIDE_WIDTH + event.velocityX / 2600;
    if (projected >= 0.5) {
      this.setHistoryProgress(1);
      return;
    }
    if (projected <= -0.5) {
      this.openCodeTaskScreen();
      return;
    }
    this.setHistoryProgress(0);
    this.setCodeTaskProgress(0);
  }

  private setHistoryProgress(target: number): void {
    const finalProgress = this.clampPageProgress(target);
    if (finalProgress > 0) {
      this.appScreen = AppScreen.History;
      this.codeTaskProgress = 0;
    }
    this.getUIContext().animateTo({
      duration: 230,
      curve: Curve.EaseOut,
      onFinish: () => {
        this.historyProgress = finalProgress;
        this.appScreen = finalProgress >= 1 ? AppScreen.History : AppScreen.Chat;
      },
    }, () => {
      this.historyProgress = finalProgress;
    });
  }

  private setCodeTaskProgress(target: number): void {
    const finalProgress = this.clampPageProgress(target);
    if (finalProgress > 0) {
      this.historyProgress = 0;
      this.appScreen = AppScreen.Chat;
    }
    this.getUIContext().animateTo({
      duration: 230,
      curve: Curve.EaseOut,
      onFinish: () => {
        this.codeTaskProgress = finalProgress;
      },
    }, () => {
      this.codeTaskProgress = finalProgress;
    });
  }

  private clampPageProgress(value: number): number {
    return Math.max(0, Math.min(1, value));
  }

  private chatPageTranslateX(): string {
    return `${(this.historyProgress - this.codeTaskProgress) * 100}%`;
  }

  private historyPageTranslateX(): string {
    return `${(this.historyProgress - 1) * 100}%`;
  }

  private codeTaskPageTranslateX(): string {
    return `${(1 - this.codeTaskProgress) * 100}%`;
  }

  private messageAgeLevel(messageIndex: number): number {
    const distanceFromLatest = this.messages.length - messageIndex - 1;
    if (this.characterExpanded) {
      if (distanceFromLatest >= 8) {
        return 3;
      }
      if (distanceFromLatest >= 5) {
        return 2;
      }
      if (distanceFromLatest >= 3) {
        return 1;
      }
      return 0;
    }
    if (distanceFromLatest >= 4) {
      return 3;
    }
    if (distanceFromLatest >= 3) {
      return 2;
    }
    if (distanceFromLatest >= 2) {
      return 1;
    }
    return 0;
  }

  private messageMetaColor(messageIndex: number): string {
    const level = this.messageAgeLevel(messageIndex);
    if (level >= 3) {
      return '#757575';
    }
    if (level === 2) {
      return '#5F5F5F';
    }
    return '#2E2E2E';
  }

  private messageTimeColor(messageIndex: number): string {
    const level = this.messageAgeLevel(messageIndex);
    if (level >= 3) {
      return '#9A9A9A';
    }
    if (level === 2) {
      return '#858585';
    }
    return '#747474';
  }

  private async copyMessageText(text: string): Promise<void> {
    if (text.trim().length === 0) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.showToast('已复制');
    } catch (error) {
      console.error(`[Amaduse] copy failed: ${errorToString(error)}`);
      this.showToast('复制失败');
    }
  }

  private async playMessageText(text: string, silent: boolean = false): Promise<void> {
    if (text.trim().length === 0) {
      return;
    }
    if (this.voiceSettings.ttsBackend === VoiceBackend.Off) {
      if (!silent) {
        this.showToast('云端语音已关闭');
      }
      return;
    }
    if (this.voiceBusy) {
      return;
    }
    this.playEmotion('joy');
    this.voiceBusy = true;
    if (!silent) {
      this.showToast('正在合成语音');
    }
    try {
      const result = await VoiceService.speak(
        this.abilityContext(),
        stripEmotionTagsForDisplay(text),
        this.selectedPersona,
        this.voiceSettings,
        this.modelSettings,
        (updated: VoiceSettings): Promise<void> => this.persistVoiceSettingsFromService(updated),
      );
      if (!result.ok) {
        this.showToast(result.error);
      } else if (!silent) {
        this.showToast('正在播放');
      }
    } catch (error) {
      console.error(`[Amaduse] voice playback failed: ${errorToString(error)}`);
      this.showToast(`语音失败：${errorToString(error).substring(0, 48)}`);
    } finally {
      this.voiceBusy = false;
    }
  }

  private async persistVoiceSettingsFromService(settings: VoiceSettings): Promise<void> {
    const next: VoiceSettings = {
      ttsBackend: settings.ttsBackend,
      siliconFlowApiKey: settings.siliconFlowApiKey,
      referenceAudioSource: settings.referenceAudioSource,
      clonedVoiceUri: settings.clonedVoiceUri,
      clonedVoiceReferenceKey: settings.clonedVoiceReferenceKey,
      autoPlay: settings.autoPlay,
      syncTextOutput: settings.syncTextOutput,
      speed: settings.speed,
      gain: settings.gain,
    };
    this.voiceSettings = next;
    await ChatPersistence.saveVoiceSettings(this.abilityContext(), next);
  }

  private showToast(message: string): void {
    try {
      const options: promptAction.ShowToastOptions = {
        message,
        duration: 1400,
      };
      this.getUIContext().getPromptAction().showToast(options);
    } catch (error) {
      console.error(`[Amaduse] toast failed: ${errorToString(error)}`);
    }
  }

  private async saveChatRecordsSafely(records: ChatRecord[]): Promise<void> {
    try {
      await ChatPersistence.saveChatRecords(this.abilityContext(), records);
    } catch (error) {
      console.error(`[Amaduse] save chat records failed: ${errorToString(error)}`);
    }
  }

  private async saveCurrentMessagesSafely(): Promise<void> {
    try {
      await ChatPersistence.saveChatMessages(this.abilityContext(), this.selectedRecord.id, this.messages);
    } catch (error) {
      console.error(`[Amaduse] save chat messages failed: ${errorToString(error)}`);
    }
  }

  private async sendMessage(): Promise<void> {
    if (!this.canSend()) {
      return;
    }
    const outgoingText = this.draft.trim().length > 0 ? this.draft.trim() : `发送了 ${this.attachments.length} 个附件`;
    const userMessage: ChatMessage = {
      id: createId('msg'),
      author: '你',
      text: outgoingText,
      isAgent: false,
      time: currentTimeText(),
      attachments: this.attachments.slice(),
      thinking: '',
      showThinking: false,
      thinkingExpanded: false,
      streaming: false,
      activeToolName: '',
      mode: this.selectedMode,
    };
    const assistantMessage: ChatMessage = {
      id: createId('msg'),
      author: this.selectedPersona.name,
      text: '',
      isAgent: true,
      time: currentTimeText(),
      attachments: [],
      thinking: '',
      showThinking: false,
      thinkingExpanded: false,
      streaming: true,
      activeToolName: '',
      mode: this.selectedMode,
    };
    const assistantIndex = this.messages.length + 1;
    const nextMessages = this.messages.slice();
    nextMessages.push(userMessage);
    nextMessages.push(assistantMessage);
    const nextRecords = updateRecordPreview(this.records, this.selectedRecord, outgoingText);
    const nextSelected = nextRecords.find((record: ChatRecord) => record.id === this.selectedRecord.id) ?? this.selectedRecord;
    this.messages = nextMessages;
    this.records = nextRecords;
    this.selectedRecord = nextSelected;
    this.draft = '';
    this.attachments = [];
    this.recording = false;
    this.toolsVisible = false;
    this.resetTranscriptPanel();
    this.sending = true;
    this.responseToken += 1;
    const token = this.responseToken;
    await this.saveChatRecordsSafely(nextRecords);
    await this.saveCurrentMessagesSafely();
    this.scrollTranscriptToBottom(true);

    let receivedStreamDelta = false;
    let streamedRawText = '';
    const syncVoiceText = this.shouldSyncVoiceText();

    try {
      const history = this.messages.slice(0, assistantIndex);
      const reply = await ChatService.streamAssistantMessage(
        history,
        outgoingText,
        this.selectedPersona,
        this.selectedMode,
        this.modelSettings,
        (delta: string): void => {
          if (token !== this.responseToken) {
            return;
          }
          receivedStreamDelta = true;
          this.appendAssistantThinkingDelta(assistantIndex, delta);
        },
        (delta: string): void => {
          if (token !== this.responseToken) {
            return;
          }
          receivedStreamDelta = true;
          streamedRawText += delta;
          if (!syncVoiceText) {
            this.updateAssistantTextFromRaw(assistantIndex, streamedRawText);
          }
        },
        {
          onToolCallStart: (call: AgentToolCall): void => {
            if (token !== this.responseToken) {
              return;
            }
            this.showToolCallStart(assistantIndex, call);
          },
          onToolCallFinish: (result: AgentToolResult): void => {
            if (token !== this.responseToken) {
              return;
            }
            this.showToolCallFinish(assistantIndex, result);
          },
          executeTool: async (call: AgentToolCall): Promise<AgentToolResult> => {
            return LocalToolService.execute(this.abilityContext(), call);
          },
        },
      );
      if (token !== this.responseToken) {
        return;
      }
      if (receivedStreamDelta) {
        const rawText = streamedRawText.length > 0 ? streamedRawText : reply.text;
        if (reply.error.length > 0 && rawText.trim().length === 0) {
          await this.showAssistantFailure(assistantIndex, reply.error);
          return;
        }
        await this.finishStreamingAssistant(assistantIndex, rawText, token, syncVoiceText);
        return;
      }
      const rawText = reply.error.length > 0 ? `请求失败：${reply.error}` : reply.text;
      await this.streamAssistantText(assistantIndex, rawText, reply.thinking, token, syncVoiceText);
    } catch (error) {
      if (token !== this.responseToken) {
        return;
      }
      await this.showAssistantFailure(assistantIndex, errorToString(error));
    }
  }

  private appendAssistantThinkingDelta(index: number, delta: string): void {
    if (delta.length === 0) {
      return;
    }
    this.updateMessage(index, (message: ChatMessage): ChatMessage => {
      return {
        id: message.id,
        author: message.author,
        text: message.text,
        isAgent: message.isAgent,
        time: message.time,
        attachments: message.attachments,
        toolPreview: message.toolPreview,
        thinking: message.thinking + delta,
        showThinking: true,
        thinkingExpanded: message.text.length === 0,
        streaming: message.streaming,
        activeToolName: message.activeToolName,
        mode: message.mode,
      };
    });
    this.scrollTranscriptToBottom();
  }

  private showToolCallStart(index: number, call: AgentToolCall): void {
    const thinking = `\n\n[工具调用]\n开始：${call.displayName}\n参数：${call.displayDetail}`;
    this.updateMessage(index, (message: ChatMessage): ChatMessage => {
      return {
        id: message.id,
        author: message.author,
        text: message.text,
        isAgent: message.isAgent,
        time: message.time,
        attachments: message.attachments,
        toolPreview: {
          title: `调用 ${call.displayName}`,
          detail: call.displayDetail,
          risk: '执行中',
        },
        thinking: appendThinkingEntry(message.thinking, thinking),
        showThinking: true,
        thinkingExpanded: message.text.length === 0,
        streaming: true,
        activeToolName: call.displayName,
        mode: message.mode,
      };
    });
    this.scrollTranscriptToBottom();
  }

  private showToolCallFinish(index: number, result: AgentToolResult): void {
    const thinking = `完成：${result.displayName}\n结果：${toolResultThinkingContent(result)}`;
    this.updateMessage(index, (message: ChatMessage): ChatMessage => {
      return {
        id: message.id,
        author: message.author,
        text: message.text,
        isAgent: message.isAgent,
        time: message.time,
        attachments: message.attachments,
        toolPreview: {
          title: result.ok ? `已调用 ${result.displayName}` : `调用失败 ${result.displayName}`,
          detail: toolPreviewDetailForResult(result),
          risk: result.ok ? '已完成' : '失败',
        },
        thinking: appendThinkingEntry(message.thinking, thinking),
        showThinking: true,
        thinkingExpanded: false,
        streaming: message.streaming,
        activeToolName: '',
        mode: message.mode,
      };
    });
    this.scrollTranscriptToBottom();
  }

  private updateAssistantTextFromRaw(index: number, rawText: string): void {
    const displayText = stripEmotionTagsForDisplay(rawText).trimStart();
    this.updateMessage(index, (message: ChatMessage): ChatMessage => {
      return {
        id: message.id,
        author: message.author,
        text: displayText,
        isAgent: message.isAgent,
        time: message.time,
        attachments: message.attachments,
        toolPreview: message.toolPreview,
        thinking: message.thinking,
        showThinking: message.showThinking,
        thinkingExpanded: false,
        streaming: message.streaming,
        activeToolName: '',
        mode: message.mode,
      };
    });
    this.scrollTranscriptToBottom();
  }

  private async finishStreamingAssistant(index: number, rawText: string, token: number, syncVoiceText: boolean = false): Promise<void> {
    if (token !== this.responseToken) {
      return;
    }
    const emotion = extractEmotion(rawText);
    if (emotion.length > 0) {
      this.playEmotion(emotion);
    }
    const displayText = stripEmotionTagsForDisplay(rawText).trimStart();
    const finalText = displayText.trim().length > 0 ? displayText : '模型没有返回正文。';
    if (syncVoiceText) {
      await this.startSyncedVoiceCaptionOutput(index, finalText, token);
      return;
    }
    this.updateMessage(index, (message: ChatMessage): ChatMessage => {
      return {
        id: message.id,
        author: message.author,
        text: finalText,
        isAgent: message.isAgent,
        time: message.time,
        attachments: message.attachments,
        toolPreview: message.toolPreview,
        thinking: message.thinking,
        showThinking: message.thinking.length > 0,
        thinkingExpanded: false,
        streaming: false,
        activeToolName: '',
        mode: message.mode,
      };
    });
    this.sending = false;
    this.scrollTranscriptToBottom();
    await this.saveCurrentMessagesSafely();
    this.autoPlayAssistant(finalText);
  }

  private async streamAssistantText(index: number, rawText: string, thinking: string, token: number, syncVoiceText: boolean = false): Promise<void> {
    const emotion = extractEmotion(rawText);
    if (emotion.length > 0) {
      this.playEmotion(emotion);
    }
    const displayText = stripEmotionTagsForDisplay(rawText).trimStart();
    const visibleText = displayText.trim().length > 0 ? displayText : '模型没有返回正文。';
    if (thinking.length > 0) {
      this.updateMessage(index, (message: ChatMessage): ChatMessage => {
        return {
          id: message.id,
          author: message.author,
          text: message.text,
          isAgent: message.isAgent,
          time: message.time,
          attachments: message.attachments,
          toolPreview: message.toolPreview,
          thinking,
          showThinking: true,
          thinkingExpanded: true,
          streaming: message.streaming,
          activeToolName: message.activeToolName,
          mode: message.mode,
        };
      });
    }
    if (syncVoiceText) {
      await this.startSyncedVoiceCaptionOutput(index, visibleText, token);
      return;
    }
    const chunks = splitForStreaming(visibleText);
    for (let chunkIndex = 0; chunkIndex < chunks.length; chunkIndex += 1) {
      if (token !== this.responseToken) {
        return;
      }
      const chunk = chunks[chunkIndex];
      this.updateMessage(index, (message: ChatMessage): ChatMessage => {
        return {
          id: message.id,
          author: message.author,
          text: message.text + chunk,
          isAgent: message.isAgent,
          time: message.time,
          attachments: message.attachments,
          toolPreview: message.toolPreview,
          thinking: message.thinking,
          showThinking: message.showThinking,
          thinkingExpanded: message.thinking.length > 0 ? false : message.thinkingExpanded,
          streaming: message.streaming,
          activeToolName: '',
          mode: message.mode,
        };
      });
      this.scrollTranscriptToBottom();
      await sleep(18);
    }
    this.updateMessage(index, (message: ChatMessage): ChatMessage => {
      return {
        id: message.id,
        author: message.author,
        text: message.text,
        isAgent: message.isAgent,
        time: message.time,
        attachments: message.attachments,
        toolPreview: message.toolPreview,
        thinking: message.thinking,
        streaming: false,
        activeToolName: '',
        thinkingExpanded: false,
        showThinking: message.thinking.length > 0,
        mode: message.mode,
      };
    });
    this.sending = false;
    await this.saveCurrentMessagesSafely();
    this.autoPlayAssistant(visibleText);
  }

  private shouldSyncVoiceText(): boolean {
    return this.voiceSettings.autoPlay &&
      this.voiceSettings.syncTextOutput &&
      this.voiceSettings.ttsBackend !== VoiceBackend.Off &&
      this.voiceSettings.siliconFlowApiKey.trim().length > 0 &&
      !this.voiceBusy;
  }

  private async startSyncedVoiceCaptionOutput(index: number, finalText: string, token: number): Promise<void> {
    if (token !== this.responseToken) {
      return;
    }
    if (this.voiceBusy) {
      this.setSyncedAssistantFinalText(index, finalText);
      this.sending = false;
      await this.saveCurrentMessagesSafely();
      return;
    }
    this.updateMessage(index, (message: ChatMessage): ChatMessage => {
      return {
        id: message.id,
        author: message.author,
        text: '',
        isAgent: message.isAgent,
        time: message.time,
        attachments: message.attachments,
        toolPreview: message.toolPreview,
        thinking: message.thinking,
        showThinking: message.thinking.length > 0,
        thinkingExpanded: false,
        streaming: true,
        activeToolName: '',
        mode: message.mode,
      };
    });
    this.scrollTranscriptToBottom();
    this.voiceBusy = true;
    try {
      const callbacks: VoicePlaybackCallbacks = {
        onSegmentPlaybackStart: async (segmentIndex: number, text: string, durationMs: number): Promise<void> => {
          await this.streamSyncedCaptionSegment(index, text, durationMs, token);
        },
      };
      const result = await VoiceService.speak(
        this.abilityContext(),
        finalText,
        this.selectedPersona,
        this.voiceSettings,
        this.modelSettings,
        (updated: VoiceSettings): Promise<void> => this.persistVoiceSettingsFromService(updated),
        callbacks,
      );
      if (token !== this.responseToken) {
        return;
      }
      if (!result.ok) {
        this.showToast(result.error);
      }
    } catch (error) {
      if (token === this.responseToken) {
        console.error(`[Amaduse] synced voice failed: ${errorToString(error)}`);
        this.showToast(`语音失败：${errorToString(error).substring(0, 48)}`);
      }
    } finally {
      this.voiceBusy = false;
      if (token === this.responseToken) {
        this.setSyncedAssistantFinalText(index, finalText);
        this.sending = false;
        await this.saveCurrentMessagesSafely();
      }
    }
  }

  private async streamSyncedCaptionSegment(index: number, text: string, durationMs: number, token: number): Promise<void> {
    const chunks = this.captionChunks(text);
    if (chunks.length === 0) {
      return;
    }
    const frameDelay = this.captionFrameDelayMs(text, durationMs, chunks.length);
    for (let chunkIndex = 0; chunkIndex < chunks.length; chunkIndex += 1) {
      if (token !== this.responseToken) {
        return;
      }
      const chunk = chunks[chunkIndex];
      this.updateMessage(index, (message: ChatMessage): ChatMessage => {
        return {
          id: message.id,
          author: message.author,
          text: message.text + chunk,
          isAgent: message.isAgent,
          time: message.time,
          attachments: message.attachments,
          toolPreview: message.toolPreview,
          thinking: message.thinking,
          showThinking: message.showThinking,
          thinkingExpanded: false,
          streaming: true,
          activeToolName: '',
          mode: message.mode,
        };
      });
      this.scrollTranscriptToBottom();
      await sleep(frameDelay);
    }
  }

  private setSyncedAssistantFinalText(index: number, finalText: string): void {
    this.updateMessage(index, (message: ChatMessage): ChatMessage => {
      return {
        id: message.id,
        author: message.author,
        text: finalText,
        isAgent: message.isAgent,
        time: message.time,
        attachments: message.attachments,
        toolPreview: message.toolPreview,
        thinking: message.thinking,
        showThinking: message.thinking.length > 0,
        thinkingExpanded: false,
        streaming: false,
        activeToolName: '',
        mode: message.mode,
      };
    });
    this.scrollTranscriptToBottom();
  }

  private captionChunks(text: string): string[] {
    const chunks: string[] = [];
    for (let index = 0; index < text.length; index += 1) {
      chunks.push(text.charAt(index));
    }
    return chunks;
  }

  private captionFrameDelayMs(text: string, durationMs: number, chunkCount: number): number {
    const estimated = Math.max(900, text.length * 180 + 500);
    const baseDuration = durationMs > 500 ? durationMs : estimated;
    return Math.min(260, Math.max(24, Math.floor((baseDuration * 0.92) / Math.max(1, chunkCount))));
  }

  private autoPlayAssistant(text: string): void {
    if (!this.voiceSettings.autoPlay || this.voiceSettings.ttsBackend === VoiceBackend.Off || text.trim().length === 0) {
      return;
    }
    this.playMessageText(text, true);
  }

  private async showAssistantFailure(index: number, detail: string): Promise<void> {
    this.updateMessage(index, (message: ChatMessage): ChatMessage => {
      return {
        id: message.id,
        author: message.author,
        text: `请求失败：${detail}`,
        isAgent: message.isAgent,
        time: message.time,
        attachments: message.attachments,
        toolPreview: message.toolPreview,
        thinking: message.thinking,
        showThinking: message.thinking.length > 0,
        thinkingExpanded: false,
        streaming: false,
        activeToolName: '',
        mode: message.mode,
      };
    });
    this.sending = false;
    this.scrollTranscriptToBottom();
    await this.saveCurrentMessagesSafely();
  }

  private stopResponse(): void {
    this.responseToken += 1;
    const streamingIndex = this.messages.findIndex((message: ChatMessage) => message.streaming);
    if (streamingIndex >= 0) {
      this.updateMessage(streamingIndex, (message: ChatMessage): ChatMessage => {
        return {
          id: message.id,
          author: message.author,
          text: message.text.length > 0 ? message.text : '已中断。',
          isAgent: message.isAgent,
          time: message.time,
          attachments: message.attachments,
          toolPreview: message.toolPreview,
          thinking: message.thinking,
          streaming: false,
          activeToolName: '',
          thinkingExpanded: false,
          showThinking: message.thinking.length > 0,
          mode: message.mode,
        };
      });
      ChatPersistence.saveChatMessages(this.abilityContext(), this.selectedRecord.id, this.messages);
    }
    this.sending = false;
  }

  private updateMessage(index: number, transform: (message: ChatMessage) => ChatMessage): void {
    if (index < 0 || index >= this.messages.length) {
      return;
    }
    const next = this.messages.slice();
    next[index] = transform(next[index]);
    this.messages = next;
  }

  private messageRenderKey(message: ChatMessage): string {
    const streaming = message.streaming ? '1' : '0';
    const thinkingVisible = message.showThinking ? '1' : '0';
    const thinkingExpanded = message.thinkingExpanded ? '1' : '0';
    const toolPreviewLength = message.toolPreview !== undefined
      ? message.toolPreview.title.length + message.toolPreview.detail.length + message.toolPreview.risk.length
      : 0;
    return `${message.id}-${message.text.length}-${message.thinking.length}-${streaming}-${thinkingVisible}-${thinkingExpanded}-${message.activeToolName.length}-${toolPreviewLength}`;
  }

  private toggleThinking(index: number): void {
    this.updateMessage(index, (message: ChatMessage): ChatMessage => {
      return {
        id: message.id,
        author: message.author,
        text: message.text,
        isAgent: message.isAgent,
        time: message.time,
        attachments: message.attachments,
        toolPreview: message.toolPreview,
        thinking: message.thinking,
        showThinking: message.showThinking,
        thinkingExpanded: !message.thinkingExpanded,
        streaming: message.streaming,
        activeToolName: message.activeToolName,
        mode: message.mode,
      };
    });
    ChatPersistence.saveChatMessages(this.abilityContext(), this.selectedRecord.id, this.messages);
  }

  private openHistoryFiles(): void {
    this.historyFilesVisible = true;
    this.historyFilePreviewVisible = false;
    this.loadHistoryFiles();
  }

  private closeHistoryFiles(): void {
    this.historyFilesVisible = false;
    this.historyFilePreviewVisible = false;
  }

  private async importHistoryFileFromPicker(): Promise<void> {
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const documentPicker = new picker.DocumentViewPicker(this.abilityContext());
      const uris = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const fileName = this.safeTransferFileName(this.fileNameFromUri(uri));
      const dir = this.historyFilesDir();
      if (!this.fileExists(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const target = this.uniqueUploadCachePath(dir, fileName);
      fileIo.copyFileSync(uri, target);
      this.loadHistoryFiles();
      this.showToast(`已导入 ${fileName}`);
    } catch (error) {
      console.error(`[Amaduse] import history file failed: ${errorToString(error)}`);
      this.showToast(`导入失败：${errorToString(error).substring(0, 80)}`);
    }
  }

  private loadHistoryFiles(): void {
    const dir = this.historyFilesDir();
    try {
      if (!this.fileExists(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const names = fileIo.listFileSync(dir);
      const files: LocalHistoryFile[] = [];
      names.forEach((name: string) => {
        const path = `${dir}/${name}`;
        try {
          const info = fileIo.statSync(path);
          if (info.isDirectory()) {
            return;
          }
          const extension = this.historyFileExtension(name);
          const kind = this.historyFileKind(extension);
          files.push({
            id: path,
            name,
            path,
            sizeBytes: info.size,
            modifiedEpoch: info.mtime,
            modifiedAt: this.formatFileTime(info.mtime),
            extension,
            kind,
            previewable: this.historyFilePreviewable(kind),
          });
        } catch (error) {
          console.warn(`[Amaduse] skip history file ${path}: ${errorToString(error)}`);
        }
      });
      files.sort((left: LocalHistoryFile, right: LocalHistoryFile) => right.modifiedEpoch - left.modifiedEpoch);
      this.historyFiles = files;
      this.historyFilesMessage = `${files.length} 个文件 · ${dir}`;
    } catch (error) {
      this.historyFiles = [];
      this.historyFilesMessage = `读取失败：${errorToString(error)}`;
    }
  }

  private openHistoryFilePreview(file: LocalHistoryFile): void {
    this.historyFilePreviewTitle = file.name;
    this.historyFilePreviewMeta = `${this.formatBytes(file.sizeBytes)} · ${file.kind} · ${file.modifiedAt}`;
    this.historyFilePreviewPath = file.path;
    this.historyFilePreviewKind = file.kind;
    this.historyFilePreviewMarkdown = file.kind === 'markdown';
    try {
      if (file.kind === 'image') {
        this.historyFilePreviewText = '';
      } else if (file.kind === 'text' || file.kind === 'markdown') {
        this.historyFilePreviewText = this.readHistoryFileText(file.path, file.sizeBytes);
      } else {
        this.historyFilePreviewText = this.readHistoryFileBinarySummary(file);
      }
    } catch (error) {
      this.historyFilePreviewMarkdown = false;
      this.historyFilePreviewText = `读取失败：${errorToString(error)}\n\n路径：${file.path}`;
    }
    this.historyFilePreviewVisible = true;
  }

  private copyHistoryFilePath(): void {
    this.copyMessageText(this.historyFilePreviewPath);
  }

  private historyFilesDir(): string {
    return `${this.abilityContext().filesDir}/${HOST_HISTORY_FILE_DIR}`;
  }

  private readHistoryFileText(path: string, sizeBytes: number): string {
    if (sizeBytes <= 0) {
      return '';
    }
    const readSize = Math.min(sizeBytes, HISTORY_FILE_TEXT_PREVIEW_BYTES);
    const data = this.readHistoryFileBytes(path, readSize);
    const decoder = util.TextDecoder.create('utf-8');
    let text = decoder.decodeToString(new Uint8Array(data));
    if (sizeBytes > HISTORY_FILE_TEXT_PREVIEW_BYTES) {
      text = `${text}\n\n... 已截断预览，完整文件大小 ${this.formatBytes(sizeBytes)}。`;
    }
    return text;
  }

  private readHistoryFileBinarySummary(file: LocalHistoryFile): string {
    const readSize = Math.min(file.sizeBytes, HISTORY_FILE_BINARY_PREVIEW_BYTES);
    const data = readSize > 0 ? this.readHistoryFileBytes(file.path, readSize) : new ArrayBuffer(0);
    const bytes = new Uint8Array(data);
    let hex = '';
    for (let i = 0; i < bytes.length; i += 1) {
      hex = `${hex}${i > 0 ? ' ' : ''}${this.hexByte(bytes[i])}`;
    }
    const kindHint = this.historyFileBinaryHint(file.kind);
    return `${kindHint}\n\n名称：${file.name}\n大小：${this.formatBytes(file.sizeBytes)}\n修改时间：${file.modifiedAt}\n路径：${file.path}\n\n头部字节：${hex.length > 0 ? hex : '空文件'}`;
  }

  private readHistoryFileBytes(path: string, readSize: number): ArrayBuffer {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const data = new ArrayBuffer(readSize);
      const readBytes = fileIo.readSync(file.fd, data);
      if (readBytes === data.byteLength) {
        return data;
      }
      return data.slice(0, readBytes);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private historyFileExtension(fileName: string): string {
    const dotIndex = fileName.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex >= fileName.length - 1) {
      return '';
    }
    return fileName.substring(dotIndex + 1).toLowerCase();
  }

  private historyFileKind(extension: string): string {
    if (extension === 'md' || extension === 'markdown') {
      return 'markdown';
    }
    if (this.valueIn(extension, ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'])) {
      return 'image';
    }
    if (this.valueIn(extension, [
      'txt', 'log', 'json', 'csv', 'tsv', 'xml', 'html', 'htm', 'css', 'js', 'ts', 'tsx', 'ets',
      'py', 'java', 'kt', 'c', 'cpp', 'h', 'hpp', 'cs', 'go', 'rs', 'swift', 'sql', 'yaml', 'yml',
      'toml', 'ini', 'env',
    ])) {
      return 'text';
    }
    if (this.valueIn(extension, ['doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'pdf'])) {
      return 'document';
    }
    if (this.valueIn(extension, ['zip', 'rar', '7z', 'tar', 'gz'])) {
      return 'archive';
    }
    if (this.valueIn(extension, ['mp3', 'wav', 'ogg', 'm4a', 'aac'])) {
      return 'audio';
    }
    if (this.valueIn(extension, ['mp4', 'mov', 'mkv', 'avi', 'webm'])) {
      return 'video';
    }
    return 'binary';
  }

  private historyFilePreviewable(kind: string): boolean {
    return kind === 'text' || kind === 'markdown' || kind === 'image';
  }

  private historyFileKindIcon(kind: string): string {
    if (kind === 'markdown') {
      return 'M';
    }
    if (kind === 'text') {
      return 'T';
    }
    if (kind === 'image') {
      return 'I';
    }
    if (kind === 'document') {
      return 'D';
    }
    if (kind === 'archive') {
      return 'Z';
    }
    if (kind === 'audio') {
      return 'A';
    }
    if (kind === 'video') {
      return 'V';
    }
    return 'B';
  }

  private historyFileKindColor(kind: string): string {
    if (kind === 'markdown') {
      return '#4D8CFF';
    }
    if (kind === 'text') {
      return '#35A06F';
    }
    if (kind === 'image') {
      return '#A15CC8';
    }
    if (kind === 'document') {
      return '#B59A62';
    }
    if (kind === 'archive') {
      return '#7B7B7B';
    }
    return INK_BLACK;
  }

  private historyFileBinaryHint(kind: string): string {
    if (kind === 'document') {
      return '该文件是文档类二进制格式。当前内置浏览器显示文件信息和头部字节，完整内容请从系统文件或主机端打开。';
    }
    if (kind === 'archive') {
      return '该文件是压缩包。当前内置浏览器显示文件信息和头部字节。';
    }
    if (kind === 'audio' || kind === 'video') {
      return '该文件是媒体格式。当前内置浏览器显示文件信息和头部字节。';
    }
    return '该文件不是可直接解码的文本格式，当前显示文件信息和头部字节。';
  }

  private valueIn(value: string, items: string[]): boolean {
    return items.indexOf(value) >= 0;
  }

  private formatFileTime(epochSeconds: number): string {
    if (epochSeconds <= 0) {
      return '未知时间';
    }
    const date = new Date(epochSeconds * 1000);
    return `${date.getFullYear()}-${this.pad2(date.getMonth() + 1)}-${this.pad2(date.getDate())} ${this.pad2(date.getHours())}:${this.pad2(date.getMinutes())}`;
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    }
    return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
  }

  private pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  private async pickAndUploadFileAttachment(): Promise<void> {
    if (!this.hostAgentSettings.enabled || this.hostAgentSettings.baseUrl.trim().length === 0) {
      this.showToast('先在设置里启用主机后端 Agent');
      return;
    }
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    const documentPicker = new picker.DocumentViewPicker(this.abilityContext());
    const uris = await documentPicker.select(options);
    if (uris.length === 0) {
      return;
    }
    const uri = uris[0];
    const fileName = this.safeTransferFileName(this.fileNameFromUri(uri));
    const uploadPath = this.prepareUploadFileForHost(uri, fileName);
    const contentType = this.mimeTypeForFileName(fileName);
    const uploadData = this.readUploadFileData(uploadPath);
    this.showToast('正在上传文件');
    const hostFile = await this.uploadFileToHost(uploadData, fileName, contentType);
    const hostPath = stringValue(hostFile.path);
    if (hostPath.length === 0) {
      throw new Error('主机后端未返回文件路径');
    }
    const nextAttachment: ComposerAttachment = {
      id: createId('att'),
      label: stringValue(hostFile.filename, fileName),
      kind: AttachmentKind.File,
      uri,
      hostPath,
      contentType: stringValue(hostFile.contentType, contentType),
      sizeBytes: hostFile.sizeBytes === undefined ? 0 : hostFile.sizeBytes,
      uploaded: true,
    };
    const nextAttachments = this.attachments.slice();
    nextAttachments.push(nextAttachment);
    this.attachments = nextAttachments;
    this.showToast(`已上传 ${nextAttachment.label}`);
  }

  private async uploadFileToHost(fileData: ArrayBuffer, fileName: string, contentType: string): Promise<UploadHostFilePreview> {
    const request = http.createHttp();
    try {
      const headers: UploadHttpHeaderMap = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      if (this.hostAgentSettings.apiKey.trim().length > 0) {
        headers.Authorization = `Bearer ${this.hostAgentSettings.apiKey.trim()}`;
      }
      const payload: UploadFileBase64Payload = {
        filename: fileName,
        contentType,
        dataBase64: buffer.from(fileData).toString('base64'),
        device: 'mobile',
        overwrite: true,
      };
      const response = await request.request(this.hostUploadEndpoint(), {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(payload),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HOST_TRANSFER_CONNECT_TIMEOUT_MS,
        readTimeout: HOST_TRANSFER_READ_TIMEOUT_MS,
        maxLimit: HOST_UPLOAD_MAX_BYTES,
      });
      const body = this.httpResponseToText(response.result);
      if (response.responseCode < 200 || response.responseCode > 299) {
        throw new Error(`HTTP ${response.responseCode} ${body.substring(0, 180)}`);
      }
      const parsed = JSON.parse(body) as UploadHostResponsePreview;
      const file = parsed.file ?? parsed.data?.file;
      if (file === undefined) {
        throw new Error(stringValue(parsed.summary, '上传响应缺少 file 字段'));
      }
      return file;
    } finally {
      request.destroy();
    }
  }

  private readUploadFileData(path: string): ArrayBuffer {
    const info = fileIo.statSync(path);
    if (info.size <= 0) {
      return new ArrayBuffer(0);
    }
    if (info.size > HOST_UPLOAD_MAX_BYTES) {
      throw new Error(`文件超过 ${HOST_UPLOAD_MAX_BYTES} bytes`);
    }
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const data = new ArrayBuffer(info.size);
      const readBytes = fileIo.readSync(file.fd, data);
      if (readBytes === data.byteLength) {
        return data;
      }
      return data.slice(0, readBytes);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private prepareUploadFileForHost(uri: string, fileName: string): string {
    const dir = `${this.abilityContext().cacheDir}/${HOST_UPLOAD_CACHE_DIR}`;
    try {
      if (!this.fileExists(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const target = this.uniqueUploadCachePath(dir, fileName);
      fileIo.copyFileSync(uri, target);
      return target;
    } catch (error) {
      console.warn(`[Amaduse] copy picked file failed, upload URI directly: ${errorToString(error)}`);
      return uri;
    }
  }

  private hostUploadEndpoint(): string {
    return `${this.trimEnd(this.hostAgentSettings.baseUrl.trim(), '/')}/api/files/upload-base64`;
  }

  private fileNameFromUri(uri: string): string {
    let cleaned = uri;
    const queryIndex = cleaned.indexOf('?');
    if (queryIndex >= 0) {
      cleaned = cleaned.substring(0, queryIndex);
    }
    const hashIndex = cleaned.indexOf('#');
    if (hashIndex >= 0) {
      cleaned = cleaned.substring(0, hashIndex);
    }
    try {
      cleaned = decodeURIComponent(cleaned);
    } catch (_) {
    }
    cleaned = cleaned.replace(/\\/g, '/');
    const index = cleaned.lastIndexOf('/');
    const name = index >= 0 ? cleaned.substring(index + 1) : cleaned;
    if (name.trim().length === 0 || name.indexOf(':') >= 0) {
      return `mobile_upload_${Date.now()}.txt`;
    }
    return name;
  }

  private safeTransferFileName(value: string): string {
    let output = value.trim().replace(/[<>:"/\\|?*\x00-\x1f]/g, '_');
    while (output.endsWith('.') || output.endsWith(' ')) {
      output = output.substring(0, output.length - 1);
    }
    if (output.length === 0 || output === '.' || output === '..') {
      return `mobile_upload_${Date.now()}.txt`;
    }
    return output;
  }

  private uniqueUploadCachePath(dir: string, fileName: string): string {
    const dotIndex = fileName.lastIndexOf('.');
    const stem = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
    const suffix = dotIndex > 0 ? fileName.substring(dotIndex) : '';
    let candidate = `${dir}/${fileName}`;
    let index = 1;
    while (this.fileExists(candidate)) {
      candidate = `${dir}/${stem}_${index}${suffix}`;
      index += 1;
    }
    return candidate;
  }

  private mimeTypeForFileName(fileName: string): string {
    const lower = fileName.toLowerCase();
    if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
      return 'text/markdown';
    }
    if (lower.endsWith('.txt') || lower.endsWith('.log')) {
      return 'text/plain';
    }
    if (lower.endsWith('.json')) {
      return 'application/json';
    }
    if (lower.endsWith('.csv')) {
      return 'text/csv';
    }
    if (lower.endsWith('.pdf')) {
      return 'application/pdf';
    }
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    return 'text/plain';
  }

  private httpResponseToText(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') {
      return result;
    }
    if (result instanceof ArrayBuffer) {
      try {
        const decoder = util.TextDecoder.create('utf-8');
        return decoder.decodeToString(new Uint8Array(result));
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

  private fileExists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (_) {
      return false;
    }
  }

  private trimEnd(value: string, char: string): string {
    let output = value;
    while (output.endsWith(char)) {
      output = output.substring(0, output.length - char.length);
    }
    return output;
  }

  private handleToolShortcut(shortcut: ToolShortcut): void {
    if (shortcut.title === '图片') {
      const nextAttachment: ComposerAttachment = {
        id: createId('att'),
        label: `图片 ${this.attachments.filter((item: ComposerAttachment) => item.kind === AttachmentKind.Image).length + 1}`,
        kind: AttachmentKind.Image,
      };
      const nextAttachments = this.attachments.slice();
      nextAttachments.push(nextAttachment);
      this.attachments = nextAttachments;
      return;
    }
    if (shortcut.title === '文件') {
      this.pickAndUploadFileAttachment().catch((error: Error | Object | string) => {
        this.showToast(`上传失败：${errorToString(error).substring(0, 48)}`);
      });
      return;
    }
    switch (shortcut.title) {
      case '相机':
        this.draft = '帮我看一下摄像头里的内容';
        break;
      case '闹钟':
        this.draft = '帮我设置一个闹钟';
        break;
      case '备忘':
        this.draft = '帮我创建一个日历任务';
        break;
      case '电脑':
        this.draft = '帮我把这个任务发送到电脑';
        break;
      default:
        break;
    }
    this.toolsVisible = false;
  }

  private async selectRecord(record: ChatRecord): Promise<void> {
    this.selectedRecord = record;
    this.records = this.records.map((item: ChatRecord): ChatRecord => {
      return {
        id: item.id,
        title: item.title,
        subtitle: item.subtitle,
        active: item.id === record.id,
      };
    });
    this.messages = await ChatPersistence.loadChatMessages(this.abilityContext(), record.id);
    this.closeHistoryScreen();
    this.scrollTranscriptToBottom(true);
  }

  private async createNewChat(): Promise<void> {
    const record = createNewChatRecord();
    const nextRecords: ChatRecord[] = [record];
    this.records.forEach((item: ChatRecord) => {
      nextRecords.push({
        id: item.id,
        title: item.title,
        subtitle: item.subtitle,
        active: false,
      });
    });
    this.records = nextRecords;
    this.selectedRecord = record;
    this.messages = [];
    this.draft = '';
    this.attachments = [];
    this.resetTranscriptPanel();
    this.closeHistoryScreen();
    this.newChatConfirmVisible = false;
    await ChatPersistence.saveChatRecords(this.abilityContext(), nextRecords);
    await ChatPersistence.saveChatMessages(this.abilityContext(), record.id, []);
  }

  private async deleteSelectedRecord(): Promise<void> {
    const nextRecords = this.records.filter((record: ChatRecord) => record.id !== this.deleteConfirmRecordId);
    if (nextRecords.length === 0) {
      nextRecords.push(createNewChatRecord());
    }
    this.records = nextRecords;
    if (this.selectedRecord.id === this.deleteConfirmRecordId) {
      this.selectedRecord = nextRecords[0];
      this.messages = await ChatPersistence.loadChatMessages(this.abilityContext(), this.selectedRecord.id);
    }
    this.deleteConfirmRecordId = '';
    await ChatPersistence.saveChatRecords(this.abilityContext(), nextRecords);
  }

  private playEmotion(emotion: string): void {
    try {
      this.live2dController.runJavaScript(`playEmotion('${emotion}')`);
    } catch (_) {
    }
  }

  private scrollTranscriptToBottom(force: boolean = false): void {
    if (this.transcriptDetachedFromBottom && !force) {
      return;
    }
    this.transcriptAutoScrolling = true;
    this.transcriptDetachedFromBottom = false;
    setTimeout(() => {
      try {
        this.transcriptScroller.scrollEdge(Edge.Bottom);
      } catch (_) {
      }
    }, 20);
    setTimeout(() => {
      this.transcriptAutoScrolling = false;
      this.transcriptDetachedFromBottom = !this.isTranscriptAtBottom();
    }, 260);
  }

  private updateCodeTaskBottomButton(): void {
    if (this.codeTaskAutoScrolling || this.codeTaskApplyingHostUpdate) {
      return;
    }
    this.codeTaskDetachedFromBottom = !this.isCodeTaskAtBottom();
  }

  private markCodeTaskAtBottom(): void {
    this.codeTaskDetachedFromBottom = false;
  }

  private isCodeTaskAtBottom(): boolean {
    try {
      return this.codeTaskScroller.isAtEnd();
    } catch (_) {
      return true;
    }
  }

  private shouldAutoFollowCodeTaskBottom(): boolean {
    return !this.codeTaskDetachedFromBottom;
  }

  private preserveCodeTaskScrollAfterUpdate(wasAtBottom: boolean, settle: boolean = false): void {
    if (wasAtBottom) {
      this.scrollCodeTaskToBottom(true, settle);
      return;
    }
    this.codeTaskDetachedFromBottom = true;
  }

  private returnCodeTaskToBottom(): void {
    this.scrollCodeTaskToBottom(true, true);
  }

  private clearCodeTaskScrollTimers(): void {
    if (this.codeTaskScrollTimer >= 0) {
      clearTimeout(this.codeTaskScrollTimer);
      this.codeTaskScrollTimer = -1;
    }
    if (this.codeTaskScrollSettleTimer >= 0) {
      clearTimeout(this.codeTaskScrollSettleTimer);
      this.codeTaskScrollSettleTimer = -1;
    }
    if (this.codeTaskHostUpdateTimer >= 0) {
      clearTimeout(this.codeTaskHostUpdateTimer);
      this.codeTaskHostUpdateTimer = -1;
    }
    this.codeTaskApplyingHostUpdate = false;
  }

  private beginCodeTaskHostUpdateWindow(): void {
    this.codeTaskApplyingHostUpdate = true;
    if (this.codeTaskHostUpdateTimer >= 0) {
      clearTimeout(this.codeTaskHostUpdateTimer);
    }
    this.codeTaskHostUpdateTimer = setTimeout(() => {
      this.codeTaskHostUpdateTimer = -1;
      this.codeTaskApplyingHostUpdate = false;
    }, 220);
  }

  private scrollCodeTaskToBottom(force: boolean = false, settle: boolean = false): void {
    if (this.codeTaskDetachedFromBottom && !force) {
      return;
    }
    this.clearCodeTaskScrollTimers();
    this.codeTaskAutoScrolling = true;
    this.codeTaskDetachedFromBottom = false;
    this.codeTaskScrollTimer = setTimeout(() => {
      this.codeTaskScrollTimer = -1;
      try {
        this.codeTaskScroller.scrollEdge(Edge.Bottom);
      } catch (_) {
      }
    }, 80);
    if (settle) {
      this.codeTaskScrollSettleTimer = setTimeout(() => {
        this.codeTaskScrollSettleTimer = -1;
        try {
          this.codeTaskScroller.scrollEdge(Edge.Bottom);
        } catch (_) {
        }
      }, 360);
    }
    setTimeout(() => {
      this.codeTaskAutoScrolling = false;
      this.codeTaskDetachedFromBottom = !this.isCodeTaskAtBottom();
    }, settle ? 620 : 320);
  }
}
