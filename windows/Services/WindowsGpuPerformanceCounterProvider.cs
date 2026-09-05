using System.ComponentModel;
using System.Diagnostics;
using System.Security;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class WindowsGpuPerformanceCounterProvider : IGpuTelemetryProvider, IDisposable
{
    private const string CategoryName = "GPU Engine";
    private const string CounterName = "Utilization Percentage";
    private readonly Func<IEnumerable<string>> _instanceNames;
    private readonly Func<string, IGpuPerformanceCounter> _createCounter;
    private readonly Dictionary<string, IGpuPerformanceCounter> _counters = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _sync = new();

    public WindowsGpuPerformanceCounterProvider()
        : this(
            ReadInstanceNames,
            name => new GpuPerformanceCounter(name))
    {
    }

    internal WindowsGpuPerformanceCounterProvider(
        Func<IEnumerable<string>> instanceNames,
        Func<string, IGpuPerformanceCounter> createCounter)
    {
        _instanceNames = instanceNames;
        _createCounter = createCounter;
    }

    public GpuTelemetrySample Capture()
    {
        lock (_sync)
        {
            return CaptureLocked();
        }
    }

    private GpuTelemetrySample CaptureLocked()
    {
        try
        {
            var instanceNames = _instanceNames()
                .Where(name => name.Contains("engtype_3D", StringComparison.OrdinalIgnoreCase))
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            foreach (var disappeared in _counters.Keys.Where(name => !instanceNames.Contains(name)).ToArray())
            {
                RemoveCounter(disappeared);
            }

            if (instanceNames.Count == 0)
            {
                return GpuTelemetrySample.Unavailable("No 3D GPU performance-counter instances are available.");
            }

            double total = 0;
            var successfulReads = 0;
            var warmingUp = false;
            foreach (var instanceName in instanceNames)
            {
                try
                {
                    if (!_counters.TryGetValue(instanceName, out var counter))
                    {
                        counter = _createCounter(instanceName);
                        _counters.Add(instanceName, counter);
                        // Utilization is an interval counter. Its first NextValue is only
                        // a baseline (0.0), so retain the reader for the next capture and
                        // never publish that initial value as measured idle usage.
                        counter.NextValue();
                        warmingUp = true;
                        continue;
                    }

                    total += counter.NextValue();
                    successfulReads++;
                }
                catch (Exception ex) when (IsExpectedCounterFailure(ex))
                {
                    // GPU engine instances can disappear while the category is enumerated.
                    RemoveCounter(instanceName);
                }
            }

            return successfulReads == 0
                ? GpuTelemetrySample.Unavailable(warmingUp
                    ? "GPU performance counters are waiting for a second sample."
                    : "GPU performance-counter instances could not be read.")
                : GpuTelemetrySample.Available(total);
        }
        catch (Exception ex) when (IsExpectedCounterFailure(ex))
        {
            ClearCounters();
            return GpuTelemetrySample.Unavailable($"GPU performance counters are inaccessible ({ex.GetType().Name}).");
        }
    }

    public void Dispose()
    {
        lock (_sync)
        {
            ClearCounters();
        }
    }

    private void ClearCounters()
    {
        foreach (var name in _counters.Keys.ToArray())
        {
            RemoveCounter(name);
        }
    }

    private void RemoveCounter(string name)
    {
        if (_counters.Remove(name, out var counter))
        {
            counter.Dispose();
        }
    }

    private static IEnumerable<string> ReadInstanceNames()
    {
        return PerformanceCounterCategory.Exists(CategoryName)
            ? new PerformanceCounterCategory(CategoryName).GetInstanceNames()
            : Array.Empty<string>();
    }

    private sealed class GpuPerformanceCounter(string instanceName) : IGpuPerformanceCounter
    {
        private readonly PerformanceCounter _counter = new(CategoryName, CounterName, instanceName, readOnly: true);

        public double NextValue() => _counter.NextValue();

        public void Dispose() => _counter.Dispose();
    }

    private static bool IsExpectedCounterFailure(Exception exception)
    {
        return exception is Win32Exception or
            InvalidOperationException or
            UnauthorizedAccessException or
            PlatformNotSupportedException or
            SecurityException;
    }
}

internal interface IGpuPerformanceCounter : IDisposable
{
    double NextValue();
}
