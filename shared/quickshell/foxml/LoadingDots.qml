import QtQuick

Item {
    id: dots
    required property var theme
    property bool busy: false
    property bool showing: false
    property int step: 0
    implicitWidth: 24
    implicitHeight: 12
    visible: showing && busy
    onBusyChanged: {
        showing=false;step=0;
        if(busy) delay.restart();else delay.stop();
    }
    Timer { id: delay; interval: 220; onTriggered: dots.showing=dots.busy }
    Timer { interval: 320; running: dots.visible; repeat: true; onTriggered: dots.step=(dots.step+1)%3 }
    Row {
        anchors.centerIn: parent;spacing: 4
        Repeater {
            model: 3
            Rectangle {
                required property int index
                width: 3;height: 3;radius: 2;color: dots.theme.ink
                opacity: index <= dots.step ? .85 : .18
                Behavior on opacity { NumberAnimation { duration: 120 } }
            }
        }
    }
}
