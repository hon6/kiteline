#!/usr/bin/env python3
"""SF Symbols 名 → Fluent UI 图标（microsoft/fluentui-system-icons，MIT）的码位表，生成 UI/Icons.g.cs。
Mac 版用的是 SF Symbols（只能在苹果系统上用），Windows / Linux 版换成最接近的 Fluent 图标。
用法：python3 desktop/client/tools/gen-icons.py <FluentSystemIcons-Regular.json> <FluentSystemIcons-Filled.json>"""
import json, sys, pathlib
regular = json.load(open(sys.argv[1])); filled = json.load(open(sys.argv[2]))
# SF 名: 候选的 Fluent 名（取第一个存在的）。.fill 结尾的 SF 用实心版
MAP = {
 "alarm": ["clock_alarm"], "antenna.radiowaves.left.and.right": ["broadcast", "live", "cellular_data_1"], "arrow.clockwise": ["arrow_clockwise"],
 "arrow.counterclockwise": ["arrow_counterclockwise"], "arrow.down": ["arrow_down"], "arrow.down.right.and.arrow.up.left": ["arrow_minimize"],
 "arrow.down.to.line": ["arrow_download"], "arrowshape.turn.up.backward": ["arrow_reply"], "arrow.triangle.2.circlepath": ["arrow_sync"],
 "arrow.triangle.branch": ["branch"], "arrow.up": ["arrow_up"], "arrow.up.arrow.down.circle": ["arrow_sort"], "arrow.up.circle": ["arrow_circle_up"],
 "arrow.up.forward.app": ["open"], "arrow.uturn.backward": ["arrow_undo"], "arrow.uturn.forward.circle": ["arrow_redo"],
 "bell": ["alert"], "bell.badge": ["alert_badge"], "bell.slash": ["alert_off"], "bolt.horizontal": ["flash"], "bolt": ["flash"],
 "book.closed": ["book"], "bubble.left": ["chat"], "bubble.left.and.bubble.right": ["chat_multiple"], "bubble.left.and.text.bubble.right": ["chat_multiple"],
 "chart.bar": ["data_bar_vertical", "data_histogram"], "checklist": ["task_list_ltr", "task_list_square_ltr", "checkbox_checked"],
 "checkmark": ["checkmark"], "checkmark.circle": ["checkmark_circle"], "checkmark.seal": ["checkmark_starburst", "ribbon"],
 "checkmark.shield": ["shield_checkmark"], "checkmark.square": ["checkbox_checked"], "chevron.down": ["chevron_down"], "chevron.left": ["chevron_left"],
 "chevron.right": ["chevron_right"], "chevron.up": ["chevron_up"], "chevron.left.forwardslash.chevron.right": ["code"],
 "circle": ["circle"], "circle.dashed": ["circle_hint", "circle_line"], "circle.dotted": ["circle_hint", "circle_line"], "circle.dotted.circle": ["circle_hint"],
 "circle.grid.2x2": ["grid_dots", "grid"], "clock.arrow.circlepath": ["history"], "cpu": ["developer_board", "chip"], "display": ["desktop"],
 "doc.badge.ellipsis": ["document_more", "document_ellipsis", "document_text"], "doc.badge.plus": ["document_add"], "doc.on.clipboard": ["clipboard_paste"],
 "doc.on.doc": ["copy"], "doc.text": ["document_text"], "dollarsign.circle": ["money", "currency_dollar_euro"], "ellipsis": ["more_horizontal"],
 "ellipsis.circle": ["more_circle"], "exclamationmark.circle": ["error_circle"], "exclamationmark.shield": ["shield_error"],
 "exclamationmark.triangle": ["warning"], "eye": ["eye"], "folder": ["folder"], "gauge.with.dots.needle.50percent": ["gauge"], "gearshape": ["settings"],
 "hand.raised": ["hand_left", "hand_right"], "hourglass": ["hourglass"], "info": ["info"], "info.circle": ["info"], "iphone": ["phone"], "iphone.gen3": ["phone"],
 "line.3.horizontal": ["line_horizontal_3"], "line.3.horizontal.decrease": ["filter"], "line.3.horizontal.decrease.circle": ["filter"],
 "list.bullet.clipboard": ["clipboard_task_list_ltr", "clipboard_bullet_list_ltr"], "list.bullet.rectangle": ["text_bullet_list_square"],
 "lock": ["lock_closed"], "lock.shield": ["shield_lock"], "magnifyingglass": ["search"], "map": ["map"], "mic": ["mic"], "minus": ["subtract"],
 "minus.circle": ["subtract_circle"], "moon.stars": ["weather_moon"], "paperplane": ["send"], "pencil": ["edit"], "pencil.line": ["edit"],
 "person.2": ["people"], "person.badge.key": ["person_key", "person_lock"], "photo": ["image"], "photo.badge.plus": ["image_add"],
 "photo.on.rectangle": ["image_multiple"], "photo.on.rectangle.angled": ["image_multiple"], "pin": ["pin"], "pin.slash": ["pin_off"], "plus": ["add"],
 "plus.circle": ["add_circle"], "plus.square.on.square": ["add_square_multiple", "square_multiple"], "plusminus.circle": ["add_subtract_circle", "diff"],
 "point.3.connected.trianglepath.dotted": ["flowchart", "organization"], "puzzlepiece.extension": ["puzzle_piece"], "qrcode": ["qr_code"],
 "questionmark.bubble": ["chat_bubbles_question"], "questionmark.circle": ["question_circle"], "quote.opening": ["text_quote"], "server.rack": ["server"],
 "sidebar.left": ["panel_left"], "slider.horizontal.3": ["options"], "sparkles": ["sparkle"], "speaker.wave.2": ["speaker_2"],
 "square.and.arrow.down": ["arrow_download", "save"], "square.and.arrow.up": ["share"], "square.and.pencil": ["compose"],
 "square.split.1x2": ["layout_row_two", "split_horizontal"], "square.split.2x1": ["layout_column_two", "split_vertical"], "stop": ["stop", "record_stop"], "sun.haze": ["weather_haze"],
 "sun.max": ["weather_sunny"], "text.bubble": ["comment"], "text.cursor": ["text_cursor", "textbox"], "text.word.spacing": ["text_word_count", "text_column_one"],
 "trash": ["delete"], "waveform": ["waveform", "sound_wave_circle", "device_eq"], "wifi.exclamationmark": ["wifi_warning"], "wifi.slash": ["wifi_off"],
 "wrench.and.screwdriver": ["wrench_screwdriver", "wrench"], "xmark": ["dismiss"], "xmark.circle": ["dismiss_circle"], "xmark.seal": ["dismiss_circle"],
 "terminal": ["window_console"], "globe": ["globe"], "laptopcomputer": ["laptop"], "paperclip": ["attach"], "map.fill": ["map"],
 "book": ["book"], "keyboard": ["keyboard"], "command": ["keyboard_command", "keyboard"], "return": ["arrow_enter_left", "arrow_enter"], "play": ["play"], "pause": ["pause"],
 "tray": ["tray_item", "mail_inbox"], "archivebox": ["archive"], "flag": ["flag"], "star": ["star"], "heart": ["heart"], "tag": ["tag"], "link": ["link"], "key": ["key"],
 "person": ["person"], "clock": ["clock"], "calendar": ["calendar_ltr", "calendar"], "network": ["network_check", "globe"], "wifi": ["wifi_1"], "cloud": ["cloud"],
 "eye.slash": ["eye_off"], "hammer": ["wrench"], "lightbulb": ["lightbulb"], "envelope": ["mail"], "timer": ["timer"], "cube": ["cube"], "shippingbox": ["box"],
 "externaldrive": ["hard_drive"], "internaldrive": ["hard_drive", "database"], "desktopcomputer": ["desktop"], "macwindow": ["window"], "cursorarrow": ["cursor"], "speaker.slash": ["speaker_mute"], "arrow.down.circle": ["arrow_circle_down"],
 "arrow.left": ["arrow_left"], "arrow.right": ["arrow_right"], "square.on.square": ["square_multiple"], "rectangle.split.3x1": ["split_vertical"],
 "dot.radiowaves.left.and.right": ["broadcast", "cellular_data_1", "wifi_1"], "arrow.turn.down.left": ["arrow_enter_left"], "text.alignleft": ["text_align_left"],
 "list.bullet": ["text_bullet_list_ltr", "list"], "number": ["number_symbol"], "calendar.badge.clock": ["calendar_clock"], "bubble.left.fill": ["chat"],
 "applewatch": ["smartwatch"], "lock.shield": ["shield_lock"], "photo.badge.plus": ["image_add"], "person.crop.circle": ["person_circle"],
 "doc.text.magnifyingglass": ["document_search"], "minus.magnifyingglass": ["zoom_out"], "plus.magnifyingglass": ["zoom_in"],
 "arrow.up.left.and.down.right.magnifyingglass": ["zoom_fit"], "folder.badge.gearshape": ["folder_open"], "arrow.triangle.2.circlepath": ["arrow_sync"],
 "door.left.hand.open": ["door_arrow_right", "door"],
}
def pick(cands, table, style):
    for base in cands:
        for size in (20, 24):
            if f"ic_fluent_{base}_{size}_{style}" in table: return base
    return None
lines = ["// 生成的文件：python3 desktop/client/tools/gen-icons.py（SF Symbols 名 → Fluent UI 图标码位），别手改", "namespace Kiteline.UI;", "",
         "public static partial class Icons", "{", "    /// SF 名 → (Fluent 名, 20 号常规, 24 号常规, 20 号实心, 24 号实心)；0 = 没有这一档",
         "    static readonly Dictionary<string, (string Name, int R20, int R24, int F20, int F24)> Table = new()", "    {"]
missing = []
for sf, cands in MAP.items():
    base = pick(cands, regular, "regular") or pick(cands, filled, "filled")
    if not base: missing.append(sf); continue
    g = lambda t, s, st: t.get(f"ic_fluent_{base}_{s}_{st}", 0)
    lines.append(f'        ["{sf}"] = ("{base}", {g(regular,20,"regular")}, {g(regular,24,"regular")}, {g(filled,20,"filled")}, {g(filled,24,"filled")}),')
lines += ["    };", "}", ""]
pathlib.Path(__file__).resolve().parent.parent.joinpath("UI/Icons.g.cs").write_text("\n".join(lines), encoding="utf-8")
print(len(MAP) - len(missing), "mapped; missing:", missing)
