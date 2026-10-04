using Windows.Devices.Bluetooth;

namespace TurboMetaReceiver;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
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
