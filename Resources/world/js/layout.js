// 排位置：前面是办公区（一个项目一块地毯、一面玻璃墙，会话一人一张桌子），后面一排机房（一家 agent 一间），天上卫星（一台设备一颗）。
// 只在会话增减、换项目时重排；同一个项目里按开始时间坐，项目按第一次出现的先后排，状态变了谁都不挪。

export const CELL_W = 7;      // 一张工位占的宽
export const CELL_D = 8.5;    // 一张工位占的深（显示器在后、人在前，后面留走道）
const ZONE_PAD = 1.5;
const ZONE_BACK = 3;          // 玻璃墙到第一排工位
const ZONE_GAP = 5;
const ROOM_D = 7.5;

export function computeLayout(data) {
  const groups = new Map();
  for (const s of data.sessions.values()) {
    if (!groups.has(s.project)) groups.set(s.project, []);
    groups.get(s.project).push(s);
  }
  const order = data.projectOrder;
  const names = [...groups.keys()].sort((a, b) => order.indexOf(a) - order.indexOf(b));
  const zones = names.map(name => {
    const list = groups.get(name).sort((a, b) => (a.startedAt - b.startedAt) || a.key.localeCompare(b.key));
    const n = list.length;
    const cols = n <= 1 ? 1 : n <= 4 ? 2 : n <= 9 ? 3 : 4;
    const rows = Math.ceil(n / cols);
    return { name, sessions: list, cols, rows, w: cols * CELL_W + ZONE_PAD * 2, d: rows * CELL_D + ZONE_BACK, x: 0, z: 0, desks: [] };
  });

  // 一行一行排项目区，一行放不下就换行（行宽按总面积定，整体接近方形）
  const area = zones.reduce((sum, z) => sum + (z.w + ZONE_GAP) * (z.d + ZONE_GAP), 0);
  const maxRow = Math.max(36, Math.sqrt(area) * 1.5);
  const rows = [];
  let row = null;
  for (const zone of zones) {
    if (!row || (row.w + zone.w > maxRow && row.items.length)) {
      row = { items: [], w: 0, d: 0 };
      rows.push(row);
    }
    row.items.push(zone);
    row.w += zone.w + (row.items.length > 1 ? ZONE_GAP : 0);
    row.d = Math.max(row.d, zone.d);
  }
  let z = 0;
  for (const r of rows) {
    let x = -r.w / 2;
    for (const zone of r.items) {
      zone.x = x;
      zone.z = z;   // 同一行的项目区按后面的待办墙对齐（10-27：以墙面对齐，不要以最后一排工位对齐）
      x += zone.w + ZONE_GAP;
    }
    z += r.d + ZONE_GAP;
  }
  for (const zone of zones) {
    zone.sessions.forEach((s, i) => {
      const col = i % zone.cols, rowIndex = Math.floor(i / zone.cols);
      zone.desks.push({
        key: s.key,
        x: zone.x + ZONE_PAD + col * CELL_W + CELL_W / 2,
        // 工位原点 = 人坐的位置；显示器在它后面 2.7
        z: zone.z + ZONE_BACK + rowIndex * CELL_D + 5.2,
      });
    });
  }
  const officeW = rows.reduce((m, r) => Math.max(m, r.w), 0);
  const officeD = Math.max(z - ZONE_GAP, 0);

  // 机房：一家 agent 一间，会话多的排中间，机柜数随会话数
  const counts = new Map();
  for (const s of data.sessions.values()) counts.set(s.agent, (counts.get(s.agent) || 0) + 1);
  const agents = [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  const rooms = agents.map(([agent, n]) => {
    const racks = Math.min(8, Math.max(3, 2 + Math.ceil(n / 2)));
    return { agent, sessions: n, racks, w: racks * 3 + 7, d: ROOM_D, x: 0, z: 0 };
  });
  // 中间放最大的，两边交替往外排
  const arranged = [];
  rooms.forEach((room, i) => { if (i % 2 === 0) arranged.push(room); else arranged.unshift(room); });
  const roomsW = arranged.reduce((sum, r) => sum + r.w, 0) + Math.max(0, arranged.length - 1) * 4;
  let rx = -roomsW / 2;
  const roomZ = -23 - ROOM_D;   // 前面隔着公司墙，往后让开
  for (const room of arranged) {
    room.x = rx;
    room.z = roomZ;
    room.dish = { x: room.x + room.w - 3, z: room.z + room.d - 3 };
    rx += room.w + 4;
  }

  const width = Math.max(officeW, roomsW, 40);
  const minZ = roomZ - 2, maxZ = Math.max(officeD, 10);
  const desks = new Map();
  for (const zone of zones) for (const d of zone.desks) desks.set(d.key, d);
  const roomByAgent = new Map(rooms.map(r => [r.agent, r]));

  // 卫星：一台设备一颗，绕整片场地转（椭圆轨道、高度错开、方向交替）
  const sources = [...data.sources.values()];
  const satellites = sources.map((source, i) => ({
    id: source.id,
    altitude: 36 + (i % 3) * 5,
    rx: width * 0.36 + 6 + (i % 2) * 6,
    rz: (maxZ - minZ) * 0.3 + 4,
    period: 220 + i * 47,
    phase: (i / Math.max(1, sources.length)) * Math.PI * 2,
    dir: i % 2 === 0 ? 1 : -1,
  }));

  // 公司的四面墙：把办公区、机房都围起来；前面多留一大块，镜头站在墙里往里看
  const room = { minX: -width / 2 - 10, maxX: width / 2 + 10, minZ: minZ - 4, maxZ: maxZ + 42 };
  // 公司墙：办公区和机房之间，从左墙接到右墙堵死（机房只留一扇关着的门，见 walls.js），朝办公区一面挂 token 计量牌（10-27）
  const company = { x: (room.minX + room.maxX) / 2, z: -9.5, w: room.maxX - room.minX - 1 };

  return {
    zones, rooms, desks, roomByAgent, satellites, company, room,
    bounds: { minX: -width / 2 - 6, maxX: width / 2 + 6, minZ, maxZ, cx: 0, cz: (minZ + maxZ) / 2, w: width + 12, d: maxZ - minZ },
  };
}
