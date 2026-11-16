#!/bin/bash
# diy-part1.sh
# 作用：在 `./scripts/feeds update -a` 之前执行，添加第三方 feed 与插件源码目录。
# 工作目录：openwrt/（源码根目录）
set -euo pipefail

echo "==> [diy-part1] 添加 PassWall 2 源"
# 注意：xiaorouji 的旧仓库已被删除，PassWall2 现在由 Openwrt-Passwall 组织维护
if ! grep -q 'openwrt-passwall2' feeds.conf.default; then
  echo "src-git passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git;main" >> feeds.conf.default
fi

echo "==> [diy-part1] 添加 OpenAppFilter（应用过滤，含内核模块 kmod-oaf）"
rm -rf package/OpenAppFilter /tmp/OpenAppFilter
git clone --depth 1 https://github.com/destan19/OpenAppFilter.git /tmp/OpenAppFilter
rm -rf /tmp/OpenAppFilter/.git
mv /tmp/OpenAppFilter package/OpenAppFilter

echo "==> [diy-part1] 添加 AccessControl Plus（上网时间控制 Plus）"
rm -rf package/luci-app-accesscontrol-plus /tmp/acp
git clone --depth 1 https://github.com/kingyond/luci-app-accesscontrol-plus.git /tmp/acp
rm -rf /tmp/acp/.git
mv /tmp/acp/luci-app-accesscontrol-plus package/luci-app-accesscontrol-plus
rm -rf /tmp/acp

echo "==> [diy-part1] 添加 AdGuard Home 的 LuCI 面板（kenzok8 维护，适配 24.10+）"
rm -rf package/luci-app-adguardhome /tmp/kz
git clone --depth 1 --filter=blob:none --sparse https://github.com/kenzok8/openwrt-packages.git /tmp/kz
git -C /tmp/kz sparse-checkout set luci-app-adguardhome
mv /tmp/kz/luci-app-adguardhome package/luci-app-adguardhome
rm -rf /tmp/kz
# 24.10 里证书包的实体名是 ca-bundle（ca-certs 只是运行时虚拟名），做一次替换避免依赖解析不到
sed -i 's/+ca-certs/+ca-bundle/g' package/luci-app-adguardhome/Makefile

echo "==> [diy-part1] 检查源码目录"
for d in package/OpenAppFilter/oaf package/OpenAppFilter/open-app-filter \
         package/OpenAppFilter/luci-app-oaf \
         package/luci-app-accesscontrol-plus \
         package/luci-app-adguardhome; do
  if [ -f "$d/Makefile" ]; then
    echo "OK   $d"
  else
    echo "::error::缺少 $d/Makefile，插件源码没有拉取成功"
    exit 1
  fi
done

echo "==> [diy-part1] 当前 feeds.conf.default："
cat feeds.conf.default
