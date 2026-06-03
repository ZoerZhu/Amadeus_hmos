export const TOOL_NAME_ALARM: string = 'alarm_tool';
export const TOOL_NAME_CALENDAR: string = 'calendar_schedule_tool';
export const TOOL_NAME_CONTACT: string = 'contact_tool';
export const TOOL_NAME_HOST_AGENT: string = 'host_agent_tool';

export interface AgentToolFunctionDescriptor {
  name: string;
  description: string;
  parameters: AgentToolParameters;
}

export interface AgentToolDefinition {
  type: string;
  'function': AgentToolFunctionDescriptor;
}

export interface AgentToolCall {
  id: string;
  name: string;
  argumentsJson: string;
  displayName: string;
  displayDetail: string;
}

export interface AgentToolResult {
  toolCallId: string;
  toolName: string;
  displayName: string;
  ok: boolean;
  summary: string;
  content: string;
}

export interface AgentToolCallbacks {
  onToolCallStart: (call: AgentToolCall) => void;
  onToolCallFinish: (result: AgentToolResult) => void;
  executeTool: (call: AgentToolCall) => Promise<AgentToolResult>;
}

interface ToolArgumentPreview {
  action?: string;
  id?: string;
  title?: string;
  time?: string;
  start_time?: string;
  end_time?: string;
  name?: string;
  phone?: string;
  query?: string;
  target_type?: string;
  target?: string;
  intent?: string;
}

interface AgentToolSchemaProperty {
  type: string;
  description: string;
}

interface AgentToolParameterProperties {
  action?: AgentToolSchemaProperty;
  id?: AgentToolSchemaProperty;
  title?: AgentToolSchemaProperty;
  time?: AgentToolSchemaProperty;
  repeat?: AgentToolSchemaProperty;
  enabled?: AgentToolSchemaProperty;
  notes?: AgentToolSchemaProperty;
  query?: AgentToolSchemaProperty;
  start_time?: AgentToolSchemaProperty;
  end_time?: AgentToolSchemaProperty;
  location?: AgentToolSchemaProperty;
  name?: AgentToolSchemaProperty;
  phone?: AgentToolSchemaProperty;
  email?: AgentToolSchemaProperty;
  organization?: AgentToolSchemaProperty;
  target_type?: AgentToolSchemaProperty;
  target?: AgentToolSchemaProperty;
  intent?: AgentToolSchemaProperty;
  payload_json?: AgentToolSchemaProperty;
  endpoint_path?: AgentToolSchemaProperty;
}

interface AgentToolParameters {
  type: string;
  additionalProperties: boolean;
  properties: AgentToolParameterProperties;
  required: string[];
}

interface FallbackToolArguments {
  action: string;
  id?: string;
  title?: string;
  time?: string;
  repeat?: string;
  enabled?: boolean;
  notes?: string;
  query?: string;
  start_time?: string;
  end_time?: string;
  location?: string;
  name?: string;
  phone?: string;
  email?: string;
  organization?: string;
  target_type?: string;
  target?: string;
  intent?: string;
  payload_json?: string;
  endpoint_path?: string;
}

export function createAgentToolDefinitions(): AgentToolDefinition[] {
  const definitions: AgentToolDefinition[] = [];
  definitions.push(createToolDefinition(
    TOOL_NAME_ALARM,
    '管理系统闹钟提醒。支持 add、update、delete、query。没有明确时间或目标时不要调用，先向用户追问。',
    createAlarmToolParameters(),
  ));
  definitions.push(createToolDefinition(
    TOOL_NAME_CALENDAR,
    '管理系统日历日程。支持 add、update、delete、query。没有明确日程标题或时间时不要调用，先向用户追问。',
    createCalendarToolParameters(),
  ));
  definitions.push(createToolDefinition(
    TOOL_NAME_CONTACT,
    '管理系统联系人。支持 add、update、delete、query。没有明确联系人姓名或查询条件时不要调用，先向用户追问。',
    createContactToolParameters(),
  ));
  definitions.push(createToolDefinition(
    TOOL_NAME_HOST_AGENT,
    '把前端无法直接完成的任务转发给用户配置的主机后端工具或后端 Agent。适合电脑文件、命令、脚本、搜索、浏览器、MCP、LangGraph 或其他后端能力。普通聊天不要调用；缺少任务目标时先追问。payload_json 必须是 JSON object 字符串。',
    createHostAgentToolParameters(),
  ));
  return definitions;
}

function createToolDefinition(name: string, description: string, parameters: AgentToolParameters): AgentToolDefinition {
  const fn: AgentToolFunctionDescriptor = {
    name,
    description,
    parameters,
  };
  return {
    type: 'function',
    'function': fn,
  };
}

function createAlarmToolParameters(): AgentToolParameters {
  const properties: AgentToolParameterProperties = {
    action: createSchemaProperty('string', '要执行的操作，只能是 add、update、delete、query。'),
    id: createSchemaProperty('string', '修改或删除时优先使用的闹钟 id。'),
    title: createSchemaProperty('string', '闹钟标题，例如 起床、吃药、开会。'),
    time: createSchemaProperty('string', '闹钟时间，尽量使用 YYYY-MM-DD HH:mm 或 HH:mm。'),
    repeat: createSchemaProperty('string', '重复规则，例如 once、daily、weekdays、weekly 或中文描述。'),
    enabled: createSchemaProperty('boolean', '闹钟是否启用。'),
    notes: createSchemaProperty('string', '补充说明。'),
    query: createSchemaProperty('string', '查询、修改或删除时用于匹配标题、时间、说明的关键词。'),
  };
  return createToolParameters(properties);
}

function createCalendarToolParameters(): AgentToolParameters {
  const properties: AgentToolParameterProperties = {
    action: createSchemaProperty('string', '要执行的操作，只能是 add、update、delete、query。'),
    id: createSchemaProperty('string', '修改或删除时优先使用的日程 id。'),
    title: createSchemaProperty('string', '日程标题。'),
    start_time: createSchemaProperty('string', '开始时间，尽量使用 YYYY-MM-DD HH:mm。'),
    end_time: createSchemaProperty('string', '结束时间，尽量使用 YYYY-MM-DD HH:mm。'),
    location: createSchemaProperty('string', '地点。'),
    notes: createSchemaProperty('string', '补充说明。'),
    query: createSchemaProperty('string', '查询、修改或删除时用于匹配标题、时间、地点、说明的关键词。'),
  };
  return createToolParameters(properties);
}

function createContactToolParameters(): AgentToolParameters {
  const properties: AgentToolParameterProperties = {
    action: createSchemaProperty('string', '要执行的操作，只能是 add、update、delete、query。'),
    id: createSchemaProperty('string', '修改或删除时优先使用的联系人 id。'),
    name: createSchemaProperty('string', '联系人姓名。'),
    phone: createSchemaProperty('string', '电话号码。'),
    email: createSchemaProperty('string', '邮箱。'),
    organization: createSchemaProperty('string', '公司或组织。'),
    notes: createSchemaProperty('string', '补充说明。'),
    query: createSchemaProperty('string', '查询、修改或删除时用于匹配姓名、电话、邮箱、组织、说明的关键词。'),
  };
  return createToolParameters(properties);
}

function createHostAgentToolParameters(): AgentToolParameters {
  const properties: AgentToolParameterProperties = {
    action: createSchemaProperty('string', '要执行的操作，只能是 call_tool、call_agent、query_capabilities。'),
    target_type: createSchemaProperty('string', '目标类型：tool、agent 或 auto。无法确定时填 auto。'),
    target: createSchemaProperty('string', '后端工具名、Agent 名称或能力标识。无法确定时留空，由后端路由。'),
    intent: createSchemaProperty('string', '用户希望主机后端完成的自然语言任务，保留关键约束、文件名、时间、输出格式。'),
    payload_json: createSchemaProperty('string', '传给后端的参数 JSON object 字符串，例如 {"query":"..."}。没有结构化参数时填 {}。'),
    endpoint_path: createSchemaProperty('string', '可选相对路径，例如 /api/agent/invoke。通常留空使用设置页默认路径。'),
  };
  return createToolParameters(properties, ['action', 'intent']);
}

function createToolParameters(properties: AgentToolParameterProperties, required: string[] = ['action']): AgentToolParameters {
  return {
    type: 'object',
    additionalProperties: false,
    properties,
    required,
  };
}

function createSchemaProperty(type: string, description: string): AgentToolSchemaProperty {
  return {
    type,
    description,
  };
}

export function isSupportedAgentTool(name: string): boolean {
  return name === TOOL_NAME_ALARM ||
    name === TOOL_NAME_CALENDAR ||
    name === TOOL_NAME_CONTACT ||
    name === TOOL_NAME_HOST_AGENT;
}

export function createAgentToolCall(id: string, name: string, argumentsJson: string): AgentToolCall {
  return {
    id: id.length > 0 ? id : `tool-${Date.now().toString(36)}`,
    name,
    argumentsJson,
    displayName: agentToolDisplayName(name),
    displayDetail: summarizeToolArguments(name, argumentsJson),
  };
}

export function createFallbackAgentToolCall(text: string): AgentToolCall | undefined {
  const normalized = text.toLowerCase();
  let toolName = '';
  if (containsAny(normalized, [
    '主机', '后端', '电脑', 'pc', 'agent', 'mcp', '调用工具', '工具调用',
    '终端', '命令', '脚本', '运行代码', '执行代码', '联网', '搜索', '网页',
  ])) {
    toolName = TOOL_NAME_HOST_AGENT;
  } else if (containsAny(normalized, ['联系人', '通讯录', '电话', '手机号', '邮箱'])) {
    toolName = TOOL_NAME_CONTACT;
  } else if (containsAny(normalized, ['日程', '日历', '会议', '行程', '安排'])) {
    toolName = TOOL_NAME_CALENDAR;
  } else if (containsAny(normalized, ['闹钟', '提醒我', '叫醒我'])) {
    toolName = TOOL_NAME_ALARM;
  }
  if (toolName.length === 0) {
    return undefined;
  }
  const action = inferAction(normalized);
  let args: FallbackToolArguments = {
    action,
    query: text,
  };
  if (toolName === TOOL_NAME_ALARM) {
    args = {
      action,
      title: text,
      time: extractClockTime(text),
      repeat: 'once',
      query: text,
    };
  }
  if (toolName === TOOL_NAME_CALENDAR) {
    args = {
      action,
      title: text,
      start_time: '',
      end_time: '',
      query: text,
    };
  }
  if (toolName === TOOL_NAME_CONTACT) {
    args = {
      action,
      name: extractContactName(text),
      phone: extractPhone(text),
      query: text,
    };
  }
  if (toolName === TOOL_NAME_HOST_AGENT) {
    args = {
      action: inferHostAction(normalized),
      target_type: 'auto',
      target: '',
      intent: text,
      payload_json: '{}',
      endpoint_path: '',
      query: text,
    };
  }
  return createAgentToolCall('', toolName, JSON.stringify(args));
}

export function agentToolDisplayName(name: string): string {
  if (name === TOOL_NAME_ALARM) {
    return '闹钟工具';
  }
  if (name === TOOL_NAME_CALENDAR) {
    return '日历日程工具';
  }
  if (name === TOOL_NAME_CONTACT) {
    return '联系人工具';
  }
  if (name === TOOL_NAME_HOST_AGENT) {
    return '主机后端 Agent';
  }
  return name;
}

export function agentToolActionLabel(action: string): string {
  const normalized = action.toLowerCase();
  if (normalized === 'add') {
    return '添加';
  }
  if (normalized === 'update') {
    return '修改';
  }
  if (normalized === 'delete') {
    return '删除';
  }
  if (normalized === 'query') {
    return '查询';
  }
  if (normalized === 'call_tool') {
    return '调用工具';
  }
  if (normalized === 'call_agent') {
    return '调用 Agent';
  }
  if (normalized === 'query_capabilities') {
    return '查询能力';
  }
  return action.length > 0 ? action : '执行';
}

function summarizeToolArguments(name: string, argumentsJson: string): string {
  const args = parseArgumentPreview(argumentsJson);
  const action = agentToolActionLabel(stringValue(args.action));
  const parts: string[] = [action];
  if (name === TOOL_NAME_ALARM) {
    parts.push('闹钟');
    appendIfPresent(parts, stringValue(args.title));
    appendIfPresent(parts, stringValue(args.time));
  } else if (name === TOOL_NAME_CALENDAR) {
    parts.push('日程');
    appendIfPresent(parts, stringValue(args.title));
    appendIfPresent(parts, stringValue(args.start_time));
  } else if (name === TOOL_NAME_CONTACT) {
    parts.push('联系人');
    appendIfPresent(parts, stringValue(args.name));
    appendIfPresent(parts, stringValue(args.phone));
  } else if (name === TOOL_NAME_HOST_AGENT) {
    parts.push('主机后端');
    appendIfPresent(parts, stringValue(args.target_type));
    appendIfPresent(parts, stringValue(args.target));
    appendIfPresent(parts, stringValue(args.intent));
  }
  appendIfPresent(parts, stringValue(args.query));
  return parts.join(' · ');
}

function parseArgumentPreview(argumentsJson: string): ToolArgumentPreview {
  try {
    return JSON.parse(argumentsJson) as ToolArgumentPreview;
  } catch (_) {
    return {};
  }
}

function inferAction(text: string): string {
  if (containsAny(text, ['删除', '删掉', '取消', '移除', 'delete'])) {
    return 'delete';
  }
  if (containsAny(text, ['修改', '改成', '更新', '变更', 'update'])) {
    return 'update';
  }
  if (containsAny(text, ['查询', '查一下', '查找', '看看', '列出', '有没有', 'query', 'search'])) {
    return 'query';
  }
  return 'add';
}

function inferHostAction(text: string): string {
  if (containsAny(text, ['有什么工具', '哪些工具', '能力列表', '可用能力', 'capabilities', 'list_tools'])) {
    return 'query_capabilities';
  }
  if (containsAny(text, ['agent', '智能体', '代理'])) {
    return 'call_agent';
  }
  return 'call_tool';
}

function extractClockTime(text: string): string {
  const match = /(\d{1,2})[:：](\d{2})/.exec(text);
  if (match === null || match.length < 3) {
    return '';
  }
  return `${match[1].padStart(2, '0')}:${match[2]}`;
}

function extractPhone(text: string): string {
  const match = /1\d{10}/.exec(text);
  if (match === null || match.length === 0) {
    return '';
  }
  return match[0];
}

function extractContactName(text: string): string {
  const marker = '联系人';
  const index = text.indexOf(marker);
  if (index < 0) {
    return '';
  }
  return text.substring(index + marker.length).replace(/[，。,.]/g, ' ').trim().split(' ')[0];
}

function containsAny(value: string, parts: string[]): boolean {
  return parts.some((part: string): boolean => value.indexOf(part) >= 0);
}

function appendIfPresent(parts: string[], value: string): void {
  if (value.length > 0 && parts.indexOf(value) < 0) {
    parts.push(value);
  }
}

function stringValue(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}
