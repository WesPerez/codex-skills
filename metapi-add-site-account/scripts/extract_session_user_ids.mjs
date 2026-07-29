#!/usr/bin/env node

import { readFileSync } from 'node:fs';

function decodeBase64Loose(value) {
  const normalized = String(value || '')
    .trim()
    .replace(/-/g, '+')
    .replace(/_/g, '/');
  if (!normalized) return null;
  try {
    const buffer = Buffer.from(normalized, 'base64');
    return buffer.length > 0 ? buffer : null;
  } catch {
    return null;
  }
}

function sessionValueFromInput(input) {
  let value = String(input || '').trim();
  if (value.startsWith('Bearer ')) value = value.slice(7).trim();
  const sessionMatch = value.match(/(?:^|;\s*)session=([^;]+)/i);
  if (sessionMatch?.[1]) value = sessionMatch[1].trim();
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function decodeGobSignedInt(encoded) {
  if (!encoded.length) return null;
  let unsigned = 0n;
  if (encoded[0] < 0x80) {
    unsigned = BigInt(encoded[0]);
  } else {
    const width = 0x100 - encoded[0];
    if (width <= 0 || encoded.length !== width + 1) return null;
    for (let index = 1; index < encoded.length; index += 1) {
      unsigned = (unsigned << 8n) | BigInt(encoded[index]);
    }
  }
  const signed = (unsigned & 1n) === 0n
    ? unsigned >> 1n
    : -((unsigned >> 1n) + 1n);
  if (signed <= 0n || signed > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return Number(signed);
}

function extractGobIdFields(payload) {
  const output = [];
  const marker = Buffer.concat([
    Buffer.from('id', 'utf8'),
    Buffer.from([0x03]),
    Buffer.from('int', 'utf8'),
    Buffer.from([0x04]),
  ]);
  let start = 0;
  while (start < payload.length) {
    const position = payload.indexOf(marker, start);
    if (position < 0) break;
    const encodedLength = payload[position + marker.length];
    const delimiter = payload[position + marker.length + 1];
    if (Number.isInteger(encodedLength) && delimiter === 0x00) {
      const byteLength = encodedLength - 1;
      const valueStart = position + marker.length + 2;
      const valueEnd = valueStart + byteLength;
      if (byteLength > 0 && valueEnd <= payload.length) {
        const value = decodeGobSignedInt(payload.subarray(valueStart, valueEnd));
        if (value && value <= 10_000_000 && !output.includes(value)) output.push(value);
      }
    }
    start = position + marker.length;
  }
  return output;
}

function extractTextCandidates(payloadText) {
  const output = [];
  const push = (value) => {
    const parsed = Number.parseInt(String(value), 10);
    if (parsed > 0 && parsed <= 10_000_000 && !output.includes(parsed)) output.push(parsed);
  };
  for (const match of payloadText.matchAll(/_(\d{4,8})(?!\d)/g)) push(match[1]);
  for (const match of payloadText.matchAll(/(?:user(?:name)?|uid|id)[^\d]{0,16}(\d{4,8})(?!\d)/gi)) {
    push(match[1]);
  }
  return output;
}

function extractCandidates(input) {
  const sessionValue = sessionValueFromInput(input);
  const outer = decodeBase64Loose(sessionValue);
  if (!outer) return [];

  const outerText = outer.toString('utf8');
  const parts = outerText.split('|');
  const gobPayload = parts.length >= 2 ? decodeBase64Loose(parts[1]) : null;
  const payload = gobPayload || outer;
  const exact = extractGobIdFields(payload);
  const fallback = extractTextCandidates(payload.toString('utf8'));
  return [...exact, ...fallback.filter((value) => !exact.includes(value))].slice(0, 8);
}

const input = readFileSync(0, 'utf8');
process.stdout.write(`${JSON.stringify(extractCandidates(input))}\n`);
