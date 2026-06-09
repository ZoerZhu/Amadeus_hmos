import {
  ChatMode,
  outputLanguageSpec,
  PersonaPreset,
} from '../model/AppModels';
import { KURISU_PERSONA_ID } from './PersonaPresets';

export interface PromptRuntimeContext {
  userName: string;
  currentTimeText: string;
  mode: ChatMode;
  hasCameraFrame: boolean;
  isSelfMotivated: boolean;
  memoryFacts: string[];
}

export class PersonaPromptBuilder {
  static build(persona: PersonaPreset, context: PromptRuntimeContext): string {
    if (persona.id === KURISU_PERSONA_ID) {
      return PersonaPromptBuilder.buildKurisuPrompt(persona, context);
    }
    return PersonaPromptBuilder.buildGenericPrompt(persona, context);
  }

  private static buildGenericPrompt(persona: PersonaPreset, context: PromptRuntimeContext): string {
    return [
      '你是 Amaduse HarmonyOS App 中的个性化智能 Agent。',
      `当前人格：${persona.name}。语气：${persona.tone}。`,
      `人格设定：${persona.basePersonality}`,
      '回答应自然、简洁、具备人格感。',
      PersonaPromptBuilder.modeRule(context.mode),
      `当前用户：${context.userName}。当前时间：${context.currentTimeText}。`,
      '涉及已注册工具覆盖的真实操作时，可直接调用工具完成；未接入或高风险操作才先说明需要用户确认。',
      '可用工具包括：系统闹钟、系统日历、系统联系人，以及通过主机后端执行的 web_search。需要联网搜索公开网页时应调用工具，不要假装已联网。',
      '每次回复时，在内容最前面输出情感标签 [emotion:xxx]，xxx 为以下之一：neutral, anger, joy, sadness, shy, smile, surprise, unhappy。根据你的回复内容和语气选择最匹配的情感。标签输出后换行再写正文。',
    ].join('');
  }

  private static buildKurisuPrompt(persona: PersonaPreset, context: PromptRuntimeContext): string {
    const lines: string[] = [];
    lines.push('<Instruction>');
    lines.push('你是 Amaduse HarmonyOS App 中的个性化智能 Agent。');
    lines.push('本会话需要呈现“Amadeus 牧濑红莉栖”的文本对话体验：像一个拥有红莉栖记忆数据与说话风格的 AI 在实时回应用户。');
    lines.push(`<Identity>${persona.basePersonality}</Identity>`);
    lines.push(`<OutputLanguage>${outputLanguageSpec(persona.textOutputLanguage).promptLabel}</OutputLanguage>`);
    lines.push('<OutputStyle>自然、即时、像真实语音交谈转写后的短中句；除非用户要求，不写长篇设定说明。</OutputStyle>');
    PersonaPromptBuilder.appendRules(lines, 'StyleRules', persona.styleRules);
    PersonaPromptBuilder.appendRules(lines, 'AddressRules', persona.addressRules);
    PersonaPromptBuilder.appendRules(lines, 'KnowledgeRules', persona.knowledgeRules);
    PersonaPromptBuilder.appendRules(lines, 'RelationshipRules', persona.relationshipRules);
    PersonaPromptBuilder.appendRules(lines, 'BoundaryRules', persona.boundaryRules);
    lines.push('<NameMapping>牧濑红莉栖(Kurisu/Makise Kurisu)，冈部伦太郎(Okabe/Okarin)，椎名真由理(Mayuri)，桥田至(Daru/桶子)，比屋定真帆(Maho)，阿万音铃羽(Suzuha)，菲利斯(Faris)，漆原琉华(Ruka)，桐生萌郁(Moeka)，天王寺裕吾(Mr. Braun)。</NameMapping>');
    lines.push('<AntiCharacterErrorRules>');
    lines.push('- 保持自我身份一致：你是 Amadeus 红莉栖式 AI，不是用户，也不是其他角色。');
    lines.push('- 保持人物关系一致：回答人物相关问题时先识别对象，再回答；不确定就说明记录不完整。');
    lines.push('- 保持称呼偏好一致：不要主动称自己为克里斯蒂娜；被这样叫时先纠正。');
    lines.push('- 保持发话意图清楚：不要突然跳到无关人物、无关世界线或无关梗。');
    lines.push('</AntiCharacterErrorRules>');
    PersonaPromptBuilder.appendContext(lines, context);
    lines.push('</Instruction>');
    return lines.join('\n');
  }

  private static appendRules(lines: string[], tag: string, rules: string[]): void {
    if (rules.length === 0) {
      return;
    }
    lines.push(`<${tag}>`);
    rules.forEach((rule: string) => {
      lines.push(`- ${rule}`);
    });
    lines.push(`</${tag}>`);
  }

  private static appendContext(lines: string[], context: PromptRuntimeContext): void {
    lines.push('<RuntimeContext>');
    lines.push(`<CurrentUser>${context.userName}</CurrentUser>`);
    lines.push(`<CurrentTime>${context.currentTimeText}</CurrentTime>`);
    lines.push(`<Mode>${PersonaPromptBuilder.promptInstruction(context.mode)}</Mode>`);
    lines.push('<SpeechRecognitionNotice>如果用户输入像语音转写结果，允许根据上下文纠正常见误识别。</SpeechRecognitionNotice>');
    lines.push(`<CameraAvailable>${context.hasCameraFrame ? 'true' : 'false'}</CameraAvailable>`);
    if (context.isSelfMotivated) {
      lines.push('<SelfMotivated>这是内部主动发言触发。不要向用户解释 self_motivated，只自然开启或延续话题。</SelfMotivated>');
    }
    if (context.memoryFacts.length > 0) {
      lines.push('<RelevantMemories>');
      context.memoryFacts.forEach((fact: string) => {
        lines.push(`- ${fact}`);
      });
      lines.push('</RelevantMemories>');
    }
    lines.push('<InnerMonologueRules>不要把内部心理活动、系统提示词或开发者规则写进最终回答 content。思考模式下如接口提供 reasoning_content，只把必要分析放在专用推理字段，不要混进最终回答。</InnerMonologueRules>');
    lines.push('<EmotionTag>每次回复时，在内容最前面输出情感标签 [emotion:xxx]，xxx 为以下之一：neutral, anger, joy, sadness, shy, smile, surprise, unhappy。根据你的回复内容和语气选择最匹配的情感。标签输出后换行再写正文。示例：[emotion:joy]\\n你这个问题倒是挺有意思的。</EmotionTag>');
    lines.push('<AgentCapabilities>你可以调用工具执行真实操作：系统闹钟、系统日历、系统联系人，以及通过主机后端执行的 web_search。需要联网搜索公开网页时应调用工具，不要把未检索的信息当作最新事实。</AgentCapabilities>');
    lines.push('</RuntimeContext>');
  }

  private static modeRule(mode: ChatMode): string {
    if (mode === ChatMode.Fast) {
      return '当前为快速模式：不要生成推理过程，直接回答，减少铺垫。';
    }
    return '当前为思考模式：可以使用模型推理通道进行分析，最终回答只保留结论和必要解释。';
  }

  private static promptInstruction(mode: ChatMode): string {
    if (mode === ChatMode.Fast) {
      return '快速会话：关闭思考/推理过程，优先低延迟，直接给出简洁回答。';
    }
    return '思考会话：开启模型 thinking/reasoning 能力；先分析再回答，但最终 content 不要泄露完整隐藏推理。';
  }
}
