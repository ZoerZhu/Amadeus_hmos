import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  AttachmentKind,
  ChatMessage,
  ChatMode,
  ChatRecord,
  ComposerAttachment,
  ConfiguredModel,
  HostAgentSettings,
  ModelProviderPreset,
  ModelSettings,
  ToolPreview,
  VoiceBackend,
  VoiceSettings,
} from '../model/AppModels';
import {
  defaultModelProvider,
  providerByName,
} from '../data/AppSeedData';
import {
  cleanDisplayText,
  createId,
  currentTimeText,
} from './AppUtils';

export const DEFAULT_VOICE_REFERENCE_SOURCE: string = 'asset://voices/kurisu-reference.wav';
const LEGACY_VOICE_REFERENCE_SOURCE: string = 'asset://voices/kurisu-reference.mp3';

const STORE_NAME = 'amaduse_store';
const KEY_CONFIGURED_MODELS = 'configured_models';
const KEY_SELECTED_MODEL = 'selected_model';
const KEY_MODEL_SETTINGS = 'model_settings';
const KEY_VOICE_SETTINGS = 'voice_settings';
const KEY_HOST_AGENT_SETTINGS = 'host_agent_settings';
const KEY_CHAT_MODE = 'chat_mode';
const KEY_CHAT_RECORDS = 'chat_records';
const KEY_MESSAGES_PREFIX = 'messages_';

interface ConfiguredModelStorage {
  id: string;
  display_name: string;
  provider: string;
  model: string;
  base_url: string;
  api_key: string;
}

interface AttachmentStorage {
  id: string;
  label: string;
  kind: string;
  uri?: string;
  host_path?: string;
  content_type?: string;
  size_bytes?: number;
  uploaded?: boolean;
}

interface ToolPreviewStorage {
  title: string;
  detail: string;
  risk: string;
}

interface MessageStorage {
  id: string;
  author: string;
  text: string;
  is_agent: boolean;
  time: string;
  attachments: AttachmentStorage[];
  tool_preview?: ToolPreviewStorage;
  thinking: string;
  show_thinking: boolean;
  thinking_expanded: boolean;
  streaming: boolean;
  active_tool_name: string;
  mode: string;
}

interface ChatRecordStorage {
  id: string;
  title: string;
  subtitle: string;
  active: boolean;
}

interface ModelSettingsStorage {
  provider: string;
  model: string;
  base_url: string;
  api_key: string;
  use_remote: boolean;
}

interface VoiceSettingsStorage {
  tts_backend?: string;
  siliconflow_api_key: string;
  reference_audio_source: string;
  cloned_voice_uri: string;
  cloned_voice_reference_key?: string;
  auto_play: boolean;
  sync_text_output: boolean;
  speed?: number;
  gain?: number;
}

interface HostAgentSettingsStorage {
  enabled?: boolean;
  base_url?: string;
  endpoint_path?: string;
  api_key?: string;
}

export class ChatPersistence {
  private static store?: preferences.Preferences;

  private static getStore(context: common.UIAbilityContext): preferences.Preferences {
    if (ChatPersistence.store === undefined) {
      ChatPersistence.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    }
    return ChatPersistence.store;
  }

  static async loadConfiguredModels(context: common.UIAbilityContext): Promise<ConfiguredModel[]> {
    const raw = await ChatPersistence.getString(context, KEY_CONFIGURED_MODELS, '');
    if (raw.length === 0) {
      return [];
    }
    try {
      const items = JSON.parse(raw) as ConfiguredModelStorage[];
      return items.map((item: ConfiguredModelStorage): ConfiguredModel => {
        const providerName = stringValue(item.provider);
        const provider = providerByName(providerName);
        return {
          id: stringValue(item.id, createId('model')),
          displayName: stringValue(item.display_name, provider.name),
          provider,
          model: stringValue(item.model, provider.defaultModel),
          baseUrl: stringValue(item.base_url, provider.baseUrl),
          apiKey: stringValue(item.api_key),
        };
      });
    } catch (_) {
      return [];
    }
  }

  static async saveConfiguredModels(context: common.UIAbilityContext, configuredModels: ConfiguredModel[]): Promise<void> {
    const payload: ConfiguredModelStorage[] = configuredModels.map((item: ConfiguredModel): ConfiguredModelStorage => {
      return {
        id: item.id,
        display_name: item.displayName,
        provider: item.provider.name,
        model: item.model,
        base_url: item.baseUrl,
        api_key: item.apiKey,
      };
    });
    await ChatPersistence.putString(context, KEY_CONFIGURED_MODELS, JSON.stringify(payload));
  }

  static async loadModelSettings(context: common.UIAbilityContext, configuredModels: ConfiguredModel[]): Promise<ModelSettings> {
    const selectedId = await ChatPersistence.getString(context, KEY_SELECTED_MODEL, '');
    const selected = configuredModels.find((item: ConfiguredModel) => item.id === selectedId);
    if (selected !== undefined) {
      return configuredModelToSettings(selected);
    }
    const firstReady = configuredModels.find((item: ConfiguredModel) => item.apiKey.length > 0);
    if (firstReady !== undefined) {
      return configuredModelToSettings(firstReady);
    }

    const raw = await ChatPersistence.getString(context, KEY_MODEL_SETTINGS, '');
    if (raw.length > 0) {
      try {
        const item = JSON.parse(raw) as ModelSettingsStorage;
        const provider = providerByName(stringValue(item.provider, defaultModelProvider().name));
        return {
          configuredModelId: '',
          provider,
          model: stringValue(item.model, provider.defaultModel),
          baseUrl: stringValue(item.base_url, provider.baseUrl),
          apiKey: stringValue(item.api_key),
          useRemote: booleanValue(item.use_remote, provider.compatible),
        };
      } catch (_) {
        return defaultModelSettings();
      }
    }
    return defaultModelSettings();
  }

  static async saveModelSettings(context: common.UIAbilityContext, settings: ModelSettings): Promise<void> {
    await ChatPersistence.putString(context, KEY_SELECTED_MODEL, settings.configuredModelId);
    const payload: ModelSettingsStorage = {
      provider: settings.provider.name,
      model: settings.model,
      base_url: settings.baseUrl,
      api_key: settings.apiKey,
      use_remote: settings.useRemote,
    };
    await ChatPersistence.putString(context, KEY_MODEL_SETTINGS, JSON.stringify(payload));
  }

  static async loadVoiceSettings(context: common.UIAbilityContext): Promise<VoiceSettings> {
    const raw = await ChatPersistence.getString(context, KEY_VOICE_SETTINGS, '');
    if (raw.length === 0) {
      return defaultVoiceSettings();
    }
    try {
      const item = JSON.parse(raw) as VoiceSettingsStorage;
      return {
        ttsBackend: voiceBackendValue(item.tts_backend, VoiceBackend.Cloud),
        siliconFlowApiKey: stringValue(item.siliconflow_api_key),
        referenceAudioSource: voiceReferenceSourceValue(item.reference_audio_source),
        clonedVoiceUri: stringValue(item.cloned_voice_uri),
        clonedVoiceReferenceKey: stringValue(item.cloned_voice_reference_key),
        autoPlay: booleanValue(item.auto_play, true),
        syncTextOutput: booleanValue(item.sync_text_output, true),
        speed: numberValue(item.speed, 1.0),
        gain: numberValue(item.gain, 0),
      };
    } catch (_) {
      return defaultVoiceSettings();
    }
  }

  static async saveVoiceSettings(context: common.UIAbilityContext, settings: VoiceSettings): Promise<void> {
    const payload: VoiceSettingsStorage = {
      tts_backend: settings.ttsBackend,
      siliconflow_api_key: settings.siliconFlowApiKey,
      reference_audio_source: settings.referenceAudioSource.length > 0 ? settings.referenceAudioSource : DEFAULT_VOICE_REFERENCE_SOURCE,
      cloned_voice_uri: settings.clonedVoiceUri,
      cloned_voice_reference_key: settings.clonedVoiceReferenceKey,
      auto_play: settings.autoPlay,
      sync_text_output: settings.syncTextOutput,
      speed: settings.speed,
      gain: settings.gain,
    };
    await ChatPersistence.putString(context, KEY_VOICE_SETTINGS, JSON.stringify(payload));
  }

  static async loadHostAgentSettings(context: common.UIAbilityContext): Promise<HostAgentSettings> {
    const raw = await ChatPersistence.getString(context, KEY_HOST_AGENT_SETTINGS, '');
    if (raw.length === 0) {
      return defaultHostAgentSettings();
    }
    try {
      const item = JSON.parse(raw) as HostAgentSettingsStorage;
      const defaults = defaultHostAgentSettings();
      return {
        enabled: booleanValue(item.enabled, defaults.enabled),
        baseUrl: stringValue(item.base_url, defaults.baseUrl),
        endpointPath: stringValue(item.endpoint_path, defaults.endpointPath),
        apiKey: stringValue(item.api_key),
      };
    } catch (_) {
      return defaultHostAgentSettings();
    }
  }

  static async saveHostAgentSettings(context: common.UIAbilityContext, settings: HostAgentSettings): Promise<void> {
    const payload: HostAgentSettingsStorage = {
      enabled: settings.enabled,
      base_url: settings.baseUrl,
      endpoint_path: settings.endpointPath,
      api_key: settings.apiKey,
    };
    await ChatPersistence.putString(context, KEY_HOST_AGENT_SETTINGS, JSON.stringify(payload));
  }

  static async loadChatMode(context: common.UIAbilityContext): Promise<ChatMode> {
    const value = await ChatPersistence.getString(context, KEY_CHAT_MODE, ChatMode.Fast);
    return value === ChatMode.Thinking ? ChatMode.Thinking : ChatMode.Fast;
  }

  static async saveChatMode(context: common.UIAbilityContext, mode: ChatMode): Promise<void> {
    await ChatPersistence.putString(context, KEY_CHAT_MODE, mode);
  }

  static async loadChatRecords(context: common.UIAbilityContext): Promise<ChatRecord[]> {
    const raw = await ChatPersistence.getString(context, KEY_CHAT_RECORDS, '');
    if (raw.length > 0) {
      try {
        const items = JSON.parse(raw) as ChatRecordStorage[];
        const records = items.map((item: ChatRecordStorage): ChatRecord => {
          return {
            id: stringValue(item.id, createId('chat')),
            title: stringValue(item.title, '新聊天'),
            subtitle: stringValue(item.subtitle),
            active: booleanValue(item.active, false),
          };
        });
        if (records.length > 0) {
          return records;
        }
      } catch (_) {
        return [createNewChatRecord()];
      }
    }
    const initial = [createNewChatRecord()];
    await ChatPersistence.saveChatRecords(context, initial);
    return initial;
  }

  static async saveChatRecords(context: common.UIAbilityContext, records: ChatRecord[]): Promise<void> {
    await ChatPersistence.putString(context, KEY_CHAT_RECORDS, JSON.stringify(records));
  }

  static async loadChatMessages(context: common.UIAbilityContext, recordId: string): Promise<ChatMessage[]> {
    const raw = await ChatPersistence.getString(context, `${KEY_MESSAGES_PREFIX}${recordId}`, '');
    if (raw.length === 0) {
      return [];
    }
    try {
      const items = JSON.parse(raw) as MessageStorage[];
      return items.map((item: MessageStorage): ChatMessage => jsonToMessage(item));
    } catch (_) {
      return [];
    }
  }

  static async saveChatMessages(context: common.UIAbilityContext, recordId: string, messages: ChatMessage[]): Promise<void> {
    const payload = messages.map((message: ChatMessage) => messageToJson(message));
    await ChatPersistence.putString(context, `${KEY_MESSAGES_PREFIX}${recordId}`, JSON.stringify(payload));
  }

  private static async getString(context: common.UIAbilityContext, key: string, fallback: string): Promise<string> {
    try {
      const value = await ChatPersistence.getStore(context).get(key, fallback);
      return typeof value === 'string' ? value : fallback;
    } catch (_) {
      return fallback;
    }
  }

  private static async putString(context: common.UIAbilityContext, key: string, value: string): Promise<void> {
    const store = ChatPersistence.getStore(context);
    await store.put(key, value);
    await store.flush();
  }
}

export function defaultModelSettings(): ModelSettings {
  const provider = defaultModelProvider();
  return {
    configuredModelId: '',
    provider,
    model: provider.defaultModel,
    baseUrl: provider.baseUrl,
    apiKey: '',
    useRemote: true,
  };
}

export function defaultVoiceSettings(): VoiceSettings {
  return {
    ttsBackend: VoiceBackend.Cloud,
    siliconFlowApiKey: '',
    referenceAudioSource: DEFAULT_VOICE_REFERENCE_SOURCE,
    clonedVoiceUri: '',
    clonedVoiceReferenceKey: '',
    autoPlay: true,
    syncTextOutput: true,
    speed: 1.0,
    gain: 0,
  };
}

export function defaultHostAgentSettings(): HostAgentSettings {
  return {
    enabled: false,
    baseUrl: '',
    endpointPath: '/api/agent/invoke',
    apiKey: '',
  };
}

export function configuredModelToSettings(item: ConfiguredModel): ModelSettings {
  return {
    configuredModelId: item.id,
    provider: item.provider,
    model: item.model,
    baseUrl: item.baseUrl,
    apiKey: item.apiKey,
    useRemote: item.apiKey.length > 0 || item.provider.name === 'Ollama',
  };
}

export function updateRecordPreview(records: ChatRecord[], current: ChatRecord, latestText: string): ChatRecord[] {
  const nextTitle = current.title === '新聊天' ? latestText.trim().substring(0, 24) || '新聊天' : current.title;
  const next: ChatRecord = {
    id: current.id,
    title: nextTitle,
    subtitle: latestText.trim().substring(0, 56),
    active: true,
  };
  return records.map((record: ChatRecord): ChatRecord => record.id === current.id ? next : {
    id: record.id,
    title: record.title,
    subtitle: record.subtitle,
    active: false,
  });
}

export function createNewChatRecord(): ChatRecord {
  return {
    title: '新聊天',
    subtitle: currentTimeText(),
    active: true,
    id: createId('chat'),
  };
}

export function makeConfiguredModel(
  editingModelId: string,
  displayName: string,
  provider: ModelProviderPreset,
  model: string,
  baseUrl: string,
  apiKey: string,
): ConfiguredModel {
  return {
    id: editingModelId.length > 0 ? editingModelId : createId('model'),
    displayName: displayName.length > 0 ? displayName : provider.name,
    provider,
    model: model.length > 0 ? model : provider.defaultModel,
    baseUrl: baseUrl.length > 0 ? baseUrl : provider.baseUrl,
    apiKey,
  };
}

function messageToJson(message: ChatMessage): MessageStorage {
  const attachments: AttachmentStorage[] = message.attachments.map((attachment: ComposerAttachment): AttachmentStorage => {
    return {
      id: attachment.id,
      label: attachment.label,
      kind: attachment.kind,
      uri: attachment.uri,
      host_path: attachment.hostPath,
      content_type: attachment.contentType,
      size_bytes: attachment.sizeBytes,
      uploaded: attachment.uploaded,
    };
  });
  return {
    id: message.id,
    author: message.author,
    text: message.text,
    is_agent: message.isAgent,
    time: message.time,
    attachments,
    tool_preview: message.toolPreview === undefined ? undefined : toolPreviewToJson(message.toolPreview),
    thinking: message.thinking,
    show_thinking: message.showThinking,
    thinking_expanded: message.thinkingExpanded,
    streaming: false,
    active_tool_name: '',
    mode: message.mode,
  };
}

function jsonToMessage(item: MessageStorage): ChatMessage {
  const rawAttachments = item.attachments;
  const attachments: ComposerAttachment[] = Array.isArray(rawAttachments) ? rawAttachments.map((attachment: AttachmentStorage): ComposerAttachment => {
    const kind = stringValue(attachment.kind) === AttachmentKind.Image ? AttachmentKind.Image : AttachmentKind.File;
    return {
      id: stringValue(attachment.id, createId('att')),
      label: stringValue(attachment.label, '附件'),
      kind,
      uri: stringValue(attachment.uri),
      hostPath: stringValue(attachment.host_path),
      contentType: stringValue(attachment.content_type),
      sizeBytes: numberValue(attachment.size_bytes, 0),
      uploaded: booleanValue(attachment.uploaded, false),
    };
  }) : [];
  return {
    id: stringValue(item.id, createId('msg')),
    author: stringValue(item.author, 'Amaduse'),
    text: cleanDisplayText(stringValue(item.text)),
    isAgent: booleanValue(item.is_agent, true),
    time: stringValue(item.time, currentTimeText()),
    attachments,
    toolPreview: jsonToToolPreview(item.tool_preview),
    thinking: cleanDisplayText(stringValue(item.thinking)),
    showThinking: booleanValue(item.show_thinking, false),
    thinkingExpanded: booleanValue(item.thinking_expanded, false),
    streaming: false,
    activeToolName: '',
    mode: stringValue(item.mode) === ChatMode.Thinking ? ChatMode.Thinking : ChatMode.Fast,
  };
}

function toolPreviewToJson(preview: ToolPreview): ToolPreviewStorage {
  return {
    title: preview.title,
    detail: preview.detail,
    risk: preview.risk,
  };
}

function jsonToToolPreview(item: ToolPreviewStorage | undefined): ToolPreview | undefined {
  if (item === undefined) {
    return undefined;
  }
  const title = stringValue(item.title);
  const detail = stringValue(item.detail);
  const risk = stringValue(item.risk);
  if (title.length === 0 && detail.length === 0) {
    return undefined;
  }
  return {
    title,
    detail,
    risk,
  };
}

function stringValue(value: string | undefined, fallback: string = ''): string {
  return typeof value === 'string' && value.length > 0 ? value : fallback;
}

function booleanValue(value: boolean | undefined, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback;
}

function numberValue(value: number | undefined, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

function voiceBackendValue(value: string | undefined, fallback: VoiceBackend): VoiceBackend {
  if (value === VoiceBackend.Off) {
    return VoiceBackend.Off;
  }
  if (value === VoiceBackend.Local) {
    return VoiceBackend.Local;
  }
  if (value === VoiceBackend.Cloud) {
    return VoiceBackend.Cloud;
  }
  return fallback;
}

function voiceReferenceSourceValue(value: string | undefined): string {
  const source = stringValue(value, DEFAULT_VOICE_REFERENCE_SOURCE);
  if (source === LEGACY_VOICE_REFERENCE_SOURCE || source === 'voices/kurisu-reference.mp3') {
    return DEFAULT_VOICE_REFERENCE_SOURCE;
  }
  return source;
}
