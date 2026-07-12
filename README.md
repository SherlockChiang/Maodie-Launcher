
# 耄耋启动器 (Maodie-Launcher)

## 简介

<table>
  <tr>
    <td width="60%" valign="middle">
      <b>耄耋启动器</b> 是一个基于可爱猫咪耄耋的Magisk/Ksu模块，可以适配Tproxy被狂暴鸿儒后没办法正常运作的HyperOS3系统。
      <br/><br/>
      本文档仍在修订中，欢迎 PR (Pull Requests)。
    </td>
    <td width="40%" valign="middle" align="center">
      <img src="https://github.com/user-attachments/assets/1cca2611-5f32-44ed-87e5-1b27450fc20c" width="100%" alt="image" style="max-width: 250px;" />
    </td>
  </tr>
</table>

## ⚠️ 使用前须知
使用 耄耋启动器 前，请悉知：

上游关系：本 README 主要介绍 耄耋启动器 的独有特性，关于 Mihomo 的通用配置特性，请查看虚空终端Wiki。

兼容性：本模块仅支持 ARM64 设备，基于 Android 10 及以上版本开发，并支持 KernelSU/APatch/Magisk；其他架构会在安装时中止。

## ✨ 独有特性
⚡ 现代网络栈： 抛弃低效的 gVisor，默认启用 system 协议栈配合 auto-route，并自动注入 sysctl 内核参数尽可能跑满带宽。

🔌 KSU 联动： 无需重启手机。在 KernelSU/Magisk 管理器中点击按钮关闭模块，代理即刻停止；点击开启后，服务就会恢复。

🌐 内置 WebUI： 支持集成 MetaCubeXD 面板提高审美，适配ksu面板进行dns模式切换、provider切换。

🤖 可莉不知道哦： 本人不了解任何fq技术，完全由Gemini生成。

## 🛠️ 安装与使用

在 KSU/APatch/Magisk 管理器中直接刷入 release 中的模块。

首次使用只需配置一个订阅地址：在模块 WebUI 中填写 Provider 1，或编辑 `maodie/config/config.yaml`，把 `provider1` 的占位 URL 替换为自己的订阅链接。需要多个 provider 时可自行按相同结构追加，名称和缓存 path 不能重复。

WebUI 访问：

默认地址：http://127.0.0.1:9090/ui

Secret：安装或点击模块 action 时会自动生成并写入 `maodie/config/config.yaml`。action 会通过 MetaCubeXD 的本机 setup 链接完成首次认证；该链接包含 secret，仅应在可信浏览器中打开，不要分享链接或 secret。控制端口只监听 `127.0.0.1`。

## 🚦 特别需知
由于上游issue：https://github.com/MetaCubeX/mihomo/issues/1362

如果您使用的是flyme系统，请直接用box4magisk模块

目前的最新版本没有根据包名的规则所以也可以尝试一下

去广告模块支持：https://github.com/SherlockChiang/Adguard-Home-For-Magisk-Mod 目前处于 beta 阶段，欢迎测试。由于上游变动较大，请谨慎测试；目前本模块已经缝合了去广告模块的部分功能。

物理去广告默认关闭。确认清单内容及不可逆的数据删除风险后，可创建空文件 `maodie/config/adblock.enabled` 并重启模块以启用；删除该文件后服务会停止巡检并按实际变更账本解除 immutable。功能会按 `maodie/config/adblock.list` 清空指定广告路径，请不要把重要 App 数据目录加入该清单。

## 🤝 鸣谢

* **[Mihomo (MetaCubeX)](https://github.com/metacubex/mihomo)**: 强大的上游核心。
* **[MetaCubeXD](https://github.com/metacubex/metacubexd)**: 优秀的 Web 控制面板。
* **[KernelSU](https://github.com/tiann/KernelSU)** / **[Magisk](https://github.com/topjohnwu/Magisk)**: 模块的运行环境支持。
* Maodie: 哎呦喂小白手套呦好胖好可爱。

**如果这个模块对您有帮助，请不要忘记去给上游项目点一个 ⭐ Star！**

最后，如果您喜欢这个模块，也请给我一个star⭐，这对我非常重要！
