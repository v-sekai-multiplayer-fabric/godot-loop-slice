using System.Diagnostics;
using System.IO;
var dir = Path.GetDirectoryName(Environment.ProcessPath)!;
Process.Start(new ProcessStartInfo(
    Path.Combine(dir, "loop-slice.exe"),
    "--headless --script res://server.gd")
{ UseShellExecute = false })?.WaitForExit();
