"""Exercise the attached drawer in its real bar host, with an isolated backend."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

EXERCISE = r'''
    property real testSurfaceHeight:0
    property real testBarY:0
    Timer { interval:300; running:true; onTriggered: {
        var window=desktopBar.item.windows[0];
        root.testSurfaceHeight=window.implicitHeight;
        root.testBarY=window.moduleContainer.mapToItem(window.contentItem,0,0).y;
        root.hide();
        root.showFromBar("sound",desktopBar.item.windows[0].screen.name,"custom/logo");
    }}
    // FloatingWindow retains its user size; validate the panel size request here.
    Timer { interval:600; running:true; onTriggered: {
        var window=desktopBar.item.windows[0];
        if (!root.drawerHost || revealClip.parent !== window.drawerContainer || panel.visible || !window.hosting || window.implicitHeight <= window.barHeight)
            throw new Error("drawer did not move into the bar host: " + JSON.stringify({host:!!root.drawerHost,parent:revealClip.parent===window.drawerContainer,visible:panel.visible,hosting:window.hosting,height:window.height,implicitHeight:window.implicitHeight,barHeight:window.barHeight,attachment:root.attachment}));
        if (window.barHeight !== 66 || window.mask.height !== 66) throw new Error("drawer changed the reserved bar/input strip");
        if (window.implicitHeight!==root.testSurfaceHeight || window.moduleContainer.mapToItem(window.contentItem,0,0).y!==root.testBarY)
            throw new Error("opening resized or moved the bar surface");
        if (!drawerBanner.visible || drawerBanner.depth<=0) throw new Error("drawer did not use the shared ribbon shape");
        if (root.drawerPlacement.top >= root.resolvedAnchor.y) throw new Error("paper did not tuck under the bookmark");
        if (root.drawerPlacement.top !== 0 || root.drawerTopInset !== window.barHeight
            || revealClip.y !== 0 || revealClip.height !== root.drawerHeight || Math.abs(keyboard.y)>1)
            throw new Error("drawer is not a continuous sheet from the top edge");
        if (window.moduleContainer.z <= window.drawerContainer.z) throw new Error("bookmark is behind the sheet");
        if (!keyboard.activeFocus) throw new Error("attached keyboard focus was lost");
        root.step(1);
        if (root.itemIndex !== 1) throw new Error("attached navigation failed");
        root.hide();
        if (keyboard.enabled) throw new Error("closing kept keyboard input");
    }}
    Timer { interval:660; running:true; onTriggered: {
        if (!root.drawerVisible || keyboard.y >= -root.drawerHeight*.1 || keyboard.y <= -root.drawerHeight)
            throw new Error("closing did not slide the complete sheet upward");
        if (desktopBar.item.windows[0].implicitHeight!==root.testSurfaceHeight)
            throw new Error("closing resized the bar surface");
    }}
    Timer { interval:900; running:true; onTriggered: {
        var window=desktopBar.item.windows[0];
        if (root.drawerVisible || window.hosting || window.implicitHeight !== root.testSurfaceHeight) throw new Error("closed drawer changed the stable bar surface");
        root.showFromBar("sound",window.screen.name,"custom/updates");
    }}
    Timer { interval:1200; running:true; onTriggered: {
        if (!root.resolvedAnchor || !keyboard.activeFocus) throw new Error("second banner lost attachment/focus");
        root.attachment={screenName:desktopBar.item.windows[0].screen.name,moduleName:"custom/not-on-this-output"};
        if (root.resolvedAnchor || !root.drawerHost || root.drawerTopInset!==66)
            throw new Error("missing bookmark detached the drawer from its bar");
        desktopBar.item.shown=false;
    }}
    Timer { interval:1500; running:true; onTriggered: {
        if (root.drawerHost || !panel.visible || revealClip.parent !== panel.contentItem) throw new Error("hidden bar did not leave a standalone drawer");
        if (root.drawerTopInset!==0 || root.drawerPlacement.top!==0)
            throw new Error("bar-free fallback did not remain attached to the screen edge");
        desktopBar.item.shown=true;
    }}
    Timer { interval:1800; running:true; onTriggered: {
        if (!root.drawerHost || !keyboard.activeFocus || panel.visible) throw new Error("bar return did not restore the attached drawer");
        root.hide();
    }}
    Timer { interval:2100; running:true; onTriggered: {
        if (root.drawerVisible) throw new Error("drawer remained visible");
        root.show("calendar");
    }}
    Timer { interval:2400; running:true; onTriggered: {
        var window=desktopBar.item.windows[0];
        if (!root.calendarLayout || !calendarSheet.visible || !root.resolvedAnchor || root.attachment.moduleName!=="custom/clock")
            throw new Error("keyboard calendar did not attach to the clock");
        if (root.drawerWidth!==430 || !drawerBanner.visible || root.drawerPlacement.top!==0 || !keyboard.activeFocus)
            throw new Error("calendar lost its compact banner or keyboard focus");
        if (groupList.visible || !root.drawerReady || root.pageLoading || root.failed || viewProcess.running)
            throw new Error("calendar queried a backend page or showed the menu sidebar");
        var month=calendarSheet.month.getMonth(),year=calendarSheet.month.getFullYear();
        root.key({key:Qt.Key_L,modifiers:0,accepted:false});
        if (calendarSheet.month.getMonth()!==(month+1)%12) throw new Error("calendar next-month key failed");
        root.key({key:Qt.Key_H,modifiers:0,accepted:false});
        if (calendarSheet.month.getMonth()!==month || calendarSheet.month.getFullYear()!==year)
            throw new Error("calendar previous-month key failed");
        calendarSheet.today=new Date(2000,0,1,12);calendarSheet.month=new Date(2000,0,1,12);
        calendarSheet.refreshToday();
        if (calendarSheet.month.getFullYear()!==new Date().getFullYear()) throw new Error("open calendar did not follow date rollover");
        calendarSheet.moveMonth(1);
        root.key({key:Qt.Key_T,modifiers:0,accepted:false});
        if (!calendarSheet.currentMonth) throw new Error("today key failed");
        root.hide();
    }}
    Timer { interval:2700; running:true; onTriggered: {
        if (root.drawerVisible || keyboard.enabled) throw new Error("calendar close kept its sheet or keyboard");
        root.showFromBar("calendar",desktopBar.item.windows[0].screen.name,"custom/clock");
    }}
    Timer { interval:3000; running:true; onTriggered: {
        if (!root.resolvedAnchor || root.attachment.moduleName!=="custom/clock" || !calendarSheet.currentMonth)
            throw new Error("clock click did not open the current month");
        root.showFromBar("calendar",desktopBar.item.windows[0].screen.name,"custom/clock");
        if (root.opened || keyboard.enabled) throw new Error("second clock click did not toggle closed");
        root.show("sound");
    }}
    Timer { interval:3300; running:true; onTriggered: {
        if (root.calendarLayout || !groupList.visible || calendarSheet.visible || root.entries.length!==3)
            throw new Error("normal drawer did not recover after calendar");
        root.show("screenshots");
    }}
    Timer { interval:3600; running:true; onTriggered: {
        if (!root.scrapbookLayout || !scrapbookSheet.visible || root.entries.length!==7 || !groupList.visible)
            throw new Error("scrapbook did not load its photo sheet inside the drawer");
        root.key({key:Qt.Key_Down,modifiers:0,accepted:false});
        if (root.itemIndex!==scrapbookSheet.columns) throw new Error("scrapbook grid navigation failed");
        root.key({key:Qt.Key_C,modifiers:0,accepted:false});
        if (actionProcess.command.slice(-3).join("|")!=="run|screenshot-copy|/sample/shot-"+scrapbookSheet.columns+".png" || actionProcess.item.close)
            throw new Error("copy does not preserve the selected picture or keeps the wrong action");
        volumeSlip.show(200,false);
        if (!volumeSlip.showing || volumeSlip.value!==150) throw new Error("volume slip level clamp failed");
        volumeSlip.show(42,true);
        if (!volumeSlip.muted || volumeSlip.value!==42) throw new Error("volume slip mute state failed");
    }}
    Timer { interval:4000; running:true; onTriggered: {
        if (!root.opened || !root.scrapbookLayout || root.failed) throw new Error("copy closed or broke the scrapbook");
        root.key({key:Qt.Key_Escape,modifiers:0,accepted:false});
        if (root.focusArea!=="groups") throw new Error("Esc did not take the scrapbook back to the sidebar");
        root.key({key:Qt.Key_Escape,modifiers:0,accepted:false});
        if (root.opened || keyboard.enabled) throw new Error("scrapbook did not close cleanly");
    }}
    Timer { interval:5500; running:true; onTriggered: {
        if (volumeSlip.showing || volumeSlip.displayable) throw new Error("volume slip did not expire");
        root.show("calendar");
    }}
    Timer { interval:5800; running:true; onTriggered: {
        if (calendarSheet.hearts.length!==2 || calendarSheet.hearts[0]!==1) throw new Error("calendar hearts did not load: "+JSON.stringify(calendarSheet.hearts));
        root.hide();
        root.show("hung");
    }}
    // A page that never answers must not hold the next one behind it.
    Timer { interval:6000; running:true; onTriggered: {
        if (!viewProcess.running || !root.pageLoading) throw new Error("hung page did not start loading");
        root.show("sound");
    }}
    Timer { interval:6400; running:true; onTriggered: {
        if (root.pageLoading || root.entries.length!==3 || root.page!=="sound") throw new Error("a hung page blocked the next page");
        root.show("slow");
        root.show("root");
    }}
    Timer { interval:7000; running:true; onTriggered: {
        if (root.page!=="root" || itemList.viewPage!=="root" || root.entries.length!==1) throw new Error("a late page reply landed on home");
        root.show("hung");
    }}
    // Staying on the hung page ends with a message, not a spinner.
    Timer { interval:7700; running:true; onTriggered: {
        if (root.pageLoading || !root.failed || root.message.indexOf("too long")<0) throw new Error("hung page never gave up: "+root.message);
        root.show("sound");
    }}
    Timer { interval:8100; running:true; onTriggered: {
        if (root.pageLoading || root.entries.length!==3 || root.failed) throw new Error("drawer did not recover after a timeout");
        console.log("TUCKED_DRAWER_OK");Qt.quit();
    }}
'''

@unittest.skipUnless(shutil.which("quickshell"), "Quickshell is required")
class TuckedDrawer(unittest.TestCase):
    def test_host_focus_resize_and_fallback(self):
        for width in [1920,1080,720]:
            with self.subTest(width=width):self.exercise(width)

    def exercise(self,width):
        renderer=ROOT/"src/fox-render/fox-render-fast"
        if not renderer.exists():
            self.skipTest("build fox-render-fast first")
        with tempfile.TemporaryDirectory(prefix="tucked-drawer-") as tmp:
            work=Path(tmp);qml=work/"qml"
            shutil.copytree(ROOT/"shared/quickshell/foxml",qml)
            subprocess.run([str(renderer),str(ROOT/"themes/FoxML_Paper/palette.sh"),str(ROOT/"templates/quickshell/foxml"),str(qml)],check=True,capture_output=True)
            config=work/"config/waybar";config.mkdir(parents=True)
            layout={"modules-left":["custom/logo"],"modules-center":[],"modules-right":["custom/updates","custom/clock"],
                "custom/clock":{"format":"Thursday 09♡09","on-click":"fox-desktop-menu calendar"},
                "custom/logo":{"format":"✎","on-click":"fox-desktop-menu root"},
                "custom/updates":{"format":"↧ 4","on-click":"fox-desktop-menu updates"}}
            for name in ["config","config_secondary"]:
                (config/name).write_text(json.dumps(layout))
            volume=(qml/"VolumeSlip.qml").read_text().replace("PanelWindow {","FloatingWindow {")
            volume=re.sub(r"^    (?:anchors.*|margins\..*|exclusionMode:.*|WlrLayershell\..*)\n","",volume,flags=re.M)
            (qml/"VolumeSlip.qml").write_text(volume)
            fixture=work/"fixture.json";fixture.write_text("{}")
            runtime=work/"runtime";runtime.mkdir(mode=0o700)
            source=(qml/"shell.qml").read_text().replace("    PanelWindow {","    FloatingWindow {")
            source=re.sub(r"^        (?:anchors \{.*|margins \{.*|exclusionMode:.*|WlrLayershell\..*)\n","",source,flags=re.M)
            source=source.replace("screen ? screen.width : 1280",str(width)).replace("screen ? screen.height : 800","1920" if width<1280 else "1080")
            source=source.replace("id: viewWatchdog; interval: 10000","id: viewWatchdog; interval: 500")
            (qml/"shell.qml").write_text(source.rsplit("\n}",1)[0]+EXERCISE+"\n}\n")
            source=(qml/"PaperBar.qml").read_text().replace("PanelWindow {","FloatingWindow {\n            implicitWidth: "+str(width))
            source=re.sub(r"^\s*(?:anchors \{ top: true; left: true; right: true \}|exclusiveZone:.*|WlrLayershell\..*|IdleInhibitor \{.*)\n","\n",source,flags=re.M)
            (qml/"PaperBar.qml").write_text(source)
            env=os.environ|{"QT_QPA_PLATFORM":"offscreen","QT_QUICK_BACKEND":"software","XDG_RUNTIME_DIR":str(runtime),
                "XDG_CONFIG_HOME":str(work/"config"),"FOXML_DRAWER_PREVIEW":"1","FOXML_BAR_AUTOSTART":"1",
                "FOXML_BAR_FIXTURE":str(fixture),"FOXML_DRAWER_BACKEND":str(ROOT/"tests/drawer-ui-backend.py"),
                "FOXML_DRAWER_TEST_LOG":str(work/"actions"),"QS_NO_RELOAD_POPUP":"1"}
            env.pop("WAYLAND_DISPLAY",None);env.pop("HYPRLAND_INSTANCE_SIGNATURE",None)
            result=subprocess.run(["quickshell","-p",str(qml),"--no-color"],env=env,capture_output=True,text=True,timeout=16)
            log=result.stdout+result.stderr
            self.assertEqual(result.returncode,0,log)
            self.assertIn("TUCKED_DRAWER_OK",log)
            for error in ["TypeError","ReferenceError","Unable to assign","Binding loop","Error:"]:
                self.assertNotIn(error,log)

if __name__=="__main__":
    unittest.main()
