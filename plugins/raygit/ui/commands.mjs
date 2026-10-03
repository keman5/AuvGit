const $ = id => document.getElementById(id);
const states = { running: '执行中', succeeded: '已完成', failed: '失败', cancelled: '已停止', timed_out: '超时' };
export class CommandButtons {
  constructor({ call, confirm, getState, onChanged, onDone }) {
    Object.assign(this, { call, confirm, getState, onChanged, onDone, config: null, repo: null, running: false, job: null });
    $('command-settings').onclick = () => this.settings();
    $('command-select').onchange = () => this.select();
    $('command-close').onclick = () => $('command-dialog').close();
    $('command-form').onsubmit = event => { event.preventDefault(); this.configure(false); };
    $('command-delete').onclick = () => this.configure(true);
    $('command-hide').onclick = () => { $('command-output-pane').hidden = true; };
    $('command-cancel').onclick = async () => {
      try { this.showJob(await this.call('command_cancel', { repo: this.repo, id: this.job.id })); }
      catch (error) { $('command-status').textContent = error.message; }
    };
  }
  setRepository(repo, config) {
    if (this.running && repo !== this.repo) return;
    if (repo !== this.repo) { this.repo = repo; this.config = null; this.job = null; $('command-output-pane').hidden = true; }
    if (config) this.config = config;
    this.render();
  }
  render() {
    $('command-buttons').replaceChildren();
    for (const item of this.config?.commands || []) {
      const button = document.createElement('button'); button.className = 'small ghost'; button.textContent = item.label; button.title = item.command;
      button.onclick = () => this.run(item); $('command-buttons').append(button);
    }
  }
  async settings() {
    if (!this.repo) return;
    $('command-error').textContent = ''; $('command-dialog').showModal();
    try { this.config = await this.call('commands', { repo: this.repo }); this.options(); }
    catch (error) { $('command-error').textContent = error.message; }
  }
  options(selected = '') {
    $('command-select').replaceChildren(new Option('＋ 新建按钮', ''));
    for (const item of this.config.commands.filter(item => !item.builtin)) $('command-select').append(new Option(item.label, item.id));
    $('command-select').value = selected; this.select();
  }
  select() {
    const item = this.config.commands.find(item => item.id === $('command-select').value);
    $('command-label').value = item?.label || ''; $('command-text').value = item?.command || ''; $('command-delete').disabled = !item;
  }
  async configure(remove) {
    const id = $('command-select').value;
    if (remove && !await this.confirm('删除按钮', '仅删除按钮配置。', $('command-label').value)) return;
    $('command-error').textContent = '';
    $('command-dialog').querySelectorAll('button,input,select,textarea').forEach(node => { node.disabled = true; });
    try {
      this.config = await this.call('configure_command', { repo: this.repo, revision: this.config.revision, ...(id ? { id } : {}), label: $('command-label').value, command: $('command-text').value, remove });
      this.render(); this.options(remove ? '' : id); this.onChanged();
      $('command-error').textContent = remove ? '按钮已删除。' : '按钮已保存。';
    } catch (error) { $('command-error').textContent = error.message; }
    finally { $('command-dialog').querySelectorAll('button,input,select,textarea').forEach(node => { node.disabled = false; }); $('command-delete').disabled = !$('command-select').value; }
  }
  showJob(job) {
    this.job = job; $('command-output-pane').hidden = false;
    $('command-status').textContent = `${job.label} · ${states[job.state]}${job.exitCode === null ? '' : ' · 退出码 ' + job.exitCode}`;
    $('command-output').textContent = '$ ' + job.command + '\n' + job.output + (job.truncated ? '\n[输出已截断]' : '');
    $('command-output').scrollTop = $('command-output').scrollHeight;
    $('command-cancel').disabled = job.state !== 'running';
  }
  async run(item) {
    if (this.running) return;
    const repo = this.repo, snapshot = this.getState().snapshot, revision = this.config.revision;
    this.running = true; this.onChanged();
    try {
      if (!await this.confirm('执行 ' + item.label, '在下面的仓库中执行命令。命令可能修改文件或访问远端。', repo + '\n\n' + item.command)) return;
      this.showJob(await this.call('command_start', { repo, snapshot, revision, id: item.id }));
      while (this.job.state === 'running') {
        await new Promise(resolve => setTimeout(resolve, 500));
        this.showJob(await this.call('command_status', { repo, id: this.job.id }));
      }
      await this.onDone();
    } catch (error) { $('command-output-pane').hidden = false; $('command-status').textContent = error.message; }
    finally { this.running = false; this.onChanged(); }
  }
}
