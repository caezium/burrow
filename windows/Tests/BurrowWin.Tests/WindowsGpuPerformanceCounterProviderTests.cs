using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class WindowsGpuPerformanceCounterProviderTests
{
    private const string Instance = "pid_123_engtype_3D";

    [Fact]
    public void Capture_RetainsTheBaselineInsteadOfReportingFirstReadZero()
    {
        var counter = new ScriptedCounter(0, 37.5, 0);
        var creations = 0;
        using var provider = new WindowsGpuPerformanceCounterProvider(
            () => [Instance],
            _ => { creations++; return counter; });

        Assert.False(provider.Capture().IsAvailable);
        Assert.Equal(37.5, provider.Capture().UsagePercent);
        Assert.Equal(0, provider.Capture().UsagePercent);
        Assert.Equal(1, creations);
        Assert.False(counter.Disposed);
    }

    [Fact]
    public void Capture_DropsDisappearedInstancesAndPrimesReplacements()
    {
        string[] instances = [Instance];
        var first = new ScriptedCounter(0, 12);
        var replacement = new ScriptedCounter(0, 42);
        var readers = new Queue<ScriptedCounter>([first, replacement]);
        using var provider = new WindowsGpuPerformanceCounterProvider(() => instances, _ => readers.Dequeue());

        Assert.False(provider.Capture().IsAvailable);
        Assert.Equal(12, provider.Capture().UsagePercent);
        instances = [];
        Assert.False(provider.Capture().IsAvailable);
        Assert.True(first.Disposed);
        instances = [Instance];
        Assert.False(provider.Capture().IsAvailable);
        Assert.Equal(42, provider.Capture().UsagePercent);
    }

    [Fact]
    public void Capture_ResetsFailedCountersAndDisposesThemOnShutdown()
    {
        var failed = new ScriptedCounter(0);
        var replacement = new ScriptedCounter(0, 17);
        var readers = new Queue<ScriptedCounter>([failed, replacement]);
        var provider = new WindowsGpuPerformanceCounterProvider(() => [Instance], _ => readers.Dequeue());

        Assert.False(provider.Capture().IsAvailable);
        Assert.False(provider.Capture().IsAvailable); // Empty reader throws InvalidOperationException.
        Assert.True(failed.Disposed);
        Assert.False(provider.Capture().IsAvailable);
        Assert.Equal(17, provider.Capture().UsagePercent);
        provider.Dispose();
        Assert.True(replacement.Disposed);
    }

    private sealed class ScriptedCounter(params double[] values) : IGpuPerformanceCounter
    {
        private readonly Queue<double> _values = new(values);
        public bool Disposed { get; private set; }
        public double NextValue() => _values.Dequeue();
        public void Dispose() => Disposed = true;
    }
}
