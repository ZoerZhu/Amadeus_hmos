import {
  abilityAccessCtrl,
  common,
  PermissionRequestResult,
  Permissions,
} from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { calendarManager } from '@kit.CalendarKit';
import { contact } from '@kit.ContactsKit';
import {
  AgentToolCall,
  AgentToolResult,
  agentToolActionLabel,
  agentToolDisplayName,
  TOOL_NAME_ALARM,
  TOOL_NAME_CALENDAR,
  TOOL_NAME_CONTACT,
  TOOL_NAME_HOST_AGENT,
} from './AgentTools';
import { HostAgentToolService } from './HostAgentToolService';
import {
  createId,
  currentPromptTimeText,
} from '../services/AppUtils';

const STORE_NAME = 'amaduse_system_tools';
const KEY_ALARM_BINDINGS = 'alarm_bindings';
const KEY_CALENDAR_BINDINGS = 'calendar_bindings';
const KEY_CONTACT_BINDINGS = 'contact_bindings';
const DEFAULT_CALENDAR_NAME = 'Amaduse';
const DEFAULT_EVENT_DURATION_MS = 60 * 60 * 1000;

interface ToolArguments {
  action?: string;
  id?: string;
  title?: string;
  time?: string;
  repeat?: string;
  enabled?: boolean;
  start_time?: string;
  end_time?: string;
  location?: string;
  name?: string;
  phone?: string;
  email?: string;
  organization?: string;
  notes?: string;
  query?: string;
}

interface AlarmBinding {
  id: string;
  reminderId: number;
  title: string;
  time: string;
  repeat: string;
  notes: string;
  updatedAt: string;
}

interface CalendarBinding {
  id: string;
  eventId: number;
  title: string;
  updatedAt: string;
}

interface ContactBinding {
  id: string;
  contactId: number;
  key: string;
  name: string;
  updatedAt: string;
}

interface AlarmItem {
  id: string;
  reminderId: number;
  title: string;
  time: string;
  repeat: string;
  notes: string;
  updatedAt: string;
}

interface CalendarScheduleItem {
  id: string;
  eventId: number;
  title: string;
  startTime: string;
  endTime: string;
  location: string;
  notes: string;
  updatedAt: string;
}

interface ContactItem {
  id: string;
  contactId: number;
  key: string;
  name: string;
  phone: string;
  email: string;
  organization: string;
  notes: string;
  updatedAt: string;
}

interface ToolPayload {
  ok: boolean;
  tool: string;
  action: string;
  summary: string;
  item?: Object;
  items?: Object[];
  error?: string;
}

interface ParsedDateTime {
  ok: boolean;
  value: Date;
  normalized: string;
}

interface ClockParts {
  ok: boolean;
  hour: number;
  minute: number;
  normalized: string;
}

export class LocalToolService {
  private static store?: preferences.Preferences;

  private static getStore(context: common.UIAbilityContext): preferences.Preferences {
    if (LocalToolService.store === undefined) {
      LocalToolService.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    }
    return LocalToolService.store;
  }

  static async execute(context: common.UIAbilityContext, call: AgentToolCall): Promise<AgentToolResult> {
    const args = parseToolArguments(call.argumentsJson);
    try {
      if (call.name === TOOL_NAME_ALARM) {
        return await LocalToolService.executeAlarm(context, call, args);
      }
      if (call.name === TOOL_NAME_CALENDAR) {
        return await LocalToolService.executeCalendar(context, call, args);
      }
      if (call.name === TOOL_NAME_CONTACT) {
        return await LocalToolService.executeContact(context, call, args);
      }
      if (call.name === TOOL_NAME_HOST_AGENT) {
        return await HostAgentToolService.execute(context, call);
      }
      return createFailureResult(call, normalizedAction(args.action), `不支持的工具：${call.name}`, 'unsupported_tool');
    } catch (error) {
      const detail = errorToString(error);
      return createFailureResult(call, normalizedAction(args.action), `系统工具调用失败：${detail}`, detail);
    }
  }

  private static async executeAlarm(
    context: common.UIAbilityContext,
    call: AgentToolCall,
    args: ToolArguments,
  ): Promise<AgentToolResult> {
    const action = normalizedAction(args.action);
    const permissionError = await requestToolPermissions(context, ['ohos.permission.PUBLISH_AGENT_REMINDER']);
    if (permissionError.length > 0) {
      return createFailureResult(call, action, permissionError, 'permission_denied');
    }
    if (action === 'query') {
      const items = await LocalToolService.querySystemAlarms(context, stringValue(args.query));
      const summary = `查询到 ${items.length} 个系统闹钟提醒。`;
      return createSuccessResult(call, action, summary, undefined, items);
    }

    if (action === 'add') {
      const clock = parseClockParts(stringValue(args.time));
      if (!clock.ok) {
        return createFailureResult(call, action, '添加系统闹钟失败：缺少有效时间，格式建议为 HH:mm。', 'invalid_time');
      }
      const id = createId('alarm');
      const request = createAlarmReminderRequest(args, clock);
      const reminderId = await reminderAgentManager.publishReminder(request);
      const binding: AlarmBinding = {
        id,
        reminderId,
        title: stringValue(args.title, '闹钟'),
        time: clock.normalized,
        repeat: stringValue(args.repeat, 'once'),
        notes: stringValue(args.notes),
        updatedAt: currentPromptTimeText(),
      };
      const bindings = await LocalToolService.loadAlarmBindings(context);
      bindings.push(binding);
      await LocalToolService.saveAlarmBindings(context, bindings);
      const item = alarmBindingToItem(binding);
      const summary = `已添加系统闹钟提醒：${item.title}，时间 ${item.time}。`;
      return createSuccessResult(call, action, summary, item);
    }

    const target = await LocalToolService.findAlarmBinding(context, args);
    if (target.id.length === 0 || target.reminderId < 0) {
      return createFailureResult(call, action, '没有找到匹配的系统闹钟提醒。', 'not_found');
    }

    if (action === 'delete') {
      await reminderAgentManager.cancelReminder(target.reminderId);
      await LocalToolService.removeAlarmBinding(context, target.reminderId);
      const item = alarmBindingToItem(target);
      const summary = `已删除系统闹钟提醒：${item.title}。`;
      return createSuccessResult(call, action, summary, item);
    }

    const clock = parseClockParts(stringValue(args.time, target.time));
    if (!clock.ok) {
      return createFailureResult(call, action, '修改系统闹钟失败：缺少有效时间，格式建议为 HH:mm。', 'invalid_time');
    }
    const request = createAlarmReminderRequest(args, clock, target);
    await reminderAgentManager.updateReminder(target.reminderId, request);
    const updated: AlarmBinding = {
      id: target.id,
      reminderId: target.reminderId,
      title: stringValue(args.title, target.title),
      time: clock.normalized,
      repeat: stringValue(args.repeat, target.repeat),
      notes: stringValue(args.notes, target.notes),
      updatedAt: currentPromptTimeText(),
    };
    await LocalToolService.upsertAlarmBinding(context, updated);
    const item = alarmBindingToItem(updated);
    const summary = `已修改系统闹钟提醒：${item.title}，时间 ${item.time}。`;
    return createSuccessResult(call, action, summary, item);
  }

  private static async executeCalendar(
    context: common.UIAbilityContext,
    call: AgentToolCall,
    args: ToolArguments,
  ): Promise<AgentToolResult> {
    const action = normalizedAction(args.action);
    const permissionError = await requestToolPermissions(context, calendarPermissions(action));
    if (permissionError.length > 0) {
      return createFailureResult(call, action, permissionError, 'permission_denied');
    }

    const calendar = await getWritableCalendar(context);
    if (action === 'query') {
      const items = await LocalToolService.querySystemSchedules(context, calendar, args);
      const summary = `查询到 ${items.length} 个系统日历日程。`;
      return createSuccessResult(call, action, summary, undefined, items);
    }

    if (action === 'add') {
      const start = parseDateTime(stringValue(args.start_time));
      if (!start.ok) {
        return createFailureResult(call, action, '添加系统日程失败：缺少有效开始时间，格式建议为 YYYY-MM-DD HH:mm。', 'invalid_start_time');
      }
      const end = parseDateTime(stringValue(args.end_time));
      const event = createCalendarEvent(args, start.value.getTime(), end.ok ? end.value.getTime() : start.value.getTime() + DEFAULT_EVENT_DURATION_MS);
      const eventId = await calendar.addEvent(event);
      const binding: CalendarBinding = {
        id: createId('schedule'),
        eventId,
        title: stringValue(args.title, '日程'),
        updatedAt: currentPromptTimeText(),
      };
      const bindings = await LocalToolService.loadCalendarBindings(context);
      bindings.push(binding);
      await LocalToolService.saveCalendarBindings(context, bindings);
      const item = eventToScheduleItem(event, binding.id, eventId);
      const summary = `已添加系统日历日程：${item.title}，开始 ${item.startTime}。`;
      return createSuccessResult(call, action, summary, item);
    }

    const targetEvent = await LocalToolService.findCalendarEvent(context, calendar, args);
    if (targetEvent.id < 0) {
      return createFailureResult(call, action, '没有找到匹配的系统日历日程。', 'not_found');
    }

    if (action === 'delete') {
      await calendar.deleteEvent(targetEvent.id);
      await LocalToolService.removeCalendarBinding(context, targetEvent.id);
      const item = eventToScheduleItem(targetEvent.event, targetEvent.localId, targetEvent.id);
      const summary = `已删除系统日历日程：${item.title}。`;
      return createSuccessResult(call, action, summary, item);
    }

    const updatedEvent = mergeCalendarEvent(targetEvent.event, args);
    await calendar.updateEvent(updatedEvent);
    const localId = targetEvent.localId.length > 0 ? targetEvent.localId : createId('schedule');
    const binding: CalendarBinding = {
      id: localId,
      eventId: targetEvent.id,
      title: stringValue(updatedEvent.title, '日程'),
      updatedAt: currentPromptTimeText(),
    };
    await LocalToolService.upsertCalendarBinding(context, binding);
    const item = eventToScheduleItem(updatedEvent, localId, targetEvent.id);
    const summary = `已修改系统日历日程：${item.title}，开始 ${item.startTime}。`;
    return createSuccessResult(call, action, summary, item);
  }

  private static async executeContact(
    context: common.UIAbilityContext,
    call: AgentToolCall,
    args: ToolArguments,
  ): Promise<AgentToolResult> {
    const action = normalizedAction(args.action);
    const permissionError = await requestToolPermissions(context, contactPermissions(action));
    if (permissionError.length > 0) {
      return createFailureResult(call, action, permissionError, 'permission_denied');
    }

    if (action === 'query') {
      const items = await LocalToolService.querySystemContacts(context, args);
      const summary = `查询到 ${items.length} 个系统联系人。`;
      return createSuccessResult(call, action, summary, undefined, items);
    }

    if (action === 'add') {
      const displayName = stringValue(args.name, '联系人');
      const newContact = createContactInfo(displayName, args);
      const contactId = await contact.addContact(context, newContact);
      const key = contactId >= 0 ? await contact.queryKey(context, contactId) : '';
      const binding: ContactBinding = {
        id: createId('contact'),
        contactId,
        key,
        name: displayName,
        updatedAt: currentPromptTimeText(),
      };
      const bindings = await LocalToolService.loadContactBindings(context);
      bindings.push(binding);
      await LocalToolService.saveContactBindings(context, bindings);
      const item = contactToItem(newContact, binding.id, contactId, key);
      const summary = `已添加系统联系人：${item.name}${item.phone.length > 0 ? `，电话 ${item.phone}` : ''}。`;
      return createSuccessResult(call, action, summary, item);
    }

    const target = await LocalToolService.findContact(context, args);
    if (target.key.length === 0) {
      return createFailureResult(call, action, '没有找到匹配的系统联系人。', 'not_found');
    }

    if (action === 'delete') {
      await contact.deleteContact(context, target.key);
      await LocalToolService.removeContactBinding(context, target.key);
      const item = contactToItem(target.contactInfo, target.localId, target.contactId, target.key);
      const summary = `已删除系统联系人：${item.name}。`;
      return createSuccessResult(call, action, summary, item);
    }

    const updated = mergeContactInfo(target.contactInfo, args);
    await contact.updateContact(context, updated);
    const localId = target.localId.length > 0 ? target.localId : createId('contact');
    const binding: ContactBinding = {
      id: localId,
      contactId: target.contactId,
      key: target.key,
      name: contactDisplayName(updated),
      updatedAt: currentPromptTimeText(),
    };
    await LocalToolService.upsertContactBinding(context, binding);
    const item = contactToItem(updated, localId, target.contactId, target.key);
    const summary = `已修改系统联系人：${item.name}${item.phone.length > 0 ? `，电话 ${item.phone}` : ''}。`;
    return createSuccessResult(call, action, summary, item);
  }

  private static async querySystemAlarms(context: common.UIAbilityContext, query: string): Promise<AlarmItem[]> {
    const reminders = await reminderAgentManager.getAllValidReminders();
    const bindings = await LocalToolService.loadAlarmBindings(context);
    const items: AlarmItem[] = [];
    reminders.forEach((info: reminderAgentManager.ReminderInfo) => {
      if (info.reminderReq.reminderType !== reminderAgentManager.ReminderType.REMINDER_TYPE_ALARM) {
        return;
      }
      const item = reminderInfoToAlarmItem(info, bindings);
      if (query.trim().length === 0 || matchesText(query, item.title, item.time, item.repeat, item.notes)) {
        items.push(item);
      }
    });
    return items.slice(0, 20);
  }

  private static async querySystemSchedules(
    context: common.UIAbilityContext,
    calendar: calendarManager.Calendar,
    args: ToolArguments,
  ): Promise<CalendarScheduleItem[]> {
    const query = stringValue(args.query, stringValue(args.title));
    const events = query.length > 0
      ? await calendar.getEvents(calendarManager.EventFilter.filterByTitle(query))
      : await calendar.getEvents();
    const bindings = await LocalToolService.loadCalendarBindings(context);
    const items: CalendarScheduleItem[] = [];
    events.forEach((event: calendarManager.Event) => {
      const item = eventToScheduleItem(event, calendarLocalId(event.id, bindings), numberValue(event.id, -1));
      if (query.length === 0 || matchesText(query, item.title, item.startTime, item.endTime, item.location, item.notes)) {
        items.push(item);
      }
    });
    return items.slice(0, 20);
  }

  private static async querySystemContacts(context: common.UIAbilityContext, args: ToolArguments): Promise<ContactItem[]> {
    const phone = stringValue(args.phone);
    const email = stringValue(args.email);
    const query = stringValue(args.query, stringValue(args.name));
    let contacts: contact.Contact[] = [];
    if (phone.length > 0) {
      contacts = await contact.queryContactsByPhoneNumber(context, phone);
    } else if (email.length > 0) {
      contacts = await contact.queryContactsByEmail(context, email);
    } else {
      contacts = await contact.queryContacts(context);
    }
    const bindings = await LocalToolService.loadContactBindings(context);
    const items: ContactItem[] = [];
    contacts.forEach((item: contact.Contact) => {
      const contactItem = contactToItem(
        item,
        contactLocalId(stringValue(item.key), bindings),
        numberValue(item.id, -1),
        stringValue(item.key),
      );
      if (query.length === 0 || matchesText(query, contactItem.name, contactItem.phone, contactItem.email, contactItem.organization, contactItem.notes)) {
        items.push(contactItem);
      }
    });
    return items.slice(0, 20);
  }

  private static async findAlarmBinding(context: common.UIAbilityContext, args: ToolArguments): Promise<AlarmBinding> {
    const id = stringValue(args.id);
    const bindings = await LocalToolService.loadAlarmBindings(context);
    const byLocalId = bindings.find((item: AlarmBinding): boolean => item.id === id);
    if (byLocalId !== undefined) {
      return byLocalId;
    }
    const reminderId = numericId(id);
    const byReminderId = bindings.find((item: AlarmBinding): boolean => item.reminderId === reminderId);
    if (byReminderId !== undefined) {
      return byReminderId;
    }
    const query = stringValue(args.query, stringValue(args.title));
    const alarms = await LocalToolService.querySystemAlarms(context, query);
    if (alarms.length === 0) {
      return emptyAlarmBinding();
    }
    const first = alarms[0];
    return {
      id: first.id,
      reminderId: first.reminderId,
      title: first.title,
      time: first.time,
      repeat: first.repeat,
      notes: first.notes,
      updatedAt: first.updatedAt,
    };
  }

  private static async findCalendarEvent(
    context: common.UIAbilityContext,
    calendar: calendarManager.Calendar,
    args: ToolArguments,
  ): Promise<SystemCalendarEvent> {
    const id = stringValue(args.id);
    const bindings = await LocalToolService.loadCalendarBindings(context);
    const localBinding = bindings.find((item: CalendarBinding): boolean => item.id === id);
    let eventId = localBinding !== undefined ? localBinding.eventId : numericId(id);
    if (eventId >= 0) {
      const byId = await calendar.getEvents(calendarManager.EventFilter.filterById([eventId]));
      if (byId.length > 0) {
        return createSystemCalendarEvent(byId[0], eventId, localBinding !== undefined ? localBinding.id : calendarLocalId(eventId, bindings));
      }
    }
    const query = stringValue(args.query, stringValue(args.title));
    const events = query.length > 0
      ? await calendar.getEvents(calendarManager.EventFilter.filterByTitle(query))
      : await calendar.getEvents();
    if (events.length === 0) {
      return emptySystemCalendarEvent();
    }
    eventId = numberValue(events[0].id, -1);
    return createSystemCalendarEvent(events[0], eventId, calendarLocalId(eventId, bindings));
  }

  private static async findContact(context: common.UIAbilityContext, args: ToolArguments): Promise<SystemContact> {
    const id = stringValue(args.id);
    const bindings = await LocalToolService.loadContactBindings(context);
    const localBinding = bindings.find((item: ContactBinding): boolean => item.id === id);
    let key = localBinding !== undefined ? localBinding.key : id;
    if (key.length > 0 && !isNumericString(key)) {
      try {
        const found = await contact.queryContact(context, key);
        return createSystemContact(found, key, numberValue(found.id, localBinding !== undefined ? localBinding.contactId : -1),
          localBinding !== undefined ? localBinding.id : contactLocalId(key, bindings));
      } catch (_) {
      }
    }
    const numeric = numericId(id);
    const byContactId = bindings.find((item: ContactBinding): boolean => item.contactId === numeric);
    if (byContactId !== undefined && byContactId.key.length > 0) {
      const found = await contact.queryContact(context, byContactId.key);
      return createSystemContact(found, byContactId.key, byContactId.contactId, byContactId.id);
    }
    const queryResult = await LocalToolService.querySystemContacts(context, args);
    if (queryResult.length === 0) {
      return emptySystemContact();
    }
    key = queryResult[0].key;
    const found = await contact.queryContact(context, key);
    return createSystemContact(found, key, queryResult[0].contactId, queryResult[0].id);
  }

  private static async loadAlarmBindings(context: common.UIAbilityContext): Promise<AlarmBinding[]> {
    const raw = await LocalToolService.getString(context, KEY_ALARM_BINDINGS);
    if (raw.length === 0) {
      return [];
    }
    try {
      const items = JSON.parse(raw) as AlarmBinding[];
      return Array.isArray(items) ? items.map((item: AlarmBinding): AlarmBinding => normalizeAlarmBinding(item)) : [];
    } catch (_) {
      return [];
    }
  }

  private static async saveAlarmBindings(context: common.UIAbilityContext, bindings: AlarmBinding[]): Promise<void> {
    await LocalToolService.putString(context, KEY_ALARM_BINDINGS, JSON.stringify(bindings));
  }

  private static async upsertAlarmBinding(context: common.UIAbilityContext, binding: AlarmBinding): Promise<void> {
    const bindings = await LocalToolService.loadAlarmBindings(context);
    const index = bindings.findIndex((item: AlarmBinding): boolean => item.reminderId === binding.reminderId || item.id === binding.id);
    if (index >= 0) {
      bindings[index] = binding;
    } else {
      bindings.push(binding);
    }
    await LocalToolService.saveAlarmBindings(context, bindings);
  }

  private static async removeAlarmBinding(context: common.UIAbilityContext, reminderId: number): Promise<void> {
    const bindings = await LocalToolService.loadAlarmBindings(context);
    await LocalToolService.saveAlarmBindings(context, bindings.filter((item: AlarmBinding): boolean => item.reminderId !== reminderId));
  }

  private static async loadCalendarBindings(context: common.UIAbilityContext): Promise<CalendarBinding[]> {
    const raw = await LocalToolService.getString(context, KEY_CALENDAR_BINDINGS);
    if (raw.length === 0) {
      return [];
    }
    try {
      const items = JSON.parse(raw) as CalendarBinding[];
      return Array.isArray(items) ? items.map((item: CalendarBinding): CalendarBinding => normalizeCalendarBinding(item)) : [];
    } catch (_) {
      return [];
    }
  }

  private static async saveCalendarBindings(context: common.UIAbilityContext, bindings: CalendarBinding[]): Promise<void> {
    await LocalToolService.putString(context, KEY_CALENDAR_BINDINGS, JSON.stringify(bindings));
  }

  private static async upsertCalendarBinding(context: common.UIAbilityContext, binding: CalendarBinding): Promise<void> {
    const bindings = await LocalToolService.loadCalendarBindings(context);
    const index = bindings.findIndex((item: CalendarBinding): boolean => item.eventId === binding.eventId || item.id === binding.id);
    if (index >= 0) {
      bindings[index] = binding;
    } else {
      bindings.push(binding);
    }
    await LocalToolService.saveCalendarBindings(context, bindings);
  }

  private static async removeCalendarBinding(context: common.UIAbilityContext, eventId: number): Promise<void> {
    const bindings = await LocalToolService.loadCalendarBindings(context);
    await LocalToolService.saveCalendarBindings(context, bindings.filter((item: CalendarBinding): boolean => item.eventId !== eventId));
  }

  private static async loadContactBindings(context: common.UIAbilityContext): Promise<ContactBinding[]> {
    const raw = await LocalToolService.getString(context, KEY_CONTACT_BINDINGS);
    if (raw.length === 0) {
      return [];
    }
    try {
      const items = JSON.parse(raw) as ContactBinding[];
      return Array.isArray(items) ? items.map((item: ContactBinding): ContactBinding => normalizeContactBinding(item)) : [];
    } catch (_) {
      return [];
    }
  }

  private static async saveContactBindings(context: common.UIAbilityContext, bindings: ContactBinding[]): Promise<void> {
    await LocalToolService.putString(context, KEY_CONTACT_BINDINGS, JSON.stringify(bindings));
  }

  private static async upsertContactBinding(context: common.UIAbilityContext, binding: ContactBinding): Promise<void> {
    const bindings = await LocalToolService.loadContactBindings(context);
    const index = bindings.findIndex((item: ContactBinding): boolean => item.key === binding.key || item.id === binding.id);
    if (index >= 0) {
      bindings[index] = binding;
    } else {
      bindings.push(binding);
    }
    await LocalToolService.saveContactBindings(context, bindings);
  }

  private static async removeContactBinding(context: common.UIAbilityContext, key: string): Promise<void> {
    const bindings = await LocalToolService.loadContactBindings(context);
    await LocalToolService.saveContactBindings(context, bindings.filter((item: ContactBinding): boolean => item.key !== key));
  }

  private static async getString(context: common.UIAbilityContext, key: string): Promise<string> {
    try {
      const value = await LocalToolService.getStore(context).get(key, '');
      return typeof value === 'string' ? value : '';
    } catch (_) {
      return '';
    }
  }

  private static async putString(context: common.UIAbilityContext, key: string, value: string): Promise<void> {
    const store = LocalToolService.getStore(context);
    await store.put(key, value);
    await store.flush();
  }
}

interface SystemCalendarEvent {
  event: calendarManager.Event;
  id: number;
  localId: string;
}

interface SystemContact {
  contactInfo: contact.Contact;
  key: string;
  contactId: number;
  localId: string;
}

function createSuccessResult(
  call: AgentToolCall,
  action: string,
  summary: string,
  item?: Object,
  items?: Object[],
): AgentToolResult {
  const payload: ToolPayload = {
    ok: true,
    tool: call.name,
    action,
    summary,
    item,
    items,
  };
  return createResult(call, true, summary, payload);
}

function createFailureResult(call: AgentToolCall, action: string, summary: string, error: string): AgentToolResult {
  const payload: ToolPayload = {
    ok: false,
    tool: call.name,
    action,
    summary,
    error,
  };
  return createResult(call, false, summary, payload);
}

function createResult(call: AgentToolCall, ok: boolean, summary: string, payload: ToolPayload): AgentToolResult {
  return {
    toolCallId: call.id,
    toolName: call.name,
    displayName: `${agentToolDisplayName(call.name)} · ${agentToolActionLabel(payload.action)}`,
    ok,
    summary,
    content: JSON.stringify(payload),
  };
}

async function requestToolPermissions(context: common.UIAbilityContext, permissions: Permissions[]): Promise<string> {
  if (permissions.length === 0) {
    return '';
  }
  try {
    const manager = abilityAccessCtrl.createAtManager();
    const result: PermissionRequestResult = await manager.requestPermissionsFromUser(context, permissions);
    for (let index = 0; index < result.authResults.length; index += 1) {
      if (result.authResults[index] !== 0) {
        const permission = index < result.permissions.length ? result.permissions[index] : permissions[index];
        return `系统权限未授予：${permission}`;
      }
    }
    return '';
  } catch (error) {
    return `系统权限请求失败：${errorToString(error)}`;
  }
}

function calendarPermissions(action: string): Permissions[] {
  if (action === 'query') {
    return ['ohos.permission.READ_CALENDAR'];
  }
  return ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
}

function contactPermissions(action: string): Permissions[] {
  if (action === 'query') {
    return ['ohos.permission.READ_CONTACTS'];
  }
  return ['ohos.permission.READ_CONTACTS', 'ohos.permission.WRITE_CONTACTS'];
}

async function getWritableCalendar(context: common.UIAbilityContext): Promise<calendarManager.Calendar> {
  const manager = calendarManager.getCalendarManager(context);
  try {
    return await manager.getCalendar();
  } catch (_) {
    const account: calendarManager.CalendarAccount = {
      name: DEFAULT_CALENDAR_NAME,
      type: calendarManager.CalendarType.LOCAL,
      displayName: DEFAULT_CALENDAR_NAME,
    };
    return await manager.createCalendar(account);
  }
}

function createAlarmReminderRequest(
  args: ToolArguments,
  clock: ClockParts,
  previous?: AlarmBinding,
): reminderAgentManager.ReminderRequestAlarm {
  const days = repeatToDaysOfWeek(stringValue(args.repeat, previous === undefined ? 'once' : previous.repeat));
  const request: reminderAgentManager.ReminderRequestAlarm = {
    reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_ALARM,
    hour: clock.hour,
    minute: clock.minute,
    title: stringValue(args.title, previous === undefined ? '闹钟' : previous.title),
    content: stringValue(args.notes, previous === undefined ? 'Amaduse 创建的闹钟提醒' : previous.notes),
    ringDuration: 30,
    snoozeTimes: 1,
    timeInterval: 5,
    tapDismissed: true,
  };
  if (days.length > 0) {
    request.daysOfWeek = days;
  }
  return request;
}

function createCalendarEvent(args: ToolArguments, startTime: number, endTime: number): calendarManager.Event {
  const location: calendarManager.Location = {
    location: stringValue(args.location),
  };
  const event: calendarManager.Event = {
    type: calendarManager.EventType.NORMAL,
    title: stringValue(args.title, '日程'),
    startTime,
    endTime: endTime > startTime ? endTime : startTime + DEFAULT_EVENT_DURATION_MS,
    description: stringValue(args.notes),
    location,
    reminderTime: [10],
  };
  return event;
}

function mergeCalendarEvent(event: calendarManager.Event, args: ToolArguments): calendarManager.Event {
  const start = parseDateTime(stringValue(args.start_time));
  const end = parseDateTime(stringValue(args.end_time));
  const locationValue = stringValue(args.location);
  const location: calendarManager.Location = locationValue.length > 0
    ? { location: locationValue }
    : (event.location === undefined ? { location: '' } : event.location);
  const updated: calendarManager.Event = {
    id: event.id,
    type: event.type,
    title: stringValue(args.title, stringValue(event.title, '日程')),
    startTime: start.ok ? start.value.getTime() : event.startTime,
    endTime: end.ok ? end.value.getTime() : event.endTime,
    isAllDay: event.isAllDay,
    attendee: event.attendee,
    timeZone: event.timeZone,
    reminderTime: event.reminderTime,
    recurrenceRule: event.recurrenceRule,
    description: stringValue(args.notes, stringValue(event.description)),
    location,
    service: event.service,
    identifier: event.identifier,
  };
  if (updated.endTime <= updated.startTime) {
    updated.endTime = updated.startTime + DEFAULT_EVENT_DURATION_MS;
  }
  return updated;
}

function createContactInfo(displayName: string, args: ToolArguments): contact.Contact {
  const name: contact.Name = {
    fullName: displayName,
  };
  const newContact: contact.Contact = {
    name,
  };
  const phone = stringValue(args.phone);
  if (phone.length > 0) {
    const phoneNumber: contact.PhoneNumber = {
      phoneNumber: phone,
      labelId: contact.PhoneNumber.NUM_MOBILE,
    };
    newContact.phoneNumbers = [phoneNumber];
  }
  const email = stringValue(args.email);
  if (email.length > 0) {
    const emailInfo: contact.Email = {
      email,
      labelId: contact.Email.EMAIL_OTHER,
    };
    newContact.emails = [emailInfo];
  }
  const organizationValue = stringValue(args.organization);
  if (organizationValue.length > 0) {
    const organization: contact.Organization = {
      name: organizationValue,
    };
    newContact.organization = organization;
  }
  const notes = stringValue(args.notes);
  if (notes.length > 0) {
    const note: contact.Note = {
      noteContent: notes,
    };
    newContact.note = note;
  }
  return newContact;
}

function mergeContactInfo(current: contact.Contact, args: ToolArguments): contact.Contact {
  const displayName = stringValue(args.name);
  if (displayName.length > 0) {
    const name: contact.Name = {
      fullName: displayName,
    };
    current.name = name;
  }
  const phone = stringValue(args.phone);
  if (phone.length > 0) {
    const phoneNumber: contact.PhoneNumber = {
      phoneNumber: phone,
      labelId: contact.PhoneNumber.NUM_MOBILE,
    };
    current.phoneNumbers = [phoneNumber];
  }
  const email = stringValue(args.email);
  if (email.length > 0) {
    const emailInfo: contact.Email = {
      email,
      labelId: contact.Email.EMAIL_OTHER,
    };
    current.emails = [emailInfo];
  }
  const organizationValue = stringValue(args.organization);
  if (organizationValue.length > 0) {
    const organization: contact.Organization = {
      name: organizationValue,
    };
    current.organization = organization;
  }
  const notes = stringValue(args.notes);
  if (notes.length > 0) {
    const note: contact.Note = {
      noteContent: notes,
    };
    current.note = note;
  }
  return current;
}

function reminderInfoToAlarmItem(info: reminderAgentManager.ReminderInfo, bindings: AlarmBinding[]): AlarmItem {
  const request = info.reminderReq as reminderAgentManager.ReminderRequestAlarm;
  const binding = bindings.find((item: AlarmBinding): boolean => item.reminderId === info.reminderId);
  const time = `${request.hour.toString().padStart(2, '0')}:${request.minute.toString().padStart(2, '0')}`;
  return {
    id: binding === undefined ? `alarm-${info.reminderId}` : binding.id,
    reminderId: info.reminderId,
    title: stringValue(request.title, binding === undefined ? '闹钟' : binding.title),
    time,
    repeat: binding === undefined ? daysOfWeekToRepeat(request.daysOfWeek) : binding.repeat,
    notes: stringValue(request.content, binding === undefined ? '' : binding.notes),
    updatedAt: binding === undefined ? currentPromptTimeText() : binding.updatedAt,
  };
}

function alarmBindingToItem(binding: AlarmBinding): AlarmItem {
  return {
    id: binding.id,
    reminderId: binding.reminderId,
    title: binding.title,
    time: binding.time,
    repeat: binding.repeat,
    notes: binding.notes,
    updatedAt: binding.updatedAt,
  };
}

function eventToScheduleItem(event: calendarManager.Event, localId: string, eventId: number): CalendarScheduleItem {
  return {
    id: localId.length > 0 ? localId : `schedule-${eventId}`,
    eventId,
    title: stringValue(event.title, '日程'),
    startTime: formatDateTime(new Date(event.startTime)),
    endTime: formatDateTime(new Date(event.endTime)),
    location: event.location === undefined ? '' : stringValue(event.location.location),
    notes: stringValue(event.description),
    updatedAt: currentPromptTimeText(),
  };
}

function contactToItem(item: contact.Contact, localId: string, contactId: number, key: string): ContactItem {
  return {
    id: localId.length > 0 ? localId : `contact-${contactId >= 0 ? contactId.toString() : key}`,
    contactId,
    key,
    name: contactDisplayName(item),
    phone: firstPhone(item),
    email: firstEmail(item),
    organization: item.organization === undefined ? '' : stringValue(item.organization.name),
    notes: item.note === undefined ? '' : stringValue(item.note.noteContent),
    updatedAt: currentPromptTimeText(),
  };
}

function contactDisplayName(item: contact.Contact): string {
  if (item.name !== undefined && item.name.fullName.length > 0) {
    return item.name.fullName;
  }
  return '联系人';
}

function firstPhone(item: contact.Contact): string {
  if (item.phoneNumbers === undefined || item.phoneNumbers.length === 0) {
    return '';
  }
  return item.phoneNumbers[0].phoneNumber;
}

function firstEmail(item: contact.Contact): string {
  if (item.emails === undefined || item.emails.length === 0) {
    return '';
  }
  return item.emails[0].email;
}

function createSystemCalendarEvent(event: calendarManager.Event, id: number, localId: string): SystemCalendarEvent {
  return {
    event,
    id,
    localId,
  };
}

function emptySystemCalendarEvent(): SystemCalendarEvent {
  return {
    event: createCalendarEvent({}, Date.now(), Date.now() + DEFAULT_EVENT_DURATION_MS),
    id: -1,
    localId: '',
  };
}

function createSystemContact(contactInfo: contact.Contact, key: string, contactId: number, localId: string): SystemContact {
  return {
    contactInfo,
    key,
    contactId,
    localId,
  };
}

function emptySystemContact(): SystemContact {
  return {
    contactInfo: createContactInfo('联系人', {}),
    key: '',
    contactId: -1,
    localId: '',
  };
}

function parseToolArguments(argumentsJson: string): ToolArguments {
  try {
    return JSON.parse(argumentsJson) as ToolArguments;
  } catch (_) {
    return {
      action: 'query',
      query: argumentsJson,
    };
  }
}

function normalizedAction(action: string | undefined): string {
  const normalized = stringValue(action).toLowerCase();
  if (normalized === 'add' || normalized === 'create' || normalized === 'set' ||
    normalized === '添加' || normalized === '新增' || normalized === '创建' || normalized === '设置') {
    return 'add';
  }
  if (normalized === 'update' || normalized === 'modify' || normalized === 'edit' ||
    normalized === '修改' || normalized === '更新' || normalized === '变更') {
    return 'update';
  }
  if (normalized === 'delete' || normalized === 'remove' || normalized === 'cancel' ||
    normalized === '删除' || normalized === '移除' || normalized === '取消') {
    return 'delete';
  }
  return 'query';
}

function parseClockParts(value: string): ClockParts {
  const match = /(\d{1,2})[:：](\d{1,2})/.exec(value);
  if (match === null || match.length < 3) {
    return {
      ok: false,
      hour: 0,
      minute: 0,
      normalized: '',
    };
  }
  const hour = Number.parseInt(match[1], 10);
  const minute = Number.parseInt(match[2], 10);
  const ok = Number.isFinite(hour) && Number.isFinite(minute) && hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;
  return {
    ok,
    hour,
    minute,
    normalized: ok ? `${hour.toString().padStart(2, '0')}:${minute.toString().padStart(2, '0')}` : '',
  };
}

function parseDateTime(value: string): ParsedDateTime {
  const normalized = value.trim().replace(/\//g, '-');
  if (normalized.length === 0) {
    return createParsedDateTime(false, new Date(0), '');
  }
  const dateTimeMatch = /(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2})[:：](\d{1,2})/.exec(normalized);
  if (dateTimeMatch !== null && dateTimeMatch.length >= 6) {
    const date = new Date(
      Number.parseInt(dateTimeMatch[1], 10),
      Number.parseInt(dateTimeMatch[2], 10) - 1,
      Number.parseInt(dateTimeMatch[3], 10),
      Number.parseInt(dateTimeMatch[4], 10),
      Number.parseInt(dateTimeMatch[5], 10),
      0,
      0,
    );
    return createParsedDateTime(!Number.isNaN(date.getTime()), date, formatDateTime(date));
  }
  const clock = parseClockParts(normalized);
  if (clock.ok) {
    const now = new Date();
    const date = new Date(now.getFullYear(), now.getMonth(), now.getDate(), clock.hour, clock.minute, 0, 0);
    return createParsedDateTime(true, date, formatDateTime(date));
  }
  return createParsedDateTime(false, new Date(0), '');
}

function createParsedDateTime(ok: boolean, value: Date, normalized: string): ParsedDateTime {
  return {
    ok,
    value,
    normalized,
  };
}

function repeatToDaysOfWeek(repeat: string): number[] {
  const normalized = repeat.toLowerCase();
  if (normalized === 'daily' || normalized === '每天' || normalized === 'everyday') {
    return [1, 2, 3, 4, 5, 6, 7];
  }
  if (normalized === 'weekdays' || normalized === '工作日') {
    return [1, 2, 3, 4, 5];
  }
  if (normalized === 'weekends' || normalized === '周末') {
    return [6, 7];
  }
  return [];
}

function daysOfWeekToRepeat(days: number[] | undefined): string {
  if (days === undefined || days.length === 0) {
    return 'once';
  }
  if (days.length === 7) {
    return 'daily';
  }
  if (days.length === 5 && days.indexOf(1) >= 0 && days.indexOf(5) >= 0) {
    return 'weekdays';
  }
  return days.join(',');
}

function formatDateTime(date: Date): string {
  const year = date.getFullYear().toString();
  const month = (date.getMonth() + 1).toString().padStart(2, '0');
  const day = date.getDate().toString().padStart(2, '0');
  const hour = date.getHours().toString().padStart(2, '0');
  const minute = date.getMinutes().toString().padStart(2, '0');
  return `${year}-${month}-${day} ${hour}:${minute}`;
}

function calendarLocalId(eventId: number | undefined, bindings: CalendarBinding[]): string {
  const id = typeof eventId === 'number' ? eventId : -1;
  const binding = bindings.find((item: CalendarBinding): boolean => item.eventId === id);
  return binding === undefined ? '' : binding.id;
}

function contactLocalId(key: string, bindings: ContactBinding[]): string {
  const binding = bindings.find((item: ContactBinding): boolean => item.key === key);
  return binding === undefined ? '' : binding.id;
}

function normalizeAlarmBinding(item: AlarmBinding): AlarmBinding {
  return {
    id: stringValue(item.id, createId('alarm')),
    reminderId: numberValue(item.reminderId, -1),
    title: stringValue(item.title, '闹钟'),
    time: stringValue(item.time),
    repeat: stringValue(item.repeat, 'once'),
    notes: stringValue(item.notes),
    updatedAt: stringValue(item.updatedAt, currentPromptTimeText()),
  };
}

function normalizeCalendarBinding(item: CalendarBinding): CalendarBinding {
  return {
    id: stringValue(item.id, createId('schedule')),
    eventId: numberValue(item.eventId, -1),
    title: stringValue(item.title, '日程'),
    updatedAt: stringValue(item.updatedAt, currentPromptTimeText()),
  };
}

function normalizeContactBinding(item: ContactBinding): ContactBinding {
  return {
    id: stringValue(item.id, createId('contact')),
    contactId: numberValue(item.contactId, -1),
    key: stringValue(item.key),
    name: stringValue(item.name, '联系人'),
    updatedAt: stringValue(item.updatedAt, currentPromptTimeText()),
  };
}

function emptyAlarmBinding(): AlarmBinding {
  return {
    id: '',
    reminderId: -1,
    title: '',
    time: '',
    repeat: '',
    notes: '',
    updatedAt: '',
  };
}

function matchesText(query: string, first: string, second: string = '', third: string = '', fourth: string = '', fifth: string = ''): boolean {
  const normalized = query.trim().toLowerCase();
  if (normalized.length === 0) {
    return false;
  }
  const haystack = `${first} ${second} ${third} ${fourth} ${fifth}`.toLowerCase();
  return haystack.indexOf(normalized) >= 0 || (first.length > 0 && normalized.indexOf(first.toLowerCase()) >= 0);
}

function numericId(value: string): number {
  if (!isNumericString(value)) {
    return -1;
  }
  return Number.parseInt(value, 10);
}

function isNumericString(value: string): boolean {
  if (value.length === 0) {
    return false;
  }
  return /^\d+$/.test(value);
}

function stringValue(value: string | undefined, fallback: string = ''): string {
  return typeof value === 'string' && value.length > 0 ? value : fallback;
}

function numberValue(value: number | undefined, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
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
