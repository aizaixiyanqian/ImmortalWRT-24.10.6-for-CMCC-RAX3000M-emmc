#!/bin/bash
# diy-part2.sh
# 作用：feeds 安装完成之后、`make defconfig` 之前执行，对 .config 做最后调整。
# 工作目录：openwrt/（此时 .config 与 files/ 已经就位）
set -euo pipefail

echo "==> [diy-part2] 统一去掉 Windows 换行符"
sed -i 's/\r$//' .config || true
find files -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true

echo "==> [diy-part2] 用 dnsmasq-full 替换默认 dnsmasq（PassWall2 / SmartDNS / AdGuardHome 都需要）"
sed -i '/^CONFIG_PACKAGE_dnsmasq[= ]/d' .config || true
grep -q '^# CONFIG_PACKAGE_dnsmasq is not set$' .config || \
  echo '# CONFIG_PACKAGE_dnsmasq is not set' >> .config
grep -q '^CONFIG_PACKAGE_dnsmasq-full=y$' .config || \
  echo 'CONFIG_PACKAGE_dnsmasq-full=y' >> .config
grep -q '^CONFIG_PACKAGE_dnsmasq_full_nftset=y$' .config || \
  echo 'CONFIG_PACKAGE_dnsmasq_full_nftset=y' >> .config

echo "==> [diy-part2] 关闭不使用的 PassWall2 可选依赖，减少体积和编译风险"
for opt in INCLUDE_Haproxy INCLUDE_ShadowsocksR_Libev_Client \
           INCLUDE_ShadowsocksR_Libev_Server INCLUDE_V2ray_Plugin; do
  sed -i "/CONFIG_PACKAGE_luci-app-passwall2_${opt}/d" .config || true
  echo "# CONFIG_PACKAGE_luci-app-passwall2_${opt} is not set" >> .config
done

echo "==> [diy-part2] make defconfig（展开为完整配置）"
make defconfig

echo "==> [diy-part2] 完成"
