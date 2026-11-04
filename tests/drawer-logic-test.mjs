import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const file = new URL('../shared/quickshell/foxml/DrawerLogic.js', import.meta.url);
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(file, 'utf8').replace(/^\.pragma library\s*/, ''), context);
const logic = context;
const plain = value => JSON.parse(JSON.stringify(value));

const rows = [{ id: 'a' }, { id: 'b', enabled: false }, { id: 'c' }];
assert.equal(logic.nextIndex(rows, 0, 1), 2);
assert.equal(logic.nextIndex(rows, 2, 1), 0);
assert.equal(logic.nextIndex(rows, 0, -1), 2);
assert.equal(logic.nextIndex([], 0, 1), -1);
assert.equal(logic.nextIndex([{ enabled: false }], 0, 1), -1);
assert.equal(logic.restoreIndex(rows, logic.identity(rows[2])), 2);
assert.equal(logic.restoreIndex(rows, logic.identity(rows[1])), 0);
assert.equal(logic.restoreIndex([], ''), 0);
assert.notEqual(logic.identity({ id: 'x:y', argument: 'z' }), logic.identity({ id: 'x', argument: 'y:z' }));

const hostile = 'a network; $(touch should-never-run) "quoted"';
assert.deepEqual(plain(logic.actionArguments({ id: 'wifi-connect', argument: hostile })), ['run', 'wifi-connect', hostile]);
assert.deepEqual(plain(logic.actionArguments({ id: 'volume' }, 45, false)), ['run', 'volume', '45']);
assert.deepEqual(plain(logic.actionArguments({ id: 'poweroff' }, undefined, true)), ['run', 'poweroff', '--confirm']);
assert.deepEqual(plain(logic.actionArguments({ id: 'drive-eject', argument: '/dev/sda' }, undefined, true)), ['run', 'drive-eject', '/dev/sda', '--confirm']);
assert.deepEqual(plain(logic.actionArguments({ id: 'speaker-1', action: 'set-output', argument: '1' })), ['run', 'set-output', '1']);
assert.equal(logic.valueText({ kind: 'slider', value: 42 }, true, 47), '47%');
assert.equal(logic.valueText({ kind: 'toggle', checked: false }, false, 0), 'off');
assert.equal(logic.valueText({ kind: 'toggle', checked: true }, false, 0), 'on');
assert.equal(logic.valueText({ kind: 'page' }, false, 0), '›');
assert.equal(logic.symbol({ icon: 'wifi' }), '⌁');
assert.equal(logic.symbol({ icon: '☾' }), '☾');
assert.equal(logic.iconName({ icon: 'firefox' }), 'firefox');
assert.equal(logic.iconName({ icon: '☾' }), '');
assert.ok(logic.barStyle(true, 'updates', 'system').includes('#custom-updates'));
assert.ok(logic.barStyle(true, 'wifi', 'connections').includes('#custom-net_speed'));
assert.ok(logic.barStyle(true, 'audio-outputs', 'sound').includes('#custom-battery'));
assert.ok(logic.barStyle(true, 'comfort', 'comfort').includes('#idle_inhibitor'));
assert.ok(logic.barStyle(true, 'root', '').includes('#custom-logo'));
assert.ok(!logic.barStyle(true, 'root', '').includes('#custom-updates'));
assert.ok(!logic.barStyle(false, 'updates', 'system').includes('#custom-updates'));
assert.ok(!logic.barStyle(true, 'x { injected }', '').includes('injected'));
console.log('drawer navigation, identity, action argv and values: passed');

assert.match(logic.footerHint({focus:'items'}, {kind:'toggle'}), /toggles on or off/);
assert.match(logic.footerHint({focus:'items'}, {kind:'slider'}), /starts adjustment/);
assert.match(logic.footerHint({focus:'items',editing:true}, {kind:'slider'}), /h \/ l adjusts/);
assert.match(logic.footerHint({focus:'items',searching:true}, {kind:'toggle'}), /type to find/);
assert.match(logic.footerHint({focus:'items',confirming:true}, {}), /Esc cancels/);
assert.match(logic.footerHint({focus:'items'}, {id:'agent-jump'}), /goes to agent/);
assert.match(logic.footerHint({focus:'groups'}, {kind:'toggle'}), /opens a drawer/);
console.log('contextual drawer hints: passed');

const sections = [{id:'desk',page:'desk',label:'Desk',items:[{id:'projects',kind:'page',label:'Projects'}]}];
assert.deepEqual(plain(logic.breadcrumbs('projects','desk',['root','desk'],sections)), [
    {label:'Desk',current:false},{label:'Projects',current:true}
]);
assert.deepEqual(plain(logic.breadcrumbs('desk','desk',[],sections)), [{label:'Desk',current:true}]);
assert.deepEqual(plain(logic.breadcrumbs('root','',[],sections)), []);
assert.deepEqual(plain(logic.breadcrumbs('picker','',[],sections)), []);
assert.deepEqual(plain(logic.breadcrumbs('audio-outputs','sound',['root'],[])), [
    {label:'sound',current:false},{label:'audio outputs',current:true}
]);
console.log('drawer breadcrumb labels and current section: passed');

assert.equal(logic.confirmationLabel({id:'drive-eject',label:'USB stick'}), 'Eject drive');
assert.equal(logic.confirmationLabel({id:'poweroff',label:'Power off'}), 'Power off');
assert.equal(logic.focusDetail({id:'password-copy',argument:'/private/secret'}), '');
assert.equal(logic.focusDetail({presentation:'download',argument:'/Downloads/a long name.pdf'}), '/Downloads/a long name.pdf');
assert.match(logic.tooltipText({label:'Notes',presentation:'download',argument:'/Downloads/Notes',modifiedAt:'2026-11-03 12:00:00 CST'}), /2026-11-03/);
assert.match(logic.detailText({enabled:false,detail:'PDF',disabledReason:'xdg-open is not installed'}), /not installed/);
assert.match(logic.footerHint({}, {enabled:false,disabledReason:'Radio state unavailable'}), /Radio state unavailable/);
console.log('confirmation labels, full paths, exact dates and unavailable reasons: passed');
