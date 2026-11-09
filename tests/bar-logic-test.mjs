import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = fs.readFileSync(new URL('../shared/quickshell/foxml/BarLogic.js', import.meta.url), 'utf8');
const ctx = vm.createContext({});
vm.runInContext(source.replace('.pragma library', ''), ctx);
const plain = value => JSON.parse(JSON.stringify(value));
assert.equal(ctx.fullscreenWorkspace(null),false);
assert.equal(ctx.fullscreenWorkspace({hasFullscreen:true,toplevels:{values:[{lastIpcObject:{fullscreen:1}}]}}),false,'maximized windows must keep the bar visible');
assert.equal(ctx.fullscreenWorkspace({hasFullscreen:true,toplevels:{values:[{lastIpcObject:{fullscreen:2}}]}}),true);
assert.equal(ctx.fullscreenWorkspace({hasFullscreen:false,toplevels:{values:[]}}),false);
const config = {'modules-left':['group/one'], 'modules-right':['custom/x'],
    'group/one':{modules:['custom/x','group/cycle','memory']}, 'group/cycle':{modules:['group/one']},
    'custom/x':{exec:'printf hello', interval:3}};
assert.deepEqual(plain(ctx.enabled(config)), ['custom/x','memory']);
assert.equal(ctx.pollers(config, config).length, 1);
assert.equal(ctx.plain('<b>a &lt; b &amp; c</b>'), 'a < b & c');
assert.deepEqual(plain(ctx.sample('{"text":"<b>42</b>","tooltip":"CPU\\n43°","class":"warning busy"}', {'return-type':'json'})),
    {text:'42',tooltip:'CPU\n43°',classes:['warning','busy']});
assert.throws(() => ctx.sample('broken', {'return-type':'json'}));
assert.equal(ctx.format('{used:0.1f}/{total:0.0f}', {used:2.32,total:15.8}), '2.3/16');
assert.equal(ctx.memory('MemTotal: 16777216 kB\nMemAvailable: 2097152 kB', {}).classes[0], 'warning');
assert.equal(ctx.primary('PRIMARY="DP-1"\nSECONDARY_OUTPUTS="HDMI-A-1"'), 'DP-1');
assert.equal(ctx.primary('PRIMARY="$(touch /tmp/never)"'), '$(touch /tmp/never)'); // Data only, never eval.
assert.equal(ctx.windowIcon('firefox', {'window-rewrite':{'class<firefox>':'fox'}}), 'fox');
assert.equal(ctx.windowIcon('other', {'window-rewrite-default':'window'}), 'window');
assert.equal(ctx.compactOutput(1920,1080,'eDP-1','eDP-1'), false);
assert.equal(ctx.compactOutput(1080,1920,'eDP-1','eDP-1'), true);
assert.equal(ctx.compactOutput(1920,1080,'DP-1','eDP-1'), true);
assert.equal(ctx.compactOutput(720,1280,'eDP-1','eDP-1'), true);
const full = {'modules-left':['group/launcher','custom/ai_status'], 'modules-right':['memory','custom/clock'], 'group/launcher':{modules:['custom/logo','hyprland/workspaces']}};
assert.equal(ctx.outputConfig(full, {}, false), full);
assert.deepEqual(plain(ctx.outputConfig(full, {}, true)['modules-right']), ['custom/clock']);
const secondary = {'modules-left':['custom/logo'], 'modules-right':['custom/clock']};
assert.equal(ctx.outputConfig(full,secondary,true), secondary);
console.log('bar logic passed');
