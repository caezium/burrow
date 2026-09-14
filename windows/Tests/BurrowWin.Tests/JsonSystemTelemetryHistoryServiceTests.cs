using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class JsonSystemTelemetryHistoryServiceTests : IDisposable
{
    private readonly string _tempRoot = Path.Combine(Path.GetTempPath(), "BurrowWinTests", Guid.NewGuid().ToString("N"));
    private readonly string _historyPath;
    // Keep every fixture recent, including the 100-minute concurrency sequence.
    private readonly DateTimeOffset _snapshotBase = DateTimeOffset.UtcNow.AddHours(-2);

    public JsonSystemTelemetryHistoryServiceTests()
    {
        Directory.CreateDirectory(_tempRoot);
        _historyPath = Path.Combine(_tempRoot, "telemetry-history.jsonl");
    }

    [Fact]
    public async Task RecordAsync_AppendsTelemetrySnapshot()
    {
        var service = new JsonSystemTelemetryHistoryService(_historyPath);

        await service.RecordAsync(CreateSnapshot(1));

        var snapshots = await service.ReadRecentAsync(10);

        var snapshot = Assert.Single(snapshots);
        Assert.Equal(12.5, snapshot.CpuUsagePercent);
        Assert.Equal("GPU pending", snapshot.GpuStatus);
        Assert.Single(snapshot.TopProcesses);
    }

    [Fact]
    public async Task ReadRecentAsync_ReturnsNewestFirst_AndSkipsInvalidLines()
    {
        var service = new JsonSystemTelemetryHistoryService(_historyPath);

        await service.RecordAsync(CreateSnapshot(1));
        await File.AppendAllTextAsync(_historyPath, "not json" + Environment.NewLine);
        await service.RecordAsync(CreateSnapshot(2));
        await service.RecordAsync(CreateSnapshot(3));

        var snapshots = await service.ReadRecentAsync(2);

        Assert.Collection(
            snapshots,
            snapshot => Assert.Equal(_snapshotBase.AddMinutes(3), snapshot.CapturedAt),
            snapshot => Assert.Equal(_snapshotBase.AddMinutes(2), snapshot.CapturedAt));
    }

    [Fact]
    public async Task RecordAsync_AndReadRecentAsync_DoNotThrowUnderConcurrency()
    {
        var service = new JsonSystemTelemetryHistoryService(_historyPath);
        await service.RecordAsync(CreateSnapshot(0));

        var writer = Task.Run(async () =>
        {
            for (var offset = 1; offset <= 100; offset++)
            {
                await service.RecordAsync(CreateSnapshot(offset));
            }
        });
        var reader = Task.Run(async () =>
        {
            for (var iteration = 0; iteration < 100; iteration++)
            {
                await service.ReadRecentAsync(10);
            }
        });

        await Task.WhenAll(writer, reader);

        var snapshots = await service.ReadRecentAsync(101);
        Assert.Equal(101, snapshots.Count);
    }

    [Fact]
    public async Task RecordAsync_PrunesExpiredSnapshots_AndKeepsRecentSnapshots()
    {
        var service = new JsonSystemTelemetryHistoryService(_historyPath, () => 1);
        var recent = CreateSnapshot(0);
        var expired = recent with { CapturedAt = _snapshotBase.AddDays(-2) };

        await service.RecordAsync(recent);
        await service.RecordAsync(expired);

        var snapshots = await service.ReadRecentAsync(10);
        var snapshot = Assert.Single(snapshots);
        Assert.Equal(recent.CapturedAt, snapshot.CapturedAt);
        Assert.Single(await File.ReadAllLinesAsync(_historyPath));
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempRoot))
        {
            Directory.Delete(_tempRoot, recursive: true);
        }
    }

    private SystemTelemetrySnapshot CreateSnapshot(int offset)
    {
        return new SystemTelemetrySnapshot(
            _snapshotBase.AddMinutes(offset),
            12.5,
            50,
            4,
            8,
            75,
            3,
            4,
            100,
            50,
            "GPU pending",
            [new ProcessTelemetry("demo", 123, 4096)]);
    }
}
