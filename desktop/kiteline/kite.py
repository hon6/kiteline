"""Kiteline 的纸鸢（北京沙燕）：托盘图标和控制台页头用。
形状照抄 KitelineKit/Shared/PaperKite.swift（App 图标、iPhone、Mac 共用的那一份；384×384 格子、y 朝下），改形状两边一起改。
这里只画小图标用的剪影：身子四周留一道缝、挖出眼睛，扇骨这些细节小了看不出来"""

PATHS = {
    "tailLeft": "M174 142 C140 164 80 204 4 238 C70 216 136 186 184 158 Z",
    "tailDown": "M178 151 C175 220 162 290 147 347 C170 292 188 226 194 155 Z",
    "farFan": "M207 63 L100 10 C95 12 94 20 97 30 C104 56 124 88 150 112 C166 127 180 134 194 137 Z",
    "farBand": "M212 58 L100 9 C95 10 93 17 96 27 L103 33 C136 51 170 69 206 85 Z",
    "nearFan": "M256 104 L378 166 C384 170 383 179 375 184 C335 191 292 188 252 174 C232 166 216 157 206 149 Z",
    "nearBand": "M262 92 L379 165 C385 169 384 178 376 183 L368 186 C330 166 290 146 248 124 Z",
    "body": "M236 40 C252 28 278 31 287 49 C290 66 284 84 270 104 C256 124 230 146 200 156 C186 160 174 158 170 150 C164 138 172 112 186 92 C200 70 218 50 236 40 Z",
    "beak": "M284 45 C290 41 296 38 302 36 C298 42 294 48 288 56 Z",
}

# 页头用的 SVG（同一只纸鸢的剪影版，颜色跟 CSS 的 color 走）
SVG_GLYPH = '<svg width="30" height="30" viewBox="0 0 384 384" style="color:#d97757"><defs><mask id="kl-kite-g" maskUnits="userSpaceOnUse" x="-20" y="-20" width="440" height="480"><path d="M174 142 C140 164 80 204 4 238 C70 216 136 186 184 158 Z" fill="#fff"/><path d="M178 151 C175 220 162 290 147 347 C170 292 188 226 194 155 Z" fill="#fff"/><path d="M207 63 L100 10 C95 12 94 20 97 30 C104 56 124 88 150 112 C166 127 180 134 194 137 Z" fill="#fff"/><path d="M212 58 L100 9 C95 10 93 17 96 27 L103 33 C136 51 170 69 206 85 Z" fill="#fff"/><path d="M256 104 L378 166 C384 170 383 179 375 184 C335 191 292 188 252 174 C232 166 216 157 206 149 Z" fill="#fff"/><path d="M262 92 L379 165 C385 169 384 178 376 183 L368 186 C330 166 290 146 248 124 Z" fill="#fff"/><path d="M236 40 C252 28 278 31 287 49 C290 66 284 84 270 104 C256 124 230 146 200 156 C186 160 174 158 170 150 C164 138 172 112 186 92 C200 70 218 50 236 40 Z" fill="#fff" stroke="#000" stroke-width="9"/><path d="M236 40 C252 28 278 31 287 49 C290 66 284 84 270 104 C256 124 230 146 200 156 C186 160 174 158 170 150 C164 138 172 112 186 92 C200 70 218 50 236 40 Z" fill="#fff"/><path d="M284 45 C290 41 296 38 302 36 C298 42 294 48 288 56 Z" fill="#fff"/><circle cx="270" cy="48" r="9" fill="#000"/></mask></defs><rect x="-20" y="-20" width="440" height="480" fill="currentColor" mask="url(#kl-kite-g)"/></svg>'


def _polygons(d, k, steps=12):
    """SVG 路径（只有绝对坐标的 M / L / C / Z）→ 折线多边形，按 k 倍缩放"""
    tokens = [t for t in d.replace(",", " ").split() if t]
    shapes, current, cmd, nums = [], [], "M", []

    def flush():
        nonlocal current
        if cmd == "M":
            for i in range(0, len(nums) - 1, 2):
                if i == 0:
                    if current:
                        shapes.append(current)
                    current = [(nums[0] * k, nums[1] * k)]
                else:
                    current.append((nums[i] * k, nums[i + 1] * k))
        elif cmd == "L":
            for i in range(0, len(nums) - 1, 2):
                current.append((nums[i] * k, nums[i + 1] * k))
        elif cmd == "C":
            for i in range(0, len(nums) - 5, 6):
                x0, y0 = current[-1]
                x1, y1, x2, y2, x3, y3 = (v * k for v in nums[i:i + 6])
                for s in range(1, steps + 1):
                    t = s / steps
                    u = 1 - t
                    current.append((u ** 3 * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t ** 3 * x3,
                                    u ** 3 * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t ** 3 * y3))

    for token in tokens:
        if token[0].isalpha():
            flush()
            cmd, nums = token[0], []
            rest = token[1:]
            if rest:
                nums.append(float(rest))
        else:
            nums.append(float(token))
    flush()
    if current:
        shapes.append(current)
    return shapes


def tray_image(size=64, color=(217, 119, 87, 255)):
    """托盘图标：纯色纸鸢剪影 + 从提线结垂下的一小段线（先按 4 倍画再缩小，边缘平滑）"""
    from PIL import Image, ImageDraw
    big = size * 4
    k = big / 384
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    draw.line([(246 * k, 196 * k), (268 * k, 384 * k)], fill=255, width=max(2, round(big / 90)))  # 要比燕尾细
    for name in ("tailLeft", "tailDown", "farFan", "farBand", "nearFan", "nearBand"):
        for poly in _polygons(PATHS[name], k):
            draw.polygon(poly, fill=255)
    for poly in _polygons(PATHS["body"], k):
        draw.line(poly + [poly[0]], fill=0, width=max(2, round(9 * k)))
        draw.polygon(poly, fill=255)
    for poly in _polygons(PATHS["beak"], k):
        draw.polygon(poly, fill=255)
    r = 10 * k
    draw.ellipse([270 * k - r, 48 * k - r, 270 * k + r, 48 * k + r], fill=0)
    mask = mask.resize((size, size), Image.LANCZOS)
    image = Image.new("RGBA", (size, size), color)
    image.putalpha(mask)
    return image
