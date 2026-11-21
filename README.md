# ImmortalWrt 云编译固件 —— CMCC RAX3000M（eMMC 版，无 Docker）

用 GitHub Actions 自动编译 **ImmortalWrt 24.10（最新 24.10 稳定分支，v24.10.6）**，目标设备为
**CMCC RAX3000M / MT7981B / eMMC 版 / OpenWrt U-Boot 布局**（设备名 `cmcc_rax3000m`）。

本仓库是 **公开版**：不含 Docker，也**不写入 Wi-Fi 密码**（默认开放网络），方便放在 Public 仓库里。

---

## 一、固件预置参数

| 项目 | 值 |
| --- | --- |
| 后台地址 | `http://192.168.6.1`（默认无密码，首次登录请自行设置） |
| 主机名 | `RAX3000M` |
| 时区 | `Asia/Shanghai`（CST-8） |
| 2.4G Wi-Fi | SSID `Persist`，**开放网络（无密码）** |
| 5G Wi-Fi | SSID `Persist-5G`，**开放网络（无密码）** |
| 主题 | 内置 Argon（系统 → 语言和界面 里切换） |
| 系统分区 | 4 GB（写在编译出的 `emmc-gpt.bin` 里，见第六节） |

> 刷完请**第一时间**做两件事：给 Wi-Fi 设 WPA2 密码、给 root 设登录密码。

## 二、集成的插件

| 插件 | 包名 | 说明 |
| --- | --- | --- |
| OpenAppFilter | `luci-app-oaf` + `kmod-oaf` + `appfilter` | 应用过滤/青少年模式，含内核模块 |
| PassWall 2 | `luci-app-passwall2` | 官方新仓库 `Openwrt-Passwall/openwrt-passwall2`，nftables 透明代理，内置 Xray + sing-box |
| AccessControl Plus | `luci-app-accesscontrol-plus` | 上网时间控制（按设备/模板限时上网） |
| AdGuard Home | `luci-app-adguardhome` + `adguardhome` | 去广告 DNS，含二进制，面板适配 24.10+ |
| SmartDNS | `luci-app-smartdns` | 国内外 DNS 分流/优选 |
| WireGuard | `luci-proto-wireguard` + `wireguard-tools` | 组网/VPN |
| Samba | `luci-app-samba4` | 网络共享（含 USB 存储、ext4/exFAT 支持） |
| TTYD | `luci-app-ttyd` | 网页终端 |

另外还带了：中文语言包、`curl`、`htop`、`nano`、`block-mount`、`e2fsprogs`、`partx-utils` 等常用工具。

> 需要 Docker 的请用另一个私有仓库版本（含 `luci-app-dockerman` + docker/dockerd/compose）。

## 三、仓库结构

```
.
├── .github/workflows/build-immortalwrt.yml   # GitHub Actions 工作流
├── configs/rax3000m-emmc.config              # 目标设备 + 插件选择
├── diy-part1.sh                              # feeds 更新前：加源、拉插件源码
├── diy-part2.sh                              # feeds 安装后：调整 .config、make defconfig
├── files/etc/uci-defaults/99-custom-settings # 首次开机：IP / 主机名 / 开放 Wi-Fi
└── README.md
```

## 四、怎么编译

1. 打开本仓库的 **Actions** 标签页，左侧选 **Build ImmortalWrt for CMCC RAX3000M (eMMC, no docker)**；
2. 点 **Run workflow**，分支参数保持默认 `openwrt-24.10`；
3. 编译约 **1.5 ~ 2.5 小时**（公开仓库是 4 核 runner）。完成后进入这次运行，
   页面底部 **Artifacts** 里下载 `ImmortalWrt-openwrt-24.10-RAX3000M-eMMC.zip`。

也可以直接 push 改动到 `main` 自动触发（改了 `configs/`、`diy-part*.sh`、`files/`、工作流时）。

解压后得到这些文件：

| 文件 | 用途 |
| --- | --- |
| `immortalwrt-mediatek-filogic-cmcc_rax3000m-squashfs-sysupgrade.itb` | **升级/安装固件**（sysupgrade 或 U-Boot 网页刷它） |
| `immortalwrt-mediatek-filogic-cmcc_rax3000m-emmc-gpt.bin` | 全新安装时重建 GPT 分区表 |
| `immortalwrt-mediatek-filogic-cmcc_rax3000m-emmc-preloader.bin` | 全新安装时写 BL2 |
| `immortalwrt-mediatek-filogic-cmcc_rax3000m-emmc-bl31-uboot.fip` | 全新安装时写 U-Boot |

构建日志和 `.config` 在 `build-info-*` 这个 Artifact 里，编译失败时先看它。

## 五、刷机方式 A：直接 sysupgrade（现有分区够大时）

适用：你现在的 U-Boot 布局分区 ≥ 200 MB（之前刷过 1 GB / 2 GB 大分区固件）。

1. 打开当前后台，进入 **系统 → 备份/升级 → 刷写新固件**；
2. 选择 `...-squashfs-sysupgrade.itb`；
3. **取消勾选「保留当前配置」**（重要：新固件要改 LAN 为 192.168.6.1、重建 Wi-Fi 配置，
   保留旧配置会导致首次配置脚本不执行）；
4. 刷写，等 3~5 分钟自动重启。

SSH 方式：

```sh
scp immortalwrt-mediatek-filogic-cmcc_rax3000m-squashfs-sysupgrade.itb root@192.168.1.1:/tmp/
ssh root@192.168.1.1
sysupgrade -n /tmp/immortalwrt-mediatek-filogic-cmcc_rax3000m-squashfs-sysupgrade.itb
```

如果提示 `Image too big` / 空间不足，改用方式 B。

## 六、刷机方式 B：eMMC 全新安装（重建 4 GB 分区，会清空数据）

> ⚠️ 这一步会重写 eMMC 的 GPT、BL2、U-Boot，**eMMC 上的数据全部丢失**。
> 操作前先备份 `factory` 分区（无线校准数据和 MAC 地址）：
> `dd if=/dev/mmcblk0p2 of=/tmp/factory.bin conv=fsync`，再用 WinSCP 下载保存。
> 命令来自 OpenWrt 官方 eMMC 安装说明，请逐条核对再执行，中途不要断电。

1. 把 `emmc-gpt.bin`、`emmc-preloader.bin`、`emmc-bl31-uboot.fip`、`sysupgrade.itb`
   上传到路由器 `/tmp/`。
2. SSH 登录后按顺序执行：

```sh
cd /tmp

# 1) 写新的 GPT 分区表
dd if=immortalwrt-mediatek-filogic-cmcc_rax3000m-emmc-gpt.bin \
   of=/dev/mmcblk0 bs=512 seek=0 count=34 conv=fsync

# 2) 重写 BL2（在 eMMC 的 boot0 分区）
echo 0 > /sys/block/mmcblk0boot0/force_ro
dd if=/dev/zero of=/dev/mmcblk0boot0 bs=512 count=8192 conv=fsync
dd if=immortalwrt-mediatek-filogic-cmcc_rax3000m-emmc-preloader.bin \
   of=/dev/mmcblk0boot0 bs=512 conv=fsync

# 3) 重写 U-Boot（fip 分区，偏移 13312 扇区 = 6.5 MB）
dd if=/dev/zero of=/dev/mmcblk0 bs=512 seek=13312 count=8192 conv=fsync
dd if=immortalwrt-mediatek-filogic-cmcc_rax3000m-emmc-bl31-uboot.fip \
   of=/dev/mmcblk0 bs=512 seek=13312 conv=fsync

sync
reboot
```

3. 重启后进入 U-Boot：网线接 LAN 口，电脑 IP 设为 `192.168.1.2/24`，
   浏览器打开 `http://192.168.1.1`（部分 U-Boot 是 `http://192.168.1.1/uboot.html`），
   上传 `...-squashfs-sysupgrade.itb` 刷写。

## 七、刷完之后（重要）

1. 电脑连 Wi-Fi `Persist`（**此时是开放网络，没有密码**），或网线接 LAN 口。
2. 打开 `http://192.168.6.1`，root 空密码登录。
3. 立刻做两件事：
   - **网络 → 无线**：给 `Persist`、`Persist-5G` 设置 WPA2 密码；
   - **系统 → 管理权**：设置 root 登录密码。
4. 确认两个频段都已启用、SSID 正确。

## 八、注意事项

1. **53 端口只能有一个 DNS 服务**：SmartDNS、AdGuard Home、PassWall2 的 DNS 分流都要 53 端口。
   建议只用其一，例如「AdGuard Home 监听 53，上游填 SmartDNS」，其余停用并取消开机自启，
   否则会出现 DNS 解析失败/网页打不开。
2. **OpenAppFilter** 会接管 netfilter 做应用识别，和 PassWall2 的规则可能互相影响；
   代理异常时先停用 OAF 验证。
3. **AccessControl Plus** 依赖 `iptables` + `snmpd`，在 24.10 的 fw4/nftables 下能用，
   但规则写法和老版 fw3 不同，极端情况下限时功能可能不生效，可改用 OAF 的「应用过滤」。
4. **PassWall2** 旧地址 `xiaorouji/openwrt-passwall2` 已被作者删除，本仓库用
   `Openwrt-Passwall/openwrt-passwall2`；节点/订阅需要刷完后自己在 LuCI 里添加。
5. 本版本**没有 Docker**；需要 Docker 请用私有仓库版本，或刷完后 `opkg update` 自行安装
   `dockerd docker luci-app-dockerman`（需要足够 overlay 空间）。
6. 固件默认**没有 root 密码**、Wi-Fi 也是开放的，刷完请立即按第七节设置，避免暴露到公网。

## 九、想改配置？

- 改 Wi-Fi 名称/密码、LAN IP：编辑 `files/etc/uci-defaults/99-custom-settings`，重新跑 Action；
- 加减插件：编辑 `configs/rax3000m-emmc.config`（`CONFIG_PACKAGE_xxx=y`），重新跑 Action；
- 固定插件版本：在 `diy-part1.sh` 里把 `git clone --depth 1` 换成带 tag 的写法。

## 十、常见问题

**Q：Action 里提示 `luci-app-passwall2` MISS？**
A：passwall2 源仓库分支改名或被墙时会出现。先看日志里 `feeds update` 是否成功，
必要时把 `diy-part1.sh` 里的 `;main` 换成实际默认分支名。

**Q：编译到一半失败？**
A：多半是某个包下载失败。点 **Re-run all jobs** 重跑通常能过；也可以下载
`build-info-*` Artifact（含 `build.log`、`build.config`）定位具体包。

**Q：运行动辄 4 小时然后“无日志掉线”？**
A：这是 runner 资源问题。本仓库已把编译目录放到 `/mnt`（runner 的大容量盘）、加了 swap，
并且去掉了 Docker，正常 2 小时内能完成；如果还出现，直接重跑。

**Q：下载的 zip 里没有 `.itb`？**
A：说明编译在生成镜像之前就失败了，本次运行是红的，看 `build-info-*` 里的 `build.log`。

**Q：刷完还是 192.168.1.1？**
A：升级时勾了「保留配置」。重新刷一次并取消保留配置（`sysupgrade -n`）。

## 2026-11-21 更新：DNS/服务架构固化

- 新增 `files/usr/bin/agh-supervisor.sh`、`agh-upstream.sh`、`dnsprobe.lua`、`netguard.sh`
- 新增 `/etc/init.d/agh-boot`、`/etc/init.d/netguard`；`AdGuardHome` 改为兼容壳，避免起两个实例
- dnsmasq 固定有序上游：`127.0.0.1#3053` → `127.0.0.1#6053` → `192.168.1.1#53`
- SmartDNS 的 2002 上游改为 **UDP**（TCP 会把 xray 单核跑满），内置 10.9 万条国内域名分流
- 预置 `/etc/AdGuardHome.yaml`：监听 3053、上游 SmartDNS 6053；**不含管理员密码**，首次打开 AGH 面板请立即设置
- 本公开版本仍**不写入 Wi-Fi 密码**，首次开机 Wi-Fi 为开放网络，请刷机后第一时间在 LuCI 设置 WPA2
- 构建时注入 Xray 26.11.9（feed 的 25.2.21 不认 PassWall2 26.x 的 `tunnel` 入站）
