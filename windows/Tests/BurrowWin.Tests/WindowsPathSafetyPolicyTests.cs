using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class WindowsPathSafetyPolicyTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "BurrowPathSafety", Guid.NewGuid().ToString("N"));
    private readonly FakeWindowsFileSystemInspector _fileSystem = new();

    public WindowsPathSafetyPolicyTests()
    {
        Directory.CreateDirectory(_root);
        _fileSystem.Set(_root, DeletionItemType.Directory);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("relative\\file.txt")]
    public void Validate_RejectsEmptyAndRelativePaths(string? path)
    {
        var result = Policy().Validate(path!, _root);

        Assert.False(result.IsSafe);
    }

    [Fact]
    public void Validate_RejectsDriveRoot()
    {
        var driveRoot = Path.GetPathRoot(_root)!;

        var result = Policy().Validate(driveRoot, _root);

        Assert.False(result.IsSafe);
        Assert.Equal("drive_root", result.ReasonCode);
    }

    [Fact]
    public void Validate_RejectsUncShareRoot()
    {
        var result = Policy().Validate(@"\\server\share\", @"\\server\share\approved");

        Assert.False(result.IsSafe);
        Assert.Contains(result.ReasonCode, new[] { "unc_path", "unsafe_scope_root" });
    }

    [Theory]
    [InlineData(@"\\?\C:\safe\file.txt")]
    [InlineData(@"\\.\C:\safe\file.txt")]
    [InlineData(@"\??\C:\safe\file.txt")]
    [InlineData(@"\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Windows")]
    public void Validate_RejectsDeviceAndNtPaths(string path)
    {
        var result = Policy().Validate(path, _root);

        Assert.False(result.IsSafe);
        Assert.Equal("device_path", result.ReasonCode);
    }

    [Fact]
    public void Validate_RejectsRawTraversalWithMixedSeparators()
    {
        var path = _root + @"\safe/../outside.txt";

        var result = Policy().Validate(path, _root);

        Assert.False(result.IsSafe);
        Assert.Equal("traversal", result.ReasonCode);
    }

    [Fact]
    public void Validate_RejectsRawDotSegment()
    {
        var result = Policy().Validate(_root + @"\.\file.txt", _root);

        Assert.False(result.IsSafe);
        Assert.Equal("traversal", result.ReasonCode);
    }

    [Fact]
    public void Validate_RejectsAlternateDataStream()
    {
        var result = Policy().Validate(Path.Combine(_root, "file.txt") + ":stream", _root);

        Assert.False(result.IsSafe);
        Assert.Equal("alternate_data_stream", result.ReasonCode);
    }

    [Fact]
    public void Validate_RejectsEnvironmentVariableExpressions()
    {
        var result = Policy().Validate(@"%TEMP%\artifact.bin", _root);

        Assert.False(result.IsSafe);
        Assert.Equal("environment_path", result.ReasonCode);
    }

    [Fact]
    public void Validate_RejectsConfiguredScopeRootItself()
    {
        var result = Policy().Validate(_root, _root);

        Assert.False(result.IsSafe);
        Assert.Equal("scope_root", result.ReasonCode);
    }

    [Fact]
    public void ValidateScopeRoot_RejectsMissingOrNonDirectoryScope()
    {
        var missing = Path.Combine(_root, "missing");
        var file = Path.Combine(_root, "scope.txt");
        _fileSystem.Set(file, DeletionItemType.File, sizeBytes: 1);

        Assert.Equal("invalid_scope", Policy().ValidateScopeRoot(missing).ReasonCode);
        Assert.Equal("invalid_scope", Policy().ValidateScopeRoot(file).ReasonCode);
    }

    [Fact]
    public void Validate_RejectsPathOutsideApprovedRoot()
    {
        var outside = Path.Combine(Path.GetDirectoryName(_root)!, "outside", "file.txt");

        var result = Policy().Validate(outside, _root);

        Assert.False(result.IsSafe);
        Assert.Equal("outside_scope", result.ReasonCode);
    }

    [Fact]
    public void Validate_UsesCaseInsensitiveWindowsScopeComparison()
    {
        var target = Path.Combine(_root, "Child", "file.txt");
        _fileSystem.Set(target, DeletionItemType.File, sizeBytes: 1);

        var result = Policy().Validate(target.ToUpperInvariant(), _root.ToLowerInvariant());

        Assert.True(result.IsSafe, result.Message);
    }

    [Fact]
    public void Validate_RejectsReparsePointInParentSegment()
    {
        var junction = Path.Combine(_root, "junction");
        var target = Path.Combine(junction, "file.txt");
        _fileSystem.Set(junction, DeletionItemType.Directory, FileAttributes.ReparsePoint);
        _fileSystem.Set(target, DeletionItemType.File, sizeBytes: 1);

        var result = Policy().Validate(target, _root);

        Assert.False(result.IsSafe);
        Assert.Equal("reparse_point", result.ReasonCode);
    }

    [Fact]
    public void ValidateScopeRoot_RejectsReparsePointAboveApprovedScope()
    {
        var junction = Path.Combine(_root, "junction");
        var scope = Path.Combine(junction, "Downloads");
        _fileSystem.Set(junction, DeletionItemType.Directory, FileAttributes.ReparsePoint);
        _fileSystem.Set(scope, DeletionItemType.Directory);

        var result = Policy().ValidateScopeRoot(scope);

        Assert.False(result.IsSafe);
        Assert.Equal("reparse_scope", result.ReasonCode);
    }

    [Fact]
    public void Validate_RejectsReparsePointAboveApprovedScope()
    {
        var junction = Path.Combine(_root, "junction");
        var scope = Path.Combine(junction, "Downloads");
        var target = Path.Combine(scope, "old-installer.exe");
        _fileSystem.Set(junction, DeletionItemType.Directory, FileAttributes.ReparsePoint);
        _fileSystem.Set(scope, DeletionItemType.Directory);
        _fileSystem.Set(target, DeletionItemType.File, sizeBytes: 10);

        var result = Policy().Validate(target, scope);

        Assert.False(result.IsSafe);
        Assert.Equal("reparse_point", result.ReasonCode);
    }

    [Fact]
    public void Validate_RejectsReparseTarget()
    {
        var target = Path.Combine(_root, "linked.txt");
        _fileSystem.Set(target, DeletionItemType.File, FileAttributes.ReparsePoint, 1);

        var result = Policy().Validate(target, _root);

        Assert.False(result.IsSafe);
        Assert.Equal("reparse_point", result.ReasonCode);
    }

    [Fact]
    public void Validate_RejectsProtectedWindowsDirectories()
    {
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        var targets = new[]
        {
            (Path.Combine(windows, "System32", "unsafe.dll"), windows),
            (Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "UnsafeApp"),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)),
            (Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "UnsafeApp"),
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData))
        };

        foreach (var (target, scope) in targets)
        {
            var result = new WindowsPathSafetyPolicy(_fileSystem).Validate(target, scope);
            Assert.False(result.IsSafe);
            Assert.Equal("protected_root", result.ReasonCode);
        }
    }

    [Fact]
    public void Validate_AllowsNormalTargetUnderApprovedScope()
    {
        var target = Path.Combine(_root, "normal", "file.txt");
        _fileSystem.Set(target, DeletionItemType.File, sizeBytes: 10);

        var result = Policy().Validate(target, _root);

        Assert.True(result.IsSafe, result.Message);
        Assert.Equal(Path.GetFullPath(target), result.CanonicalPath);
    }

    public void Dispose()
    {
        Directory.Delete(_root, recursive: true);
    }

    private WindowsPathSafetyPolicy Policy() => new(_fileSystem, []);
}
