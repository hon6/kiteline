import SwiftUI

/// 左边栏顶上的入口图标：一颗像素地球（我的世界的方块：水、草地、沙滩），鼠标移上去转起来；开着世界时下面一道主题色
public struct WorldGlobeIcon: View {
    var active = false
    @State private var hovering = false

    public init(active: Bool = false) { self.active = active }

    /// 18 列的地图（循环滚动 = 地球在转），每格一个方块：w 水、g 草地、d 深色草地、s 沙滩
    private static let map = [
        "wwwggwwwwwwsggwwww",
        "wwgggdwwwwggggwwww",
        "wsgdggswwwggdgswww",
        "wwgggwwwwwwgggwwgw",
        "wwwgwwwwggwwgwwggg",
        "wwwwwwwgdggwwwwgdg",
        "wwwswwwggggswwwwgw",
        "wwgggwwwgdgwwwwwww",
        "wwwgwwwwwgwwwwwsww",
    ]
    private static let rows = [3, 5, 7, 9, 9, 9, 7, 5, 3]

    public var body: some View {
        TimelineView(.animation(minimumInterval: 0.11, paused: !hovering)) { context in
            let shift = hovering ? Int(context.date.timeIntervalSinceReferenceDate * 9) % 18 : 4
            Canvas { ctx, size in
                let cell = floor(min(size.width, size.height) / 9)
                let origin = CGPoint(x: (size.width - cell * 9) / 2, y: (size.height - cell * 9) / 2)
                for (r, width) in Self.rows.enumerated() {
                    let start = (9 - width) / 2
                    let line = Array(Self.map[r])
                    for c in start..<(start + width) {
                        let kind = line[(c + shift) % line.count]
                        // 同一种方块深浅错开一点，像我的世界的贴图
                        let odd = (r + c + shift) % 3 == 0
                        let color: Color = switch kind {
                        case "g": odd ? Color(red: 0.36, green: 0.62, blue: 0.22) : Color(red: 0.42, green: 0.69, blue: 0.26)
                        case "d": Color(red: 0.27, green: 0.50, blue: 0.18)
                        case "s": Color(red: 0.86, green: 0.80, blue: 0.55)
                        default: odd ? Color(red: 0.20, green: 0.42, blue: 0.84) : Color(red: 0.25, green: 0.48, blue: 0.90)
                        }
                        ctx.fill(Path(CGRect(x: origin.x + CGFloat(c) * cell, y: origin.y + CGFloat(r) * cell, width: cell, height: cell)), with: .color(color))
                    }
                }
                // 左上一点高光、右下一点阴影：有点立体
                ctx.fill(Path(CGRect(x: origin.x + cell * 2, y: origin.y + cell * 2, width: cell, height: cell)), with: .color(.white.opacity(0.35)))
                if active {
                    ctx.fill(Path(CGRect(x: origin.x + cell * 2, y: origin.y + cell * 9 + 1, width: cell * 5, height: max(1.5, cell / 2))), with: .color(Theme.claude))
                }
            }
        }
        .frame(width: 20, height: 22)
        #if os(macOS)
        .onHover { hovering = $0 }
        #else
        // 手机上没有悬停：出现时转一圈就停（一直转的话导航栏每秒重画九次，费电）
        .task {
            hovering = true
            try? await Task.sleep(for: .seconds(2))
            hovering = false
        }
        #endif
    }
}
