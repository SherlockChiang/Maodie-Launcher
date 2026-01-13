# 耄耋启动器 (Maodie-Launcher)
## 简介

<img width="250" height="242" align="right" alt="image" src="https://github.com/user-attachments/assets/1cca2611-5f32-44ed-87e5-1b27450fc20c" />

**耄耋启动器** 是一个基于可爱猫咪耄耋的Magisk/Ksu模块，可以适配Tproxy被狂暴鸿儒后没办法正常运作的HyperOS3系统。

本文档仍在修订中，欢迎 PR (Pull Requests)。
## ⚠️ 使用前须知
使用 耄耋启动器 前，请悉知：

上游关系：本 README 主要介绍 耄耋启动器 的独有特性（如系统栈调优、防杀机制），关于 Mihomo 的通用配置特性，请查看虚空终端。

兼容性：本模块基于最新的 Android 特性开发（支持 KernelSU/APatch），如果您的系统低于 Android 10，建议升级以获得最佳体验。

## ✨ 独有特性 (Features)
⚡ 现代网络栈 (System Stack)： 抛弃低效的 gVisor，默认启用 system 协议栈配合 auto-route，并自动注入 sysctl 内核参数尽可能跑满带宽。

🔌 KSU 联动： 无需重启手机。在 KernelSU/Magisk 管理器中点击按钮关闭模块，代理即刻停止；点击开启后，服务就会恢复。

🌐 内置 WebUI： 支持集成 MetaCubeXD 面板提高审美。

🤖 可莉不知道哦： 本人不了解任何fq技术，完全由Gemini生成。

## 🛠️ 安装与使用

在Ksu管理器中直接刷入release中的模块

准备好您的 config.yaml 并正确填写您自己的订阅链接

WebUI 访问：

默认地址：http://127.0.0.1:9090/ui

Secret：默认为空（建议在 config 中修改）。

## 🤝 鸣谢
Mihomo : 强大的上游核心。

MetaCubeXD: 优秀的 Web 控制面板。

Maodie: 哎呦喂小白手套呦好胖好可爱。
