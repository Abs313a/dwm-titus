import QtQuick
import Quickshell
import Quickshell.Io
import qs.core

Scope {
    id: root

    property bool visible: false
    property bool settingsVisible: false
    property bool busy: false
    property bool editorAvailable: false
    property bool actionUsesPasswordStdin: false
    property bool panelSnapshotPending: false
    property bool panelSnapshotRescanPending: false
    property bool settingsSnapshotPending: false
    property bool settingsSnapshotRescanPending: false
    property bool sharedSnapshotPending: false
    property bool sharedSnapshotRescanPending: false
    property bool wifiPasswordPromptVisible: false
    property string wifiPasswordPromptOrigin: ""
    property int selectedIndex: 0
    property int selectedWifiIndex: -1
    property string statusText: "NET offline"
    property string connectionKind: "disconnected"
    property int wifiSignal: -1
    readonly property string barIconState: root.connectionKind
    property string message: ""
    property string providerState: "idle"
    property string providerDetail: ""
    property string operationState: "read-only"
    property string actionOrigin: ""
    property string actionLabel: ""
    property string snapshotOrigin: ""
    property bool actionFailed: false
    property string wifiPassword: ""
    property var devices: []
    property var connections: []
    property var wifiNetworks: []

    readonly property var activeConnections: root.connections.filter(function(profile) {
        return profile.active;
    })
    readonly property var savedProfiles: root.connections.filter(function(profile) {
        return !profile.active && root.isSupportedProfile(profile.type);
    })
    readonly property bool active: true
    readonly property bool actionsAvailable: (providerState === "available" || providerState === "restricted")
        && operationState === "delegated"

    function isSupportedProfile(type) {
        return type === "802-3-ethernet" || type === "ethernet" || type === "802-11-wireless" || type === "wifi" || type === "vpn";
    }

    function supportsFixedWifiSecurity(security) {
        const value = (security || "").toUpperCase();
        return value.indexOf("802.1X") < 0 && value.indexOf("EAP") < 0
            && value.indexOf("ENTERPRISE") < 0;
    }

    function open() {
        root.visible = true;
        root.refresh(true);
    }

    function close() {
        root.visible = false;
        root.selectedIndex = 0;
        root.selectedWifiIndex = -1;
        root.wifiPasswordPromptVisible = false;
        root.wifiPasswordPromptOrigin = "";
        root.message = "";
        root.wifiPassword = "";
        root.stopUnownedWork("panel");
    }

    function openSettings() {
        root.settingsVisible = true;
        root.refresh(false, "settings");
    }

    function closeSettings() {
        root.settingsVisible = false;
        root.selectedWifiIndex = -1;
        root.wifiPasswordPromptVisible = false;
        root.wifiPasswordPromptOrigin = "";
        root.wifiPassword = "";
        root.stopUnownedWork("settings");
    }

    function stopUnownedWork(origin) {
        if (root.actionOrigin === origin && actionProcess.running) actionProcess.running = false;
        if (root.snapshotOrigin === origin && snapshotProcess.running) snapshotProcess.running = false;
        root.clearPendingSnapshot(origin);
    }

    function snapshotPendingOwner(origin) {
        return origin === "panel" || origin === "settings" ? origin : "shared";
    }

    function clearPendingSnapshot(origin) {
        const owner = root.snapshotPendingOwner(origin);
        if (owner === "panel") {
            root.panelSnapshotPending = false;
            root.panelSnapshotRescanPending = false;
        } else if (owner === "settings") {
            root.settingsSnapshotPending = false;
            root.settingsSnapshotRescanPending = false;
        } else {
            root.sharedSnapshotPending = false;
            root.sharedSnapshotRescanPending = false;
        }
    }

    function queuePendingSnapshot(rescanWifi, origin) {
        const owner = root.snapshotPendingOwner(origin);
        if (owner === "panel") {
            root.panelSnapshotPending = true;
            root.panelSnapshotRescanPending = root.panelSnapshotRescanPending || rescanWifi === true;
        } else if (owner === "settings") {
            root.settingsSnapshotPending = true;
            root.settingsSnapshotRescanPending = root.settingsSnapshotRescanPending || rescanWifi === true;
        } else {
            root.sharedSnapshotPending = true;
            root.sharedSnapshotRescanPending = root.sharedSnapshotRescanPending || rescanWifi === true;
        }
    }

    function refreshPendingSnapshot() {
        const hasPending = root.panelSnapshotPending || root.settingsSnapshotPending || root.sharedSnapshotPending;
        if (!hasPending) return;
        const rescanWifi = root.panelSnapshotRescanPending || root.settingsSnapshotRescanPending
            || root.sharedSnapshotRescanPending;
        const origin = root.sharedSnapshotPending ? "shared" : (root.panelSnapshotPending ? "panel" : "settings");
        root.clearPendingSnapshot("panel");
        root.clearPendingSnapshot("settings");
        root.clearPendingSnapshot("shared");
        root.refresh(rescanWifi, origin);
    }

    function toggle() {
        if (root.visible) {
            root.close();
        } else {
            root.open();
        }
    }

    function refresh(rescanWifi, origin) {
        if (!root.active) return;
        const requestOrigin = origin || (root.visible ? "panel" : "shared");
        if (snapshotProcess.running) {
            root.queuePendingSnapshot(rescanWifi, requestOrigin);
            return;
        }
        root.providerState = "loading";
        root.snapshotOrigin = requestOrigin;
        snapshotProcess.command = Commands.networkHelperCommand("snapshot", ["--rescan", rescanWifi ? "yes" : "no"]);
        snapshotProcess.running = true;
        if (!editorCheckProcess.running) {
            editorCheckProcess.running = true;
        }
    }

    function refreshWifi(rescan, origin) {
        root.refresh(rescan === true, origin);
    }

    function parseSnapshot(text) {
        const devices = [];
        const connections = [];
        const wifiNetworks = [];
        const selectedBssid = root.selectedWifiNetwork() ? root.selectedWifiNetwork().bssid : "";
        let protocolValid = false;
        let providerSeen = false;
        let malformed = false;
        root.operationState = "read-only";

        for (const line of text.trim().split("\n")) {
            if (line.length === 0) continue;
            const fields = line.split("\t");
            if (fields[0] === "connectivity-protocol") {
                protocolValid = fields.length >= 3 && fields[1] === "1";
            } else if (fields[0] === "provider") {
                if (fields.length < 5 || fields[1] !== "network") { malformed = true; continue; }
                providerSeen = true;
                root.providerState = fields[2];
                root.operationState = fields[3];
                root.providerDetail = fields[4];
            } else if (fields[0] === "network-device") {
                if (fields.length < 5) { malformed = true; continue; }
                devices.push({ "device": fields[1], "type": fields[2], "state": fields[3], "connection": fields[4] === "-" ? "" : fields[4] });
            } else if (fields[0] === "network-profile") {
                if (fields.length < 6) { malformed = true; continue; }
                connections.push({ "name": fields[1], "uuid": fields[2], "type": fields[3], "active": fields[4] === "yes", "device": fields[5] === "-" ? "" : fields[5] });
            } else if (fields[0] === "wifi-network") {
                if (fields.length < 8) { malformed = true; continue; }
                const security = fields[5] === "--" ? "" : fields[5];
                wifiNetworks.push({ "active": fields[1] === "*", "bssid": fields[2], "ssid": fields[3],
                    "signal": fields[4], "security": security, "channel": fields[6], "device": fields[7], "secured": security.length > 0 });
            }
        }

        if (!protocolValid || !providerSeen || malformed) {
            root.providerState = "failure";
            root.providerDetail = !protocolValid ? "Unsupported connectivity protocol" : "Malformed network provider record";
            root.statusText = "NET unavailable";
            root.connectionKind = "disconnected";
            root.wifiSignal = -1;
            root.devices = [];
            root.connections = [];
            root.wifiNetworks = [];
            root.message = root.providerDetail;
            return;
        }

        root.devices = devices;
        root.connections = connections;
        root.wifiNetworks = wifiNetworks;
        root.selectedWifiIndex = -1;
        for (let i = 0; i < wifiNetworks.length; i++) {
            if (wifiNetworks[i].bssid === selectedBssid) {
                root.selectedWifiIndex = i;
                break;
            }
        }
        if (root.wifiPasswordPromptVisible && root.selectedWifiIndex < 0) {
            root.cancelWifiPasswordPrompt();
        }
        let ethernetDevice = "";
        let wifiDevice = "";
        let wifiSignal = -1;
        for (const device of devices) {
            if (device.state !== "connected") continue;
            if (device.type === "ethernet" && ethernetDevice.length === 0) ethernetDevice = device.device;
            if (device.type === "wifi" && wifiDevice.length === 0) wifiDevice = device.device;
        }
        if (ethernetDevice.length > 0) {
            root.connectionKind = "ethernet";
            root.wifiSignal = -1;
        } else if (wifiDevice.length > 0) {
            root.connectionKind = "wifi";
            for (const network of wifiNetworks) {
                if (!network.active || network.device !== wifiDevice) continue;
                const signal = Number(network.signal);
                if (isFinite(signal)) wifiSignal = Math.max(0, Math.min(100, Math.round(signal)));
                break;
            }
            root.wifiSignal = wifiSignal;
        } else {
            root.connectionKind = "disconnected";
            root.wifiSignal = -1;
        }
        const stateReadable = root.providerState === "available" || root.providerState === "restricted";
        const connectedDevice = ethernetDevice.length > 0 ? ethernetDevice : wifiDevice;
        root.statusText = stateReadable ? (connectedDevice.length > 0 ? "NET " + connectedDevice : "NET offline") : "NET unavailable";
        if (root.providerState !== "available") root.message = root.providerDetail;
        else if (!root.actionFailed && !root.busy) root.message = "";
        if (root.selectedIndex >= connections.length) root.selectedIndex = Math.max(0, connections.length - 1);
        if (root.selectedWifiIndex >= wifiNetworks.length) root.selectedWifiIndex = -1;
    }

    function selectedWifiNetwork() {
        if (root.selectedWifiIndex < 0 || root.selectedWifiIndex >= root.wifiNetworks.length) {
            return null;
        }

        return root.wifiNetworks[root.selectedWifiIndex];
    }

    function selectWifi(index) {
        if (index < 0 || index >= root.wifiNetworks.length) {
            return;
        }

        if (root.selectedWifiIndex === index) {
            return;
        }

        root.selectedWifiIndex = index;
        root.wifiPasswordPromptVisible = false;
        root.wifiPassword = "";
        root.message = "";
    }

    function cancelWifiPasswordPrompt() {
        root.wifiPasswordPromptVisible = false;
        root.wifiPasswordPromptOrigin = "";
        root.selectedWifiIndex = -1;
        root.wifiPassword = "";
        root.message = "";
    }

    function connectWifi(network, origin) {
        if (!network || network.device.length === 0 || network.bssid.length === 0 || network.ssid.length === 0) {
            return;
        }
        if (!root.actionsAvailable || root.busy || actionProcess.running) {
            return;
        }

        if (!root.supportsFixedWifiSecurity(network.security)) {
            root.message = "Enterprise Wi-Fi opens in Advanced NetworkManager settings";
            root.openEditor();
            return;
        }

        if (network.secured && root.wifiPassword.length === 0) {
            for (let i = 0; i < root.wifiNetworks.length; i++) {
                if (root.wifiNetworks[i].bssid === network.bssid && root.wifiNetworks[i].device === network.device) {
                    root.selectedWifiIndex = i;
                    break;
                }
            }
            root.wifiPasswordPromptVisible = true;
            root.wifiPasswordPromptOrigin = origin || "panel";
            root.message = "";
            return;
        }

        const args = [network.device, network.bssid, network.ssid];
        if (network.secured) {
            args.push("--password-stdin");
            args.push(network.security);
        }

        root.busy = true;
        root.actionFailed = false;
        root.actionOrigin = origin || "panel";
        root.actionLabel = "connect Wi-Fi";
        root.actionUsesPasswordStdin = network.secured;
        root.wifiPasswordPromptVisible = false;
        root.wifiPasswordPromptOrigin = "";
        root.message = "Connecting " + network.ssid;
        actionProcess.command = Commands.networkHelperCommand("wifi-connect", args);
        actionProcess.running = true;
    }

    function connectSelectedWifi(origin) {
        root.connectWifi(root.selectedWifiNetwork(), origin);
    }

    function connectProfile(profile, origin) {
        if (!profile || profile.uuid.length === 0) {
            return;
        }
        if (!root.actionsAvailable || root.busy || actionProcess.running) {
            return;
        }

        root.busy = true;
        root.actionFailed = false;
        root.actionOrigin = origin || "panel";
        root.actionLabel = "activate profile";
        root.actionUsesPasswordStdin = false;
        root.message = "Connecting " + profile.name;
        actionProcess.command = Commands.networkHelperCommand("connect", [profile.uuid]);
        actionProcess.running = true;
    }

    function disconnectDevice(device, origin) {
        if (!device || device.length === 0) {
            return;
        }
        if (!root.actionsAvailable || root.busy || actionProcess.running) {
            return;
        }

        root.busy = true;
        root.actionFailed = false;
        root.actionOrigin = origin || "panel";
        root.actionLabel = "disconnect device";
        root.actionUsesPasswordStdin = false;
        root.message = "Disconnecting " + device;
        actionProcess.command = Commands.networkHelperCommand("disconnect", [device]);
        actionProcess.running = true;
    }

    function forgetProfile(profile, origin) {
        if (!root.actionsAvailable || !profile || profile.uuid.length === 0 || root.busy || actionProcess.running) return;
        root.busy = true;
        root.actionFailed = false;
        root.actionOrigin = origin || "panel";
        root.actionLabel = "forget profile";
        root.actionUsesPasswordStdin = false;
        root.message = "Forgetting " + profile.name;
        actionProcess.command = Commands.networkHelperCommand("forget", [profile.uuid]);
        actionProcess.running = true;
    }

    function openEditor() {
        if (!root.editorAvailable) {
            return;
        }

        editorProcess.running = true;
    }

    Process {
        id: snapshotProcess

        command: Commands.networkHelperCommand("snapshot", ["--rescan", "no"])
        running: false
        stdout: StdioCollector { onStreamFinished: root.parseSnapshot(this.text) }
        stderr: StdioCollector {
            onStreamFinished: {
                const error = this.text.trim();
                if (error.length > 0) {
                    root.providerState = "failure";
                    root.providerDetail = error;
                    root.message = error;
                }
            }
        }
        onRunningChanged: {
            if (running) return;
            root.snapshotOrigin = "";
            root.refreshPendingSnapshot();
        }
    }

    Process {
        id: actionProcess

        command: ["sh", "-c", "exit 0"]
        running: false
        stdinEnabled: true

        onStarted: {
            if (root.actionUsesPasswordStdin) {
                write(root.wifiPassword + "\n");
                root.actionUsesPasswordStdin = false;
                root.wifiPassword = "";
            }
        }

        onRunningChanged: {
            if (!running) {
                root.busy = false;
                root.actionUsesPasswordStdin = false;
                root.wifiPassword = "";
                if (!root.actionFailed) root.message = "";
                root.refresh(false);
                root.actionOrigin = "";
                root.actionLabel = "";
            }
        }

        stderr: StdioCollector {
            onStreamFinished: {
                const error = this.text.trim();
                if (error.length > 0) {
                    root.actionFailed = true;
                    root.message = root.actionLabel + " failed: " + error;
                }
            }
        }
    }

    Process {
        id: networkMonitorProcess
        command: Commands.networkHelperCommand("monitor")
        running: true

        stdout: SplitParser {
            onRead: root.refresh(false)
        }
        onRunningChanged: {
            if (!running) networkMonitorRestartTimer.restart();
        }
    }

    Timer {
        id: networkMonitorRestartTimer
        interval: 3000
        repeat: false
        onTriggered: {
            if (!networkMonitorProcess.running) networkMonitorProcess.running = true;
        }
    }

    Process {
        id: editorProcess

        command: Commands.networkHelperCommand("editor")
        running: false
    }

    Process {
        id: editorCheckProcess

        command: ["sh", "-c", "command -v nm-connection-editor >/dev/null 2>&1 && printf yes || printf no"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: root.editorAvailable = this.text.trim() === "yes"
        }
    }

    Component.onCompleted: root.refresh(false)
}
