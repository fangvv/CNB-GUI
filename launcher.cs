using System;
using System.IO;
using System.Diagnostics;
using System.Reflection;

// CNB-GUI 单文件启动器
//
// 把 cnb-gui.ps1 作为嵌入资源打包，双击本 exe 时：
//   1) 把嵌入的 ps1 解压成临时文件；
//   2) 设置环境变量 CNB_GUI_SELF 指向那份临时 ps1（这样 ps1 里「STA 重启自己」那一步
//      能找到自己，因为 Invoke-Expression 下 $PSCommandPath 是空的）；
//   3) 隐藏拉起 powershell -STA -NoProfile -ExecutionPolicy Bypass 并 Invoke-Expression 运行；
//   4) 本进程直接退出。刻意不删那份临时文件：ShellExecuteEx 启动 powershell 是异步的，
//      删早了 [IO.File]::ReadAllText 会找不到文件、面板起不来；文件名每次随机，
//      留在 %TEMP% 里只有几十 KB，下次启动也不冲突。
//
// 编译（依赖 Windows 自带 .NET Framework 的 csc.exe，无需安装任何东西）：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe ^
//       /out:CNB-GUI.exe /resource:cnb-gui.ps1 launcher.cs
static class Program {
    [STAThread]
    static int Main() {
        try {
            // 1) 从嵌入资源读出 cnb-gui.ps1，按原始字节写回临时文件（保留其 UTF-8 BOM）
            var asm = Assembly.GetExecutingAssembly();
            string resName = null;
            foreach (var n in asm.GetManifestResourceNames()) {
                if (n.EndsWith("cnb-gui.ps1", StringComparison.OrdinalIgnoreCase)) { resName = n; break; }
            }
            if (resName == null) return 2;

            byte[] bytes;
            using (var rs = asm.GetManifestResourceStream(resName))
            using (var ms = new MemoryStream()) {
                rs.CopyTo(ms);
                bytes = ms.ToArray();
            }

            string ps1 = Path.Combine(Path.GetTempPath(),
                "cnb-gui-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".ps1");
            File.WriteAllBytes(ps1, bytes);

            // 2) 让 ps1 能定位到自己
            Environment.SetEnvironmentVariable("CNB_GUI_SELF", ps1);

            // 3) 隐藏拉起 PowerShell（-STA：面板要求 STA 线程）
            // 必须用 UseShellExecute=true（走 ShellExecuteEx）而不是 CreateNoWindow：
            // 在部分机器上（Win10 1904x 实测），UseShellExecute=false + CreateNoWindow
            // 隐藏启动 powershell.exe 会抛“拒绝访问”，导致 launcher 秒退、面板起不来。
            var psi = new ProcessStartInfo {
                FileName = "powershell.exe",
                Arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
                            "-Command \"Invoke-Expression ([IO.File]::ReadAllText($env:CNB_GUI_SELF))\"",
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            Process.Start(psi);
            return 0;
        } catch {
            return 1;
        }
    }
}
