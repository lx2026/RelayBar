// State and markup checks for the design prototype. This does not render a browser.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const file = new URL('../docs/design/assets/2026-10-21-frame-redesign/frame-redesign.html', import.meta.url);
const source = fs.readFileSync(file, 'utf8');
assert(Buffer.byteLength(source) < 1_000_000);
assert(!/<!doctype|<html|<head>|<body/i.test(source));
assert(/color-scheme:\s*light dark/.test(source));
const script = [...source.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match => match[1]).join('\n');
const apps = ['menu'].map(layout => ({
  dataset: {layout}, style: {}, innerHTML: '', listeners: {},
  classList: {toggle() {}},
  addEventListener(event, callback) { this.listeners[event] = callback; },
  querySelector() { return null; },
  contains() { return false; },
  closest() { return null; }
}));
const root = {isConnected: true, querySelectorAll() {return apps;}};
const globals = {};
const previewControls = [];
const context = vm.createContext({
  document: {getElementById: () => root},
  window: {addEventListener(name, callback) {globals[name] = callback;}},
  setInterval: () => 1, clearInterval() {}, setTimeout: () => 1, clearTimeout() {},
  Tweak: class {
    constructor(config) { previewControls.push(config); }
    addSelect() {}
  }
});
vm.runInContext(script, context);
function click(app, dataset) {
  app.listeners.click({target:{closest(){return {dataset, disabled:false};}}});
}
const app = apps[0], mock = app.frameMock;
assert(app.innerHTML.includes('Dune study.png'));
assert(!app.innerHTML.includes('aria-label="Show subfolders"'));
mock.action('folders');
assert(app.innerHTML.includes('role="dialog" aria-label="Folders"'));
click(app, {root:'1'});
assert.equal(mock.state.root, 1);
assert(!app.innerHTML.includes('data-select="2"'));
assert(app.innerHTML.includes('data-select="4"'));
mock.choose(0); mock.render();
click(app, {select:'2'});
assert(app.innerHTML.includes('aria-label="Playback position"'));
assert(app.innerHTML.includes('HEVC'));
mock.action('play'); assert.equal(mock.state.playing,true);
mock.action('next'); assert.equal(mock.state.playing,false);
assert(!app.innerHTML.includes('aria-label="Playback position"'));
click(app,{folder:'Clips'}); click(app,{filter:'favorites'});
assert.equal(mock.state.selected,5);
mock.action('favorite');
assert(app.innerHTML.includes('No favorites here'));
mock.action('all'); mock.action('trash');
assert(app.innerHTML.includes('data-action="undo"'));
mock.action('undo'); assert.equal(mock.state.deleted.length,0);
mock.state.screen='Missing folder';mock.render();
assert(app.innerHTML.includes('This folder is unavailable'));
assert(!app.innerHTML.includes('aria-label="Selected file metadata"'));
assert(/data-action="export"[^>]* disabled/.test(app.innerHTML));
mock.state.screen='Unsupported video';previewControls[0].onChange();
assert(app.innerHTML.includes('This video can’t be played'));
assert(app.innerHTML.includes('aria-label="Selected file metadata"'));
assert(!app.innerHTML.includes('aria-label="Playback position"'));
mock.state.screen='Start';mock.render();
assert(app.innerHTML.includes('Open a folder.'));
assert(!app.innerHTML.includes('aria-label="Subfolders"'));
for (const theme of ['light','dark']) {
  mock.state.theme=theme;mock.render();assert.equal(app.style.colorScheme,theme);
}
mock.state.theme='system';mock.render();assert.equal(app.style.colorScheme,'');
mock.state.screen='Inspect';mock.state.focus=true;mock.state.grid=true;mock.state.popover='folders';mock.render();
const press=(key,extra={})=>globals.keydown({key,preventDefault(){},target:{matches(){return false;},closest(){return null;}},...extra});
press('Escape');assert.equal(mock.state.popover,null);assert.equal(mock.state.grid,true);assert.equal(mock.state.focus,true);
press('Escape');assert.equal(mock.state.grid,false);assert.equal(mock.state.focus,true);
press('Escape');assert.equal(mock.state.focus,false);
mock.state.sheet='export';press('Escape');assert.equal(mock.state.sheet,null);
mock.choose(0);mock.render();
press(' ');assert.equal(mock.state.focus,false);assert.equal(mock.state.playing,false);
press('Enter');assert.equal(mock.state.focus,true);
mock.action('folders');const oldSelection=mock.state.selected;press('ArrowRight');assert.equal(mock.state.selected,oldSelection);
press('Escape');press('ArrowRight');assert.equal(mock.state.selected,2);
press(' ');assert.equal(mock.state.playing,true);
press('ArrowRight');assert.equal(mock.state.playing,false);
mock.action('trash');mock.action('trash');assert.equal(mock.state.deleted.length,2);
press('z',{metaKey:true});press('z',{metaKey:true});assert.equal(mock.state.deleted.length,0);
mock.state.screen='Start';mock.render();press('Backspace',{metaKey:true});assert.equal(mock.state.deleted.length,0);
mock.state.screen='Missing folder';mock.render();press('e',{metaKey:true,shiftKey:true});assert.equal(mock.state.sheet,null);
mock.choose(0);click(app,{select:'2'});mock.state.grid=true;press(' ');assert.equal(mock.state.playing,false);
mock.state.grid=false;mock.state.screen='Unsupported video';press(' ');assert.equal(mock.state.playing,false);
mock.state.screen='Inspect';mock.state.focus=false;
const summaryTarget={matches(){return false;},closest(selector){return selector.includes('summary')?{}:null;}};
press('Enter',{target:summaryTarget});assert.equal(mock.state.focus,false);
press(' ',{target:summaryTarget});assert.equal(mock.state.playing,false);
console.log('PASS: script syntax, folder switching, scope/filter, video controls, stop-on-navigation, Trash/Undo, failure states, theme selection, layered Escape, keyboard isolation and undo stack.');
console.log('PASS: system theme fallback, disabled commands in unavailable states, no playback without a player, and disclosure keyboard ownership.');
console.log('Browser rendering and real video decoding are outside this prototype check.');
