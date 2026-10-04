using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace TurboMetaReceiver;

static class SelfTests
{
    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "TurboMeta-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var key = RandomNumberGenerator.GetBytes(32);
        var json = Encoding.UTF8.GetBytes("{\"version\":1,\"sessionID\":\"ad67d421-08d9-4f22-aed2-ee0000000009\",\"transcript\":\"[00:00:01] 기술부채 — 검증되지 않은 발언\",\"record\":{}}");
        var nonce = RandomNumberGenerator.GetBytes(12); var cipher = new byte[json.Length]; var tag = new byte[16];
        using (var aes = new AesGcm(key, 16)) aes.Encrypt(nonce, json, cipher, tag);
        var sealedData = nonce.Concat(cipher).Concat(tag).ToArray();
        byte[] Header(byte[] payload) {
            var header = new byte[69]; header[0] = 1;
            BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(1), payload.Length);
            SHA256.HashData(payload).CopyTo(header, 5);
            HMACSHA256.HashData(key, header.AsSpan(0, 37)).CopyTo(header, 37); return header;
        }
        byte[] Chunk(byte[] payload, int offset = 0) {
            var packet = new byte[payload.Length + 5]; packet[0] = 2;
            BinaryPrimitives.WriteInt32LittleEndian(packet.AsSpan(1), offset); payload.CopyTo(packet, 5); return packet;
        }
        var receiver = new BleReceiver(root, key, _ => {});
        receiver.Accept(Header(sealedData)); receiver.Accept(Chunk(sealedData)); receiver.Accept([3]);
        var original = Directory.GetFiles(root, "record.json", SearchOption.AllDirectories).Single();
        if (!File.ReadAllBytes(original).SequenceEqual(json)) throw new Exception("roundtrip");
        receiver.Accept(Header(sealedData)); receiver.Accept([3]);
        if (Directory.GetFiles(root, "record.json", SearchOption.AllDirectories).Length != 1) throw new Exception("duplicate");
        MustReject(() => new BleReceiver(root, RandomNumberGenerator.GetBytes(32), _ => {}).Accept(Header(sealedData)));
        var bad = sealedData.ToArray(); bad[12] ^= 1;
        var damaged = new BleReceiver(root, key, _ => {}); damaged.Accept(Header(bad)); damaged.Accept(Chunk(bad)); MustReject(() => damaged.Accept([3]));
        var ordering = new BleReceiver(root, key, _ => {}); ordering.Accept(Header(sealedData)); MustReject(() => ordering.Accept(Chunk(sealedData, 1)));
        var large = Header(sealedData); BinaryPrimitives.WriteInt32LittleEndian(large.AsSpan(1), int.MaxValue); MustReject(() => ordering.Accept(large));
        MustReject(() => ArchiveImport.Store(root, Encoding.UTF8.GetBytes("{\"version\":2}")));
    }
    static void MustReject(Action action) { try { action(); } catch { return; } throw new Exception("invalid input accepted"); }
}
