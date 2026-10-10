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
//   4) 等面板退出后删除临时文件，本进程退出。
//
// 编译（依赖 Windows 自带 .NET Framework 的 csc.exe，无需安装任何东西）：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe ^
//       /out:CNB-GUI.exe /resource:cnb-gui.ps1 launcher.cs
static class Program {
    [STAThread]
    static int Main() {
        string ps1 = null;
        Process proc = null;
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

            ps1 = Path.Combine(Path.GetTempPath(),
                "cnb-gui-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".ps1");
            File.WriteAllBytes(ps1, bytes);

            // 2) 让 ps1 能定位到自己
            Environment.SetEnvironmentVariable("CNB_GUI_SELF", ps1);

            // 3) 隐藏拉起 PowerShell（-STA：面板要求 STA 线程）
            var psi = new ProcessStartInfo {
                FileName = "powershell.exe",
                Arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
                            "-Command \"Invoke-Expression ([IO.File]::ReadAllText($env:CNB_GUI_SELF))\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            proc = Process.Start(psi);

            // 4) 等面板退出后再清理临时文件（面板是常驻托盘进程，本进程一直隐藏等待）
            if (proc != null) proc.WaitForExit();
            return 0;
        } catch {
            return 1;
        } finally {
            try { if (ps1 != null && File.Exists(ps1)) File.Delete(ps1); } catch { }
        }
    }
}
