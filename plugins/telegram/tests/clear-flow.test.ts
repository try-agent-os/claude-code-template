// clear-flow recognition + owner-gate unit tests.
//
// Covers the pure logic that decides whether an incoming text is the `/clear`
// command and whether the sender is allowed to inject it. The actual tmux
// injection (handleClear → operator-clear-inject.sh) is exercised separately via
// the script's own DRY-RUN; it is not unit-tested here because it shells out to a
// live tmux server.
import { test } from 'node:test';
import assert from 'node:assert/strict';
// isClearAdmin reads TELEGRAM_ADMIN_USER_IDS at CALL time (not import time), so a
// plain static import is fine; set the allowlist before the admin-gate test runs.
import { isClearCommand, isClearAdmin } from '../src/clear-flow.js';

process.env.TELEGRAM_ADMIN_USER_IDS = '999000111';

test('isClearCommand matches a bare /clear (any case, optional @bot)', () => {
  assert.equal(isClearCommand('/clear'), true);
  assert.equal(isClearCommand('  /clear  '), true);
  assert.equal(isClearCommand('/CLEAR'), true);
  assert.equal(isClearCommand('/clear@examplebot'), true);
});

test('isClearCommand rejects non-clear text and /clear with args', () => {
  assert.equal(isClearCommand('/clear all'), false);
  assert.equal(isClearCommand('clear'), false); // no leading slash → normal message
  assert.equal(isClearCommand('/clearfoo'), false);
  assert.equal(isClearCommand('please /clear'), false);
  assert.equal(isClearCommand(''), false);
  assert.equal(isClearCommand(null), false);
  assert.equal(isClearCommand(undefined), false);
});

test('isClearAdmin gates on the owner allowlist', () => {
  assert.equal(isClearAdmin(999000111), true);
  assert.equal(isClearAdmin(999), false);
});
