import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "DrawerLogic.js" as Logic

ShellRoot {
    id: root

    property bool pickerActive: false
    property bool pickerPrompt: false
    property var pickerItems: []
    property string pickerResponse: ""
    property bool opened: false
    property bool searching: false
    property string searchPage: "search"
    property bool editing: false
    property bool actionBusy: false
    property string page: "root"
    property string pageTitle: "today."
    property string groupId: ""
    property string message: ""
    property bool failed: false
    property var groups: []
    property var entries: []
    property var creditSnapshot: null
    property var trail: []
    readonly property var breadcrumbs: Logic.breadcrumbs(page, groupId, trail, groups, pageTitle)
    property var remembered: ({})
    property string focusArea: "groups"
    property int groupIndex: 0
    property int itemIndex: 0
    property int tagIndex: 0
    readonly property var todayTags: Logic.todayTags(today, groups)
    property int draftValue: 0
    readonly property bool calendarLayout: page === "calendar" && !pickerLayout
    readonly property bool scrapbookLayout: page === "screenshots" && !pickerLayout
    readonly property bool gardenLayout: page === "garden" && !pickerLayout
    property var garden: null
    property int gardenIndex: -1
    property bool viewFailed: false
    readonly property string footerHint: calendarLayout ? "h / l changes month · t today · g the garden · Esc closes" : scrapbookLayout ? "arrows choose · c copies · Enter opens · Esc goes back" : gardenLayout ? "h / l a week · j / k a day · Esc goes back" : Logic.footerHint({confirming: pendingConfirm !== null, busy: actionBusy,
        prompt: pickerActive && pickerPrompt, searching: searching, picker: pickerActive,
        editing: editing, focus: focusArea}, entries[itemIndex])
    property var pendingConfirm: null
    property bool confirmYes: false
    property string worktreeProject: ""
    property int viewSerial: 0
    property int navigationSerial: 0
    property bool drawerReady: true
    // A page change is pending. The 4s background refresh never sets this, so it can't blink a page.
    property bool pageLoading: false
    property var today: ({})
    property var nextView: null
    property var nextAction: null
    property string backend: Quickshell.env("FOXML_DRAWER_BACKEND") || "fox-drawer"
    property string barStatePath: Quickshell.env("FOXML_DRAWER_BAR_STATE") || (Quickshell.env("FOXML_DRAWER_PREVIEW") === "1" ? ""
        : (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/waybar/drawer-state.css")
    property string lastBarStyle: ""

    onOpenedChanged: barWrite.restart()
    onPageChanged: barWrite.restart()
    onGroupIdChanged: barWrite.restart()

    function syncBar(closing) {
        if (!barStatePath) return;
        var css = Logic.barStyle(closing ? false : opened, page, groupId);
        if (css === lastBarStyle) return;
        barStyle.setText(css);
        lastBarStyle = css;
    }

    Theme { id: theme }
    readonly property alias paperTheme: theme
    LevelSlip { id: levelSlip; theme: root.paperTheme; output: root.focusedScreen }
    IpcHandler {
        target: "volume"
        function present(value: int, muted: bool): void { levelSlip.showVolume(value, muted); }
        function status(): string { return JSON.stringify({visible:levelSlip.showing && levelSlip.kind === "sound", value:levelSlip.value, muted:levelSlip.muted}); }
    }
    IpcHandler {
        target: "brightness"
        function present(value: int): void { levelSlip.showBrightness(value); }
        function status(): string { return JSON.stringify({visible:levelSlip.showing && levelSlip.kind === "light", value:levelSlip.value}); }
    }

    property bool barEnabled: Quickshell.env("FOXML_BAR_AUTOSTART") === "1" || Quickshell.env("FOXML_DRAWER_PREVIEW") !== "1"
    property var attachment: null
    property var openScreen: null
    property bool closingPicker: false
    readonly property bool pickerLayout: opened ? pickerActive : closingPicker
    readonly property var focusedScreen: Quickshell.screens.find(function(output) {
        return Hyprland.focusedMonitor && output.name === Hyprland.focusedMonitor.name;
    }) || Quickshell.screens[0] || null
    readonly property var resolvedAnchor: attachment && desktopBar.item ? desktopBar.item.anchorFor(attachment.screenName, attachment.moduleName) : null
    readonly property var drawerScreen: resolvedAnchor ? resolvedAnchor.screen : openScreen || focusedScreen
    readonly property var drawerHost: desktopBar.item && drawerScreen ? desktopBar.item.hostFor(drawerScreen.name) : null
    readonly property real drawerTopInset: theme.paperDetails && drawerHost ? drawerHost.barHeight : 0
    readonly property var drawerPlacement: panel.placement
    readonly property real drawerWidth: panel.implicitWidth
    readonly property real drawerHeight: panel.implicitHeight
    property real drawerReveal: opened ? 1 : 0
    readonly property bool drawerVisible: opened || drawerReveal > .001
    Behavior on drawerReveal { NumberAnimation { duration: theme.paperDetails ? 220 : 160; easing.type: Easing.OutCubic } }
    Loader {
        id: desktopBar
        active: root.barEnabled
        source: "PaperBar.qml"
        onLoaded: item.controller = root
    }
    IpcHandler {
        target: "bar"
        function start(): void { root.barEnabled = true; if (desktopBar.item) desktopBar.item.shown = true; }
        function show(): void { root.barEnabled = true; if (desktopBar.item) desktopBar.item.shown = true; }
        function hide(): void { if (desktopBar.item) desktopBar.item.shown = false; }
        function toggle(): void { if (!root.barEnabled) root.barEnabled = true; else if (desktopBar.item) desktopBar.item.shown = !desktopBar.item.shown; }
        function refresh(name: string): void { if (desktopBar.item) desktopBar.item.refresh(name); }
        function status(): string {
            return JSON.stringify(desktopBar.item ? desktopBar.item.status() : {enabled:root.barEnabled, ready:false, visible:false, error:""});
        }
    }
    function placeAtLauncher() {
        openScreen = focusedScreen;
        attachment = desktopBar.item && desktopBar.item.shown && openScreen ? {screenName:openScreen.name, moduleName:"custom/logo"} : null;
    }
    function showFromBar(pageId, screenName, moduleName) {
        if (opened && page === pageId) { hide(); return; }
        show(pageId);
        openScreen = Quickshell.screens.find(function(output) {return output.name === screenName;}) || focusedScreen;
        attachment = {screenName:screenName, moduleName:moduleName};
    }

    FileView {
        id: barStyle
        path: root.barStatePath
        preload: false
        atomicWrites: true
        blockWrites: true
        printErrors: false
        onSaveFailed: error => console.warn("Could not update the Waybar drawer marker:", error)
    }
    Timer { id: barWrite; interval: 40; onTriggered: root.syncBar(false) }

    FileView { id: pickerRequest; preload: false; blockLoading: true; blockAllReads: true; printErrors: false }
    FileView { id: pickerReply; preload: false; blockLoading: true; blockAllReads: true; atomicWrites: true; blockWrites: true; printErrors: false }

    function finishPicker(response) {
        if (!pickerActive) return;
        pickerReply.path = pickerResponse;
        pickerReply.reload();
        pickerReply.text();
        pickerReply.setText(JSON.stringify(response));
        pickerActive = false;
        pickerItems = [];
        pickerResponse = "";
    }

    function showPicker(path) {
        var prefix = (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/foxml-picker-";
        if (path.indexOf(prefix) !== 0 || !/^[A-Za-z0-9]{6}\/request\.json$/.test(path.slice(prefix.length))) return;
        pickerRequest.path = path;
        pickerRequest.reload();
        var data;
        try { data = JSON.parse(pickerRequest.text()); } catch (error) { return; }
        if (!data || typeof data.title !== "string" || !Array.isArray(data.items) || data.items.length > 10000) return;
        if (!opened) placeAtLauncher();
        finishPicker({cancel: true});
        finishEdit();
        remember();
        pickerActive = true;
        pickerPrompt = data.prompt === true;
        pickerResponse = path.replace(/request\.json$/, "response.json");
        pickerItems = data.items.map(function(label, index) {
            return {id: "picker-entry", label: String(label), kind: "action", argument: String(index), pickerIndex: index, enabled: true};
        });
        opened = true;
        searching = pickerPrompt;
        editing = false;
        pendingConfirm = null;
        nextView = null;
        viewSerial++;
        navigationSerial++;
        page = "picker";
        pageTitle = data.title;
        groupId = "";
        trail = [];
        entries = pickerItems;
        itemIndex = 0;
        drawerReady = true;
        pageLoading = false;
        focusArea = "items";
        searchInput.text = "";
        note("");
        Qt.callLater(function() { if (root.pickerPrompt) searchInput.forceActiveFocus(); else keyboard.forceActiveFocus(); });
    }

    function backendCommand(args) {
        return [backend].concat(["--config", Quickshell.shellPath("menus.json")]).concat(args);
    }

    function note(text, error) {
        message = text;
        failed = error === true;
    }

    function buttonShade(pressed, hovered) {
        return pressed ? (theme.paperDetails ? Qt.alpha(theme.highlight, .8) : Qt.alpha(theme.line, .4)) : hovered ? (theme.paperDetails ? theme.hoverFill : Qt.alpha(theme.surface, .6)) : "transparent";
    }

    function remember() {
        if (page !== "root" && entries.length) {
            var saved = Object.assign({}, remembered);
            saved[page] = { key: Logic.identity(entries[itemIndex]), scroll: itemList.contentY };
            remembered = saved;
        }
    }

    // A page reply still in flight must not land on whatever is showing now.
    function dropView() {
        nextView = null;
        viewSerial++;
        if (viewProcess.running) viewProcess.running = false;
    }

    function requestView() {
        if (!opened || pendingConfirm || calendarLayout) return;
        if (pickerActive) {
            var needle = searching ? searchInput.text.toLowerCase() : "";
            entries = pickerItems.filter(function(row) { return row.label.toLowerCase().indexOf(needle) >= 0; });
            itemIndex = 0;
            return;
        }
        if (page === "root" && !searching) {
            dropView();
            if (!groupProcess.running) groupProcess.running = true;
            return;
        }
        nextView = { serial: ++viewSerial, page: searching ? searchPage : page,
                     query: searching ? searchInput.text : "", filter: searching };
        // One page loads at a time; leaving a page gives up its load so a slow one can't hold the next.
        if (viewProcess.running && viewProcess.requestedPage !== nextView.page) viewProcess.running = false;
        startView();
    }

    function startView() {
        if (viewProcess.running || !nextView) return;
        var request = nextView;
        nextView = null;
        viewProcess.serial = request.serial;
        viewProcess.requestedPage = request.page;
        viewProcess.command = backendCommand(["view", request.page].concat(request.filter ? [request.query] : [])
            .concat(request.page === "worktrees" && worktreeProject ? ["--project", worktreeProject] : []));
        viewProcess.running = true;
    }

    function viewTimedOut(serial) {
        if (serial !== viewSerial || !opened) return;
        pageLoading = false;
        drawerReady = true;
        viewFailed = true;
        note("That page took too long to open. Try it again in a moment.", true);
    }

    function applyView(serial, requestedPage, output, exitCode, diagnostic) {
        if (serial !== viewSerial || !opened) return;
        pageLoading = false;
        try {
            var data = JSON.parse(output);
            var partial = exitCode !== 0 || Boolean(data.error);
            var recovered = viewFailed && !partial;
            viewFailed = partial;
            if (partial && !Array.isArray(data.items)) {
                note(data.error || "This drawer could not be read.", true);
                return;
            }
            var oldKey = Logic.identity(entries[itemIndex]);
            var samePage = entries.length && itemList.viewPage === requestedPage;
            var saved = remembered[page];
            entries = Array.isArray(data.items) ? data.items : [];
            creditSnapshot = requestedPage === "api-credits" ? data.credits || null : null;
            pageTitle = data.title || page;
            drawerReady = true;
            if (data.group && !searching) {
                groupId = data.group;
                var gi = groups.findIndex(function(g) { return g.page === groupId || g.id === groupId; });
                if (gi >= 0 && focusArea !== "groups") groupIndex = gi;
            }
            itemIndex = Logic.restoreIndex(entries, samePage ? oldKey : (saved ? saved.key : ""));
            if (requestedPage === "garden") {
                garden = data.garden || null;
                var planted = garden && Array.isArray(garden.counts) ? garden.counts.length : 0;
                if (!samePage || gardenIndex >= planted) gardenIndex = planted - 1;
            }
            itemList.viewPage = requestedPage;
            if (scrapbookLayout) Qt.callLater(function() { scrapbookSheet.reveal(root.itemIndex); });
            if (!samePage) {
                Qt.callLater(function() {
                    itemList.contentY = saved && !searching ? saved.scroll : 0;
                    // A first visit reads from the top even when the first live row sits below a page of notes.
                    if (saved || searching) itemList.positionViewAtIndex(itemIndex, ListView.Contain);
                });
            }
            if (partial) note(data.error || "Some controls are unavailable.", true);
            else if (recovered) note("a little order, restored.");
        } catch (error) {
            viewFailed = true;
            note(exitCode !== 0 ? "The drawer service is unavailable. " + diagnostic.trim().slice(0, 180)
                               : "The drawer service returned an unreadable reply.", true);
        }
    }

    function show(pageId) {
        previewTimer.stop();
        // Rows are remembered while the drawer stays open; each fresh open starts every page at the top.
        if (!opened) { placeAtLauncher(); remembered = ({}); }
        finishPicker({cancel: true});
        opened = true;
        searching = false;
        editing = false;
        pendingConfirm = null;
        searchInput.text = "";
        trail = [];
        page = pageId || "root";
        searching = page === "search";
        if (searching) searchPage = "search";
        pageLoading = true;
        navigationSerial++;
        focusArea = page === "root" ? "groups" : "items";
        note("");
        if (calendarLayout) {
            openScreen = focusedScreen;
            attachment = desktopBar.item && desktopBar.item.shown && openScreen ? {screenName:openScreen.name, moduleName:"custom/clock"} : null;
            nextView = null;
            viewSerial++;
            entries = [];
            groupId = "";
            pageTitle = "calendar";
            pageLoading = false;
            drawerReady = true;
            calendarSheet.reset();
            if (viewProcess.running) viewProcess.running = false;
            Qt.callLater(function() { keyboard.forceActiveFocus(); });
            return;
        }
        if (!groupProcess.running) groupProcess.running = true;
        if (page === "root") {
            dropView();
            entries = [];
            pageTitle = "today.";
            groupId = "";
            groupIndex = 0;
        } else {
            entries = [];
            requestView();
        }
        Qt.callLater(function() { if (root.searching) searchInput.forceActiveFocus(); else keyboard.forceActiveFocus(); });
    }

    function hide(response) {
        closingPicker = pickerActive;
        finishPicker(response || {cancel: true});
        finishEdit();
        remember();
        opened = false;
        editing = false;
        searching = false;
        pendingConfirm = null;
        dropView();
        previewTimer.stop();
        navigationSerial++;
    }

    // Moving through the sidebar shows each drawer as you pass it; the keyboard stays in the sidebar.
    function previewGroup(index) {
        if (!opened || focusArea !== "groups" || pickerActive || searching || editing || pendingConfirm || calendarLayout) return;
        var group = groups[index];
        if (!group) return;
        var target = group.page || group.id;
        if (target === "root") { if (page !== "root" || trail.length) show("root"); return; }
        if (page === target && !trail.length) return;
        remember();
        groupId = target;
        trail = [];
        page = target;
        navigationSerial++;
        note("");
        drawerReady = false;
        pageLoading = true;
        entries = [];
        requestView();
    }

    function chooseGroup(index) {
        if (pickerActive) return;
        if (!groups[index]) return;
        previewTimer.stop();
        remember();
        groupIndex = index;
        if (groups[index].page === "root") {
            // Today is already showing, so Enter steps down into the favorites beneath it, or its tags.
            if (page === "root") {
                if (entries.length) focusArea = "items";
                else if (todayTags.length) { focusArea = "tags"; tagIndex = 0; }
            }
            else show("root");
            return;
        }
        // The preview already brought this drawer up, so Enter only steps into it.
        if (page === (groups[index].page || groups[index].id) && !trail.length && !searching) {
            focusArea = "items";
            keyboard.forceActiveFocus();
            return;
        }
        groupId = groups[index].page || groups[index].id;
        trail = [];
        page = groupId;
        navigationSerial++;
        note("");
        drawerReady = false;
        pageLoading = true;
        entries = [];
        editing = false;
        searching = false;
        pendingConfirm = null;
        focusArea = "items";
        requestView();
        keyboard.forceActiveFocus();
    }

    function goBack() {
        if (calendarLayout) { hide(); return; }
        if (pickerActive && (pickerPrompt || !searching)) { hide(); return; }
        if (pendingConfirm) { pendingConfirm = null; return; }
        if (editing) { finishEdit(); return; }
        if (searching) {
            if (page === "search") { hide(); return; }
            searching = false;
            navigationSerial++;
            searchInput.text = "";
            itemList.viewPage = "";
            requestView();
            keyboard.forceActiveFocus();
            return;
        }
        if (trail.length) {
            remember();
            var stack = trail.slice();
            page = stack.pop();
            navigationSerial++;
            note("");
            drawerReady = false;
            pageLoading = true;
            trail = stack;
            entries = [];
            requestView();
        } else if (focusArea === "items" || focusArea === "tags") {
            remember();
            focusArea = "groups";
            note("");
        } else hide();
    }

    function startSearch() {
        remember();
        editing = false;
        searching = true;
        navigationSerial++;
        searchPage = page !== "root" && !groups.some(function(g) { return g.id === page || g.page === page; }) ? page : "search";
        focusArea = "items";
        searchInput.text = "";
        requestView();
        Qt.callLater(function() { searchInput.forceActiveFocus(); });
        note("");
    }

    function step(delta) {
        if (pendingConfirm) { confirmYes = !confirmYes; return; }
        if (editing) return;
        if (focusArea === "groups") {
            groupIndex = Logic.nextIndex(groups, groupIndex, delta);
            groupList.positionViewAtIndex(groupIndex, ListView.Contain);
            previewTimer.restart();
        } else if (focusArea === "tags") {
            if (delta > 0 && entries.length) { focusArea = "items"; itemIndex = Logic.nextIndex(entries, -1, 1); itemList.positionViewAtIndex(itemIndex, ListView.Contain); }
        } else if (delta < 0 && page === "root" && !searching && !pickerActive && todayTags.length && itemIndex === Logic.nextIndex(entries, -1, 1)) {
            // Up from the first favorite reaches the tags above it.
            focusArea = "tags";
            tagIndex = Math.min(tagIndex, todayTags.length - 1);
        } else {
            itemIndex = Logic.nextIndex(entries, itemIndex, delta);
            itemList.positionViewAtIndex(itemIndex, ListView.Contain);
        }
    }

    // The calendar is a small sheet under the clock; the garden is a full drawer page, so it reopens at the launcher.
    function gardenFromCalendar() {
        if (!calendarLayout) return;
        placeAtLauncher();
        show("garden");
    }

    function openTag(tag) {
        if (!tag || actionBusy || pendingConfirm) return;
        if (tag.page) {
            focusArea = "items";
            activate({id: tag.page, kind: "page", page: tag.page, label: tag.text});
        } else if (tag.action) runAction({id: tag.action, action: tag.action, argument: tag.argument, label: tag.text, kind: "action", close: true}, undefined, false);
    }

    function screenshotAction(index, action) {
        if (actionBusy || !entries[index]) return;
        var item = Object.assign({}, entries[index], {id:action, close:action !== "screenshot-copy"});
        runAction(item, undefined, false);
    }

    function activate(item, confirmed) {
        if (pickerActive) {
            if (pickerPrompt) {
                if (!searchInput.text.trim()) return;
                hide({text: searchInput.text});
            } else if (item && item.enabled !== false) { hide({index: item.pickerIndex}); }
            return;
        }
        if (!item || item.enabled === false || actionBusy) return;
        if (searching && searchPage === "search" && item.group && (item.kind === "slider" || item.kind === "toggle")) {
            searching = false;
            searchInput.text = "";
            page = item.group;
            groupId = item.group;
            navigationSerial++;
            trail = [];
            var saved = Object.assign({}, remembered);
            saved[page] = { key: Logic.identity(item), scroll: 0 };
            remembered = saved;
            pageLoading = true;
            entries = [];
            itemList.viewPage = "";
            requestView();
            keyboard.forceActiveFocus();
            note("");
            return;
        }
        if (item.kind === "page") {
            if ((item.page || item.id) === "worktrees") worktreeProject = "";
            remember();
            if (searching) {
                searching = false;
                searchInput.text = "";
                trail = [];
            } else trail = trail.concat([page]);
            page = item.page || item.id;
            navigationSerial++;
            note("");
            drawerReady = false;
            pageLoading = true;
            entries = [];
            requestView();
            keyboard.forceActiveFocus();
            return;
        }
        if (item.kind === "slider") {
            draftValue = Math.round(Number(item.value || 0));
            editing = true;
            note("");
            return;
        }
        if (item.confirm && !confirmed) {
            pendingConfirm = item;
            confirmYes = false;
            return;
        }
        runAction(item, undefined, confirmed === true);
    }

    function bookmark(item) {
        if (!item || item.presentation !== "project" || actionBusy || pendingConfirm) return;
        runAction(Object.assign({}, item, {id: "project-bookmark", action: "project-bookmark", close: false}), undefined, false);
    }

    function eject(item) {
        if (!item || item.presentation !== "library" || actionBusy || pendingConfirm) return;
        activate({id: "drive-eject", argument: item.ejectArgument, label: "Eject drive", kind: "action",
            confirm: "Eject this drive? All its volumes will be unmounted. Save your open files first."});
    }

    function runAction(item, value, confirmed) {
        nextAction = { item: item, args: Logic.actionArguments(item, value, confirmed) };
        startAction();
    }

    function startAction() {
        if (actionProcess.running || !nextAction) return;
        var job = nextAction;
        nextAction = null;
        actionProcess.item = job.item;
        actionProcess.location = navigationSerial;
        actionProcess.command = backendCommand(job.args);
        actionBusy = true;
        actionProcess.running = true;
    }

    function adjust(delta) {
        var item = entries[itemIndex];
        if (!editing || !item || item.kind !== "slider") return;
        draftValue = Math.max(0, Math.min(100, draftValue + delta));
        sliderWrite.item = item;
        sliderWrite.value = draftValue;
        sliderWrite.restart();
    }

    function finishEdit() {
        if (!editing) return;
        editing = false;
        if (sliderWrite.running) {
            sliderWrite.stop();
            runAction(sliderWrite.item, sliderWrite.value, false);
        } else if (!actionBusy) requestView();
    }

    function key(event) {
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
        var k = event.key;
        if (calendarLayout) {
            if (k === Qt.Key_Escape || k === Qt.Key_Q) hide();
            else if (k === Qt.Key_H || k === Qt.Key_Left || k === Qt.Key_PageUp) calendarSheet.moveMonth(-1);
            else if (k === Qt.Key_L || k === Qt.Key_Right || k === Qt.Key_PageDown) calendarSheet.moveMonth(1);
            else if (k === Qt.Key_T || k === Qt.Key_Home) calendarSheet.reset();
            else if (k === Qt.Key_G) gardenFromCalendar();
            else return;
            event.accepted = true;
            return;
        }
        if (gardenLayout && focusArea === "items" && !searching && !pendingConfirm) {
            var planted = garden && Array.isArray(garden.counts) ? garden.counts.length : 0;
            if (k === Qt.Key_Q) hide();
            else if (k === Qt.Key_Escape) goBack();
            else if (k === Qt.Key_Slash) startSearch();
            else if (k === Qt.Key_F) show("root");
            else if (k === Qt.Key_Left || k === Qt.Key_H) { if (gardenIndex < 7) goBack(); else gardenIndex -= 7; }
            else if (k === Qt.Key_Right || k === Qt.Key_L) gardenIndex = Math.min(planted - 1, gardenIndex + 7);
            else if (k === Qt.Key_Up || k === Qt.Key_K) gardenIndex = Math.max(0, gardenIndex - 1);
            else if (k === Qt.Key_Down || k === Qt.Key_J) gardenIndex = Math.min(planted - 1, gardenIndex + 1);
            else if (k === Qt.Key_T || k === Qt.Key_Home) gardenIndex = planted - 1;
            else return;
            event.accepted = true;
            return;
        }
        if (scrapbookLayout && focusArea === "items" && !searching && !pendingConfirm) {
            if (k === Qt.Key_Q) hide();
            else if (k === Qt.Key_Escape) goBack();
            else if (k === Qt.Key_Slash) startSearch();
            else if (k === Qt.Key_F) show("root");
            else if (k === Qt.Key_Left || k === Qt.Key_H) {
                if (itemIndex % scrapbookSheet.columns === 0) goBack(); else itemIndex--;
            }
            else if (k === Qt.Key_Right || k === Qt.Key_L) itemIndex = Math.min(entries.length - 1, itemIndex + 1);
            else if (k === Qt.Key_Up || k === Qt.Key_K) itemIndex = Math.max(0, itemIndex - scrapbookSheet.columns);
            else if (k === Qt.Key_Down || k === Qt.Key_J) itemIndex = Math.min(entries.length - 1, itemIndex + scrapbookSheet.columns);
            else if (k === Qt.Key_C) screenshotAction(itemIndex, "screenshot-copy");
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) activate(entries[itemIndex]);
            else return;
            itemIndex = Math.max(0, itemIndex);
            event.accepted = true;
            return;
        }
        if (searching) {
            if (k === Qt.Key_Escape) { goBack(); event.accepted = true; }
            else if (k === Qt.Key_Down || k === Qt.Key_Up) { step(k === Qt.Key_Down ? 1 : -1); event.accepted = true; }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
                activate(entries[itemIndex]); event.accepted = true;
            }
            return;
        }
        if (pickerActive) {
            if (k === Qt.Key_Escape || k === Qt.Key_H || k === Qt.Key_Left || k === Qt.Key_Q) goBack();
            else if (k === Qt.Key_J || k === Qt.Key_Down) step(1);
            else if (k === Qt.Key_K || k === Qt.Key_Up) step(-1);
            else if (k === Qt.Key_L || k === Qt.Key_Right || k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) activate(entries[itemIndex]);
            else if (k === Qt.Key_Slash) startSearch();
            else return;
            event.accepted = true;
            return;
        }
        if (focusArea === "tags" && !editing && !pendingConfirm) {
            var tagCount = todayTags.length;
            if (!tagCount || page !== "root") { focusArea = entries.length ? "items" : "groups"; event.accepted = true; return; }
            tagIndex = Math.max(0, Math.min(tagIndex, tagCount - 1));
            if (k === Qt.Key_Escape) goBack();
            else if (k === Qt.Key_Q) hide();
            else if (k === Qt.Key_H || k === Qt.Key_Left) { if (tagIndex > 0) tagIndex--; else goBack(); }
            else if (k === Qt.Key_L || k === Qt.Key_Right) tagIndex = Math.min(tagCount - 1, tagIndex + 1);
            else if (k === Qt.Key_J || k === Qt.Key_Down) step(1);
            else if (k === Qt.Key_K || k === Qt.Key_Up) {}
            else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) openTag(todayTags[tagIndex]);
            else if (k === Qt.Key_Slash) startSearch();
            else if (k === Qt.Key_F) show("root");
            else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) focusArea = "groups";
            else return;
            event.accepted = true;
            return;
        }
        if (k === Qt.Key_Escape) goBack();
        else if (k === Qt.Key_R && !editing && !pendingConfirm && !actionBusy && focusArea === "items"
                 && entries[itemIndex] && entries[itemIndex].presentation === "download") {
            runAction(Object.assign({}, entries[itemIndex], {id: "download-folder", action: "download-folder"}), undefined, false);
        }
        else if (k === Qt.Key_B && !editing && !pendingConfirm && focusArea === "items"
                 && entries[itemIndex] && entries[itemIndex].presentation === "project") bookmark(entries[itemIndex]);
        else if ((k === Qt.Key_W || k === Qt.Key_N) && !editing && !pendingConfirm && !actionBusy && focusArea === "items"
                 && entries[itemIndex] && entries[itemIndex].presentation === "project") {
            runAction(Object.assign({}, entries[itemIndex], {id: k === Qt.Key_W ? "project-worktrees" : "work-tasks", close: false}), undefined, false);
        }
        else if (k === Qt.Key_E && !editing && !pendingConfirm && focusArea === "items"
                 && entries[itemIndex] && entries[itemIndex].presentation === "library") eject(entries[itemIndex]);
        else if (k === Qt.Key_T && !editing && !pendingConfirm && !actionBusy && focusArea === "items"
                 && entries[itemIndex] && entries[itemIndex].presentation === "project") {
            runAction(Object.assign({}, entries[itemIndex], {id: "project-terminal", action: "project-terminal"}), undefined, false);
        }
        else if (k === Qt.Key_F && !editing && !pendingConfirm) show("root");
        else if (k === Qt.Key_Q && !editing && !pendingConfirm) hide();
        else if (k === Qt.Key_J || k === Qt.Key_Down) step(1);
        else if (k === Qt.Key_K || k === Qt.Key_Up) step(-1);
        else if (k === Qt.Key_H || k === Qt.Key_Left) {
            if (editing) adjust(-5);
            else if (pendingConfirm) confirmYes = false;
            else goBack();
        } else if (k === Qt.Key_L || k === Qt.Key_Right || k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
            if (editing) {
                if (k === Qt.Key_L || k === Qt.Key_Right) adjust(5);
                else finishEdit();
            } else if (pendingConfirm) {
                if (confirmYes) { var accepted = pendingConfirm; pendingConfirm = null; activate(accepted, true); }
                else pendingConfirm = null;
            } else if (focusArea === "groups") chooseGroup(groupIndex);
            else activate(entries[itemIndex]);
        } else if (k === Qt.Key_Slash) startSearch();
        else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            if (entries.length) focusArea = focusArea === "groups" ? "items" : "groups";
        } else if (k === Qt.Key_Home || (k === Qt.Key_G && !(event.modifiers & Qt.ShiftModifier))) {
            if (focusArea === "groups") groupIndex = 0; else itemIndex = 0;
        } else if (k === Qt.Key_End || (k === Qt.Key_G && (event.modifiers & Qt.ShiftModifier))) {
            if (focusArea === "groups") groupIndex = groups.length - 1; else itemIndex = entries.length - 1;
        } else return;
        event.accepted = true;
    }

    IpcHandler {
        target: "drawer"
        function toggle(page: string): void { if (root.opened && (!page || page === root.page)) root.hide(); else root.show(page); }
        function open(page: string): void { root.show(page); }
        function close(): void { root.hide(); }
        function pick(path: string): void { root.showPicker(path); }
        function cancelPicker(path: string): void {
            if (root.pickerActive && root.pickerResponse === path.replace(/request\.json$/, "response.json")) root.hide();
        }
        function status(): string {
            return JSON.stringify({ open: root.opened, page: root.page, searching: root.searching,
                editing: root.editing, focus: root.focusArea, searchFocused: root.searching && searchInput.activeFocus, selected: Logic.identity(root.entries[root.itemIndex]),
                group: root.groupId, count: root.entries.length, busy: root.actionBusy, error: root.failed,
                attached:!!root.resolvedAnchor, screen:root.drawerScreen ? root.drawerScreen.name : "", reveal:root.drawerReveal,
                connected:theme.paperDetails && !!root.drawerHost, topInset:root.drawerTopInset,
                placement:root.drawerPlacement, width:root.drawerWidth, height:root.drawerHeight, sheetY:keyboard.y,
                visible:root.drawerVisible, source:root.attachment ? root.attachment.moduleName : "" });
        }
    }

    Process {
        id: groupProcess
        command: root.backendCommand(["view", "root"])
        stdout: StdioCollector { id: groupOut }
        stderr: StdioCollector { id: groupErr }
        onExited: (code, status) => {
            if (!root.opened || root.pickerActive || root.calendarLayout) return;
            try {
                var data = JSON.parse(groupOut.text);
                if ((code !== 0 || data.error) && !Array.isArray(data.items)) throw new Error(data.error || "Cannot read menu groups.");
                if (code !== 0 || data.error) root.note(data.error || "Some home cards are unavailable.", true);
                var previousGroup = Logic.identity(root.groups[root.groupIndex]);
                var refreshedGroups = Array.isArray(data.items) ? data.items : [];
                if (JSON.stringify(root.groups) !== JSON.stringify(refreshedGroups)) root.groups = refreshedGroups;
                if (root.page === "root" && !root.searching && !root.editing && !root.pendingConfirm) {
                    var previous = Logic.identity(root.entries[root.itemIndex]);
                    root.entries = Array.isArray(data.favorites) ? data.favorites : [];
                    root.itemIndex = Logic.restoreIndex(root.entries, previous);
                    root.pageTitle = "today.";
                    root.today = data.today || {};
                    root.drawerReady = true;
                    itemList.viewPage = "root";
                }
                var gi = root.focusArea === "groups" ? -1 : root.groups.findIndex(function(g) { return g.page === root.page || g.id === root.groupId; });
                root.groupIndex = gi >= 0 ? gi : Logic.restoreIndex(root.groups, previousGroup);
            } catch (error) { root.note(String(error.message || error), true); }
            if (root.page === "root") root.pageLoading = false;
        }
    }
    Process {
        id: viewProcess
        property int serial: 0
        property string requestedPage: ""
        property bool timedOut: false
        stdout: StdioCollector { id: viewOut }
        stderr: StdioCollector { id: viewErr }
        onExited: (code, status) => {
            if (timedOut) root.viewTimedOut(serial); else root.applyView(serial, requestedPage, viewOut.text, code, viewErr.text);
            timedOut = false;
            Qt.callLater(root.startView);
        }
    }
    Timer { id: viewWatchdog; interval: 10000; running: viewProcess.running; onTriggered: { viewProcess.timedOut = true; viewProcess.running = false; } }
    Process {
        id: actionProcess
        property var item: null
        property int location: 0
        stdout: StdioCollector { id: actionOut }
        stderr: StdioCollector { id: actionErr }
        property bool timedOut: false
        onExited: (code, status) => {
            root.actionBusy = false;
            if (timedOut) {
                timedOut = false;
                root.note("That took too long, so I stopped waiting for it.", true);
                Qt.callLater(root.startAction);
                return;
            }
            try {
                var result = JSON.parse(actionOut.text);
                root.note(result.message || (result.ok ? "all set." : "That action did not complete."), !result.ok || code !== 0);
                if (result.ok && code === 0) {
                    if (root.opened && location === root.navigationSerial && result.page) {
                        root.worktreeProject = result.project || "";
                        root.show(result.page);
                    }
                    else if (root.opened && location === root.navigationSerial && (result.close || (item && item.close))) root.hide();
                    else if (!root.editing) root.requestView();
                }
            } catch (error) { root.note("That action did not complete. " + actionErr.text.trim().slice(0, 160), true); }
            Qt.callLater(root.startAction);
        }
    }
    Timer { interval: 120000; running: actionProcess.running; onTriggered: { actionProcess.timedOut = true; actionProcess.running = false; } }
    Timer {
        id: sliderWrite
        property var item: null
        property int value: 0
        interval: 160
        onTriggered: { if (item) root.runAction(item, value, false); }
    }
    Timer { id: searchDebounce; interval: 160; onTriggered: root.requestView() }
    // Long enough that holding j to run down the sidebar loads only where you stop.
    Timer { id: previewTimer; interval: 180; onTriggered: root.previewGroup(root.groupIndex) }
    Timer {
        interval: 4000; repeat: true
        running: root.opened && !root.pickerActive && !root.calendarLayout && !root.scrapbookLayout && !root.gardenLayout && !root.searching && !root.editing && !root.pendingConfirm && !root.actionBusy
        onTriggered: {
            if (!groupProcess.running) groupProcess.running = true;
            // A refresh would replace the request a slow page is still answering, and it would never finish.
            if (root.page !== "root" && !viewProcess.running) root.requestView();
        }
    }

    component PaperShadow: Item {
        id: paperShadow
        required property color ink
        property real strength: 0.06
        Behavior on strength { NumberAnimation { duration: 70 } }
        anchors.fill: parent
        z: -1
        Rectangle {
            x: parent.width; y: 4; width: 4; height: Math.max(0, parent.height - 4)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Qt.alpha(paperShadow.ink, paperShadow.strength) }
                GradientStop { position: 1; color: "transparent" }
            }
        }
        Rectangle {
            x: 4; y: parent.height; width: Math.max(0, parent.width - 4); height: 4
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.alpha(paperShadow.ink, paperShadow.strength) }
                GradientStop { position: 1; color: "transparent" }
            }
        }
    }

    PanelWindow {
        id: panel
        screen: root.drawerScreen
        visible: root.drawerVisible && !root.drawerHost
        anchors { top: true; right: true }
        readonly property var placement: Logic.drawerPlacement(screen ? screen.width : 1280, implicitWidth, root.resolvedAnchor, theme.paperDetails)
        margins { top: panel.placement.top; right: (panel.screen ? panel.screen.width : 1280) - panel.placement.left - panel.implicitWidth }
        implicitWidth: Math.min(root.calendarLayout ? 430 : root.pickerLayout ? 640 : 790, (screen ? screen.width : 1280) - 32)
        implicitHeight: Math.min(Logic.drawerBody(root.calendarLayout ? "calendar" : root.pickerLayout && root.pickerPrompt ? "prompt" : "drawer", screen ? screen.height : 800) + root.drawerTopInset, Math.max(180, (screen ? screen.height : 800) - placement.top - 16))
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "foxml-drawer"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened && !root.drawerHost ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Item {
            id: revealClip
            parent: root.drawerHost || panel.contentItem
            x: root.drawerHost ? panel.placement.left : 0
            y: root.drawerHost ? panel.placement.top : 0
            width: panel.implicitWidth
            height: panel.implicitHeight * (theme.paperDetails ? 1 : root.drawerReveal)
            opacity: theme.paperDetails ? 1 : Math.min(1, root.drawerReveal * 2)
            clip: true
            onParentChanged: { if (root.opened) Qt.callLater(function() { keyboard.forceActiveFocus(); }); }
        FocusScope {
            id: keyboard
            x: 0
            y: -(theme.paperDetails ? panel.implicitHeight : 14) * (1-root.drawerReveal)
            width: panel.implicitWidth; height: panel.implicitHeight
            enabled: root.opened
            focus: true
            Keys.onPressed: event => root.key(event)

            Item {
                anchors.fill: parent
                anchors.margins: 5
                anchors.topMargin: theme.paperDetails ? 0 : 5
                BarRibbon {
                    id: drawerBanner
                    objectName: "drawer-banner"
                    anchors.fill: parent
                    visible: theme.paperDetails
                    theme: root.paperTheme
                    depth: height - 4
                    edgeStyle: "page"
                    inset: 0
                }
                Rectangle {
                    visible: !theme.paperDetails
                    anchors.fill: parent
                    color: theme.background
                    radius: Math.max(4, Math.min(theme.radius, 12))
                    border.width: 1; border.color: theme.line
                }
                PaperGrain { anchors.fill:parent; anchors.bottomMargin:14; theme:root.paperTheme }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    anchors.topMargin: 24 + root.drawerTopInset
                    spacing: 14

                    RowLayout {
                        Layout.fillWidth: true
                        Text { textFormat: Text.PlainText; text: root.calendarLayout ? "// LITTLE DAYS" : "// THE QUIET CORNER"; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 10; font.letterSpacing: 1 }
                        Item { Layout.fillWidth: true }
                        ToolButton {
                            text: "◇"
                            visible: !root.calendarLayout
                            implicitWidth: 28; implicitHeight: 28; padding: 0
                            font.family: theme.fontFamily
                            palette.buttonText: theme.ink
                            background: Rectangle { color: root.buttonShade(parent.down, parent.hovered); radius: 3 }
                            onClicked: root.show("root")
                            Accessible.name: "Pinned favorites (f)"
                            BarHint { theme:root.paperTheme; visible:parent.hovered; text:"Pinned favorites · f" }
                        }
                        Rectangle { visible: !root.calendarLayout; width: 5; height: 5; radius: 3; color: root.failed ? theme.error : theme.success }
                        Text { visible: !root.calendarLayout; textFormat: Text.PlainText; text: root.actionBusy ? "WORKING" : root.pageLoading ? "OPENING" : root.pickerLayout && root.pickerPrompt ? "WRITE" : root.searching ? "SEARCH" : root.editing ? "ADJUST" : "NORMAL"; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9 }
                        LoadingDots { theme: root.paperTheme; busy: root.opened && (root.actionBusy || root.pageLoading); Layout.preferredWidth: visible ? 24 : 0 }
                        ToolButton {
                            text: "×"
                            implicitWidth: 28; implicitHeight: 28; padding: 0
                            font.pixelSize: 19
                            palette.buttonText: theme.muted
                            background: Rectangle { color: root.buttonShade(parent.down, parent.hovered); radius: 3 }
                            onClicked: root.hide()
                            Accessible.name: "Close drawer"
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: !root.calendarLayout
                        Text { textFormat: Text.PlainText; text: theme.paperDetails && root.page === "power" && Logic.isNight(new Date()) ? "goodnight, see you tomorrow." : "make yourself at home."; color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: panel.implicitWidth < 580 ? 21 : 27; Layout.fillWidth: true; elide: Text.ElideRight }
                        BotanicalMark {
                            Layout.preferredWidth: 30; Layout.preferredHeight: 36
                            theme: root.paperTheme
                        }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: !root.calendarLayout
                        spacing: 18

                        ListView {
                            id: groupList
                            visible: !root.pickerLayout && root.page !== "search"
                            Layout.preferredWidth: panel.implicitWidth < 580 ? 125 : 179
                            Layout.fillHeight: true
                            clip: true
                            spacing: 7
                            bottomMargin: theme.paperDetails && contentHeight >= height ? 4 : 0
                            model: root.groups
                            currentIndex: root.groupIndex
                            keyNavigationEnabled: false
                            boundsBehavior: Flickable.StopAtBounds
                            boundsMovement: Flickable.StopAtBounds
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                width: groupList.width - (theme.paperDetails ? 4 : 0)
                                height: 59
                                radius: 4
                                color: groupMouse.pressed ? Qt.alpha(theme.line, .35) : index === root.groupIndex ? (theme.paperDetails || root.focusArea === "groups" ? theme.focusFill : Qt.alpha(theme.selection, theme.selectionOpacity * .45)) : theme.paperDetails ? (groupMouse.containsMouse ? theme.hoverFill : Qt.alpha(theme.highlight, .23)) : root.buttonShade(false, groupMouse.containsMouse)
                                border.width: theme.paperDetails || (index === root.groupIndex && root.focusArea === "groups") ? 1 : 0
                                border.color: theme.line
                                PaperShadow {
                                    visible: theme.paperDetails
                                    ink: theme.ink
                                    strength: groupMouse.pressed ? .012 : index === root.groupIndex && root.focusArea === "groups" ? .06 : .035
                                }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    spacing: 10
                                    Item {
                                        readonly property string pencilIcon: theme.paperDetails ? Logic.paperIcon(modelData) : ""
                                        Layout.preferredWidth: 24; Layout.preferredHeight: 24
                                        Image { anchors.fill: parent; visible: parent.pencilIcon.length > 0; source: parent.pencilIcon; sourceSize.width: 48; sourceSize.height: 48; fillMode: Image.PreserveAspectFit }
                                        Text { anchors.centerIn: parent; visible: !parent.pencilIcon; textFormat: Text.PlainText; text: Logic.symbol(modelData); color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 16; font.weight: Font.Normal }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 3
                                        Text { textFormat: Text.PlainText; text: modelData.label || ""; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: theme.paperDetails ? 13 : 12; font.weight: theme.paperDetails ? Font.DemiBold : Font.Normal; elide: Text.ElideRight; Layout.fillWidth: true }
                                        Text { textFormat: Text.PlainText; visible: panel.implicitWidth >= 580; text: modelData.summary || modelData.detail || ""; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                                    }
                                    Text { textFormat: Text.PlainText; text: "›"; color: theme.muted; font.pixelSize: 18 }
                                }
                                MouseArea {
                                    id: groupMouse
                                    anchors.fill: parent; hoverEnabled: true
                                    onClicked: root.chooseGroup(index); cursorShape: Qt.PointingHandCursor
                                }
                                BarHint { theme:root.paperTheme; visible:groupMouse.containsMouse; text:modelData.summary || modelData.detail || "" }
                            }
                        }

                        Rectangle { visible: !root.pickerLayout; width: theme.paperDetails ? 2 : 1; Layout.fillHeight: true; color: theme.line }

                        ColumnLayout {
                            id: drawer
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 10
                            opacity: !root.drawerReady ? 0 : 1
                            Behavior on opacity { NumberAnimation { duration: 160 } }
                            transform: Translate {
                                x: root.drawerReady ? 0 : 28
                                Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: theme.paperDetails ? 38 : 28
                                color: theme.paperDetails ? Qt.alpha(theme.highlight, .55) : "transparent"
                                radius: 3
                                border.width: theme.paperDetails ? 1 : 0
                                border.color: theme.line
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: theme.paperDetails ? 10 : 0
                                    anchors.rightMargin: theme.paperDetails ? 10 : 0
                                Text {
                                    id: pageHeading
                                    textFormat: Text.PlainText; text: Logic.pageHeading(root.searching && !root.pickerLayout ? "find anything" : root.pageTitle, theme.paperDetails)
                                    color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: 20; Layout.fillWidth: true; elide: Text.ElideRight
                                    PaperFlourish {
                                        theme: root.paperTheme
                                        kind: Logic.pageFlourish(root.page, root.searching)
                                        visible: theme.paperDetails && !root.pickerLayout && (kind === "swash" || kind === "underline")
                                        z: -1; x: 0; y: kind === "swash" ? 2 : pageHeading.height - 1
                                        width: Math.min(pageHeading.contentWidth, pageHeading.width)
                                        height: kind === "swash" ? Math.max(0, pageHeading.height - 2) : 4
                                    }
                                }
                                Text {
                                    id: pageCount
                                    textFormat: Text.PlainText; text: root.page === "root" || (root.pickerLayout && root.pickerPrompt) ? "" : String(root.entries.length).padStart(2, "0")
                                    color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 10
                                    PaperFlourish {
                                        theme: root.paperTheme; kind: "circle"
                                        visible: theme.paperDetails && !root.pickerLayout && Logic.pageFlourish(root.page, root.searching) === "circle" && pageCount.text.length > 0
                                        z: -1; x: -7; y: -5; width: pageCount.width + 14; height: pageCount.height + 10
                                    }
                                }
                            }
                                }
                            ApiCreditMeter {
                                objectName: "drawer-api-credits"
                                theme: root.paperTheme
                                credit: root.creditSnapshot
                                compact: true
                                visible: root.page === "api-credits" && credit !== null
                                Layout.fillWidth: true
                            }
                            Text {
                                id: breadcrumbRow
                                visible: !root.searching && (root.breadcrumbs.length > 1 || text.length > 0)
                                Layout.fillWidth: true
                                textFormat: Text.PlainText
                                text: (root.focusArea === "items" ? Logic.focusDetail(root.entries[root.itemIndex]) : "") || root.breadcrumbs.slice(0, -1).map(function(crumb) { return crumb.label; }).join(" / ")
                                color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9
                                elide: Text.ElideMiddle
                            }

                            Rectangle {
                                visible: root.searching
                                Layout.fillWidth: true
                                height: 38
                                color: theme.surface
                                radius: 4
                                border.width: 1
                                border.color: theme.line
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10
                                    Text { textFormat: Text.PlainText; text: "/"; color: theme.accent; font.family: theme.fontFamily }
                                    TextField {
                                        id: searchInput
                                        Layout.fillWidth: true
                                        color: theme.ink
                                        font.family: theme.fontFamily
                                        font.pixelSize: 12
                                        placeholderText: root.pickerPrompt && root.pickerLayout ? "write here…" : root.searchPage === "search" ? "apps, projects, settings, recent things…" : "find on this page…"
                                        placeholderTextColor: theme.muted
                                        selectByMouse: true
                                        background: Item {
                                            Rectangle { anchors.bottom: parent.bottom; width: theme.paperDetails ? Math.min(48, parent.width) : parent.width; height: 1; visible: searchInput.activeFocus; color: theme.paperDetails ? theme.detailAccent : theme.accent }
                                        }
                                        onTextChanged: if (root.searching) searchDebounce.restart()
                                        Keys.onPressed: event => root.key(event)
                                    }
                                    ToolButton {
                                        visible: root.pickerLayout && root.pickerPrompt
                                        text: "↵"
                                        palette.buttonText: theme.ink
                                        background: Rectangle { color: root.buttonShade(parent.down, parent.hovered); radius: 3 }
                                        onClicked: root.activate(null)
                                        Accessible.name: "Submit text"
                                    }
                                }
                            }

                            TodaySheet {
                                id: todaySheet
                                visible: root.page === "root" && !root.searching && !root.pickerLayout && !root.pendingConfirm
                                active: root.opened && visible
                                theme: root.paperTheme
                                today: root.today
                                groups: root.groups
                                favorites: root.entries.length
                                commandFor: root.backendCommand
                                selectedTag: root.focusArea === "tags" ? root.tagIndex : -1
                                onOpenTag: tag => root.openTag(tag)
                                onOpenGarden: root.openTag({page: "garden", text: "Commit garden"})
                                Layout.fillWidth: true
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                GardenSheet {
                                    id: gardenSheet
                                    visible: root.gardenLayout && !root.searching
                                    theme: root.paperTheme
                                    garden: root.garden
                                    selectedIndex: root.gardenIndex
                                    anchors.fill: parent
                                    onChoose: index => { root.gardenIndex = index; root.focusArea = "items"; keyboard.forceActiveFocus(); }
                                }

                                ScrapbookSheet {
                                    id: scrapbookSheet
                                    visible: root.scrapbookLayout
                                    theme: root.paperTheme
                                    entries: root.entries
                                    selectedIndex: root.itemIndex
                                    busy: root.pageLoading || root.actionBusy
                                    anchors.fill: parent
                                    onChoose: index => { root.itemIndex = index; root.focusArea = "items"; keyboard.forceActiveFocus(); }
                                    onOpenPicture: index => root.activate(root.entries[index])
                                    onCopyPicture: index => root.screenshotAction(index, "screenshot-copy")
                                    onOpenFolder: index => root.screenshotAction(index, "screenshot-folder")
                                    onCapture: root.activate({id:"screenshot-capture",kind:"action",enabled:true,close:true})
                                }

                                ListView {
                                    id: itemList
                                    property string viewPage: ""
                                    anchors.fill: parent
                                    visible: !root.pendingConfirm && !root.scrapbookLayout && !root.gardenLayout && (root.page !== "root" || root.entries.length > 0 || root.searching)
                                    clip: true
                                    spacing: 7
                                    bottomMargin: theme.paperDetails && contentHeight >= height ? 4 : 0
                                    model: root.entries
                                    currentIndex: root.itemIndex
                                    keyNavigationEnabled: false
                                    boundsBehavior: Flickable.StopAtBounds
                                    ScrollBar.vertical: PageEdgeScrollBar {
                                        id: itemScroll
                                        theme: root.paperTheme
                                        policy: ScrollBar.AsNeeded
                                        visible: itemList.contentHeight > itemList.height
                                    }
                                    delegate: Rectangle {
                                        id: itemRow
                                        required property var modelData
                                        required property int index
                                        property bool selected: index === root.itemIndex && root.focusArea === "items"
                                        readonly property string pencilIcon: theme.paperDetails ? Logic.paperIcon(modelData) : ""
                                        property string menuIcon: pencilIcon || (Logic.iconName(modelData) ? Quickshell.iconPath(Logic.iconName(modelData), true) : "")
                                        readonly property var connection: theme.paperDetails ? Logic.connectionState(modelData) : null
                                        readonly property bool mediaArtwork: modelData.presentation === "media" && Boolean(modelData.artwork)
                                        readonly property bool clipboardPhoto: theme.paperDetails && root.page === "clipboard-images" && Boolean(modelData.image)
                                        readonly property string stateLabel: theme.paperDetails ? Logic.statusLabel(modelData) : ""
                                        // A row that belongs to the one above it sits indented beneath it.
                                        readonly property int indent: modelData.nested === true ? 22 : 0
                                        // Today's favorites sit a little closer so more of them fit under the day.
                                        readonly property bool compactRow: root.page === "root" && !root.searching
                                        x: indent
                                        width: Math.max(0, itemList.width - theme.scrollGutter - indent)
                                        property bool card: modelData.presentation === "project" || modelData.presentation === "library" || modelData.presentation === "download"
                                        height: card ? 94 : modelData.kind === "slider" ? 91 : modelData.image || mediaArtwork ? 80 : itemRow.compactRow ? 54 : 72
                                        radius: 4
                                        readonly property color rowFill: itemMouse.pressed ? Qt.alpha(theme.line, .35) : selected ? theme.focusFill : theme.paperDetails ? (itemMouse.containsMouse && modelData.enabled !== false ? theme.hoverFill : theme.background) : card ? theme.surface : root.buttonShade(false, itemMouse.containsMouse)
                                        readonly property color rowEdge: itemMouse.pressed ? theme.muted : theme.paperDetails && !selected ? Qt.alpha(theme.line, .6) : theme.line
                                        color: theme.paperDetails && card ? "transparent" : rowFill
                                        border.width: theme.paperDetails && card ? 0 : theme.paperDetails || selected || card || itemMouse.containsMouse ? 1 : 0
                                        border.color: rowEdge
                                        opacity: modelData.enabled === false ? (theme.paperDetails ? .75 : .48) : 1
                                        PaperCardSurface {
                                            anchors.fill: parent; visible: theme.paperDetails && itemRow.card
                                            theme: root.paperTheme; presentation: modelData.presentation || ""
                                            fillColor: itemRow.rowFill; edgeColor: itemRow.rowEdge
                                        }
                                        PaperShadow {
                                            visible: theme.paperDetails
                                            ink: theme.ink
                                            strength: itemMouse.pressed ? .012 : itemRow.selected ? .06 : .035
                                        }
                                        Rectangle {
                                            visible: itemRow.card
                                            anchors.top: parent.top
                                            anchors.left: theme.paperDetails && modelData.presentation === "project" ? parent.left : undefined
                                            anchors.right: theme.paperDetails && modelData.presentation === "project" ? undefined : parent.right
                                            anchors.topMargin: 7; anchors.leftMargin: 14; anchors.rightMargin: 10
                                            width: cardStamp.implicitWidth + (theme.paperDetails ? 8 : 0); height: cardStamp.implicitHeight + (theme.paperDetails ? 4 : 0)
                                            color: theme.paperDetails ? Qt.alpha(theme.highlight, .45) : "transparent"
                                            border.width: theme.paperDetails ? 1 : 0
                                            border.color: Qt.alpha(theme.muted, .55)
                                            Text {
                                                id: cardStamp; anchors.centerIn: parent
                                                text: modelData.presentation === "library" ? (modelData.mounted ? "CHECKED OUT" : "ON THE SHELF") : modelData.presentation === "download" ? (modelData.stamp || "INCOMING") : (theme.paperDetails ? "PROJECT " : "") + String(index + 1).padStart(2, "0")
                                                color: theme.paperDetails ? theme.ink : theme.muted; font.family: theme.fontFamily; font.pixelSize: theme.paperDetails ? 10 : 8; font.weight: theme.paperDetails ? Font.DemiBold : Font.Normal
                                            }
                                        }
                                        Rectangle {
                                            visible: itemRow.card && !(theme.paperDetails && modelData.presentation === "download")
                                            anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
                                            anchors.bottomMargin: 11; anchors.leftMargin: 48; anchors.rightMargin: 12
                                            height: 1; color: theme.line; opacity: .6
                                        }
                                        Rectangle { visible: selected; width: 2; anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; color: theme.detailAccent; radius: 1 }
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.margins: itemRow.compactRow ? 10 : 12
                                            spacing: 10
                                            Image {
                                                objectName: "item-menu-icon"
                                                visible: itemRow.connection === null && !itemRow.mediaArtwork && !itemRow.clipboardPhoto && Boolean(modelData.image || itemRow.menuIcon)
                                                source: modelData.image || itemRow.menuIcon
                                                sourceSize.width: modelData.image ? 42 : 24
                                                sourceSize.height: modelData.image ? 42 : 24
                                                Layout.preferredWidth: visible ? (modelData.image ? 42 : 24) : 0
                                                Layout.preferredHeight: modelData.image ? 42 : 24
                                                fillMode: Image.PreserveAspectFit
                                                asynchronous: true
                                            }
                                            MediaArtwork {
                                                objectName: "media-artwork"
                                                theme: root.paperTheme
                                                visible: itemRow.mediaArtwork
                                                source: itemRow.mediaArtwork ? modelData.artwork : ""
                                                Layout.preferredWidth: visible ? 48 : 0
                                                Layout.preferredHeight: 52
                                            }
                                            ClipboardPhoto {
                                                theme: root.paperTheme; visible: itemRow.clipboardPhoto
                                                source: visible ? modelData.image : ""
                                                Layout.preferredWidth: visible ? 52 : 0; Layout.preferredHeight: 56
                                            }
                                            ClipIcon { theme: root.paperTheme; visible: itemRow.connection !== null; linked: itemRow.connection === true; Layout.preferredWidth: visible ? 24 : 0; Layout.preferredHeight: 24 }
                                            Text { textFormat: Text.PlainText; visible: itemRow.connection === null && !itemRow.mediaArtwork && !modelData.image && !itemRow.menuIcon; text: Logic.symbol(modelData); color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 16; font.weight: Font.Normal; Layout.preferredWidth: visible ? 24 : 0 }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 4
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 8
                                                    Text { id: entryLabel; textFormat: Text.PlainText; text: modelData.label || ""; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 12; elide: Text.ElideRight; Layout.fillWidth: true }
                                                    StateTag { objectName:"media-state-tag"; theme:root.paperTheme; text:itemRow.stateLabel; visible:text.length>0 }
                                                }
                                                Text { id: entryDetail; textFormat: Text.PlainText; text: Logic.detailText(modelData, itemRow.stateLabel.length > 0); visible: text.length > 0; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                                                ContextHearts {
                                                    objectName: "context-hearts"
                                                    theme: root.paperTheme
                                                    percent: modelData.presentation === "claude" && modelData.context !== undefined ? Number(modelData.context) : -1
                                                    fresh: modelData.fresh === true
                                                }
                                                PencilProgress {
                                                    id: ruler
                                                    theme: root.paperTheme
                                                    visible: modelData.kind === "slider"
                                                    Layout.fillWidth: true
                                                    Layout.topMargin: 6
                                                    Layout.preferredHeight: theme.paperDetails ? 14 : 3
                                                    tickMarks: theme.paperDetails
                                                    value: root.editing && selected ? root.draftValue : Number(modelData.value || 0)
                                                }
                                            }
                                            ColumnLayout {
                                                Layout.preferredWidth: modelData.kind === "slider" ? 58 : 31
                                                spacing: 5
                                                Rectangle {
                                                    visible: modelData.kind === "toggle"
                                                    width: 29; height: 16; radius: 8
                                                    color: "transparent"; border.width: 1; border.color: theme.muted
                                                    Rectangle { width: 8; height: 8; radius: 4; y: 4; x: modelData.checked || modelData.active ? 17 : 4; color: theme.paperDetails && (modelData.checked || modelData.active) ? theme.detailAccent : theme.ink; Behavior on x { NumberAnimation { duration: 100 } } }
                                                }
                                                Text { textFormat: Text.PlainText; visible: modelData.kind !== "toggle"; text: (theme.paperDetails && root.editing && selected && modelData.kind === "slider" ? "✎ " : "") + Logic.valueText(modelData, root.editing && selected, root.draftValue); color: theme.ink; font.family: theme.fontFamily; font.pixelSize: modelData.kind === "page" ? 18 : 11; Layout.alignment: Qt.AlignRight }
                                                Text { textFormat: Text.PlainText; visible: modelData.kind === "toggle"; text: Logic.valueText(modelData, false, 0); color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 8; Layout.alignment: Qt.AlignRight }
                                            }
                                        }
                                        MouseArea {
                                            id: itemMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: modelData.enabled === false ? Qt.ArrowCursor : Qt.PointingHandCursor
                                            onClicked: { root.itemIndex = index; root.focusArea = "items"; root.activate(modelData); keyboard.forceActiveFocus(); }
                                        }
                                        ToolTip {
                                            id: itemTip
                                            visible: (itemMouse.containsMouse || itemRow.selected) && text.length > 0 && (entryLabel.truncated || entryDetail.truncated || Boolean(modelData.modifiedAt) || (Logic.focusDetail(modelData).length > 0 && breadcrumbRow.truncated))
                                            delay: 900
                                            timeout: 7000
                                            // Below the row when the space above it inside the list can't hold the tip (it would cover the page title).
                                            y: itemRow.y - itemList.contentY < implicitHeight + 6 ? itemRow.height + 4 : -implicitHeight - 4
                                            // ToolTip centres on its unwrapped width, which slides a long tip off the drawer's left edge.
                                            x: 0
                                            text: Logic.tooltipText(modelData)
                                            contentItem: Text { text: itemTip.text; textFormat: Text.PlainText; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 10; wrapMode: Text.WrapAnywhere }
                                            background: Rectangle {
                                                color:theme.tooltipFill; border.color:theme.line; radius:4
                                                Rectangle { x:0; y:(parent.height-height)/2; width:2; height:Math.min(16,parent.height-8); radius:1; color:theme.highlight; visible:theme.paperDetails }
                                            }
                                            width: Math.min(implicitWidth, itemRow.width)
                                        }
                                        Canvas {
                                            visible: modelData.presentation === "project" && modelData.bookmarked === true
                                            anchors.top: parent.top; anchors.right: parent.right; anchors.rightMargin: 30
                                            width: 12; height: 23
                                            onPaint: {
                                                var ctx = getContext("2d"); ctx.clearRect(0, 0, width, height);
                                                ctx.fillStyle = theme.detailAccent;
                                                ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(width, 0);
                                                ctx.lineTo(width, height); ctx.lineTo(width / 2, height - 5);
                                                ctx.lineTo(0, height); ctx.closePath(); ctx.fill();
                                            }
                                        }
                                        ToolButton {
                                            visible: modelData.presentation === "project" || modelData.presentation === "library"
                                            anchors.bottom: parent.bottom; anchors.right: parent.right
                                            anchors.rightMargin: 8; anchors.bottomMargin: 2
                                            width: 23; height: 23
                                            text: modelData.presentation === "library" ? "⏏" : modelData.bookmarked ? "◆" : "◇"
                                            font.pixelSize: 12
                                            background: Rectangle { color: root.buttonShade(parent.down, parent.hovered); radius: 3 }
                                            contentItem: Text { text: parent.text; color: modelData.presentation === "project" && modelData.bookmarked ? theme.detailAccent : theme.ink; font: parent.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                            Accessible.name: modelData.presentation === "library" ? "Eject drive (e)" : "Toggle bookmark ribbon (b)"
                                            BarHint { theme:root.paperTheme; visible:parent.hovered; text:parent.Accessible.name }
                                            onClicked: {
                                                root.itemIndex = index; root.focusArea = "items";
                                                if (modelData.presentation === "library") root.eject(modelData); else root.bookmark(modelData);
                                                keyboard.forceActiveFocus();
                                            }
                                        }
                                        ToolButton {
                                            visible: modelData.presentation === "project"
                                            anchors.bottom: parent.bottom; anchors.right: parent.right
                                            anchors.rightMargin: 35; anchors.bottomMargin: 2
                                            width: 23; height: 23; text: "▥"; font.pixelSize: 12
                                            background: Rectangle { color: root.buttonShade(parent.down, parent.hovered); radius: 3 }
                                            contentItem: Text { text: parent.text; color: theme.ink; font: parent.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                            Accessible.name: "Open project worktrees (w)"
                                            BarHint { theme: root.paperTheme; visible: parent.hovered; text: parent.Accessible.name }
                                            onClicked: root.runAction(Object.assign({}, modelData, {id: "project-worktrees", close: false}), undefined, false)
                                        }
                                    }
                                }

                                Column {
                                    id: emptyNote
                                    readonly property var note: Logic.emptyState(root.page, root.searching, root.failed)
                                    anchors.centerIn: parent
                                    width: parent.width - 28
                                    spacing: 15
                                    visible: root.page !== "root" && !root.scrapbookLayout && !root.gardenLayout && (!(root.pickerLayout && root.pickerPrompt) && !root.pendingConfirm && !root.entries.length && !root.pageLoading && (root.drawerReady || root.failed))
                                    Image {
                                        visible: theme.paperDetails && !root.failed
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        source: Logic.emptyIllustration(root.page, root.searching, root.failed)
                                        width: 180
                                        height: 114
                                        sourceSize.width: 360
                                        fillMode: Image.PreserveAspectFit
                                        smooth: true
                                        mipmap: true
                                    }
                                    Text { visible: !theme.paperDetails || root.failed; textFormat: Text.PlainText; width: parent.width; text: root.failed ? "!" : theme.paperDetails || root.page === "root" ? "✎" : "·"; color: root.failed ? theme.error : theme.muted; font.family: theme.fontFamily; font.pixelSize: theme.paperDetails ? 27 : 34; horizontalAlignment: Text.AlignHCenter }
                                    Text { textFormat: Text.PlainText; width: parent.width; text: parent.note.title; color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: 18; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap }
                                    Text { textFormat: Text.PlainText; width: parent.width; text: parent.note.detail; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 10; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.5; wrapMode: Text.WordWrap }
                                }

                                Item {
                                    id: confirmationCard
                                    anchors.centerIn: parent
                                    width: parent.width - 24
                                    height: confirmationContent.implicitHeight + (theme.paperDetails ? 48 : 0)
                                    visible: root.pendingConfirm !== null
                                    PaperShadow {
                                        visible: theme.paperDetails
                                        ink: theme.ink
                                    }
                                    Canvas {
                                        visible: theme.paperDetails
                                        anchors.fill: parent
                                        onWidthChanged: requestPaint()
                                        onHeightChanged: requestPaint()
                                        onPaint: {
                                            var ctx = getContext("2d"), fold = 18, w = width - .5, h = height - .5;
                                            ctx.clearRect(0, 0, width, height);
                                            ctx.fillStyle = theme.background;
                                            ctx.strokeStyle = Qt.alpha(theme.line, 0.7);
                                            ctx.lineWidth = 1;
                                            ctx.beginPath(); ctx.moveTo(.5, .5); ctx.lineTo(w - fold, .5);
                                            ctx.lineTo(w, fold); ctx.lineTo(w, h); ctx.lineTo(.5, h); ctx.closePath();
                                            ctx.fill(); ctx.stroke();
                                            ctx.fillStyle = theme.focusFill;
                                            ctx.beginPath(); ctx.moveTo(w - fold, .5); ctx.lineTo(w - fold, fold);
                                            ctx.lineTo(w, fold); ctx.closePath(); ctx.fill(); ctx.stroke();
                                        }
                                    }
                                    ColumnLayout {
                                        id: confirmationContent
                                        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                                        anchors.margins: theme.paperDetails ? 24 : 0
                                        spacing: 20
                                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: root.pendingConfirm ? root.pendingConfirm.label + "?" : ""; color: theme.ink; font.family: theme.headingFont; font.italic: true; font.pixelSize: 24; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap }
                                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: root.pendingConfirm && typeof root.pendingConfirm.confirm === "string" ? root.pendingConfirm.confirm : "one moment before you go.\nthis action needs your confirmation."; color: theme.muted; font.family: theme.fontFamily; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; lineHeight: 1.5 }
                                        RowLayout {
                                            Layout.alignment: Qt.AlignHCenter
                                            spacing: 12
                                            Repeater {
                                                model: ["stay here", Logic.confirmationLabel(root.pendingConfirm)]
                                                delegate: Rectangle {
                                                    required property string modelData
                                                    required property int index
                                                    width: Math.max(116, confirmationButtonText.implicitWidth + 28); height: 42; radius: 4
                                                    color: root.confirmYes === (index === 1) ? (theme.paperDetails ? theme.focusFill : Qt.alpha(theme.selection, theme.selectionOpacity)) : theme.surface
                                                    border.width: 1; border.color: theme.line
                                                    Text { id: confirmationButtonText; textFormat: Text.PlainText; anchors.centerIn: parent; text: modelData; color: theme.ink; font.family: theme.fontFamily; font.pixelSize: 11 }
                                                    MouseArea { anchors.fill: parent; onClicked: { var item = root.pendingConfirm; root.pendingConfirm = null; if (index === 1) root.activate(item, true); } }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    CalendarSheet {
                        id: calendarSheet
                        visible: root.calendarLayout
                        active: root.opened && root.calendarLayout
                        theme: root.paperTheme
                        commandFor: root.backendCommand
                        onOpenGarden: root.gardenFromCalendar()
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }
                    Text { visible: root.message.length > 0 && !root.calendarLayout; textFormat: Text.PlainText; text: (root.failed ? "! " : "✿ ") + root.message; color: root.failed ? theme.error : theme.muted; font.family: theme.fontFamily; font.pixelSize: 10; Layout.fillWidth: true; elide: Text.ElideRight; Accessible.role: Accessible.StaticText; Accessible.name: root.message }
                    Rectangle { Layout.fillWidth: true; height: 1; color: theme.line }
                    Flow {
                        id: hintFooter
                        visible: theme.paperDetails
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        spacing: 0
                        Accessible.role: Accessible.StaticText
                        Accessible.name: root.footerHint
                        Repeater {
                            model: Logic.hintParts(root.footerHint)
                            delegate: Item {
                                required property var modelData
                                implicitWidth: Math.min(hintFooter.width, hintWord.implicitWidth + (modelData.key ? 10 : 0))
                                implicitHeight: 19
                                Rectangle { visible: modelData.key; anchors.fill: parent; anchors.topMargin: 1; anchors.bottomMargin: 1; color: theme.highlight; border.color: Qt.alpha(theme.line, .8); radius: 3 }
                                Text { id: hintWord; textFormat: Text.PlainText; anchors.centerIn: parent; width: Math.max(0, parent.width - (modelData.key ? 10 : 0)); elide: Text.ElideRight; text: modelData.text; color: modelData.key ? theme.ink : theme.muted; font.family: theme.fontFamily; font.pixelSize: panel.implicitWidth < 580 ? 9 : 10 }
                            }
                        }
                    }
                    Text {
                        visible: !theme.paperDetails
                        textFormat: Text.PlainText
                        text: root.footerHint
                        color: theme.muted; font.family: theme.fontFamily
                        font.pixelSize: panel.implicitWidth < 580 ? 9 : 10
                        Layout.fillWidth: true; elide: Text.ElideRight
                    }
                }
            }
        }
    }

    }

    Component.onCompleted: {
        barWrite.restart();
        if (Quickshell.env("FOXML_DRAWER_PREVIEW") === "1") show("sound");
    }
    Component.onDestruction: { finishPicker({cancel: true}); syncBar(true); }
}
