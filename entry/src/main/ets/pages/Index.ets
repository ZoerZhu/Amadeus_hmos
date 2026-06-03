import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
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

@Entry
@Component
struct Index {
  private live2dController: webview.WebviewController = new webview.WebviewController();
  private transcriptScroller: Scroller = new Scroller();
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
  @State private recording: boolean = false;
  @State private sending: boolean = false;
  @State private voiceBusy: boolean = false;
  @State private settingsVisible: boolean = false;
  @State private settingsSheetMode: SettingsSheetMode = SettingsSheetMode.Full;
  @State private modelMenuVisible: boolean = false;
  @State private newChatConfirmVisible: boolean = false;
  @State private deleteConfirmRecordId: string = '';

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

  aboutToAppear(): void {
    this.loadState();
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
              this.toolPreviewCard(message.toolPreview);
            }

            if (message.activeToolName.length > 0) {
              Text(`正在调用 ${message.activeToolName} ...`)
                .fontSize(14)
                .fontColor('#666666')
            }

            if (message.text.length > 0) {
              CyclingMessageText({
                text: message.text,
                ageLevel: this.messageAgeLevel(index),
                isUser: false,
              })
            } else if (message.streaming && !message.showThinking) {
              this.thinkingLine(`${message.author} thinking...`)
            }
          }
          .constraintSize({ maxWidth: 324 })
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
          .constraintSize({ maxWidth: 324 })
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
        .constraintSize({ maxWidth: 308 })
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
        .constraintSize({ maxWidth: 308 })
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
        Text(message.streaming && message.thinkingExpanded ? '思考中' : '思考过程')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#7A7A7A')
          .layoutWeight(1)
        Text(message.thinkingExpanded ? '收起' : '展开')
          .fontSize(11)
          .fontColor('#8A8A8A')
      }
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.toggleThinking(index))

      if (message.thinkingExpanded) {
        Scroll() {
          Text(message.thinking)
            .fontSize(13)
            .fontColor('#7C7C7C')
            .lineHeight(19)
            .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 190 })
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
  }

  @Builder
  private toolPreviewCard(preview: ToolPreview) {
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
  }

  @Builder
  private attachmentRow(attachments: ComposerAttachment[]) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(attachments, (attachment: ComposerAttachment) => {
        Text(`${attachment.kind === AttachmentKind.Image ? '图片' : '文件'} · ${attachment.label}`)
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
          Text(attachment.label)
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
            this.historyActionCard('⚡', 'Algorithm works', '已固定项目', () => {}, true);
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
  }

  private updatePagePan(event: GestureEvent): void {
    const nextProgress = this.pageDragStartProgress + event.offsetX / PAGE_SLIDE_WIDTH;
    this.historyProgress = this.clampPageProgress(nextProgress);
    if (this.historyProgress > 0) {
      this.appScreen = AppScreen.History;
    }
  }

  private finishPagePan(event: GestureEvent): void {
    const projected = this.pageDragStartProgress + event.offsetX / PAGE_SLIDE_WIDTH + event.velocityX / 2600;
    this.setHistoryProgress(projected >= 0.5 ? 1 : 0);
  }

  private setHistoryProgress(target: number): void {
    const finalProgress = this.clampPageProgress(target);
    if (finalProgress > 0) {
      this.appScreen = AppScreen.History;
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

  private clampPageProgress(value: number): number {
    return Math.max(0, Math.min(1, value));
  }

  private chatPageTranslateX(): string {
    return `${this.historyProgress * 100}%`;
  }

  private historyPageTranslateX(): string {
    return `${(this.historyProgress - 1) * 100}%`;
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
        thinking: message.thinking,
        showThinking: message.showThinking,
        thinkingExpanded: message.thinkingExpanded,
        streaming: true,
        activeToolName: call.displayName,
        mode: message.mode,
      };
    });
    this.scrollTranscriptToBottom();
  }

  private showToolCallFinish(index: number, result: AgentToolResult): void {
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
          detail: result.summary,
          risk: result.ok ? '已完成' : '失败',
        },
        thinking: message.thinking,
        showThinking: message.showThinking,
        thinkingExpanded: message.thinkingExpanded,
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
      const nextAttachment: ComposerAttachment = {
        id: createId('att'),
        label: `文件 ${this.attachments.filter((item: ComposerAttachment) => item.kind === AttachmentKind.File).length + 1}`,
        kind: AttachmentKind.File,
      };
      const nextAttachments = this.attachments.slice();
      nextAttachments.push(nextAttachment);
      this.attachments = nextAttachments;
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
}
