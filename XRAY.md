# 固件内置 Xray 说明

本仓库编译的固件会**内置 Xray-core 26.11.9**（官方 arm64 二进制），
用于修复 ImmortalWrt 24.10 自带的 25.2.21 无法解析 PassWall2 26.x 新配置
（`unknown config id: tunnel`）的问题。

## 实现方式

工作流 `.github/workflows/build-immortalwrt.yml` 中新增步骤 **Bake Xray 26.11.9 into image**：

1. 从官方 Release 下载 `Xray-linux-arm64-v8a.zip`：
   `https://github.com/XTLS/Xray-core/releases/download/v26.11.9/Xray-linux-arm64-v8a.zip`
2. 解压后放到 `openwrt/files/usr/bin/xray`；
3. 镜像打包时 `files/` 最后覆盖根文件系统，因此最终固件里的 `/usr/bin/xray` 就是 26.11.9。

> 源码源里仍然会编译 `xray-core 25.2.21` 包（PassWall2 的依赖需要它），
> 但它的 `/usr/bin/xray` 会被 `files/` 覆盖，不会真正生效。
> `opkg` 里的版本号仍显示 25.2.21，这是正常现象。

## 验证

刷机后 SSH 执行：

```sh
xray version
# 期望输出包含 Xray 26.11.9
```

如果显示 25.2.21，说明 `files/usr/bin/xray` 没生效，检查 Action 日志里
**Bake Xray 26.11.9 into image** 步骤是否成功。

## 升级/降级 Xray

修改 `build-immortalwrt.yml` 里 `XRAY_VER="26.11.9"` 后重新跑 Action 即可。
若想回到源码源版本，删除该步骤后重跑。
