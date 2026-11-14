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
    [{ text: '✉ 2 in Trader are waiting', action: 'agent-jump', argument: 'k1' }, { text: '✉ foxtag needs you', action: 'agent-jump', argument: 'k2' },
     { text: '80% · plugged in', page: 'power' }, { text: '⌁ home', page: 'wifi' }, { text: '↻ 0 cached updates', page: 'updates' },
     { text: '✉ 1 agent note', page: 'agents' }]);
assert.equal(plain(logic.todayTags({ waiting: [{ project: 'Trader', argument: 'k', asking: true, count: 3 }] }, []))[0].text,
    '✉ 3 in Trader, one needs you');
// The garden closes the row once the sheet passes its hearts: unread, none yet, or the month's count.
assert.deepEqual(plain(logic.todayTags({}, [{ id: 'sound', summary: '11% · speakers' }], -1)),
    [{ text: '♪ 11% · speakers', page: 'audio-outputs' }, { text: '❦ the garden', page: 'garden' }]);
assert.equal(plain(logic.todayTags({}, [], 0))[0].text, '❦ no commits this month');
// Morning: last night's notes lead the row and open in Neovim; a running job that ran before says what's left.
assert.deepEqual(plain(logic.todayTags({ lastNight: [{ name: 'Linux_Theme', next: 'W3 /dev/shm', hasNext: true }, { name: 'x', next: 'did a thing', hasNext: false }] }, []))
    .slice(0, 2), [{ text: '☾ last night · Linux_Theme · next: W3 /dev/shm', action: 'goodnight-open', argument: 'Linux_Theme' },
                   { text: '☾ last night · x · did a thing', action: 'goodnight-open', argument: 'x' }]);
assert.equal(plain(logic.todayTags({ jobsRunning: 2, runningJob: { name: 'Build the engine', left: 'about 2m left' } }, []))[0].text,
    '◷ Build the engine · about 2m left · 2 running'.replace('◷', logic.glyphs ? logic.glyphs.jobs : '◷'));
assert.equal(plain(logic.todayTags({}, [], 1))[0].text, '❦ 1 day active this month');
assert.equal(plain(logic.todayTags({ battery: '9%' }, [], 12)).at(-1).text, '❦ 12 days active this month');
const gardenCounts = [0, 1, 2, 3, 4, 8, 0, 9, 9, 0];
assert.deepEqual(plain(logic.gardenThresholds(gardenCounts)), [2, 4, 8]);
assert.deepEqual(plain(logic.gardenThresholds([0, 0])), [0, 0, 0]);
assert.deepEqual(gardenCounts.map(count => logic.gardenLevel(count, [2, 4, 8])), [0, 1, 1, 2, 2, 3, 0, 4, 4, 0]);
assert.deepEqual(plain(logic.gardenHearts(gardenCounts)), [8, 7, 5], 'the busiest three, a tie to the later day');
assert.deepEqual(plain(logic.gardenHearts([0, 0])), []);
assert.equal(logic.gardenSummary('2025-11-02', gardenCounts), '· 36 commits this year · longest streak 5 days · busiest nov 10 (9)');
assert.equal(logic.gardenSummary('2025-11-02', [0, 0]), 'the garden is waiting for its first commit');
assert.equal(logic.gardenSummary('2025-11-02', [0, 1234]), '· 1,234 commits this year · longest streak 1 day · busiest nov 3 (1234)');
assert.equal(logic.gardenReadout('2025-11-02', gardenCounts, 1, 9), 'mon, nov 3 · 1 commit');
assert.equal(logic.gardenReadout('2025-11-02', gardenCounts, 9, 9), 'today · no commits');
assert.equal(logic.gardenReadout('2025-11-02', gardenCounts, 12, 9), '');
assert.equal(logic.gardenDate('2025-12-28', 7).getFullYear(), 2026, 'days roll across the new year');
assert.deepEqual(plain(logic.gardenMonths('2025-11-02', 0, 10)), [{ week: 0, text: 'nov' }, { week: 5, text: 'dec' }, { week: 9, text: 'jan' }]);
assert.equal(logic.sinceLine(0), '');
assert.equal(logic.sinceLine(1), '✎ 1 commit since this morning');
assert.equal(logic.sinceLine(12), '✎ 12 commits since this morning');
assert.deepEqual(plain(logic.todayTags(undefined, undefined)), []);
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
const shared = [{ id: 'work-open', argument: '1' }, { id: 'work-jump', argument: '%2' }, { id: 'work-open', argument: '2' }, { id: 'work-jump', argument: '%2' }];
assert.equal(logic.restoreIndex(shared, logic.identity(shared[3]), 3), 3, 'rows sharing an identity keep the cursor where it was');
assert.equal(logic.restoreIndex(shared.slice(0, 3), logic.identity({ id: 'gone' }), 5), 2, 'a row that is gone leaves the cursor on its neighbour');
assert.equal(logic.restoreIndex(rows, logic.identity({ id: 'gone' }), 1), 2, 'the neighbour is the nearest row that can be selected, the one below on a tie');
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
console.log('confirmation labels, full paths, exact dates and unavailable reasons: passed');

assert.equal(logic.pageHeading('Wi-Fi',true),'wi-fi.');
assert.equal(logic.pageHeading('API usage',true),'API usage.');
assert.equal(logic.pageHeading('Review with API credits',true),'review with API credits.');
assert.equal(logic.pageHeading('Shell tools',true),'shell tools.');
assert.equal(logic.pageHeading('GitHub',true),'GitHub.');
assert.equal(logic.pageHeading('today.',true),'today.');
assert.equal(logic.pageHeading('Delete this?',true),'delete this?');
assert.equal(logic.pageHeading("Caramel's notes",true),"caramel's notes.");
assert.equal(logic.pageHeading('Wi-Fi',false),'Wi-Fi');
assert.equal(logic.drawerBody('drawer',1080),842);
assert.equal(logic.drawerBody('drawer',800),624);
assert.equal(logic.drawerBody('drawer',3072),1536);
assert.equal(logic.drawerBody('drawer',2560),1280);
assert.equal(logic.drawerBody('drawer',1600),940);
assert.equal(logic.fitHeight(1602, 0, 908), 1602, 'unknown content: the full sheet');
assert.equal(logic.fitHeight(1602, 1180, 908), 1180, 'a tall screen stops where the page does');
assert.equal(logic.fitHeight(1602, 400, 908), 908, 'never shorter than the laptop sheet');
assert.equal(logic.fitHeight(908, 1400, 908), 908, 'a laptop keeps its usual sheet');
assert.equal(logic.fitHeight(1602, 2400, 908), 1602, 'a long page scrolls inside the screen limit');
assert.equal(logic.sectionHeading('in progress',true),'in progress');
assert.equal(logic.sectionHeading('AI',true),'AI');
assert.equal(logic.sectionHeading('upkeep',false),'UPKEEP');
const sectioned=[{kind:'heading',enabled:false,label:'upkeep'},{id:'updates'},{id:'storage'},{kind:'heading',enabled:false,label:'power'},{id:'power'}];
assert.equal(logic.nextIndex(sectioned,-1,1),1,'the first heading is passed over');
assert.equal(logic.nextIndex(sectioned,2,1),4,'down skips the next heading');
assert.equal(logic.nextIndex(sectioned,4,-1),2,'up skips it too');
assert.equal(logic.restoreIndex(sectioned,''),1,'a fresh tab starts on its first row, not its heading');
assert.equal(logic.headingAbove(sectioned,4),3);
assert.equal(logic.headingAbove(sectioned,2),2);
assert.equal(logic.rowCount(sectioned),3,'headings are not counted as rows');
const size={kind:'slider',id:'display-scale',argument:'DP-2',stop:1,stops:[{value:100,label:'100%',detail:'fits like 2160×3840'},{value:125,label:'125%',detail:'fits like 1728×3072'},{value:150,label:'150%',detail:'fits like 1440×2560'}]};
assert.ok(logic.hasStops(size));
assert.deepEqual(plain(logic.actionArguments(size,150,false)),['run','display-scale','DP-2=150'],'a stop slider names its screen and the value');
assert.deepEqual(plain(logic.actionArguments({kind:'slider',id:'volume'},40,false)),['run','volume','40'],'a plain slider sends its value alone');
assert.equal(logic.sliderPosition(size,false,0),50);
assert.equal(logic.sliderPosition(size,true,2),100);
assert.equal(logic.valueText(size,false,0),'125%');
assert.equal(logic.valueText(size,true,0),'100%');
assert.equal(logic.stopDetail(size,1),'now · 125% · fits like 1728×3072');
assert.equal(logic.stopDetail(size,2),'Enter for 150% · fits like 1440×2560');
assert.equal(logic.pageHeading('Acer B277K L',true),'acer B277K L.');
assert.equal(logic.pageHeading('A look at your day',true),'a look at your day.');
assert.ok(logic.scopedPage('display') && logic.scopedPage('display-modes') && logic.scopedPage('worktrees') && !logic.scopedPage('displays'));
assert.deepEqual(plain(logic.breadcrumbs('cheatsheet-keys','system',['cheatsheet'],[{id:'system',label:'System',items:[]}],'Desktop',{cheatsheet:'Shortcut reference'})).map(c=>c.label),['System','Shortcut reference','Desktop'],'a page seen earlier names itself in the trail');
assert.ok(logic.scopedPage('cheatsheet-keys') && !logic.scopedPage('cheatsheet'), 'a section of the reference names its book; the landing page does not');
assert.equal(logic.nextIndex(sectioned,sectioned.length,-1),4,'G lands on the last row');
assert.equal(logic.drawerBody('calendar',3072),590);
assert.equal(logic.drawerBody('prompt',1080),310);
assert.match(logic.emptyState('downloads',true,false).title,/matching/);
assert.match(logic.emptyState('bookmarks',false,false).detail,/press b/);
assert.match(logic.emptyState('root',false,true).title,/moment/);
assert.equal(logic.emptyState('updates',false,false).title,'all up to date.');
assert.equal(logic.emptyState('failures',false,false).title,'nothing has failed today.');
assert.equal(logic.emptyState('jobs',false,false).title,'no jobs yet.');
assert.equal(logic.emptyState('test-results',false,false).title,'no test runs yet.');
assert.equal(logic.emptyState('reviews',false,false).title,'no changes waiting.');
assert.match(logic.emptyState('next-steps',false,false).detail,/press n on a project card/);
assert.match(logic.emptyState('screenshots',false,false).detail,/alt ⇧ o takes one/);
assert.match(logic.emptyState('unknown-page',false,false).title,/nothing here yet/);
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
const workTags=logic.todayTags({jobsRunning:2,jobsFinished:1,jobsFailed:1,changesToReview:3,nextStep:'rerun the sanitizer'},[]);
assert.ok(workTags.some(t=>t.page==='jobs' && t.text.includes('2 jobs running')));
assert.ok(workTags.some(t=>t.page==='reviews' && t.text==='◎ 3 changes to look over'));
assert.ok(workTags.some(t=>t.page==='next-steps' && t.text==='↳ next: rerun the sanitizer'));
assert.equal(plain(logic.todayTags({jobsRunning:1,jobsFinished:0},[]))[0].text,'◷ 1 job running');
assert.equal(plain(logic.todayTags({jobsRunning:0,jobsFinished:287},[]))[0].text,'◷ 287 jobs finished');
assert.equal(plain(logic.todayTags({jobsRunning:2,jobsFinished:1},[]))[0].text,'◷ 2 jobs running · 1 finished');
assert.deepEqual(plain(logic.todayTags({jobsRunning:0,jobsFinished:0},[])),[]);
assert.ok(workTags.some(t=>t.page==='next-steps' && t.text.includes('rerun the sanitizer')));
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
// One glyph per item: no two items share one, a menu's older glyph maps to the item's own, a custom one stays.
const glyphOwners={};
for (const [id,glyph] of Object.entries(logic.glyphs)) if (id!=='passwords') {
    assert.ok(!glyphOwners[glyph], `${id} and ${glyphOwners[glyph]} share ${glyph}`);
    glyphOwners[glyph]=id;
}
const shown=new Map();
for (const row of [...menus.groups,...menus.groups.flatMap(group=>group.items)]) {
    const glyph=logic.symbol(row);
    assert.ok(!shown.has(glyph) || shown.get(glyph)===row.id, `${row.id} and ${shown.get(glyph)} both show ${glyph}`);
    shown.set(glyph,row.id);
}
assert.equal(logic.symbol({id:'next-steps',icon:'◇'}),'↳');
assert.equal(logic.symbol({id:'models',icon:'◈'}),'⬡');
assert.equal(logic.symbol({id:'idle',icon:'◷'}),'⊙');
assert.equal(logic.symbol({id:'next-steps',icon:'★'}),'★');
assert.equal(logic.paperIcon({id:'next-steps',icon:'↳'}),'paper-icon-next.svg');
assert.equal(logic.paperIcon({id:'clipboard-images',icon:'▧'}),'paper-icon-clipboard.svg');
assert.equal(logic.paperIcon({id:'models',icon:'★'}),'');
assert.equal(logic.emptyIllustration('downloads',false,false),'paper-empty-tray.svg');
assert.equal(logic.emptyIllustration('downloads',true,false),'paper-sprig.png');
assert.equal(logic.emptyIllustration('downloads',false,true),'');
assert.equal(logic.pageFlourish('bookmarks',false),'circle');
assert.equal(logic.pageFlourish('root',true),'');

// Claude sessions: a working count on Today, plan usage, the state tag and the context hearts.
assert.deepEqual(plain(logic.todayTags({ claudeWorking: 2 }, [])), [{ text: '⋯ 2 working', page: 'agents' }]);
assert.deepEqual(plain(logic.todayTags({ claudeWorking: 0 }, [])), []);
assert.deepEqual(plain(logic.todayTags({ dueSoon: [{ title: 'Assignment 4', course: 'CS 303', when: 'tomorrow 11:59 pm' }] }, [])),
                 [{ text: '✎ Assignment 4 · CS 303 · due tomorrow 11:59 pm', page: 'calendar' }], 'a deadline is a tag that opens the calendar');
assert.deepEqual(plain(logic.todayTags({ claudeWorking: 2, claudeSessions: 4 }, [])), [{ text: '⋯ 2 of 4 working', page: 'agents' }], 'the waiting ones still count');
assert.equal(logic.claudeLine('76% of the week left · refills sun'), 'Claude · 76% of the week left · refills sun');
assert.equal(logic.claudeLine(''), '');
assert.equal(logic.claudeLine('76% of the week left · refills sun', 130), 'Claude · 2h 10m today · 76% of the week left · refills sun');
assert.equal(logic.claudeLine('', 40), 'Claude · 40m today');
assert.equal(logic.claudeTime(0), '');
assert.equal(logic.claudeTime(120), '2h today');
assert.equal(logic.claudeTime(undefined), '');
assert.equal(logic.statusLabel({ presentation: 'claude', claudeState: 'needs you' }), 'needs you');
assert.equal(logic.detailText({ presentation: 'claude', claudeState: 'working', detail: '41% of its context' }, true), '41% of its context');
assert.equal(logic.detailText({ presentation: 'claude', claudeState: 'working', detail: '41% of its context' }, false), 'working · 41% of its context',
    'without the paper tag the state rides in the detail');
assert.deepEqual([-1, 0, 9, 10, 41, 90, 100, 140].map(logic.contextHearts), [-1, 0, 0, 1, 2, 5, 5, 5]);
assert.equal(logic.contextHearts(undefined), -1);
console.log('claude session logic: ok');
