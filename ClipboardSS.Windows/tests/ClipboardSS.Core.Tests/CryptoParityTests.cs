using System.Text;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Models;

namespace ClipboardSS.Core.Tests;

public sealed class CryptoParityTests
{
    [Fact]
    public async Task FileTransferVectorsMatchWireProtocol()
    {
        await using var stream = new MemoryStream([1, 2, 3]);
        Assert.Equal("53d35d037113cb046848c134d774023f716d41879185bb35b942a0472bcd70fe",
            await ContentHasher.FileHashAsync(stream, TestContext.Current.CancellationToken));
        var pairKey = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var key = FileTransferCrypto.DeriveFileKey(pairKey, "6f9619ff-8b86-d011-b42d-00c04fc964ff");
        Assert.Equal("2b3f780b885ee8149fe062a00b2bb4ecc9b4326c058ad858b23009f3397a4554", Convert.ToHexString(key).ToLowerInvariant());
        Assert.Equal("878b3fd3c6494ba0be8976ec7543362243af08", Convert.ToHexString(FileTransferCrypto.SealChunk(key, 0, [1, 2, 3])).ToLowerInvariant());
        Assert.Equal("fc5bf0de6da51d44d7e16d35ec05ed598dd1cf", Convert.ToHexString(FileTransferCrypto.SealChunk(key, 1, [1, 2, 3])).ToLowerInvariant());
        Assert.ThrowsAny<Exception>(() => FileTransferCrypto.OpenChunk(key, 1, FileTransferCrypto.SealChunk(key, 0, [1, 2, 3])));
        var wrongKey = key.ToArray(); wrongKey[0] ^= 1;
        Assert.ThrowsAny<Exception>(() => FileTransferCrypto.OpenChunk(wrongKey, 0, FileTransferCrypto.SealChunk(key, 0, [1, 2, 3])));
    }
    [Fact]
    public void ContentHasherMatchesWireProtocolVectors()
    {
        Assert.Equal(
            "f2860ecbb844a4c152aed2007055a3d41911dcb0fb7a64b996525d5b62a722e1",
            ContentHasher.TextHash("Hello, world!"));
        Assert.Equal(
            "1b91e2105a1a014f55e1038235f53eae70458235d3f37da8672b563a21c04929",
            ContentHasher.ImageHash([1, 2, 3]));
    }

    [Fact]
    public void HkdfSha256MatchesRfc5869TestCaseOne()
    {
        var output = HkdfSha256.Derive(
            Enumerable.Repeat((byte)0x0b, 22).ToArray(),
            Convert.FromHexString("000102030405060708090a0b0c"),
            Convert.FromHexString("f0f1f2f3f4f5f6f7f8f9"),
            42);

        Assert.Equal(
            "3cb25f25faacd57a90434f64d0362f2a" +
            "2d2d0a90cf1a5a4c5db02d56ecc4c5bf" +
            "34007208d5b887185865",
            Hex(output));
    }

    [Fact]
    public void X25519MatchesRfc7748AliceBobVector()
    {
        var alice = PairingSession.FromPrivateKey(Convert.FromHexString(
            "77076d0a7318a57d3c16c17251b26645" +
            "df4c2f87ebc0992ab177fba51db92c2a"));
        var bob = PairingSession.FromPrivateKey(Convert.FromHexString(
            "5dab087e624a8a4b79e17f8b83800ee6" +
            "6f3bb1292618b6fd1c2f8b27ff88e0eb"));

        Assert.Equal(
            "8520f0098930a754748b7ddcb43ef75a" +
            "0dbf3a0d26381af4eba4a98eaa9b4e6a",
            Hex(alice.EphemeralPublicKey));
        Assert.Equal(
            "de9edb7d7b7dc1b4d35b61c2ece43537" +
            "3f8343c85b78674dadfc7e146f882b4f",
            Hex(bob.EphemeralPublicKey));
        Assert.Equal(
            "4a5d9d5ba4ce2de1728e3bf480350f25" +
            "e07e21c947d19e3376f09b3c1e161742",
            Hex(alice.DeriveSharedSecret(bob.EphemeralPublicKey)));

        var aliceResult = alice.CompletePairing(
            bob.EphemeralPublicKey,
            Guid.NewGuid(),
            Guid.NewGuid(),
            true,
            "123456");
        var bobResult = bob.CompletePairing(
            alice.EphemeralPublicKey,
            Guid.NewGuid(),
            Guid.NewGuid(),
            false,
            "123456");

        Assert.Equal(aliceResult.PairKey, bobResult.PairKey);
        Assert.Equal(aliceResult.ConfirmCode, bobResult.ConfirmCode);
    }

    [Fact]
    public void ChaCha20Poly1305MatchesRfc8439AeadVector()
    {
        var key = Convert.FromHexString(
            "808182838485868788898a8b8c8d8e8f" +
            "909192939495969798999a9b9c9d9e9f");
        var nonce = Convert.FromHexString("070000004041424344454647");
        var associatedData = Convert.FromHexString("50515253c0c1c2c3c4c5c6c7");
        var plaintext = Convert.FromHexString(
            "4c616469657320616e642047656e746c" +
            "656d656e206f662074686520636c6173" +
            "73206f66202739393a20496620492063" +
            "6f756c64206f6666657220796f75206f" +
            "6e6c79206f6e652074697020666f7220" +
            "746865206675747572652c2073756e73" +
            "637265656e20776f756c642062652069" +
            "742e");

        var encrypted = ChaCha20Poly1305Cipher.Encrypt(key, nonce, plaintext, associatedData);

        Assert.Equal(
            "d31a8d34648e60db7b86afbc53ef7ec2" +
            "a4aded51296e08fea9e2b5a736ee62d6" +
            "3dbea45e8ca9671282fafb69da92728b" +
            "1a71de0a9e060b2905d6a5b67ecd3b36" +
            "92ddbd7f2d778b8c9803aee328091b58" +
            "fab324e4fad675945585808b4831d7bc" +
            "3ff4def08e4b7a9de576d26586cec64b" +
            "61161ae10b594f09e26a7e902ecbd0600691",
            Hex(encrypted));
        Assert.Equal(plaintext, ChaCha20Poly1305Cipher.Decrypt(key, nonce, encrypted, associatedData));
    }

    [Fact]
    public void PairingIsSymmetricAndBoundToCode()
    {
        var initiator = new PairingSession();
        var target = new PairingSession();
        var initiatorId = Guid.Parse("550E8400-E29B-41D4-A716-446655440000");
        var targetId = Guid.Parse("4D967C79-47DC-4E1F-A3BD-D3160B082DA7");

        var left = initiator.CompletePairing(
            target.EphemeralPublicKey, initiatorId, targetId, true, "123456");
        var right = target.CompletePairing(
            initiator.EphemeralPublicKey, initiatorId, targetId, false, "123456");
        var wrong = initiator.CompletePairing(
            target.EphemeralPublicKey, initiatorId, targetId, true, "654321");

        Assert.Equal(left.PairKey, right.PairKey);
        Assert.Equal(left.ConfirmCode, right.ConfirmCode);
        Assert.Equal(6, left.ConfirmCode.Length);
        Assert.NotEqual(left.PairKey, wrong.PairKey);
        Assert.NotEqual(left.ConfirmCode, wrong.ConfirmCode);
    }

    [Fact]
    public void ConfirmationProofMatchesPinnedLowercaseUuidVector()
    {
        var proof = PairingSession.GenerateConfirmationProof(
            Enumerable.Repeat((byte)0x2a, 32).ToArray(),
            Guid.Parse("550E8400-E29B-41D4-A716-446655440000"),
            Guid.Parse("4D967C79-47DC-4E1F-A3BD-D3160B082DA7"));

        Assert.Equal(
            "59b84a953852c81f998d8c4a29b0a4a05afe4464f1693a0c91c753441f2a11e8",
            Hex(proof));
    }

    [Fact]
    public void EnvelopeRoundTripsAndRejectsWrongKey()
    {
        var payload = new ClipPayload
        {
            Id = Guid.NewGuid(),
            Type = ClipType.Text,
            CreatedAt = DateTimeOffset.FromUnixTimeSeconds(1_698_148_800),
            Text = "secret message",
            PreviewText = "secret",
            ContentHash = "hash123",
            SourceDeviceName = "Mac",
        };
        var key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        var envelope = EnvelopeCrypto.Seal(payload, Guid.NewGuid(), key);

        Assert.Equal(payload, EnvelopeCrypto.Open(envelope, key));
        Assert.Throws<EnvelopeCryptoException>(() =>
            EnvelopeCrypto.Open(envelope, Enumerable.Repeat((byte)42, 32).ToArray()));
    }

    private static string Hex(ReadOnlySpan<byte> data) => Convert.ToHexString(data).ToLowerInvariant();
}
