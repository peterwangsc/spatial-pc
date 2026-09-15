// Local derivative fixture policy. Upstream Apple source/license preserved.
using System;
using System.Diagnostics;
using System.IO;

namespace FoveatedStreaming.WindowsSample
{
    internal static class FixturePolicy
    {
        public static string ValidateRuntime(string manifest)
        {
            if (string.IsNullOrWhiteSpace(manifest) || !Path.IsPathRooted(manifest) ||
                manifest.StartsWith(@"\\") || manifest.IndexOf('"') >= 0 ||
                !string.Equals(Path.GetFileName(manifest), "openxr_cloudxr.json", StringComparison.OrdinalIgnoreCase) ||
                !File.Exists(manifest))
                throw new InvalidOperationException("Select the reviewed local runtime manifest explicitly.");
            return Path.GetFullPath(manifest);
        }

        public static string RequireRuntime()
        {
            return ValidateRuntime(Environment.GetEnvironmentVariable("SPATIALPC_XR_RUNTIME_JSON"));
        }
        public static void MatchRuntime(string actual, string expected)
        {
            if (!string.Equals(ValidateRuntime(actual), ValidateRuntime(expected), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Runtime manifest does not match fixture selection.");
        }

        public static ProcessStartInfo Child(string executable, string manifest)
        {
            manifest = ValidateRuntime(manifest);
            if (!Path.IsPathRooted(executable) || executable.StartsWith(@"\\") || !File.Exists(executable))
                throw new InvalidOperationException("Select the reviewed local executable explicitly.");
            var info = new ProcessStartInfo(Path.GetFullPath(executable)) {
                UseShellExecute = false, CreateNoWindow = true,
                WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(executable))
            };
            info.EnvironmentVariables["XR_RUNTIME_JSON"] = manifest;
            info.EnvironmentVariables["NV_CXR_FILE_LOGGING"] = "0";
            info.EnvironmentVariables.Remove("XR_ENABLE_API_LAYERS");
            info.EnvironmentVariables.Remove("XR_API_LAYER_PATH");
            info.EnvironmentVariables.Remove("XR_LOADER_DEBUG");
            return info;
        }

        public static string MessageMetadata(bool sent, int bytes)
        {
            if (bytes < 1 || bytes > 65536) throw new InvalidDataException("Session message length outside fixture limit.");
            return (sent ? "[SEND] bytes=" : "[RECV] bytes=") + bytes;
        }
    }
}
