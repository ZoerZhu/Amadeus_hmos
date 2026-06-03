import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import {
  PersonaPreset,
  VoiceSettings,
} from '../model/AppModels';
import { KURISU_REFERENCE_TEXT } from '../persona/PersonaPresets';
import { cleanDisplayText } from './AppUtils';

const SILICONFLOW_SPEECH_ENDPOINT = 'https://api.siliconflow.cn/v1/audio/speech';
const SILICONFLOW_TTS_MODEL = 'FunAudioLLM/CosyVoice2-0.5B';
const DEFAULT_REFERENCE_AUDIO = 'voices/kurisu-reference.mp3';
const OUTPUT_FILE_NAME = 'amaduse_voice.mp3';
const PLAYER_STATE_TIMEOUT_MS = 8000;

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
  ): Promise<VoicePlaybackResult> {
    const input = cleanDisplayText(text).trim();
    if (input.length === 0) {
      return createVoiceResult(false, '', '没有可播放的文本。');
    }
    if (settings.siliconFlowApiKey.trim().length === 0) {
      return createVoiceResult(false, '', '需要先在设置中填写 SiliconFlow API Key。');
    }

    await VoiceService.stopCurrentPlayer();

    const audioData = await VoiceService.requestSpeech(context, input, persona, settings);
    const filePath = VoiceService.writeAudioFile(context, audioData);
    await VoiceService.playAudioFile(filePath);
    return createVoiceResult(true, filePath, '');
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

  private static async requestSpeech(
    context: common.UIAbilityContext,
    input: string,
    persona: PersonaPreset,
    settings: VoiceSettings,
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
      speed: 1.0,
      gain: 0,
    };
    if (voiceUri.length === 0) {
      const reference: SpeechReference = {
        audio: VoiceService.referenceAudioDataUrl(context, persona, settings),
        text: KURISU_REFERENCE_TEXT,
      };
      payload.references = [reference];
    }
    return payload;
  }

  private static referenceAudioDataUrl(
    context: common.UIAbilityContext,
    persona: PersonaPreset,
    settings: VoiceSettings,
  ): string {
    const configuredPath = VoiceService.normalizeRawfilePath(settings.referenceAudioSource);
    const personaPath = VoiceService.normalizeRawfilePath(persona.referenceAudioAsset);
    const rawPath = configuredPath.length > 0 ? configuredPath : (personaPath.length > 0 ? personaPath : DEFAULT_REFERENCE_AUDIO);
    const rawData = context.resourceManager.getRawFileContentSync(rawPath);
    const encoded = buffer.from(rawData).toString('base64');
    return `data:audio/mpeg;base64,${encoded}`;
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

  private static writeAudioFile(context: common.UIAbilityContext, audioData: ArrayBuffer): string {
    const filePath = `${context.cacheDir}/${OUTPUT_FILE_NAME}`;
    const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, audioData);
    } finally {
      fileIo.closeSync(file);
    }
    return filePath;
  }

  private static async playAudioFile(filePath: string): Promise<void> {
    const sourceFile = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
    const player = await media.createAVPlayer();
    VoiceService.currentPlayer = player;
    VoiceService.currentAudioFile = sourceFile;
    const onStateChange: media.OnAVPlayerStateChangeHandle = (state: media.AVPlayerState): void => {
      if (state === 'completed' || state === 'stopped' || state === 'error') {
        VoiceService.releasePlayer(player);
      }
    };
    player.on('stateChange', onStateChange);
    const initialized = VoiceService.waitForPlayerState(player, 'initialized', 'prepared');
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
    await player.play();
  }

  private static waitForPlayerState(
    player: media.AVPlayer,
    stateA: media.AVPlayerState,
    stateB: media.AVPlayerState,
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
        }, PLAYER_STATE_TIMEOUT_MS);
      } catch (error) {
        finish(error instanceof Error ? error.message : String(error));
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
}

function createVoiceResult(ok: boolean, filePath: string, error: string): VoicePlaybackResult {
  return {
    ok,
    filePath,
    error,
  };
}
