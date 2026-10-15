import test from 'node:test';
import assert from 'node:assert/strict';
import { repoFromLaunchContext } from '../ui/launch.mjs';

test('global entrypoint with no launch path leaves the repository picker available', () => {
  for (const context of [undefined, {}, { 'openai/deepLink': { url: '/' } }]) assert.equal(repoFromLaunchContext(context), null);
});
test('host deep link decodes only the repository, including unicode and literal special characters', () => {
  const repo = '/tmp/项目 + & % # repo';
  const url = '/workspace?' + new URLSearchParams({ repo, command: 'git push', stage: 'true' });
  assert.equal(repoFromLaunchContext({ 'openai/deepLink': { url } }), repo);
});
test('invalid deep links cannot become repository paths', () => {
  for (const url of ['https://evil.invalid/workspace?repo=/tmp/a', '//evil.invalid/?repo=/tmp/a', '/\\evil.invalid/?repo=/tmp/a', '/unknown?repo=/tmp/a', '/?repo=relative', '/?repo=%2Ftmp%00a', '/?repo=/tmp/a#fragment']) {
    assert.equal(repoFromLaunchContext({ 'openai/deepLink': { url } }), null, url);
  }
});
