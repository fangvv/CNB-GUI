using System;
using System.IO;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;

// CNB-GUI 单文件启动器
//
// 把 cnb-gui.ps1 作为嵌入资源打包，双击本 exe 时：
//   1) 把嵌入的 ps1 解压成临时文件（没有 UTF-8 BOM 就补一个，-File 才不会把中文按 ANSI 读）；
//   2) 设置环境变量 CNB_GUI_SELF 指向那份临时 ps1（保险起见；-File 启动时 $PSCommandPath 也可用）；
//   3) 隐藏拉起 powershell -STA -NoProfile -ExecutionPolicy Bypass -File <临时 ps1>；
//   4) 本进程直接退出。刻意不删那份临时文件：ShellExecuteEx 启动 powershell 是异步的，
//      删早了会找不到文件、面板起不来；文件名每次随机，留在 %TEMP% 里只有几十 KB，下次启动也不冲突。
//
// 为什么用 -File 而不是 -Command "Invoke-Expression (...)"：
//   「隐藏窗口 + Bypass + IEX 读文件执行」这组特征会被部分安全软件/策略直接拦截，
//   Process.Start 抛 Win32Exception「拒绝访问」，面板完全起不来。
//   实测改成同样隐藏、同样 Bypass，只是换成 -File，就能正常启动。
//
// 编译（依赖 Windows 自带 .NET Framework 的 csc.exe，无需安装任何东西）：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe ^
//       /out:CNB-GUI.exe /resource:cnb-gui.ps1 launcher.cs
static class Program {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    static void ShowError(string message) {
        // 启动失败时给一个可见提示：winexe 没有控制台，静默退出会让用户只看到「没反应」
        try { MessageBoxW(IntPtr.Zero, message, "CNB 开发环境", 0x00000010); } catch { }
    }

    [STAThread]
    static int Main() {
        try {
            // 1) 从嵌入资源读出 cnb-gui.ps1，按原始字节写回临时文件
            var asm = Assembly.GetExecutingAssembly();
            string resName = null;
            foreach (var n in asm.GetManifestResourceNames()) {
                if (n.EndsWith("cnb-gui.ps1", StringComparison.OrdinalIgnoreCase)) { resName = n; break; }
            }
            if (resName == null) { ShowError("启动失败：EXE 里没有找到 cnb-gui.ps1 资源。请重新运行 build-exe.bat 打包。"); return 2; }

            byte[] bytes;
            using (var rs = asm.GetManifestResourceStream(resName))
            using (var ms = new MemoryStream()) {
                rs.CopyTo(ms);
                bytes = ms.ToArray();
            }

            // -File 对没有 BOM 的脚本会按系统 ANSI 解析，中文会乱码；这里统一补一个 BOM
            if (bytes.Length < 3 || bytes[0] != 0xEF || bytes[1] != 0xBB || bytes[2] != 0xBF) {
                var bom = new byte[] { 0xEF, 0xBB, 0xBF };
                var withBom = new byte[bom.Length + bytes.Length];
                Buffer.BlockCopy(bom, 0, withBom, 0, bom.Length);
                Buffer.BlockCopy(bytes, 0, withBom, bom.Length, bytes.Length);
                bytes = withBom;
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
                Arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"",
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            Process.Start(psi);
            return 0;
        } catch (Exception ex) {
            ShowError("启动失败：" + ex.Message + "\r\n\r\n可改用 CNB-Workspace.bat 启动；若仍然失败，请检查安全软件或系统策略是否拦截了本程序。");
            return 1;
        }
    }
}
