import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import {
  ModelProviderPreset,
  ModelSettings,
  OutputLanguage,
  PersonaPreset,
  VoiceBackend,
  VoiceSettings,
} from '../model/AppModels';
import { KURISU_REFERENCE_TEXT } from '../persona/PersonaPresets';
import { cleanDisplayText } from './AppUtils';

const SILICONFLOW_SPEECH_ENDPOINT = 'https://api.siliconflow.cn/v1/audio/speech';
const SILICONFLOW_VOICE_UPLOAD_ENDPOINT = 'https://api.siliconflow.cn/v1/uploads/audio/voice';
const SILICONFLOW_TTS_MODEL = 'FunAudioLLM/CosyVoice2-0.5B';
const DEFAULT_REFERENCE_AUDIO = 'voices/kurisu-reference.wav';
const OUTPUT_FILE_PREFIX = 'amaduse_voice';
const VOICE_CACHE_DIR_NAME = 'amaduse_voice_cache';
const VOICE_CACHE_VERSION = 'v1';
const FILE_COPY_CHUNK_SIZE = 64 * 1024;
const PLAYER_PREPARE_TIMEOUT_MS = 8000;
const PLAYER_PLAYBACK_TIMEOUT_MS = 180000;
const SPEECH_SEGMENT_TARGET_CHAR_COUNT = 30;
const SPEECH_SEGMENT_MAX_CHAR_COUNT = 55;
const SPEECH_SEGMENT_HARD_BREAK_MIN_CHAR_COUNT = 20;
const SPEECH_PREPARE_CONCURRENCY = 2;
const SPEECH_TTS_MAX_ATTEMPTS = 2;
const SPEECH_HARD_BREAKS = '。！？!?；;\n';
const SPEECH_SOFT_BREAKS = '，,、 ：:';
const WAITING_SEGMENT_ERROR = '等待合成。';

interface SpeechReference {
  audio: string;
  text: string;
}

interface SpeechPayload {
  model: string;
  input: string;
  voice: string;
  response_format: string;
  sample_rate: number;
  stream: boolean;
  speed: number;
  gain: number;
  references?: SpeechReference[];
}

interface SpeechHeaderMap {
  'Content-Type': string;
  'Accept': string;
  'Authorization': string;
}

interface UploadVoiceHeaderMap {
  'Content-Type': string;
  'Accept': string;
  'Authorization': string;
}

interface JsonHeaderMap {
  'Content-Type': string;
  'Accept': string;
  'Authorization'?: string;
}

interface TranslationMessage {
  role: string;
  content: string;
}

interface ThinkingPayload {
  type: string;
}

interface ReasoningPayload {
  effort: string;
  exclude: boolean;
}

interface TranslationPayload {
  model: string;
  stream: boolean;
  messages: TranslationMessage[];
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

interface TranslationResponseMessage {
  content?: string;
}

interface TranslationChoice {
  message: TranslationResponseMessage;
}

interface TranslationResponse {
  choices: TranslationChoice[];
}

interface UploadVoiceResponse {
  uri?: string;
}

interface ReferenceAudioInfo {
  rawPath: string;
  dataUrl: string;
  referenceKey: string;
}

interface ChatCompletionModeConfig {
  providerName: string;
  providerBaseUrl: string;
  baseUrl: string;
  model: string;
  defaultModel: string;
}

interface SpeechSegmentResult {
  index: number;
  text: string;
  filePath: string;
  error: string;
}

interface SegmentWorkerState {
  nextIndex: number;
}

interface VoicePlaybackProgress {
  firstFilePath: string;
  firstError: string;
  playedCount: number;
}

export interface VoicePlaybackCallbacks {
  onSegmentPlaybackStart?: (index: number, text: string, durationMs: number) => Promise<void>;
}

export interface VoicePlaybackResult {
  ok: boolean;
  filePath: string;
  error: string;
}

export class VoiceService {
  private static currentPlayer?: media.AVPlayer;
  private static currentAudioFile?: fileIo.File;

  static async speak(
    context: common.UIAbilityContext,
    text: string,
    persona: PersonaPreset,
    settings: VoiceSettings,
    modelSettings: ModelSettings,
    onSettingsUpdated: (settings: VoiceSettings) => Promise<void>,
    callbacks?: VoicePlaybackCallbacks,
  ): Promise<VoicePlaybackResult> {
    if (settings.ttsBackend === VoiceBackend.Off) {
      return createVoiceResult(false, '', '云端语音已关闭。');
    }
    if (settings.ttsBackend === VoiceBackend.Local) {
      return createVoiceResult(false, '', '鸿蒙端暂未接入本地 CosyVoice2，请使用云端语音。');
    }
    if (settings.siliconFlowApiKey.trim().length === 0) {
      return createVoiceResult(false, '', '需要先在设置中填写 SiliconFlow API Key。');
    }

    const sourceText = VoiceService.toSpeechSourceText(cleanDisplayText(text));
    if (sourceText.length === 0) {
      return createVoiceResult(false, '', '没有可播放的文本。');
    }

    await VoiceService.stopCurrentPlayer();
    const initialCachePath = VoiceService.safeVoiceCachePath(context, sourceText, persona, settings, modelSettings);
    if (initialCachePath.length > 0 && VoiceService.cachedAudioExists(initialCachePath)) {
      console.info(`[Amaduse] voice cache hit ${initialCachePath}`);
      await VoiceService.playAudioFile(initialCachePath, createSpeechSegmentResult(0, sourceText, initialCachePath, ''), callbacks);
      return createVoiceResult(true, initialCachePath, '');
    }

    await VoiceService.ensureCachedVoiceUri(context, persona, settings, onSettingsUpdated);
    const cachePath = VoiceService.safeVoiceCachePath(context, sourceText, persona, settings, modelSettings);
    if (cachePath.length > 0 && cachePath !== initialCachePath && VoiceService.cachedAudioExists(cachePath)) {
      console.info(`[Amaduse] voice cache hit ${cachePath}`);
      await VoiceService.playAudioFile(cachePath, createSpeechSegmentResult(0, sourceText, cachePath, ''), callbacks);
      return createVoiceResult(true, cachePath, '');
    }

    const segments = VoiceService.splitSpeechSegments(sourceText);
    const playback = await VoiceService.prepareAndPlaySegmentAudioFiles(context, segments, persona, settings, modelSettings, onSettingsUpdated, cachePath, callbacks);
    if (playback.playedCount === 0) {
      return createVoiceResult(false, '', playback.firstError.length > 0 ? playback.firstError : '语音服务未返回音频，请检查当前语音模型配置。');
    }
    return createVoiceResult(true, playback.firstFilePath, playback.firstError);
  }

  static async stopCurrentPlayer(): Promise<void> {
    const player = VoiceService.currentPlayer;
    VoiceService.currentPlayer = undefined;
    if (player === undefined) {
      VoiceService.closeCurrentAudioFile();
      return;
    }
    try {
      await player.stop();
    } catch (_) {
    }
    try {
      await player.release();
    } catch (_) {
    } finally {
      VoiceService.closeCurrentAudioFile();
    }
  }

  private static async prepareAndPlaySegmentAudioFiles(
    context: common.UIAbilityContext,
    segments: string[],
    persona: PersonaPreset,
    settings: VoiceSettings,
    modelSettings: ModelSettings,
    onSettingsUpdated: (settings: VoiceSettings) => Promise<void>,
    cachePath: string,
    callbacks?: VoicePlaybackCallbacks,
  ): Promise<VoicePlaybackProgress> {
    const results: SpeechSegmentResult[] = [];
    for (let index = 0; index < segments.length; index += 1) {
      results.push(createSpeechSegmentResult(index, segments[index], '', WAITING_SEGMENT_ERROR));
    }

    const workerCount = Math.min(SPEECH_PREPARE_CONCURRENCY, segments.length);
    const workerState: SegmentWorkerState = {
      nextIndex: 0,
    };
    const workers: Promise<void>[] = [];
    for (let index = 0; index < workerCount; index += 1) {
      workers.push(VoiceService.runSegmentWorker(workerState, results, context, segments, persona, settings, modelSettings, onSettingsUpdated));
    }

    let firstFilePath = '';
    let firstError = '';
    let playedCount = 0;
    for (let index = 0; index < segments.length; index += 1) {
      while (results[index].error === WAITING_SEGMENT_ERROR) {
        await VoiceService.delay(50);
      }
      const result = results[index];
      if (result.filePath.length > 0) {
        if (firstFilePath.length === 0) {
          firstFilePath = result.filePath;
        }
        await VoiceService.playAudioFile(result.filePath, result, callbacks);
        playedCount += 1;
      } else if (firstError.length === 0 && result.error.length > 0) {
        firstError = `第 ${result.index + 1} 段语音生成失败：${result.error}`;
      }
    }

    await Promise.all(workers);
    VoiceService.saveMergedAudioCache(cachePath, results);
    return createVoicePlaybackProgress(firstFilePath, firstError, playedCount);
  }

  private static async runSegmentWorker(
    workerState: SegmentWorkerState,
    results: SpeechSegmentResult[],
    context: common.UIAbilityContext,
    segments: string[],
    persona: PersonaPreset,
    settings: VoiceSettings,
    modelSettings: ModelSettings,
    onSettingsUpdated: (settings: VoiceSettings) => Promise<void>,
  ): Promise<void> {
    while (true) {
      const index = workerState.nextIndex;
      workerState.nextIndex += 1;
      if (index >= segments.length) {
        return;
      }
      results[index] = await VoiceService.prepareSingleSegmentAudio(context, index, segments[index], persona, settings, modelSettings, onSettingsUpdated);
    }
  }

  private static async prepareSingleSegmentAudio(
    context: common.UIAbilityContext,
    index: number,
    segment: string,
    persona: PersonaPreset,
    settings: VoiceSettings,
    modelSettings: ModelSettings,
    onSettingsUpdated: (settings: VoiceSettings) => Promise<void>,
  ): Promise<SpeechSegmentResult> {
    const speechText = await VoiceService.prepareSpeechText(segment, persona, modelSettings);
    if (speechText.length === 0) {
      return createSpeechSegmentResult(index, segment, '', '');
    }

    let lastError = '';
    for (let attempt = 0; attempt < SPEECH_TTS_MAX_ATTEMPTS; attempt += 1) {
      try {
        const audioData = await VoiceService.requestSpeech(context, speechText, persona, settings, onSettingsUpdated);
        const filePath = VoiceService.writeAudioFile(context, audioData, index);
        return createSpeechSegmentResult(index, segment, filePath, '');
      } catch (error) {
        lastError = errorToString(error);
        if (attempt < SPEECH_TTS_MAX_ATTEMPTS - 1) {
          await VoiceService.delay(450 * (attempt + 1));
        }
      }
    }
    return createSpeechSegmentResult(index, segment, '', lastError.length > 0 ? lastError : '语音生成失败。');
  }

  private static async prepareSpeechText(
    text: string,
    persona: PersonaPreset,
    modelSettings: ModelSettings,
  ): Promise<string> {
    const sourceText = VoiceService.toSpeechSourceText(text);
    if (sourceText.length === 0) {
      return '';
    }
    if (persona.voiceOutputLanguage !== OutputLanguage.Japanese) {
      return VoiceService.toTtsInputText(sourceText);
    }
    return VoiceService.translateForSpeech(sourceText, modelSettings);
  }

  private static async translateForSpeech(text: string, modelSettings: ModelSettings): Promise<string> {
    const cleaned = VoiceService.toSpeechSourceText(text);
    const fallback = VoiceService.toTtsInputText(cleaned);
    if (fallback.length === 0 || VoiceService.hasJapaneseKana(fallback)) {
      return fallback;
    }
    if (!modelSettings.useRemote || !modelSettings.provider.compatible) {
      return fallback;
    }
    if (modelSettings.apiKey.length === 0 && modelSettings.provider.name.toLowerCase() !== 'ollama') {
      return fallback;
    }

    const request = http.createHttp();
    try {
      const base = trimEnd(modelSettings.baseUrl.trim(), '/');
      const endpoint = `${base}/chat/completions`;
      const headers: JsonHeaderMap = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      if (modelSettings.apiKey.length > 0) {
        headers.Authorization = `Bearer ${modelSettings.apiKey}`;
      }
      const payload = VoiceService.buildTranslationPayload(modelSettings, cleaned);
      const response = await request.request(endpoint, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(payload),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 45000,
      });
      if (response.responseCode < 200 || response.responseCode > 299) {
        return fallback;
      }
      const body = VoiceService.responseBodyToText(response.result, response.resultType);
      const data = JSON.parse(body) as TranslationResponse;
      const choices = data.choices;
      if (!Array.isArray(choices) || choices.length === 0) {
        return fallback;
      }
      const translated = VoiceService.toTtsInputText(cleanDisplayText(stringValue(choices[0].message.content))).trim();
      return translated.length > 0 ? translated : fallback;
    } catch (_) {
      return fallback;
    } finally {
      request.destroy();
    }
  }

  private static buildTranslationPayload(settings: ModelSettings, input: string): TranslationPayload {
    const config: ChatCompletionModeConfig = {
      providerName: settings.provider.name,
      providerBaseUrl: settings.provider.baseUrl,
      baseUrl: settings.baseUrl,
      model: settings.model,
      defaultModel: settings.provider.defaultModel,
    };
    const requestModel = resolveFastRequestModel(config);
    const messages: TranslationMessage[] = [
      createTranslationMessage(
        'system',
        '你是专业翻译助手。把输入翻译成自然口语日语，只返回适合 TTS 直接朗读的日语译文。不要解释，不要 Markdown，不要编号、项目符号、引号、括号、emoji、URL。句子之间只使用：、，、。等自然停顿符号。',
      ),
      createTranslationMessage('user', input),
    ];
    const payload: TranslationPayload = {
      model: requestModel,
      stream: false,
      messages,
    };
    applyFastModeParameters(payload, config, requestModel);
    return payload;
  }

  private static async ensureCachedVoiceUri(
    context: common.UIAbilityContext,
    persona: PersonaPreset,
    settings: VoiceSettings,
    onSettingsUpdated: (settings: VoiceSettings) => Promise<void>,
  ): Promise<void> {
    const configuredVoice = settings.clonedVoiceUri.trim();
    const cachedReferenceKey = settings.clonedVoiceReferenceKey.trim();
    if (configuredVoice.length > 0 && cachedReferenceKey.length === 0) {
      return;
    }

    const referenceInfo = VoiceService.referenceAudioInfo(context, persona, settings);
    if (configuredVoice.length > 0 && cachedReferenceKey === referenceInfo.referenceKey) {
      return;
    }

    if (cachedReferenceKey.length > 0 && cachedReferenceKey !== referenceInfo.referenceKey) {
      settings.clonedVoiceUri = '';
      settings.clonedVoiceReferenceKey = '';
    }

    try {
      const voiceUri = await VoiceService.uploadReferenceVoice(settings, referenceInfo);
      if (voiceUri.length === 0) {
        return;
      }
      settings.clonedVoiceUri = voiceUri;
      settings.clonedVoiceReferenceKey = referenceInfo.referenceKey;
      await onSettingsUpdated(settings);
    } catch (error) {
      if (cachedReferenceKey.length > 0) {
        settings.clonedVoiceUri = '';
        settings.clonedVoiceReferenceKey = '';
        try {
          await onSettingsUpdated(settings);
        } catch (_) {
        }
      }
      console.error(`[Amaduse] voice clone failed: ${errorToString(error)}`);
    }
  }

  private static async uploadReferenceVoice(
    settings: VoiceSettings,
    referenceInfo: ReferenceAudioInfo,
  ): Promise<string> {
    const boundary = `----AmadeusVoice${Date.now().toString(36)}`;
    const customName = `amadeus-hmos-kurisu-${Date.now().toString(36)}`;
    const body = VoiceService.buildUploadVoiceMultipartBody(boundary, referenceInfo, customName);
    const request = http.createHttp();
    try {
      const headers: UploadVoiceHeaderMap = {
        'Content-Type': `multipart/form-data; boundary=${boundary}`,
        'Accept': 'application/json',
        'Authorization': `Bearer ${settings.siliconFlowApiKey.trim()}`,
      };
      const response = await request.request(SILICONFLOW_VOICE_UPLOAD_ENDPOINT, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 120000,
      });
      const responseText = VoiceService.responseBodyToText(response.result, response.resultType);
      if (response.responseCode < 200 || response.responseCode > 299) {
        throw new Error(`HTTP ${response.responseCode} ${responseText.substring(0, 220)}`);
      }
      const data = JSON.parse(responseText) as UploadVoiceResponse;
      return stringValue(data.uri).trim();
    } finally {
      request.destroy();
    }
  }

  private static buildUploadVoiceMultipartBody(
    boundary: string,
    referenceInfo: ReferenceAudioInfo,
    customName: string,
  ): string {
    let body = '';
    body += multipartTextField(boundary, 'audio', referenceInfo.dataUrl);
    body += multipartTextField(boundary, 'model', SILICONFLOW_TTS_MODEL);
    body += multipartTextField(boundary, 'customName', customName);
    body += multipartTextField(boundary, 'text', KURISU_REFERENCE_TEXT);
    body += `--${boundary}--\r\n`;
    return body;
  }

  private static async requestSpeech(
    context: common.UIAbilityContext,
    input: string,
    persona: PersonaPreset,
    settings: VoiceSettings,
    onSettingsUpdated: (settings: VoiceSettings) => Promise<void>,
  ): Promise<ArrayBuffer> {
    const request = http.createHttp();
    try {
      const headers: SpeechHeaderMap = {
        'Content-Type': 'application/json',
        'Accept': 'audio/mpeg',
        'Authorization': `Bearer ${settings.siliconFlowApiKey.trim()}`,
      };
      const payload = VoiceService.buildSpeechPayload(context, input, persona, settings);
      const response = await request.request(SILICONFLOW_SPEECH_ENDPOINT, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(payload),
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 20000,
        readTimeout: 120000,
      });
      const statusCode = response.responseCode;
      if (statusCode < 200 || statusCode > 299) {
        if (statusCode === 403 && settings.clonedVoiceReferenceKey.trim().length > 0) {
          settings.clonedVoiceUri = '';
          settings.clonedVoiceReferenceKey = '';
          try {
            await onSettingsUpdated(settings);
          } catch (_) {
          }
        }
        throw new Error(`HTTP ${statusCode} ${VoiceService.responseBodyToText(response.result, response.resultType).substring(0, 220)}`);
      }
      return VoiceService.responseBodyToArrayBuffer(response.result, response.resultType);
    } finally {
      request.destroy();
    }
  }

  private static buildSpeechPayload(
    context: common.UIAbilityContext,
    input: string,
    persona: PersonaPreset,
    settings: VoiceSettings,
  ): SpeechPayload {
    const voiceUri = settings.clonedVoiceUri.trim();
    const payload: SpeechPayload = {
      model: SILICONFLOW_TTS_MODEL,
      input,
      voice: voiceUri,
      response_format: 'mp3',
      sample_rate: 44100,
      stream: false,
      speed: boundedNumber(settings.speed, 1.0, 0.25, 4.0),
      gain: boundedNumber(settings.gain, 0, -20, 20),
    };
    if (voiceUri.length === 0) {
      const referenceInfo = VoiceService.referenceAudioInfo(context, persona, settings);
      const reference: SpeechReference = {
        audio: referenceInfo.dataUrl,
        text: KURISU_REFERENCE_TEXT,
      };
      payload.references = [reference];
    }
    return payload;
  }

  private static referenceAudioInfo(
    context: common.UIAbilityContext,
    persona: PersonaPreset,
    settings: VoiceSettings,
  ): ReferenceAudioInfo {
    const configuredPath = VoiceService.normalizeRawfilePath(settings.referenceAudioSource);
    const personaPath = VoiceService.normalizeRawfilePath(persona.referenceAudioAsset);
    const rawPath = configuredPath.length > 0 ? configuredPath : (personaPath.length > 0 ? personaPath : DEFAULT_REFERENCE_AUDIO);
    const rawData = context.resourceManager.getRawFileContentSync(rawPath);
    const encoded = buffer.from(rawData).toString('base64');
    const mimeType = rawPath.toLowerCase().endsWith('.wav') ? 'audio/wav' : 'audio/mpeg';
    return {
      rawPath,
      dataUrl: `data:${mimeType};base64,${encoded}`,
      referenceKey: VoiceService.referenceAudioKey(rawPath, rawData),
    };
  }

  private static normalizeRawfilePath(source: string): string {
    let path = source.trim();
    if (path.startsWith('asset://')) {
      path = path.substring('asset://'.length);
    }
    if (path.startsWith('rawfile://')) {
      path = path.substring('rawfile://'.length);
    }
    if (path.startsWith('resource://rawfile/')) {
      path = path.substring('resource://rawfile/'.length);
    }
    if (path.startsWith('/')) {
      path = path.substring(1);
    }
    return path;
  }

  private static referenceAudioKey(rawPath: string, rawData: Uint8Array): string {
    let checksum = 0;
    for (let index = 0; index < rawData.length; index += 1) {
      checksum = (checksum + rawData[index] * ((index % 251) + 1)) % 1000000007;
    }
    return `${rawPath}|${rawData.length}|${checksum}`;
  }

  private static safeVoiceCachePath(
    context: common.UIAbilityContext,
    sourceText: string,
    persona: PersonaPreset,
    settings: VoiceSettings,
    modelSettings: ModelSettings,
  ): string {
    try {
      return VoiceService.voiceCachePath(context, sourceText, persona, settings, modelSettings);
    } catch (error) {
      console.error(`[Amaduse] voice cache path failed: ${errorToString(error)}`);
      return '';
    }
  }

  private static voiceCachePath(
    context: common.UIAbilityContext,
    sourceText: string,
    persona: PersonaPreset,
    settings: VoiceSettings,
    modelSettings: ModelSettings,
  ): string {
    const cacheDir = VoiceService.ensureVoiceCacheDirectory(context);
    const voiceUri = settings.clonedVoiceUri.trim();
    const voiceIdentity = voiceUri.length > 0 ? `voice:${voiceUri}` : `reference:${VoiceService.referenceAudioInfo(context, persona, settings).referenceKey}`;
    const translationIdentity = persona.voiceOutputLanguage === OutputLanguage.Japanese ?
      `${modelSettings.provider.name}|${modelSettings.baseUrl}|${modelSettings.model}|${modelSettings.useRemote}` :
      'no-translation';
    const rawKey = [
      VOICE_CACHE_VERSION,
      SILICONFLOW_TTS_MODEL,
      persona.id,
      persona.voiceOutputLanguage,
      voiceIdentity,
      boundedNumber(settings.speed, 1.0, 0.25, 4.0).toFixed(2),
      boundedNumber(settings.gain, 0, -20, 20).toFixed(2),
      translationIdentity,
      sourceText,
    ].join('\n');
    const key = `${VOICE_CACHE_VERSION}_${sourceText.length}_${VoiceService.stableHash(rawKey, 17)}_${VoiceService.stableHash(rawKey, 97)}`;
    return `${cacheDir}/${key}.mp3`;
  }

  private static ensureVoiceCacheDirectory(context: common.UIAbilityContext): string {
    const cacheDir = `${context.filesDir}/${VOICE_CACHE_DIR_NAME}`;
    if (!VoiceService.fileExists(cacheDir)) {
      fileIo.mkdirSync(cacheDir, true);
    }
    return cacheDir;
  }

  private static cachedAudioExists(filePath: string): boolean {
    if (filePath.length === 0) {
      return false;
    }
    if (!VoiceService.fileExists(filePath)) {
      return false;
    }
    try {
      return fileIo.statSync(filePath).size > 0;
    } catch (_) {
      return false;
    }
  }

  private static saveMergedAudioCache(cachePath: string, results: SpeechSegmentResult[]): void {
    if (cachePath.length === 0 || results.length === 0 || VoiceService.cachedAudioExists(cachePath)) {
      return;
    }
    for (let index = 0; index < results.length; index += 1) {
      if (results[index].filePath.length === 0 || results[index].error.length > 0) {
        return;
      }
    }

    const tempPath = `${cachePath}.${Date.now().toString(36)}.tmp`;
    let targetFile: fileIo.File;
    try {
      targetFile = fileIo.openSync(tempPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    } catch (error) {
      console.error(`[Amaduse] voice cache open failed: ${errorToString(error)}`);
      return;
    }
    try {
      for (let index = 0; index < results.length; index += 1) {
        VoiceService.appendFileToOpenFile(results[index].filePath, targetFile);
      }
    } catch (error) {
      VoiceService.safeCloseFile(targetFile);
      VoiceService.safeUnlink(tempPath);
      console.error(`[Amaduse] voice cache merge failed: ${errorToString(error)}`);
      return;
    }
    VoiceService.safeCloseFile(targetFile);

    try {
      if (VoiceService.cachedAudioExists(cachePath)) {
        VoiceService.safeUnlink(tempPath);
        return;
      }
      fileIo.renameSync(tempPath, cachePath);
      console.info(`[Amaduse] voice cache saved ${cachePath}`);
    } catch (error) {
      VoiceService.safeUnlink(tempPath);
      console.error(`[Amaduse] voice cache save failed: ${errorToString(error)}`);
    }
  }

  private static appendFileToOpenFile(sourcePath: string, targetFile: fileIo.File): void {
    const sourceFile = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
    try {
      let remaining = fileIo.statSync(sourcePath).size;
      while (remaining > 0) {
        const chunkSize = Math.min(FILE_COPY_CHUNK_SIZE, remaining);
        const chunk = new ArrayBuffer(chunkSize);
        const bytesRead = fileIo.readSync(sourceFile.fd, chunk);
        if (bytesRead <= 0) {
          break;
        }
        if (bytesRead === chunkSize) {
          fileIo.writeSync(targetFile.fd, chunk);
        } else {
          fileIo.writeSync(targetFile.fd, chunk.slice(0, bytesRead));
        }
        remaining -= bytesRead;
      }
    } finally {
      fileIo.closeSync(sourceFile);
    }
  }

  private static fileExists(filePath: string): boolean {
    try {
      return fileIo.accessSync(filePath);
    } catch (_) {
      return false;
    }
  }

  private static safeUnlink(filePath: string): void {
    try {
      if (filePath.length > 0 && VoiceService.fileExists(filePath)) {
        fileIo.unlinkSync(filePath);
      }
    } catch (_) {
    }
  }

  private static safeCloseFile(file: fileIo.File): void {
    try {
      fileIo.closeSync(file);
    } catch (_) {
    }
  }

  private static stableHash(value: string, seed: number): string {
    let hash = seed;
    for (let index = 0; index < value.length; index += 1) {
      hash = (hash * 131 + value.charCodeAt(index)) % 2147483647;
    }
    return hash.toString(36);
  }

  private static writeAudioFile(context: common.UIAbilityContext, audioData: ArrayBuffer, index: number): string {
    const filePath = `${context.cacheDir}/${OUTPUT_FILE_PREFIX}_${Date.now()}_${index}.mp3`;
    const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, audioData);
    } finally {
      fileIo.closeSync(file);
    }
    return filePath;
  }

  private static async playAudioFile(
    filePath: string,
    segment: SpeechSegmentResult,
    callbacks?: VoicePlaybackCallbacks,
  ): Promise<void> {
    const sourceFile = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
    const player = await media.createAVPlayer();
    VoiceService.currentPlayer = player;
    VoiceService.currentAudioFile = sourceFile;
    try {
      const initialized = VoiceService.waitForPlayerState(player, 'initialized', 'prepared', PLAYER_PREPARE_TIMEOUT_MS);
      const fileInfo = fileIo.statSync(filePath);
      const source: media.AVFileDescriptor = {
        fd: sourceFile.fd,
        offset: 0,
        length: fileInfo.size,
      };
      player.fdSrc = source;
      await initialized;
      if (player.state !== 'prepared') {
        await player.prepare();
      }
      const durationMs = VoiceService.playbackDurationMs(player, segment.text);
      let captionTask: Promise<void> | undefined = undefined;
      if (callbacks !== undefined && callbacks.onSegmentPlaybackStart !== undefined) {
        captionTask = callbacks.onSegmentPlaybackStart(segment.index, segment.text, durationMs);
      }
      const ended = VoiceService.waitForPlayerState(player, 'completed', 'stopped', PLAYER_PLAYBACK_TIMEOUT_MS);
      await player.play();
      await ended;
      if (captionTask !== undefined) {
        await captionTask;
      }
    } finally {
      VoiceService.releasePlayer(player);
    }
  }

  private static playbackDurationMs(player: media.AVPlayer, text: string): number {
    const duration = player.duration;
    if (duration > 300) {
      return duration;
    }
    return Math.max(900, text.length * 180 + 500);
  }

  private static waitForPlayerState(
    player: media.AVPlayer,
    stateA: media.AVPlayerState,
    stateB: media.AVPlayerState,
    timeoutMs: number,
  ): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void) => {
      let finished = false;
      let timer = -1;
      const finish = (error: string): void => {
        if (finished) {
          return;
        }
        finished = true;
        if (timer >= 0) {
          clearTimeout(timer);
        }
        try {
          player.off('stateChange', onStateChange);
        } catch (_) {
        }
        if (error.length > 0) {
          reject(new Error(error));
        } else {
          resolve();
        }
      };
      const onStateChange: media.OnAVPlayerStateChangeHandle = (state: media.AVPlayerState): void => {
        if (state === stateA || state === stateB) {
          finish('');
          return;
        }
        if (state === 'error' || state === 'released') {
          finish(`播放器状态异常：${state}`);
        }
      };
      try {
        player.on('stateChange', onStateChange);
        if (player.state === stateA || player.state === stateB) {
          finish('');
          return;
        }
        timer = setTimeout(() => {
          finish(`等待播放器进入 ${stateA}/${stateB} 超时，当前状态：${player.state}`);
        }, timeoutMs);
      } catch (error) {
        finish(errorToString(error));
      }
    });
  }

  private static releasePlayer(player: media.AVPlayer): void {
    try {
      player.off('stateChange');
    } catch (_) {
    }
    if (VoiceService.currentPlayer === player) {
      VoiceService.currentPlayer = undefined;
      VoiceService.closeCurrentAudioFile();
    }
    player.release().catch(() => {
    });
  }

  private static closeCurrentAudioFile(): void {
    const sourceFile = VoiceService.currentAudioFile;
    VoiceService.currentAudioFile = undefined;
    if (sourceFile === undefined) {
      return;
    }
    try {
      fileIo.closeSync(sourceFile);
    } catch (_) {
    }
  }

  private static splitSpeechSegments(text: string): string[] {
    const source = VoiceService.toSpeechSourceText(text);
    if (source.length === 0) {
      return [];
    }
    const segments: string[] = [];
    let remaining = source;
    while (remaining.length > 0) {
      let endIndex = VoiceService.findSpeechSegmentEndIndex(remaining, false);
      if (endIndex < 0) {
        endIndex = VoiceService.findSpeechSegmentEndIndex(remaining, true);
      }
      if (endIndex < 0) {
        break;
      }
      const segment = remaining.substring(0, endIndex + 1).trim();
      remaining = remaining.substring(endIndex + 1).trim();
      if (segment.length > 0) {
        segments.push(segment);
      }
    }
    return segments.length > 0 ? segments : [source];
  }

  private static findSpeechSegmentEndIndex(text: string, force: boolean): number {
    let meaningfulCount = 0;
    let lastSoftBreak = -1;
    let lastHardBreak = -1;
    for (let index = 0; index < text.length; index += 1) {
      const ch = text.charAt(index);
      if (VoiceService.isMeaningfulSpeechChar(ch)) {
        meaningfulCount += 1;
      }
      if (SPEECH_HARD_BREAKS.indexOf(ch) >= 0) {
        lastHardBreak = index;
        if (meaningfulCount >= SPEECH_SEGMENT_HARD_BREAK_MIN_CHAR_COUNT) {
          return index;
        }
      }
      if (SPEECH_SOFT_BREAKS.indexOf(ch) >= 0) {
        lastSoftBreak = index;
        if (meaningfulCount >= SPEECH_SEGMENT_TARGET_CHAR_COUNT) {
          return index;
        }
      }
      if (meaningfulCount >= SPEECH_SEGMENT_MAX_CHAR_COUNT) {
        if (lastSoftBreak >= 0) {
          return lastSoftBreak;
        }
        if (lastHardBreak >= 0) {
          return lastHardBreak;
        }
        return index;
      }
    }
    return force ? text.length - 1 : -1;
  }

  private static toSpeechSourceText(value: string): string {
    let text = value.replace(/```[\s\S]*?```/g, ' ');
    text = text.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1');
    text = text.replace(/`([^`]*)`/g, '$1');
    text = text.replace(/https?:\/\/\S+/g, ' ');
    text = text.replace(/^\s{0,3}#{1,6}\s*/gm, '');
    text = text.replace(/^\s*(?:[-*+]\s+|\d+[.)、]\s*)/gm, '');
    text = text.replace(/[`*_~>#\[\]{}()（）"“”‘’'「」『』【】《》<>|\\\/]+/g, ' ');
    text = VoiceService.removeSymbolEmoji(text);
    text = text.replace(/\s+/g, ' ');
    return text.trim();
  }

  private static toTtsInputText(value: string): string {
    let text = VoiceService.toSpeechSourceText(value);
    text = text.replace(/[.!?。！？]{4,}/g, '。');
    text = text.replace(/[,，、]{3,}/g, '、');
    text = text.replace(/[:：]{3,}/g, '：');
    return text.trim();
  }

  private static removeSymbolEmoji(value: string): string {
    let output = '';
    for (let index = 0; index < value.length; index += 1) {
      const code = value.charCodeAt(index);
      if (code >= 0xD800 && code <= 0xDFFF) {
        continue;
      }
      if (code >= 0x2600 && code <= 0x27BF) {
        continue;
      }
      output += value.charAt(index);
    }
    return output;
  }

  private static hasJapaneseKana(value: string): boolean {
    for (let index = 0; index < value.length; index += 1) {
      const code = value.charCodeAt(index);
      if (code >= 0x3040 && code <= 0x30FF) {
        return true;
      }
    }
    return false;
  }

  private static isMeaningfulSpeechChar(value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    const code = value.charCodeAt(0);
    if (code >= 0x30 && code <= 0x39) {
      return true;
    }
    if (code >= 0x41 && code <= 0x5A) {
      return true;
    }
    if (code >= 0x61 && code <= 0x7A) {
      return true;
    }
    if (code >= 0x3040 && code <= 0x30FF) {
      return true;
    }
    if (code >= 0x3400 && code <= 0x9FFF) {
      return true;
    }
    return false;
  }

  private static responseBodyToArrayBuffer(result: string | Object | ArrayBuffer, resultType: http.HttpDataType): ArrayBuffer {
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

  private static responseBodyToText(result: string | Object | ArrayBuffer, resultType: http.HttpDataType): string {
    if (typeof result === 'string') {
      return result;
    }
    if (result instanceof ArrayBuffer || resultType === http.HttpDataType.ARRAY_BUFFER) {
      try {
        return buffer.from(result as ArrayBuffer).toString('utf-8');
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

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}

function createVoiceResult(ok: boolean, filePath: string, error: string): VoicePlaybackResult {
  return {
    ok,
    filePath,
    error,
  };
}

function createSpeechSegmentResult(index: number, text: string, filePath: string, error: string): SpeechSegmentResult {
  return {
    index,
    text,
    filePath,
    error,
  };
}

function createVoicePlaybackProgress(firstFilePath: string, firstError: string, playedCount: number): VoicePlaybackProgress {
  return {
    firstFilePath,
    firstError,
    playedCount,
  };
}

function createTranslationMessage(role: string, content: string): TranslationMessage {
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

function resolveFastRequestModel(config: ChatCompletionModeConfig): string {
  const model = config.model.length > 0 ? config.model : config.defaultModel;
  if (!isDeepSeekProvider(config)) {
    return model;
  }
  if (containsIgnoreCase(model, 'reasoner')) {
    return 'deepseek-chat';
  }
  return model;
}

function applyFastModeParameters(payload: TranslationPayload, config: ChatCompletionModeConfig, requestModel: string): void {
  if (isMiMoProvider(config, requestModel)) {
    payload.thinking = createThinkingPayload('disabled');
    payload.top_p = 0.95;
    payload.temperature = 0.3;
    payload.max_completion_tokens = 384;
    return;
  }
  if (isOpenRouterProvider(config)) {
    payload.reasoning = createReasoningPayload('none', true);
    payload.max_tokens = 384;
    payload.temperature = 0.3;
    return;
  }
  if (isDashScopeProvider(config, requestModel)) {
    payload.enable_thinking = false;
    payload.max_tokens = 384;
    payload.temperature = 0.3;
    return;
  }
  if (isDeepSeekProvider(config)) {
    payload.max_tokens = 384;
    payload.temperature = 0.3;
    return;
  }
  if (isOpenAiProvider(config, requestModel)) {
    if (isOpenAiReasoningModel(requestModel)) {
      payload.reasoning_effort = 'minimal';
      payload.max_completion_tokens = 384;
    } else {
      payload.max_tokens = 384;
      payload.temperature = 0.3;
    }
    return;
  }
  payload.max_tokens = 384;
  payload.temperature = 0.3;
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

function multipartTextField(boundary: string, name: string, value: string): string {
  return `--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`;
}

function boundedNumber(value: number, fallback: number, minimum: number, maximum: number): number {
  if (!Number.isFinite(value)) {
    return fallback;
  }
  return Math.min(Math.max(value, minimum), maximum);
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
