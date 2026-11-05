using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("DriveRelay")]
[assembly: AssemblyDescription("DriveRelay")]
[assembly: AssemblyProduct("DriveRelay")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class DriveRelayLauncher
{
    [STAThread]
    private static int Main()
    {
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, "DriveRelayTray.ps1");
            if (!File.Exists(script))
                throw new FileNotFoundException("DriveRelayTray.ps1 is missing. Extract the whole DriveRelay folder before starting it.", script);

            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo start = new ProcessStartInfo(powershell);
            start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"";
            start.WorkingDirectory = root;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            using (Process process = Process.Start(start)) { }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "DriveRelay could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
