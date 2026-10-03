import { EditorState, Compartment } from '@codemirror/state';
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection } from '@codemirror/view';
import { history, historyKeymap, defaultKeymap, indentWithTab, undo, redo } from '@codemirror/commands';
import { searchKeymap, highlightSelectionMatches, openSearchPanel } from '@codemirror/search';
import { syntaxHighlighting, defaultHighlightStyle, bracketMatching } from '@codemirror/language';
import { javascript } from '@codemirror/lang-javascript';
import { json } from '@codemirror/lang-json';
import { css } from '@codemirror/lang-css';
import { markdown } from '@codemirror/lang-markdown';
import { MergeView, goToNextChunk, goToPreviousChunk } from '@codemirror/merge';

const labels = { head: 'HEAD', index: '索引', worktree: '工作区', base: '共同祖先', ours: '我们的版本', theirs: '他们的版本' };
const $ = id => document.getElementById(id);
const theme = EditorView.theme({
  '&': { height: '100%', backgroundColor: 'var(--panel)', color: 'var(--ink)', fontSize: '12px' },
  '.cm-scroller': { overflow: 'auto', fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', lineHeight: '1.65' },
  '.cm-gutters': { backgroundColor: 'var(--panel)', color: 'var(--muted)', borderRight: 'none' },
  '.cm-activeLine, .cm-activeLineGutter': { backgroundColor: 'var(--hover)' },
  '.cm-cursor': { borderLeftColor: 'var(--ink)' },
  '.cm-selectionBackground, &.cm-focused .cm-selectionBackground': { backgroundColor: 'var(--selection)' },
  '.cm-panels': { backgroundColor: 'var(--subtle)', color: 'var(--ink)' },
  '.cm-textfield': { color: 'var(--ink)', backgroundColor: 'var(--panel)' },
});
function language(file) {
  if (/\.(jsx?|tsx?|mjs|cjs)$/.test(file)) return javascript({ typescript: /\.tsx?$/.test(file), jsx: /\.[jt]sx$/.test(file) });
  if (/\.json$/.test(file)) return json(); if (/\.css$/.test(file)) return css(); if (/\.md$/.test(file)) return markdown(); return [];
}

export class ComparisonEditor {
  constructor({ call, confirm, onSaved }) {
    this.call = call; this.confirm = confirm; this.onSaved = onSaved; this.data = null; this.merge = null; this.third = null; this.target = 'worktree'; this.drafts = {}; this.saving = false; this.loading = false; this.syncing = false; this.generation = 0;
    $('compare-close').onclick = () => this.close();
    $('compare-dialog').addEventListener('cancel', event => { event.preventDefault(); this.close(); });
    $('compare-save').onclick = () => this.save(false);
    $('compare-stage').onclick = () => this.save(true);
    $('compare-reload').onclick = () => this.reload();
    $('compare-left').onchange = () => this.changeBase();
    $('compare-target').onchange = () => this.changeTarget();
    $('compare-third').onchange = () => this.showThird();
    $('compare-collapse').onchange = () => this.merge?.reconfigure({ collapseUnchanged: $('compare-collapse').checked ? { margin: 3, minSize: 8 } : undefined });
    $('compare-wrap').onchange = () => this.wrap();
    $('compare-search').onclick = () => this.merge && openSearchPanel(this.merge.b);
    $('compare-undo').onclick = () => this.merge && undo(this.merge.b);
    $('compare-redo').onclick = () => this.merge && redo(this.merge.b);
    $('compare-next').onclick = () => this.merge && goToNextChunk(this.merge.b);
    $('compare-prev').onclick = () => this.merge && goToPreviousChunk(this.merge.b);
    $('compare-accept').onclick = () => this.acceptVersion();
    window.addEventListener('beforeunload', event => { if (this.dirty()) { event.preventDefault(); event.returnValue = ''; } });
  }
  dirty() { return this.data && Object.entries(this.drafts).some(([key, text]) => text !== (this.data.versions[key]?.text ?? '')); }
  message(text, error = false) { $('compare-message').textContent = text; $('compare-message').classList.toggle('error-text', error); }
  async open(repo, file, scope = 'working') {
    if (this.data && this.dirty() && !await this.confirm('保留当前编辑？', '打开其他文件会关闭当前草稿。请先保存，或明确放弃。', '选择“确认”放弃未保存编辑。')) return;
    const request = ++this.generation; this.loading = true;
    this.destroy(); this.data = null; this.drafts = {};
    $('compare-title').textContent = file; $('compare-dialog').showModal(); this.message('正在读取文件版本…'); this.buttons();
    try {
      const data = await this.call('compare', { repo, file });
      if (request !== this.generation) return;
      this.data = data; this.target = scope === 'staged' && !data.conflict ? 'index' : 'worktree';
      this.drafts = { worktree: data.versions.worktree.text ?? '', index: data.versions.index.text ?? '' };
      for (const id of ['compare-left', 'compare-third']) {
        $(id).replaceChildren(); if (id === 'compare-third') { const none = new Option('双栏', ''); $(id).append(none); }
        for (const key of Object.keys(labels)) if (data.versions[key]) $(id).append(new Option(labels[key], key));
      }
      $('compare-target').value = this.target;
      $('compare-left').value = data.conflict ? 'ours' : this.target === 'index' ? 'head' : 'index';
      $('compare-third').value = data.conflict ? 'theirs' : '';
      this.mount(); this.showThird();
      if (data.versions[this.target].editable && data.versions[$('compare-left').value].text !== undefined) this.message(data.conflict ? '冲突文件：编辑工作区，检查冲突标记后保存并标记解决。' : '左侧只读；右侧可编辑。箭头将左侧差异块应用到右侧草稿，保存后才写入文件。');
    } catch (error) { this.message(error.message, true); }
    finally { if (request === this.generation) { this.loading = false; this.buttons(); } }
  }
  extensions(editable, label, wrap) {
    return [theme, EditorState.phrases.of({ 'Find': '查找', 'Replace': '替换为', 'next': '下一个', 'previous': '上一个', 'all': '全部', 'match case': '区分大小写', 'regexp': '正则表达式', 'by word': '整词', 'replace': '替换', 'replace all': '全部替换', 'close': '关闭搜索' }), lineNumbers(), drawSelection(), highlightActiveLine(), highlightActiveLineGutter(), bracketMatching(),
      syntaxHighlighting(defaultHighlightStyle), language(this.data.file), highlightSelectionMatches(), history(),
      EditorState.readOnly.of(!editable), EditorView.editable.of(editable), EditorView.contentAttributes.of({ 'aria-label': label }),
      wrap.of($('compare-wrap').checked ? EditorView.lineWrapping : []),
      keymap.of([{ key: 'Mod-s', run: () => { this.save(false); return true; } }, ...defaultKeymap, ...historyKeymap, ...searchKeymap, indentWithTab]),
    ];
  }
  mount() {
    this.destroy(); const left = this.data.versions[$('compare-left').value], right = this.data.versions[this.target];
    this.wrapA = new Compartment(); this.wrapB = new Compartment(); this.editing = new Compartment(); this.wasEditable = null;
    const editable = right.editable && !(this.target === 'index' && this.data.conflict);
    this.merge = new MergeView({
      a: { doc: left.text ?? '', extensions: this.extensions(false, '基准文件（只读）', this.wrapA) },
      b: { doc: this.drafts[this.target], extensions: [...this.extensions(true, '编辑文件内容', this.wrapB), this.editing.of([EditorState.readOnly.of(!editable), EditorView.editable.of(editable)]), EditorView.updateListener.of(update => {
        if (update.docChanged) { this.drafts[this.target] = update.state.doc.toString(); this.buttons(); }
      })] },
      parent: $('compare-editors'), collapseUnchanged: $('compare-collapse').checked ? { margin: 3, minSize: 8 } : undefined, highlightChanges: true, gutter: true, diffConfig: { timeout: 250, scanLimit: 2000 },
      ...(editable && left.text !== undefined ? { revertControls: 'a-to-b', renderRevertControl: () => { const button = document.createElement('button'); button.textContent = '→'; button.title = '应用此差异块到右侧草稿'; return button; } } : {}),
    });
    this.merge.b.scrollDOM.addEventListener('scroll', () => this.syncScroll(this.merge.b), { passive: true });
    this.merge.a.scrollDOM.addEventListener('scroll', () => this.syncScroll(this.merge.a), { passive: true });
    $('compare-left-label').textContent = labels[$('compare-left').value] + (left.exists ? '' : ' · 文件不存在');
    $('compare-right-label').textContent = labels[this.target] + (editable ? ' · 可编辑' : ' · 只读');
    $('compare-stage').textContent = this.data.conflict ? '保存并标记解决' : '保存并暂存';
    if (!editable || left.text === undefined) this.message([left.reason, right.reason].filter(Boolean).join('；') || '此版本只读。', true);
    this.buttons();
  }
  syncScroll(source) {
    if (this.syncing || !$('compare-sync').checked) return;
    this.syncing = true;
    for (const view of [this.merge?.a, this.merge?.b, this.third]) if (view && view !== source) view.scrollDOM.scrollTop = source.scrollDOM.scrollTop;
    requestAnimationFrame(() => { this.syncing = false; });
  }
  buttons() {
    const available = this.data && !this.saving && !this.loading;
    document.querySelectorAll('#compare-dialog button,#compare-dialog select,#compare-dialog input').forEach(node => { node.disabled = !available; });
    $('compare-close').disabled = this.saving;
    const right = this.data?.versions[this.target];
    const editable = available && right?.editable && !(this.target === 'index' && this.data.conflict);
    if (this.merge && this.wasEditable !== !!editable) { this.wasEditable = !!editable; this.merge.b.dispatch({ effects: this.editing.reconfigure([EditorState.readOnly.of(!editable), EditorView.editable.of(!!editable)]) }); }
    $('compare-save').disabled = !editable || this.drafts[this.target] === right?.text;
    $('compare-stage').disabled = !editable || this.target !== 'worktree';
    $('compare-accept').disabled = !editable || this.data?.versions[$('compare-left').value]?.text === undefined;
    $('compare-dirty').textContent = this.saving ? '保存中…' : this.dirty() ? '● 未保存' : '已保存';
    $('compare-format').textContent = right?.text === undefined ? (right?.reason || '') : `UTF-8${right.bom ? ' BOM' : ''} · ${right.eol} · ${this.merge?.chunks.length ?? 0} 个差异块`;
  }
  changeBase() {
    if (!this.merge) return;
    const version = this.data.versions[$('compare-left').value];
    this.merge.reconfigure({ revertControls: version.text !== undefined && this.data.versions[this.target].editable && !(this.target === 'index' && this.data.conflict) ? 'a-to-b' : undefined });
    this.merge.a.dispatch({ changes: { from: 0, to: this.merge.a.state.doc.length, insert: version.text ?? '' } });
    $('compare-left-label').textContent = labels[$('compare-left').value];
    this.message(version.reason || '箭头只修改右侧草稿；保存前不会覆盖磁盘。', !!version.reason); this.buttons();
  }
  changeTarget() { this.target = $('compare-target').value; this.mount(); this.showThird(); }
  showThird() {
    this.third?.destroy(); this.third = null; $('compare-extra').replaceChildren();
    const key = $('compare-third').value;
    $('compare-extra-pane').hidden = !key; $('compare-body').classList.toggle('three-way', !!key);
    if (!key || !this.data) return;
    this.wrapC = new Compartment();
    $('compare-extra-label').textContent = labels[key] + ' · 只读';
    this.third = new EditorView({ doc: this.data.versions[key].text ?? '', extensions: this.extensions(false, '参考版本（只读）', this.wrapC), parent: $('compare-extra') });
    this.third.scrollDOM.addEventListener('scroll', () => this.syncScroll(this.third), { passive: true });
  }
  wrap() {
    for (const [view, compartment] of [[this.merge?.a, this.wrapA], [this.merge?.b, this.wrapB], [this.third, this.wrapC]]) if (view) view.dispatch({ effects: compartment.reconfigure($('compare-wrap').checked ? EditorView.lineWrapping : []) });
  }
  async acceptVersion() {
    if (!this.merge || this.data.versions[$('compare-left').value]?.text === undefined) return;
    if (!await this.confirm('采用左侧完整版本', '此操作替换右侧草稿，可撤销；仍需保存。', labels[$('compare-left').value] + ' → ' + labels[this.target])) return;
    this.merge.b.dispatch({ changes: { from: 0, to: this.merge.b.state.doc.length, insert: this.data.versions[$('compare-left').value].text } });
  }
  async save(stage) {
    if (!this.data || this.saving || this.loading || !this.data.versions[this.target].editable) return;
    if (stage && !await this.confirm(this.data.conflict ? '保存并标记解决' : '保存并暂存', '将当前工作区草稿保存，并把这个文件加入索引。', this.data.file)) return;
    const dirtyTargets = Object.keys(this.drafts).filter(key => this.drafts[key] !== this.data.versions[key].text);
    this.saving = true; this.buttons();
    try {
      const result = await this.call('save', { repo: this.data.repo, file: this.data.file, token: this.data.token, target: this.target, text: this.drafts[this.target], stage });
      this.data = result;
      for (const key of Object.keys(this.drafts)) if (key === this.target || !dirtyTargets.includes(key)) this.drafts[key] = result.versions[key].text ?? '';
      this.changeBase(); this.showThird(); this.message(result.notice);
      await this.onSaved();
    } catch (error) { this.message(error.message, true); }
    finally { this.saving = false; this.buttons(); }
  }
  async reload() {
    if (this.dirty() && !await this.confirm('重新加载文件', '重新加载会放弃未保存的草稿。', this.data.file)) return;
    const { repo, file } = this.data; this.drafts = {}; this.data = null;
    await this.open(repo, file, this.target === 'index' ? 'staged' : 'working');
  }
  async close() {
    if (this.saving) return;
    if (this.dirty() && !await this.confirm('关闭对比', '仍有未保存的编辑，是否放弃？', this.data.file)) return;
    this.generation++; this.destroy(); this.data = null; this.drafts = {}; $('compare-dialog').close();
  }
  destroy() { this.merge?.destroy(); this.third?.destroy(); this.merge = null; this.third = null; $('compare-editors').replaceChildren(); $('compare-extra').replaceChildren(); }
}
