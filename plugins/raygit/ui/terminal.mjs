import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
const $ = id => document.getElementById(id);
export class ProjectTerminal {
  constructor({ call, onError, onChange }) {
    Object.assign(this, { call, onError, onChange, repo: null, sessions: new Map(), visible: false, opening: false, input: Promise.resolve() });
    this.term = new Terminal({ fontFamily: 'Menlo, ui-monospace, monospace', fontSize: 12, cursorBlink: true, scrollback: 3000, theme: { background: '#1e1f22', foreground: '#e0e2e6', cursor: '#e0e2e6' } });
    this.fit = new FitAddon(); this.term.loadAddon(this.fit); this.term.open($('terminal-screen'));
    this.term.onData(data => {
      const item = this.sessions.get(this.repo);
      if (!item || item.exited || this.opening) return;
      // Serialize input. Capturing repo/id prevents pending keystrokes reaching another project.
      this.input = this.input.then(() => this.call('terminal_input', { repo: item.repo, id: item.id, data })).catch(error => this.onError(error.message));
    });
    this.term.attachCustomKeyEventHandler(event => !(event.metaKey && event.code === 'Backquote'));
    this.term.onResize(({ cols, rows }) => {
      const item = this.sessions.get(this.repo);
      if (item && !item.exited) this.call('terminal_resize', { repo: item.repo, id: item.id, cols, rows }).catch(error => this.onError(error.message));
    });
    new ResizeObserver(() => this.resize()).observe($('terminal-screen'));
    $('terminal-toggle').onclick = () => this.toggle();
    $('terminal-hide').onclick = () => this.hide();
    $('terminal-close').onclick = () => this.close();
    document.addEventListener('keydown', event => {
      if (event.metaKey && event.code === 'Backquote' && !event.altKey && !event.ctrlKey && !document.querySelector('dialog[open]')) {
        event.preventDefault(); this.toggle();
      }
    }, true);
    this.timer = setInterval(() => this.poll(), 350);
    window.addEventListener('pagehide', () => {
      for (const item of this.sessions.values()) this.call('terminal_close', { repo: item.repo, id: item.id }).catch(() => {});
    });
  }
  setRepository(repo) {
    if (this.repo === repo) return;
    this.repo = repo; this.term.reset();
    $('terminal-path').textContent = repo || '';
    const item = this.sessions.get(repo);
    if (item) this.term.write(item.output);
    if (this.visible) this.show();
  }
  resize() { if (this.visible) { try { this.fit.fit(); } catch {} } }
  async toggle() { if (!this.repo || this.opening) return; this.visible ? this.hide() : await this.show(); }
  hide() { this.visible = false; $('terminal-pane').hidden = true; $('terminal-toggle').setAttribute('aria-expanded', 'false'); this.onChange(); }
  async show() {
    if (!this.repo || this.opening) return;
    this.visible = true; $('terminal-pane').hidden = false; $('terminal-toggle').setAttribute('aria-expanded', 'true'); this.resize();
    const repo = this.repo;
    if (!this.sessions.has(repo)) {
      this.opening = true; $('terminal-status').textContent = '连接中…';
      try {
        const item = await this.call('terminal_open', { repo, cols: Math.max(10, this.term.cols), rows: Math.max(2, this.term.rows) });
        this.sessions.set(repo, { ...item, cursor: 0, output: '', exited: false });
      } catch (error) { this.onError(error.message); $('terminal-status').textContent = '连接失败 · 点击终端重试'; }
      finally { this.opening = false; }
    }
    if (this.repo !== repo) { if (this.visible) await this.show(); return; }
    this.resize(); this.term.focus(); await this.poll();
  }
  async poll() {
    const item = this.sessions.get(this.repo);
    if (!this.visible || document.hidden || !item || item.polling || item.exited) return;
    item.polling = true;
    try {
      const result = await this.call('terminal_read', { repo: item.repo, id: item.id, cursor: item.cursor });
      if (!this.sessions.has(item.repo)) return;
      item.cursor = result.cursor; item.output = (item.output + result.output).slice(-256 * 1024);
      item.exited = result.exitCode !== null;
      if (this.repo !== item.repo) return;
      if (result.truncated) this.term.write('\r\n[较早的终端输出已截断]\r\n');
      this.term.write(result.output);
      $('terminal-status').textContent = item.exited ? `已退出 (${result.exitCode}) · 关闭后可重新打开` : '交互式终端';
    } catch (error) { item.exited = true; if (this.repo === item.repo) { $('terminal-status').textContent = '连接中断 · 关闭后重试'; this.onError(error.message); } }
    finally { item.polling = false; }
  }
  async close() {
    const item = this.sessions.get(this.repo);
    if (this.opening) return;
    if (item) {
      try { await this.call('terminal_close', { repo: item.repo, id: item.id }); }
      catch (error) { this.onError(error.message); }
      this.sessions.delete(item.repo);
    }
    if (!item || this.repo === item.repo) { this.term.reset(); this.hide(); }
  }
}
