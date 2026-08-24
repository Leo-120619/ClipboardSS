using System.Text.Json;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;

namespace ClipboardSS.Core.Tests;

public sealed class WireJsonTests
{
    [Fact]
    public void PayloadSnapshotUsesCanonicalKeyNamesUuidDateAndNullPolicy()
    {
        var payload = new ClipPayload
        {
            Id = Guid.Parse("550E8400-E29B-41D4-A716-446655440000"),
            Type = ClipType.Text,
            CreatedAt = DateTimeOffset.Parse("2023-10-24T12:00:00.987654Z"),
            Text = "hello",
            PreviewText = "hello",
            ContentHash = "abc",
            SourceDeviceName = "Windows",
        };

        Assert.Equal(
            "{\"id\":\"550e8400-e29b-41d4-a716-446655440000\",\"type\":\"text\",\"createdAt\":\"2023-10-24T12:00:00Z\",\"text\":\"hello\",\"previewText\":\"hello\",\"contentHash\":\"abc\",\"sourceDeviceName\":\"Windows\"}",
            JsonSerializer.Serialize(payload, WireJson.Options));
    }

    [Fact]
    public void DecoderAcceptsUppercaseUuidFractionalDateNullAndMissingOptionals()
    {
        const string json = """
            {
              "id": "550E8400-E29B-41D4-A716-446655440000",
              "type": "text",
              "createdAt": "2023-10-24T12:00:00.987Z",
              "text": null,
              "imageBase64": null,
              "previewText": "Empty text",
              "contentHash": "abc",
              "sourceDeviceName": "Phone"
            }
            """;

        var payload = JsonSerializer.Deserialize<ClipPayload>(json, WireJson.Options);

        Assert.NotNull(payload);
        Assert.Equal(Guid.Parse("550e8400-e29b-41d4-a716-446655440000"), payload.Id);
        Assert.Equal(DateTimeOffset.Parse("2023-10-24T12:00:00.987Z"), payload.CreatedAt);
        Assert.Null(payload.Text);
        Assert.Null(payload.ImageExtension);
    }

    [Fact]
    public void EnvelopeSnapshotUsesLowercaseSourceUuidAndVersionKey()
    {
        var envelope = new ClipEnvelope
        {
            SourceDeviceId = Guid.Parse("550E8400-E29B-41D4-A716-446655440000"),
            Nonce = "AA==",
            Ciphertext = "AQ==",
        };

        Assert.Equal(
            "{\"v\":1,\"sourceDeviceId\":\"550e8400-e29b-41d4-a716-446655440000\",\"nonce\":\"AA==\",\"ciphertext\":\"AQ==\"}",
            JsonSerializer.Serialize(envelope, WireJson.Options));
    }
}
