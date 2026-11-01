// Kiteline 的 GNOME Shell 扩展（随 Kiteline 电脑端一起发，由 Kiteline 装到 ~/.local/share/gnome-shell/extensions/kiteline@betac.cn）。
// 本机的 Kiteline 后台（desktop/kiteline/shellext.py）经会话总线调它，做 GNOME 桌面上普通程序做不了的几件事：
// - 列出窗口、切换前台窗口：Wayland 下别的程序无权切窗口，从手机发消息时要先把 VS Code 切到前台、投完把前台还回去
// - 「VS Code 在虚拟屏幕中运行」（同 Mac / Windows 版）：把 VS Code 的窗口藏起来——不画出来、鼠标点不到，键盘输入照常，
//   切到前台也不会出现在你面前；藏着的窗口放到所有工作区上，切过去不会换工作区
// - 你自己切到藏着的窗口（Alt+Tab、Dock、概览里点它）：放回来给你看；关掉别的窗口时系统顺手把焦点给了它：把焦点让给下一个看得见的窗口
// - Kiteline 退出、卡住（30 秒没续约）或扩展停用：藏着的窗口全部放回来
// - 投递把 VS Code 切到前台的这一两秒，暂时接管键盘（同打开概览时），把你接着打的字截下来，前台还回去以后补发（见 HoldKeys）
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// 接口版本：后台按它判断装的是不是这一版（改了接口就加 1，同时改 metadata.json 的 version）
const VERSION = 2;

const IFACE = `<node>
  <interface name="cn.betac.Kiteline">
    <method name="Version"><arg type="u" direction="out"/></method>
    <method name="Windows"><arg type="s" direction="out"/></method>
    <method name="Focused"><arg type="t" direction="out"/></method>
    <method name="Activate"><arg type="t" direction="in"/><arg type="b" direction="out"/></method>
    <method name="Hide"><arg type="at" direction="in"/><arg type="u" direction="out"/></method>
    <method name="Show"><arg type="at" direction="in"/><arg type="u" direction="out"/></method>
    <method name="Keep"><arg type="u" direction="in"/></method>
    <method name="HoldKeys"><arg type="u" direction="in"/><arg type="b" direction="out"/></method>
    <method name="KeysIdle"><arg type="u" direction="out"/></method>
    <method name="PauseKeys"/>
    <method name="ResumeKeys"><arg type="b" direction="out"/></method>
    <method name="ReleaseKeys"><arg type="b" direction="in"/><arg type="u" direction="out"/></method>
    <signal name="Shown"><arg type="t"/></signal>
  </interface>
</node>`;

export default class KitelineExtension extends Extension {
    enable() {
        // 藏着的窗口：id → {window, sticky（原来就在所有工作区上）, handlers}
        this._hidden = new Map();
        // Kiteline 刚请求切过去的窗口：这几秒里它到前台不算你要看它
        this._requested = null;
        this._lease = 0;
        this._last = null;
        this._lastGone = false;
        this._lastHandlers = [];
        this._remember(global.display.focus_window);
        this._focusHandler = global.display.connect('notify::focus-window', () => this._focusChanged());
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 5, () => {
            this._checkLease();
            return GLib.SOURCE_CONTINUE;
        });
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, '/cn/betac/Kiteline');
    }

    disable() {
        this._dbus?.unexport();
        this._dbus = null;
        if (this._timer)
            GLib.source_remove(this._timer);
        this._timer = 0;
        global.display.disconnect(this._focusHandler);
        this._forgetLast();
        this._showAll();
        this._hidden = null;
        this.ReleaseKeys(false);
        this._keyboard = null;
    }

    // MARK: 会话总线上的方法

    Version() {
        return VERSION;
    }

    /// 普通窗口的列表（JSON）：id、类名、应用 id、标题、进程、藏着没有、在不在前台、最小化没有
    Windows() {
        const focus = global.display.focus_window;
        const list = this._windows().map(w => ({
            id: w.get_id(), wmClass: w.get_wm_class() ?? '', app: w.get_gtk_application_id() ?? '', title: w.get_title() ?? '',
            pid: w.get_pid(), hidden: this._hidden.has(w.get_id()), focused: w === focus, minimized: w.minimized,
        }));
        return JSON.stringify(list);
    }

    Focused() {
        return global.display.focus_window?.get_id() ?? 0;
    }

    /// 切到前台（藏着的照样藏着）。不用 Main.activateWindow：它会顺手关掉概览，你正在概览里时不该被打断
    Activate(id) {
        const window = this._find(id);
        if (!window)
            return false;
        this._requested = {id, until: Date.now() + 4000};
        if (window.minimized)
            window.unminimize();
        window.activate(global.get_current_time());
        return true;
    }

    Hide(ids) {
        let count = 0;
        for (const id of ids) {
            const window = this._find(id);
            if (window && this._hide(window))
                count++;
        }
        return count;
    }

    /// 放回来（不切前台）；空列表 = 全部
    Show(ids) {
        if (ids.length === 0)
            return this._showAll();
        let count = 0;
        for (const id of ids) {
            if (this._show(id))
                count++;
        }
        return count;
    }

    /// 续约：Kiteline 开着虚拟屏幕时每 10 秒调一次；过期还没续（退出、崩溃、卡住）就全部放回来
    Keep(seconds) {
        this._lease = Date.now() + seconds * 1000;
    }

    // MARK: 投递期间截住你的按键（同 Mac 版 KeyHold）
    // 投递把 VS Code 切到前台的这一两秒，你手上可能还在打字：这些键落进 VS Code 会混进刚粘贴的消息，输入法正在拼字时，
    // Kiteline 按的回车还会被输入法拿去上屏拼音，消息根本没发出去（10-25 在 Mac 上遇到）。Wayland 下普通程序截不了键盘，
    // 由桌面暂时接管（同打开概览时）：键交给一个看不见的部件记下来，前台还回去以后用虚拟键盘按原顺序补发。
    // 接管期间 VS Code 没有键盘焦点，粘贴、回车前 Kiteline 先 PauseKeys 放开，按完 ResumeKeys 再接管；seconds 秒后自己放开

    /// 开始接管键盘；接管不了（别的程序正接管着）返回 false。已经在接管就只把时限往后延
    HoldKeys(seconds) {
        if (this._hold) {
            this._holdTimer(seconds);
            return true;
        }
        const actor = new Clutter.Actor({reactive: true, width: 1, height: 1, opacity: 0});
        Main.layoutManager.uiGroup.add_child(actor);
        const hold = {actor, grab: null, keys: [], timer: 0, last: Date.now()};
        const record = pressed => (_actor, event) => {
            hold.keys.push([event.get_key_code(), pressed]);
            hold.last = Date.now();
            return Clutter.EVENT_STOP;
        };
        actor.connect('key-press-event', record(true));
        actor.connect('key-release-event', record(false));
        this._hold = hold;
        if (!this._grab()) {
            this._hold = null;
            actor.destroy();
            return false;
        }
        this._holdTimer(seconds);
        return true;
    }

    /// 你多久没按键了（毫秒；从开始接管算起）：Kiteline 等你停手再放开键盘去粘贴、回车，别让正在打的字漏进 VS Code
    KeysIdle() {
        return this._hold ? Math.min(Date.now() - this._hold.last, 0xffffffff) : 0xffffffff;
    }

    PauseKeys() {
        if (this._hold?.grab) {
            Main.popModal(this._hold.grab);
            this._hold.grab = null;
        }
    }

    ResumeKeys() {
        return this._hold ? this._grab() : false;
    }

    /// 放开键盘；replay = 把截下的键补发给现在的前台窗口（Kiteline 先把前台还回去再调）。返回截下了几次按键
    ReleaseKeys(replay) {
        const hold = this._hold;
        if (!hold)
            return 0;
        this._hold = null;
        if (hold.timer)
            GLib.source_remove(hold.timer);
        if (hold.grab)
            Main.popModal(hold.grab);
        hold.actor.destroy();
        const presses = hold.keys.filter(([, pressed]) => pressed).length;
        if (replay && hold.keys.length > 0) {
            // 等桌面把键盘焦点交回窗口再补发；截着时按下、放开以后才松开的键补一个松开，别一直按着
            const down = new Set();
            for (const [code, pressed] of hold.keys) {
                if (pressed)
                    down.add(code);
                else
                    down.delete(code);
            }
            const keys = [...hold.keys, ...[...down].map(code => [code, false])];
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 60, () => {
                this._keyboard ??= Clutter.get_default_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
                for (const [code, pressed] of keys)
                    this._keyboard.notify_key(GLib.get_monotonic_time(), code - 8, pressed ? Clutter.KeyState.PRESSED : Clutter.KeyState.RELEASED);
                return GLib.SOURCE_REMOVE;
            });
        }
        return presses;
    }

    _grab() {
        const hold = this._hold;
        if (hold.grab)
            return true;
        const grab = Main.pushModal(hold.actor, {actionMode: Shell.ActionMode.NONE});
        if (!(grab.get_seat_state() & Clutter.GrabState.KEYBOARD)) {
            Main.popModal(grab);
            return false;
        }
        hold.grab = grab;
        global.stage.set_key_focus(hold.actor);
        return true;
    }

    _holdTimer(seconds) {
        const hold = this._hold;
        if (hold.timer)
            GLib.source_remove(hold.timer);
        hold.timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, Math.max(1, seconds), () => {
            hold.timer = 0;
            if (this._hold === hold) {
                console.log('Kiteline：接管键盘超时（Kiteline 没有放开），自动放开');
                this.ReleaseKeys(false);
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    // MARK: 藏起来、放回来

    _windows() {
        return global.get_window_actors().map(actor => actor.meta_window)
            .filter(w => w && w.get_window_type() === Meta.WindowType.NORMAL && !w.is_skip_taskbar());
    }

    _find(id) {
        return this._windows().find(w => w.get_id() === id) ?? null;
    }

    _hide(window) {
        const id = window.get_id();
        if (this._hidden.has(id))
            return false;
        const actor = window.get_compositor_private();
        if (!actor)
            return false;
        const entry = {window, sticky: window.is_on_all_workspaces(), handlers: []};
        // 放到所有工作区上：切过去投递时不会换工作区；压到最底下：系统找下一个窗口给焦点时先轮到看得见的
        if (!entry.sticky)
            window.stick();
        window.lower();
        actor.hide();
        // 切到前台、取消最小化的动画会把它重新显示出来：藏着期间一律再藏回去
        entry.handlers.push([actor, actor.connect('notify::visible', () => {
            if (actor.visible && this._hidden?.has(id)) {
                GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                    if (this._hidden?.has(id))
                        actor.hide();
                    return GLib.SOURCE_REMOVE;
                });
            }
        })]);
        entry.handlers.push([window, window.connect('unmanaged', () => this._drop(id))]);
        this._hidden.set(id, entry);
        return true;
    }

    _show(id) {
        const entry = this._drop(id);
        if (!entry)
            return false;
        const {window} = entry;
        if (!entry.sticky)
            window.unstick();
        const actor = window.get_compositor_private();
        if (actor && !window.minimized)
            actor.show();
        return true;
    }

    _showAll() {
        let count = 0;
        for (const id of [...(this._hidden?.keys() ?? [])]) {
            if (this._show(id))
                count++;
        }
        return count;
    }

    _drop(id) {
        const entry = this._hidden?.get(id);
        if (!entry)
            return null;
        for (const [object, handler] of entry.handlers) {
            try {
                object.disconnect(handler);
            } catch (e) {
                // 窗口已经关了
            }
        }
        this._hidden.delete(id);
        return entry;
    }

    _checkLease() {
        if (this._hidden.size > 0 && this._lease && Date.now() > this._lease) {
            console.log('Kiteline：没有续约（Kiteline 已退出或无响应），把藏着的窗口放回来');
            this._showAll();
            this._lease = 0;
        }
    }

    // MARK: 谁把藏着的窗口切到了前台

    _remember(window) {
        this._forgetLast();
        this._last = window;
        this._lastGone = false;
        if (window) {
            const gone = () => {
                this._lastGone = true;
            };
            this._lastHandlers = [window.connect('unmanaging', gone), window.connect('unmanaged', gone)];
        }
    }

    _forgetLast() {
        if (this._last) {
            for (const handler of this._lastHandlers) {
                try {
                    this._last.disconnect(handler);
                } catch (e) {
                    // 窗口已经关了
                }
            }
        }
        this._last = null;
        this._lastHandlers = [];
    }

    _focusChanged() {
        const window = global.display.focus_window;
        const previous = this._last;
        const previousGone = this._lastGone || (previous?.minimized ?? false);
        this._remember(window);
        if (!window || !this._hidden.has(window.get_id()))
            return;
        // Kiteline 自己切过去的（投递）
        if (this._requested?.id === window.get_id() && Date.now() < this._requested.until)
            return;
        // 你从 Alt+Tab、Dock、概览里选了它：前一个窗口还好好的（或者在概览里）→ 放回来给你看
        if (Main.overview.visible || (previous && previous !== window && !previousGone)) {
            this._show(window.get_id());
            this._dbus?.emit_signal('Shown', new GLib.Variant('(t)', [window.get_id()]));
            return;
        }
        // 关掉 / 最小化别的窗口时系统顺手把焦点给了它：让给下一个看得见的窗口，别让键盘输入打进看不见的地方
        GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            this._yield(window);
            return GLib.SOURCE_REMOVE;
        });
    }

    _yield(window) {
        if (global.display.focus_window !== window || !this._hidden?.has(window.get_id()))
            return;
        const workspace = global.workspace_manager.get_active_workspace();
        const next = global.display.get_tab_list(Meta.TabList.NORMAL, workspace)
            .find(w => w !== window && !this._hidden.has(w.get_id()) && !w.minimized);
        if (next)
            next.activate(global.get_current_time());
        else
            global.display.unset_input_focus?.(global.get_current_time());
    }
}
