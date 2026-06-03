export function createId(prefix: string = 'id'): string {
  const random = Math.floor(Math.random() * 1000000000).toString(36);
  return `${prefix}-${Date.now().toString(36)}-${random}`;
}

export function currentTimeText(): string {
  const date = new Date();
  const hours = date.getHours().toString().padStart(2, '0');
  const minutes = date.getMinutes().toString().padStart(2, '0');
  return `${hours}:${minutes}`;
}

export function currentPromptTimeText(): string {
  const date = new Date();
  const year = date.getFullYear().toString();
  const month = (date.getMonth() + 1).toString().padStart(2, '0');
  const day = date.getDate().toString().padStart(2, '0');
  const hours = date.getHours().toString().padStart(2, '0');
  const minutes = date.getMinutes().toString().padStart(2, '0');
  return `北京时间 ${year}-${month}-${day} ${hours}:${minutes}`;
}

export function splitForStreaming(text: string): string[] {
  if (text.trim().length === 0) {
    return [];
  }
  const chunks: string[] = [];
  let index = 0;
  while (index < text.length) {
    const next = Math.min(index + 3, text.length);
    chunks.push(text.substring(index, next));
    index = next;
  }
  return chunks;
}

export function cleanStreamChunk(value: string): string {
  if (value.length === 0) {
    return '';
  }
  const trimmed = value.trim();
  if (trimmed.toLowerCase() === 'null') {
    return '';
  }
  if (isAllNullTokens(trimmed)) {
    return '';
  }
  return value;
}

export function cleanDisplayText(value: string): string {
  const normalized = value.replace(/(null){2,}/ig, '');
  if (normalized.trim().toLowerCase() === 'null') {
    return '';
  }
  return normalized;
}

export function stripEmotionTagsForDisplay(value: string): string {
  let output = value.replace(/\[emotion:(\w+)\]/ig, '');
  const markerStart = output.lastIndexOf('[');
  if (markerStart < 0) {
    return output;
  }
  const trailing = output.substring(markerStart + 1).toLowerCase();
  const hasLineBreak = output.substring(markerStart).indexOf('\n') >= 0;
  if (hasLineBreak) {
    return output;
  }
  const fullMarkerPrefix = 'emotion:';
  if (fullMarkerPrefix.startsWith(trailing) || trailing.startsWith(fullMarkerPrefix)) {
    output = output.substring(0, markerStart);
  }
  return output;
}

export function extractEmotion(value: string): string {
  const match = /\[emotion:(\w+)\]/i.exec(value);
  if (match === null || match.length < 2) {
    return '';
  }
  const emotion = match[1];
  const valid = ['neutral', 'anger', 'joy', 'sadness', 'shy', 'smile', 'surprise', 'unhappy'];
  return valid.indexOf(emotion) >= 0 ? emotion : '';
}

function isAllNullTokens(value: string): boolean {
  if (value.length === 0 || value.length % 4 !== 0) {
    return false;
  }
  for (let index = 0; index < value.length; index += 4) {
    if (value.substring(index, index + 4).toLowerCase() !== 'null') {
      return false;
    }
  }
  return true;
}
