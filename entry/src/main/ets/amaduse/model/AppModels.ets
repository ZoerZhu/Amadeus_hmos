export enum AttachmentKind {
  Image = 'Image',
  File = 'File',
}

export enum ChatMode {
  Fast = 'Fast',
  Thinking = 'Thinking',
}

export enum AppScreen {
  Chat = 'Chat',
  History = 'History',
}

export enum SettingsSheetMode {
  Full = 'Full',
  ModelOnly = 'ModelOnly',
}

export enum OutputLanguage {
  Japanese = 'Japanese',
  Chinese = 'Chinese',
  English = 'English',
}

export enum VoiceBackend {
  Off = 'off',
  Cloud = 'cloud',
  Local = 'local',
}

export interface OutputLanguageSpec {
  code: string;
  promptLabel: string;
}

export interface ComposerAttachment {
  id: string;
  label: string;
  kind: AttachmentKind;
}

export interface ToolPreview {
  title: string;
  detail: string;
  risk: string;
}

export interface ToolShortcut {
  title: string;
  subtitle: string;
  icon: string;
}

export interface ModelProviderPreset {
  name: string;
  baseUrl: string;
  defaultModel: string;
  compatible: boolean;
  note: string;
}

export interface ModelSettings {
  configuredModelId: string;
  provider: ModelProviderPreset;
  model: string;
  baseUrl: string;
  apiKey: string;
  useRemote: boolean;
}

export interface ConfiguredModel {
  id: string;
  displayName: string;
  provider: ModelProviderPreset;
  model: string;
  baseUrl: string;
  apiKey: string;
}

export interface ChatMessage {
  id: string;
  author: string;
  text: string;
  isAgent: boolean;
  time: string;
  attachments: ComposerAttachment[];
  toolPreview?: ToolPreview;
  thinking: string;
  showThinking: boolean;
  thinkingExpanded: boolean;
  streaming: boolean;
  activeToolName: string;
  mode: ChatMode;
}

export interface ChatRecord {
  id: string;
  title: string;
  subtitle: string;
  active: boolean;
}

export interface PersonaPreset {
  id: string;
  name: string;
  subtitle: string;
  tone: string;
  basePersonality: string;
  styleRules: string[];
  addressRules: string[];
  knowledgeRules: string[];
  relationshipRules: string[];
  boundaryRules: string[];
  voiceOutputLanguage: OutputLanguage;
  textOutputLanguage: OutputLanguage;
  ttsVoiceId: string;
  referenceAudioAsset: string;
}

export interface VoiceSettings {
  ttsBackend: VoiceBackend;
  siliconFlowApiKey: string;
  referenceAudioSource: string;
  clonedVoiceUri: string;
  clonedVoiceReferenceKey: string;
  autoPlay: boolean;
  syncTextOutput: boolean;
  speed: number;
  gain: number;
}

export interface ChatUiState {
  selectedPersona: PersonaPreset;
  selectedMode: ChatMode;
}

export function chatModeLabel(mode: ChatMode): string {
  return mode === ChatMode.Fast ? '快速' : '思考';
}

export function chatModeCaption(mode: ChatMode): string {
  return mode === ChatMode.Fast ? '更短延迟，直接回答' : '先展示推理摘要，再回答';
}

export function outputLanguageSpec(language: OutputLanguage): OutputLanguageSpec {
  if (language === OutputLanguage.Japanese) {
    return { code: 'ja', promptLabel: '日文' };
  }
  if (language === OutputLanguage.English) {
    return { code: 'en', promptLabel: '英文' };
  }
  return { code: 'zh', promptLabel: '中文' };
}
