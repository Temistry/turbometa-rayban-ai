using System.Security.Cryptography;

namespace TurboMetaReceiver;

sealed class ReceiverWindow : Form
{
    readonly TextBox vault = new() { Text = @"C:\data\myObsidian", Width = 540 };
    readonly TextBox key = new() { Width = 540, ReadOnly = true, UseSystemPasswordChar = true };
    readonly Label status = new() { AutoSize = true, MaximumSize = new Size(550, 0), Text = "수신 대기 전 · 키를 아이폰에 입력하세요." };
    readonly Button start = new() { Text = "수신 시작", AutoSize = true };
    readonly Button stop = new() { Text = "수신 중지", AutoSize = true, Enabled = false };
    BleReceiver? receiver;
    readonly byte[] secret;

    public ReceiverWindow()
    {
        Text = "TurboMeta · Obsidian BLE 수신기"; Width = 620; Height = 400;
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TurboMetaReceiver");
        Directory.CreateDirectory(root);
        var keyPath = Path.Combine(root, "receiver-key.dpapi");
        if (File.Exists(keyPath)) secret = ProtectedData.Unprotect(File.ReadAllBytes(keyPath), null, DataProtectionScope.CurrentUser);
        else {
            secret = RandomNumberGenerator.GetBytes(32);
            File.WriteAllBytes(keyPath, ProtectedData.Protect(secret, null, DataProtectionScope.CurrentUser));
        }
        key.Text = Convert.ToHexString(secret);
        var reveal = new CheckBox { Text = "연결 키 표시 (신뢰하는 아이폰에만 입력)", AutoSize = true };
        reveal.CheckedChanged += (_, _) => key.UseSystemPasswordChar = !reveal.Checked;
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(18), WrapContents = false };
        panel.Controls.AddRange([new Label { Text = "Obsidian 저장소", AutoSize = true }, vault,
            new Label { Text = "연결 키 · 인터넷 전송 없음", AutoSize = true }, key, reveal, start, stop, status]);
        Controls.Add(panel);
        start.Click += async (_, _) => {
            start.Enabled = false;
            try {
                if (!Directory.Exists(vault.Text)) throw new IOException("저장소 폴더가 없습니다.");
                receiver = new BleReceiver(vault.Text, secret, message => BeginInvoke((Action)(() => status.Text = message)));
                await receiver.Start();
                vault.Enabled = false; stop.Enabled = true;
            } catch (Exception ex) { receiver?.Stop(); receiver = null; start.Enabled = true; status.Text = "시작 실패: " + ex.Message; }
        };
        stop.Click += (_, _) => StopReceiver();
        FormClosing += (_, _) => StopReceiver();
    }
    void StopReceiver() { receiver?.Stop(); receiver = null; start.Enabled = true; stop.Enabled = false; vault.Enabled = true; status.Text = "수신 중지됨"; }
}
