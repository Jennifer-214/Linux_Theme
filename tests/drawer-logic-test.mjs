import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const file = new URL('../shared/quickshell/foxml/DrawerLogic.js', import.meta.url);
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(file, 'utf8').replace(/^\.pragma library\s*/, ''), context);
const logic = context;
const plain = value => JSON.parse(JSON.stringify(value));

assert.equal(logic.isNight(new Date(2026, 10, 6, 21, 59)), false);
assert.equal(logic.isNight(new Date(2026, 10, 6, 22, 0)), true);
assert.equal(logic.isNight(new Date(2026, 10, 6, 4, 59)), true);
assert.equal(logic.isNight(new Date(2026, 10, 6, 5, 0)), false);
for (const id of ['audio-output', 'theme-set', 'wifi-connect', 'bluetooth-connect']) assert.equal(logic.connectionState({ id, checked: true }), true);
assert.equal(logic.connectionState({ id: 'nightlight', checked: true }), null);

assert.equal(logic.greeting(new Date(2026, 10, 6, 9), 'fox'), 'good morning, fox');
assert.equal(logic.greeting(new Date(2026, 10, 6, 13), 'fox'), 'good afternoon, fox');
assert.equal(logic.greeting(new Date(2026, 10, 6, 19), ''), 'good evening');
assert.equal(logic.greeting(new Date(2026, 10, 6, 23), 'fox'), 'still up?');
assert.deepEqual(plain(logic.todayTags({ battery: '80%', batteryState: 'not charging', notes: 1,
    waiting: [{ project: 'Trader', argument: 'k1', asking: false, count: 2 }, { project: 'foxtag', argument: 'k2', asking: true }, { project: 'x' }] },
    [{ id: 'connections', summary: 'home' }, { id: 'sound', summary: '' }, { id: 'system', summary: '0 cached updates' }])),
    [{ text: '◇ 2 in Trader are waiting', action: 'agent-jump', argument: 'k1' }, { text: '◇ foxtag needs you', action: 'agent-jump', argument: 'k2' },
     { text: '80% · plugged in', page: 'power' }, { text: 'home', page: 'wifi' }, { text: '0 cached updates', page: 'updates' },
     { text: '1 agent note', page: 'agents' }]);
assert.equal(plain(logic.todayTags({ waiting: [{ project: 'Trader', argument: 'k', asking: true, count: 3 }] }, []))[0].text,
    '◇ 3 in Trader, one needs you');
const gardenCounts = [0, 1, 2, 3, 4, 8, 0, 9, 9, 0];
assert.deepEqual(plain(logic.gardenThresholds(gardenCounts)), [2, 4, 8]);
assert.deepEqual(plain(logic.gardenThresholds([0, 0])), [0, 0, 0]);
assert.deepEqual(gardenCounts.map(count => logic.gardenLevel(count, [2, 4, 8])), [0, 1, 1, 2, 2, 3, 0, 4, 4, 0]);
assert.deepEqual(plain(logic.gardenHearts(gardenCounts)), [8, 7, 5], 'the busiest three, a tie to the later day');
assert.deepEqual(plain(logic.gardenHearts([0, 0])), []);
assert.equal(logic.gardenSummary('2025-11-02', gardenCounts), '♥ 36 commits this year · longest streak 5 days · busiest nov 10 (9)');
assert.equal(logic.gardenSummary('2025-11-02', [0, 0]), 'the garden is waiting for its first commit');
assert.equal(logic.gardenSummary('2025-11-02', [0, 1234]), '♥ 1,234 commits this year · longest streak 1 day · busiest nov 3 (1234)');
assert.equal(logic.gardenReadout('2025-11-02', gardenCounts, 1, 9), 'mon, nov 3 · 1 commit');
assert.equal(logic.gardenReadout('2025-11-02', gardenCounts, 9, 9), 'today · no commits');
assert.equal(logic.gardenReadout('2025-11-02', gardenCounts, 12, 9), '');
assert.equal(logic.gardenDate('2025-12-28', 7).getFullYear(), 2026, 'days roll across the new year');
assert.deepEqual(plain(logic.gardenMonths('2025-11-02', 0, 10)), [{ week: 0, text: 'nov' }, { week: 5, text: 'dec' }, { week: 9, text: 'jan' }]);
assert.equal(logic.sinceLine(0), '');
assert.equal(logic.sinceLine(1), '✎ 1 commit since this morning');
assert.equal(logic.sinceLine(12), '✎ 12 commits since this morning');
assert.equal(logic.footerHint({ focus: 'tags' }), 'Enter opens · h / l choose · j goes to favorites · Esc goes back');
assert.deepEqual(plain(logic.todayTags(undefined, undefined)), []);
assert.equal(logic.heartLine(1), '♥ 1 day with a heart this month');
assert.equal(logic.paperIcon({ id: 'dnd', icon: '✉' }), 'paper-icon-bell.svg');
assert.equal(logic.paperIcon({ id: 'dnd', icon: '⊘' }), 'paper-icon-bell.svg');
assert.equal(logic.paperIcon({ id: 'today', icon: 'today' }), 'paper-icon-today.svg');

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

for (const state of [{focus:'groups'},{focus:'items'},{editing:true},{searching:true},{confirming:true},{busy:true}]) {
    const hint=logic.footerHint(state,{kind:'slider'});
    const parts=plain(logic.hintParts(hint));
    assert.equal(parts.map(part=>part.text).join(''),hint,'keycaps changed the shortcut instructions');
}
assert.deepEqual(plain(logic.hintParts('h / l choose')).filter(part=>part.key).map(part=>part.text),['h','l']);
assert.deepEqual(plain(logic.hintParts('/ searches')).filter(part=>part.key).map(part=>part.text),['/']);
assert.match(logic.emptyState('downloads',true,false).title,/matching/);
assert.match(logic.emptyState('bookmarks',false,false).detail,/press b/);
assert.match(logic.emptyState('root',false,true).title,/moment/);
console.log('keycap instructions and context-sensitive empty states: passed');

for (const width of [720,1080,1920]) {
    const sheetWidth=Math.min(790,width-32);
    for (const anchor of [{x:14,y:40,width:35},{x:width-140,y:55,width:126}]) {
        const p=logic.drawerPlacement(width,sheetWidth,anchor);
        assert.ok(p.left >= 0 && p.left+sheetWidth <= width);
        assert.ok(p.top < anchor.y, "paper must start behind the bookmark");
    }
}
assert.equal(logic.drawerPlacement(1920,790,null).top,63);
for (const width of [1920,1080,720]) {
    const sheet=Math.min(790,width-32);
    for (const anchor of [null,{x:14,y:32,width:36},{x:width-110,y:46,width:96}]) {
        const placement=logic.drawerPlacement(width,sheet,anchor,true);
        assert.equal(placement.top,0,'connected paper must reach the screen edge');
        assert.ok(placement.left>=0 && placement.left+sheet<=width);
    }
}
console.log('drawer attachment stays inside landscape and portrait outputs: passed');
assert.equal(logic.connectionState({id:'wifi-connect',checked:true}),true);
assert.equal(logic.connectionState({id:'wifi-connect',checked:false}),false);
assert.equal(logic.connectionState({id:'bluetooth-connect',checked:true}),true);
assert.equal(logic.connectionState({id:'bluetooth-connect',enabled:false}),null);
assert.equal(logic.connectionState({id:'wifi-toggle',checked:true}),null);
assert.equal(logic.connectionState({id:'wifi-connect'}),null);
assert.equal(logic.statusLabel({presentation:'media',mediaState:'Paused'}),'paused');
assert.equal(logic.statusLabel({presentation:'media',mediaState:'Playing'}),'');
assert.equal(logic.statusLabel({mediaState:'Paused'}),'');
assert.equal(logic.detailText({presentation:'media',mediaState:'Paused',detail:'Artist · Paused'},true),'Artist');
assert.equal(logic.detailText({presentation:'media',mediaState:'Paused',detail:'Paused'},true),'');
assert.equal(logic.detailText({presentation:'media',mediaState:'Paused',detail:'Artist · Paused'}),'Artist · Paused');

const menus=JSON.parse(fs.readFileSync(new URL('../shared/quickshell/foxml/menus.json',import.meta.url),'utf8'));
for (const group of menus.groups) assert.ok(logic.paperIcon(group).endsWith('.svg'));
for (const id of ['apps','vault','lock']) {
    const item=menus.groups.flatMap(group=>group.items).find(item=>item.id===id);
    assert.ok(logic.paperIcon(item).endsWith('.svg'));
    assert.equal(logic.paperIcon({...item,icon:'my-own-icon'}),'');
    assert.equal(logic.paperIcon({...item,icon:'★'}),'');
}
assert.equal(logic.paperIcon({id:'app-launch',icon:'firefox'}),'');
assert.equal(logic.paperIcon({id:'agent-jump',icon:'message'}),'paper-icon-mail.svg');
assert.equal(logic.paperIcon({id:'agent-clear',icon:'message'}),'paper-icon-mail.svg');
assert.equal(logic.paperIcon({id:'download-open',icon:'✉'}),'paper-icon-mail.svg');
assert.equal(logic.paperIcon({id:'window-focus',icon:'window'}),'paper-icon-window.svg');
assert.equal(logic.paperIcon({id:'password-copy',icon:'key'}),'paper-icon-passwords.svg');
assert.equal(logic.paperIcon({id:'clipboard-restore',icon:'clipboard'}),'paper-icon-clipboard.svg');
for (const item of menus.groups.flatMap(group=>group.items)) {
    const icon = logic.paperIcon(item);
    assert.ok(icon, 'Paper menu item is missing a themed icon: '+item.id);
    assert.ok(fs.existsSync(new URL('../templates/quickshell/foxml/'+icon, import.meta.url)));
    assert.equal(logic.paperIcon({...item,icon:'my-own-icon'}),'');
}
assert.equal(logic.emptyIllustration('downloads',false,false),'paper-empty-tray.svg');
assert.equal(logic.emptyIllustration('downloads',true,false),'paper-cat.png');
assert.equal(logic.emptyIllustration('downloads',false,true),'');
assert.equal(logic.pageFlourish('bookmarks',false),'circle');
assert.equal(logic.pageFlourish('root',true),'');

// Claude sessions: a working count on Today, plan usage, the state tag and the context hearts.
assert.deepEqual(plain(logic.todayTags({ claudeWorking: 2 }, [])), [{ text: '✎ 2 working', page: 'agents' }]);
assert.deepEqual(plain(logic.todayTags({ claudeWorking: 0 }, [])), []);
assert.equal(logic.claudeLine('22% of this 5h · 61% this week'), 'Claude · 22% of this 5h · 61% this week');
assert.equal(logic.claudeLine(''), '');
assert.equal(logic.statusLabel({ presentation: 'claude', claudeState: 'needs you' }), 'needs you');
assert.equal(logic.detailText({ presentation: 'claude', claudeState: 'working', detail: '41% of its context' }, true), '41% of its context');
assert.equal(logic.detailText({ presentation: 'claude', claudeState: 'working', detail: '41% of its context' }, false), 'working · 41% of its context',
    'without the paper tag the state rides in the detail');
assert.deepEqual([-1, 0, 9, 10, 41, 90, 100, 140].map(logic.contextHearts), [-1, 0, 0, 1, 2, 5, 5, 5]);
assert.equal(logic.contextHearts(undefined), -1);
console.log('claude session logic: ok');
