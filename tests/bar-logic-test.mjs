import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = fs.readFileSync(new URL('../shared/quickshell/desk/BarLogic.js', import.meta.url), 'utf8');
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
// Workspace pins for a waiting Claude pass through; anything that isn't a small workspace id stays out.
assert.deepEqual(plain(ctx.sample('{"text":"◇ 1","pins":[2,"x",0,7.5,40]}', {'return-type':'json'})).pins, [2, 40]);
assert.equal(ctx.sample('{"text":"✎ 1"}', {'return-type':'json'}).pins, undefined);
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

// The retro bar: each helper's output (in the shapes shared/waybar_scripts and the backends print) as a DOS code
// and value, its tooltip opening with what the code means.
const retro = (name, text, classes = [], extra = {}, state = {}) => ctx.retroSample(name, {text, tooltip:'tip', classes, ...extra}, state);
const label = (...args) => retro(...args).text;
assert.equal(label('custom/ai_status', ' 35B idle', ['expert']), 'LLM 35B IDLE');
assert.equal(label('custom/ai_status', ' 35B 21.3/24.0g'), 'LLM 35B 21.3/24G');
assert.equal(label('custom/ai_status', ' ⚠ reboot', ['warning']), 'LLM REBOOT');
assert.equal(label('custom/claude', '✎ 2'), 'CLAUDE 2 RUN');
assert.equal(label('custom/claude', '✎ 1  ◇ 2  ! 1', ['asking', 'stopped']), 'CLAUDE 1 RUN 2 WAIT 1 ERR');
assert.equal(label('custom/claude', '✓ all done  ◇ 2', ['done']), 'CLAUDE DONE 2 WAIT');
assert.equal(label('custom/api_credits', 'API ~$200.00 left'), 'API $200 LEFT');
assert.equal(label('custom/api_credits', 'API · setup'), 'API SETUP');
assert.equal(label('custom/foxml_sentry', '\u{F0483} 20', ['ok']), 'SEC 20 OK');
assert.equal(label('custom/foxml_sentry', '\u{F0026} 1 · \u{F0483} 20', ['warning']), 'SEC 1 WARN');
assert.equal(label('custom/foxml_sentry', '\u{F0026} 2 · \u{F0483} 18', ['critical']), 'SEC 2 CRIT');
assert.equal(label('custom/system_health', ' CPU 99% RAM 90% 84°', ['critical']), 'STRESS CPU 99% RAM 90% 84°C');
assert.equal(label('power-profiles-daemon', '◈', ['balanced']), 'PWR BAL');
assert.equal(label('power-profiles-daemon', '↟', ['performance']), 'PWR TURBO');
assert.equal(label('power-profiles-daemon', '❀', ['power-saver']), 'PWR SAVE');
assert.equal(label('custom/battery', '✓ \u{F06A5} 79%', ['plugged']), 'BAT 79% AC');
assert.equal(label('custom/battery', 'ϟ \u{F0088} 42% +27W', ['charging']), 'BAT 42% +27W');
assert.equal(label('custom/battery', 'ϟ \u{F0088} 42%', ['charging']), 'BAT 42% CHG');
assert.equal(label('custom/battery', '\u{F007E} 55% -9W'), 'BAT 55% -9W');
assert.equal(label('custom/battery', '\u{F06A5} 79% -5W', ['plugged-drain']), 'BAT 79% AC -5W');
assert.equal(label('idle_inhibitor', '○', [], {}, {idle:false}), 'AWAKE OFF');
assert.equal(label('idle_inhibitor', '☼', [], {}, {idle:true}), 'AWAKE ON');
assert.equal(label('custom/net_speed', '↓ 12.4 MB/s  ↑ 310 KB/s'), 'NET ↓12.4M ↑310K');
assert.equal(label('custom/cpu', '\u{F0EE0} 16% 40°'), 'CPU 16% 40°C');
assert.equal(label('custom/gpu', '\u{F08AE} on', ['idle']), 'GPU ON');
assert.equal(label('memory', '\u{F035B} 8.9/31g'), 'MEM 8.9/31G');
assert.equal(label('custom/disk', '\u{F02CA} 207g/920g'), 'DSK 207/920G');
assert.equal(label('custom/updates', '↻  37', ['mid']), 'UPD 37');
assert.equal(label('custom/clock', '  Mon Nov 16  1:01 AM'), 'MON NOV 16  1:01 AM');
assert.equal(label('custom/logo', '≡'), '≡');
assert.equal(retro('custom/disk', '\u{F02CA} 207g/920g').tooltip, 'DSK: disk space used / size of /, in GB\ntip');
assert.equal(ctx.retroSample('custom/foxml_sentry', {text:'x 1', tooltip:'🚨 Critical:\n✓ on\n◇ set\nWeather: ⛅️ 9°C', classes:[]}, {}).tooltip.split('\n').slice(1).join('|'),
    '! Critical:|√ on|♦ set|Weather: partly cloudy 9°C');
// A helper that printed nothing hides its module (as in waybar); one that printed garbage reads as an error.
assert.equal(label('custom/system_health', '!', ['warning'], {failed:true, silent:true}), '');
assert.equal(label('custom/system_health', ''), '');
assert.equal(label('custom/gpu', '!', ['warning'], {failed:true}), 'GPU ERR');
// Reverse video means it needs you; critical ones blink.
assert.equal(ctx.retroAlert(['calm']), false);
assert.equal(ctx.retroAlert(['berry']), false);
for (const name of ['critical', 'error', 'warning', 'stopped', 'asking', 'done', 'plugged-drain', 'high']) assert.equal(ctx.retroAlert([name]), true, name);
assert.equal(ctx.retroBlinks(['warning']), false);
assert.equal(ctx.retroBlinks(['critical']), true);
// Three zones: the work modules leave the sides for one middle group; a layout that uses the middle stays.
const zoned = plain(ctx.retroZones({'modules-left':['group/launcher','custom/ai_status','custom/claude','custom/api_credits'], 'modules-center':[],
    'modules-right':['group/system','custom/clock'], 'custom/claude':{exec:'x'}}));
assert.deepEqual([zoned['modules-left'], zoned['modules-center'], zoned['modules-right']],
    [['group/launcher'], ['group/retro-work'], ['group/system','custom/clock']]);
assert.deepEqual(zoned['group/retro-work'].modules, ['custom/ai_status','custom/claude','custom/api_credits']);
assert.deepEqual(zoned['custom/claude'], {exec:'x'});
const centred = {'modules-left':['custom/claude'], 'modules-center':['custom/clock'], 'modules-right':[]};
assert.equal(ctx.retroZones(centred), centred);
console.log('bar logic passed');
