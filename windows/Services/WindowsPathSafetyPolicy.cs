using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class WindowsPathSafetyPolicy : IWindowsPathSafetyPolicy
{
    private static readonly char[] Separators = ['\\', '/'];
    private readonly IWindowsFileSystemInspector _fileSystem;
    private readonly IReadOnlyList<string> _protectedRoots;

    public WindowsPathSafetyPolicy()
        : this(new WindowsFileSystemInspector())
    {
    }

    public WindowsPathSafetyPolicy(
        IWindowsFileSystemInspector fileSystem,
        IEnumerable<string>? protectedRoots = null)
    {
        _fileSystem = fileSystem;
        _protectedRoots = (protectedRoots ?? DefaultProtectedRoots())
            .Where(root => !string.IsNullOrWhiteSpace(root))
            .Select(root => TryCanonicalize(root, out var canonical) ? canonical : string.Empty)
            .Where(root => root.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public PathSafetyResult ValidateScopeRoot(string scopeRoot)
    {
        var rawCheck = ValidateRawPath(scopeRoot, "scope");
        if (rawCheck is not null)
        {
            return rawCheck;
        }

        if (!TryCanonicalize(scopeRoot, out var canonicalRoot))
        {
            return PathSafetyResult.Reject("invalid_scope", "The approved scope root could not be canonicalized.");
        }

        if (IsUncPath(canonicalRoot) || IsDriveRoot(canonicalRoot))
        {
            return PathSafetyResult.Reject("unsafe_scope_root", "Drive and UNC roots cannot be deletion scopes.", canonicalScopeRoot: canonicalRoot);
        }

        if (_protectedRoots.Any(root => IsPathAtOrUnderRoot(canonicalRoot, root)))
        {
            return PathSafetyResult.Reject(
                "protected_scope_root",
                "Protected Windows and application roots cannot be deletion scopes.",
                canonicalScopeRoot: canonicalRoot);
        }

        var scopeInfo = _fileSystem.Inspect(canonicalRoot);
        if (!scopeInfo.Exists || scopeInfo.ItemType != DeletionItemType.Directory)
        {
            return PathSafetyResult.Reject(
                "invalid_scope",
                "The approved scope root must be an existing directory.",
                canonicalScopeRoot: canonicalRoot);
        }

        var reparse = FindReparsePoint(canonicalRoot);
        return reparse is null
            ? new PathSafetyResult(true, "safe_scope", "The approved scope root is safe.", canonicalRoot, canonicalRoot, scopeInfo)
            : PathSafetyResult.Reject("reparse_scope", $"An approved scope path component is a reparse point: {reparse}", canonicalScopeRoot: canonicalRoot);
    }

    public PathSafetyResult Validate(string path, string approvedScopeRoot)
    {
        var rawPathCheck = ValidateRawPath(path, "target");
        if (rawPathCheck is not null)
        {
            return rawPathCheck;
        }

        var rawScopeCheck = ValidateRawPath(approvedScopeRoot, "scope");
        if (rawScopeCheck is not null)
        {
            return rawScopeCheck;
        }

        if (!TryCanonicalize(path, out var canonicalPath) || !TryCanonicalize(approvedScopeRoot, out var canonicalRoot))
        {
            return PathSafetyResult.Reject("canonicalization_failed", "The target or approved scope could not be canonicalized.");
        }

        if (IsUncPath(canonicalPath))
        {
            return PathSafetyResult.Reject("unc_path", "UNC targets are not supported by the reversible deletion fallback.", canonicalPath, canonicalRoot);
        }

        if (IsDriveRoot(canonicalPath))
        {
            return PathSafetyResult.Reject("drive_root", "Drive roots cannot be deleted.", canonicalPath, canonicalRoot);
        }

        if (IsDriveRoot(canonicalRoot) || IsUncPath(canonicalRoot))
        {
            return PathSafetyResult.Reject("unsafe_scope_root", "Drive and UNC roots cannot be deletion scopes.", canonicalPath, canonicalRoot);
        }

        if (_protectedRoots.Any(root => IsPathAtOrUnderRoot(canonicalRoot, root)))
        {
            return PathSafetyResult.Reject(
                "protected_root",
                "The approved scope is inside a protected Windows or application root.",
                canonicalPath,
                canonicalRoot);
        }

        var scopeInfo = _fileSystem.Inspect(canonicalRoot);
        if (!scopeInfo.Exists || scopeInfo.ItemType != DeletionItemType.Directory)
        {
            return PathSafetyResult.Reject(
                "invalid_scope",
                "The approved scope root must be an existing directory.",
                canonicalPath,
                canonicalRoot);
        }

        if (string.Equals(canonicalPath, canonicalRoot, StringComparison.OrdinalIgnoreCase))
        {
            return PathSafetyResult.Reject("scope_root", "The configured scope root itself cannot be deleted.", canonicalPath, canonicalRoot);
        }

        if (!IsPathUnderRoot(canonicalPath, canonicalRoot))
        {
            return PathSafetyResult.Reject("outside_scope", "The target escapes its approved scope.", canonicalPath, canonicalRoot);
        }

        if (_protectedRoots.Any(root => IsPathAtOrUnderRoot(canonicalPath, root)))
        {
            return PathSafetyResult.Reject("protected_root", "The target is inside a protected Windows or application root.", canonicalPath, canonicalRoot);
        }

        var reparse = FindReparsePoint(canonicalPath);
        if (reparse is not null)
        {
            return PathSafetyResult.Reject("reparse_point", $"A target path component is a reparse point: {reparse}", canonicalPath, canonicalRoot);
        }

        return new PathSafetyResult(
            true,
            "safe",
            "The target passed Windows path safety validation.",
            canonicalPath,
            canonicalRoot,
            _fileSystem.Inspect(canonicalPath));
    }

    private static PathSafetyResult? ValidateRawPath(string? path, string role)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return PathSafetyResult.Reject($"empty_{role}", $"The {role} path is empty.");
        }

        var trimmed = path.Trim();
        if (trimmed.Contains('%', StringComparison.Ordinal))
        {
            return PathSafetyResult.Reject(
                "environment_path",
                $"The {role} must not contain environment-variable expressions.");
        }

        var normalized = trimmed.Replace('/', '\\');
        if (normalized.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith(@"\\.\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith(@"\??\", StringComparison.OrdinalIgnoreCase) ||
            normalized.Contains(@"\GLOBALROOT\", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("GLOBALROOT", StringComparison.OrdinalIgnoreCase))
        {
            return PathSafetyResult.Reject("device_path", $"The {role} uses a device or NT path prefix.");
        }

        if (!Path.IsPathFullyQualified(trimmed))
        {
            return PathSafetyResult.Reject("relative_path", $"The {role} must be an absolute path.");
        }

        if (trimmed.Split(Separators, StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => segment is "." or ".."))
        {
            return PathSafetyResult.Reject("traversal", $"The {role} contains a raw traversal segment.");
        }

        var firstColon = normalized.IndexOf(':');
        if (firstColon >= 0 && (firstColon != 1 || normalized.IndexOf(':', firstColon + 1) >= 0))
        {
            return PathSafetyResult.Reject("alternate_data_stream", $"The {role} contains alternate data stream syntax.");
        }

        return null;
    }

    private string? FindReparsePoint(string canonicalPath)
    {
        // A lexical scope can itself sit below a junction. Walk from the volume root so
        // an alias above the scope cannot redirect a permitted target into a protected tree.
        var current = Path.GetPathRoot(canonicalPath);
        if (string.IsNullOrWhiteSpace(current))
        {
            return canonicalPath;
        }

        if (_fileSystem.Inspect(current).IsReparsePoint)
        {
            return current;
        }

        var relative = Path.GetRelativePath(current, canonicalPath);
        foreach (var segment in relative.Split(Separators, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (_fileSystem.Inspect(current).IsReparsePoint)
            {
                return current;
            }
        }

        return null;
    }

    private static bool TryCanonicalize(string path, out string canonicalPath)
    {
        canonicalPath = string.Empty;
        try
        {
            var expanded = Environment.ExpandEnvironmentVariables(path.Trim());
            if (expanded.Contains('%', StringComparison.Ordinal))
            {
                return false;
            }

            canonicalPath = Path.GetFullPath(expanded).TrimEnd(Separators);
            return canonicalPath.Length > 0;
        }
        catch (Exception ex) when (ex is ArgumentException or IOException or NotSupportedException or System.Security.SecurityException)
        {
            return false;
        }
    }

    private static bool IsDriveRoot(string path)
    {
        var root = Path.GetPathRoot(path);
        return !string.IsNullOrWhiteSpace(root) &&
               string.Equals(path.TrimEnd(Separators), root.TrimEnd(Separators), StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsUncPath(string path) => path.StartsWith(@"\\", StringComparison.Ordinal);

    private static bool IsPathAtOrUnderRoot(string path, string root) =>
        string.Equals(path, root, StringComparison.OrdinalIgnoreCase) || IsPathUnderRoot(path, root);

    private static bool IsPathUnderRoot(string path, string root) =>
        path.StartsWith(root.TrimEnd(Separators) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith(root.TrimEnd(Separators) + Path.AltDirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    private static IEnumerable<string> DefaultProtectedRoots()
    {
        yield return Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        yield return Environment.SystemDirectory;
        yield return Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        yield return Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        yield return Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFiles);
        yield return Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFilesX86);
        yield return Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        yield return Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms);
    }
}
