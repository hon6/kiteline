// 照片墙：项目里最近出现的图（你发的截图、Claude 发来的图、它看过的图）像拍立得一样钉在这个项目的玻璃墙上，
// 每个项目最多三张，新的挤掉旧的；点一下看大图。

import * as THREE from '../vendor/three.module.min.js';

const MAX = 3;

export class Photos {
  constructor(world) {
    this.world = world;
    this.group = new THREE.Group();
    world.scene.add(this.group);
    this.byProject = new Map();   // 项目 → [{url, mesh, texture}]
    this.loader = new THREE.TextureLoader();
    this.frameGeo = new THREE.PlaneGeometry(1.9, 2.15);
    this.imageGeo = new THREE.PlaneGeometry(1.66, 1.5);
    this.frameMat = new THREE.MeshLambertMaterial({ color: 0xF4F1EA });
  }

  add(project, url) {
    const list = this.byProject.get(project) || [];
    if (list.some(p => p.url === url)) return;
    const texture = this.loader.load(url, (tex) => {
      // 按图的比例裁成正方形一点的样子（拍立得）
      const img = tex.image;
      if (img && img.width && img.height) {
        const aspect = img.width / img.height, box = 1.66 / 1.5;
        if (aspect > box) { tex.repeat.set(box / aspect, 1); tex.offset.set((1 - box / aspect) / 2, 0); }
        else { tex.repeat.set(1, aspect / box); tex.offset.set(0, (1 - aspect / box) / 2); }
      }
      this.world.invalidate();
    });
    texture.colorSpace = THREE.SRGBColorSpace;
    const holder = new THREE.Group();
    const frame = new THREE.Mesh(this.frameGeo, this.frameMat);
    const image = new THREE.Mesh(this.imageGeo, new THREE.MeshBasicMaterial({ map: texture }));
    image.position.set(0, 0.17, 0.01);
    frame.userData.photo = url;
    image.userData.photo = url;
    holder.add(frame, image);
    list.unshift({ url, holder, texture, image });
    while (list.length > MAX) {
      const old = list.pop();
      this.group.remove(old.holder);
      old.texture.dispose();
      old.image.material.dispose();
    }
    this.byProject.set(project, list);
    this.group.add(holder);
    this.place();
  }

  /// 按现在的排位钉到各项目的玻璃墙右边（排位变了重新钉）
  place() {
    const layout = this.world.layout;
    if (!layout) return;
    for (const [project, list] of this.byProject) {
      const zone = layout.zones.find(z => z.name === project);
      // 玻璃墙左边是待办便签，图只钉在右边放得下的地方
      const fits = zone ? Math.max(1, Math.floor(zone.w * 0.42 / 2.2)) : 0;
      list.forEach((p, i) => {
        p.holder.visible = !!zone && i < fits;
        if (!zone) return;
        p.holder.position.set(zone.x + zone.w - 1.6 - i * 2.2, 2.0, zone.z + 0.36);
        p.holder.rotation.set(0, 0, ((i * 37 + project.length * 13) % 9 - 4) * 0.02);
      });
    }
  }

  pick(raycaster) {
    const hits = raycaster.intersectObjects(this.group.children, true);
    return hits.length ? hits[0].object.userData.photo : null;
  }
}
