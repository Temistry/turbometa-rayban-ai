using Windows.Devices.Bluetooth;

namespace TurboMetaReceiver;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        if (args.Contains("--radio-test")) {
            Task.Run(async () => {
                var log = new List<string>();
                var receiver = new BleReceiver(Path.GetTempPath(), System.Security.Cryptography.RandomNumberGenerator.GetBytes(32), text => { lock (log) log.Add(text); });
                try { await receiver.Start(); await Task.Delay(4000); }
                catch (Exception ex) { lock (log) log.Add("ERROR: " + ex.Message); }
                finally { receiver.Stop(); }
                lock (log) File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "radio-test.txt"), log);
            }).GetAwaiter().GetResult();
            return;
        }
        if (args.Contains("--self-test")) {
            SelfTests.Run();
            File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "self-test.txt"), "PASS: encrypted receive, duplicate, wrong key, corruption, ordering, size, version");
            return;
        }
        if (args.Contains("--probe"))
        {
            var adapter = BluetoothAdapter.GetDefaultAsync().AsTask().GetAwaiter().GetResult();
            File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "ble-probe.txt"),
                adapter == null ? "No adapter" : $"LE={adapter.IsLowEnergySupported}; Peripheral={adapter.IsPeripheralRoleSupported}");
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new ReceiverWindow());
    }
}
