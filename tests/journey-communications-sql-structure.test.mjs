import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';

const migrationsDir = new URL('../supabase/migrations/', import.meta.url);
const migrationSources = readdirSync(migrationsDir)
  .filter((name) => name.endsWith('.sql'))
  .sort()
  .map((name) => readFileSync(new URL(name, migrationsDir), 'utf8'));
const allMigrations = migrationSources.join('\n');

const fixtures = [
  readFileSync(new URL('../supabase/tests/journey_communications_security_contract.sql', import.meta.url), 'utf8'),
  readFileSync(new URL('../supabase/tests/journey_communications_end_to_end.sql', import.meta.url), 'utf8'),
].join('\n');
const allTaskSql = `${allMigrations}\n${fixtures}`;

function stripComments(sql) {
  let result = '';
  let quote = null;
  for (let index = 0; index < sql.length; index += 1) {
    const current = sql[index];
    const next = sql[index + 1];
    if (!quote && current === '-' && next === '-') {
      while (index < sql.length && sql[index] !== '\n') index += 1;
      result += '\n';
      continue;
    }
    if (!quote && current === '/' && next === '*') {
      index += 2;
      while (index < sql.length && !(sql[index] === '*' && sql[index + 1] === '/')) index += 1;
      index += 1;
      result += ' ';
      continue;
    }
    if ((current === "'" || current === '"') && (!quote || quote === current)) {
      if (quote === current && next === current) {
        result += current + next;
        index += 1;
        continue;
      }
      quote = quote ? null : current;
    }
    result += current;
  }
  return result;
}

function topLevelKeyword(sql, keyword, startAt = 0) {
  let depth = 0;
  let quote = null;
  for (let index = startAt; index < sql.length; index += 1) {
    const current = sql[index];
    const next = sql[index + 1];
    if ((current === "'" || current === '"') && (!quote || quote === current)) {
      if (quote === current && next === current) {
        index += 1;
        continue;
      }
      quote = quote ? null : current;
      continue;
    }
    if (quote) continue;
    if (current === '(') depth += 1;
    if (current === ')') depth -= 1;
    if (depth !== 0) continue;
    const candidate = sql.slice(index, index + keyword.length);
    const before = sql[index - 1] ?? ' ';
    const after = sql[index + keyword.length] ?? ' ';
    if (candidate.toLowerCase() === keyword && !/[a-z0-9_]/i.test(before) && !/[a-z0-9_]/i.test(after)) return index;
  }
  return -1;
}

function splitTopLevel(sql) {
  const parts = [];
  let start = 0;
  let depth = 0;
  let quote = null;
  for (let index = 0; index < sql.length; index += 1) {
    const current = sql[index];
    const next = sql[index + 1];
    if ((current === "'" || current === '"') && (!quote || quote === current)) {
      if (quote === current && next === current) {
        index += 1;
        continue;
      }
      quote = quote ? null : current;
      continue;
    }
    if (quote) continue;
    if (current === '(') depth += 1;
    if (current === ')') depth -= 1;
    if (current === ',' && depth === 0) {
      parts.push(sql.slice(start, index).trim());
      start = index + 1;
    }
  }
  parts.push(sql.slice(start).trim());
  return parts;
}

function projectedColumns(viewName) {
  let columns = null;
  for (const rawSource of migrationSources) {
    const source = stripComments(rawSource);
    const escaped = viewName.replace('.', '[.]');
    const definitions = [...source.matchAll(new RegExp(`create\\s+or\\s+replace\\s+view\\s+${escaped}\\b[\\s\\S]*?\\bas\\s+select\\b`, 'gi'))];
    for (const definition of definitions) {
      const selectStart = definition.index + definition[0].length;
      const fromAt = topLevelKeyword(source, 'from', selectStart);
      assert.notEqual(fromAt, -1, `${viewName} projection has no top-level FROM`);
      columns = new Set(splitTopLevel(source.slice(selectStart, fromAt)).map((item) => {
        const alias = item.match(/\bas\s+"?([a-z_][a-z0-9_]*)"?\s*$/i)?.[1]
          ?? item.match(/\s+"?([a-z_][a-z0-9_]*)"?\s*$/i)?.[1]
          ?? item.match(/[.]"?([a-z_][a-z0-9_]*)"?\s*$/i)?.[1];
        assert.ok(alias, `cannot derive ${viewName} projection alias from: ${item}`);
        return alias.toLowerCase();
      }));
    }
    if (columns) {
      const rename = new RegExp(`alter\\s+view\\s+${viewName.replace('.', '[.]')}\\s+rename\\s+column\\s+([a-z_][a-z0-9_]*)\\s+to\\s+([a-z_][a-z0-9_]*)`, 'gi');
      for (const match of source.matchAll(rename)) {
        columns.delete(match[1].toLowerCase());
        columns.add(match[2].toLowerCase());
      }
    }
  }
  assert.ok(columns, `${viewName} has no in-repository projection definition`);
  return columns;
}

function projectionReferences(sql, viewName) {
  const source = stripComments(sql);
  const escaped = viewName.replace('.', '[.]');
  const references = [];
  const fromPattern = new RegExp(`\\bfrom\\s+${escaped}\\b(?:\\s+([a-z_][a-z0-9_]*))?`, 'gi');
  const sqlKeywords = new Set(['where', 'join', 'order', 'group', 'limit', 'offset', 'for', 'union']);
  for (const match of source.matchAll(fromPattern)) {
    const statementStart = source.lastIndexOf(';', match.index) + 1;
    const statementEndAt = source.indexOf(';', match.index);
    const statement = source.slice(statementStart, statementEndAt < 0 ? source.length : statementEndAt);
    const alias = match[1] && !sqlKeywords.has(match[1].toLowerCase()) ? match[1].toLowerCase() : null;
    if (alias) {
      for (const column of statement.matchAll(new RegExp(`\\b${alias}[.]([a-z_][a-z0-9_]*)`, 'gi'))) references.push(column[1].toLowerCase());
    } else {
      for (const counted of statement.matchAll(/\bcount\s*\(\s*(?:distinct\s+)?([a-z_][a-z0-9_]*)/gi)) references.push(counted[1].toLowerCase());
      const whereAt = topLevelKeyword(statement, 'where');
      if (whereAt >= 0) {
        const predicate = statement.slice(whereAt + 'where'.length);
        const nestedSelectAt = topLevelKeyword(predicate, 'select');
        const outerPredicate = predicate.slice(0, nestedSelectAt < 0 ? predicate.length : nestedSelectAt);
        for (const column of outerPredicate.matchAll(/\b([a-z_][a-z0-9_]*)\s+(?:in\b|=|<>|is\b)/gi)) references.push(column[1].toLowerCase());
      }
    }
  }
  return references;
}

test('Task 8 fixture references only columns projected by every in-repository journey view', () => {
  const views = [
    'public.v2_customer_my_journey_conversations',
    'public.v2_customer_my_journey_messages',
    'public.v2_captain_my_journey_conversations',
    'public.v2_captain_my_journey_messages',
    'public.v2_admin_journey_conversations',
    'public.v2_admin_operational_alerts',
    'public.v2_admin_journey_messages',
    'public.v2_admin_journey_broadcast_deliveries',
  ];
  for (const view of views) {
    const projected = projectedColumns(view);
    const references = projectionReferences(fixtures, view);
    assert.ok(references.length > 0, `${view} is not behaviorally exercised by Task 8`);
    for (const column of references) assert.ok(projected.has(column), `${view}.${column} is referenced but not projected`);
  }
});

test('Task 8 migrations use the production schema contracts proven by preview', () => {
  assert.doesNotMatch(allMigrations, /pace_v2[.]journey_messages\b/i);
  assert.doesNotMatch(allMigrations, /\bjourney_messages[.](?:conversation_id|sender_type|broadcast_source_id)\b/i);
  assert.doesNotMatch(allTaskSql, /'journey_messages'/i);
  assert.doesNotMatch(allMigrations, /to_jsonb\(b\)->>'user_id'/i);
  assert.doesNotMatch(allTaskSql, /bookings\s+b\s+set\s+status='active'/i);
  assert.match(allMigrations, /pace_v2[.]booking_owner_user_id\(b[.]id\)/i);
  assert.match(allMigrations, /pace_v2[.]journey_conversation_messages\b/i);
  assert.doesNotMatch(allMigrations, /pace_v2[.]customer_notifications\b/i);
  assert.doesNotMatch(allMigrations, /pace_v2[.]orders\s+o\s+on\s+o[.]booking_id\s*=\s*b[.]id/i);
  assert.match(allMigrations, /pace_v2[.]orders\s+o\s+on\s+o[.]id\s*=\s*b[.]order_id/i);
  assert.match(allMigrations, /alter table pace_v2[.]departures add column if not exists actual_arrival_ts/i);
  assert.match(allMigrations, /pace_v2[.]notifications\b/i);
  assert.match(allMigrations, /scheduled_at/i);
});
