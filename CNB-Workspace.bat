@echo off
rem ==========================================================================
rem  CNB 云原生开发环境 Windows 图形面板启动器
rem
rem  双击即可，不留黑色命令行窗口：交给 mshta（它本身就是窗口程序、没有控制台）
rem  把 PowerShell 以隐藏方式拉起来，然后本窗口立刻退出。这样 PowerShell 的父进程
rem  不是 cmd，关掉面板时也不会把 VSCode / 浏览器一起带走。
rem
rem  关于编码（这是之前乱码的真正原因，三条都对上才不乱码）：
rem    1) 本文件必须存成 GBK(936)。cmd.exe 是按系统 ANSI 代码页逐字节解析 bat 的，
rem       存成 UTF-8 的话中文注释会被拆成乱七八糟的字节。
rem    2) 不能再 chcp 65001。Windows PowerShell 5.1 在 936 的 conhost 下强行切
rem       65001 反而会把中文输出打成乱码 —— 系统默认代码页才是最匹配的。
rem    3) cnb-gui.ps1 是 UTF-8 带 BOM（PowerShell 5.1 只认带 BOM 的 UTF-8，
rem       没有 BOM 就按 GBK 解，所有中文当场变乱码）。这里仍用
rem       [IO.File]::ReadAllText() 读进来再执行，是为了兜底：哪天被编辑器存成
rem       无 BOM 也照样能跑（ReadAllText 默认 UTF-8，且自动识别并剥掉 BOM）。
rem
rem  脚本自身路径经环境变量 CNB_GUI_SELF 传进去：Invoke-Expression 下
rem  $PSCommandPath 是空的，脚本要靠它自己重启自己（STA 检查那一步）。
rem
rem  mshta 被安全软件禁用时，下面的 console 分支是原来的可见方式兜底。
rem ==========================================================================

if /i "%~1"=="--console" goto console

mshta vbscript:createobject("wscript.shell").run("powershell -STA -NoProfile -ExecutionPolicy Bypass -Command ""$env:CNB_GUI_SELF='%~dp0cnb-gui.ps1'; Invoke-Expression ([IO.File]::ReadAllText($env:CNB_GUI_SELF))""",0)(window.close) && exit /b

:console
powershell -STA -NoProfile -ExecutionPolicy Bypass -Command "$env:CNB_GUI_SELF='%~dp0cnb-gui.ps1'; Invoke-Expression ([IO.File]::ReadAllText($env:CNB_GUI_SELF))"
exit /b
